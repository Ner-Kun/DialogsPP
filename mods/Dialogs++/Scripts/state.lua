local conf = require("conf")
local log = conf.log
local S = {}

S.DIALOGUE_PATH = "/Game/_Dawnwalker/UI/_Unified/Dialogues/WBP_Dialogue.WBP_Dialogue_C"
S.TICK_MS = 250
S.IDLE_EVERY_NTH = 8  -- full check every 2s while no dialogue is open
S.MODE_NONE = 0 -- 0 = none
S.MODE_DIALOGUE = 1 -- 1 = dialogue open
S.MODE_OPTIONS = 2 -- 2 = options on screen
S.HIDDEN_VIS = { [1] = true, [2] = true, [3] = true }
S.dlgPath = nil
S.seenDialogue = nil
S.lastFireClock = 0
S.lastMode = nil
S.curState = "BOOT"
S.setState = function(s, why)
    if s ~= S.curState then
        log("state: %s -> %s (%s)", S.curState, s, why or "?")
        S.curState = s
    end
end
S.lastHover = nil
S.clickCount = 0
S.state2Clock = nil
S.waitTick = 0
S.dlgClock = nil
S.skipFlight = nil
S.FLIGHT_TIMEOUT = 1.0
S.FLIGHT_BLIND_TIMEOUT = 0.3
S.QUIET_MS = 300
S.SPAM_CEIL_MS = 3000
S.FLIGHT_HOLD = 5.0
S.lineSig = nil
S.lineSigT = 0
S.lineGuid = nil
S.started = false
S.primeArrowDone = nil
S.quietTickLogged = false
S.REFOCUS_MISSES = 5
S.refocusFails = 0
S.refocusGaveUp = false
S.focusProbeDone = false
S.arrowClock = nil
S.lastRefocus = nil
S.lastFocusSig = nil
S.lastActiveSig = nil
S.lastActiveFlagSig = nil
S.menuOpen = false
S.pauseWidget = nil
S.pauseResolved = nil
S.pauseResolveTries = nil
S.pauseResolveParked = nil
S.choiceHookAt = nil
S.pausePollInit = nil
S.pauseOpenedAt = nil
S.stuckStartWarned = nil
S.lastResolveSig = nil
S.escPauseArmed = false
S.timedChoice = nil
S.timedWatchT0 = nil
S.timedAppliedSec = nil
S.timedDefaultLogged = nil
S.uiMgr = nil
S.uiDum = nil
S.firstUnlocked = nil
S.slotMapDone = nil
S.promptVisible = nil
S.graphFrozen = false
S.freezeAt = nil
S.FREEZE_CEIL = 3
S.lastNodeClass = nil
S.endStrikes = 0
S.END_STRIKES_NEEDED = 3
S.dialogueOver = false
S.skipBtnDone = nil
S.lastSkipBtnSig = nil
S.skipBtnBlocked = nil
S.skipPromptHidden = nil
S.tickCount = 0
S.spaceCount = 0
S.lastSpaceClock = 0
S.lastKeyClock = 0


S.resetDialogue = function()
    S.lastMode = nil
    S.dlgClock = os.clock()
    S.dlgPath = nil
    S.waitTick = 0
    S.dialogueOver = false
    S.endStrikes = 0
    S.started = false
    S.lastActiveSig = nil
    S.lastActiveFlagSig = nil
    S.pausePollInit = nil
    S.pauseOpenedAt = nil
    S.stuckStartWarned = nil
    S.escPauseArmed = false
    S.primeArrowDone = nil
    S.quietTickLogged = false
    S.arrowClock = nil
    S.skipFlight = nil
    S.lineSig = nil
    S.pauseResolveTries = nil
    S.pauseResolveParked = nil
    S.menuOpen = false
    S.choiceHookAt = nil
    S.timedChoice = nil
    S.timedWatchT0 = nil
    S.firstUnlocked = nil
    S.slotMapDone = nil
    S.promptVisible = nil
    S.graphFrozen = false
    S.freezeAt = nil
    S.lastNodeClass = nil
    S.lastFocusSig = nil
    S.skipBtnDone = nil
    S.lastSkipBtnSig = nil
    S.skipBtnBlocked = nil
    S.skipPromptHidden = nil
end

return S
