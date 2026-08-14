-- @name        Runebook Copier
-- @author      3HMonkey
-- @version     1.0.0
-- @tags        utility, magery
-- @description Copies a runebook into one or more target books: recalls
--              to every entry, marks fresh runes on the spot (one per
--              target book), names them like the original and drops
--              them in. Resumes automatically by comparing entry names.

----------------------------------------------------------------------
--  Runebook Copier
--
--  Pick the SOURCE book to copy, a HOME book that contains an entry
--  named "home" (any case), a RESOURCE container with reagents and
--  blank runes, and one or more TARGET books. Blank runes can live in
--  their own container ("Rune container", optional). Everything -
--  source, home and target books - must be in your backpack, and both
--  containers must be reachable at your home spot. Press START.
--
--  For every source entry the script recalls there once and marks one
--  rune per target book (so three copies = three marks per stop, not
--  three separate trips), renames each rune to the original entry
--  name via the server prompt and drops it into its target book.
--
--  Resume: at START the target books are read and entries that already
--  carry a source name are skipped - an interrupted run just continues
--  where it stopped.
--
--  ⚠ Put only BLANK runes into the resource container - a marked
--  Felucca rune looks identical to a blank one (same graphic, hue 0)
--  and the script cannot tell them apart.
--
--  Travel needs 11 mana (charges AND magery), marking needs 20 mana
--  and magery 50+; the script meditates when mana runs low. The reg
--  reserve keeps a safety stock of Black Pearl / Bloodmoss / Mandrake
--  in your pack - below reserve + trip cost it recalls home and
--  restocks instead of stranding you.
--
--  Restocking takes runes for the whole remaining job (as many as the
--  open slots in your target books need), not one per trip.
--
--  Needs Razor 0.7+ (server prompts + raw gump texts). Settings persist
--  (Config 'RunebookCopierSettings'), lifetime stats too.
----------------------------------------------------------------------

-- ==================== Runebook gump (measured on Sagas) =============
-- The runebook gump is a DynamicGump: the server does NOT validate its
-- button ids, so any entry button can be sent directly. Formula
-- 2 + index*6 + type; type 0 = travel by book charge (no skill, no
-- regs, no fizzle, 11 mana), 3 = recall by magery (spell 31, regs,
-- 11 mana), 1 = drop rune, 2 = set default. Button 0 closes.
--
-- ⚠ Openers trap: the server only forgets that a player has the book
-- open when it receives a gump RESPONSE - dropping a rune into a book
-- that still counts as open fails (1005571). So books are always
-- closed with Reply(id, 0), never with the client-side Gumps.Close.

local RUNEBOOK_GUMP = 0x594FE266
local RUNEBOOK      = 0x22C5
local RUNE          = 0x1F14

local BLACK_PEARL   = 0xF7A
local BLOODMOSS     = 0xF7B
local MANDRAKE      = 0xF86

local REGS = { { BLACK_PEARL, 'Black Pearl' }, { BLOODMOSS, 'Bloodmoss' }, { MANDRAKE, 'Mandrake' } }

local MANA_RECALL   = 11
local MANA_MARK     = 20
local BOOK_DELAY_S  = 3      -- server: 2.5s recharge after every book travel

local function BTN(index, typ)
    return 2 + index * 6 + typ
end

local TRAVEL_MODES = { 'Charges', 'Magery', 'Charges, then Magery' }
local FAIL_MODES = { 'Skip + report', 'Stop' }

-- ==================== Settings / state ==============================

local settings = {
    travelMode  = 3,
    regReserve  = 5,
    onFail      = 1,
    recallLow   = true,   -- recall home + stop below hpPct
    hpPct       = 50,
    cure        = true,
    heal        = true,
    sourceBook  = nil,
    homeBook    = nil,
    resourceBag = nil,
    runeBag     = nil,    -- optional; blank runes come from here instead
    targets     = {},     -- runebook serials
}

local state = {
    running     = false,
    preflight   = false,
    status      = 'Idle - press START.',
    startTime   = 0,
    lastTravel  = 0,

    homeIdx     = nil,     -- server index of the "home" entry
    work        = nil,     -- { {idx, name, books={serials}}, ... }
    workIdx     = 1,
    runeNo      = 0,       -- progress within the current entry
    have        = {},      -- bookSerial -> { [name]=true }
    free        = {},      -- bookSerial -> free slots
    blankRunes  = {},      -- serials fetched from the resource container

    copied      = 0,
    marked      = 0,
    skipped     = {},      -- { {name=..., reason=...}, ... }
    regsUsed    = 0,
    sourceCharges = -1,

    pickSource  = false,
    pickHome    = false,
    pickBag     = false,
    pickRuneBag = false,
    pickTarget  = false,
    lastError   = '',
}

local ui = {}

-- ==================== Small helpers =================================

local function setStatus(text)
    state.status = text
    if ui.status ~= nil then ui.status:SetText(text) end
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

local function countBp(gfx)
    return Items.CountType(gfx, 0) or 0
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

local function hpPct()
    local max = Player.HitsMax or 0
    if max <= 0 then return 100 end
    return (Player.Hits or 0) / max * 100
end

local function mageryBase()
    local base = Skills.GetBase('Magery')
    if base == nil or base == 0 then base = Skills.GetValue('Magery') end
    return base or 0
end

-- Overview cache (counts pushed to the labels from the main loop).
local contCounts = {}
local lastCountRefresh = 0

--- Blank runes come from the rune container when one is set, otherwise
--- from the resource container.
local function runeSource()
    if settings.runeBag ~= nil then return settings.runeBag end
    return settings.resourceBag
end

