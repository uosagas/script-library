-- @name        Blacksmithy Trainer
-- @author      3HMonkey
-- @version     1.0.0
-- @tags        training, crafting
-- @description Trains Blacksmithy from 35 to 120 by crafting the best item
--              for your current skill, with a live window: resource
--              counter, progress, statistics, optional smelting of what it
--              makes, restocking from a container and self-crafted hammers.

----------------------------------------------------------------------
--  Blacksmithy Trainer
--
--  Stand next to a forge and an anvil with iron ingots and a smith
--  hammer in your backpack, then start the script and press START.
--
--  It picks the item that trains best at your current skill, crafts it
--  through the craft gump ("Make Last" after the first one) and can
--  smelt each piece right back into ingots.
--
--  Below 35 skill nothing here gains reliably - buy Blacksmithy from an
--  NPC trainer up to 35 first, the window will tell you.
--
--  Everything is set in the window: target skill, smelting, hammer
--  handling and the restock container. Only the per-bracket statistics
--  are persisted (Config 'BlacksmithyTrainer', clearable in the window).
----------------------------------------------------------------------

-- ==================== Craft gump (measured on Sagas) ================
-- Both the blacksmith and the tinker gump are the same server gump
-- class, so they share this id. Button ids follow the server formula
-- 1 + type + index * 7 (verified against the live gump).

local GUMP_ID        = 0x9E26D92D
local GUMP_WAIT_MS   = 8000

-- ⚠ The server VALIDATES that a pressed button exists in the gump that is
-- currently shown (unknown ids are silently dropped). So the script has to
-- click exactly like a player would: category -> item DETAILS button
-- (3 + idx*7, item list) -> CREATE button (2 + idx*7, details page); after
-- the first craft "Make Last" repeats it. Groups on the second list page
-- need a "Next Page" press first.

local BTN_MAKE_LAST  = 21   -- type 6, index 2 (always present)
local BTN_SMELT      = 14   -- type 6, index 1 (blacksmith gump only)
local BTN_PAGE_NEXT  = 84   -- group list "Next Page" (page 0 -> 1)
local BTN_PAGE_PREV  = 77   -- group list "Prev Page" (page 1 -> 0)

-- Category buttons: 1 + groupIndex * 7 (only the visible page exists!)
local GRP_PLATE      = 15   -- Platemail       (group page 1)
local GRP_BLADED     = 43   -- Bladed (swords) (group page 1)
local GRP_SPEARS     = 57   -- Polearms/Spears (group page 2!)
local GRP_TINK_TOOLS = 1    -- Tinkering: Tools

-- ==================== Items =========================================

local IRON_INGOT     = 0x1BF2   -- iron ingots, hue 0
local IRON_INGOT_ALT = 0x1BEF   -- same stack, flipped graphic
local SMITH_HAMMER   = 0x13E3
local TINKER_TOOLS   = 0x1EB8

local MIN_TRAIN_SKILL = 35      -- below this: buy from an NPC trainer

-- Training plan: each step lists the item that gains best in its range.
-- detail = button in the item list (3 + idx*7), create = button on the
-- details page (2 + idx*7). page2 = group lives on list page 2.
local STEPS = {
    { upTo =  43, name = 'Cutlass',      group = GRP_BLADED, detail = 10, create =  9, gfx = 0x1441, ingots = 10 },
    { upTo =  47, name = 'Scimitar',     group = GRP_BLADED, detail = 45, create = 44, gfx = 0x13B6, ingots = 12 },
    { upTo =  52, name = 'Kryss',        group = GRP_BLADED, detail = 31, create = 30, gfx = 0x1401, ingots = 14 },
    { upTo =  60, name = 'Katana',       group = GRP_BLADED, detail = 24, create = 23, gfx = 0x13FF, ingots = 14 },
    { upTo =  95, name = 'Short Spear',  group = GRP_SPEARS, detail = 17, create = 16, gfx = 0x1403, ingots = 12, page2 = true },
    { upTo = 106, name = 'Plate Gorget', group = GRP_PLATE,  detail = 17, create = 16, gfx = 0x1413, ingots = 10 },
    { upTo = 108, name = 'Plate Gloves', group = GRP_PLATE,  detail = 10, create =  9, gfx = 0x1414, ingots = 12 },
    { upTo = 116, name = 'Plate Arms',   group = GRP_PLATE,  detail =  3, create =  2, gfx = 0x1410, ingots = 18 },
    { upTo = 119, name = 'Plate Legs',   group = GRP_PLATE,  detail = 24, create = 23, gfx = 0x1411, ingots = 20 },
    { upTo = 120, name = 'Plate Chest',  group = GRP_PLATE,  detail = 31, create = 30, gfx = 0x1415, ingots = 25 },
}

