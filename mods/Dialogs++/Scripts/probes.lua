local conf = require("conf")
local S = require("state")
local U = require("util")
local log = conf.log
local Try, Usable, resolve = U.Try, U.Usable, U.resolve
local P = {}

P.readTimedChoice = function()
    local dlg = S.seenDialogue
    if not Usable(dlg) then return false end
    local cn = Try(function() return dlg.DisplayedChoice end)
    if not Usable(cn) then return false end
    local d = Try(function() return cn.TimedChoiceDuration end)
    if type(d) == "number" and d > 0 then return true end
    local td = Try(function() return cn.TimedChoiceData end)
    if td ~= nil then
        local b = Try(function() return td.bIsTimedChoice end)
        if b == true then return true end
    end
    return false
end

--- Pause menu: stable instance after first open; visibility tracks open/close.
local function isLivePauseInstance(o)
    if not Usable(o) then return false end
    local cn = Try(function() return o:GetClass():GetFName():ToString() end)
    return type(cn) == "string" and cn:find("PauseMenu", 1, true) ~= nil
end
P.resolvePauseMenu = function()
    if S.pauseResolved ~= nil then return end
    S.pauseScanTries = (S.pauseScanTries or 0) + 1
    if S.pauseScanTries > 5 then
        if not S.pauseScanParked then
            S.pauseScanParked = true
            log("pausemenu: scan failed, parking till next dialogue")
        end
        return
    end
    local found = nil
    local how = nil
    if type(FindAllOf) == "function" then
        local ok, res = pcall(FindAllOf, "WBP_PauseMenu_C")
        if ok and res ~= nil then
            pcall(function()
                for _, o in pairs(res) do
                    if isLivePauseInstance(o) then found = o break end
                end
            end)
            res = nil
            if found ~= nil then how = "findall" end
        else
            return -- transient miss
        end
    end
    if found == nil and type(FindObject) == "function" then
        local cand = Try(function() return FindObject(nil, "WBP_PauseMenu_C", 0, 0) end)
        if isLivePauseInstance(cand) then
            found = cand
            how = "findobject"
        elseif Usable(cand) then
            return
        end
    end
    S.pauseResolved = true
    if found ~= nil then
        S.pauseWidget = found
        local nm = Try(function() return found:GetName() end)
        local cn = Try(function() return found:GetClass():GetFName():ToString() end)
        local rsig = tostring(cn) .. "/" .. tostring(how)
        if rsig ~= S.lastResolveSig then
            S.lastResolveSig = rsig
            log("pausemenu: resolved (name=%s cls=%s via %s)", tostring(nm), tostring(cn), tostring(how))
        end
    else
        log("pausemenu: no live instance")
    end
end

--- Shared menu transition: poll and ESC paths log identically and freeze clocks.
P.thawPauseClocks = function(pausedFor)
    if pausedFor == nil or pausedFor <= 0 then return end
    if S.state2Clock ~= nil then S.state2Clock = S.state2Clock + pausedFor end
    if S.timedWatchT0 ~= nil then S.timedWatchT0 = S.timedWatchT0 + pausedFor end
    if S.arrowClock ~= nil then S.arrowClock = S.arrowClock + pausedFor end
    if S.lineSigT ~= nil then S.lineSigT = S.lineSigT + pausedFor end
    if S.skipFlight ~= nil then S.skipFlight.t = S.skipFlight.t + pausedFor end
end
P.noteMenuOpen = function(label)
    S.pauseOpenedAt = os.clock()
    log("menu: %s", label)
end
P.noteMenuClosed = function(label)
    local now = os.clock()
    local pausedFor = 0
    if S.pauseOpenedAt ~= nil then
        pausedFor = now - S.pauseOpenedAt
        S.pauseOpenedAt = nil
        P.thawPauseClocks(pausedFor)
    end
    if pausedFor >= 1 then
        log("menu: %s (paused %ds)", label, math.floor(pausedFor))
    else
        log("menu: %s", label)
    end
end