local function refreshCounts()
    if settings.resourceBag ~= nil then
        for i = 1, #REGS do
            contCounts[REGS[i][1]] = Items.CountTypeInContainer(settings.resourceBag, REGS[i][1], 0) or 0
        end
    end
    local bag = runeSource()
    if bag ~= nil then
        contCounts[RUNE] = Items.CountTypeInContainer(bag, RUNE, 0) or 0
    end
end

-- ==================== Persistence ===================================

local STATS_CONFIG = 'RunebookCopier'
local SETTINGS_CONFIG = 'RunebookCopierSettings'

local lifetime = { entriesCopied = 0, runesMarked = 0 }

local function saveStats()
    Config.Save(STATS_CONFIG, lifetime)
end

local function loadStats()
    local cfg = Config.Load(STATS_CONFIG)
    if type(cfg) ~= 'table' then return end
    lifetime.entriesCopied = math.floor(tonumber(cfg.entriesCopied) or 0)
    lifetime.runesMarked = math.floor(tonumber(cfg.runesMarked) or 0)
end

local function clearStats()
    lifetime = { entriesCopied = 0, runesMarked = 0 }
    Config.Delete(STATS_CONFIG)
end

local function saveSettings()
    local cfg = {
        travelMode = settings.travelMode,
        regReserve = settings.regReserve,
        onFail = settings.onFail,
        recallLow = settings.recallLow,
        hpPct = settings.hpPct,
        cure = settings.cure,
        heal = settings.heal,
        sourceBook = settings.sourceBook,
        homeBook = settings.homeBook,
        resourceBag = settings.resourceBag,
        runeBag = settings.runeBag,
        targets = {},
    }
    for i = 1, #settings.targets do cfg.targets[i] = settings.targets[i] end
    Config.Save(SETTINGS_CONFIG, cfg)
end

