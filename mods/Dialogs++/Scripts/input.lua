local conf = require("conf")
local S = require("state")
local U = require("util")
local E = require("engine")
local P = require("probes")
local log = conf.log
local settings = conf.settings
local Try, Usable = U.Try, U.Usable
local optionsShown = U.optionsShown

local function onClick()
    --- Ignore clicks outside active dialogue; lingering widgets may remain Usable.
    if not Usable(S.seenDialogue) then return end
    if S.dialogueOver then return end
    -- Frozen transition: avoid the graph during fades and teardown; clicks here have crashed the game.
    if S.graphFrozen then
        S.clickCount = S.clickCount + 1
        log("click #%d swallowed (frozen)", S.clickCount)
        return
    end

    S.clickCount = S.clickCount + 1
    local mine = S.clickCount
    local tag = string.format("click #%d", mine)
    local now = U.passDebounce(S.lastFireClock, settings.DebounceMs)
    if now == nil then
        log("%s swallowed (debounce)", tag)
        return
    end
    -- Read the gap before overwriting the timestamp.
    local sincePrevMs = (now - S.lastFireClock) * 1000
    S.lastFireClock = now

    local shown = optionsShown()
    if shown then
        log("%s", E.doConfirm(tag, "click", now, sincePrevMs))
        return
    end

    -- Skip path: engine.doSkip enforces in-flight, dialogue, menu, and first-line gates.
    if not E.lmbOn() then return end
    if E.twoPress(tag) then return end
    log("%s", E.doSkip(tag))
end

-- Space skip: use click skip gates off-list; keep Space native on choice lists.
-- Two-press mode stays native; the bind never consumes Space.
local function onSpace()
    if not Usable(S.seenDialogue) then return end
    if S.dialogueOver then return end
    if S.graphFrozen then
        S.spaceCount = S.spaceCount + 1
        log("space #%d swallowed (frozen)", S.spaceCount)
        return
    end
    local shownS = optionsShown()
    if shownS then
        log("space")
        return
    end
    if not E.spaceOn() then
        log("space")
        return
    end
    if settings.TwoPress then
        -- Native two-step: the game shows the prompt, then skips on the second press.
        log("space")
        return
    end
    S.spaceCount = S.spaceCount + 1
    local mine = S.spaceCount
    local tag = string.format("space #%d", mine)
    local now = U.passDebounce(S.lastSpaceClock, settings.DebounceMs)
    if now == nil then
        log("%s swallowed (debounce)", tag)
        return
    end
    S.lastSpaceClock = now
    log("%s", E.doSkip(tag))
end

-- W/S navigate via DLL arrows; confirm uses the click gates.
-- Binds respect live KbNav/ConfirmKey; keys aren't consumed off-list.
local function findKey(name)
    if type(Key) ~= "table" then return nil end
    if Key[name] ~= nil then return Key[name] end
    local want = string.upper(name)
    local found = nil
    pcall(function()
        for k, v in pairs(Key) do
            if type(k) == "string" and string.upper(k) == want then
                found = v
                break
            end
        end
    end)
    return found
end

local function onNavKey(dir)
    if not settings.KbNav then return end
    if not Usable(S.seenDialogue) then return end
    if S.dialogueOver then return end
    if S.graphFrozen then return end
    local shownN = optionsShown()
    if not shownN then return end
    if S.lastMode ~= S.MODE_OPTIONS then return end
    if E.native == nil then
        log("key %s: native missing", dir)
        return
    end
    if dir == "W" then
        if E.native.prime == nil then
            log("key W: arrow up missing")
            return
        end
        local okU, errU = pcall(E.native.prime)
        log("key W -> up ok=%s %s", tostring(okU), okU and "" or tostring(errU))
    else
        if E.native.down == nil then
            log("key S: arrow down missing (old DLL?)")
            return
        end
        local okD, errD = pcall(E.native.down)
        log("key S -> down ok=%s %s", tostring(okD), okD and "" or tostring(errD))
    end
end

local function onConfirmKey(which)
    -- 0 = E, 1 = F, 2 = either key confirms.
    local ck = settings.ConfirmKey or 0
    if ck ~= 2 and which ~= ((ck == 1) and "F" or "E") then return end
    if not settings.KbNav then return end
    if not Usable(S.seenDialogue) then return end
    if S.dialogueOver then return end
    if S.graphFrozen then
        log("key %s swallowed (frozen)", which)
        return
    end
    local now = U.passDebounce(S.lastKeyClock, settings.DebounceMs)
    if now == nil then
        log("key %s swallowed (debounce)", which)
        return
    end
    S.lastKeyClock = now
    -- shared spam clock: a key confirm right after a click tail is still a
    -- tail confirm - same quiet rule as clicks.
    local sincePrevMs = (now - S.lastFireClock) * 1000
    S.lastFireClock = now
    local shown = optionsShown()
    if not shown then return end
    log("%s", E.doConfirm(string.format("key %s", which), "key", now, sincePrevMs))
