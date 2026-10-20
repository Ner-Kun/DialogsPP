local conf = {}

conf.VERSION = "1.0.3"
conf.TAG = string.format("[Dialogs++ %s]", conf.VERSION)

conf.settings = {
    -- Dialogue skip input: 0 = off, 1 = left click, 2 = Space, 3 = both
    SkipLines = 3,
    -- Two-press skip. Vanilla: first press shows the prompt, second skips.
    TwoPress = false,
    -- Hide "space" prompt widget (visual only), once per dialogue.
    HidePrompt = false,
    -- Enable wheel navigation for reply lists
    WheelScroll = true,
    -- Keyboard navigation: W/S via DLL arrows
    KbNav = false,
    -- Reply confirm key (requires KbNav): 0 = E, 1 = F, 2 = both
    ConfirmKey = 0,
    -- Timed choice duration in seconds, set before the game arms the timer. 0 = vanilla
    TimerExtendSec = 30,
    DebounceMs = 90,
    Log = true,
}

conf.log = function(fmt, ...)
    if conf.settings.Log then
        print(conf.TAG .. " " .. string.format(fmt, ...) .. "\n")
    end
end

-- Reread config.ini every 2s and apply changes live. Unknown keys are ignored
-- The debug source can come back as a non-string; a bad value must not break
-- config rereads.
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