P.readPauseMenu = function()
    P.resolvePauseMenu()
    local open = false
    if Usable(S.pauseWidget) then
        local vis = Try(function() return S.pauseWidget:GetVisibility() end)
        -- IsVisible is the gate: GetVisibility sits at a constant on live
        -- instances; a nil reading keeps the previous state (no flap).
        local isv = Try(function() return S.pauseWidget:IsVisible() end)
        -- the menu's own focus, logged as witness next to IsVisible
        local mfocus = Try(function() return S.pauseWidget:HasFocusedDescendants() end)
        if isv ~= nil then
            open = (isv == true)
            local sig = "vis=" .. tostring(vis) .. " isvis=" .. tostring(isv)
                .. " mfocus=" .. tostring(mfocus)
            if S.lastMenuSig ~= sig then
                S.lastMenuSig = sig
                log("pausemenu: %s", sig)
            end
        elseif vis ~= nil then
            open = (vis == 0)
        end
    else
        if S.pauseWidget ~= nil then
            S.pauseWidget = nil
            S.pauseResolved = nil
            log("pausemenu: anchor died")
        end
    end
    if open ~= S.menuOpen then
        S.menuOpen = open
        S.escPauseArmed = false
        if open then
            P.noteMenuOpen("open")
        else
            P.noteMenuClosed("closed")
        end
    end
end

--- After dialogue end, find a live widget with a valid ActiveDialogue.
P.reacquireDialogue = function()
    if type(FindAllOf) ~= "function" then return nil end
    local ok, res = pcall(FindAllOf, "WBP_Dialogue_C")
    if not ok or res == nil then return nil end
    local found = nil
    pcall(function()
        for _, o in pairs(res) do
            if Usable(o) then
                local cs = Try(function() return o.CinematicSystem end)
                if Usable(cs) then
                    local ad = Try(function() return cs.ActiveDialogue end)
                    if Usable(ad) then found = o break end
                end
            end
        end
    end)
    res = nil
    return found
end

--- Log Space-path flags from the fresh per-dialogue widget, never cache it.
P.readSkipButton = function()
    local dlg = S.seenDialogue
    if not Usable(dlg) then return end
    local btn = Try(function() return dlg.SkipButtonWidget end)
    if not Usable(btn) then
        S.promptVisible = nil
        if S.skipBtnDone == nil then
            S.skipBtnDone = true
            S.lastSkipBtnSig = "gone"
            log("skipbtn: widget null/unreadable")
        elseif S.lastSkipBtnSig ~= "gone" then
            S.lastSkipBtnSig = "gone"
            log("skipbtn chg: widget null/unreadable")
        end
        return
    end
    local hold = Try(function() return btn.bHoldSkipButtonAfterPressing end)
    local anyIn = Try(function() return btn.bSkipOnAnyInput end)
    local handle = Try(function() return btn.SkipInputAction end)
    local rowName = nil
    if handle ~= nil then
        rowName = Try(function() return handle.RowName:ToString() end)
        if type(rowName) ~= "string" then
            rowName = Try(function() return tostring(handle.RowName) end)
        end
    end

    local ea = Try(function() return btn.SkipEnhancedInputAction end)
    local eaName = nil
    if Usable(ea) then
        eaName = Try(function() return ea:GetName() end)
        if type(eaName) ~= "string" then
            eaName = Try(function() return ea:GetFullName() end)
        end
    elseif type(ea) == "userdata" then
        eaName = "null"
    else
        eaName = "missing"
    end

    local iaw = Try(function() return btn.InputActionWidget end)
    local wdgName = nil
    if Usable(iaw) then
        local wea = Try(function() return iaw.EnhancedInputAction end)
        if Usable(wea) then
            wdgName = Try(function() return wea:GetName() end)
            if type(wdgName) ~= "string" then
                wdgName = Try(function() return wea:GetFullName() end)
            end
        elseif type(wea) == "userdata" then
            wdgName = "null"
        else
            wdgName = "missing"
        end
    elseif type(iaw) == "userdata" then
        wdgName = "nowidget-null"
    else
        wdgName = "nowidget-missing"
    end

    local en = Try(function() return btn:GetIsEnabled() end)
    if en == nil then en = Try(function() return btn.bIsEnabled end) end
    local vis = Try(function() return btn:GetVisibility() end)

    if vis ~= nil then S.promptVisible = not (vis == 1 or vis == 2) end
    local sig = string.format("hold=%s any=%s row=%s ea=%s wdg=%s en=%s vis=%s",
        tostring(hold), tostring(anyIn), tostring(rowName),
        tostring(eaName), tostring(wdgName), tostring(en), tostring(vis))
    if S.skipBtnDone == nil then
        S.skipBtnDone = true
        S.lastSkipBtnSig = sig
        log("skipbtn: %s", sig)
    elseif sig ~= S.lastSkipBtnSig then
        S.lastSkipBtnSig = sig
        log("skipbtn chg: %s", sig)
    end
