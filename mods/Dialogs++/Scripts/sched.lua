local conf = require("conf")

--- Game-thread timer queue. UE4SS's ExecuteInGameThreadWithDelay keeps the
--- callback in the Lua registry, and in this build a delayed entry can lose
--- that ref ("Ref was not function") before it fires. Keeping the closures in
--- a plain table and draining them from a game-thread loop avoids the registry
--- entirely. Callers must already be on the game thread.
local M = {}
local timers = {}

function M.later(ms, fn)
    timers[#timers + 1] = { due = os.clock() + (ms or 0) / 1000, fn = fn }
end

function M.drain()
    if #timers == 0 then return end
    local now = os.clock()
    local due, rest = {}, {}
    for i = 1, #timers do
        local t = timers[i]
        if t.due <= now then
            due[#due + 1] = t
        else
            rest[#rest + 1] = t
        end
    end
    timers = rest
    for i = 1, #due do
        local ok, err = pcall(due[i].fn)
        if not ok then conf.err("timer: %s", tostring(err)) end
    end
end

return M
