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

--- CENSUS PREWRITE: enumerate future timed Choice nodes; graph walks read dangling children on newer UE4SS builds.
--- Match FullName paths only (ignore class prefix); filters templates, keeping live instances.
P.censusPrewrite = function()
    local sec = conf.settings.TimerExtendSec
    if type(sec) ~= "number" or sec <= 0 then return end
    if S.censusFired then return end
    if type(FindAllOf) ~= "function" then return end
    local dlg = S.seenDialogue
    if not Usable(dlg) then return end
    local cs = Try(function() return dlg.CinematicSystem end)
    if not Usable(cs) then return end
    local ad = Try(function() return cs.ActiveDialogue end)
    if not Usable(ad) then return end
    local adpath = Try(function() return ad:GetFullName() end)
    if type(adpath) ~= "string" or adpath == "" then return end

    local adid = adpath:match("^%S+%s+(.+)$") or adpath
    local ok, res = pcall(FindAllOf, "CinematicNode_Choice")
    if not ok or res == nil then return end
    local wrote = false
    pcall(function()
        for _, o in pairs(res) do
            if Usable(o) then
                local fn = Try(function() return o:GetFullName() end)
                if type(fn) == "string" then
                    local fnpath = fn:match("^%S+%s+(.+)$") or fn
                    if fnpath:sub(1, #adid) == adid
                    and not S.prewriteKeys[fn] then
                        local td = Try(function() return o.TimedChoiceData end)
                        if td ~= nil and Try(function() return td.bIsTimedChoice end) == true then
                            S.prewriteKeys[fn] = true
                            local oldOver = Try(function() return td.bOverrideDefaultDuration end)
                            local oldDovr = Try(function() return td.DurationOverride end)
                            local okO = pcall(function() td.bOverrideDefaultDuration = true end)
                            local okD = pcall(function() td.DurationOverride = sec end)
                            if okO and okD then wrote = true end
                            log("timed prewrite: ok=%s over=%s->true dovr=%s->%s (census)",
                                tostring(okO and okD), tostring(oldOver),
                                tostring(oldDovr), tostring(sec))
                        end
                    end
                end
            end
        end
    end)
    res = nil
    if wrote then S.censusFired = true end
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

P.readTimedDefault = function()
    if P._cineSettingsClass == nil and type(FindObject) == "function" then
        P._cineSettingsClass = Try(function()
            return FindObject("/Script/DialogueSystem.CinematicSettings")
        end)
    end
    if P._cineSettingsClass == nil then return nil end
    local cdo = Try(function() return P._cineSettingsClass:GetDefaultObject() end)
    if cdo == nil then return nil end
    local v = Try(function() return cdo.DefaultTimedChoiceDuration end)
    if type(v) == "number" then return v end
    return nil
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

P.PEEK_DEPTH = 5

P.peekAhead = function()
    local dlg = S.seenDialogue
    if not Usable(dlg) then return "more" end
    local cs = Try(function() return dlg.CinematicSystem end)
    if not Usable(cs) then return "more" end
    local ad = Try(function() return cs.ActiveDialogue end)
    if not Usable(ad) then return "more" end
    local rn = Try(function() return ad:GetActiveResponseNode() end)
    if not Usable(rn) then return "more" end
    local seen = {}
    local trail = {}
    local recipe = nil
    local recipeTimed = nil
    local function readRecipe(nd)
        local td = Try(function() return nd.TimedChoiceData end)
        local timed, over, dovr = nil, nil, nil
        if td ~= nil then
            timed = Try(function() return td.bIsTimedChoice end)
            over = Try(function() return td.bOverrideDefaultDuration end)
            dovr = Try(function() return td.DurationOverride end)
        end
        recipeTimed = (timed == true)
        local ndur = Try(function() return nd.TimedChoiceDuration end)
        recipe = string.format("timed=%s override=%s dovr=%s nodedur=%s",
            tostring(timed), tostring(over), tostring(dovr), tostring(ndur))
    end
    local function trailAdd(cls, note)
        if #trail < 16 then
            trail[#trail + 1] = tostring(cls) .. (note or "")
        end
    end
    local function visit(nd, depth)
        if not Usable(nd) then trailAdd("?", "?dead"); return "more" end
        if depth > P.PEEK_DEPTH then trailAdd("?", "?deep"); return "more" end
        local key = Try(function() return nd:GetFullName() end) or ""
        if key ~= "" then
            if seen[key] then trailAdd("?", "?loop"); return "more" end
            seen[key] = true
        end
        local cls = Try(function() return nd:GetClass():GetFName():ToString() end)
        cls = (type(cls) == "string") and cls or ""
        local short = cls:gsub("CinematicNode_", ""):gsub("FlowNode_", "")
        if short == "" then short = "?" end
        if cls:find("Choice", 1, true) then
            trailAdd(short, "!")
            if recipe == nil then readRecipe(nd) end
            return "choice"
        end
        local outs = Try(function()
            local t = {}
            for _, v in pairs(nd:GetConnectedNodes()) do
                if type(v) == "userdata" then t[#t + 1] = v end
            end
            return t
        end)
        if type(outs) ~= "table" then trailAdd(short, "?outs"); return "more" end
        if #outs == 0 then trailAdd(short, "."); return "end" end
        trailAdd(short, string.format("(%d)", #outs))
        local anyMore = false
        for _, o in ipairs(outs) do
            local r = visit(o, depth + 1)
            if r == "choice" then return "choice" end
            if r == "more" then anyMore = true end
        end
        if anyMore then return "more" end
        return "end"
    end
    local ok, res = pcall(visit, rn, 0)
    if not ok then
        log("peek: !error => more")
        return "more"
    end
    if res ~= "choice" and res ~= "end" then res = "more" end
    if res == "end" then return res, table.concat(trail, ">"), recipe, recipeTimed end
    if res == "choice" then return res, nil, recipe, recipeTimed end
    return res
end

return P
