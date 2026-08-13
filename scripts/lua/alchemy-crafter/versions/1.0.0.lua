-- @name        Alchemy Crafter
-- @author      3HMonkey
-- @version     1.0.0
-- @tags        crafting
-- @description Crafts potion kegs and fills them from a per-type work
--              list (checkbox + amount per keg type), with a live
--              resource overview for backpack AND containers,
--              statistics and unloading of finished kegs.

----------------------------------------------------------------------
--  Alchemy Crafter
--
--  Fills potion kegs and/or crafts new ones. Tick the keg types you
--  want, set the amount behind each, set your containers and press
--  START. The types are worked top to bottom. Keg colours come from
--  the server automatically (hue per potion type).
--
--  How keg filling works on Sagas: a brewed potion is poured straight
--  into a matching keg in your backpack - but only into a keg that was
--  already started (1-99 charges held). So the script brews the first
--  potion into a bottle, tips it onto the keg by hand and lets the
--  server pour every following brew automatically. A brew that stays
--  in the backpack is the exact "keg is full" signal.
--
--  Potions of one family share a single bottle graphic (all heal tiers
--  are one item id!), so when a type starts, any leftover potions of
--  that family are stashed into the restock container first - they
--  could type a keg wrongly otherwise.
--
--  Keg crafting is tinkering 75 (1 keg + 10 bottles + 2 barrel lids +
--  1 barrel tap). By default the parts come from the restock container;
--  the "craft parts" option also builds them from logs and ingots
--  (needs carpentry 57.8 + a saw for kegs/staves/lids).
--
--  The unload container (when set) doubles as a SECOND restock source
--  during fill runs - empty kegs crafted into it earlier are pulled
--  back out automatically.
--
--  The window setup and the lifetime statistics are persisted (Config 'AlchemyCrafter',
--  clearable in the window).
----------------------------------------------------------------------

-- ==================== Craft gump (measured on Sagas) ================
-- Every craft system shares the same server gump class and id. Button
-- ids follow the server formula 1 + type + index * 7. The server
-- VALIDATES that a pressed button exists in the gump that is currently
-- shown (unknown ids are silently dropped), so the script clicks
-- exactly like a player: category -> item DETAILS (3 + idx*7) ->
-- CREATE (2 + idx*7, details page only); "Make Last" repeats it.
-- Group lists are paginated by the server (8 per page).

local GUMP_ID       = 0x9E26D92D
local GUMP_WAIT_MS  = 8000

local BTN_MAKE_LAST = 21
local BTN_PAGE_NEXT = 84   -- group list "Next Page"
local BTN_PAGE_PREV = 77   -- group list "Prev Page"

-- ==================== Items =========================================

local MORTAR        = 0xE9B    -- mortar and pestle (alchemy tool)
local TINKER_TOOLS  = 0x1EB8
local SAW           = 0x1034   -- carpentry tool

local POTION_KEG    = 0x1940   -- empty AND filled; the type shows as hue
local PLAIN_KEG     = 0xE7F    -- crafting part, NOT the potion keg!
local BOTTLE        = 0xF0E
local BARREL_STAVES = 0x1EB1
local BARREL_LID    = 0x1DB8
local BARREL_HOOPS  = 0x1DB7
local BARREL_TAP    = 0x1004
local LOG           = 0x1BDD
local IRON_INGOT    = 0x1BF2
local IRON_INGOT_ALT= 0x1BEF

-- Reagents
local BLACK_PEARL   = 0xF7A
local BLOODMOSS     = 0xF7B
local GARLIC        = 0xF84
local GINSENG       = 0xF85
local MANDRAKE      = 0xF86
local NIGHTSHADE    = 0xF88
local SULFUROUS_ASH = 0xF8C
local SPIDERS_SILK  = 0xF8D

local REG_NAMES = {}
REG_NAMES[BLACK_PEARL]   = 'Black Pearl'
REG_NAMES[BLOODMOSS]     = 'Bloodmoss'
REG_NAMES[GARLIC]        = 'Garlic'
REG_NAMES[GINSENG]       = 'Ginseng'
REG_NAMES[MANDRAKE]      = 'Mandrake'
REG_NAMES[NIGHTSHADE]    = 'Nightshade'
REG_NAMES[SULFUROUS_ASH] = 'Sulf. Ash'
REG_NAMES[SPIDERS_SILK]  = 'Spiders Silk'

local KEG_MAX       = 100

-- ==================== Potion table ==================================
-- grp = category button (1 + groupIndex*7), page2 = category sits on
-- the second group list page. detail/create per the formula. gfx is
-- shared inside a family (all heal potions are 0xF0C), so counting
-- always works with deltas, never absolutes. hue = the keg hue the
-- server assigns per family (informational; the server colours kegs
-- itself when they are typed).