local TARGET_CHOICES = { 100, 105, 110, 115, 120 }

-- ==================== State =========================================

local settings = {
    target     = 120,
    smelt      = true,
    smeltAfter = 1,        -- collect this many pieces, then smelt them all
    smeltOnOverweight = true, -- melt everything early when weight runs out
    craftHammer = false,   -- craft hammers with tinkering instead of restocking
    restockBag = nil,      -- container serial, set with the button
}

local state = {
    running   = false,
    status    = 'Idle - press START.',
    step      = nil,
    startSkill = 0,
    startTime = 0,
    crafted   = 0,
    failed    = 0,
    smelted   = 0,
    ingotsUsed = 0,
    ingotsRecycled = 0,
    lastError = '',
    pickBag   = false,
}

-- ==================== Small helpers =================================

local function skillNow()
    local base = Skills.GetBase('Blacksmithy')
    if base == nil or base == 0 then base = Skills.GetValue('Blacksmithy') end
    return base or 0
end

local function ingotCount()
    return (Items.CountType(IRON_INGOT, 0) or 0) + (Items.CountType(IRON_INGOT_ALT, 0) or 0)
end

--- Finds an item of the graphic in the BACKPACK only - FindByType would
--- also match worn items or items lying in the WORLD (a deco hammer on
--- the forge!), and we must never use or smelt those.
local function findPieceInBackpack(gfx)
    local items = Items.FindInContainer(Player.Backpack.Serial)
    if items == nil then return nil end
    for i = 1, #items do
        local it = items[i]
        if it ~= nil and it.Graphic == gfx then return it end
    end
    return nil
end

local function findHammer()
    return findPieceInBackpack(SMITH_HAMMER)
end

--- Crafted pieces of the current step (success detector: the result
--- message only shows inside the gump, never in the journal, so we
--- count backpack items before and after instead).
local function pieceCount(gfx)
    return Items.CountType(gfx, 0) or 0
end

