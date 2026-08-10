----------------------------------------------------------------------
--  Loot Organizer
--  Demo script for the UOSagas Razor Lua engine.
--
--  Sorts the contents of any container (a corpse, a loot bag or your
--  own backpack) into destination containers that you assign per
--  category through the script window:
--
--      Weapons | Armor & Shields | Jewelry & Clothing | Reagents
--      Gems | Potions & Scrolls | Gold | Good Loot (optional)
--
--  Optional features (checkboxes):
--      * Identify unknown magic items first (uses the Item ID skill)
--      * Route good magic loot into its own container
--        (Force+ weapons, Fortification+ armor, Fortified+ durability)
--      * Gold fallback: put gold into your backpack when no Gold
--        container is assigned
--
--  Settings (assigned containers + checkboxes) are saved automatically
--  via the Config API and restored the next time the script starts
--  (file: Data/Profiles/Scripts/Config/LootOrganizer.json).
--
--  How to use:
--      1. Run the script - the window opens (saved settings load).
--      2. Click "Set" next to a category and target a container.
--         Assign as many categories as you like; unassigned ones
--         are simply skipped.
--      3. Click "Sort backpack" or "Sort container..." (then target
--         the corpse/chest/bag you want to loot from).
--      4. "Stop" aborts a running sort at any time.
--
--  Notes:
--      * Weapon and armor graphics are hardcoded below - generated
--        from the UOSagas server code (Items/Weapons + Items/Armor).
--        The client tile data (item.IsWeapon/IsArmor/IsWearable) is
--        kept as a fallback for graphics not in the lists.
--      * Magic tier keywords match the UOSagas server naming:
--        weapons  "... of ruin/might/force/power/vanquishing"
--        armor    "... of defense/guarding/hardening/fortification/
--                  invulnerability"
--        both     "durable/substantial/massive/fortified/indestructible ..."
--        Unidentified magic items show as "Unidentified <item>".
----------------------------------------------------------------------

-- ==================== Configuration ================================

local SETTINGS_NAME  = 'LootOrganizer'  -- Config file name
local MOVE_PAUSE_MS  = 650    -- pause between item moves (object delay)
local OPEN_PAUSE_MS  = 900    -- pause after opening the source container
local ID_PAUSE_MS    = 1500   -- pause after each Item ID attempt
local ID_MAX_TRIES   = 2      -- identify attempts per item
local TARGET_TIMEOUT = 15000  -- ms to wait when targeting a container

-- Type ids taken from the UOSagas server code.
local GOLD_ID     = 0x0EED
local REAGENT_IDS = { 0x0F7A, 0x0F7B, 0x0F84, 0x0F85, 0x0F86, 0x0F88, 0x0F8C, 0x0F8D }
local GEM_IDS     = { 0x0F10, 0x0F13, 0x0F15, 0x0F16, 0x0F19, 0x0F21, 0x0F25, 0x0F26, 0x0F2D }
local POTION_RANGE = { 0x0F06, 0x0F0D }   -- BasePotion graphics
local SCROLL_RANGE = { 0x1F2D, 0x1F72 }   -- magery spell scrolls

