local conf = require("conf")
local S = require("state")
local log = conf.log

local H = {}
H.ids = {}

local function noopPre() end

local function hook(path, post, label)
    if type(RegisterHook) ~= "function" then
        log("hook %s: RegisterHook missing", label)
        return
    end
    local ok, _, postId = pcall(RegisterHook, path, noopPre, post)
    if ok and postId ~= nil then
        H.ids[path] = true
        log("hook %s: ok", label)
    else
        log("hook %s: failed (%s)", label, tostring(postId))
    end
end

-- Defer registration until dialogue-appeared; UFunctions aren't available at mod load.

local pending = {
    -- Hook the choice widget's selection call to timestamp confirms.
    -- Tick reads the hovered index and logs native and synthetic confirms together.
    -- Pause visibility is polled; Show/Activate hooks never fired.
    -- Dialogue events are C++ delegates, not hookable UFunctions.
    { "/Script/DogwoodUI.CinematicDialogueChoiceWidget:OnChoiceSelected", function()
        S.choiceHookAt = os.clock()
    end, "OnChoiceSelected" },
}

H.ensure = function()
    for _, e in ipairs(pending) do
        if H.ids[e[1]] == nil then hook(e[1], e[2], e[3]) end
    end
end

return H