local function stepForSkill(skill)
    for i = 1, #STEPS do
        if skill < STEPS[i].upTo then return STEPS[i] end
    end
    return STEPS[#STEPS]
end

local function setStatus(text)
    state.status = text
end

local function elapsed()
    if state.startTime == 0 then return 0 end
    -- os.time can return fractional seconds here - %d in formatTime
    -- refuses non-integer numbers, so keep this an integer.
    return math.floor(os.time() - state.startTime)
end

local function formatTime(seconds)
    seconds = math.floor(seconds or 0)
    if seconds <= 0 then return '0:00' end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then return string.format('%d:%02d:%02d', h, m, s) end
    return string.format('%d:%02d', m, s)
end

local function gainPerHour()
    local secs = elapsed()
    if secs < 60 then return 0 end
    return (skillNow() - state.startSkill) / (secs / 3600)
end

-- ==================== Per-bracket statistics (persistent) ===========
-- 10-point brackets (35-40, 40-50, ... 110-120), written after every
-- craft cycle and persisted via the Config API so an aborted session
-- can be resumed without losing the numbers.

local CONFIG_NAME = 'BlacksmithyTrainer'

local bracketStats = {}

local function bracketKey(skill)
    if skill < 40 then return '35-40' end
    local lo = math.floor(skill / 10) * 10
    return string.format('%d-%d', lo, lo + 10)
end

local function statsBracket(skill)
    local key = bracketKey(skill)
    local b = bracketStats[key]
    if b == nil then
        b = { crafted = 0, failed = 0, smelted = 0, used = 0, recycled = 0, seconds = 0 }
        bracketStats[key] = b
    end
    return b
end

local function saveStats()
    Config.Save(CONFIG_NAME, bracketStats)
end

local function loadStats()
    local cfg = Config.Load(CONFIG_NAME)
    if type(cfg) ~= 'table' then return end
    for key, b in pairs(cfg) do
        if type(b) == 'table' then
            bracketStats[key] = {
                crafted  = math.floor(tonumber(b.crafted) or 0),
                failed   = math.floor(tonumber(b.failed) or 0),
                smelted  = math.floor(tonumber(b.smelted) or 0),
                used     = math.floor(tonumber(b.used) or 0),
                recycled = math.floor(tonumber(b.recycled) or 0),
                seconds  = math.floor(tonumber(b.seconds) or 0),
            }
        end
    end
end

local function clearStats()
    bracketStats = {}
    Config.Delete(CONFIG_NAME)
end

local function printStats()
    local keys = {}
    for key in pairs(bracketStats) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return (tonumber(a:match('^%d+')) or 0) < (tonumber(b:match('^%d+')) or 0) end)

    if #keys == 0 then
        Messages.Print('Blacksmithy stats: nothing recorded yet.', 88)
        return
    end

    for i = 1, #keys do
        local b = bracketStats[keys[i]]
        Messages.Print(string.format('%s: %d crafted, %d failed, %d net ingots, %s', keys[i], b.crafted, b.failed, b.used - b.recycled, formatTime(b.seconds)), 88)
    end
end

loadStats()

-- ==================== Gump plumbing =================================

--- Opens the tool and waits for its craft gump. Returns true on success.
local function openTool(toolSerial)
    Player.UseObject(toolSerial)
    return Gumps.WaitForGump(GUMP_ID, GUMP_WAIT_MS)
end

--- Presses a button and waits for the craft gump to come back. The server
--- re-sends the gump after every craft, so this is our natural clock.
---
--- The reply is handed to the game thread and only closes the old gump when
--- that thread runs, so we first wait for the old one to disappear - waiting
--- for "a gump" right away would match the OLD one and race ahead of the
--- server, sending the next button into a gump that is already gone.
local function pressAndWait(button, waitMs)
    Gumps.Reply(GUMP_ID, button)

    local waited = 0
    while Gumps.HasGump(GUMP_ID) and waited < 2000 do
        Pause(50)
        waited = waited + 50
    end

    return Gumps.WaitForGump(GUMP_ID, waitMs or GUMP_WAIT_MS)
end

--- Makes sure the gump is open; re-opens the tool if it was closed.
local function ensureGump(toolSerial)
    if Gumps.HasGump(GUMP_ID) then return true end
    return openTool(toolSerial)
end

-- ==================== Restock =======================================

--- Opens the restock container so its contents are loaded client-side -
--- FindInContainer only sees what the client has already received.
local function openRestockBag()
    if settings.restockBag == nil then return false end
    Player.UseObject(settings.restockBag)
    Pause(800)
    return true
end

--- Pulls ingots out of the restock container into the backpack.
local function restockIngots(want)
    if not openRestockBag() then return false end

    local moved = false
    for _, gfx in ipairs({ IRON_INGOT, IRON_INGOT_ALT }) do
        local have = Items.CountTypeInContainer(settings.restockBag, gfx, 0) or 0
        if have > 0 then
            local items = Items.FindInContainer(settings.restockBag)
            if items ~= nil then
                for i = 1, #items do
                    local it = items[i]
                    if it ~= nil and it.Graphic == gfx and it.Hue == 0 then
                        setStatus('Restocking ingots...')
                        Player.PickUp(it.Serial, want)
                        Pause(700)
                        Player.DropInBackpack()
                        Pause(700)
                        moved = true
                        break
                    end
                end
            end
        end
        if moved then break end
    end

    return moved
