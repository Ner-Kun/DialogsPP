local S = require("state")
local log = require("conf").log
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

--- NotifyOnNewObject fires when a dialogue widget is created. The game reuses
--- the widget for later dialogues and across save loads, so the cache keeps
--- candidates. Every use validates the object again; the cache is not a
--- trusted pointer.
local dialogueCache = {}
local function pruneDialogueCache()
    for i = #dialogueCache, 1, -1 do
        if not Usable(dialogueCache[i]) then table.remove(dialogueCache, i) end
    end
end
U.rememberDialogue = function(obj)
    if not Usable(obj) then return end
    pruneDialogueCache()
    for i = 1, #dialogueCache do
        if dialogueCache[i] == obj then return end
    end
    dialogueCache[#dialogueCache + 1] = obj
end
--- A nil or empty path returns the newest candidate for reacquire; the caller
--- still validates that it has a live ActiveDialogue.
local function cachedDialogue(path)
    pruneDialogueCache()
    for i = #dialogueCache, 1, -1 do
        local obj = dialogueCache[i]
        if path == nil or path == "" then return obj end
        local fn = Try(function() return obj:GetFullName() end)
        if fn == path then return obj end
    end
    return nil
end
U.findCachedDialogue = cachedDialogue

--- Class plus address; GetName is nil on these widgets, and the address is what
--- tells two reused instances apart in logs.
local function anchorTag(obj)
    local class = Try(function() return obj:GetClass():GetFName():ToString() end)
    local addr = Try(function() return tostring(obj) end)
    return tostring(class) .. " " .. tostring(addr)
end

--- Our own mod folder (Scripts/..): the settings file and the DLL live here.
U.modFolder = function()
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    local scripts = src:match("^(.*)[/\\][^/\\]*$")
    if scripts == nil then return nil end
    return scripts:match("^(.*)[/\\][^/\\]*$")
end

--- Fresh anchor at freeze engage, never every tick. The Notify cache is
--- newest-first and holds the widget the game just created, so it is tried
--- first. FindObject is a fallback because it can return an older instance with
--- the same path; a fallback hit is not added to the cache. A miss drops the
--- anchor, and the next tick reacquires from the game's manager pointer.
U.refreshAnchor = function()
    local path = S.dlgPath
    if type(path) ~= "string" or path == "" then return end
    local found = cachedDialogue(path)
    local src = nil
    if found ~= nil then
        src = "cache"
    elseif type(FindObject) == "function" then
        -- class + short instance name (the full-path form never hits).
        local cls = path:match("^(%S+)")
        local short = path:match("[^%.:]+$")
        if type(cls) == "string" and type(short) == "string" and short ~= cls then
            local obj = Try(function() return FindObject(cls, short, 0, 0) end)
            if Usable(obj) then
                local fn = Try(function() return obj:GetFullName() end)
                if fn == path then found, src = obj, "fo" end
            end
        end
        src = src or "miss"
    end
    -- no lookup ran, or the cache is empty and FindObject is unavailable: keep the anchor
    if src == nil then return end
    if src == "miss" then
        log("anchor: miss")
    else
        log("anchor: %s %s", src, anchorTag(found))
    end
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

--- UE4SS fires twice per press. The echo returns nil, and the caller logs the
--- swallow so pairs stay visible in the log.
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
