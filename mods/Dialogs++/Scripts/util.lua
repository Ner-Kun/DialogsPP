local S = require("state")
local U = {}

U.Try = function(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end
local Try = U.Try

--- Alive AND not on the way out. IsValid alone is not enough: an object
--- queued for garbage collection still answers true until the collector runs.
U.Usable = function(o)
    if o == nil or type(o) ~= "userdata" then return false end
    local ok, valid = pcall(function() return o:IsValid() end)
    if not ok or valid ~= true then return false end
    if type(EInternalObjectFlags) == "table" and EInternalObjectFlags.PendingKill ~= nil then
        local okKill, dying = pcall(function()
            return o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill)
        end)
        if okKill and dying then return false end
    end
    return true
end
local Usable = U.Usable

--- Our own mod folder (Scripts/..): the settings file and the DLL live here.
U.modFolder = function()
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    local scripts = src:match("^(.*)[/\\][^/\\]*$")
    if scripts == nil then return nil end
    return scripts:match("^(.*)[/\\][^/\\]*$")
end

--- Fresh anchor: look the dialogue up by stored path, but ONLY at the danger moment (freeze engage)
--- never every tick - enumeration costs 90ms a call. A freed widget stops being found; a held userdata would lie.
--- Cheap hash lookup first, enumeration fallback, both verified by FullName.
U.refreshAnchor = function()
    local path = S.dlgPath
    if type(path) ~= "string" or path == "" then return end
    local found, src = nil, nil
    if type(FindObject) == "function" then
        -- class + short instance name (the full-path form never hits).
        local cls = path:match("^(%S+)")
        local short = path:match("[^%.:]+$")
        if type(cls) == "string" and type(short) == "string" and short ~= cls then
            src = "miss"
            local obj = Try(function() return FindObject(cls, short, 0, 0) end)
            if Usable(obj) then
                local fn = Try(function() return obj:GetFullName() end)
                if fn == path then found, src = obj, "fo" end
            end
        end
    end
    if found == nil and type(FindAllOf) == "function" then
        src = "miss"
        local ok, res = pcall(FindAllOf, "WBP_Dialogue_C")
        if ok and res ~= nil then
            pcall(function()
                for _, o in pairs(res) do
                    if Usable(o) then
                        local fn = Try(function() return o:GetFullName() end)
                        if fn == path then found = o break end
                    end
                end
            end)
            res = nil
            if found ~= nil then src = "fa" end
        end
    end
    -- no lookup ran (no API): keep the anchor untouched
    if src == nil then return end
    if found ~= nil or src == "miss" then
        S.seenDialogue = found
    end
end

--- Fresh resolve on every call, never cached: the widget tree is rebuilt
--- by the game at any moment. Either return may be nil.
U.resolve = function(dlg)
    if not Usable(dlg) then return nil, nil end
    local cw = Try(function() return dlg.ChoiceWidget end)
    if not Usable(cw) then return nil, nil end
    local g = Try(function() return cw.ButtonGroup end)
    if not Usable(g) then return cw, nil end
    return cw, g
end

U.optionsShown = function()
    local dlg = S.seenDialogue
    if not Usable(dlg) then
        if S.seenDialogue ~= nil then S.seenDialogue = nil end
        return false, 0, nil
    end
    local cw, g = U.resolve(dlg)
    if g == nil then return false, 0, nil end
    local n = Try(function() return g:GetButtonCount() end)
    if type(n) ~= "number" or n <= 0 then return false, 0, nil end
    local vis = (cw ~= nil) and Try(function() return cw:GetVisibility() end) or nil
    if type(vis) == "number" and S.HIDDEN_VIS[vis] then
        return false, n, vis
    end
    return true, n, vis
end

--- True when the dialogue itself is gone, even if its widget lingers
--- (hidden/pooled). Widget death cannot be trusted because exiting through
--- pause never destroys the widget; a quiet ActiveDialogue is the signal.
U.dialogueGone = function()
    local dlg = S.seenDialogue
    if not Usable(dlg) then return true end
    local cs = Try(function() return dlg.CinematicSystem end)
    if not Usable(cs) then return true end
    local ad = Try(function() return cs.ActiveDialogue end)
    return not Usable(ad)
end

--- Progress signature of the current line: active response node + voice
--- section as one string, node guid alone as second return (first-line
--- detection: sections churn inside one line, nodes don't). Unreadable step =
--- nil, and the flight gate degrades to timeout-only. TICK CONTEXT ONLY:
--- the click handler copies S.lineSig because engine calls in click
--- context crashed the game.
U.flightSig = function()
    local dlg = S.seenDialogue
    if not Usable(dlg) then return nil end
    local cs = Try(function() return dlg.CinematicSystem end)
    if not Usable(cs) then return nil end
    local ad = Try(function() return cs.ActiveDialogue end)
    if not Usable(ad) then return nil end
    local rn = Try(function() return ad:GetActiveResponseNode() end)
    if not Usable(rn) then return "no-response", "no-response" end
    local guid = Try(function() return tostring(rn.NodeGuid) end)
    local sec = Try(function() return tostring(rn.CurrentVoiceSection) end)
    if guid == nil or sec == nil then return nil end
    return guid .. "|" .. sec, guid
end

--- UE4SS fires twice per press. The echo returns nil (and the caller
--- logs the swallow, so pairs stay visible in the tape).
U.passDebounce = function(last, debounceMs)
    local now = os.clock()
    if (now - last) * 1000 < debounceMs then return nil end
    return now
end

--- Stale-hover latch: the hover the tick saw and that has not moved
--- since, or nil. Confirming anything else risks calling into a widget
--- the game already tore down. Shared by click and key confirms.
U.stableHover = function()
    local _, ggL = U.resolve(S.seenDialogue)
    local hhL = (ggL ~= nil) and Try(function() return ggL:GetHoveredButtonIndex() end) or nil
    if S.lastHover ~= nil and S.lastHover >= 0 and hhL ~= nil and hhL == S.lastHover then
        return hhL
    end
    return nil
end

return U