end

--- Fetches ONE item of the given graphic from the restock container -
--- used for spare hammers and, with the craft option, tinker tools.
local function restockFromBag(gfx, what)
    if not openRestockBag() then return false end

    local items = Items.FindInContainer(settings.restockBag)
    if items == nil then return false end

    for i = 1, #items do
        local it = items[i]
        if it ~= nil and it.Graphic == gfx then
            setStatus('Restocking ' .. what .. '...')
            Player.PickUp(it.Serial, 1)
            Pause(700)
            Player.DropInBackpack()
            Pause(700)
            return true
        end
    end

    return false
end

local function restockHammer()
    return restockFromBag(SMITH_HAMMER, 'a smith hammer')
end

--- Crafts a smith hammer with tinker tools (hammers are a tinkering item).
local function craftHammer()
    local tools = findPieceInBackpack(TINKER_TOOLS)

    -- No tools in the backpack? Try the restock container before giving up.
    if tools == nil and restockFromBag(TINKER_TOOLS, 'tinker tools') then
        tools = findPieceInBackpack(TINKER_TOOLS)
    end

    if tools == nil then
        state.lastError = 'No tinker tools for crafting a hammer.'
        return false
    end

    setStatus('Crafting a smith hammer...')

    if not openTool(tools.Serial) then return false end
    if not pressAndWait(GRP_TINK_TOOLS) then return false end
    if not pressAndWait(45) then return false end        -- Smith Hammer details
    if not pressAndWait(44, 15000) then return false end -- Create Item

    Gumps.Close(GUMP_ID)
    Pause(500)

    return findHammer() ~= nil
end

--- Makes sure a hammer is in the backpack (craft it or fetch a spare).
local function ensureHammer()
    local hammer = findHammer()
    if hammer ~= nil then return hammer end

    if settings.craftHammer then
        if craftHammer() then return findHammer() end
    end

    if restockHammer() then return findHammer() end

    state.lastError = 'Out of smith hammers.'
    return nil
end

-- ==================== Smelting ======================================

--- Smelts one crafted piece back into ingots (craft gump -> Smelt Item).
local function smeltOne(gfx, toolSerial)
    local piece = findPieceInBackpack(gfx)
    if piece == nil then return false end

    if not ensureGump(toolSerial) then return false end

    Gumps.Reply(GUMP_ID, BTN_SMELT)
    Pause(300)   -- let the game thread deliver the click before we look for the cursor

    if not Targeting.WaitForTarget(3000) then
        setStatus('Smelt: no target cursor.')
        return false
    end

    local ingotsBeforeSmelt = ingotCount()

    Targeting.TargetSerial(piece.Serial)
    Pause(900)
    state.smelted = state.smelted + 1

    -- The gump comes back on its own after smelting.
    Gumps.WaitForGump(GUMP_ID, 3000)

    local gained = ingotCount() - ingotsBeforeSmelt
    if gained > 0 then
        state.ingotsRecycled = state.ingotsRecycled + gained
    end

    return true
end

-- ==================== Crafting ======================================

local selectedGroup = nil   -- which category the gump currently shows

--- A craft press timed out. A worn-out tool is the usual reason: the
--- server only re-sends the gump while the tool still has charges, so
--- the last use of a hammer looks exactly like a timeout. In that case
--- the next cycle fetches a fresh hammer and reopens the gump.
local function craftPressFailed()
    if findHammer() == nil then
        setStatus('Hammer worn out - getting a new one...')
        return true
    end

    setStatus('Craft gump did not come back.')
    return false
end