local POTIONS = {
    { name = 'Refresh',                grp =  1, detail =  3, create =  2, gfx = 0xF0B, hue =   37, color = '#E05555', reg = BLACK_PEARL,   regs =  3, lo =   5, hi =  30 },
    { name = 'Total Refresh',          grp =  1, detail = 10, create =  9, gfx = 0xF0B, hue =   37, color = '#E05555', reg = BLACK_PEARL,   regs =  8, lo =  25, hi =  50 },
    { name = 'Agility',                grp =  8, detail =  3, create =  2, gfx = 0xF08, hue =   94, color = '#5599EE', reg = BLOODMOSS,     regs =  3, lo =  40, hi =  65 },
    { name = 'Greater Agility',        grp =  8, detail = 10, create =  9, gfx = 0xF08, hue =   94, color = '#5599EE', reg = BLOODMOSS,     regs =  8, lo =  60, hi =  85 },
    { name = 'Lesser Nightsight',      grp = 15, detail =  3, create =  2, gfx = 0xF06, hue = 1107, color = '#7788EE', reg = SPIDERS_SILK,  regs =  2, lo = -25, hi =  25 },
    { name = 'Nightsight',             grp = 15, detail = 10, create =  9, gfx = 0xF06, hue = 1107, color = '#7788EE', reg = SPIDERS_SILK,  regs =  4, lo =   0, hi =  50 },
    { name = 'Greater Nightsight',     grp = 15, detail = 17, create = 16, gfx = 0xF06, hue = 1107, color = '#7788EE', reg = SPIDERS_SILK,  regs = 10, lo =  50, hi = 100 },
    { name = 'Lesser Heal',            grp = 22, detail =  3, create =  2, gfx = 0xF0C, hue =  253, color = '#E0C040', reg = GINSENG,       regs =  1, lo =  20, hi =  40 },
    { name = 'Heal',                   grp = 22, detail = 10, create =  9, gfx = 0xF0C, hue =  253, color = '#E0C040', reg = GINSENG,       regs =  5, lo =  35, hi =  60 },
    { name = 'Greater Heal',           grp = 22, detail = 17, create = 16, gfx = 0xF0C, hue =  253, color = '#E0C040', reg = GINSENG,       regs = 10, lo =  55, hi =  80 },
    { name = 'Strength',               grp = 29, detail =  3, create =  2, gfx = 0xF09, hue =  956, color = '#DDDDDD', reg = MANDRAKE,      regs =  3, lo =  40, hi =  65 },
    { name = 'Greater Strength',       grp = 29, detail = 10, create =  9, gfx = 0xF09, hue =  956, color = '#DDDDDD', reg = MANDRAKE,      regs =  8, lo =  60, hi =  85 },
    { name = 'Lesser Poison',          grp = 36, detail =  3, create =  2, gfx = 0xF0A, hue =  363, color = '#55C055', reg = NIGHTSHADE,    regs =  3, lo =  20, hi =  40 },
    { name = 'Poison',                 grp = 36, detail = 10, create =  9, gfx = 0xF0A, hue =  363, color = '#55C055', reg = NIGHTSHADE,    regs =  5, lo =  35, hi =  65 },
    { name = 'Greater Poison',         grp = 36, detail = 17, create = 16, gfx = 0xF0A, hue =  363, color = '#55C055', reg = NIGHTSHADE,    regs = 10, lo =  60, hi =  85 },
    { name = 'Deadly Poison',          grp = 36, detail = 24, create = 23, gfx = 0xF0A, hue =  363, color = '#55C055', reg = NIGHTSHADE,    regs = 14, lo =  80, hi = 105 },
    { name = 'Lethal Poison',          grp = 36, detail = 31, create = 30, gfx = 0xF0A, hue =  363, color = '#55C055', reg = NIGHTSHADE,    regs = 20, lo = 100, hi = 125, recipe = true },
    { name = 'Lesser Cure',            grp = 43, detail =  3, create =  2, gfx = 0xF07, hue =   44, color = '#E09040', reg = GARLIC,        regs =  1, lo =  20, hi =  40 },
    { name = 'Cure',                   grp = 43, detail = 10, create =  9, gfx = 0xF07, hue =   44, color = '#E09040', reg = GARLIC,        regs =  5, lo =  35, hi =  60 },
    { name = 'Greater Cure',           grp = 43, detail = 17, create = 16, gfx = 0xF07, hue =   44, color = '#E09040', reg = GARLIC,        regs = 10, lo =  55, hi =  80 },
    { name = 'Lesser Explosion',       grp = 50, detail =  3, create =  2, gfx = 0xF0D, hue =  419, color = '#B060E0', reg = SULFUROUS_ASH, regs =  3, lo =   5, hi =  55 },
    { name = 'Explosion',              grp = 50, detail = 10, create =  9, gfx = 0xF0D, hue =  419, color = '#B060E0', reg = SULFUROUS_ASH, regs =  6, lo =  35, hi =  85 },
    { name = 'Greater Explosion',      grp = 50, detail = 17, create = 16, gfx = 0xF0D, hue =  419, color = '#B060E0', reg = SULFUROUS_ASH, regs = 12, lo =  65, hi = 115 },
    { name = 'Inflammable Oil',        grp = 57, detail =  3, create =  2, gfx = 0xFDB3, hue = 1128, color = '#E07030', reg = SULFUROUS_ASH, regs =  5, reg2 = SPIDERS_SILK, regs2 = 5, lo = 45, hi =  95, page2 = true },
    { name = 'Greater Inflammable Oil',grp = 57, detail = 10, create =  9, gfx = 0xFDB3, hue = 1128, color = '#E07030', reg = SULFUROUS_ASH, regs =  8, reg2 = SPIDERS_SILK, regs2 = 8, lo = 75, hi = 120, page2 = true, recipe = true },
}

-- ==================== Part table (keg crafting) =====================
-- tool: 'tinker' or 'saw'. All parts use the full click path (their
-- amounts are small); only potion brewing uses Make Last.

local PARTS = {
    tap    = { what = 'a barrel tap',   tool = 'tinker', grp =  8, detail = 24, create = 23, gfx = BARREL_TAP },
    hoops  = { what = 'barrel hoops',   tool = 'tinker', grp =  8, detail = 45, create = 44, gfx = BARREL_HOOPS },
    mortar = { what = 'a mortar',       tool = 'tinker', grp =  1, detail = 10, create =  9, gfx = MORTAR },
    staves = { what = 'barrel staves',  tool = 'saw',    grp =  8, detail =  3, create =  2, gfx = BARREL_STAVES },
    lid    = { what = 'a barrel lid',   tool = 'saw',    grp =  8, detail = 10, create =  9, gfx = BARREL_LID },
    keg    = { what = 'a keg',          tool = 'saw',    grp = 22, detail = 59, create = 58, gfx = PLAIN_KEG },
}

-- The potion keg itself: tinkering, "Assemblies" group on group PAGE 2.
local POTIONKEG_CRAFT = { what = 'a potion keg', tool = 'tinker', grp = 57, detail = 45, create = 44, gfx = POTION_KEG, page2 = true }

-- ==================== State =========================================

local MODES = { 'Fill kegs', 'Craft kegs', 'Craft + fill' }

local settings = {
    mode        = 1,      -- index into MODES
    craftTarget = 5,      -- kegs to craft (0 = no limit / follow the list)
    craftParts  = false,  -- build missing parts from logs/ingots
    unload      = false,  -- move finished kegs into the unload container
    restockBag  = nil,
    unloadBag   = nil,    -- also used as a SECOND restock source
    types       = {},     -- per POTIONS index: { enabled, count }
}

for i = 1, #POTIONS do
    settings.types[i] = { enabled = false, count = 1 }
end

local state = {
    running     = false,
    status      = 'Idle - press START.',
    startTime   = 0,

    queue       = nil,       -- POTIONS indices to work through (START)
    queueIdx    = 1,
    typeEntered = nil,       -- housekeeping done for this queue type
    filledThisType = 0,

    activeKeg   = nil,       -- serial of the keg we are filling
    kegStarted  = false,     -- first potion tipped in (server auto-pours now)
    craftsThisKeg = 0,       -- brews since the keg was started

    crafts      = 0,         -- brew attempts this session
    fails       = 0,         -- exact per finished keg: crafts - 100
    kegsFilled  = 0,
    kegsCrafted = 0,
    regsUsed    = 0,

    alchemySelected = false, -- full click path done, Make Last is armed
    toolKind    = nil,       -- which tool owns the open craft gump

    contCounts  = {},        -- last container scan, key "gfx:hue"
    contScan    = 0,         -- os.time of that scan

    pickRestock = false,
    pickUnload  = false,
    rescan      = false,
    lastError   = '',
}

-- UI element handles (filled in the window section). All display goes
-- through direct SetText/SetValue pushes from the main loop - the
-- window has ZERO polling bindings, every binding evaluation would run
-- a Lua snippet through the engine and that made the UI laggy.
local ui = {}

-- ==================== Small helpers =================================

