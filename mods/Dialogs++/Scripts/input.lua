local conf = require("conf")
local S = require("state")
local U = require("util")
local Sch = require("sched")
local E = require("engine")
local P = require("probes")
local log = conf.log
local settings = conf.settings
local Try, Usable = U.Try, U.Usable
local optionsShown = U.optionsShown

-- Key callbacks fire off the game thread. The delayed form is the one that
-- stays safe in this UE4SS build.
local function dispatch(fn)
    if type(ExecuteInGameThreadWithDelay) == "function" then
        ExecuteInGameThreadWithDelay(0, fn)
    else
        ExecuteInGameThread(fn)
    end
end

local function onClick()
    --- Ignore clicks outside active dialogue; lingering widgets may remain Usable.
    if not Usable(S.seenDialogue) then return end
    if S.dialogueOver then return end
    -- Frozen transition: never touch the graph during fades and teardown.
    if S.graphFrozen then
        S.clickCount = S.clickCount + 1
        log("skip: click #%d blocked (frozen)", S.clickCount)
        return
    end

    S.clickCount = S.clickCount + 1
    local mine = S.clickCount
    local tag = string.format("click #%d", mine)
    local now = U.passDebounce(S.lastFireClock, settings.DebounceMs)
    if now == nil then
        log("skip: %s blocked (debounce)", tag)
        return
    end
    -- Read the gap before overwriting the timestamp.
    local sincePrevMs = (now - S.lastFireClock) * 1000
    S.lastFireClock = now

    local shown = optionsShown()
    if shown then
        log("choice: %s", E.doConfirm(tag, "click", now, sincePrevMs))
        return
    end

    -- Skip path: engine.doSkip enforces in-flight, dialogue, menu, and first-line gates.
    if not E.lmbOn() then return end
    if E.twoPress(tag) then return end
    log("skip: %s", E.doSkip(tag))
end

-- Space skip: use click skip gates off-list; keep Space native on choice lists.
-- Two-press mode stays native; the bind never consumes Space.
local finishSpaceSkip

-- Queue the call on the game thread. Zero delay means the next frame, not a
-- second press: the press already happened, this only moves the call into the
-- engine's thread so the action is safe to invoke.
local function scheduleSpace(pending, delayMs)
    Sch.later(delayMs or 0, function() finishSpaceSkip(pending) end)
end

finishSpaceSkip = function(pending)
    if S.pendingSpace ~= pending then return end
    S.pendingSpace = nil
    local spanMs = (os.clock() - pending.at) * 1000
    if spanMs > 80 and not pending.waited then
        log("skip: %s late (+%.0fms)", pending.tag, spanMs)
    end

    if settings.TwoPress or not E.spaceOn() then
        log("skip: %s blocked (mode)", pending.tag)
        return
    end
    if S.dialogueOver or S.endStrikes > 0 then
        log("skip: %s blocked (dialogue over)", pending.tag)
        return
    end
    if S.escPauseArmed or S.menuOpen then
        log("skip: %s blocked (pause)", pending.tag)
        return
    end
    if S.graphFrozen then
        log("skip: %s blocked (frozen)", pending.tag)
        return
    end
    if not S.started then
        log("skip: %s blocked (not started)", pending.tag)
        return
    end
    if S.seenDialogue ~= pending.dlg then
        log("skip: %s blocked (new dialogue)", pending.tag)
        return
    end
    -- The widget clears its own dialogue pointer before the subsystem drops
    -- the active one. Calling the skip entry in that window dereferences a
    -- null dialogue, so a press there is dropped.
    local shownDlg = Try(function() return pending.dlg.DisplayedDialogue end)
    if shownDlg == nil or not Usable(shownDlg) then
        log("skip: %s blocked (no displayed dialogue)", pending.tag)
        return
    end
    local csNow = Try(function() return pending.dlg.CinematicSystem end)
    if Usable(csNow) then
        local activeNow = Try(function() return csNow.ActiveDialogue end)
        if activeNow == nil or not Usable(activeNow) then
            log("skip: %s blocked (no active dialogue)", pending.tag)
            return
        end
    end
    if optionsShown() or S.lastMode == S.MODE_OPTIONS then
        log("skip: %s blocked (list)", pending.tag)
        return
    end
    if S.skipFlight ~= nil then
        -- The tick refreshes lineSig at 250 ms, so the gate can be up to that
        -- stale. A fresh read decides whether the previous skip already landed;
        -- if it did, continue. If not, hold the press and retry instead of
        -- dropping it: the user pressed, the skip should happen when it can.
        local sigNow, guidNow = U.flightSig()
        local moved = sigNow ~= nil and sigNow ~= "no-response"
            and S.skipFlight.sig ~= nil and sigNow ~= S.skipFlight.sig
        if moved then
            log("skip: %s flight released (fresh)", pending.tag)
            S.skipFlight = nil
            S.lineSig = sigNow
            if guidNow ~= nil then S.lineGuid = guidNow end
        else
            local waitedMs = (os.clock() - pending.at) * 1000
            if waitedMs < S.SPACE_RETRY_MS then
                S.pendingSpace = pending
                if not pending.waited then
                    pending.waited = true
                    log("skip: %s waiting (in flight)", pending.tag)
                end
                scheduleSpace(pending, S.SPACE_RETRY_STEP)
                return
            end
            log("skip: %s blocked (in flight, %.0fms)", pending.tag, waitedMs)
            return
        end
    end
    if (S.lastNativeSkipAt or 0) >= pending.at then
        log("skip: %s native (hook moved)", pending.tag)
        return
    end
    if S.skipHookReady then
        log("skip: %s", E.doSkip(pending.tag))
        return
    end
    if pending.sig == nil or pending.guid == nil then
        log("skip: %s blocked (no baseline)", pending.tag)
        return
    end
    if S.lineGuid == nil or S.lineGuid == "no-response" then
        log("skip: %s blocked (no line)", pending.tag)
        return
    end
    if S.lineGuid ~= pending.guid then
        log("skip: %s native (node moved)", pending.tag)
        return
    end
    if S.lineSig == nil or S.lineSig == "no-response" then
        log("skip: %s blocked (no signature)", pending.tag)
        return
    end
    if S.lineSig ~= pending.sig then
        log("skip: %s voice moved (same node)", pending.tag)
    end

    log("skip: %s", E.doSkip(pending.tag))