--- One craft cycle. Returns true when the loop may continue.
local function craftOnce()
    local skill = skillNow()
    local step = stepForSkill(skill)
    state.step = step

    -- Ingots first: craft, then a safety margin so we never stall mid-craft.
    local ingots = ingotCount()
    local didRestock = false
    if ingots < step.ingots then
        didRestock = true
        if not restockIngots(math.max(step.ingots * 20, 200)) then
            state.lastError = 'Out of iron ingots.'
            setStatus('Stopped - out of iron ingots.')
            return false
        end
        ingots = ingotCount()
        if ingots < step.ingots then
            state.lastError = 'Out of iron ingots.'
            setStatus('Stopped - out of iron ingots.')
            return false
        end
    end

    local hammer = ensureHammer()
    if hammer == nil then
        setStatus('Stopped - ' .. state.lastError)
        return false
    end

    -- After a restock an open craft gump still shows the OLD resource
    -- counts - close it once, ensureGump reopens it with fresh numbers.
    if didRestock and Gumps.HasGump(GUMP_ID) then
        Gumps.Close(GUMP_ID)
        Pause(400)
    end

    if not ensureGump(hammer.Serial) then
        setStatus('Craft gump did not open.')
        return false
    end

    -- Step change with batch smelting: melt the leftovers of the previous
    -- item first, they would otherwise sit in the backpack forever.
    if settings.smelt and state.lastGfx ~= nil and state.lastGfx ~= step.gfx then
        local guard = 0
        while guard < 60 and smeltOne(state.lastGfx, hammer.Serial) do
            guard = guard + 1
        end
    end
    state.lastGfx = step.gfx

    local cycleStart = os.time()
    local piecesBefore = pieceCount(step.gfx)
    local ingotsBefore = ingotCount()

    -- First craft of a step: click like a player - category (flipping the
    -- group page if needed), item DETAILS, then CREATE. Afterwards
    -- "Make Last" repeats it with one click. The server drops presses on
    -- buttons that are not in the current gump, so order matters.
    if selectedGroup ~= step.name then
        setStatus('Selecting ' .. step.name .. '...')

        if not pressAndWait(step.group) then
            -- Group button not on the shown list page - flip and retry.
            local flip = step.page2 and BTN_PAGE_NEXT or BTN_PAGE_PREV
            if not pressAndWait(flip) then return false end
            if not pressAndWait(step.group) then return false end
        end

        if not pressAndWait(step.detail) then return false end
        if not pressAndWait(step.create, 15000) then return craftPressFailed() end
        selectedGroup = step.name
    else
        if not pressAndWait(BTN_MAKE_LAST, 15000) then return craftPressFailed() end
    end

    -- The gump is back, so the craft has finished. The result message only
    -- exists inside the gump, so the backpack tells us how it went: a new
    -- piece appeared = success, otherwise it was a failure.
    local success = pieceCount(step.gfx) > piecesBefore
    if success then
        state.crafted = state.crafted + 1
    else
        state.failed = state.failed + 1
    end

    local ingotsAfter = ingotCount()
    local usedDelta = 0
    if ingotsBefore > ingotsAfter then
        usedDelta = ingotsBefore - ingotsAfter
        state.ingotsUsed = state.ingotsUsed + usedDelta
    end

    -- Batch smelting: every smelt costs a gump round-trip plus a target,
    -- so collecting a few pieces first and melting them in one go is
    -- noticeably faster ("Smelt after" in the window).
    local recycledBefore = state.ingotsRecycled
    local smeltedBefore = state.smelted

    local wantSmelt = settings.smelt and pieceCount(step.gfx) >= math.max(1, settings.smeltAfter)

    -- Overweight beats the batch counter: 15 stones head room keeps the
    -- next piece and an ingot restock from overloading the character.
    if settings.smeltOnOverweight and (Player.Weight or 0) + 15 >= (Player.MaxWeight or 0) then
        wantSmelt = true
        setStatus('Overweight - smelting early...')
    end

    if wantSmelt then
        local guard = 0
        while guard < 60 and smeltOne(step.gfx, hammer.Serial) do
            guard = guard + 1
        end
    end

    -- Persistente 10er-Schritt-Statistik fortschreiben (alle 10 Zyklen
    -- gesichert, zusaetzlich bei Stop und beim Schliessen des Fensters).
    local b = statsBracket(skill)
    if success then b.crafted = b.crafted + 1 else b.failed = b.failed + 1 end
    b.used = b.used + usedDelta
    b.recycled = b.recycled + (state.ingotsRecycled - recycledBefore)
    b.smelted = b.smelted + (state.smelted - smeltedBefore)
    b.seconds = b.seconds + math.max(0, math.floor(os.time() - cycleStart))

    state.cyclesSinceSave = (state.cyclesSinceSave or 0) + 1
    if state.cyclesSinceSave >= 10 then
        state.cyclesSinceSave = 0
        saveStats()
    end

    return true