local function loadSettings()
    local cfg = Config.Load(SETTINGS_CONFIG)
    if type(cfg) ~= 'table' then return end

    settings.travelMode = math.floor(tonumber(cfg.travelMode) or settings.travelMode)
    if settings.travelMode < 1 or settings.travelMode > 3 then settings.travelMode = 3 end
    settings.regReserve = math.max(0, math.floor(tonumber(cfg.regReserve) or 5))
    settings.onFail = math.floor(tonumber(cfg.onFail) or 1)
    if settings.onFail < 1 or settings.onFail > 2 then settings.onFail = 1 end
    settings.recallLow = cfg.recallLow == true
    settings.hpPct = math.max(1, math.floor(tonumber(cfg.hpPct) or 50))
    settings.cure = cfg.cure == true
    settings.heal = cfg.heal == true
    settings.sourceBook = tonumber(cfg.sourceBook)
    settings.homeBook = tonumber(cfg.homeBook)
    settings.resourceBag = tonumber(cfg.resourceBag)
    settings.runeBag = tonumber(cfg.runeBag)

    if type(cfg.targets) == 'table' then
        for i = 1, 8 do
            local v = cfg.targets[i]
            if v == nil then v = cfg.targets[tostring(i)] end
            local serial = tonumber(v)
            if serial ~= nil then settings.targets[#settings.targets + 1] = serial end
        end
    end
end

loadStats()
loadSettings()

-- ==================== Runebook access ===============================

--- Closes the runebook gump SERVER-side (Reply 0) - see Openers trap.
local function closeBook()
    if Gumps.HasGump(RUNEBOOK_GUMP) then
        Gumps.Reply(RUNEBOOK_GUMP, 0)
        Pause(400)
    end
end

--- Opens a runebook and returns its gump texts (nil on failure).
--- Respects the 2.5s recharge after a book travel.
local function openBook(serial)
    closeBook()

    local since = os.time() - state.lastTravel
    if state.lastTravel > 0 and since < BOOK_DELAY_S then
        Pause(math.floor((BOOK_DELAY_S - since) * 1000) + 100)
    end

    Player.UseObject(serial)
    if not Gumps.WaitForGump(RUNEBOOK_GUMP, 5000) then return nil end

    local gump = Gumps.GetGump(RUNEBOOK_GUMP)
    if gump == nil then return nil end

    -- RawTexts = only the strings the SERVER wrote, in its order. Texts
    -- puts every resolved cliloc in front of them ("Drop rune", "Set
    -- default", ... from the detail pages), which makes positional
    -- reading impossible. Needs Razor 0.7+.
    return gump.RawTexts
end

--- Parses the raw gump strings. The server writes them in this order:
--- [1] charges, [2] max charges, [3..18] the 16 index entries
--- ("Empty" for a free slot), then the detail pages (ignored).
local function parseBook(texts)
    if texts == nil or #texts < 18 then return nil end

    local book = { charges = math.floor(tonumber(texts[1]) or 0), entries = {} }
    for i = 1, 16 do
        local name = texts[2 + i]
        if name ~= nil and name ~= '' and name ~= 'Empty' then
            book.entries[i] = name
        end
    end
    return book
end

--- Opens + parses in one go; always leaves the gump CLOSED server-side.
local function readBook(serial)
    local texts = openBook(serial)
    if texts == nil then return nil end
    local book = parseBook(texts)
    closeBook()
    return book
end

-- ==================== Mana / safety =================================

--- Meditates when (and only when) the mana for the next spell is
--- missing. Once it starts it fills up completely - that saves a lot of
--- short meditation stops on a long copy run. Pattern taken from the
--- Magery Trainer in the script library (500ms poll, stagnation retry,
--- 2 minute timeout).
local MEDITATE_RETRY_MS   = 500
local MEDITATE_TIMEOUT_MS = 120000

local function ensureMana(need)
    if (Player.Mana or 0) >= need then return true end

    setStatus('Not enough mana - meditating...')
    Journal.Clear()
    Skills.Use('Meditation')

    local waited = 0
    local lastMana = Player.Mana or 0
    local stagnant = 0
    local maxMana = Player.MaxMana or need

    while (Player.Mana or 0) < maxMana do
        Pause(MEDITATE_RETRY_MS)
        waited = waited + MEDITATE_RETRY_MS
        if waited >= MEDITATE_TIMEOUT_MS then break end

        local m = Player.Mana or 0
        if m <= lastMana then
            stagnant = stagnant + 1
            if stagnant >= 6 then
                Journal.Clear()
                Skills.Use('Meditation')
                stagnant = 0
            end
        else
            stagnant = 0
        end
        lastMana = m

        -- Enough for the next spell and meditation stalled? Move on.
        if m >= need and stagnant >= 3 then break end
    end

    return (Player.Mana or 0) >= need
end

local function castOnSelf(spell)
    Journal.Clear()
    Spells.Cast(spell)
    if Target.WaitForTarget(4000) then
        Target.Self()
    end
    Pause(1200)
end

--- Cure/heal per the options. Returns false when the script should
--- bail out (health stays low and the recall-home option is on) -
--- the caller stops after travelHome.
local function safetyOk()
    if settings.cure and Player.IsPoisoned then
        setStatus('Poisoned - curing...')
        local guard = 0
        while Player.IsPoisoned and guard < 3 do
            guard = guard + 1
            if not ensureMana(11) then break end
            castOnSelf('Cure')
        end
    end

    if settings.heal then
        local guard = 0
        while hpPct() < settings.hpPct and guard < 4 do
            guard = guard + 1
            setStatus('Healing...')
            if not ensureMana(12) then break end
            if mageryBase() >= 60 then castOnSelf('Greater Heal') else castOnSelf('Heal') end
        end
    end

    if settings.recallLow and hpPct() < settings.hpPct then
        return false
    end

    return true
end

-- ==================== Travel ========================================

local TRAVEL_ERRORS = {
    'not allowed to travel', 'cannot teleport', 'location is blocked',
    'criminal', 'heat of battle', 'too encumbered', 'another facet',
    'do not have that spell', 'no charges left', 'not yet recovered',
    'More reagents are needed', 'Insufficient mana',
}

local function travelJournalError()
    for i = 1, #TRAVEL_ERRORS do
        if Journal.Contains(TRAVEL_ERRORS[i]) then return TRAVEL_ERRORS[i] end
    end
    return nil
end

--- Travels via a runebook entry. Returns ok, err. 'already there'
--- (no movement, no error) counts as ok.
local function pressTravel(bookSerial, entryIdx)
    local texts = openBook(bookSerial)
    if texts == nil then return false, 'book gump did not open' end

    local book = parseBook(texts)
    if bookSerial == settings.sourceBook and book ~= nil then
        state.sourceCharges = book.charges
    end

    local btnType = 3
    if settings.travelMode == 1 then
        if book == nil or book.charges < 1 then
            closeBook()
            return false, 'no book charges left'
        end
        btnType = 0
    elseif settings.travelMode == 3 then
        if book ~= nil and book.charges > 0 then btnType = 0 else btnType = 3 end
    end

    if not ensureMana(MANA_RECALL + 2) then
        closeBook()
        return false, 'not enough mana'
    end

    Journal.Clear()
    local x0, y0 = Player.X, Player.Y

    -- The reply closes the gump on both sides and starts the travel.
    Gumps.Reply(RUNEBOOK_GUMP, BTN(entryIdx, btnType))
    if btnType == 3 then state.regsUsed = state.regsUsed + 1 end

    local waited = 0
    while waited < 8000 do
        Pause(250)
        waited = waited + 250

        if Player.X ~= x0 or Player.Y ~= y0 then
            state.lastTravel = os.time()
            Pause(1200)
            return true
        end

        local err = travelJournalError()
        if err ~= nil then
            state.lastTravel = os.time()
            return false, err
        end
        if Journal.Contains('The spell fizzles') then
            state.lastTravel = os.time()
            return false, 'fizzle'
        end
    end

    -- No movement and no error: most likely already standing there.
    state.lastTravel = os.time()
    return true
end

local RETRYABLE = { ['fizzle'] = true, ['not enough mana'] = true, ['Insufficient mana'] = true, ['not yet recovered'] = true, ['book gump did not open'] = true }

local function travelTo(bookSerial, entryIdx, what)
    for attempt = 1, 3 do
        setStatus('Traveling to ' .. what .. (attempt > 1 and (' (retry ' .. (attempt - 1) .. ')') or '') .. '...')
        local ok, err = pressTravel(bookSerial, entryIdx)
        if ok then return true end
        if not RETRYABLE[err or ''] and attempt >= 2 then return false, err end
        Pause(1200)
    end
    return false, 'travel kept failing'
end

local function travelHome()
    local ok, err = travelTo(settings.homeBook, state.homeIdx, 'home')
    if not ok then
        setStatus('Could not recall home (' .. (err or '?') .. ')!')
        return false
    end
    return true
end

-- ==================== Supplies ======================================

--- A MARKED rune carries "a recall rune for <place>" in its tooltip; a
--- blank one has no such line. On Felucca both look identical (same
--- graphic, hue 0), so the tooltip is the only way to tell them apart.
local function isMarkedRune(it)
    local props = it.Properties
    if props ~= nil and string.find(props, 'recall rune for', 1, true) ~= nil then return true end
    local name = it.Name
    if name ~= nil and string.find(name, 'recall rune for', 1, true) ~= nil then return true end
    return false
end

local function knowsRune(it)
    if it.Properties ~= nil and it.Properties ~= '' then return true end
    if it.Name ~= nil and it.Name ~= '' then return true end
    return false
end

local function isPooled(serial)
    for i = 1, #state.blankRunes do
        if state.blankRunes[i] == serial then return true end
    end
    return false
end

--- Adopts blank runes that are ALREADY in the backpack into the pool -
--- no need to fly home when you are carrying runes anyway. Runes whose
--- tooltip has not arrived yet are left alone (re-marking someone's
--- marked rune would destroy it).
local function collectBlankRunes()
    local items = Items.FindInContainer(Player.Backpack.Serial)
    if items == nil then return 0 end

    local added, unknown = 0, 0
    for i = 1, #items do
        local it = items[i]
        if it ~= nil and it.Graphic == RUNE and not isPooled(it.Serial) then
            if not knowsRune(it) then
                unknown = unknown + 1
            elseif not isMarkedRune(it) then
                state.blankRunes[#state.blankRunes + 1] = it.Serial
                added = added + 1
            end
        end
    end

    state.unknownRunes = unknown
    return added
end

local function blankRuneCount()
    local n = 0
    for i = 1, #state.blankRunes do
        if findSerialInBackpack(state.blankRunes[i]) ~= nil then n = n + 1 end
    end
    return n
end

local function takeBlankRune()
    while #state.blankRunes > 0 do
        local serial = table.remove(state.blankRunes, 1)
        if findSerialInBackpack(serial) ~= nil then return serial end
    end
    return nil
end

--- Opens a container. Right after a recall the client has not received
--- the nearby items yet, so the serial is briefly unknown ("UseObject:
--- Invalid serial") - wait for the item to show up before using it.
local function openBag(serial)
    if serial == nil then return false end

    local waited = 0
    while Items.FindBySerial(serial) == nil and waited < 8000 do
        Pause(500)
        waited = waited + 500
    end

    if Items.FindBySerial(serial) == nil then
        state.lastError = string.format('Container 0x%X is not in range (are you at home?).', math.floor(serial))
        return false
    end

    Player.UseObject(serial)
    Pause(900)
    return true
end

local function openResourceBag()
    return openBag(settings.resourceBag)
end

--- The rune container may sit INSIDE the resource container - the
--- client only learns about a nested container once its parent has
--- been opened, so open the parent first.
local function openRuneBag()
    local bag = runeSource()
    if bag == nil then return false end
    if bag == settings.resourceBag then return openBag(bag) end

    if Items.FindBySerial(bag) == nil then
        openResourceBag()
        Pause(400)
    end

    return openBag(bag)
end

--- Fills the pack up to `want` blank runes. Runes do not stack, so they
--- are moved one by one - but the container is opened ONCE and a rune
--- that refuses to move is simply skipped instead of ending the whole
--- restock.
local function restockRunes(want)
    local bag = runeSource()
    if not openRuneBag() then return false end

    local items = Items.FindInContainer(bag)
    if items == nil then
        state.lastError = 'The rune container did not open.'
        return false
    end

    local moved = 0
    for i = 1, #items do
        if blankRuneCount() >= want then break end

        local it = items[i]
        if it ~= nil and it.Graphic == RUNE and not isPooled(it.Serial) then
            -- Marked runes in the container are left alone.
            if not knowsRune(it) or not isMarkedRune(it) then
                setStatus(string.format('Restocking runes... (%d/%d)', blankRuneCount(), want))
                Player.PickUp(it.Serial, 1)
                Pause(700)
                Player.DropInBackpack()
                Pause(700)
                if findSerialInBackpack(it.Serial) ~= nil then
                    state.blankRunes[#state.blankRunes + 1] = it.Serial
                    moved = moved + 1
                end
            end
        end
    end

    return moved > 0
end

local function restockReg(gfx, name, want)
    if not openResourceBag() then return false end

    local items = Items.FindInContainer(settings.resourceBag)
    if items == nil then return false end

    for i = 1, #items do
        local it = items[i]
        if it ~= nil and it.Graphic == gfx and it.Hue == 0 then
            setStatus('Restocking ' .. name .. '...')
            Player.PickUp(it.Serial, want)
            Pause(700)
            Player.DropInBackpack()
            Pause(700)
            return true
        end
    end

    return false
end

--- True when the pack holds enough for the trip WITHOUT touching the
--- reg reserve: reserve + needed sets of each reagent, enough runes.
local function suppliesOk(needRunes, needSets)
    if blankRuneCount() < needRunes then return false end
    for i = 1, #REGS do
        if countBp(REGS[i][1]) < settings.regReserve + needSets then return false end
    end
    return true
end

--- How many runes the rest of the job still needs (one per copy that is
--- still open) - so a restock trip fills up for many entries at once
--- instead of fetching a single rune per stop.
local function runesStillNeeded()
    if state.work == nil then return 1 end

    local total = 0
    for i = state.workIdx, #state.work do
        local item = state.work[i]
        for k = 1, #item.books do
            local serial = item.books[k]
            -- Books that ran out of slots do not need runes any more.
            if state.free[serial] == nil or state.free[serial] > 0 then
                total = total + 1
            end
        end
    end
    return total
end

--- Recalls home and fills the pack: reagents from the resource
--- container, blank runes from the rune container (or the resource one).
--- Runes are stocked for the whole remaining job, capped by carry weight.
local function restockAtHome(needRunes, needSets)
    setStatus('Supplies low - recalling home to restock...')
    if not travelHome() then
        if state.lastError == '' then state.lastError = 'Could not recall home for restocking.' end
        return false
    end

    for i = 1, #REGS do
        local gfx, name = REGS[i][1], REGS[i][2]
        if countBp(gfx) < settings.regReserve + needSets then
            restockReg(gfx, name, math.max(50, settings.regReserve + needSets * 4))
        end
    end

    -- Take runes for everything that is still open (one per remaining
    -- copy - so a full source book means a full stack of runes), capped
    -- only by carry weight. ⚠ MaxWeight can be 0 before the first status
    -- packet arrives - never let that clamp the amount to nothing.
    local want = math.max(needRunes, runesStillNeeded())
    local maxWeight = Player.MaxWeight or 0
    if maxWeight > 0 then
        local room = math.floor(maxWeight - (Player.Weight or 0) - 20)
        if room < needRunes then room = needRunes end
        if want > room then want = room end
    end

    collectBlankRunes()

    if blankRuneCount() < want then
        restockRunes(want)
    end

    refreshCounts()

    if not suppliesOk(needRunes, needSets) then
        if blankRuneCount() < needRunes then
            if state.lastError == '' then
                local extra = ''
                if (state.unknownRunes or 0) > 0 then
                    extra = string.format(' (%d rune(s) in the pack were ignored - no tooltip yet, so I cannot tell blank from marked)', state.unknownRunes)
                end
                state.lastError = 'Out of blank runes' .. extra .. '.'
            end
        else
            state.lastError = 'Out of reagents (below the reserve).'
        end
        return false
    end

    return true
end

-- ==================== Mark / rename / store =========================

--- Marks the given rune, renames it via the server prompt and returns
--- ok, err. The prompt doubles as the mark success test: an unmarked
--- rune answers the double-click with "not yet marked" instead.
local function markAndRename(runeSerial, name)
    for attempt = 1, 3 do
        if not ensureMana(MANA_MARK + 2) then return false, 'not enough mana' end

        setStatus('Marking rune (' .. name .. ')...')
        Journal.Clear()
        Spells.Cast('Mark')

        if Target.WaitForTarget(5000) then
            Target.TargetSerial(runeSerial)
        else
            return false, 'no target cursor from Mark'
        end

        Pause(1500)
        state.regsUsed = state.regsUsed + 1

        if Journal.Contains('More reagents are needed') then return false, 'out of reagents' end
        if Journal.Contains('not appear to work') then return false, 'marking is blocked here' end
        if Journal.Contains('location is blocked') then return false, 'location is blocked' end

        -- Success test + rename in one step: double-click opens the
        -- rename prompt ONLY on a marked rune.
        Journal.Clear()
        Player.UseObject(runeSerial)

        local waited = 0
        while not Player.HasPrompt and waited < 3000 do
            Pause(100)
            waited = waited + 100
        end

        if Player.HasPrompt then
            Player.ResponsePrompt(name)
            Pause(500)
            state.marked = state.marked + 1
            lifetime.runesMarked = lifetime.runesMarked + 1
            return true
        end

        -- No prompt: the mark failed (fizzle or similar) - try again.
        if Journal.Contains('Insufficient mana') then
            -- loop handles mana next round
        end
        setStatus('Mark did not take - trying again...')
        Pause(800)
    end

    return false, 'mark kept failing'
end

--- Drops the (renamed) rune into the target book.
local function storeRune(runeSerial, bookSerial)
    closeBook()   -- the book must not count as open server-side

    Journal.Clear()
    Player.PickUp(runeSerial, 1)
    Pause(700)
    Player.DropInContainer(bookSerial)
    Pause(800)

    if findSerialInBackpack(runeSerial) == nil then return true end

    if Journal.Contains('runebook is full') then
        Player.DropInBackpack()
        Pause(500)
        return false, 'book full'
    end

    Player.DropInBackpack()
    Pause(500)
    return false, 'drop failed'
end

-- ==================== Work list =====================================

local function bookLabel(serial)
    return string.format('0x%X', math.floor(serial))
end

local function recordSkip(name, reason)
    state.skipped[#state.skipped + 1] = { name = name, reason = reason }
end

local function printReport()
    Messages.Print(string.format('Runebook Copier: %d entries copied, %d runes marked.', state.copied, state.marked), 88)
    if #state.skipped == 0 then
        Messages.Print('Nothing was skipped.', 88)
    else
        for i = 1, #state.skipped do
            Messages.Print(string.format('Skipped: %s (%s)', state.skipped[i].name, state.skipped[i].reason), 53)
        end
    end
end

--- One work item: travel to the entry, mark+store one rune per book.
--- Returns true to continue with the next entry, false to stop.
local function processEntry(item)
    local books = {}
    for i = 1, #item.books do
        if state.free[item.books[i]] == nil or state.free[item.books[i]] > 0 then
            books[#books + 1] = item.books[i]
        end
    end
    if #books == 0 then
        recordSkip(item.name, 'no space left in any target book')
        return true
    end

    -- Sets of regs this trip needs: the marks, plus the travel casts
    -- when magery does the traveling (out + potential trip home).
    local needSets = #books
    if settings.travelMode ~= 1 then needSets = needSets + 2 end

    -- Blank runes you are already carrying count too.
    collectBlankRunes()

    if not suppliesOk(#books, needSets) then
        if not restockAtHome(#books, needSets) then return false end
    end

    local ok, err = travelTo(settings.sourceBook, item.idx, item.name)
    if not ok then
        if settings.onFail == 2 then
            state.lastError = string.format('%s: %s', item.name, err or 'travel failed')
            return false
        end
        recordSkip(item.name, err or 'travel failed')
        return true
    end

    if not safetyOk() then
        travelHome()
        state.lastError = 'Health low - recalled home and stopped.'
        return false
    end

    for k = 1, #books do
        state.runeNo = k

        local rune = takeBlankRune()
        if rune == nil then
            state.lastError = 'Out of blank runes mid-entry.'
            return false
        end

        local ok2, err2 = markAndRename(rune, item.name)
        if ok2 then
            local ok3, err3 = storeRune(rune, books[k])
            if ok3 then
                state.copied = state.copied + 1
                lifetime.entriesCopied = lifetime.entriesCopied + 1
                if state.have[books[k]] == nil then state.have[books[k]] = {} end
                state.have[books[k]][item.name] = true
                if state.free[books[k]] ~= nil then state.free[books[k]] = state.free[books[k]] - 1 end
            elseif err3 == 'book full' then
                state.free[books[k]] = 0
                recordSkip(item.name, 'target book ' .. bookLabel(books[k]) .. ' is full')
            else
                if settings.onFail == 2 then
                    state.lastError = string.format('%s: %s', item.name, err3 or 'store failed')
                    return false
                end
                recordSkip(item.name, (err3 or 'store failed') .. ' (' .. bookLabel(books[k]) .. ')')
            end
        else
            -- The rune is still blank - put it back into the pool.
            if findSerialInBackpack(rune) ~= nil then
                state.blankRunes[#state.blankRunes + 1] = rune
            end
            if err2 == 'out of reagents' or err2 == 'not enough mana' then
                state.lastError = err2
                return false
            end
            if settings.onFail == 2 then
                state.lastError = string.format('%s: %s', item.name, err2 or 'mark failed')
                return false
            end
            recordSkip(item.name, err2 or 'mark failed')
            -- Marking is location-bound - the remaining books would fail
            -- the same way, so move on to the next entry.
            break
        end

        if not safetyOk() then
            travelHome()
            state.lastError = 'Health low - recalled home and stopped.'
            return false
        end

        saveStats()
    end

    return true
end

-- ==================== Preflight =====================================

local function preflight()
    if settings.sourceBook == nil or settings.homeBook == nil or settings.resourceBag == nil then
        state.lastError = 'Pick the source book, the home book and the resource container first.'
        return false
    end
    if #settings.targets == 0 then
        state.lastError = 'Add at least one target book.'
        return false
    end
    if mageryBase() < 50 then
        state.lastError = 'Marking needs at least 50 magery.'
        return false
    end

    -- Everything travels with us, so everything must be in the backpack.
    local need = { settings.sourceBook, settings.homeBook }
    for i = 1, #settings.targets do need[#need + 1] = settings.targets[i] end
    for i = 1, #need do
        if findSerialInBackpack(need[i]) == nil then
            state.lastError = 'Book ' .. bookLabel(need[i]) .. ' must be in your backpack.'
            return false
        end
    end

    -- Home book: find the "home" entry.
    setStatus('Reading the home book...')
    local home = readBook(settings.homeBook)
    if home == nil then
        state.lastError = 'Could not read the home book.'
        return false
    end
    state.homeIdx = nil
    for i = 1, 16 do
        local name = home.entries[i]
        if name ~= nil and string.lower(name) == 'home' then
            state.homeIdx = i - 1
            break
        end
    end
    if state.homeIdx == nil then
        state.lastError = 'The home book has no entry named "home".'
        return false
    end

    -- Source book.
    setStatus('Reading the source book...')
    local source = readBook(settings.sourceBook)
    if source == nil then
        state.lastError = 'Could not read the source book.'
        return false
    end
    state.sourceCharges = source.charges

    local sourceList = {}
    local seen = {}
    local warned = {}
    for i = 1, 16 do
        local name = source.entries[i]
        if name ~= nil then
            if seen[name] then
                if not warned[name] then
                    warned[name] = true
                    Messages.Print('Runebook Copier: duplicate name "' .. name .. '" - only the first entry is copied.', 53)
                end
            else
                seen[name] = true
                sourceList[#sourceList + 1] = { idx = i - 1, name = name }
            end
        end
    end
    if #sourceList == 0 then
        state.lastError = 'The source book is empty.'
        return false
    end

    -- Target books: existing names = resume state, plus free slots.
    state.have = {}
    state.free = {}
    for t = 1, #settings.targets do
        local serial = settings.targets[t]
        setStatus('Reading target book ' .. t .. '/' .. #settings.targets .. '...')
        local book = readBook(serial)
        if book == nil then
            state.lastError = 'Could not read target book ' .. bookLabel(serial) .. '.'
            return false
        end
        state.have[serial] = {}
        local used = 0
        for i = 1, 16 do
            if book.entries[i] ~= nil then
                state.have[serial][book.entries[i]] = true
                used = used + 1
            end
        end
        state.free[serial] = 16 - used
    end

    -- Work list: for each source entry the books still missing it.
    state.work = {}
    for i = 1, #sourceList do
        local entry = sourceList[i]
        local books = {}
        for t = 1, #settings.targets do
            local serial = settings.targets[t]
            if not state.have[serial][entry.name] then books[#books + 1] = serial end
        end
        if #books > 0 then
            state.work[#state.work + 1] = { idx = entry.idx, name = entry.name, books = books }
        end
    end

    if #state.work == 0 then
        state.lastError = 'Nothing to copy - every target book already has all entries.'
        return false
    end

    state.workIdx = 1

    local adopted = collectBlankRunes()
    if adopted > 0 then
        Messages.Print(string.format('Runebook Copier: %d blank rune(s) in the backpack will be used.', adopted), 68)
    end
    if (state.unknownRunes or 0) > 0 then
        Messages.Print(string.format('Runebook Copier: %d rune(s) in the backpack ignored - no tooltip yet, hover them once so I can tell blank from marked.', state.unknownRunes), 53)
    end

    return true
end

-- ==================== Window ========================================

local win = UI.Window('Runebook Copier', 120, 120)

ui.status = win:Label('Idle - press START.')

win:Separator()

local srcRow = win:Row()
srcRow:Button('Source book', function() state.pickSource = true end)
ui.srcLbl = srcRow:Label(settings.sourceBook ~= nil and bookLabel(settings.sourceBook) or 'not set')
srcRow:Button('Home book', function() state.pickHome = true end)
ui.homeLbl = srcRow:Label(settings.homeBook ~= nil and bookLabel(settings.homeBook) or 'not set')

local bagRow = win:Row()
bagRow:Button('Resource container', function() state.pickBag = true end)
ui.bagLbl = bagRow:Label(settings.resourceBag ~= nil and bookLabel(settings.resourceBag) or 'not set')
bagRow:Button('Rune container', function() state.pickRuneBag = true end)
ui.runeBagLbl = bagRow:Label(settings.runeBag ~= nil and bookLabel(settings.runeBag) or 'same as resources')
bagRow:Button('x', function()
    if state.running then return end
    settings.runeBag = nil
    ui.runeBagLbl:SetText('same as resources')
    saveSettings()
end)

local tgtRow = win:Row()
tgtRow:Button('Add target book', function() state.pickTarget = true end)
ui.tgtLbl = tgtRow:Label(#settings.targets > 0 and (#settings.targets .. ' book(s)') or 'none')
tgtRow:Button('Clear', function()
    if state.running then return end
    settings.targets = {}
    ui.tgtLbl:SetText('none')
    saveSettings()
end)

win:Separator()

-- Travel mode radio row.
local travelBoxes = {}
local travelRow = win:Row()
travelRow:Label('Travel:')
for i, label in ipairs(TRAVEL_MODES) do
    local box
    box = travelRow:Checkbox(label, i == settings.travelMode, function(checked)
        if state.running then
            box:SetChecked(i == settings.travelMode)
            return
        end
        if checked then
            settings.travelMode = i
            for j, other in ipairs(travelBoxes) do
                if j ~= i then other:SetChecked(false) end
            end
        else
            if settings.travelMode == i then box:SetChecked(true) end
        end
    end)
    travelBoxes[i] = box
end

local optRow = win:Row()
optRow:Label('Reg reserve:')
local reserveBox = optRow:TextBox(tostring(settings.regReserve), function(text)
    local n = math.floor(tonumber(text) or -1)
    if n >= 0 then settings.regReserve = n end
end)
reserveBox:SetWidth(30)
optRow:Label('each   On failure:')
local failBoxes = {}
for i, label in ipairs(FAIL_MODES) do
    local box
    box = optRow:Checkbox(label, i == settings.onFail, function(checked)
        if checked then
            settings.onFail = i
            for j, other in ipairs(failBoxes) do
                if j ~= i then other:SetChecked(false) end
            end
        else
            if settings.onFail == i then box:SetChecked(true) end
        end
    end)
    failBoxes[i] = box
end

local safeRow = win:Row()
local lowChk = safeRow:Checkbox('Recall home below', settings.recallLow, function(checked)
    settings.recallLow = checked
end)
local hpBox = safeRow:TextBox(tostring(settings.hpPct), function(text)
    local n = math.floor(tonumber(text) or 0)
    if n >= 1 and n <= 99 then settings.hpPct = n end
end)
hpBox:SetWidth(30)
safeRow:Label('% HP')
local cureChk = safeRow:Checkbox('Cure poison', settings.cure, function(checked)
    settings.cure = checked
end)
local healChk = safeRow:Checkbox('Heal when hurt', settings.heal, function(checked)
    settings.heal = checked
end)

win:Separator()

ui.regs    = win:Label('Regs: -')
ui.runes   = win:Label('Blank runes: -')
ui.mana    = win:Label('Mana: -')
ui.progress = win:Label('Progress: -')
ui.stats   = win:Label('Copied 0   marked 0   skipped 0')
ui.runtime = win:Label('Runtime 0:00')

local toolRow = win:Row()
toolRow:Button('Print report', printReport)
toolRow:Button('Clear stats', function()
    clearStats()
    Messages.Print('Runebook Copier stats cleared.', 88)
end)
toolRow:Button('Clear saved settings', function()
    if state.running then
        Messages.Print('Runebook Copier: stop the script first.', 33)
        return
    end
    Config.Delete(SETTINGS_CONFIG)
    settings.travelMode = 3
    settings.regReserve = 5
    settings.onFail = 1
    settings.recallLow = true
    settings.hpPct = 50
    settings.cure = true
    settings.heal = true
    settings.sourceBook = nil
    settings.homeBook = nil
    settings.resourceBag = nil
    settings.runeBag = nil
    settings.targets = {}
    for j, box in ipairs(travelBoxes) do box:SetChecked(j == 3) end
    for j, box in ipairs(failBoxes) do box:SetChecked(j == 1) end
    reserveBox:SetText('5')
    lowChk:SetChecked(true)
    hpBox:SetText('50')
    cureChk:SetChecked(true)
    healChk:SetChecked(true)
    ui.srcLbl:SetText('not set')
    ui.homeLbl:SetText('not set')
    ui.bagLbl:SetText('not set')
    ui.runeBagLbl:SetText('same as resources')
    ui.tgtLbl:SetText('none')
    setStatus('Saved settings cleared.')
end)

win:Separator()

local controlRow = win:Row()
local startButton

local function setRunning(on)
    state.running = on
    startButton:SetText(on and 'STOP' or 'START')
    if not on then
        saveStats()
        saveSettings()
    end
end

startButton = controlRow:Button('START', function()
    if state.running then
        setRunning(false)
        setStatus('Stopped.')
        return
    end

    state.copied = 0
    state.marked = 0
    state.skipped = {}
    state.regsUsed = 0
    state.blankRunes = {}
    state.runeNo = 0
    state.lastError = ''
    state.lastTravel = 0
    state.startTime = os.time()
    saveSettings()

    -- Book reading pauses, so the preflight runs in the main loop.
    state.preflight = true
    setStatus('Checking setup...')
end)

controlRow:Button('Close', function()
    setRunning(false)
    win:Close()
end)

win:OnClose(function()
    state.running = false
    saveStats()
    saveSettings()
end)

-- ==================== Display push ==================================

local function updateUi()
    local regsText = ''
    for i = 1, #REGS do
        local part = string.format('%s %d/%d', REGS[i][2], countBp(REGS[i][1]), contCounts[REGS[i][1]] or 0)
        if regsText == '' then regsText = part else regsText = regsText .. '   ' .. part end
    end
    ui.regs:SetText('Regs (pack/container): ' .. regsText)

    ui.runes:SetText(string.format('Blank runes: %d in pack   %d in container', blankRuneCount(), contCounts[RUNE] or 0))

    local chargesText = state.sourceCharges >= 0 and tostring(state.sourceCharges) or '-'
    ui.mana:SetText(string.format('Mana %d/%d   Source book charges: %s', math.floor(Player.Mana or 0), math.floor(Player.MaxMana or 0), chargesText))

    if state.work == nil or not state.running then
        ui.progress:SetText('Progress: -')
    else
        local item = state.work[state.workIdx]
        local name = item ~= nil and item.name or '-'
        local total = item ~= nil and #item.books or 0
        ui.progress:SetText(string.format('Entry %d/%d (%s)   rune %d/%d', math.min(state.workIdx, #state.work), #state.work, name, state.runeNo, total))
    end

    ui.stats:SetText(string.format('Copied %d   marked %d   skipped %d   reg sets used %d', state.copied, state.marked, #state.skipped, state.regsUsed))
    ui.runtime:SetText('Runtime ' .. formatTime(elapsed()))
end

-- ==================== Main loop =====================================

if Player.Backpack == nil then
    Messages.Print('Runebook Copier: no backpack - are you logged in?', 33)
    return
end

Messages.Print('Runebook Copier: pick your books and the resource container, then press START.', 68)

local function pickSerial(prompt)
    Messages.Print(prompt, 68)
    Pause(400)
    UI.Pump()
    local serial = Targeting.GetNewTarget(20000)
    if serial ~= nil and serial ~= 0 then return serial end
    return nil
end

local function pickBookSerial(prompt)
    local serial = pickSerial(prompt)
    if serial == nil then return nil end
    local item = Items.FindBySerial(serial)
    if item == nil or item.Graphic ~= RUNEBOOK then
        setStatus('That is not a runebook.')
        return nil
    end
    return serial
end

refreshCounts()
updateUi()

while win:IsOpen() do
    UI.Pump()

    if os.time() - lastCountRefresh >= 0.75 then
        lastCountRefresh = os.time()
        if not state.running then refreshCounts() end
        updateUi()
    end

    if state.pickSource then
        state.pickSource = false
        setStatus('Target the SOURCE runebook...')
        local serial = pickBookSerial('Target the runebook you want to copy.')
        if serial ~= nil then
            settings.sourceBook = serial
            ui.srcLbl:SetText(bookLabel(serial))
            saveSettings()
            setStatus('Source book set.')
        end
    end

    if state.pickHome then
        state.pickHome = false
        setStatus('Target the HOME runebook...')
        local serial = pickBookSerial('Target the runebook that holds your "home" rune.')
        if serial ~= nil then
            settings.homeBook = serial
            ui.homeLbl:SetText(bookLabel(serial))
            saveSettings()
            setStatus('Home book set.')
        end
    end

    if state.pickBag then
        state.pickBag = false
        setStatus('Target the resource container...')
        local serial = pickSerial('Target the container with blank runes and reagents.')
        if serial ~= nil then
            settings.resourceBag = serial
            ui.bagLbl:SetText(bookLabel(serial))
            saveSettings()
            refreshCounts()
            setStatus('Resource container set.')
        end
    end

    if state.pickRuneBag then
        state.pickRuneBag = false
        setStatus('Target the rune container...')
        local serial = pickSerial('Target the container that holds your BLANK runes.')
        if serial ~= nil then
            settings.runeBag = serial
            ui.runeBagLbl:SetText(bookLabel(serial))
            saveSettings()
            refreshCounts()
            setStatus('Rune container set.')
        end
    end

    if state.pickTarget then
        state.pickTarget = false
        if #settings.targets >= 8 then
            setStatus('Eight target books are the limit.')
        else
            setStatus('Target a TARGET runebook...')
            local serial = pickBookSerial('Target a runebook to copy INTO (repeat for more).')
            if serial ~= nil then
                local dupe = serial == settings.sourceBook
                for i = 1, #settings.targets do
                    if settings.targets[i] == serial then dupe = true end
                end
                if dupe then
                    setStatus('That book is already in the list (or the source).')
                else
                    settings.targets[#settings.targets + 1] = serial
                    ui.tgtLbl:SetText(#settings.targets .. ' book(s)')
                    saveSettings()
                    setStatus(#settings.targets .. ' target book(s).')
                end
            end
        end
    end

    if state.preflight then
        state.preflight = false
        if preflight() then
            setRunning(true)
            setStatus(string.format('Running - %d entries to copy...', #state.work))
        else
            setStatus('Not started - ' .. state.lastError)
            Messages.Print('Runebook Copier: ' .. state.lastError, 33)
        end
    end

    if state.running then
        if state.work ~= nil and state.workIdx <= #state.work then
            local item = state.work[state.workIdx]
            state.runeNo = 0
            if processEntry(item) then
                state.workIdx = state.workIdx + 1
            else
                setRunning(false)
                if state.lastError ~= '' then
                    setStatus('Stopped - ' .. state.lastError)
                    Messages.Print('Runebook Copier: ' .. state.lastError, 33)
                end
                printReport()
            end
        else
            setRunning(false)
            setStatus('Done! Heading home...')
            travelHome()
            setStatus(string.format('Done - %d entries copied.', state.copied))
            Messages.Print('Runebook Copier: finished.', 68)
            printReport()
        end
        updateUi()
    else
        Pause(200)
    end
end

Messages.Print('Runebook Copier closed.', 68)
