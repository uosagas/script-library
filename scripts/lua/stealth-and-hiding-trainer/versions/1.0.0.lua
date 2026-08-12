-- @name        Stealth and Hiding Trainer
-- @author      3HMonkey
-- @version     1.0.0
-- @tags        training
-- @description Trains Stealth by bouncing through a nearby moongate and
--              stealthing after each trip. Equips ringmail (tunic and
--              sleeves) from 80 upwards and can train Hiding to 80
--              first. Target values are configurable below.

----------------------------------------------------------------------
--  Stealth and Hiding Trainer
--
--  Stand next to a moongate and start the script. Each round it uses
--  the gate, answers the destination gump, waits out the travel pause,
--  hides if needed and uses the Stealth skill. From 80 Stealth on it
--  wears a ringmail tunic and sleeves (armor makes the checks harder,
--  which keeps the gains coming) - keep both in your backpack or
--  already equipped.
--
--  The moongate gump is answered with button 1 (travel) plus the
--  destination radio switch; the script walks through every
--  destination in DESTINATIONS in order. The stop you are currently
--  standing at simply does not teleport - the script notices that
--  (position unchanged) and moves on to the next one.
----------------------------------------------------------------------

local TARGET_STEALTH     = 100    -- stop when Stealth reaches this
local TRAIN_HIDING_FIRST = true   -- train Hiding up to HIDING_REQUIRED first
local HIDING_REQUIRED    = 80     -- Stealth needs this much Hiding
local HIDE_PAUSE_MS      = 15000  -- pause between Hiding attempts

local GATE_GRAPHIC   = 0x0F6C     -- blue moongate
local GUMP_ID        = 0x22E12657 -- the moongate destination gump
local GUMP_WAIT_MS   = 15000
local TRAVEL_BUTTON  = 1          -- the gump's OK/travel button
local DESTINATIONS   = {          -- radio switch per destination, in travel order
    { switch = 0, name = 'Adena' },
    { switch = 1, name = 'Coldstone' },
    { switch = 2, name = 'Moonvale' },
    { switch = 3, name = "New Buccaneer's Den" },
    { switch = 4, name = 'Volaria' },
    { switch = 5, name = 'Westwend' },
    { switch = 6, name = 'Duel Area' },
}
local TRAVEL_PAUSE_MS = 10000     -- wait after traveling before stealthing
local STEP_PAUSE_MS   = 600

local ARMOR_FROM     = 80         -- wear ringmail from this Stealth value on
local TUNIC_GRAPHIC  = 0x13EC     -- ringmail tunic  (torso, layer 13)
local SLEEVES_GRAPHIC = 0x13EE    -- ringmail sleeves (arms, layer 19)
local LAYER_TORSO    = 13
local LAYER_ARMS     = 19

local function status(text, hue)
    Messages.Overhead(text, hue or 88, Player.Serial)
end

local function stealthNow()
    return Skills.GetValue('Stealth')
end

local function findWearable(graphic, layer)
    local worn = Items.FindByLayer(layer)
    if worn ~= nil and worn.Graphic == graphic then
        return worn.Serial, true
    end

    local items = Items.FindInContainer(Player.Backpack.Serial)
    if items ~= nil then
        for i = 1, #items do
            local item = items[i]
            if item ~= nil and item.Graphic == graphic then
                return item.Serial, false
            end
        end
    end
    return nil, false
end

local function ensureEquipped(graphic, layer, name)
    local worn = Items.FindByLayer(layer)
    if worn ~= nil and worn.Graphic == graphic then return true end

    local serial = findWearable(graphic, layer)
    if serial == nil then
        status('No ' .. name .. ' found!', 33)
        return false
    end

    Player.Equip(serial)
    Pause(STEP_PAUSE_MS)
    return true
end

local function trainHiding()
    while Skills.GetValue('Hiding') < HIDING_REQUIRED do
        status(string.format('Hiding %.1f / %d', Skills.GetValue('Hiding'), HIDING_REQUIRED), 88)
        Skills.Use('Hiding')
        Pause(HIDE_PAUSE_MS)
    end
end

local function takeTrip(dest)
    local gate = Items.FindByType(GATE_GRAPHIC)
    if gate == nil or gate.Distance > 2 then
        status('No moongate in reach - stand next to one.', 33)
        return false
    end

    local fromX, fromY = Player.X, Player.Y

    Player.UseObject(gate.Serial)

    if not Gumps.WaitForGump(GUMP_ID, GUMP_WAIT_MS) then
        status('Moongate gump did not open.', 33)
        return false
    end

    Gumps.Reply(GUMP_ID, TRAVEL_BUTTON, { dest.switch })
    Pause(TRAVEL_PAUSE_MS)

    -- Standing at this destination already? Nothing happened - skip
    -- the stealth attempt and let the loop try the next stop.
    if Player.X == fromX and Player.Y == fromY then
        return true
    end

    if not Player.IsHidden then
        Skills.Use('Hiding')
        Pause(STEP_PAUSE_MS)
    end

    Skills.Use('Stealth')
    Pause(STEP_PAUSE_MS)
    return true
end

if Player.Backpack == nil then
    Messages.Print('Stealth and Hiding Trainer: no backpack found - are you logged in?', 33)
    return
end

if Skills.GetValue('Hiding') < HIDING_REQUIRED then
    if TRAIN_HIDING_FIRST then
        Messages.Print('Stealth and Hiding Trainer: training Hiding to ' .. HIDING_REQUIRED .. ' first.', 68)
        trainHiding()
    else
        status('Train your Hiding to ' .. HIDING_REQUIRED .. ' first!', 33)
        return
    end
end

if findWearable(TUNIC_GRAPHIC, LAYER_TORSO) == nil then
    status('Buy a ringmail tunic', 33)
    return
end
if findWearable(SLEEVES_GRAPHIC, LAYER_ARMS) == nil then
    status('Buy ringmail sleeves', 33)
    return
end

Messages.Print('Stealth and Hiding Trainer: starting at ' .. string.format('%.1f', stealthNow()) .. ' Stealth.', 68)

local destIndex = 1
local trips = 0

while stealthNow() < TARGET_STEALTH do
    if stealthNow() >= ARMOR_FROM then
        if not ensureEquipped(TUNIC_GRAPHIC, LAYER_TORSO, 'ringmail tunic') then break end
        if not ensureEquipped(SLEEVES_GRAPHIC, LAYER_ARMS, 'ringmail sleeves') then break end
    end

    if not takeTrip(DESTINATIONS[destIndex]) then break end
    destIndex = (destIndex % #DESTINATIONS) + 1

    trips = trips + 1
    if trips % 5 == 0 then
        status(string.format('Stealth %.1f  (%d trips)', stealthNow(), trips), 88)
    end
end

if stealthNow() >= TARGET_STEALTH then
    status('Stealth complete! (' .. string.format('%.1f', stealthNow()) .. ')', 68)
    Messages.Print('Stealth and Hiding Trainer: done at ' .. string.format('%.1f', stealthNow()) .. '.', 68)
end