end

-- ==================== Window ========================================

local win = UI.Window('Blacksmithy Trainer', 120, 120)

win:Label(function()
    local skill = skillNow()
    if skill < MIN_TRAIN_SKILL then
        return string.format('Skill %.1f - buy up to %d from an NPC first!', skill, MIN_TRAIN_SKILL)
    end
    return string.format('Blacksmithy %.1f / %d', skill, settings.target)
end, 500)

win:ProgressBar(function()
    local skill = skillNow()
    local from = math.max(state.startSkill, MIN_TRAIN_SKILL)
    if settings.target <= from then return 1 end
    local p = (skill - from) / (settings.target - from)
    if p < 0 then return 0 end
    if p > 1 then return 1 end
    return p
end, 500)

win:Label(function()
    if state.step == nil then return 'Item: -' end
    return string.format('Item: %s  (%d ingots each)', state.step.name, state.step.ingots)
end, 500)

win:Label(function()
    local ingots = math.floor(ingotCount())
    local runs = 0
    if state.step ~= nil and state.step.ingots > 0 then
        runs = math.floor(ingots / state.step.ingots)
    end
    return string.format('Iron ingots: %d   (%d more crafts)', ingots, runs)
end, 500)

win:Label(function() return 'Status: ' .. state.status end, 300)

win:Separator()

-- Target skill as a radio row: checkboxes that clear each other.
local targetBoxes = {}
local targetRow = win:Row()
for i, value in ipairs(TARGET_CHOICES) do
    local box
    box = targetRow:Checkbox(tostring(value), value == settings.target, function(checked)
        if checked then
            settings.target = value
            for j, other in ipairs(targetBoxes) do
                if j ~= i then other:SetChecked(false) end
            end
        else
            -- Never leave the group empty - re-check the active one.
            if settings.target == value then box:SetChecked(true) end
        end
    end)
    targetBoxes[i] = box
end

local smeltRow = win:Row()
smeltRow:Checkbox('Smelt what I craft, after', settings.smelt, function(checked)
    settings.smelt = checked
end)
local smeltBox = smeltRow:TextBox(tostring(settings.smeltAfter), function(text)
    local n = math.floor(tonumber(text) or 0)
    if n >= 1 then settings.smeltAfter = n end
end)
smeltBox:SetWidth(40)
smeltRow:Label('piece(s)')

win:Checkbox('Smelt early when overweight', settings.smeltOnOverweight, function(checked)
    settings.smeltOnOverweight = checked
end)

win:Checkbox('Craft my own smith hammers (needs tinker tools)', settings.craftHammer, function(checked)
    settings.craftHammer = checked
end)

-- The picker runs in the main loop, not here: asking for a target blocks
-- until the player clicks, and a button callback must not stall the window.
local bagRow = win:Row()
bagRow:Button('Set restock container', function()
    state.pickBag = true
end)
bagRow:Label(function()
    if settings.restockBag == nil then return 'No restock container' end
    return string.format('Restock: 0x%X', math.floor(settings.restockBag))
end, 500)

win:Separator()

win:Label(function()
    return string.format('Crafted %d   failed %d   smelted %d', state.crafted, state.failed, state.smelted)
end, 500)

win:Label(function()
    return string.format('Ingots: used %d   recycled %d   net %d', math.floor(state.ingotsUsed), math.floor(state.ingotsRecycled), math.floor(state.ingotsUsed - state.ingotsRecycled))
end, 500)

