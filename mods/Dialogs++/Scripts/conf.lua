local conf = {}

conf.VERSION = "1.0.4"
conf.TAG = string.format("[Dialogs++ %s]", conf.VERSION)

conf.settings = {
    -- Dialogue skip input: 0 = off, 1 = left click, 2 = Space, 3 = both
    SkipLines = 3,
    -- Two-press skip. Vanilla: first press shows the prompt, second skips.
    TwoPress = false,
    -- Hide "space" prompt widget (visual only), once per dialogue.
    HidePrompt = true,
    -- Enable wheel navigation for reply lists
    WheelScroll = true,
    -- Keyboard navigation: W/S via DLL arrows
    KbNav = true,
    -- Reply confirm key (requires KbNav): 0 = E, 1 = F, 2 = both
    ConfirmKey = 0,
    -- Timed choice duration in seconds, set before the game arms the timer. 0 = vanilla
    TimerExtendSec = 60,
    DebounceMs = 90,
    Log = false,
}

conf.log = function(fmt, ...)
    if conf.settings.Log then
        print(conf.TAG .. " " .. string.format(fmt, ...) .. "\n")
    end
end

conf.always = function(fmt, ...)
    print(conf.TAG .. " " .. string.format(fmt, ...) .. "\n")
end

conf.warn = function(fmt, ...)
    print(conf.TAG .. " WARN " .. string.format(fmt, ...) .. "\n")
end

conf.err = function(fmt, ...)
    print(conf.TAG .. " ERROR " .. string.format(fmt, ...) .. "\n")
end

-- Short stable id for a GUID string.
conf.shortId = function(s)
    if type(s) ~= "string" then return "?" end
    local a = s:match("^(-?%d+)%.")
    if a == nil then return s end
    local n = tonumber(a) or 0
    if n < 0 then n = n + 4294967296 end
    return string.format("%08x", n % 4294967296)
end

-- Reread config.ini every 2s and apply changes live.
local function findRoot()
    local info = type(debug) == "table" and type(debug.getinfo) == "function"
        and debug.getinfo(1, "S") or nil
    local src = type(info) == "table" and info.source or nil
    if type(src) ~= "string" then return nil end
    local scripts = src:gsub("^@", ""):match("^(.*)[/\\][^/\\]*$")
    return scripts and scripts:match("^(.*)[/\\][^/\\]*$") or nil
end

local root = findRoot()
conf.root = root

local function readText(path)
    local f = io.open(path, "rb")
    if f == nil then return nil end
    local text = f:read("a")
    f:close()
    return text
end

local function writeText(path, text)
    local f = io.open(path, "wb")
    if f == nil then return false end
    local ok = f:write(text)
    f:close()
    return ok ~= nil
end

--- Vortex removes the mod folder on update, so the user's settings also live
--- under the game's Saved folder, outside anything Vortex manages.
local function backupPath()
    local app = os.getenv("LOCALAPPDATA")
    if type(app) ~= "string" or app == "" then return nil end
    return app .. "\\Dawnwalker\\Saved\\DialogsPP-settings.ini"
end

local function settingsText()
    local s = conf.settings
    local function flag(v) return v and "1" or "0" end
    return table.concat({
        "[Settings]",
        "SkipLines = " .. tostring(s.SkipLines),
        "TwoPress = " .. flag(s.TwoPress),
        "HidePrompt = " .. flag(s.HidePrompt),
        "WheelScroll = " .. flag(s.WheelScroll),
        "KbNav = " .. flag(s.KbNav),
        "ConfirmKey = " .. tostring(s.ConfirmKey),
        "TimerExtendSec = " .. tostring(s.TimerExtendSec),
        "LogEnabled = " .. flag(s.Log),
        "",
    }, "\r\n")
end

local lastBackupText = nil

local function saveBackup(text)
    local path = backupPath()
    if path == nil or text == lastBackupText then return end
    if writeText(path, text) then
        lastBackupText = text
        conf.log("settings: backup updated")
    else
        conf.warn("settings: backup write failed")
    end
end

--- Runs before the first read. The file either exists or it does not, so no
--- content heuristics are needed.
local function ensureConfigFile()
    if root == nil or type(io) ~= "table" or type(io.open) ~= "function" then return end
    local path = root .. "\\config.ini"
    local have = readText(path)
    if have ~= nil then
        saveBackup(have)
        return
    end
    local bak = backupPath()
    local saved = bak ~= nil and readText(bak) or nil
    if saved ~= nil then
        if writeText(path, saved) then
            lastBackupText = saved
            conf.always("settings: restored from backup")
        else
            conf.warn("settings: restore failed, using defaults")
        end
        return
    end
    local text = settingsText()
    if writeText(path, text) then
        lastBackupText = text
        conf.always("settings: created defaults")
        if bak ~= nil then writeText(bak, text) end
    else
        conf.warn("settings: cannot create config.ini")
    end
end

local lastConfigText = nil
local configChecked = false
local function readConfig()
    local log = conf.log
    local settings = conf.settings
    if root == nil or type(io) ~= "table" or type(io.open) ~= "function" then
        if not configChecked then
            configChecked = true
            log("config: no file access, defaults")
        end
        return
    end
    local f = io.open(root .. "\\config.ini", "rb")
    if f == nil then
        if not configChecked then
            configChecked = true
            log("config: no config.ini yet, defaults (open Mod Settings and Apply once)")
        end
        return
    end
    local text = f:read(4096)
    f:close()
    configChecked = true
    if text == nil or text == lastConfigText then return end
    lastConfigText = text
    saveBackup(text)
    local inSettings = false
    local map = { SkipLines = "num", TwoPress = "bool",
                  HidePrompt = "bool", WheelScroll = "bool",
                  KbNav = "bool", ConfirmKey = "num",
                  TimerExtendSec = "num", LogEnabled = "bool" }
    local clamp = { TimerExtendSec = 5000,
                    SkipLines = 3, ConfirmKey = 2 }
    local applied = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local s = line:match("^%s*(.-)%s*$")
        if s:match("^%[.+%]$") then
            inSettings = (s:lower() == "[settings]")
        elseif inSettings then
            local k, v = s:match("^([%w_]+)%s*=%s*(.-)%s*$")
            if k ~= nil and map[k] ~= nil then
                if map[k] == "bool" and (v == "0" or v == "1") then
                    local key = (k == "LogEnabled") and "Log" or k
                    settings[key] = (v == "1")
                    applied[#applied + 1] = k
                elseif map[k] == "num" then
                    local n = math.floor(tonumber(v) or -1)
                    if n >= 0 then
                        local hi = clamp[k] or 5000
                        if n > hi then n = hi end
                        settings[k] = n
                        applied[#applied + 1] = k
                    end
                end
            end
        end
    end
    if #applied > 0 then log("config: updated (%s)", table.concat(applied, ", ")) end
end
conf.readConfig = readConfig

ensureConfigFile()
readConfig()
local keyNames = { "E", "F", "E/F" }
conf.log("settings: skip=%s two-press=%s wheel=%s log=%s hide=%s kb=%s key=%s text=%ss",
    tostring(conf.settings.SkipLines),
    tostring(conf.settings.TwoPress),
    tostring(conf.settings.WheelScroll),
    tostring(conf.settings.Log),
    tostring(conf.settings.HidePrompt), tostring(conf.settings.KbNav),
    keyNames[(conf.settings.ConfirmKey or 0) + 1] or "?",
    tostring(conf.settings.TimerExtendSec))


return conf
