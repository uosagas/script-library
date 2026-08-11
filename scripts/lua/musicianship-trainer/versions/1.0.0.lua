-- @name        Musicianship Trainer
-- @author      3HMonkey
-- @version     1.0.0
-- @tags        training
-- @description Picks the best instrument from your backpack (priority
--              list like the classic UOSteam macro) and plays it until
--              the target skill is reached. Re-finds the next
--              instrument automatically when one breaks.

----------------------------------------------------------------------
--  Musicianship Trainer
--
--  Instrument priority after the classic UOSteam macro:
--
--      tambourine (red tassel) > flute > tambourine > drum
--      > lute > lap harp > standing harp
--
--  Put one or more instruments loose into your backpack (top level,
--  not inside a pouch) and start the script. It keeps playing the
--  first instrument it finds; when that one breaks or vanishes it
--  moves on to the next. No instrument left -> the script stops.
--
--  No window - start it from the Lua tab, stop it with the Stop button.
----------------------------------------------------------------------

-- ==================== Configuration ================================

local TARGET_SKILL  = 100     -- stop when Musicianship reaches this
local PLAY_PAUSE_MS = 10000   -- pause between plays (skill-gain delay)

-- Priority order: first match wins.
local INSTRUMENTS = {
    { graphic = 0x0E9E, name = 'Tambourine (red tassel)' },
    { graphic = 0x2805, name = 'Flute' },
    { graphic = 0x0E9D, name = 'Tambourine' },
    { graphic = 0x0E9C, name = 'Drum' },
    { graphic = 0x0EB3, name = 'Lute' },
    { graphic = 0x0EB2, name = 'Lap Harp' },
    { graphic = 0x0EB1, name = 'Standing Harp' },
}

-- ==================== Helpers ======================================

local function status(text, hue)
    Messages.Overhead(text, hue or 88, Player.Serial)
end

local function skillNow()
    return Skills.GetValue('Musicianship')
end

--- Best instrument in the top level of the backpack, or nil.
local function findInstrument()
    local items = Items.FindInContainer(Player.Backpack.Serial)
    if items == nil then return nil end

    for _, kind in ipairs(INSTRUMENTS) do
        for i = 1, #items do
            local item = items[i]
            if item ~= nil and item.Graphic == kind.graphic then
                return item, kind
            end
        end
    end
    return nil
end

-- ==================== Main =========================================

if Player.Backpack == nil then
    Messages.Print('Musicianship Trainer: no backpack found - are you logged in?', 33)
    return
end

if skillNow() >= TARGET_SKILL then
    status('Musicianship already at target.', 68)
    return
end

Messages.Print('Musicianship Trainer: starting at '
    .. string.format('%.1f', skillNow()) .. '.', 68)

local instrumentSerial = nil
local plays = 0

while skillNow() < TARGET_SKILL do
    -- (Re-)find an instrument when we have none or ours is gone/broken.
    if instrumentSerial == nil or Items.FindBySerial(instrumentSerial) == nil then
        local item, kind = findInstrument()
        if item == nil then
            status('No instrument found', 33)
            Messages.Print('Musicianship Trainer: no instrument in the backpack - stopping.', 33)
            return
        end
        instrumentSerial = item.Serial
        status('Instrument set: ' .. kind.name, 66)
    end

    Player.UseObject(instrumentSerial)
    Pause(PLAY_PAUSE_MS)

    plays = plays + 1
    if plays % 10 == 0 then
        status(string.format('Musicianship %.1f  (%d plays)', skillNow(), plays), 88)
    end
end

status('Musicianship complete! (' .. string.format('%.1f', skillNow()) .. ')', 68)
Messages.Print('Musicianship Trainer: done at ' .. string.format('%.1f', skillNow()) .. '.', 68)
