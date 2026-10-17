local conf = require("conf")
local S = require("state")
local U = require("util")
local log = conf.log
local settings = conf.settings
local Try, Usable, resolve = U.Try, U.Usable, U.resolve

local E = {}

E.native = nil  -- dialogs_mode_0/1/2 + prime/down arrows, or nil

--- Load dialogs++.dll from mod folder and resolve its cdecl entry points.
--- Lua C ABI: one ignored pointer argument, int return; calls need no arguments.
E.loadNative = function()
    local root = U.modFolder()
    if root == nil then
        log("cannot locate the mod folder, wheel disabled")
        return
    end

    local dll = root .. "\\bin\\dialogs++.dll"
    if type(package) ~= "table" or type(package.loadlib) ~= "function" then
        log("package.loadlib missing, wheel disabled")
        return
    end
    local function load(name)
        local ok, fn = pcall(package.loadlib, dll, name)
        if ok and type(fn) == "function" then return fn end
        log("export %s not found (%s), wheel disabled", name, dll)
        return nil
    end
    local m0, m1, m2 = load("dialogs_mode_0"), load("dialogs_mode_1"), load("dialogs_mode_2")
    if m0 ~= nil and m1 ~= nil and m2 ~= nil then
        E.native = { [0] = m0, [1] = m1, [2] = m2 }
        local mP = load("dialogs_prime_arrow")
        if mP ~= nil then
            E.native.prime = mP
        else
            log("export dialogs_prime_arrow not found, arrow prime off")
        end
        -- Keyboard navigation (W/S)
        local mD = load("dialogs_arrow_down")
        if mD ~= nil then
            E.native.down = mD
        else
            log("export dialogs_arrow_down not found, S key off")
        end
        log("native bridge ready (%s)", dll)
    end
end

--- Send dialogue state directly to the DLL. Log pcall
E.notify = function(mode, label)
    if mode == S.lastMode then return end
    S.lastMode = mode
    -- WheelScroll off keeps DLL in dialogue mode
    local dllMode = mode
    local suffix = ""
    if mode == S.MODE_OPTIONS and not settings.WheelScroll then
        dllMode = S.MODE_DIALOGUE
        suffix = " (wheel off)"
    end
    if E.native ~= nil then
        local ok, err = pcall(E.native[dllMode])
        log("dll mode -> %d (%s) native_call=%s%s %s", mode, label, tostring(ok),
            suffix, ok and "" or tostring(err))
    else
        log("dll mode -> %d (%s) NATIVE MISSING", mode, label)
    end
end

-- Input enablement off the SkipLines picker: 1 = Lclick, 2 = Space.
E.lmbOn = function()
    return settings.SkipLines == 1 or settings.SkipLines == 3
end
E.spaceOn = function()
    return settings.SkipLines == 2 or settings.SkipLines == 3
end

E.skipOne = function(dlg)
    -- Use the game's skip entry to preserve its permission checks. Avoid the deeper route.
    -- 1 press Space blocks the native double press upstream.
    if Usable(dlg) and pcall(function() dlg:HandleSkipActionNative() end) then
        return "skipped-action"
    end
    return "action-failed"
end

E.confirmHovered = function(tag)
    local _, g = resolve(S.seenDialogue)
    local h = (g ~= nil) and Try(function() return g:GetHoveredButtonIndex() end) or nil
    if h == nil or h < 0 then return string.format("%s: no-hover", tag) end
    local b = Try(function() return g:GetButtonBaseAtIndex(h) end)
    if not Usable(b) then return string.format("%s: button-unreadable", tag) end
    -- No availability check: arrow navigation follows the game's valid options,
    -- but GetAvailability can reject legal picks. Quiet/delay/stable-hover gates handle spam, invalid targets, and races.
    local ok, err = pcall(function() g:OnHandleButtonBaseClicked(b) end)
    if ok then return string.format("%s: confirmed hover=%d", tag, h) end
    return string.format("%s: confirm-failed %s", tag, tostring(err))
end

