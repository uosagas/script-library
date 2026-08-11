-- @name        UI Example - Advanced
-- @author      3HMonkey
-- @version     1.0.0
-- @tags        helpers, utility
-- @description A character dashboard that uses every script-UI control:
--              live progress bars, sliders, text input, rows, visibility
--              toggles and settings that persist via the Config API.

----------------------------------------------------------------------
--  UI Example - Advanced: Character Dashboard
--
--  A tour through the whole script-UI toolbox:
--
--      * Live labels and progress bars driven by BINDING FUNCTIONS -
--        pass a function instead of a value and the engine polls it
--      * Rows for side-by-side layout, SetWidth for alignment
--      * Slider (warn threshold + overhead hue), TextBox with
--        placeholder, buttons, checkboxes
--      * SetVisible to collapse a whole section ("compact mode")
--      * A low-health warning with a cooldown, computed inside a
--        binding - bindings are plain Lua functions, they may think
--      * Config API: every setting survives a restart
--      * OnClose + Run to hand control to the engine
--
--  Run it from the Lua tab while you are in game.
----------------------------------------------------------------------

local SETTINGS_NAME = 'UIExampleAdvanced'

-- ==================== Settings (with defaults) =====================

local settings = {
    threshold = 50,     -- warn when HP falls below this percentage
    warnOverhead = true,
    compact = false,
    hue = 88,           -- hue for overhead texts
}

local function saveSettings()
    if not Config.Save(SETTINGS_NAME, settings) then
        Messages.Print('Dashboard: could not save settings.', 33)
    end
end

local function loadSettings()
    local cfg = Config.Load(SETTINGS_NAME)
    if cfg == nil then return end
    if type(cfg.threshold) == 'number' then settings.threshold = cfg.threshold end
    if cfg.warnOverhead ~= nil then settings.warnOverhead = cfg.warnOverhead end
    if cfg.compact ~= nil then settings.compact = cfg.compact end
    if type(cfg.hue) == 'number' then settings.hue = cfg.hue end
end

loadSettings()

-- ==================== Small helpers ================================

--- Fraction 0..1 for a progress bar, safe against 0/0 before login.
local function frac(value, max)
    if max == nil or max <= 0 then return 0 end
    if value == nil or value < 0 then return 0 end
    if value > max then return 1 end
    return value / max
end

local function hpPercent()
    return math.floor(frac(Player.Hits, Player.HitsMax) * 100 + 0.5)
end

-- ==================== Window =======================================

local win = UI.Window('Character Dashboard', 220, 180)

-- Header: a live label combining several player fields.
win:Label(function()
    return Player.Name .. '   (' .. Player.X .. ', ' .. Player.Y .. ')'
end, 500):SetColor('#E6C34A')

win:Separator()

-- ==================== Vitals (bound progress bars) =================
-- Each bar gets a FUNCTION returning 0..1; the engine polls it every
-- 250 ms. The label next to it is bound too, so text and bar agree.

local function vitalRow(name, color, value, max)
    local row = win:Row()
    row:Label(name):SetWidth(55)
    local bar = row:ProgressBar(function() return frac(value(), max()) end, 250)
    bar:SetColor(color)
    row:Label(function() return value() .. '/' .. max() end, 250):SetColor('#B8B8B8')
    return bar
end

vitalRow('Health',  '#CC3333', function() return Player.Hits end, function() return Player.HitsMax end)
vitalRow('Mana',    '#3366CC', function() return Player.Mana end, function() return Player.MaxMana end)
vitalRow('Stamina', '#33CC99', function() return Player.Stam end, function() return Player.MaxStam end)

-- ==================== Low-health warning ===========================
-- The status label's binding does the actual thinking: it compares HP
-- against the threshold and fires an overhead warning with a cooldown.
-- (10 binding ticks x 500 ms = one warning every ~5 seconds at most.)

local warnCooldown = 0

local statusLabel = win:Label(function()
    if warnCooldown > 0 then warnCooldown = warnCooldown - 1 end

    local pct = hpPercent()
    if pct < settings.threshold then
        if settings.warnOverhead and warnCooldown <= 0 then
            Messages.Overhead('LOW HEALTH: ' .. pct .. '%', 33, Player.Serial)
            warnCooldown = 10
        end
        return 'Status: LOW HEALTH (' .. pct .. '% < ' .. settings.threshold .. '%)'
    end
    return 'Status: OK (' .. pct .. '%, warn below ' .. settings.threshold .. '%)'
end, 500)

win:Separator()

-- ==================== Options section ==============================
-- Everything below can be hidden with the compact-mode checkbox, so
-- keep the created controls around to call SetVisible on them later.

local optionControls = {}
local function tracked(control)
    table.insert(optionControls, control)
    return control
end

local thrRow = win:Row()
tracked(thrRow:Label('Warn below'))
local thrValueLabel
tracked(thrRow:Slider(10, 90, settings.threshold, function(value)
    settings.threshold = math.floor(value + 0.5)
    thrValueLabel:SetText(settings.threshold .. '%')
    saveSettings()
end))
thrValueLabel = thrRow:Label(settings.threshold .. '%')
tracked(thrValueLabel)

tracked(win:Checkbox('Overhead warning', settings.warnOverhead, function(checked)
    settings.warnOverhead = checked
    saveSettings()
end))

local hueRow = win:Row()
tracked(hueRow:Label('Shout hue'))
local hueValueLabel
tracked(hueRow:Slider(1, 999, settings.hue, function(value)
    settings.hue = math.floor(value + 0.5)
    hueValueLabel:SetText(tostring(settings.hue))
    saveSettings()
end))
hueValueLabel = hueRow:Label(tostring(settings.hue))
tracked(hueValueLabel)

-- TextBox + button: shout the text over your head in the chosen hue.
local shoutRow = win:Row()
local shoutBox = shoutRow:TextBox()
shoutBox:SetPlaceholder('Something to shout...')
tracked(shoutBox)
tracked(shoutRow:Button('Shout', function()
    local text = shoutBox:GetText()
    if text == nil or text == '' then
        Messages.Print('Dashboard: type something first.', 53)
        return
    end
    Messages.Overhead(text, settings.hue, Player.Serial)
end))

win:Separator()

-- ==================== Footer =======================================

local function applyCompact()
    for _, control in ipairs(optionControls) do
        control:SetVisible(not settings.compact)
    end
end

local footer = win:Row()
footer:Checkbox('Compact mode', settings.compact, function(checked)
    settings.compact = checked
    applyCompact()
    saveSettings()
end)
footer:Button('Close', function() win:Close() end)

applyCompact()

win:OnClose(function()
    Messages.Print('Dashboard closed - settings are saved.', 88)
end)

-- ==================== Start ========================================

if Player.HitsMax == nil or Player.HitsMax == 0 then
    Messages.Print('Dashboard: no player data - are you logged in?', 33)
end

Messages.Print('Character Dashboard ready.', 68)
win:Run()
