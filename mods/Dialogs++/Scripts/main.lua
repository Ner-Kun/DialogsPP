do
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    local dir = src:match("^(.*)[/\\][^/\\]*$")
    if dir ~= nil and type(package) == "table" then
        package.path = (package.path or "") .. ";" .. dir .. "/?.lua"
    end
end

local conf = require("conf")
local S = require("state")
local Try = require("util").Try
require("probes")
local E = require("engine")
local tick = require("tick")
local H = require("hooks")
require("input")

--  start
E.loadNative()

pcall(function()
    NotifyOnNewObject(S.DIALOGUE_PATH, function(obj)
        S.seenDialogue = obj
        S.tickCount = 0
        S.resetDialogue()
        S.dlgPath = Try(function() return obj:GetFullName() end)
        H.ensure()
        conf.log("dialogue appeared")
        S.setState("APPEARED", "new-object")
        --[[ BIRTH LADDER DISABLED: suspected mod collision; birth window was clean (6 ms), while the 0x000002.. heap read family occurred outside it.
        local b0 = os.clock()
        conf.log("birth: enter")
        conf.log("birth: reset %.1fms", (os.clock() - b0) * 1000)
        conf.log("birth: path %.1fms", (os.clock() - b0) * 1000)
        conf.log("birth: hooks %.1fms", (os.clock() - b0) * 1000)
        S.birthWatch = true
        conf.log("birth: exit %.1fms", (os.clock() - b0) * 1000)
        --]]
    end)
end)

LoopAsync(S.TICK_MS, function()
    ExecuteInGameThread(tick)
    return false
end)

conf.log("%s ready.", conf.VERSION)
S.setState("IDLE", "ready")