local function skillNow()
    local base = Skills.GetBase('Alchemy')
    if base == nil or base == 0 then base = Skills.GetValue('Alchemy') end
    return base or 0
end

local function setStatus(text)
    state.status = text
    if ui.status ~= nil then
        ui.status:SetText(string.format('Alchemy %.1f   %s', skillNow(), text))
    end
end

local function elapsed()
    if state.startTime == 0 then return 0 end
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

local function countBp(gfx, hue)
    return Items.CountType(gfx, hue or 0) or 0
end

--- Finds an item in the BACKPACK only - FindByType would also match
--- items in the world (a deco keg on a shelf!).
local function findInBackpack(gfx, hue)
    local items = Items.FindInContainer(Player.Backpack.Serial)
    if items == nil then return nil end
    for i = 1, #items do
        local it = items[i]
        if it ~= nil and it.Graphic == gfx and (hue == nil or it.Hue == hue) then return it end
    end
    return nil
end

local function findSerialInBackpack(serial)
    local items = Items.FindInContainer(Player.Backpack.Serial)
    if items == nil then return nil end
    for i = 1, #items do
        local it = items[i]
        if it ~= nil and it.Serial == serial then return it end
    end
    return nil
end

local function ingotCount()
    return countBp(IRON_INGOT) + countBp(IRON_INGOT_ALT)
end

local function contKey(gfx, hue)
    return string.format('%d:%d', gfx, hue or 0)
end

local function contCount(gfx, hue)
    return state.contCounts[contKey(gfx, hue)] or 0
end