end

--- The settings CDO holds the timed-choice length the game arms from
--- (section /Script/DialogueSystem.CinematicSettings - the value ini mods ship).
--- Plain FindObject takes a class+name pair; full paths never hit (see
--- util.refreshAnchor), so the Static paths go first. The property read
--- validates a hit; success caches, misses log once and retry on a throttle.
local function validateSettings(o)
    if o == nil then return nil end
    local v = Try(function() return o.DefaultTimedChoiceDuration end)
    if type(v) == "number" then return o end
    local cdo = Try(function() return o:GetDefaultObject() end)
    if cdo ~= nil then
        local v2 = Try(function() return cdo.DefaultTimedChoiceDuration end)
        if type(v2) == "number" then return cdo end
    end
    return nil
end

local function cineCdo()
    if P._cineCdo ~= nil then return P._cineCdo end
    local now = os.clock()
    if P._cineRetryAt ~= nil and now < P._cineRetryAt then return nil end
    P._cineRetryAt = now + 2.0
    local cands = {}
    if type(StaticFindObject) == "function" then
        cands[#cands + 1] = { "static-cdo", function()
            return StaticFindObject("/Script/DialogueSystem.Default__CinematicSettings")
        end }
        cands[#cands + 1] = { "static-class", function()
            return StaticFindObject("/Script/DialogueSystem.CinematicSettings")
        end }
    end
    if type(FindObject) == "function" then
        cands[#cands + 1] = { "find-cdo", function()
            return FindObject(nil, "Default__CinematicSettings", 0, 0)
        end }
        cands[#cands + 1] = { "find-class", function()
            return FindObject(nil, "CinematicSettings", 0, 0)
        end }
    end
    for _, c in ipairs(cands) do
        local hit = validateSettings(Try(c[2]))
        if hit ~= nil then
            P._cineCdo = hit
            log("timed default: cdo resolved (via %s)", c[1])
            return P._cineCdo
        end
    end
    if P._cineMissLogged ~= true then
        P._cineMissLogged = true
        log("timed default: cdo not found (static+find tried)")
    end
    return nil
end

--- Timed choice length: one property write on the settings CDO covers every
--- future arming on every build - no per-node lookups, no enumeration.
--- Nodes carrying bOverrideDefaultDuration keep their authored value.
P.applyTimedDefault = function()
    local sec = conf.settings.TimerExtendSec
    if type(sec) ~= "number" then return end
    local cdo = cineCdo()
    if cdo == nil then return end
    local cur = Try(function() return cdo.DefaultTimedChoiceDuration end)
    if type(cur) ~= "number" then return end
    if P._timedDefaultOrig == nil then P._timedDefaultOrig = cur end
    -- 0 = vanilla: restore the value loaded at startup, never leave our number behind
    local want = (sec > 0) and sec or P._timedDefaultOrig
    if cur ~= want then
        local clockNow = os.clock()
        if P._writeRetryAt ~= nil and clockNow < P._writeRetryAt then return end
        P._writeRetryAt = clockNow + 2.0
        local ok = pcall(function() cdo.DefaultTimedChoiceDuration = want end)
        local now = ok and Try(function() return cdo.DefaultTimedChoiceDuration end) or nil
        log("timed default: %s -> %s ok=%s now=%s", tostring(cur), tostring(want),
            tostring(ok), tostring(now))
        if ok and now == want then S.timedAppliedSec = sec end
        return
    end
    S.timedAppliedSec = sec
    if S.timedDefaultLogged ~= want then
        S.timedDefaultLogged = want
        log("timed default: dur=%s (in place)", tostring(want))
    end
