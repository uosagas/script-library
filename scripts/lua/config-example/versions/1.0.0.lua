-- @name        Config Example
-- @author      3HMonkey
-- @version     1.0.0
-- @tags        helpers
-- @description Shows the whole Config API: defaults, loading, saving,
--              nested tables, Exists and Delete. Run it a few times and
--              watch the values survive restarts.

----------------------------------------------------------------------
--  Config Example
--
--  Every script can persist its settings as a table. The file lands in
--  Data/LuaScripts/Config/<name>.json next to your other script data,
--  survives restarts and is shared between runs of the script.
--
--  The API is four functions:
--
--      Config.Save(name, table)   write a table   -> true/false
--      Config.Load(name)          read it back    -> table or nil
--      Config.Exists(name)        saved before?   -> true/false
--      Config.Delete(name)        remove the file -> true/false
--
--  Run this script a few times: the run counter climbs, your last
--  position is remembered, and the visited-spots list grows. Set
--  RESET_ON_START to true once to wipe everything and start fresh.
----------------------------------------------------------------------

local SETTINGS_NAME  = 'ConfigExample'
local RESET_ON_START = false   -- true = Config.Delete demo: wipe and start over

-- ==================== 1) Defaults + merge ==========================
-- Start from a defaults table and copy saved values over it. This way
-- a config written by an OLDER script version never breaks a newer
-- one: missing keys simply keep their default.

local settings = {
    runs = 0,                -- how often this script was started
    greeting = 'Hello',      -- a plain string value
    lastPosition = nil,      -- a nested table { x, y } (nil = never saved)
    visited = {},            -- a growing list of positions
}

local function mergeInto(target, saved)
    if type(saved) ~= 'table' then return end
    for key, value in pairs(saved) do
        target[key] = value
    end
end

-- ==================== 2) Exists / Delete ===========================

if RESET_ON_START and Config.Exists(SETTINGS_NAME) then
    Config.Delete(SETTINGS_NAME)
    Messages.Print('Config Example: settings wiped (RESET_ON_START).', 53)
end

if Config.Exists(SETTINGS_NAME) then
    Messages.Print('Config Example: found saved settings, loading them.', 68)
else
    Messages.Print('Config Example: first run - starting with defaults.', 88)
end

-- ==================== 3) Load ======================================
-- Config.Load returns nil when nothing was saved yet, so the merge
-- below is safe on the very first run.

mergeInto(settings, Config.Load(SETTINGS_NAME))

-- ==================== 4) Use the values ============================

settings.runs = settings.runs + 1

Messages.Print(settings.greeting .. ', ' .. Player.Name
    .. '! This is run #' .. settings.runs .. ' of this script.', 68)

if settings.lastPosition ~= nil then
    local dx = math.abs(Player.X - settings.lastPosition.x)
    local dy = math.abs(Player.Y - settings.lastPosition.y)
    Messages.Print('Last run you stood at ('
        .. settings.lastPosition.x .. ', ' .. settings.lastPosition.y
        .. ') - that is ' .. math.max(dx, dy) .. ' tiles from here.', 88)
end

-- Nested tables round-trip as you would expect: store a table, get a
-- table back. Numbers, strings, booleans and nested tables are safe;
-- functions and userdata are not.
settings.lastPosition = { x = Player.X, y = Player.Y }

table.insert(settings.visited, { x = Player.X, y = Player.Y })
if #settings.visited > 5 then
    table.remove(settings.visited, 1)  -- keep only the last five spots
end

local spots = {}
for _, p in ipairs(settings.visited) do
    table.insert(spots, '(' .. p.x .. ',' .. p.y .. ')')
end
Messages.Print('Recent spots: ' .. table.concat(spots, ' '), 88)

-- ==================== 5) Save ======================================
-- Save returns false when the file could not be written - worth
-- checking once instead of silently losing settings.

if Config.Save(SETTINGS_NAME, settings) then
    Messages.Print('Config Example: settings saved. Run me again!', 68)
else
    Messages.Print('Config Example: could not save settings.', 33)
end
