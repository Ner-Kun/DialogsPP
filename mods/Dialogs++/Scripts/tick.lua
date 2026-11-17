local conf = require("conf")
local S = require("state")
local U = require("util")
local P = require("probes")
local E = require("engine")
local log = conf.log
local settings = conf.settings
local Try, Usable = U.Try, U.Usable
local resolve, optionsShown, dialogueGone, flightSig = U.resolve, U.optionsShown, U.dialogueGone, U.flightSig
local configReadError = false

-- Timed choice progress for the log: seconds left out of the total when the
-- node exposes it, percent otherwise.
local function timerLeft(rem, dur)
    if type(dur) == "number" and dur > 0 then
        return string.format("%.1fs/%.0fs", rem * dur, dur)
    end
    return string.format("%.0f%%", rem * 100)
end

-- A failed config read must not escape the tick: it would disable the mod until
-- the game restarts.
local function tick()
    S.tickCount = S.tickCount + 1
    local tickCount = S.tickCount
    local now = os.clock()
    if (tickCount % 8) == 1 then
        local ok, err = pcall(conf.readConfig)
        if ok then
            configReadError = false
        elseif not configReadError then
            configReadError = true
            conf.warn("config: read failed (%s)", tostring(err))
        end
    end
    -- Timed choice length rides the settings CDO; apply on boot and on every
    -- live config change. The compare is pure Lua, the write one property op.
    if S.timedAppliedSec ~= settings.TimerExtendSec then
        P.applyTimedDefault()
        P.syncTimed()
    end
    if S.graphFrozen and S.freezeAt ~= nil and (now - S.freezeAt) > S.FREEZE_CEIL then
        S.graphFrozen = false
        S.freezeAt = nil
        log("graph: thawed (ceiling)")
    end
    
    if not S.dialogueOver and not Usable(S.seenDialogue) and (tickCount % S.IDLE_EVERY_NTH) ~= 1 then
        return
    end
    -- Over-watch: drop the anchor at dialogue end and reacquire the reused widget
    -- from the game's own manager pointer. The manager re-points when the next
    -- dialogue starts; new widgets still arrive through NotifyOnNewObject.
    if S.dialogueOver then
        local found, src = P.reacquireDialogue()
        if found ~= nil then
            S.seenDialogue = found
            S.resetDialogue()
            S.dlgPath = Try(function() return found:GetFullName() end)
                log("dialogue: reopen (%s)", src or "?")
            S.setState("APPEARED", "reopened")
            return
        end
        S.setState("OVER", "over-watch")
        return
    end
    if not Usable(S.seenDialogue) then
        if S.seenDialogue ~= nil then S.seenDialogue = nil end
        S.dlgPath = nil
        S.graphFrozen = false
        S.freezeAt = nil
        -- Log dialogue end duration separately; the state line scrolls away.
        if S.lastMode == S.MODE_DIALOGUE or S.lastMode == S.MODE_OPTIONS then
                log("dialogue: end %.1fs (widget-gone)", os.clock() - (S.dlgClock or os.clock()))
        end
        E.notify(S.MODE_NONE, "no dialogue")
        S.setState("IDLE", "widget-gone")
        return
    end
    -- ActiveDialogue idle ~750ms = over, even if widget lingers; grace covers handovers.
    -- Drop anchor on confirmation. While frozen, skip checks and preserve strikes.
    if not S.graphFrozen and dialogueGone() then
        S.endStrikes = S.endStrikes + 1
        S.skipFlight = nil
        S.lineSig = nil
        S.skipBtnDone = nil
        S.skipPromptHidden = nil
        if S.endStrikes >= S.END_STRIKES_NEEDED then
            S.endStrikes = 0
            S.dialogueOver = true
            S.graphFrozen = false
            S.freezeAt = nil
            log("dialogue: quiet (over)")
            if S.lastMode == S.MODE_DIALOGUE or S.lastMode == S.MODE_OPTIONS then
                log("dialogue: end %.1fs (active-gone)", os.clock() - (S.dlgClock or os.clock()))
            end
            E.notify(S.MODE_NONE, "no dialogue")
            S.setState("OVER", "active-gone")
            -- Drop the anchor; further polls would touch a dead object.
            -- Reacquire fresh for chained dialogues via NewObject or the over branch.
            S.seenDialogue = nil
            S.dlgPath = nil
        end
        return
    end
    if not S.graphFrozen then S.endStrikes = 0 end

    -- Widget deactivation signals teardown or handover and a graph rebuild; freeze until it reactivates.
    local actSig = nil
    do
        local dlgA = S.seenDialogue
        if Usable(dlgA) then
            local a = Try(function() return dlgA:IsActivated() end)
            if a ~= nil then actSig = tostring(a) end
        end
    end
    -- Freeze on deactivation; validate once at the danger point.
    if actSig == "false" then
        if not S.dialogueOver and not S.graphFrozen then
            S.graphFrozen = true
            S.freezeAt = now
            log("graph: frozen (widget inactive)")
            U.refreshAnchor()
        end
    elseif actSig == "true" then
        if S.graphFrozen then
            S.graphFrozen = false
            S.freezeAt = nil
            log("graph: thawed")
        end
    end
    -- Hard freeze: only the pause poll runs. Child widgets may be dead; all dialogue side work waits for thaw.
    if S.graphFrozen then
        if S.pausePollInit == nil or (tickCount % 4) == 1 then P.readPauseMenu() end
        return
    end
    -- Skip-button state is read-only: check immediately, then at 1 Hz. Fast skips can end a dialogue in about a second; the widget is per conversation.
    if S.skipBtnDone == nil or (tickCount % 4) == 1 then P.readSkipButton() end
    -- UI link first: it feeds the native menu gate that readPauseMenu reads.
    if S.uiMgr == nil or (tickCount % 4) == 1 then P.readUiManager() end
    -- Poll the pause menu immediately, then at 1 Hz; menu state changes slowly.
    if S.pausePollInit == nil or (tickCount % 4) == 1 then P.readPauseMenu() end

    local pausedTick = S.escPauseArmed or S.menuOpen
    -- Prompt hide: collapse the prompt widget, nothing else. SetBlocked is not
    -- used because it runs game-side code that dereferences a null
    -- InputActionWidget before the prompt is armed. Collapsing only changes
    -- Slate visibility, and the prompt never writes its own visibility back
    -- (vis stays 4 on live dialogues), so one write per dialogue holds.
    if not pausedTick and S.started and settings.HidePrompt
        and not settings.TwoPress and S.skipPromptHidden == nil then
        local dlgH = S.seenDialogue
        if Usable(dlgH) then
            local btnH = Try(function() return dlgH.SkipButtonWidget end)
            if Usable(btnH) then
                local before = Try(function() return btnH:GetVisibility() end)
                local okH, errH = pcall(function() btnH:SetVisibility(1) end)
                local after = Try(function() return btnH:GetVisibility() end)
                log("prompt hide: %s -> %s ok=%s %s", tostring(before),
                    tostring(after), tostring(okH),
                    okH and "" or tostring(errH))
                if okH then S.skipPromptHidden = true end
            end
        end
    end
    local shown, n, vis = optionsShown()

    if S.graphFrozen and shown then
        S.graphFrozen = false
        S.freezeAt = nil
        log("graph: thawed (list)")
    end
    if shown then
        if S.lastMode ~= S.MODE_OPTIONS then
            S.state2Clock = os.clock()
            S.primeArrowDone = false
            S.quietTickLogged = false
            S.timedChoice = nil
            S.timedWatchT0 = nil
            S.firstUnlocked = nil
            S.slotMapDone = nil
            S.refocusFails = 0
            S.refocusGaveUp = false
            S.focusProbeDone = false
            log("choice: list n=%d vis=%s", n, tostring(vis))
            if S.pendingSpace ~= nil then
                S.pendingSpace = nil
                log("skip: deferred blocked (list)")
            end
            if S.skipFlight ~= nil then
                S.skipFlight = nil
                S.lineSig = nil
                log("flight answered (choice)")
            end
        end
        E.notify(S.MODE_OPTIONS, string.format("%d reply options visible (vis=%s)", n, tostring(vis)))

        if S.menuOpen then
            S.setState("PAUSED", "menu-over-list")
        elseif S.timedChoice == true then
            S.setState("OPTIONS-TIMED", "list")
        else
            S.setState("OPTIONS", "list")
        end
        -- Track hover source: arrow, wheel/mouse, or game (otherwise).
        local cw, g = resolve(S.seenDialogue)
        local h = (g ~= nil) and Try(function() return g:GetHoveredButtonIndex() end) or nil
        if h ~= S.lastHover then
            -- Infer source: wheel keys aren't exposed in this build.
        -- New list (-1/nil -> N): arrow if our UP moved hover, else game.
        -- Mid-list move: likely wheel/mouse input; game may re-hover after changes.
        -- Reset to -1: game clears hover after selection/rebuild.
            local now2 = os.clock()
            local src = "game"
            local appearing = (S.state2Clock ~= nil) and ((now2 - S.state2Clock) < 1.5)
            if appearing and (S.lastHover == nil or S.lastHover == -1) and h ~= -1 then
                if S.arrowClock ~= nil and (now2 - S.arrowClock) < 1.5 then
                    src = "arrow"
                end
            elseif h ~= -1 then
                src = "wheel/mouse"
            end
            log("choice: hover %s -> %s (%s)", tostring(S.lastHover), tostring(h), src)
            S.lastHover = h
            S.refocusFails = 0
            S.refocusGaveUp = false
        end
        -- Focus state gates the hover priming and the recovery request below.
        local descFocused = nil
        if g ~= nil and cw ~= nil then
            local d = Try(function() return cw:HasFocusedDescendants() end)
            if d ~= nil then descFocused = (d == true) end
        end

        -- Anti-spam: leave the list untouched while clicks continue.
        -- After SPAM_CEIL_MS, resume arrow recovery to prevent permanent lockup.
        local quietMs = (now - (S.lastFireClock or (now - 10))) * 1000
        local spamHeld = quietMs < S.QUIET_MS
            and (now - (S.state2Clock or now)) * 1000 <= S.SPAM_CEIL_MS
        -- Prime hover with one DLL UP after focus; creates hover from -1 and
        -- repaints index 0 via Slate. Focus alone never sets the highlight.
        if not pausedTick and (settings.WheelScroll or settings.KbNav) and S.primeArrowDone == false
            and E.native ~= nil and E.native.prime ~= nil
            and h ~= nil and (h == -1 or h >= 0) and descFocused then
            if spamHeld then
                if not S.quietTickLogged then
                    S.quietTickLogged = true
                    log("choice: prime held (spam-quiet %dms<%dms)",
                        math.floor(quietMs), S.QUIET_MS)
                end
            else
                S.primeArrowDone = true
                S.arrowClock = os.clock()
                local okP, errP = pcall(E.native.prime)
                log("choice: prime (hover=%s) ok=%s %s", tostring(h),
                    tostring(okP), okP and "" or tostring(errP))
            end
        end
        -- Clicks steal Slate focus, breaking wheel/arrows; re-hover restores it. The kbd column confirms recovery.
        if not pausedTick and h ~= nil and h >= 0 and g ~= nil then
            local fd = nil
            if cw ~= nil then
                fd = Try(function() return cw:HasFocusedDescendants() end)
            end

            if fd ~= false then
                S.refocusFails = 0
                S.refocusGaveUp = false
            elseif not S.refocusGaveUp and (now - (S.lastRefocus or -10)) >= 1.0 then
                S.lastRefocus = now
                local bR = Try(function() return g:GetButtonBaseAtIndex(h) end)
                if Usable(bR) then
                    local okR, errR = pcall(function() g:OnButtonBaseHovered(bR) end)
                    log("choice: refocus (hover=%d) ok=%s %s", h, tostring(okR),
                        okR and "" or tostring(errR))
                    if okR then
                        S.refocusFails = S.refocusFails + 1
                        if S.refocusFails >= S.REFOCUS_MISSES then
                            S.refocusGaveUp = true
                            conf.warn("choice: refocus gave up (%d misses)", S.refocusFails)
                        end
                    end
                end
            end
        end

        -- After 1.5s without focus, request recovery once per list via RequestRefreshFocus.
        -- No hover needed; arrow primes it once focus returns. Works for wheel and keyboard.
        if not pausedTick and (settings.WheelScroll or settings.KbNav) and not S.focusProbeDone
            and descFocused == false
            and not spamHeld and S.state2Clock ~= nil
            and (now - S.state2Clock) > 1.5 then
            S.focusProbeDone = true
            local dlgP = S.seenDialogue
            local okW, errW = false, "no-dialogue"
            if Usable(dlgP) then
                okW, errW = pcall(function() dlgP:RequestRefreshFocus() end)
            end
            log("choice: focus refresh ok=%s %s", tostring(okW),
                okW and "" or tostring(errW))
        end
        -- Detect visible timers once per list; bypass confirm delay since the game auto-picks.
        -- Engine remaining time (0..1) drives the countdown heartbeat.
        if S.timedChoice == nil and not S.graphFrozen then
            S.timedChoice = P.readTimedChoice()
            if S.timedChoice then
                S.timedWatchT0 = now
                local info = P.timedInfo() or {}
                local total = info.total
                local node = type(info.node) == "string" and info.node:sub(1, 40) or "?"
                local dlgShort = type(S.dlgPath) == "string" and S.dlgPath:match("([^%.]+)$") or "?"
                log("timer: start dlg=%s node=%s total=%ss wanted=%ss override=%s authored=%ss",
                    dlgShort, node, tostring(total), tostring(settings.TimerExtendSec),
                    tostring(info.override), tostring(info.authored))
                if settings.TimerExtendSec > 0 and type(total) == "number"
                    and math.abs(total - settings.TimerExtendSec) > 0.5 then
                    log("timer: NOT extended (total=%ss, wanted=%ss)",
                        tostring(total), tostring(settings.TimerExtendSec))
                end
            end
        end
        -- Heartbeat once per second while a timed choice runs: shows the game's
        -- own countdown, which is what the extension setting changes.
        if S.timedChoice == true and not pausedTick and (tickCount % 4) == 1 then
            local remLive, durLive = P.readTimedRemaining()
            if remLive ~= nil then
                local elap = (S.timedWatchT0 ~= nil) and (now - S.timedWatchT0) or -1
                log("timer: remain=%s (T+%.0fs)", timerLeft(remLive, durLive), elap)
            end
        end

        if S.firstUnlocked == nil and not S.graphFrozen then
            S.firstUnlocked = P.readFirstUnlocked()
        end
        if S.slotMapDone == nil and not S.graphFrozen then
            S.slotMapDone = true
            P.readSlotMap()
        end
    else
        S.primeArrowDone = nil
        S.quietTickLogged = false
        S.arrowClock = nil
        S.timedChoice = nil
        S.timedWatchT0 = nil
        S.firstUnlocked = nil
        S.slotMapDone = nil
        if S.lastHover ~= nil then S.lastHover = nil end
        -- Focus-back detects menu closure (ESC/Continue); uses the shared transition and clock freeze
        if S.menuOpen then
            local dlgF = S.seenDialogue
            if Usable(dlgF) then
                local fd = Try(function() return dlgF:HasFocusedDescendants() end)
                if fd == true then
                    S.menuOpen = false
                    P.noteMenuClosed("closed (focus-back)")
                end
            end
        end
        -- Click handler reuses the cached signature; no engine reads.
        -- Freeze it during graph rebuilds: stale data only delays timeout,
        -- while fresh reads may touch a partially built node.
        if not S.graphFrozen then
            S.lineSig, S.lineGuid = flightSig()
            S.lineSigT = now
        end

        if not S.started and S.lineGuid ~= nil and S.lineGuid ~= "no-response" then
            S.started = true
            log("dialogue: start")
        end
        -- Line change confirms progress. Timeout alone never releases the skip gate: a skip into silence can crash the game.
        if S.skipFlight ~= nil then
            if S.skipFlight.sig == nil and S.lineSig ~= nil and S.lineSig ~= "no-response" then
                S.skipFlight.sig = S.lineSig
                log("flight adopted (was blind)")
            end
            if S.lineSig ~= nil and S.lineSig ~= "no-response"
                and S.skipFlight.sig ~= nil and S.lineSig ~= S.skipFlight.sig then
                S.skipFlight = nil
            elseif (now - S.skipFlight.t) > S.FLIGHT_HOLD then
                log("flight: hold expired")
                S.skipFlight = nil
            elseif S.skipFlight.sig == nil then
                if (now - S.skipFlight.t) > S.FLIGHT_BLIND_TIMEOUT and not S.skipFlight.held then
                    S.skipFlight.held = true
                    log("flight: blind timeout, holding")
                end
            elseif (now - S.skipFlight.t) > S.FLIGHT_TIMEOUT and not S.skipFlight.held then
                S.skipFlight.held = true
                log("flight: timeout, holding")
            end
        end
        E.notify(S.MODE_DIALOGUE, "dialogue open")
        -- Shadow-only state; gates unchanged. PAUSED overrides all while the menu is open.
        -- LINES tracks the active node class for tracing terminal chains.
        if S.menuOpen then
            S.setState("PAUSED", "menu-over-lines")
        elseif not S.started then
            S.setState("APPEARED", "waiting-first-line")
            if not S.stuckStartWarned and (now - (S.dlgClock or now)) > 30 then
                S.stuckStartWarned = true
                conf.warn("dialogue: no first line after %.0fs", now - (S.dlgClock or now))
            end
        else
            if not S.graphFrozen then
                S.lastNodeClass = P.activeNodeClass()
            end
            local ncls = S.lastNodeClass
            S.setState((ncls ~= nil) and ("LINES(" .. ncls .. ")") or "LINES", "lines")
        end
    end
end

return tick