end


-- LOG-ONLY
P.readTimedRemaining = function()
    local dlg = S.seenDialogue
    if not Usable(dlg) then return nil end
    local cn = Try(function() return dlg.DisplayedChoice end)
    if not Usable(cn) then return nil end
    local r = Try(function() return cn:GetRemainingTimePercentage() end)
    if type(r) == "number" then return r end
    return nil
end

P.readSlotMap = function()
    local dlg = S.seenDialogue
    if not Usable(dlg) then return end
    local _, g = resolve(S.seenDialogue)
    if g == nil then
        log("slots: no group")
        return
    end
    local n = Try(function() return g:GetButtonCount() end)
    if type(n) ~= "number" or n <= 0 or n > 16 then
        log("slots: count unreadable")
        return
    end
    local cn = Try(function() return dlg.DisplayedChoice end)
    if not Usable(cn) then
        log("slots: node unreadable (n=%d)", n)
        return
    end
    local arr = Try(function() return cn.Choices end)
    local parts = {}
    for i = 0, n - 1 do
        local st = "?"
        if arr ~= nil then
            local ln = Try(function() return arr[i + 1] end)
            local gg = (ln ~= nil) and Try(function() return ln.Guid end) or nil
            if gg ~= nil then
                local av = Try(function() return cn:GetAvailability(gg) end)
                if av == 0 then st = "open"
                elseif av == 1 then st = "locked"
                elseif av == 2 then st = "hidden" end
                local used = Try(function() return cn:IsChoiceUsed(gg) end)
                if used == true then st = st .. "*" end
            end
        end
        parts[#parts + 1] = string.format("%d:%s", i, st)
    end
    log("slots: %s", table.concat(parts, " "))
end

P.readFirstUnlocked = function()
    local dlg = S.seenDialogue
    if not Usable(dlg) then return false end
    local cwU, gU = resolve(S.seenDialogue)
    if gU == nil then
        log("firstunlocked: no group")
        return false
    end
    local first = Try(function() return cwU.FirstUnlockedChoiceWidget end)
    if not Usable(first) then
        log("firstunlocked: field null/unreadable")
        return false
    end
    local fname = Try(function() return first:GetFullName() end)
    local fhow = "full"
    if type(fname) ~= "string" then
        fname = Try(function() return first:GetName() end)
        fhow = "name"
    end
    if type(fname) ~= "string" then
        log("firstunlocked: name unreadable")
        return false
    end
    local n = Try(function() return gU:GetButtonCount() end)
    if type(n) ~= "number" or n <= 0 or n > 16 then
        log("firstunlocked: count unreadable")
        return false
    end
    for i = 0, n - 1 do
        local b = Try(function() return gU:GetButtonBaseAtIndex(i) end)
        if Usable(b) then
            local bn = nil
            if fhow == "full" then
                bn = Try(function() return b:GetFullName() end)
            else
                bn = Try(function() return b:GetName() end)
            end
            if bn == fname then
                log("firstunlocked: index=%d (n=%d via %s)", i, n, fhow)
                return true
            end
        end
    end
    log("firstunlocked: no match (n=%d)", n)
    return false
end

P.activeNodeClass = function()
    local dlg = S.seenDialogue
    if not Usable(dlg) then return nil end
    local cs = Try(function() return dlg.CinematicSystem end)
    if not Usable(cs) then return nil end
    local ad = Try(function() return cs.ActiveDialogue end)
    if not Usable(ad) then return nil end
    local rn = Try(function() return ad:GetActiveResponseNode() end)
    if not Usable(rn) then return nil end
    local cls = Try(function() return rn:GetClass():GetFName():ToString() end)
    if type(cls) ~= "string" or cls == "" then return nil end
    local short = cls:gsub("CinematicNode_", ""):gsub("FlowNode_", ""):gsub("DialogueNode_", "")
    if short == "" then short = cls end
    return short
end

return P