end

local function bindNavKey(name, fn, label)
    local k = findKey(name)
    if k == nil then
        log("%s not available in this UE4SS build", label)
        return
    end
    local ok, err = pcall(function()
        RegisterKeyBind(k, function()
            ExecuteInGameThread(fn)
        end)
    end)
    if not ok then log("could not bind %s: %s", label, tostring(err)) end
end
bindNavKey("W", function() onNavKey("W") end, "W")
bindNavKey("S", function() onNavKey("S") end, "S")
bindNavKey("E", function() onConfirmKey("E") end, "E")
bindNavKey("F", function() onConfirmKey("F") end, "F")

local lmb = Try(function() return Key.LEFT_MOUSE_BUTTON end)
if lmb ~= nil then
    local ok, err = pcall(function()
        RegisterKeyBind(lmb, function()
            ExecuteInGameThread(onClick)
        end)
    end)
    if not ok then log("could not bind LMB: %s", tostring(err)) end
else
    log("LMB key not available in this UE4SS build")
end

-- ESC arms pause detection until the menu poll confirms it; disarm on disable,
-- confirmed transitions, or swallowed presses.
local esc = Try(function() return Key.ESCAPE end)
if esc ~= nil then
    pcall(function()
        RegisterKeyBind(esc, function()
            if Usable(S.seenDialogue) and not S.dialogueOver then
                S.escPauseArmed = not S.escPauseArmed
                -- ESC close: toggling OFF triggers the shared transition and clock freeze.
                -- Mouse close (Continue) is detected by tick focus recovery.
                if not S.escPauseArmed and S.menuOpen then
                    S.menuOpen = false
                    P.noteMenuClosed("closed (esc)")
                end
                -- ESC likely means the menu instance now exists; keep its live anchor.
                -- Reset only dead anchors and parked resolve budgets.
                if S.escPauseArmed then
                    if not Usable(S.pauseWidget) then
                        S.pauseResolveTries = nil
                        S.pauseResolveParked = nil
                        S.pauseResolved = nil
                    end
                end
            else
                S.escPauseArmed = false
            end
            log("KEY ESC")
        end)
    end)
end

-- Discover wheel keys from the Key table; documented names are missing in this UE4SS build.
-- Listen-only binds don't consume input; DLL stays active. Silent outside dialogue.
local function bindWheel(name, keyObj, counter)
    local ok, err = pcall(function()
        RegisterKeyBind(keyObj, function()
            if not Usable(S.seenDialogue) then return end
            counter[1] = counter[1] + 1
            log("wheel %s #%d", name, counter[1])
        end)
    end)
    log("wheel bind %s: %s", name, ok and "ok" or tostring(err))
end
do
    local all, ups, downs = {}, {}, {}
    if type(Key) == "table" then
        pcall(function()
            for k, v in pairs(Key) do
                if type(k) == "string" then
                    local l = k:lower()
                    if l:find("wheel", 1, true) or l:find("scroll", 1, true) then
                        all[#all + 1] = k
                        if l:find("up", 1, true) then
                            ups[#ups + 1] = { k, v }
                        elseif l:find("down", 1, true) then
                            downs[#downs + 1] = { k, v }
                        end
                    end
                end
            end
        end)
    end
    table.sort(all)
    log("Key type=%s wheel/scroll entries (%d): %s",
        type(Key), #all, table.concat(all, ", "))
    local upCount, downCount = { 0 }, { 0 }
    for _, e in ipairs(ups) do bindWheel("up:" .. e[1], e[2], upCount) end
    for _, e in ipairs(downs) do bindWheel("down:" .. e[1], e[2], downCount) end
    if #ups == 0 and #downs == 0 then
        log("wheel keys not available in this UE4SS build")
    end
end

-- Space: vanilla listen-only or skip handler when enabled. Binding never consumes input.
local spc = Try(function() return Key.SPACE end)
if spc ~= nil then
    pcall(function()
        RegisterKeyBind(spc, function()
            ExecuteInGameThread(onSpace)
        end)
    end)
else
    log("space key not available in this UE4SS build")
end

return true