win:Label(function()
    return 'Runtime: ' .. formatTime(elapsed())
end, 1000)

win:Label(function()
    local key = bracketKey(skillNow())
    local b = bracketStats[key]
    if b == nil then return 'Bracket ' .. key .. ': no data yet' end
    return string.format('Bracket %s: %d crafted, %d failed, net %d ingots, %s', key, b.crafted, b.failed, b.used - b.recycled, formatTime(b.seconds))
end, 1000)

local statsRow = win:Row()
statsRow:Button('Print stats', printStats)
statsRow:Button('Clear stats', function()
    clearStats()
    Messages.Print('Blacksmithy stats cleared.', 88)
end)

win:Label(function()
    local gain = skillNow() - state.startSkill
    local perHour = gainPerHour()
    if perHour <= 0 then
        return string.format('Gained %.1f skill', gain)
    end
    local left = settings.target - skillNow()
    local eta = left > 0 and (left / perHour) * 3600 or 0
    return string.format('Gained %.1f   %.2f/h   ETA %s', gain, perHour, formatTime(math.floor(eta)))
end, 1000)

win:Separator()

local controlRow = win:Row()
local startButton

--- Central switch: flips the loop AND the button text (buttons have no
--- Bind, only labels and progress bars do - SetText is the way).
local function setRunning(on)
    state.running = on
    startButton:SetText(on and 'STOP' or 'START')
    if not on then saveStats() end
end

startButton = controlRow:Button('START', function()
    if state.running then
        setRunning(false)
        setStatus('Stopped.')
        return
    end

    if skillNow() < MIN_TRAIN_SKILL then
        Messages.Print(string.format('Blacksmithy Trainer: train to %d at an NPC first.', MIN_TRAIN_SKILL), 33)
        return
    end

    state.crafted = 0
    state.failed = 0
    state.smelted = 0
    state.ingotsUsed = 0
    state.ingotsRecycled = 0
    state.lastError = ''
    state.startSkill = skillNow()
    state.startTime = os.time()
    selectedGroup = nil
    setRunning(true)
    setStatus('Running...')
end)

controlRow:Button('Close', function()
    setRunning(false)
    win:Close()
end)

win:OnClose(function()
    state.running = false
    saveStats()
    Gumps.Close(GUMP_ID)
end)

-- ==================== Main loop =====================================

if Player.Backpack == nil then
    Messages.Print('Blacksmithy Trainer: no backpack - are you logged in?', 33)
    return
end

Messages.Print('Blacksmithy Trainer: stand at a forge with an anvil, then press START.', 68)

state.step = stepForSkill(skillNow())

while win:IsOpen() do
    UI.Pump()

    if state.pickBag then
        state.pickBag = false
        Messages.Print('Target the container holding your ingots and spare hammers.', 68)
        setStatus('Waiting for the restock container...')
        -- Let the status label render once before the pick blocks the loop.
        Pause(400)
        UI.Pump()
        local serial = Targeting.GetNewTarget(20000)
        if serial ~= nil and serial ~= 0 then
            settings.restockBag = serial
            Messages.Print(string.format('Restock container set to 0x%X.', serial), 68)
            setStatus(state.running and 'Running...' or 'Idle - press START.')
        else
            setStatus('No container picked.')
        end
    end

    if state.running then
        if skillNow() >= settings.target then
            setRunning(false)
            setStatus(string.format('Done - reached %.1f!', skillNow()))
            Messages.Print(string.format('Blacksmithy Trainer: target %d reached.', settings.target), 68)
        else
            setStatus('Crafting ' .. (state.step and state.step.name or '?') .. '...')
            if not craftOnce() then
                setRunning(false)
                if state.lastError ~= '' then
                    Messages.Print('Blacksmithy Trainer: ' .. state.lastError, 33)
                end
            end
        end
    else
        Pause(200)
    end
end

Gumps.Close(GUMP_ID)
Messages.Print('Blacksmithy Trainer closed.', 68)