end

local function onSpace()
    if not Usable(S.seenDialogue) then return end
    if S.dialogueOver then return end
    if S.graphFrozen then
        S.spaceCount = S.spaceCount + 1
        log("skip: space #%d blocked (frozen)", S.spaceCount)
        return
    end
    local shownS = optionsShown()
    if shownS then
        log("space: native (list)")
        return
    end
    if not E.spaceOn() then
        log("space: native (skip off)")
        return
    end
    if settings.TwoPress then
        -- Native two-step: the game shows the prompt, then skips on the second press.
        log("space: native (two-press)")
        return
    end
    if S.pendingSpace ~= nil then
        S.spaceCount = S.spaceCount + 1
        log("skip: space #%d blocked (pending)", S.spaceCount)
        return
    end
    S.spaceCount = S.spaceCount + 1
    local mine = S.spaceCount
    local tag = string.format("space #%d", mine)
    local now = U.passDebounce(S.lastSpaceClock, settings.DebounceMs)
    if now == nil then
        log("skip: %s blocked (debounce)", tag)
        return
    end
    S.lastSpaceClock = now
    if (now - (S.lastNativeSkipAt or 0)) < 0.25 then
        log("skip: %s native (already)", tag)
        return
    end

    -- The game's own handler runs first for the same press; by the time we get
    -- here, a native skip is already recorded. Only call the entry when it is
    -- not, and hop to the game thread for the call. Zero delay means the next
    -- tick, not a second press: the gate above already covers the native path.
    local pending = {
        tag = tag,
        at = now,
        sig = S.lineSig,
        guid = S.lineGuid,
        dlg = S.seenDialogue,
    }
    S.pendingSpace = pending
    log("skip: %s press (line=%s)", tag, conf.shortId(S.lineSig))
    scheduleSpace(pending, S.SPACE_DEFER_MS)
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
        log("nav %s: native bridge missing", dir)
        return
    end
    if dir == "W" then
        if E.native.prime == nil then
            log("nav W: arrow up missing")
            return
        end
        local okU, errU = pcall(E.native.prime)
        log("nav W: up ok=%s %s", tostring(okU), okU and "" or tostring(errU))
    else
        if E.native.down == nil then
            log("nav S: arrow down missing (old DLL?)")
            return
        end
        local okD, errD = pcall(E.native.down)
        log("nav S: down ok=%s %s", tostring(okD), okD and "" or tostring(errD))
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
        log("choice: key %s blocked (frozen)", which)
        return
    end
    local now = U.passDebounce(S.lastKeyClock, settings.DebounceMs)
    if now == nil then
        log("choice: key %s blocked (debounce)", which)
        return
    end
    S.lastKeyClock = now
    -- shared spam clock: a key confirm right after a click tail is still a
    -- tail confirm - same quiet rule as clicks.
    local sincePrevMs = (now - S.lastFireClock) * 1000
    S.lastFireClock = now
    local shown = optionsShown()
    if not shown then return end
    log("choice: %s", E.doConfirm(string.format("key %s", which), "key", now, sincePrevMs))
end

local function bindNavKey(name, fn, label)
    local k = findKey(name)
    if k == nil then
        conf.warn("bind %s: key missing in this UE4SS build", label)
        return
    end
    local ok, err = pcall(function()
        RegisterKeyBind(k, function()
            dispatch(fn)
        end)
    end)
    if not ok then conf.warn("bind %s: %s", label, tostring(err)) end
end
bindNavKey("W", function() onNavKey("W") end, "W")
bindNavKey("S", function() onNavKey("S") end, "S")
bindNavKey("E", function() onConfirmKey("E") end, "E")
bindNavKey("F", function() onConfirmKey("F") end, "F")

local lmb = Try(function() return Key.LEFT_MOUSE_BUTTON end)
if lmb ~= nil then
    local ok, err = pcall(function()
        RegisterKeyBind(lmb, function()
            dispatch(onClick)
        end)
    end)
    if not ok then conf.warn("bind LMB: %s", tostring(err)) end
else
    conf.warn("bind LMB: key missing in this UE4SS build")
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
            log("pause: esc (armed=%s)", tostring(S.escPauseArmed))
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
        end)
    end)
    if not ok then conf.warn("bind wheel %s: %s", name, tostring(err)) end
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
    log("wheel: keys type=%s entries (%d): %s",
        type(Key), #all, table.concat(all, ", "))
    local upCount, downCount = { 0 }, { 0 }
    for _, e in ipairs(ups) do bindWheel("up:" .. e[1], e[2], upCount) end
    for _, e in ipairs(downs) do bindWheel("down:" .. e[1], e[2], downCount) end
    if #ups == 0 and #downs == 0 then
        conf.warn("bind wheel: no wheel keys in this UE4SS build")
    end
end

-- Space: vanilla listen-only or skip handler when enabled. Binding never consumes input.
local spc = Try(function() return Key.SPACE end)
if spc ~= nil then
    pcall(function()
        RegisterKeyBind(spc, function()
            dispatch(onSpace)
        end)
    end)
else
    conf.warn("bind space: key missing in this UE4SS build")
end

return true
