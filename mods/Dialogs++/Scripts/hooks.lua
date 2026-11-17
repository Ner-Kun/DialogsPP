local conf = require("conf")
local S = require("state")
local log = conf.log

local H = {}
H.ids = {}

local function noopPre() end

local function hook(path, post, label)
    if type(RegisterHook) ~= "function" then
        conf.warn("hook %s: RegisterHook missing", label)
        return false
    end
    local ok, _, postId = pcall(RegisterHook, path, noopPre, post)
    if ok and postId ~= nil then
        H.ids[path] = true
        log("hook %s: ok", label)
        return true
    end
    conf.warn("hook %s: failed (%s)", label, tostring(postId))
    return false
end

-- Defer registration until dialogue-appeared; UFunctions aren't available at mod load.

local pending = {
    -- Timestamp native picks so the log shows them next to the mod's confirms.
    -- Pause visibility is polled; Show/Activate hooks never fired.
    -- Dialogue events are C++ delegates, not hookable UFunctions.
    { "/Script/DogwoodUI.CinematicDialogueChoiceWidget:OnChoiceSelected", function()
        log("choice: native select")
    end, "OnChoiceSelected" },
    -- Skip diagnostics: tells us whether the native path or our fallback fired.
    { "/Script/DogwoodUI.CinematicDialogueWidget:HandleSkipActionNative", function()
        local source = S.inModSkip and "mod" or "native"
        if source == "native" then S.lastNativeSkipAt = os.clock() end
        log("skip: src=%s line=%s flight=%s pending=%s frozen=%s",
            source, conf.shortId(S.lineSig),
            tostring(S.skipFlight ~= nil), tostring(S.pendingSpace ~= nil),
            tostring(S.graphFrozen))
    end, "HandleSkipActionNative" },
}

-- WBP_Dialogue's own skip event cannot be hooked in this build (RegisterHook
-- returns nil for that Blueprint event), so HandleSkipActionNative is the
-- observable point: it fires for both the native path and our fallback.

H.ensure = function()
    for _, e in ipairs(pending) do
        if H.ids[e[1]] == nil then
            local ok = hook(e[1], e[2], e[3])
            if e[1]:find("HandleSkipActionNative", 1, true) then
                S.skipHookReady = ok
            end
        end
    end
end

return H
