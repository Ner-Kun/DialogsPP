do
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    local dir = src:match("^(.*)[/\\][^/\\]*$")
    if dir ~= nil and type(package) == "table" then
        package.path = (package.path or "") .. ";" .. dir .. "/?.lua"
    end
end

local conf = require("conf")
local S = require("state")
local U = require("util")
local Sch = require("sched")
local Try = U.Try
local P = require("probes")
local E = require("engine")
local tick = require("tick")
local H = require("hooks")
require("input")

E.loadNative()
P.watchChoiceNodes()

pcall(function()
    NotifyOnNewObject(S.DIALOGUE_PATH, function(obj)
        S.seenDialogue = obj
        S.tickCount = 0
        S.resetDialogue()
        S.dlgPath = Try(function() return obj:GetFullName() end)
        U.rememberDialogue(obj)
        H.ensure()
        local short = type(S.dlgPath) == "string" and S.dlgPath:match("([^%.]+)$") or "?"
        conf.log("dialogue: appear %s", short)
        S.setState("APPEARED", "new-object")
    end)
end)

-- Everything runs on the game thread: one loop drains the timer queue and
-- starts the tick when it is due. LoopAsync/ExecuteInGameThread would put Lua
-- on a UE4SS worker thread too, and two threads on one Lua state corrupt the
-- registry ("Ref was not function", UE4SS issue #1180).
local tickAt = 0
local function frame()
    Sch.drain()
    local now = os.clock()
    if now >= tickAt then
        tickAt = now + S.TICK_MS / 1000
        local ok, err = pcall(tick)
        if not ok then conf.err("tick: %s", tostring(err)) end
    end
end
if type(LoopInGameThreadWithDelay) == "function" then
    LoopInGameThreadWithDelay(25, frame)
else
    LoopAsync(25, function()
        ExecuteInGameThread(frame)
        return false
    end)
end

local schedMode = (type(LoopInGameThreadWithDelay) == "function") and "game" or "worker"
local keyNames = { [0] = "E", [1] = "F", [2] = "E/F" }
conf.always("loaded %s | scheduler=%s | dll=%s | skip=%d two=%s hide=%s wheel=%s kb=%s key=%s timer=%ds log=%s",
    conf.VERSION, schedMode, E.native and "ok" or "missing",
    conf.settings.SkipLines, tostring(conf.settings.TwoPress),
    tostring(conf.settings.HidePrompt), tostring(conf.settings.WheelScroll),
    tostring(conf.settings.KbNav),
    keyNames[conf.settings.ConfirmKey or 0] or "?",
    conf.settings.TimerExtendSec, tostring(conf.settings.Log))
S.setState("IDLE", "ready")
