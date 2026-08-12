-- @name        Magery Trainer
-- @author      3HMonkey
-- @version     1.1.0
-- @tags        training
-- @description Trains Magery from 30 to 100 by casting the cheapest
--              spell that still gains, meditates when mana runs out and
--              optionally restocks exactly the reagents the current
--              spell needs from a container.

local SETTINGS_NAME   = 'MageryTrainer'
local TARGET_SKILL    = 100
local CAST_PAUSE_MS   = 1000
local TARGET_WAIT_MS  = 4500
local MANA_BUFFER     = 4

local RESTOCK_ENABLED = true
local MIN_REAGENTS    = 5
local RESTOCK_AMOUNT  = 30
local MOVE_PAUSE_MS   = 650
local OPEN_PAUSE_MS   = 900

local MEDITATE_RETRY_MS   = 500
local MEDITATE_TIMEOUT_MS = 120000

local REAGENTS = {
    blackpearl = { name = 'Black Pearl',   graphic = 0x0F7A },
    bloodmoss  = { name = 'Bloodmoss',     graphic = 0x0F7B },
    garlic     = { name = 'Garlic',        graphic = 0x0F84 },
    mandrake   = { name = 'Mandrake Root', graphic = 0x0F86 },
    nightshade = { name = 'Nightshade',    graphic = 0x0F88 },
    silk       = { name = "Spiders' Silk", graphic = 0x0F8D },
}

local TIERS = {
    { below = 45,  spell = 'Bless',        mana = 9,
      reagents = { 'garlic', 'mandrake' } },
    { below = 55,  spell = 'Mana Drain',   mana = 11,
      reagents = { 'blackpearl', 'mandrake', 'silk' } },
    { below = 75,  spell = 'Invisibility', mana = 20,
      reagents = { 'bloodmoss', 'nightshade' } },
    { below = 200, spell = 'Mana Vampire', mana = 40,
      reagents = { 'blackpearl', 'bloodmoss', 'mandrake', 'silk' } },
}

local restockContainer = nil
local casts = 0

local function status(text, hue)
    Messages.Overhead(text, hue or 88, Player.Serial)
end

local function skillNow()
    return Skills.GetValue('Magery')
end

local function tierFor(skill)
    for _, tier in ipairs(TIERS) do
        if skill < tier.below then return tier end
    end
    return nil
end

local function countReagent(graphic)
    local items = Items.FindInContainer(Player.Backpack.Serial)
    if items == nil then return 0 end

    local total = 0
    for i = 1, #items do
        local item = items[i]
        if item ~= nil and item.Graphic == graphic then
            total = total + math.max(1, item.Amount or 1)
        end
    end
    return total
end

local function loadSettings()
    local cfg = Config.Load(SETTINGS_NAME)
    if cfg ~= nil and type(cfg.container) == 'number' and cfg.container > 0 then
        restockContainer = cfg.container
    end
end

local function saveSettings()
    Config.Save(SETTINGS_NAME, { container = restockContainer })
end

local function ensureContainer()
    if restockContainer ~= nil and Items.FindBySerial(restockContainer) ~= nil then
        return true
    end

    status('Target your reagent container', 88)
    local serial = Target.GetNewTarget(15000)
    if serial == nil then return false end

    local item = Items.FindBySerial(serial)
    if item == nil or not item.IsContainer then
        Messages.Print('Magery Trainer: that is not a container.', 33)
        return false
    end

    restockContainer = serial
    saveSettings()
    Messages.Print('Magery Trainer: restock container saved.', 68)
    return true
end

local function restockReagent(reg)
    local have = countReagent(reg.graphic)
    if have >= MIN_REAGENTS then return true end

    status('Restocking ' .. reg.name .. '...', 88)
    Player.UseObject(restockContainer)
    Pause(OPEN_PAUSE_MS)

    while have < RESTOCK_AMOUNT do
        local stock = Items.FindInContainer(restockContainer)
        local stack = nil
        if stock ~= nil then
            for i = 1, #stock do
                if stock[i] ~= nil and stock[i].Graphic == reg.graphic then
                    stack = stock[i]
                    break
                end
            end
        end

        if stack == nil then
            return have > 0
        end

        local want = math.min(RESTOCK_AMOUNT - have, math.max(1, stack.Amount or 1))
        if not Player.PickUp(stack.Serial, want) then return have > 0 end
        Pause(250)
        if not Player.DropInContainer(Player.Backpack.Serial) then return have > 0 end
        Pause(MOVE_PAUSE_MS)

        have = countReagent(reg.graphic)
    end

    return true
end

local function ensureReagents(tier)
    if not RESTOCK_ENABLED then return true end
    if not ensureContainer() then
        Messages.Print('Magery Trainer: no restock container - restock disabled for this run.', 53)
        RESTOCK_ENABLED = false
        return true
    end

    for _, key in ipairs(tier.reagents) do
        local reg = REAGENTS[key]
        if not restockReagent(reg) then
            Messages.Print('Magery Trainer: out of ' .. reg.name .. ' (backpack and container).', 33)
            return false
        end
    end
    return true
end

local function meditate()
    status('Meditating...', 88)
    Journal.Clear()
    Skills.Use('Meditation')

    local waited = 0
    local lastMana = Player.Mana
    local stagnant = 0

    while Player.Mana < Player.MaxMana do
        Pause(MEDITATE_RETRY_MS)
        waited = waited + MEDITATE_RETRY_MS
        if waited >= MEDITATE_TIMEOUT_MS then
            Messages.Print('Magery Trainer: meditation timed out - continuing.', 53)
            return
        end

        if Player.Mana <= lastMana then
            stagnant = stagnant + 1
            if stagnant >= 6 then
                Journal.Clear()
                Skills.Use('Meditation')
                stagnant = 0
            end
        else
            stagnant = 0
        end
        lastMana = Player.Mana
    end
end

local function castTier(tier)
    Journal.Clear()
    Spells.Cast(tier.spell)

    if Target.WaitForTarget(TARGET_WAIT_MS) then
        Target.Self()
    end

    Pause(CAST_PAUSE_MS)

    if Journal.Contains('insufficient mana') then
        Journal.Clear()
        meditate()
    end
end

if Player.Backpack == nil then
    Messages.Print('Magery Trainer: no backpack found - are you logged in?', 33)
    return
end

if skillNow() < 30 then
    status('Magery below 30 - train at an NPC first.', 33)
    return
end

loadSettings()
Messages.Print('Magery Trainer: starting at ' .. string.format('%.1f', skillNow()) .. ' Magery.', 68)

while true do
    local skill = skillNow()

    if skill >= TARGET_SKILL then
        status('Magery complete! (' .. string.format('%.1f', skill) .. ')', 68)
        Messages.Print('Magery Trainer: done at ' .. string.format('%.1f', skill) .. '.', 68)
        break
    end

    local tier = tierFor(skill)
    if tier == nil then break end

    if not ensureReagents(tier) then
        status('Out of reagents - stopping.', 33)
        break
    end

    if Player.Mana < tier.mana + MANA_BUFFER then
        meditate()
    end

    castTier(tier)

    casts = casts + 1
    if casts % 10 == 0 then
        status(string.format('Magery %.1f  (%s, %d casts)', skillNow(), tier.spell, casts), 88)
    end
end