-- All weapon graphics, generated from the server (Items/Weapons/**).
local WEAPON_IDS = {
    0x08FD, 0x08FE, 0x0903, 0x0904, 0x0905, 0x0906, 0x0908, 0x090B, 0x090C,
    0x0DF0, 0x0DF2, 0x0E81, 0x0E86, 0x0E87, 0x0E89, 0x0EC3,
    0x0F43, 0x0F45, 0x0F47, 0x0F49, 0x0F4B, 0x0F4D, 0x0F50, 0x0F52,
    0x0F5C, 0x0F5E, 0x0F61, 0x0F62,
    0x13B0, 0x13B2, 0x13B4, 0x13B6, 0x13B8, 0x13B9,
    0x13F6, 0x13F8, 0x13FB, 0x13FD, 0x13FF, 0x1401, 0x1403, 0x1405, 0x1407,
    0x1439, 0x143B, 0x143D, 0x143E, 0x1441, 0x1443,
    0x26BA, 0x26BB, 0x26BC, 0x26BD, 0x26BE, 0x26BF, 0x26C0, 0x26C1, 0x26C2, 0x26C3,
    0x27A2, 0x27A3, 0x27A4, 0x27A5, 0x27A6, 0x27A7, 0x27A8, 0x27A9,
    0x27AB, 0x27AD, 0x27AE, 0x27AF,
    0x2D1E, 0x2D20, 0x2D21, 0x2D22, 0x2D24, 0x2D25, 0x2D28, 0x2D2B,
    0x2D2F, 0x2D32, 0x2D33, 0x2D35, 0xFEA9,
}

-- All armor and shield graphics, generated from the server
-- (Items/Armor/** including shields).
local ARMOR_IDS = {
    0x0283, 0x0284, 0x0285, 0x0286, 0x0287, 0x0288, 0x0289, 0x028A,
    0x0301, 0x0302, 0x0303, 0x0304, 0x0305, 0x0306, 0x0310, 0x0311,
    0x0403, 0x0404, 0x0405, 0x0406, 0x0407, 0x0408, 0x0409, 0x040A,
    0x13BB, 0x13BE, 0x13BF, 0x13C6, 0x13C7, 0x13CB, 0x13CC, 0x13CD,
    0x13D5, 0x13D6, 0x13DA, 0x13DB, 0x13DC, 0x13EB, 0x13EC, 0x13EE, 0x13F0,
    0x1408, 0x140A, 0x140C, 0x140E, 0x1410, 0x1411, 0x1412, 0x1413, 0x1414, 0x1415,
    0x144E, 0x144F, 0x1450, 0x1451, 0x1452,
    0x1B72, 0x1B73, 0x1B74, 0x1B76, 0x1B79, 0x1B7A, 0x1B7B, 0x1BC3, 0x1BC4,
    0x1C00, 0x1C02, 0x1C04, 0x1C06, 0x1C08, 0x1C0A, 0x1C0C, 0x1DB9, 0x1F0B,
    0x2641, 0x2643, 0x2645, 0x2647, 0x2657,
    0x2774, 0x2775, 0x2776, 0x2777, 0x2778, 0x2779, 0x277A, 0x277D, 0x277E, 0x277F,
    0x2780, 0x2781, 0x2784, 0x2785, 0x2786, 0x2788, 0x2789, 0x278A, 0x278B,
    0x278D, 0x278E, 0x2791, 0x2792, 0x2793, 0x279D, 0x27C6, 0x27C7, 0x27D2,
    0x2B67, 0x2B69, 0x2B6A, 0x2B6B, 0x2B6C, 0x2B6D, 0x2B6E, 0x2B6F,
    0x2B70, 0x2B71, 0x2B72, 0x2B73, 0x2B74, 0x2B75, 0x2B76, 0x2B77, 0x2B78, 0x2B79,
    0x2FB8, 0x2FC5, 0x2FC6, 0x2FC7, 0x2FC8, 0x2FC9, 0x2FCA, 0x2FCB,
    0x4200, 0x457E,
}

-- Magic tier keywords (server: WeaponDamageLevel / ArmorProtectionLevel /
-- *DurabilityLevel). Trim or extend these lists to taste.
local GOOD_WEAPON_WORDS     = { 'of force', 'of power', 'of vanquishing' }
local GOOD_ARMOR_WORDS      = { 'of hardening', 'of fortification', 'of invulnerability' }
local GOOD_DURABILITY_WORDS = { 'fortified', 'indestructible' }

-- Force a category for specific graphics (extension point), e.g.:
--   OVERRIDES[0x0E76] = 'wearables'   -- leather bag as a wearable
local OVERRIDES = {}

local CATEGORIES = {
    { key = 'weapons',   label = 'Weapons' },
    { key = 'armor',     label = 'Armor & Shields' },
    { key = 'wearables', label = 'Jewelry & Clothing' },
    { key = 'reagents',  label = 'Reagents' },
    { key = 'gems',      label = 'Gems' },
    { key = 'potions',   label = 'Potions & Scrolls' },
    { key = 'gold',      label = 'Gold' },
    { key = 'good',      label = 'Good Loot' },
}

-- ==================== State ========================================

local containers = {}     -- category key -> container serial
local catLabels  = {}     -- category key -> UI label (shows assignment)
local busy = false        -- one operation at a time
local stopRequested = false

-- Fast lookup sets built from the id lists above.
local weaponSet, armorSet, reagentSet, gemSet = {}, {}, {}, {}
for _, id in ipairs(WEAPON_IDS)  do weaponSet[id]  = true end
for _, id in ipairs(ARMOR_IDS)   do armorSet[id]   = true end
for _, id in ipairs(REAGENT_IDS) do reagentSet[id] = true end
for _, id in ipairs(GEM_IDS)     do gemSet[id]     = true end

-- ==================== Small helpers ================================

local function inRange(range, value)
    return value >= range[1] and value <= range[2]
end

local function containsAny(text, words)
    for i = 1, #words do
        if string.find(text, words[i], 1, true) then return true end
    end
    return false
end

--- Lowercase name + properties of an item (safe for nil fields).
local function itemText(item)
    return string.lower((item.Name or '') .. ' ' .. (item.Properties or ''))
end

local function shortSerial(serial)
    return string.format('0x%08X', serial)
end

--- Display name for a container serial (falls back to the serial).
local function containerDisplay(serial)
    local item = Items.FindBySerial(serial)
    if item ~= nil and item.Name ~= '' then
        return item.Name .. '  ' .. shortSerial(serial)
    end
    return shortSerial(serial)
end

-- ==================== UI ===========================================

local win = UI.Window('Loot Organizer', 150, 150)

win:Label('Assign a container per category, then sort.'):SetColor('#9CDCFE')
local statusLabel = win:Label('Ready')
statusLabel:SetColor('#DCDCAA')
win:Separator()

local function setStatus(text)
    statusLabel:SetText(text)
end

local function updateCatLabel(cat)
    if containers[cat.key] ~= nil then
        catLabels[cat.key]:SetText(cat.label .. ':  ' .. containerDisplay(containers[cat.key]))
        catLabels[cat.key]:SetColor('#6FCF6F')
    else
        catLabels[cat.key]:SetText(cat.label .. ':  (not set)')
        catLabels[cat.key]:SetColor('#DCDCDC')
    end
end

--- Run one operation with a busy guard and error handling. Callbacks
--- call this directly - the engine keeps delivering other (short)
--- callbacks such as Stop while the job is busy.
local function runJob(job)
    if busy then
        Messages.Print('Loot Organizer: busy - please wait or press Stop.', 53)
        return
    end

    busy = true
    stopRequested = false

    local ok, err = pcall(job)
    if not ok then
        setStatus('Error: ' .. tostring(err))
        Messages.Print('Loot Organizer error: ' .. tostring(err), 33)
    end

    busy = false
    stopRequested = false
end

--- One row per category: [Set] button + assignment label.
for _, cat in ipairs(CATEGORIES) do
    local row = win:Row()
    row:Button('Set', function()
        runJob(function() AssignContainer(cat) end)
    end)
    catLabels[cat.key] = row:Label(cat.label .. ':  (not set)')
end

win:Separator()
local identifyChk = win:Checkbox('Identify unknown magic items (Item ID skill)', false)
local goodChk     = win:Checkbox('Separate good loot (Force+/Fortification+/Fortified+)', true)
local goldChk     = win:Checkbox('Gold to backpack when no Gold container is set', true)
win:Separator()

local actions = win:Row()
actions:Button('Sort backpack', function()
    runJob(function() SortContainer(Player.Backpack.Serial, 'backpack', true) end)
end)
actions:Button('Sort container...', function()
    runJob(function() SortTargetedContainer() end)
end)
actions:Button('Stop', function()
    -- Short callback: delivered even while a sort is running.
    stopRequested = true
    setStatus('Stopping...')
end)

-- ==================== Settings (Config API) ========================

function SaveSettings()
    local cfg = {
        containers = {},
        identify = identifyChk:IsChecked(),
        goodLoot = goodChk:IsChecked(),
        goldFallback = goldChk:IsChecked(),
    }
    for key, serial in pairs(containers) do
        cfg.containers[key] = serial
    end

    if not Config.Save(SETTINGS_NAME, cfg) then
        Messages.Print('Loot Organizer: could not save settings.', 33)
    end
end

function LoadSettings()
    local cfg = Config.Load(SETTINGS_NAME)
    if cfg == nil then return end

    if type(cfg.containers) == 'table' then
        for _, cat in ipairs(CATEGORIES) do
            local serial = cfg.containers[cat.key]
            if type(serial) == 'number' and serial > 0 then
                containers[cat.key] = serial
                updateCatLabel(cat)
            end
        end
    end

    if cfg.identify ~= nil then identifyChk:SetChecked(cfg.identify) end
    if cfg.goodLoot ~= nil then goodChk:SetChecked(cfg.goodLoot) end
    if cfg.goldFallback ~= nil then goldChk:SetChecked(cfg.goldFallback) end

    Messages.Print('Loot Organizer: settings loaded.', 68)
end

-- Persist checkbox changes (fires only on user interaction, not on
-- the SetChecked calls above).
identifyChk:OnChange(function() SaveSettings() end)
goodChk:OnChange(function() SaveSettings() end)
goldChk:OnChange(function() SaveSettings() end)

-- ==================== Container assignment =========================

function AssignContainer(cat)
    setStatus('Target the ' .. cat.label .. ' container...')
    Messages.Overhead('Target the ' .. cat.label .. ' container', 88, Player.Serial)

    local serial = Target.GetNewTarget(TARGET_TIMEOUT)
    if serial == nil then
        setStatus('Ready')
        Messages.Print('Loot Organizer: no target - ' .. cat.label .. ' unchanged.', 53)
        return
    end

    local item = Items.FindBySerial(serial)
    if item == nil then
        setStatus('Ready')
        Messages.Print('Loot Organizer: that is not an item in view.', 33)
        return
    end

    if not item.IsContainer then
        setStatus('Ready')
        Messages.Print('Loot Organizer: ' .. (item.Name or 'that item') .. ' is not a container.', 33)
        return
    end

    containers[cat.key] = serial
    updateCatLabel(cat)
    SaveSettings()
    setStatus('Ready')
    Messages.Print('Loot Organizer: ' .. cat.label .. ' -> ' .. containerDisplay(serial) .. '.', 68)
end

-- ==================== Classification ===============================

local function isUnidentified(item)
    return string.find(itemText(item), 'unidentified', 1, true) ~= nil
end

--- Is this a magic item worth the good-loot container?
local function isGoodLoot(item, base)
    local text = itemText(item)

    if containsAny(text, GOOD_DURABILITY_WORDS) then return true end
    if base == 'weapons' and containsAny(text, GOOD_WEAPON_WORDS) then return true end
    if (base == 'armor' or base == 'wearables') and containsAny(text, GOOD_ARMOR_WORDS) then return true end

    return false
end

--- Returns the category key for an item, or nil if it is not handled.
local function classify(item)
    if OVERRIDES[item.Graphic] then return OVERRIDES[item.Graphic] end

    if item.Graphic == GOLD_ID then return 'gold' end
    if reagentSet[item.Graphic] then return 'reagents' end
    if gemSet[item.Graphic] then return 'gems' end
    if inRange(POTION_RANGE, item.Graphic) or inRange(SCROLL_RANGE, item.Graphic) then
        return 'potions'
    end

    -- Equipment: hardcoded server graphics first, tile data as fallback.
    local base = nil
    if weaponSet[item.Graphic] then
        base = 'weapons'
    elseif armorSet[item.Graphic] then
        base = 'armor'
    elseif item.IsWeapon then
        base = 'weapons'
    elseif item.IsArmor then
        base = 'armor'
    elseif item.IsWearable then
        base = 'wearables'
    end

    if base ~= nil and goodChk:IsChecked() and containers.good ~= nil and isGoodLoot(item, base) then
        return 'good'
    end

    return base
end

-- ==================== Identify =====================================

--- Try to identify one item with the Item ID skill. Returns the
--- (possibly refreshed) item.
local function identify(item)
    for attempt = 1, ID_MAX_TRIES do
        if stopRequested then return item end

        setStatus('Identifying ' .. (item.Name or 'item') .. ' (' .. attempt .. '/' .. ID_MAX_TRIES .. ')')
        Skills.Use('Item ID')

        if Target.WaitForTarget(3000) then
            Target.TargetSerial(item.Serial)
        else
            Messages.Print('Loot Organizer: no target cursor from Item ID - skipping identify.', 53)
            return item
        end

        Pause(ID_PAUSE_MS)

        local fresh = Items.FindBySerial(item.Serial)
        if fresh == nil then return item end
        item = fresh
        if not isUnidentified(item) then return item end
    end

    return item
end

-- ==================== Moving =======================================

--- Move one item into a container. Returns true on success.
local function moveItem(item, destSerial)
    if not Player.PickUp(item.Serial, item.Amount) then
        return false
    end

    Pause(250)

    if not Player.DropInContainer(destSerial) then
        return false
    end

    Pause(MOVE_PAUSE_MS)
    return true
end

--- Serial belongs to one of the assigned destination containers?
local function isDestination(serial)
    for _, s in pairs(containers) do
        if s == serial then return true end
    end
    return false
end

-- ==================== Sorting ======================================

function SortContainer(sourceSerial, sourceName, isBackpack)
    -- ---- validate the source -----------------------------------
    if sourceSerial == nil then
        error('no source container', 0)
    end

    local source = Items.FindBySerial(sourceSerial)
    if not isBackpack then
        if source == nil then
            error('source container is not in view', 0)
        end
        if source.Distance > 3 then
            error('source container is too far away (' .. source.Distance .. ' tiles)', 0)
        end

        -- Open it so the client knows its contents.
        setStatus('Opening ' .. sourceName .. '...')
        Player.UseObject(sourceSerial)
        Pause(OPEN_PAUSE_MS)
    end

    local items = Items.FindInContainer(sourceSerial)
    if items == nil or #items == 0 then
        setStatus('Nothing to sort in ' .. sourceName .. '.')
        Messages.Print('Loot Organizer: ' .. sourceName .. ' is empty (or not loaded yet).', 53)
        return
    end

    -- ---- sort --------------------------------------------------
    local moved, skipped, failed = 0, 0, 0
    local total = #items

    for i = 1, total do
        if stopRequested then break end

        local item = items[i]

        -- Never move our own destination containers around.
        if item ~= nil and not isDestination(item.Serial) then
            setStatus('Sorting ' .. i .. '/' .. total .. '  (' .. (item.Name or '?') .. ')')

            -- Optional identify pass for unknown magic equipment.
            if identifyChk:IsChecked() and isUnidentified(item)
               and (weaponSet[item.Graphic] or armorSet[item.Graphic]
                    or item.IsWeapon or item.IsArmor or item.IsWearable) then
                item = identify(item)
            end

            local key = classify(item)
            local dest = nil

            if key == 'gold' then
                -- Gold container first, backpack as an optional fallback.
                dest = containers.gold
                if dest == nil and goldChk:IsChecked() then
                    dest = Player.Backpack.Serial
                end
            elseif key ~= nil then
                dest = containers[key]
            end

            -- Do not "move" items that are already in the target.
            if dest ~= nil and dest ~= sourceSerial then
                if moveItem(item, dest) then
                    moved = moved + 1
                else
                    failed = failed + 1
                    Messages.Print('Loot Organizer: could not move ' .. (item.Name or 'item') .. '.', 33)
                end
            else
                skipped = skipped + 1
            end
        end
    end

    -- ---- summary -----------------------------------------------
    local summary = 'Done: ' .. moved .. ' moved, ' .. skipped .. ' skipped'
    if failed > 0 then summary = summary .. ', ' .. failed .. ' FAILED' end
    if stopRequested then summary = summary .. ' (stopped)' end

    setStatus(summary)
    Messages.Print('Loot Organizer: ' .. summary .. '.', failed > 0 and 33 or 68)
end

function SortTargetedContainer()
    setStatus('Target the container to sort...')
    Messages.Overhead('Target the container to sort', 88, Player.Serial)

    local serial = Target.GetNewTarget(TARGET_TIMEOUT)
    if serial == nil then
        setStatus('Ready')
        return
    end

    local source = Items.FindBySerial(serial)
    if source == nil then
        setStatus('Ready')
        Messages.Print('Loot Organizer: that is not an item in view.', 33)
        return
    end

    if not (source.IsContainer or source.IsCorpse) then
        setStatus('Ready')
        Messages.Print('Loot Organizer: target a container or a corpse.', 33)
        return
    end

    local name = (source.Name ~= '' and source.Name) or 'container'
    SortContainer(serial, name, false)
end

-- ==================== Start ========================================

if Player.Backpack == nil then
    Messages.Print('Loot Organizer: no backpack found - are you logged in?', 33)
    win:Close()
    return
end

LoadSettings()
Messages.Print('Loot Organizer ready - assign containers in the window.', 68)

-- Hand control to the engine: keeps the window alive, delivers all
-- callbacks and bindings, returns when the window is closed.
win:Run()