--- Two-press skip: first press reveals the hidden prompt without skipping.
--- Returns true if consumed at most one fresh-resolved game thread call.
E.twoPress = function(tag)
    if not settings.TwoPress then return false end
    if S.promptVisible == true then return false end
    local dlg = S.seenDialogue
    if not Usable(dlg) then return false end
    local btn = Try(function() return dlg.SkipButtonWidget end)
    if not Usable(btn) then return false end
    -- restore the prompt's natural shown state (vis=4 on live dialogues).
    local ok, err = pcall(function() btn:SetVisibility(4) end)
    log("%s shows prompt ok=%s %s", tag, tostring(ok), ok and "" or tostring(err))
    if ok then S.promptVisible = true end
    return true
end

--- Shared click/Space skip tail: gates, one native call, and in-flight tracking.
--- Returns a log-ready string; caller adds the press tag. Tick owns lineSig; no engine reads beyond skipOne
E.doSkip = function(tag)
    -- Block skips after dialogue ends while delayed end detection catches up
    if S.dialogueOver or S.endStrikes > 0 then
        return string.format("%s swallowed (dialogue over)", tag)
    end
    -- Swallow presses when ESC or the menu flag indicates an overlay.
    -- Clear the ESC heuristic; the menu flag clears on visibility.
    if S.escPauseArmed or S.menuOpen then
        S.escPauseArmed = false
        return string.format("%s swallowed (pause?)", tag)
    end
    -- Block all entry points during frozen transitions; never touch a rebuilding graph.
    if S.graphFrozen then
        return string.format("%s swallowed (frozen)", tag)
    end
    -- Widget exists before readiness; fade/streaming tasks run first.
    -- Synthetic skips wait for the first line; native input remains vanilla.
    if not S.started then
        return string.format("%s swallowed (not started)", tag)
    end
    if S.skipFlight ~= nil then
        return string.format("%s swallowed (in flight)", tag)
    end
    local dlg = S.seenDialogue
    local how = "no-dialogue"
    if Usable(dlg) then
        how = E.skipOne(dlg)
        if how == "skipped-action" then
            -- copy the tick's running signature; never read the engine here
            -- because engine calls in click context crashed the game.
            local now = os.clock()
            local base = nil
            if S.lineSig ~= nil and (now - (S.lineSigT or 0)) <= 0.5 then base = S.lineSig end
            S.skipFlight = { t = now, sig = base }
            if base == nil then
                log("flight blind (short gate)")
            end
        end
    end
    return string.format("%s -> %s", tag, tostring(how))
end

--- Shared click/E/F confirm tail; returns a log-ready string using the caller's
--- press tag, confirm tag, timestamp, and pre-update quiet span.
E.doConfirm = function(tag, ctag, now, sincePrevMs)
    -- pause: same as skips, a menu over the list means hands off.
    if S.escPauseArmed or S.menuOpen then
        S.escPauseArmed = false
        return string.format("%s swallowed (pause)", tag)
    end
    -- Block all inputs during frozen transitions; never access a rebuilding graph.
    if S.graphFrozen then
        return string.format("%s swallowed (frozen)", tag)
    end
    -- Fail closed until tick processes the list; confirming early risks racing widget construction.
    if S.lastMode ~= S.MODE_OPTIONS then
        return string.format("%s swallowed (list unseen)", tag)
    end
    -- Anti-spam: block input until clicks stop. Confirm requires real quiet
    -- with no timeout to prevent rhythm-based choices. Only hover recovery
    -- has a timeout (tick); timed lists rely on the game's own timer.
    if sincePrevMs < S.QUIET_MS then
        return string.format("%s swallowed (spam-quiet %dms<%dms)", tag,
            math.floor(sincePrevMs), S.QUIET_MS)
    end
    -- Timed choices bypass spam-quiet; the game selects on its own timer.
    -- Otherwise require real quiet before confirming; physical presses still reach the game.
    if S.timedChoice == true then
        if U.stableHover() == nil then
            return string.format("%s swallowed (hover unseen/unstable)", tag)
        end
        return string.format("%s -> %s", tag, E.confirmHovered(ctag))
    end
    if U.stableHover() == nil then
        return string.format("%s swallowed (hover unseen/unstable)", tag)
    end
    return string.format("%s -> %s", tag, E.confirmHovered(ctag))
end

return E