--- Distinct reagent graphics of all ticked types (for the overview and
--- the container scan).
local function activeRegs()
    local list, seen = {}, {}
    for i = 1, #POTIONS do
        if settings.types[i].enabled then
            local p = POTIONS[i]
            if not seen[p.reg] then
                seen[p.reg] = true
                list[#list + 1] = p.reg
            end
            if p.reg2 ~= nil and not seen[p.reg2] then
                seen[p.reg2] = true
                list[#list + 1] = p.reg2
            end
        end
    end
    return list
end

-- Backpack counts for the OVERVIEW come from this cache, refreshed once
-- per ~0.75s in the main loop. The craft logic keeps using live counts.
local bpCounts = {}
local lastCountRefresh = 0

local function bcount(gfx)
    return bpCounts[gfx] or 0
end

local function refreshCounts()
    local list = activeRegs()
    local goods = { BOTTLE, POTION_KEG, PLAIN_KEG, BARREL_LID, BARREL_TAP, BARREL_STAVES, BARREL_HOOPS, LOG, IRON_INGOT, IRON_INGOT_ALT }
    for i = 1, #goods do list[#list + 1] = goods[i] end
    for i = 1, #list do
        bpCounts[list[i]] = Items.CountType(list[i], 0) or 0
    end
end

-- ==================== Lifetime statistics (persistent) ==============

local CONFIG_NAME = 'AlchemyCrafter'

local lifetime = { potions = {}, kegsCrafted = 0 }

local function lifetimeFor(name)
    local p = lifetime.potions[name]
    if p == nil then
        p = { crafts = 0, fails = 0, kegs = 0 }
        lifetime.potions[name] = p
    end
    return p
end

local function saveStats()
    Config.Save(CONFIG_NAME, lifetime)
end

local function loadStats()
    local cfg = Config.Load(CONFIG_NAME)
    if type(cfg) ~= 'table' then return end
    lifetime.kegsCrafted = math.floor(tonumber(cfg.kegsCrafted) or 0)
    if type(cfg.potions) == 'table' then
        for name, p in pairs(cfg.potions) do
            if type(p) == 'table' then
                lifetime.potions[name] = {
                    crafts = math.floor(tonumber(p.crafts) or 0),
                    fails  = math.floor(tonumber(p.fails) or 0),
                    kegs   = math.floor(tonumber(p.kegs) or 0),
                }
            end
        end
    end
end

local function clearStats()
    lifetime = { potions = {}, kegsCrafted = 0 }
    Config.Delete(CONFIG_NAME)
end

local function printStats()
    local any = false
    for name, p in pairs(lifetime.potions) do
        any = true
        Messages.Print(string.format('%s: %d kegs, %d brews, %d failed', name, p.kegs, p.crafts, p.fails), 88)
    end
    Messages.Print(string.format('Kegs crafted %d', lifetime.kegsCrafted), 88)
    if not any and lifetime.kegsCrafted == 0 then
        Messages.Print('Alchemy Crafter: nothing recorded yet.', 88)
    end
end

loadStats()

-- ==================== Settings persistence ==========================
-- The whole window setup (mode, targets, options, containers, the
-- per-type list) survives script restarts; "Clear saved" wipes it
-- back to defaults.

local SETTINGS_CONFIG = 'AlchemyCrafterSettings'

local function saveSettings()
    local cfg = {
        mode = settings.mode,
        craftTarget = settings.craftTarget,
        craftParts = settings.craftParts,
        unload = settings.unload,
        restockBag = settings.restockBag,
        unloadBag = settings.unloadBag,
        types = {},
    }
    for i = 1, #POTIONS do
        local t = settings.types[i]
        cfg.types[i] = { enabled = t.enabled, count = t.count }
    end
    Config.Save(SETTINGS_CONFIG, cfg)
end

local function loadSettings()
    local cfg = Config.Load(SETTINGS_CONFIG)
    if type(cfg) ~= 'table' then return end

    settings.mode = math.floor(tonumber(cfg.mode) or settings.mode)
    if settings.mode < 1 or settings.mode > #MODES then settings.mode = 1 end
    settings.craftTarget = math.max(0, math.floor(tonumber(cfg.craftTarget) or settings.craftTarget))
    settings.craftParts = cfg.craftParts == true
    settings.unload = cfg.unload == true
    settings.restockBag = tonumber(cfg.restockBag)
    settings.unloadBag = tonumber(cfg.unloadBag)

    if type(cfg.types) == 'table' then
        for i = 1, #POTIONS do
            -- Depending on the JSON round-trip the index may come back
            -- as a number or a string key - accept both.
            local t = cfg.types[i]
            if type(t) ~= 'table' then t = cfg.types[tostring(i)] end
            if type(t) == 'table' then
                settings.types[i].enabled = t.enabled == true
                settings.types[i].count = math.max(1, math.floor(tonumber(t.count) or 1))
            end
        end
    end
end

loadSettings()

-- ==================== Gump plumbing =================================

local function openTool(toolSerial)
    Player.UseObject(toolSerial)
    return Gumps.WaitForGump(GUMP_ID, GUMP_WAIT_MS)
end

--- Presses a button and waits for the craft gump to come back. Waits for
--- the OLD gump to disappear first - waiting for "a gump" right away
--- would match the old one and race ahead of the server.
---
--- A Reply without a client-side gump is LOST ("Gump not found") - the
--- client may be mid-replacement between two presses, so give the gump
--- a moment to (re)appear before pressing.
local function pressAndWait(button, waitMs)
    if not Gumps.HasGump(GUMP_ID) and not Gumps.WaitForGump(GUMP_ID, 1500) then
        return false
    end

    Gumps.Reply(GUMP_ID, button)

    local waited = 0
    while Gumps.HasGump(GUMP_ID) and waited < 2000 do
        Pause(50)
        waited = waited + 50
    end

    return Gumps.WaitForGump(GUMP_ID, waitMs or GUMP_WAIT_MS)
end

--- Selects a craft category, flipping the group page when the button is
--- not on the shown page. ⚠ ANY press closes the client gump (the reply
--- machinery sends a local CloseGump) - a press the server drops leaves
--- us with NO gump at all, so the tool must be reopened before flipping.
local function selectGroup(def, toolSerial)
    if pressAndWait(def.grp, def.page2 and 3000 or GUMP_WAIT_MS) then return true end

    if not Gumps.HasGump(GUMP_ID) then
        if toolSerial == nil or not openTool(toolSerial) then return false end
    end

    local flip = def.page2 and BTN_PAGE_NEXT or BTN_PAGE_PREV
    if not pressAndWait(flip) then return false end
    return pressAndWait(def.grp)
end

-- ==================== Restock =======================================
-- Resources come from the restock container FIRST; when an unload
-- container is set it counts as a SECOND source (handy: kegs crafted
-- into it earlier feed the fill runs later).

local function sourceBags()
    local bags = {}
    if settings.restockBag ~= nil then bags[#bags + 1] = settings.restockBag end
    if settings.unloadBag ~= nil and settings.unloadBag ~= settings.restockBag then
        bags[#bags + 1] = settings.unloadBag
    end
    return bags
end

--- Opens a container so its contents are loaded client-side -
--- FindInContainer/CountTypeInContainer only see loaded containers.
local function openBag(serial)
    if serial == nil then return false end
    Player.UseObject(serial)
    Pause(800)
    return true
end

local function openRestockBag()
    return openBag(settings.restockBag)
end

--- Pulls a pile of a stackable resource out of the source containers.
local function restockStack(gfxList, want, what)
    local bags = sourceBags()

    for b = 1, #bags do
        if openBag(bags[b]) then
            for g = 1, #gfxList do
                local gfx = gfxList[g]
                local items = Items.FindInContainer(bags[b])
                if items ~= nil then
                    for i = 1, #items do
                        local it = items[i]
                        if it ~= nil and it.Graphic == gfx and it.Hue == 0 then
                            setStatus('Restocking ' .. what .. '...')
                            Player.PickUp(it.Serial, want)
                            Pause(700)
                            Player.DropInBackpack()
                            Pause(700)
                            return true
                        end
                    end
                end
            end
        end
    end

    return false
end

--- Fetches ONE item of the graphic (and hue, if given) from the source
--- containers - kegs must match hue 0, a filled keg is not "empty"!
local function restockOne(gfx, hue, what)
    local bags = sourceBags()

    for b = 1, #bags do
        if openBag(bags[b]) then
            local items = Items.FindInContainer(bags[b])
            if items ~= nil then
                for i = 1, #items do
                    local it = items[i]
                    if it ~= nil and it.Graphic == gfx and (hue == nil or it.Hue == hue) then
                        setStatus('Restocking ' .. what .. '...')
                        Player.PickUp(it.Serial, 1)
                        Pause(700)
                        Player.DropInBackpack()
                        Pause(700)
                        return true
                    end
                end
            end
        end
    end

    return false
end

-- ==================== Container resource scan =======================

--- Re-counts the tracked resources across BOTH source containers.
--- Called after restocks, keg completions and from the Rescan button.
local function rescanContainer()
    local bags = sourceBags()
    if #bags == 0 then return end

    local list = activeRegs()
    local goods = { BOTTLE, POTION_KEG, PLAIN_KEG, BARREL_LID, BARREL_TAP, BARREL_STAVES, BARREL_HOOPS, LOG, IRON_INGOT, IRON_INGOT_ALT }
    for i = 1, #goods do list[#list + 1] = goods[i] end

    for i = 1, #list do
        state.contCounts[contKey(list[i], 0)] = 0
    end

    for b = 1, #bags do
        if openBag(bags[b]) then
            for i = 1, #list do
                local key = contKey(list[i], 0)
                state.contCounts[key] = state.contCounts[key] + (Items.CountTypeInContainer(bags[b], list[i], 0) or 0)
            end
        end
    end

    state.contScan = math.floor(os.time())
end

-- ==================== Tools =========================================

local TOOL_GFX = { mortar = MORTAR, tinker = TINKER_TOOLS, saw = SAW }
local TOOL_NAME = { mortar = 'a mortar and pestle', tinker = 'tinker tools', saw = 'a saw' }

--- Finds (or restocks) the tool and makes sure ITS craft gump is open.
--- All systems share one gump id, so switching tools closes the old one.
local function useCraftTool(kind)
    local tool = findInBackpack(TOOL_GFX[kind])

    if tool == nil and restockOne(TOOL_GFX[kind], nil, TOOL_NAME[kind]) then
        tool = findInBackpack(TOOL_GFX[kind])
    end

    if tool == nil then
        state.lastError = 'No ' .. TOOL_NAME[kind] .. ' (backpack or restock container).'
        return nil
    end

    if state.toolKind ~= kind and Gumps.HasGump(GUMP_ID) then
        Gumps.Close(GUMP_ID)
        Pause(400)
    end

    if not Gumps.HasGump(GUMP_ID) then
        if not openTool(tool.Serial) then
            state.lastError = 'Craft gump did not open.'
            return nil
        end
    end

    state.toolKind = kind
    return tool
end

--- Closes the gump so the next cycle reopens it with fresh resource
--- counts - after a restock it still shows the old numbers.
local function refreshGump()
    if Gumps.HasGump(GUMP_ID) then
        Gumps.Close(GUMP_ID)
        Pause(400)
    end
end

--- START pre-flight: every tool the chosen mode needs must be in the
--- backpack or the restock container, otherwise we refuse to run and
--- name what is missing.
local function preflightTools()
    local need = {}
    if settings.mode ~= 2 then need[#need + 1] = 'mortar' end
    if settings.mode ~= 1 then need[#need + 1] = 'tinker' end
    if settings.mode ~= 1 and settings.craftParts then need[#need + 1] = 'saw' end

    local bags = sourceBags()
    local opened = {}
    local missing = ''

    for i = 1, #need do
        local kind = need[i]
        local have = findInBackpack(TOOL_GFX[kind]) ~= nil

        for b = 1, #bags do
            if have then break end
            if not opened[bags[b]] then opened[bags[b]] = openBag(bags[b]) end
            if opened[bags[b]] then
                have = (Items.CountTypeInContainer(bags[b], TOOL_GFX[kind], 0) or 0) > 0
            end
        end

        if not have then
            if missing == '' then missing = TOOL_NAME[kind] else missing = missing .. ', ' .. TOOL_NAME[kind] end
        end
    end

    if missing ~= '' then
        state.lastError = 'Missing tools: ' .. missing .. ' (put them in the backpack or the restock container).'
        return false
    end

    return true
end

-- ==================== Unloading =====================================

local function unloadKeg(kegSerial)
    if settings.unloadBag == nil then return false end

    setStatus('Unloading the keg...')
    Player.PickUp(kegSerial, 1)
    Pause(700)
    Player.DropInContainer(settings.unloadBag)
    Pause(700)

    return findSerialInBackpack(kegSerial) == nil
end

-- ==================== Part crafting =================================

--- Crafts ONE part via the full click path. Returns TWO values:
--- ok    = the click path went through (gump came back), and
--- made  = the item count actually went up.
--- ok=true/made=false is a normal server-side craft FAIL (skill roll,
--- materials lost) - callers retry it, they must NOT stop the script.
local function craftPart(def, isRetry)
    local tool = useCraftTool(def.tool)
    if tool == nil then return false, false end

    setStatus('Crafting ' .. def.what .. '...')

    local before = countBp(def.gfx)

    if not selectGroup(def, tool.Serial) then return false, false end
    if not pressAndWait(def.detail) then return false, false end
    if not pressAndWait(def.create, 15000) then
        -- A worn-out tool eats the last press without resending the gump.
        if not isRetry and findInBackpack(TOOL_GFX[def.tool]) == nil then
            return craftPart(def, true)
        end
        return false, false
    end

    return true, countBp(def.gfx) > before
end

--- Makes sure `want` items of a part are in the backpack: restock first,
--- then (with the option) craft them from raw materials.
local function ensurePart(key, want)
    local def = PARTS[key]

    local guard = 0
    while countBp(def.gfx) < want and guard < 30 do
        guard = guard + 1

        if restockOne(def.gfx, 0, def.what) then
            -- fine, count again
        elseif settings.craftParts then
            -- Raw materials for this part first.
            if def.tool == 'saw' then
                local logsNeed = (key == 'keg') and 5 or ((key == 'lid') and 4 or 5)
                if countBp(LOG) < logsNeed and not restockStack({ LOG }, 100, 'logs') then
                    state.lastError = 'Out of logs.'
                    return false
                end
            else
                local ingotsNeed = (key == 'hoops') and 10 or 4
                if ingotCount() < ingotsNeed and not restockStack({ IRON_INGOT, IRON_INGOT_ALT }, 100, 'ingots') then
                    state.lastError = 'Out of iron ingots.'
                    return false
                end
            end

            -- A keg is itself made of parts - collect those first.
            if key == 'keg' then
                if not ensurePart('staves', 3) then return false end
                if not ensurePart('hoops', 1) then return false end
                if not ensurePart('lid', 2) then return false end
            end

            local ok, made = craftPart(def)
            if not ok then
                if state.lastError == '' then state.lastError = 'Craft gump flow broke while making ' .. def.what .. '.' end
                return false
            end
            if not made then
                -- Normal failed craft roll: materials are lost, the loop
                -- restocks and simply tries again.
                setStatus('Failed ' .. def.what .. ' - trying again...')
            end
        else
            state.lastError = 'Out of ' .. def.what .. ' (enable "craft parts" or refill the container).'
            return false
        end
    end

    if countBp(def.gfx) >= want then return true end
    if state.lastError == '' then
        state.lastError = 'Could not get enough ' .. def.what .. ' after several tries.'
    end
    return false
end

--- Crafts one potion keg (tinkering): 1 keg + 10 bottles + 2 lids + 1 tap.
local function craftKegOnce()
    -- Kegs are heavy - make room before hauling in parts for another one.
    if (Player.Weight or 0) + 30 >= (Player.MaxWeight or 0) then
        if settings.mode == 2 and settings.unload then
            local fresh = findInBackpack(POTION_KEG, 0)
            if fresh == nil or not unloadKeg(fresh.Serial) then
                state.lastError = 'Too heavy and nothing to unload.'
                return false
            end
        else
            state.lastError = 'Too heavy to craft another keg.'
            return false
        end
    end

    setStatus('Collecting keg parts...')

    if countBp(BOTTLE) < 10 and not restockStack({ BOTTLE }, 30, 'bottles') then
        state.lastError = 'Out of bottles.'
        return false
    end
    if countBp(BOTTLE) < 10 then
        state.lastError = 'Out of bottles.'
        return false
    end

    if not ensurePart('keg', 1) then return false end
    if not ensurePart('lid', 2) then return false end
    if not ensurePart('tap', 1) then return false end

    refreshGump()   -- restocks above leave stale resource counts behind

    local before = countBp(POTION_KEG, 0)

    local ok, made = craftPart(POTIONKEG_CRAFT)
    if not ok then
        if state.lastError == '' then
            state.lastError = 'Craft gump flow broke while making a potion keg.'
        end
        return false
    end

    if not made then
        -- Failed roll: the parts are consumed, the next cycle collects
        -- fresh ones and tries again. This must NOT stop the script.
        setStatus('Potion keg craft failed - trying again...')
        return true
    end

    if countBp(POTION_KEG, 0) > before then
        state.kegsCrafted = state.kegsCrafted + 1
        lifetime.kegsCrafted = lifetime.kegsCrafted + 1
        saveStats()
        rescanContainer()
        setStatus(string.format('Crafted keg %d.', state.kegsCrafted))

        -- Craft-only mode: kegs would pile up in the backpack, so the
        -- unload option moves each fresh one straight into the container.
        if settings.mode == 2 and settings.unload then
            local fresh = findInBackpack(POTION_KEG, 0)
            if fresh ~= nil then unloadKeg(fresh.Serial) end
        end
    end

    return true
end

-- ==================== Keg filling ===================================

--- Makes sure an empty keg is in the backpack and remembered as the
--- active one. The type is set later by tipping the first potion in.
local function ensureActiveKeg()
    if state.activeKeg ~= nil then
        if findSerialInBackpack(state.activeKeg) ~= nil then return true end
        -- Keg left the backpack (player moved it) - start over.
        state.activeKeg = nil
        state.kegStarted = false
    end

    local keg = findInBackpack(POTION_KEG, 0)

    if keg == nil then
        -- Weight guard: a keg is heavy, leave room for it.
        if (Player.Weight or 0) + 25 >= (Player.MaxWeight or 0) then
            state.lastError = 'Too heavy to pick up another keg.'
            return false
        end
        if restockOne(POTION_KEG, 0, 'an empty potion keg') then
            keg = findInBackpack(POTION_KEG, 0)
        end
    end

    if keg == nil then
        state.lastError = 'Out of empty potion kegs.'
        return false
    end

    state.activeKeg = keg.Serial
    state.kegStarted = false
    state.craftsThisKeg = 0
    return true
end

--- Tips one brewed potion onto the active keg. Sets the keg type
--- server-side (OnDragDrop) and returns the empty bottle.
local function startKegWithPotion(p)
    local pot = findInBackpack(p.gfx, 0)
    if pot == nil then return false end

    local before = countBp(p.gfx)

    setStatus('Tipping the first potion into the keg...')
    Player.PickUp(pot.Serial, 1)
    Pause(700)
    Player.DropInContainer(state.activeKeg)
    Pause(800)

    -- Accepted = one potion fewer in the backpack (leftovers may remain).
    if countBp(p.gfx) < before then
        state.kegStarted = true
        state.craftsThisKeg = 0
        return true
    end

    return false
end

--- A finished keg: statistics, unload, advance the work list.
local function finishKeg(p, typeIdx)
    -- Between start (held 1) and full (held 100) exactly 99 brews poured,
    -- plus the one that just stayed in the backpack = 100 successes.
    local kegFails = math.max(0, state.craftsThisKeg - KEG_MAX)
    state.fails = state.fails + kegFails
    state.kegsFilled = state.kegsFilled + 1
    state.filledThisType = state.filledThisType + 1

    local lt = lifetimeFor(p.name)
    lt.kegs = lt.kegs + 1
    lt.crafts = lt.crafts + state.craftsThisKeg
    lt.fails = lt.fails + kegFails
    saveStats()

    local kegSerial = state.activeKeg

    if settings.unload then unloadKeg(kegSerial) end

    state.activeKeg = nil
    state.kegStarted = false
    state.craftsThisKeg = 0

    if state.filledThisType >= math.max(1, settings.types[typeIdx].count) then
        state.queueIdx = state.queueIdx + 1
    end

    rescanContainer()
    setStatus(string.format('%s keg %d full!', p.name, state.filledThisType))
end

--- Stows family potions away before a type starts - all tiers of a
--- family share one bottle graphic, a foreign potion would type the
--- keg wrongly and the fill loop would never see it pour.
local function stashFamilyPotions(p)
    if countBp(p.gfx) == 0 then return true end

    if settings.restockBag == nil then
        state.lastError = p.name .. ': family potions in the backpack - set a restock container so I can stash them.'
        return false
    end

    setStatus('Stashing leftover potions...')
    local guard = 0
    while countBp(p.gfx) > 0 and guard < 20 do
        guard = guard + 1
        local pot = findInBackpack(p.gfx, 0)
        if pot == nil then break end
        Player.PickUp(pot.Serial, 100)
        Pause(700)
        Player.DropInContainer(settings.restockBag)
        Pause(700)
    end

    return countBp(p.gfx) == 0
end

--- One brewing cycle for the current work list type. Returns true when
--- the loop may continue.
local function brewOnce()
    local typeIdx = state.queue[state.queueIdx]
    if typeIdx == nil then return false end
    local p = POTIONS[typeIdx]

    -- First visit of this type: clean slate for the family graphic.
    if state.typeEntered ~= typeIdx then
        if skillNow() < p.lo then
            state.lastError = string.format('%s needs at least %d skill.', p.name, p.lo)
            return false
        end
        if not stashFamilyPotions(p) then
            if state.lastError == '' then state.lastError = 'Could not stash leftover potions.' end
            return false
        end
        state.typeEntered = typeIdx
        state.filledThisType = 0
        state.alchemySelected = false
        state.activeKeg = nil
        state.kegStarted = false
    end

    -- Reagents first: enough for the brew plus a margin.
    local need = p.regs
    local didRestock = false
    if countBp(p.reg) < need then
        didRestock = true
        if not restockStack({ p.reg }, math.max(need * 25, 100), REG_NAMES[p.reg]) or countBp(p.reg) < need then
            state.lastError = 'Out of ' .. REG_NAMES[p.reg] .. '.'
            return false
        end
    end
    if p.reg2 ~= nil and countBp(p.reg2) < p.regs2 then
        didRestock = true
        if not restockStack({ p.reg2 }, math.max(p.regs2 * 25, 100), REG_NAMES[p.reg2]) or countBp(p.reg2) < p.regs2 then
            state.lastError = 'Out of ' .. REG_NAMES[p.reg2] .. '.'
            return false
        end
    end

    -- A few bottles: brewing is bottle-neutral while pouring into a keg
    -- (the keg hands the bottle back), but we need a small buffer.
    if countBp(BOTTLE) < 2 then
        didRestock = true
        if not restockStack({ BOTTLE }, 20, 'bottles') or countBp(BOTTLE) < 1 then
            state.lastError = 'Out of bottles.'
            return false
        end
    end

    if didRestock then
        rescanContainer()
        refreshGump()
    end

    if not ensureActiveKeg() then return false end

    -- A leftover potion of THIS type (from the keg-full signal) starts
    -- the next keg without brewing a fresh one.
    if not state.kegStarted and countBp(p.gfx) > 0 then
        if not startKegWithPotion(p) then
            state.lastError = 'The keg refused the potion.'
            return false
        end
        return true
    end

    local mortar = useCraftTool('mortar')
    if mortar == nil and settings.craftParts then
        -- Mortars are a tinkering item - build one when allowed to.
        if ingotCount() < 3 then restockStack({ IRON_INGOT, IRON_INGOT_ALT }, 100, 'ingots') end
        local ok, made = craftPart(PARTS.mortar)
        if made then
            state.lastError = ''
            mortar = useCraftTool('mortar')
        elseif ok then
            -- Failed roll, ingots lost - try again next cycle.
            state.lastError = ''
            setStatus('Mortar craft failed - trying again...')
            return true
        end
    end
    if mortar == nil then return false end

    local before = countBp(p.gfx)

    local goal = math.max(1, settings.types[typeIdx].count)
    setStatus(string.format('Brewing %s... (keg %d/%d)', p.name, state.filledThisType + 1, goal))

    if not state.alchemySelected then
        if not selectGroup(p, mortar.Serial) then
            setStatus('Category did not open.')
            return false
        end
        if not pressAndWait(p.detail) then return false end
        if not pressAndWait(p.create, 15000) then
            if findInBackpack(MORTAR) == nil then
                setStatus('Mortar worn out - getting a new one...')
                return true
            end
            setStatus('Craft gump did not come back.')
            return false
        end
        state.alchemySelected = true
    else
        if not pressAndWait(BTN_MAKE_LAST, 15000) then
            if findInBackpack(MORTAR) == nil then
                setStatus('Mortar worn out - getting a new one...')
                return true
            end
            setStatus('Craft gump did not come back.')
            return false
        end
    end

    state.crafts = state.crafts + 1
    state.regsUsed = state.regsUsed + need
    if state.kegStarted then
        state.craftsThisKeg = state.craftsThisKeg + 1
    end

    local after = countBp(p.gfx)

    if after > before then
        -- The potion stayed in the backpack: either the keg is not started
        -- yet (first brew) or it stopped taking potions = full.
        if not state.kegStarted then
            if not startKegWithPotion(p) then
                state.lastError = 'The keg refused the potion.'
                return false
            end
        else
            finishKeg(p, typeIdx)
        end
    end
    -- Otherwise the potion was poured into the keg (or the brew failed
    -- and only cost reagents) - nothing to do, the counter estimates it.

    return true
end

-- ==================== Window ========================================

local win = UI.Window('Alchemy Crafter', 120, 120)

ui.status = win:Label('Alchemy - Idle - press START.')

win:Separator()

-- Mode as a radio row of checkboxes that clear each other.
local modeBoxes = {}
local modeRow = win:Row()
for i, label in ipairs(MODES) do
    local box
    box = modeRow:Checkbox(label, i == settings.mode, function(checked)
        if state.running then
            box:SetChecked(i == settings.mode)
            return
        end
        if checked then
            settings.mode = i
            for j, other in ipairs(modeBoxes) do
                if j ~= i then other:SetChecked(false) end
            end
        else
            if settings.mode == i then box:SetChecked(true) end
        end
    end)
    modeBoxes[i] = box
end

local craftRow = win:Row()
craftRow:Label('Kegs to craft:')
local craftBox = craftRow:TextBox(tostring(settings.craftTarget), function(text)
    local n = math.floor(tonumber(text) or -1)
    if n >= 0 then settings.craftTarget = n end
end)
craftBox:SetWidth(40)
craftRow:Label('(0 = no limit; fill amounts come from the list)')

local partsChk = win:Checkbox('Craft missing parts from logs/ingots (carpentry + tinkering)', settings.craftParts, function(checked)
    settings.craftParts = checked
end)

local optRow = win:Row()
local unloadChk = optRow:Checkbox('Unload full kegs to:', settings.unload, function(checked)
    settings.unload = checked
end)
optRow:Button('Set container', function()
    state.pickUnload = true
end)
ui.unloadLbl = optRow:Label(settings.unloadBag ~= nil and string.format('0x%X', math.floor(settings.unloadBag)) or 'not set')

local bagRow = win:Row()
bagRow:Button('Set restock container', function()
    state.pickRestock = true
end)
ui.restockLbl = bagRow:Label(settings.restockBag ~= nil and string.format('0x%X', math.floor(settings.restockBag)) or 'not set')
bagRow:Button('Rescan', function()
    state.rescan = true
end)

win:Separator()

-- ==================== Keg type work list ============================
-- Three types per row: tick it, set the amount (small box). The keg
-- colour comes from the server automatically (hue per potion type).

ui.typeChecks = {}
ui.typeBoxes = {}

local function addTypeCell(row, i)
    local p = POTIONS[i]
    local t = settings.types[i]

    local chk = row:Checkbox(p.name, t.enabled, function(checked)
        settings.types[i].enabled = checked
    end)
    chk:SetWidth(148)
    ui.typeChecks[i] = chk

    local box = row:TextBox(tostring(t.count), function(text)
        local n = math.floor(tonumber(text) or 0)
        if n >= 1 then settings.types[i].count = n end
    end)
    box:SetWidth(30)
    ui.typeBoxes[i] = box
end

for base = 1, #POTIONS, 3 do
    local row = win:Row()
    for off = 0, 2 do
        if base + off <= #POTIONS then addTypeCell(row, base + off) end
    end
end

win:Separator()

-- ==================== Overview (pushed, no bindings) ================

ui.regs    = win:Label('Reagents: -')
ui.goods   = win:Label('Bottles: -   Empty kegs: -')
ui.parts1  = win:Label('Kegs(part): -   Lids: -   Taps: -')
ui.parts2  = win:Label('Staves: -   Hoops: -   Logs: -   Ingots: -')
ui.scan    = win:Label('Container: not scanned yet')

win:Separator()

ui.keg     = win:Label('Keg: -')
ui.kegBar  = win:ProgressBar()
ui.stats1  = win:Label('Brews 0   failed 0   regs used 0')
ui.stats2  = win:Label('Kegs: filled 0   crafted 0')
ui.runtime = win:Label('Runtime 0:00')

--- Wipes the saved settings and puts every control back to defaults
--- (SetChecked/SetText do not fire the callbacks, so settings and UI
--- are reset side by side).
local function resetSettings()
    Config.Delete(SETTINGS_CONFIG)

    settings.mode = 1
    settings.craftTarget = 5
    settings.craftParts = false
    settings.unload = false
    settings.restockBag = nil
    settings.unloadBag = nil

    for j, box in ipairs(modeBoxes) do box:SetChecked(j == 1) end
    craftBox:SetText('5')
    partsChk:SetChecked(false)
    unloadChk:SetChecked(false)
    ui.restockLbl:SetText('not set')
    ui.unloadLbl:SetText('not set')

    for i = 1, #POTIONS do
        settings.types[i].enabled = false
        settings.types[i].count = 1
        ui.typeChecks[i]:SetChecked(false)
        ui.typeBoxes[i]:SetText('1')
    end

    setStatus('Saved settings cleared.')
end

local statsRow = win:Row()
statsRow:Button('Print stats', printStats)
statsRow:Button('Clear stats', function()
    clearStats()
    Messages.Print('Alchemy Crafter stats cleared.', 88)
end)
statsRow:Button('Clear saved settings', function()
    if state.running then
        Messages.Print('Alchemy Crafter: stop the script before clearing the settings.', 33)
        return
    end
    resetSettings()
    Messages.Print('Alchemy Crafter settings cleared.', 88)
end)

win:Separator()

local controlRow = win:Row()
local startButton

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

    local wantsFill = settings.mode ~= 2

    -- Build the work list from the ticked types, top to bottom.
    local queue = {}
    for i = 1, #POTIONS do
        if settings.types[i].enabled and settings.types[i].count >= 1 then
            queue[#queue + 1] = i
        end
    end

    if wantsFill and #queue == 0 then
        Messages.Print('Alchemy Crafter: tick at least one keg type in the list.', 33)
        return
    end

    state.queue = queue
    state.queueIdx = 1
    state.typeEntered = nil
    state.filledThisType = 0
    state.crafts = 0
    state.fails = 0
    state.kegsFilled = 0
    state.kegsCrafted = 0
    state.regsUsed = 0
    state.craftsThisKeg = 0
    state.activeKeg = nil
    state.kegStarted = false
    state.alchemySelected = false
    state.toolKind = nil
    state.lastError = ''
    state.startTime = os.time()

    saveSettings()

    -- Tools are verified in the main loop (opening the restock container
    -- pauses - that must not happen inside a button callback).
    state.preflight = true
    setStatus('Checking tools...')
end)

controlRow:Button('Close', function()
    setRunning(false)
    win:Close()
end)

win:OnClose(function()
    state.running = false
    saveStats()
    saveSettings()
    Gumps.Close(GUMP_ID)
end)

-- ==================== Display push ==================================
-- Everything below writes straight into the window model (SetText /
-- SetValue) - visible within the host's next 100ms sync, no Lua
-- binding machinery involved.

local function updateUi()
    ui.status:SetText(string.format('Alchemy %.1f   %s', skillNow(), state.status))

    local regList = activeRegs()
    if #regList == 0 then
        ui.regs:SetText('Reagents: tick a keg type below')
    else
        local text = ''
        for i = 1, #regList do
            local gfx = regList[i]
            local part = string.format('%s: %d / %d', REG_NAMES[gfx], bcount(gfx), contCount(gfx))
            if text == '' then text = part else text = text .. '   ' .. part end
        end
        ui.regs:SetText(text)
    end

    ui.goods:SetText(string.format('Bottles: %d / %d   Empty kegs: %d / %d', bcount(BOTTLE), contCount(BOTTLE), bcount(POTION_KEG), contCount(POTION_KEG)))
    ui.parts1:SetText(string.format('Kegs(part): %d / %d   Lids: %d / %d   Taps: %d / %d', bcount(PLAIN_KEG), contCount(PLAIN_KEG), bcount(BARREL_LID), contCount(BARREL_LID), bcount(BARREL_TAP), contCount(BARREL_TAP)))
    ui.parts2:SetText(string.format('Staves: %d / %d   Hoops: %d / %d   Logs: %d / %d   Ingots: %d / %d', bcount(BARREL_STAVES), contCount(BARREL_STAVES), bcount(BARREL_HOOPS), contCount(BARREL_HOOPS), bcount(LOG), contCount(LOG), bcount(IRON_INGOT) + bcount(IRON_INGOT_ALT), contCount(IRON_INGOT) + contCount(IRON_INGOT_ALT)))

    if state.contScan == 0 then
        ui.scan:SetText('Container: not scanned yet (set container + Rescan)')
    else
        ui.scan:SetText('Container scanned ' .. formatTime(math.floor(os.time()) - state.contScan) .. ' ago')
    end

    if state.activeKeg == nil then
        ui.keg:SetText('Keg: -')
        ui.kegBar:SetValue(0)
    elseif not state.kegStarted then
        ui.keg:SetText('Keg: empty (waiting for the first potion)')
        ui.kegBar:SetValue(0)
    else
        local est = math.min(KEG_MAX, 1 + state.craftsThisKeg)
        ui.keg:SetText(string.format('Keg: ~%d/%d (crafting estimate)', est, KEG_MAX))
        ui.kegBar:SetValue(math.min(1, est / KEG_MAX))
    end

    ui.stats1:SetText(string.format('Brews %d   failed %d   regs used %d', state.crafts, state.fails, math.floor(state.regsUsed)))
    ui.stats2:SetText(string.format('Kegs: filled %d   crafted %d', state.kegsFilled, state.kegsCrafted))

    local secs = elapsed()
    local perHour = 0
    if secs >= 60 then perHour = state.crafts / (secs / 3600) end
    ui.runtime:SetText(string.format('Runtime %s   %.0f brews/h', formatTime(secs), perHour))
end

-- ==================== Main loop =====================================

if Player.Backpack == nil then
    Messages.Print('Alchemy Crafter: no backpack - are you logged in?', 33)
    return
end

Messages.Print('Alchemy Crafter: tick keg types, set containers, press START.', 68)

--- Target picks block the loop, so they run here (never in a callback)
--- and flush the status label once beforehand.
local function pickSerial(prompt)
    Messages.Print(prompt, 68)
    Pause(400)
    UI.Pump()
    local serial = Targeting.GetNewTarget(20000)
    if serial ~= nil and serial ~= 0 then return serial end
    return nil
end

refreshCounts()
updateUi()

while win:IsOpen() do
    UI.Pump()

    -- One batched refresh for counts + all display labels.
    if os.time() - lastCountRefresh >= 0.75 then
        lastCountRefresh = os.time()
        refreshCounts()
        updateUi()
    end

    if state.pickRestock then
        state.pickRestock = false
        setStatus('Waiting for the restock container...')
        local serial = pickSerial('Target the container holding your reagents, bottles, kegs and parts.')
        if serial ~= nil then
            settings.restockBag = serial
            ui.restockLbl:SetText(string.format('0x%X', math.floor(serial)))
            saveSettings()
            setStatus('Restock container set.')
            rescanContainer()
        else
            setStatus('No container picked.')
        end
    end

    if state.pickUnload then
        state.pickUnload = false
        setStatus('Waiting for the unload container...')
        local serial = pickSerial('Target the container that should receive the full kegs.')
        if serial ~= nil then
            settings.unloadBag = serial
            ui.unloadLbl:SetText(string.format('0x%X', math.floor(serial)))
            saveSettings()
            setStatus('Unload container set.')
        else
            setStatus('No container picked.')
        end
    end

    if state.rescan then
        state.rescan = false
        setStatus('Scanning the restock container...')
        rescanContainer()
        setStatus(settings.restockBag ~= nil and 'Container scanned.' or 'Set a restock container first.')
    end

    if state.preflight then
        state.preflight = false
        if preflightTools() then
            setRunning(true)
            setStatus('Running...')
        else
            setStatus('Not started - ' .. state.lastError)
            Messages.Print('Alchemy Crafter: ' .. state.lastError, 33)
        end
    end

    if state.running then
        local mode = settings.mode

        local craftGoal = settings.craftTarget
        if mode == 3 and craftGoal == 0 and state.queue ~= nil then
            -- Craft as many kegs as the work list wants to fill.
            craftGoal = 0
            for i = 1, #state.queue do
                craftGoal = craftGoal + math.max(1, settings.types[state.queue[i]].count)
            end
        end

        -- In craft-only mode a goal of 0 means "until parts run out".
        local wantCraft = (mode == 2 or mode == 3) and (craftGoal == 0 or state.kegsCrafted < craftGoal)
        local wantFill = (mode == 1 or mode == 3) and state.queue ~= nil and state.queueIdx <= #state.queue

        if wantCraft then
            if not craftKegOnce() then
                setRunning(false)
                if state.lastError ~= '' then
                    setStatus('Stopped - ' .. state.lastError)
                    Messages.Print('Alchemy Crafter: ' .. state.lastError, 33)
                end
            end
        elseif wantFill then
            if not brewOnce() then
                setRunning(false)
                if state.lastError ~= '' then
                    setStatus('Stopped - ' .. state.lastError)
                    Messages.Print('Alchemy Crafter: ' .. state.lastError, 33)
                end
            end
        else
            setRunning(false)
            setStatus('Done - work list finished!')
            Messages.Print('Alchemy Crafter: work list finished.', 68)
        end

        updateUi()
    else
        Pause(200)
    end
end

Gumps.Close(GUMP_ID)
Messages.Print('Alchemy Crafter closed.', 68)
