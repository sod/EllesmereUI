-------------------------------------------------------------------------------
--  EllesmereUICooldownManager.lua
--  CDM Look Customization and Cooldown Display
--  Mirrors Blizzard CDM bars with custom styling, cooldown swipes,
--  desaturation, active state animations, and per-spec profiles.
--  Does NOT parse secret values works around restricted APIs.
-------------------------------------------------------------------------------
local _, ns = ...
local ECME = EllesmereUI.Lite.NewAddon("EllesmereUICooldownManager")
ns.ECME = ECME

-- Snap a value to a whole number of physical pixels at the bar's effective scale.
-- Uses the same approach as the border system: convert to physical pixels,
-- round to nearest integer, convert back.
local function SnapForScale(x, barScale)
    if x == 0 then return 0 end
    local es = (UIParent:GetScale() or 1) * (barScale or 1)
    return EllesmereUI.PP.SnapForES(x, es)
end

local floor = math.floor
local GetTime = GetTime

ns.DEFAULT_MAPPING_NAME = "Buff Name (eg: Divine Purpose)"

local RECONCILE = {
    readyDelay = 2,
    retryDelay = 1,
    retryMax = 5,
    lastSpecChangeAt = 0,
    lastZoneInAt = 0,
    pending = false,
    retries = 0,
    retryToken = 0,
}


-------------------------------------------------------------------------------
--  Shape Constants (shared with action bars)
-------------------------------------------------------------------------------
local CDM_SHAPES = {
    masks = {
        circle   = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\circle_mask.tga",
        csquare  = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\csquare_mask.tga",
        diamond  = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\diamond_mask.tga",
        hexagon  = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\hexagon_mask.tga",
        portrait = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\portrait_mask.tga",
        shield   = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\shield_mask.tga",
        square   = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\square_mask.tga",
    },
    borders = {
        circle   = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\circle_border.tga",
        csquare  = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\csquare_border.tga",
        diamond  = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\diamond_border.tga",
        hexagon  = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\hexagon_border.tga",
        portrait = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\portrait_border.tga",
        shield   = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\shield_border.tga",
        square   = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\square_border.tga",
    },
    insets = {
        circle = 17, csquare = 17, diamond = 14,
        hexagon = 17, portrait = 17, shield = 13, square = 17,
    },
    iconExpand = 7,
    iconExpandOffsets = {
        circle = 2, csquare = 4, diamond = 2, hexagon = 4,
        portrait = 2, shield = 2, square = 4,
    },
    zoomDefaults = {
        none = 0.08, cropped = 0.04, square = 0.06, circle = 0.06, csquare = 0.06,
        diamond = 0.06, hexagon = 0.06, portrait = 0.06, shield = 0.06,
    },
    edgeScales = {
        circle = 0.75, csquare = 0.75, diamond = 0.70,
        hexagon = 0.65, portrait = 0.70, shield = 0.65, square = 0.75,
    },
}
ns.CDM_SHAPE_MASKS   = CDM_SHAPES.masks
ns.CDM_SHAPE_BORDERS = CDM_SHAPES.borders
ns.CDM_SHAPE_ZOOM_DEFAULTS = CDM_SHAPES.zoomDefaults
-- Forward declarations for glow helpers (defined later, used by consolidated helpers)
local StartNativeGlow, StopNativeGlow

-- Hover states for CDM bar fade in/out
local _cdmHoverStates = {}       -- [barKey] = { isHovered=false, fadeDir=nil }

-- Keybind cache: built once out-of-combat, looked up per tick
local _cdmKeybindCache       = {}   -- [spellID] -> formatted key string
local _keybindRebuildPending = false
local _keybindCacheReady     = false  -- true after first successful build

-- Combat state tracked via events (InCombatLockdown() can lag behind PLAYER_REGEN_DISABLED)
local _inCombat = false

-- Multi-charge spell tracking
local _multiChargeSpells = {}
local _maxChargeCount    = {}

-- Per-tick caches (rebuilt each UpdateAllCDMBars tick)
local _tickBlizzActiveCache   = {}
local _tickBlizzAllChildCache = {}
local _tickBlizzBuffChildCache = {}
local _tickBarViewerCache     = {}   -- BuffBarCooldownViewer (vi=4) children only
local _tickCDUtilTrackedSet   = {}
local _tickBuffIconTrackedSet = {}

-- Viewer child iteration buffer and viewer name list
local _viewerChildBuf = {}
local _viewerChildSet = {}  -- hash set for O(1) dup check
local _cdmViewerNames = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
}

-- External frame cache: stores all addon data keyed by Blizzard frame references
-- instead of writing custom keys onto Blizzard's secure frame tables (which taints them).
-- Weak keys so entries are collected when frames are recycled.
local _ecmeFC = setmetatable({}, { __mode = "k" })
local function FC(f) local c = _ecmeFC[f]; if not c then c = {}; _ecmeFC[f] = c end; return c end

-- Duration object caches (hooked from Blizzard SetCooldownFromDurationObject)
local _ecmeChildHasDurObj = {}
local _ecmeDurObjCache    = {}
local _ecmeRawStartCache  = {}
local _ecmeRawDurCache    = {}

-- Custom bar spell-cast timers (for buff bars with user-configured durations)
local _customBarTimers = {}

-- Health item combat lockout tracking
local _healthCombatLockout = {}

-- cooldownID -> corrected spellID (from viewer child scan)
local _cdIDToCorrectSID = {}

-- Racial ability data
local RACE_RACIALS = {
    Scourge            = { 7744 },
    Tauren             = { 20549 },
    Orc                = { 20572, 33697, 33702 },
    BloodElf           = { 202719, 50613, 25046, 69179, 80483, 155145, 129597, 232633, 28730 },
    Dwarf              = { 20594 },
    Troll              = { 26297 },
    Draenei            = { 28880 },
    NightElf           = { 58984 },
    Human              = { 59752 },
    DarkIronDwarf      = { 265221 },
    Gnome              = { 20589 },
    HighmountainTauren = { 69041 },
    Worgen             = { 68992 },
    Goblin             = { 69070 },
    Pandaren           = { 107079 },
    MagharOrc          = { 274738 },
    LightforgedDraenei = { 255647 },
    VoidElf            = { 256948 },
    KulTiran           = { 287712 },
    ZandalariTroll     = { 291944 },
    Vulpera            = { 312411 },
    Mechagnome         = { 312924 },
    Dracthyr           = { 357214, { 368970, class = "EVOKER" } },
    EarthenDwarf       = { 436344 },
    Haranir            = { 1287685 },
}
ns.RACE_RACIALS = RACE_RACIALS

local ALL_RACIAL_SPELLS = {}
for _, racials in pairs(RACE_RACIALS) do
    for _, entry in ipairs(racials) do
        local sid = type(entry) == "table" and entry[1] or entry
        ALL_RACIAL_SPELLS[sid] = true
    end
end

local _myRacials = {}
local _myRacialsSet = {}

local HEALTH_ITEMS = {
    { itemID = 241308, spellID = 1236616, altItemIDs = { 245898, 245897, 241309 }, combatLockout = true },
    { itemID = 241288, spellID = 1236994, altItemIDs = { 241289, 245902, 245903 }, combatLockout = true },
    { itemID = 241304, spellID = 1234768, altItemIDs = { 241305 }, combatLockout = true },
    { itemID = 241300, spellID = 1236648, altItemIDs = { 245917, 245916, 241301 }, combatLockout = true },
    { itemID = 5512,   spellID = 6262, combatLockout = true },
    { itemID = 224464, spellID = 452930, class = "WARLOCK" },
}
ns.HEALTH_ITEMS = HEALTH_ITEMS

-- Buff bar presets (shared by CDM buff bars and Tracking Bars)
local BUFF_BAR_PRESETS = {
    {
        key      = "bloodlust",
        name     = UnitFactionGroup("player") == "Horde" and "Bloodlust" or "Heroism",
        icon     = 132313,
        spellIDs = { 2825, 32182, 80353, 264667, 390386, 381301, 444062, 444257 },
        duration = 40,
    },
    {
        key      = "lights_potential",
        name     = "Light's Potential",
        icon     = 7548911,
        spellIDs = { 1236616, 431932 },
        duration = 30,
    },
    {
        key      = "potion_recklessness",
        name     = "Potion of Recklessness",
        icon     = 7548916,
        spellIDs = { 1236994 },
        duration = 30,
    },
    {
        key      = "invis_potion",
        name     = "Invisibility Potion",
        icon     = 134764,
        spellIDs = { 371125, 431424, 371133, 371134, 1236551 },
        duration = 18,
    },
    {
        key         = "time_spiral",
        name        = "Time Spiral",
        icon        = 4622479,
        glowBased   = true,
        glowSpellIDs = {
            48265, 195072, 189110, 1850, 252216, 358267, 186257, 1953,
            212653, 361138, 119085, 190784, 73325, 2983, 192063, 58875,
            79206, 48020, 6544,
        },
        spellIDs = {},
        duration = 10,
    },
    {
        key      = "call_dreadstalkers",
        name     = "Call Dreadstalkers",
        icon     = 1378282,
        spellIDs = { 104316 },
        duration = 12,
        class    = "WARLOCK",
    },
    {
        key      = "demonic_tyrant",
        name     = "Summon Demonic Tyrant",
        icon     = 2065628,
        spellIDs = { 265187 },
        duration = 15,
        class    = "WARLOCK",
    },
    {
        key      = "summon_vilefiend",
        name     = "Summon Vilefiend",
        icon     = 1616211,
        spellIDs = { 264119 },
        duration = 15,
        class    = "WARLOCK",
    },
    {
        key      = "grimoire_felguard",
        name     = "Grimoire: Felguard",
        icon     = 136216,
        spellIDs = { 111898 },
        duration = 17,
        class    = "WARLOCK",
    },
}
ns.BUFF_BAR_PRESETS = BUFF_BAR_PRESETS

-- Item presets for CD/utility bars (potions that track cooldowns)
local CDM_ITEM_PRESETS = {
    {
        key      = "lights_potential",
        name     = "Light's Potential",
        icon     = 7548911,
        itemID   = 241308,
        altItemIDs = { 245898, 245897, 241309 },
    },
    {
        key      = "potion_recklessness",
        name     = "Potion of Recklessness",
        icon     = 7548916,
        itemID   = 241288,
        altItemIDs = { 241289, 245902, 245903 },
    },
    {
        key      = "silvermoon_health",
        name     = "Silvermoon Health Potion",
        icon     = 7548909,
        itemID   = 241304,
        altItemIDs = { 241305 },
    },
    {
        key      = "lightfused_mana",
        name     = "Lightfused Mana Potion",
        icon     = 7548907,
        itemID   = 241300,
        altItemIDs = { 245917, 245916, 241301 },
    },
    {
        key      = "invis_potion",
        name     = "Invisibility Potion",
        icon     = 134764,
        itemID   = 211756,
        altItemIDs = { 241304, 241305 },
    },
}
ns.CDM_ITEM_PRESETS = CDM_ITEM_PRESETS

local HEALTH_ITEM_BY_SPELL = {}
for _, hi in ipairs(HEALTH_ITEMS) do
    HEALTH_ITEM_BY_SPELL[hi.spellID] = hi
end

local function GetActiveHealthItemID(hi)
    local baseCount = C_Item.GetItemCount(hi.itemID, false, true) or 0
    if baseCount > 0 then return hi.itemID, baseCount end
    if hi.altItemIDs then
        for _, altID in ipairs(hi.altItemIDs) do
            local altCount = C_Item.GetItemCount(altID, false, true) or 0
            if altCount > 0 then return altID, altCount end
        end
    end
    return hi.itemID, 0
end
ns.GetActiveHealthItemID = GetActiveHealthItemID

local BuildAllCDMBars
local RegisterCDMUnlockElements

-------------------------------------------------------------------------------
--  Defaults
-------------------------------------------------------------------------------
local DEFAULTS = {
    global = {},
    profile = {
        -- _capturedOnce intentionally omitted from defaults so StripDefaults
        -- never removes it on logout. It is set to true after first capture
        -- and must survive profile switches and reloads.
        -- _capturedOnce = nil,
        -- CDM Look
        reskinBorders   = true,
        -- Bar Glows (per-spec)
        spec            = {},
        activeSpecKey   = "0",
        -- CDM Bars (our replacement for Blizzard CDM)
        cdmBars = {
            enabled = true,
            hideBlizzard = true,
            rotationHelperEnabled = false,
            rotationHelperGlowStyle = 5,
            -- The 3 default bars (match Blizzard CDM)
            bars = {
                {
                    key = "cooldowns", name = "Cooldowns", enabled = true,
                    iconSize = 42, numRows = 1, spacing = 2,
                    borderSize = 1, borderR = 0, borderG = 0, borderB = 0, borderA = 1,
                    borderClassColor = false,
                    bgR = 0.08, bgG = 0.08, bgB = 0.08, bgA = 0.6,
                    iconZoom = 0.08, iconShape = "none",
                    verticalOrientation = false, barBgEnabled = false, barBgAlpha = 1.0,
                    barBgR = 0, barBgG = 0, barBgB = 0,
                    borderThickness = "thin",
                    anchorTo = "none", anchorPosition = "left",
                    anchorOffsetX = 0, anchorOffsetY = 0,
                    barVisibility = "always", housingHideEnabled = true,
                    visHideHousing = true, visOnlyInstances = false,
                    visHideMounted = false, visHideNoTarget = false, visHideNoEnemy = false,
                    showCooldownText = true, showTooltip = false, showKeybind = false,
                    keybindSize = 10, keybindOffsetX = 2, keybindOffsetY = -2,
                    keybindR = 1, keybindG = 1, keybindB = 1, keybindA = 0.9,
                },
                {
                    key = "utility", name = "Utility", enabled = true,
                    iconSize = 36, numRows = 1, spacing = 2,
                    borderSize = 1, borderR = 0, borderG = 0, borderB = 0, borderA = 1,
                    borderClassColor = false,
                    bgR = 0.08, bgG = 0.08, bgB = 0.08, bgA = 0.6,
                    iconZoom = 0.08, iconShape = "none",
                    verticalOrientation = false, barBgEnabled = false, barBgAlpha = 1.0,
                    barBgR = 0, barBgG = 0, barBgB = 0,
                    borderThickness = "thin",
                    anchorTo = "none", anchorPosition = "left",
                    anchorOffsetX = 0, anchorOffsetY = 0,
                    barVisibility = "always", housingHideEnabled = true,
                    visHideHousing = true, visOnlyInstances = false,
                    visHideMounted = false, visHideNoTarget = false, visHideNoEnemy = false,
                    showCooldownText = true, showTooltip = false, showKeybind = false,
                    keybindSize = 10, keybindOffsetX = 2, keybindOffsetY = -2,
                    keybindR = 1, keybindG = 1, keybindB = 1, keybindA = 0.9,
                },
                {
                    key = "buffs", name = "Buffs", enabled = true,
                    iconSize = 32, numRows = 1, spacing = 2,
                    borderSize = 1, borderR = 0, borderG = 0, borderB = 0, borderA = 1,
                    borderClassColor = false,
                    bgR = 0.08, bgG = 0.08, bgB = 0.08, bgA = 0.6,
                    iconZoom = 0.08, iconShape = "none",
                    verticalOrientation = false, barBgEnabled = false, barBgAlpha = 1.0,
                    barBgR = 0, barBgG = 0, barBgB = 0,
                    borderThickness = "thin",
                    anchorTo = "none", anchorPosition = "left",
                    anchorOffsetX = 0, anchorOffsetY = 0,
                    barVisibility = "always", housingHideEnabled = true,
                    hideBuffsWhenInactive = true,
                    visHideHousing = true, visOnlyInstances = false,
                    visHideMounted = false, visHideNoTarget = false, visHideNoEnemy = false,
                    showCooldownText = true, showTooltip = false, showKeybind = false,
                    keybindSize = 10, keybindOffsetX = 2, keybindOffsetY = -2,
                    keybindR = 1, keybindG = 1, keybindB = 1, keybindA = 0.9,
                },
            },
        },
        -- Saved positions for CDM bars (keyed by bar key)
        cdmBarPositions = {},
    },
}

-------------------------------------------------------------------------------
--  Dedicated spell assignment store helpers
--  Lives at EllesmereUIDB.spellAssignments, completely separate from profiles.
--  Consolidated into a single local table to stay within Lua 5.1's 200 local
--  variable limit for the main chunk.
-------------------------------------------------------------------------------
local SpellStore = {}

function SpellStore.Get()
    if not EllesmereUIDB then EllesmereUIDB = {} end
    if not EllesmereUIDB.spellAssignments then
        EllesmereUIDB.spellAssignments = { specProfiles = {} }
    end
    return EllesmereUIDB.spellAssignments
end

function SpellStore.GetSpecProfiles()
    return SpellStore.Get().specProfiles
end

-- (SpellStore.GetBarGlows removed -- Bar Glows disabled pending rewrite)

-------------------------------------------------------------------------------
--  Direct spell data accessor (single source of truth)
--  Returns the spell table for a bar key under the current spec, creating
--  it if needed. All spell reads/writes go through this -- no copies.
-------------------------------------------------------------------------------
function ns.GetBarSpellData(barKey)
    local specKey = ns.GetActiveSpecKey()
    if not specKey or specKey == "0" then return nil end
    local sp = SpellStore.GetSpecProfiles()
    local prof = sp[specKey]
    if not prof then
        prof = { barSpells = {} }
        sp[specKey] = prof
    end
    if not prof.barSpells then prof.barSpells = {} end
    local bs = prof.barSpells[barKey]
    if not bs then
        bs = {}
        prof.barSpells[barKey] = bs
    end
    -- Migrate old key names to assignedSpells
    if not bs.assignedSpells then
        if bs.trackedSpells then
            bs.assignedSpells = bs.trackedSpells
            bs.trackedSpells = nil
        elseif bs.customSpells then
            bs.assignedSpells = bs.customSpells
            bs.customSpells = nil
        end
    else
        -- Clean up stale keys
        bs.trackedSpells = nil
        bs.customSpells = nil
    end
    return bs
end

-- Variant that accepts an explicit specKey (for validation, migration, etc.)
function ns.GetBarSpellDataForSpec(barKey, specKey)
    if not specKey or specKey == "0" then return nil end
    local sp = SpellStore.GetSpecProfiles()
    local prof = sp[specKey]
    if not prof then return nil end
    if not prof.barSpells then return nil end
    local bs = prof.barSpells[barKey]
    if not bs then return nil end
    -- Migrate old key names to assignedSpells
    if not bs.assignedSpells then
        if bs.trackedSpells then
            bs.assignedSpells = bs.trackedSpells
            bs.trackedSpells = nil
        elseif bs.customSpells then
            bs.assignedSpells = bs.customSpells
            bs.customSpells = nil
        end
    else
        bs.trackedSpells = nil
        bs.customSpells = nil
    end
    return bs
end

-------------------------------------------------------------------------------
--  Spec helpers
-------------------------------------------------------------------------------
local function GetCurrentSpecKey()
    local specIndex = GetSpecialization and GetSpecialization()
    if not specIndex then return "0" end
    local specID = select(1, C_SpecializationInfo.GetSpecializationInfo(specIndex))
    return tostring(specID or 0)
end

-- Per-character activeSpecKey storage.
-- Stored in EllesmereUIDB.cdmActiveSpec[charKey] so shared profiles
-- can never cause cross-character spell contamination.
-- Placed on ns to avoid consuming file-scope local slots.
function ns.GetCharKey()
    local name = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "Unknown"
    return name .. "-" .. realm
end

function ns.GetActiveSpecKey()
    if not EllesmereUIDB then return "0" end
    if not EllesmereUIDB.cdmActiveSpec then EllesmereUIDB.cdmActiveSpec = {} end
    return EllesmereUIDB.cdmActiveSpec[ns.GetCharKey()] or "0"
end

function ns.SetActiveSpecKey(specKey)
    if not EllesmereUIDB then return end
    if not EllesmereUIDB.cdmActiveSpec then EllesmereUIDB.cdmActiveSpec = {} end
    EllesmereUIDB.cdmActiveSpec[ns.GetCharKey()] = specKey
end

-- Validates that activeSpecKey matches the real spec. If not, triggers a full
-- spec switch. Called from multiple events as a safety net so the CDM can
-- NEVER show the wrong spec's icons.
local _specValidated = false
function ns.IsReconcileReady()
    local p = ECME.db and ECME.db.profile
    if not p then return false end
    if not _specValidated then return false end
    local realKey = GetCurrentSpecKey()
    if realKey == "0" then return false end
    if ns.GetActiveSpecKey() ~= realKey then return false end
    local now = GetTime()
    if RECONCILE.lastSpecChangeAt > 0 and (now - RECONCILE.lastSpecChangeAt) < RECONCILE.readyDelay then return false end
    if RECONCILE.lastZoneInAt > 0 and (now - RECONCILE.lastZoneInAt) < RECONCILE.readyDelay then return false end
    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet) then return false end
    for cat = 0, 3 do
        local knownIDs = C_CooldownViewer.GetCooldownViewerCategorySet(cat, false)
        if knownIDs and next(knownIDs) then
            return true
        end
    end
    return true
end

local function ValidateSpec()
    if not ECME.db then return end
    local realKey = GetCurrentSpecKey()
    if realKey == "0" then return end  -- spec API not ready yet
    if ns.GetActiveSpecKey() == realKey then
        _specValidated = true
        return
    end
    -- Mismatch detected -- force a full spec switch
    _specValidated = true
    -- SwitchSpecProfile is defined later; called via ns reference
    if ns.SwitchSpecProfile then
        RECONCILE.lastSpecChangeAt = GetTime()
        ns.SwitchSpecProfile(realKey)
    end
end

local function EnsureSpec(profile, key)
    profile.spec[key] = profile.spec[key] or { mappings = {}, selectedMapping = 1 }
    return profile.spec[key]
end

local function GetStore()
    local p = ECME.db.profile
    local specKey = ns.GetActiveSpecKey()
    return EnsureSpec(p, specKey)
end

local function EnsureMappings(store)
    if not store.mappings then store.mappings = {} end
    if #store.mappings == 0 then
        store.mappings[1] = {
            enabled = false, name = ns.DEFAULT_MAPPING_NAME,
            actionBar = 1, actionButton = 1, cdmSlot = 1,
            hideFromCDM = false, mode = "ACTIVE",
            glowStyle = 1, glowColor = { r = 1, g = 0.82, b = 0.1 },
        }
    end
    store.selectedMapping = tonumber(store.selectedMapping) or 1
    if store.selectedMapping < 1 then store.selectedMapping = 1 end
    if store.selectedMapping > #store.mappings then store.selectedMapping = #store.mappings end
    for _, m in ipairs(store.mappings) do
        if m.enabled == nil then m.enabled = true end
        if m.hideFromCDM == nil then m.hideFromCDM = false end
        if m.mode ~= "MISSING" then m.mode = "ACTIVE" end
        m.glowStyle = tonumber(m.glowStyle) or 1
        if not m.glowColor then m.glowColor = { r = 1, g = 0.82, b = 0.1 } end
        m.name = tostring(m.name or "")
        if type(m.actionBar) ~= "string" or not ns.CDM_BAR_ROOTS[m.actionBar] then
            m.actionBar = tonumber(m.actionBar) or 1
        end
        m.actionButton = tonumber(m.actionButton) or 1
        m.cdmSlot = tonumber(m.cdmSlot) or 1
    end
end

-- Expose for options
ns.GetStore = GetStore
ns.EnsureMappings = EnsureMappings

-------------------------------------------------------------------------------
--  Per-Spec Profile Helpers
--  Saves/restores spell lists, bar glows, and buff bars per specialization.
--  Bar structure, settings, and positions are shared across all specs.
-------------------------------------------------------------------------------
local MAIN_BAR_KEYS = { cooldowns = true, utility = true, buffs = true }

-- Bar types that support talent-aware dormant slot persistence.
-- Trinket/racial/potion and buff bars are excluded.
local TALENT_AWARE_BAR_TYPES = { cooldowns = true, utility = true }

-------------------------------------------------------------------------------
--  Resolve the best spellID from a CooldownViewerCooldownInfo struct.
--  Priority: overrideSpellID > first linkedSpellID > spellID.
--  The base spellID field can be a spec aura (e.g. 137007 "Unholy Death
--  Knight") while the real tracked spell lives in linkedSpellIDs.
-------------------------------------------------------------------------------
local function ResolveInfoSpellID(info)
    if not info then return nil end
    local sid
    if info.overrideSpellID and info.overrideSpellID > 0 then
        sid = info.overrideSpellID
    else
        local linked = info.linkedSpellIDs
        if linked then
            for i = 1, #linked do
                if linked[i] and linked[i] > 0 then sid = linked[i]; break end
            end
        end
        if not sid and info.spellID and info.spellID > 0 then sid = info.spellID end
    end
    return sid
end

-------------------------------------------------------------------------------
--  Resolve the best spellID from a Blizzard CDM viewer child frame.
--  For buff bars the cooldownInfo struct often contains the wrong spellID
--  (spec aura instead of the actual tracked buff). The child frame itself
--  knows the correct spell via GetAuraSpellID / GetSpellID at runtime.
--  Falls back to ResolveInfoSpellID when the frame methods aren't available.
--  ONLY used in out-of-combat paths (snapshot, dropdown, reconcile).
-------------------------------------------------------------------------------
local function ResolveChildSpellID(child)
    if not child then return nil end
    -- Prefer the aura spellID (most accurate for buff viewers).
    -- Wrap comparisons in pcall: these frame methods can return secret
    -- number values in combat which cannot be compared with > 0.
    if child.GetAuraSpellID then
        local ok, auraID = pcall(child.GetAuraSpellID, child)
        if ok and auraID then
            local cmpOk, gt = pcall(function() return auraID > 0 end)
            if cmpOk and gt then return auraID end
        end
    end
    -- Then try the frame's own spellID
    if child.GetSpellID then
        local ok, fid = pcall(child.GetSpellID, child)
        if ok and fid then
            local cmpOk, gt = pcall(function() return fid > 0 end)
            if cmpOk and gt then return fid end
        end
    end
    -- Fall back to cooldownInfo struct
    local cdID = child.cooldownID or (child.cooldownInfo and child.cooldownInfo.cooldownID)
    if cdID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
        return ResolveInfoSpellID(info)
    end
    return nil
end

-------------------------------------------------------------------------------
--  Build a set of currently known (learned) spellIDs across all CDM categories.
--  Uses GetCooldownViewerCategorySet(cat, false) which returns only learned
--  spells, then resolves each cdID to its base spellID.
-------------------------------------------------------------------------------
local function BuildAvailableSpellPool()
    local known = {}
    if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCategorySet then return known end
    for cat = 0, 3 do
        local knownIDs = C_CooldownViewer.GetCooldownViewerCategorySet(cat, false)
        if knownIDs then
            for _, cdID in ipairs(knownIDs) do
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                if info then
                    local primarySid = ResolveInfoSpellID(info)
                    -- Store ALL related spell IDs so reconcile can match
                    -- regardless of whether the bar stores the base ID,
                    -- override ID, or a linked ID.
                    if primarySid and primarySid > 0 then
                        known[primarySid] = true
                    end
                    if info.spellID and info.spellID > 0 then
                        known[info.spellID] = true
                    end
                    if info.overrideSpellID and info.overrideSpellID > 0 then
                        known[info.overrideSpellID] = true
                    end
                    if info.linkedSpellIDs then
                        for _, lsid in ipairs(info.linkedSpellIDs) do
                            if lsid and lsid > 0 then
                                known[lsid] = true
                            end
                        end
                    end
                end
            end
        end
    end
    -- Fallback: also check the full CDM category set (cat, true) which
    -- includes ALL spells for the class regardless of talent selection.
    -- Spells that exist in the full set AND pass IsPlayerSpell are known
    -- even if the viewer hasn't updated yet after a talent swap.
    local _IsPlayerSpell = IsPlayerSpell
    if _IsPlayerSpell then
        for cat = 0, 3 do
            local allIDs = C_CooldownViewer.GetCooldownViewerCategorySet(cat, true)
            if allIDs then
                for _, cdID in ipairs(allIDs) do
                    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                    if info then
                        local sid = ResolveInfoSpellID(info)
                        if sid and sid > 0 and not known[sid] and _IsPlayerSpell(sid) then
                            known[sid] = true
                        end
                        if info.spellID and info.spellID > 0 and not known[info.spellID] and _IsPlayerSpell(info.spellID) then
                            known[info.spellID] = true
                        end
                        if info.overrideSpellID and info.overrideSpellID > 0 and not known[info.overrideSpellID] and _IsPlayerSpell(info.overrideSpellID) then
                            known[info.overrideSpellID] = true
                        end
                    end
                end
            end
        end
    end
    return known
end

--- Deep-copy a table (simple values + nested tables, no metatables/functions)
local function DeepCopy(src)
    if type(src) ~= "table" then return src end
    local copy = {}
    for k, v in pairs(src) do copy[k] = DeepCopy(v) end
    return copy
end

--- Save the current spec's non-spell per-spec data.
--- Spell data lives directly in the global store via ns.GetBarSpellData()
-------------------------------------------------------------------------------
--  Cached bar sizes -- purely cosmetic hint for pre-sizing frames on login
--  so anchored elements don't jump. Has zero impact on spell logic or icons.
--  Stored in EllesmereUIDB.cdmCachedBarSizes[charKey][specKey][barKey] = count
-------------------------------------------------------------------------------
function ns.SaveCachedBarSizes()
    if not EllesmereUIDB then return end
    local charKey = ns.GetCharKey()
    local specKey = ns.GetActiveSpecKey()
    if not specKey or specKey == "0" then return end
    if not EllesmereUIDB.cdmCachedBarSizes then EllesmereUIDB.cdmCachedBarSizes = {} end
    if not EllesmereUIDB.cdmCachedBarSizes[charKey] then EllesmereUIDB.cdmCachedBarSizes[charKey] = {} end
    local frames = ns.cdmBarFrames
    local iconsByKey = ns.cdmBarIcons
    if not frames or not iconsByKey then return end
    local counts = {}
    for key, frame in pairs(frames) do
        local icons = iconsByKey[key]
        if icons then
            local vis = 0
            for _, icon in ipairs(icons) do
                if icon:IsShown() then vis = vis + 1 end
            end
            if vis > 0 then counts[key] = vis end
        end
    end
    EllesmereUIDB.cdmCachedBarSizes[charKey][specKey] = counts
end

--- and never needs copying.
local function SaveCurrentSpecProfile()
    local p = ECME.db.profile
    local specKey = ns.GetActiveSpecKey()
    if not specKey or specKey == "0" then return end
    local specProfiles = SpellStore.GetSpecProfiles()
    if not specProfiles[specKey] then specProfiles[specKey] = { barSpells = {} } end
    local prof = specProfiles[specKey]

    -- Bar Glows (from dedicated store)
    local bgData = ns.GetBarGlows and ns.GetBarGlows()
    if bgData then prof.barGlows = DeepCopy(bgData) end

    -- Tracked Buff Bars + positions (from profile)
    if p.trackedBuffBars then
        prof.trackedBuffBars = DeepCopy(p.trackedBuffBars)
    end
    if p.tbbPositions then
        prof.tbbPositions = DeepCopy(p.tbbPositions)
    end

    -- Snapshot visible icon counts for pre-sizing on next login
    ns.SaveCachedBarSizes()
end

--- Restore non-spell per-spec data for a spec.
--- Spell data is read directly from the global store by all consumers.
local function LoadSpecProfile(specKey)
    local p = ECME.db.profile
    local specProfiles = SpellStore.GetSpecProfiles()
    local prof = specProfiles[specKey]

    if prof then
        -- Restore Bar Glows to dedicated store
        if prof.barGlows then
            SpellStore.Get().barGlows = DeepCopy(prof.barGlows)
        end
        -- Restore Tracked Buff Bars + positions to profile
        if prof.trackedBuffBars ~= nil then
            p.trackedBuffBars = DeepCopy(prof.trackedBuffBars)
        end
        if prof.tbbPositions ~= nil then
            p.tbbPositions = DeepCopy(prof.tbbPositions)
        end
    else
        -- No saved profile for this spec: start fresh
        SpellStore.Get().barGlows = {
            enabled = true, selectedBar = 1, assignments = {},
        }
        p.trackedBuffBars = { selectedBar = 1, bars = {} }
        p.tbbPositions = nil
    end
end

-- Timestamp of the last spec switch. Used to suppress TalentAwareReconcile
-- during the transition window where spell data may be stale.
local _lastSpecSwitchTime = 0

--- Full spec switch: save non-spell data, update active spec, rebuild everything.
--- Spell data is already in the global store keyed by spec -- switching the
--- active spec key is all that's needed for spells to "switch".
local function SwitchSpecProfile(newSpecKey)
    _lastSpecSwitchTime = GetTime()

    local p = ECME.db.profile
    local oldSpecKey = ns.GetActiveSpecKey()

    -- Save non-spell per-spec data for the old spec
    if oldSpecKey and oldSpecKey ~= "0" then
        SaveCurrentSpecProfile()
    end

    -- Update active spec (per-character)
    ns.SetActiveSpecKey(newSpecKey)
    EnsureSpec(p, newSpecKey)

    -- Load non-spell per-spec data for the new spec
    LoadSpecProfile(newSpecKey)

    -- Rebuild all CDM systems (deferred so Blizzard CDM frames are ready)
    C_Timer.After(0.5, function()
        BuildAllCDMBars()
        RegisterCDMUnlockElements()
        -- Rebuild Bar Glows + Tracking Bars for the new spec
        -- (LoadSpecProfile already restored their data from specProfiles)
        if ns.RequestBarGlowUpdate then ns.RequestBarGlowUpdate() end
        if ns.BuildTrackedBuffBars then ns.BuildTrackedBuffBars() end
        -- Queue reanchor so viewer hooks pick up the new spec's frames
        if ns.QueueReanchor then ns.QueueReanchor() end

        -- Refresh options panel if open
        if EllesmereUI and EllesmereUI._mainFrame and EllesmereUI._mainFrame:IsShown() then
            if EllesmereUI.InvalidateContentHeaderCache then
                EllesmereUI:InvalidateContentHeaderCache()
            end
            if EllesmereUI.RefreshPage then
                EllesmereUI:RefreshPage(true)
            end
        end
    end)
end
ns.SwitchSpecProfile = SwitchSpecProfile

-------------------------------------------------------------------------------
--  CDM Bar Roots
-------------------------------------------------------------------------------
ns.CDM_BAR_ROOTS = {
    CDM_COOLDOWN = "EssentialCooldownViewer",
    CDM_UTILITY  = "UtilityCooldownViewer",
}

-------------------------------------------------------------------------------
--  Action Button Lookup (supports Blizzard and popular bar addons)
-------------------------------------------------------------------------------
local blizzBarNames = {
    [1] = "ActionButton",
    [2] = "MultiBarBottomLeftButton",
    [3] = "MultiBarBottomRightButton",
    [4] = "MultiBarRightButton",
    [5] = "MultiBarLeftButton",
    [6] = "MultiBar5Button",
    [7] = "MultiBar6Button",
    [8] = "MultiBar7Button",
}

-- EAB slot offsets match BAR_SLOT_OFFSETS in EllesmereUIActionBars.lua
local eabSlotOffsets = { 0, 60, 48, 24, 36, 144, 156, 168 }

local actionButtonCache = {}

local function GetActionButton(bar, i)
    bar = bar or 1
    local cacheKey = bar * 100 + i
    if actionButtonCache[cacheKey] then return actionButtonCache[cacheKey] end
    -- Try EABButton first (EllesmereUIActionBars creates these when Blizzard
    -- buttons are unavailable, e.g. when Dominos hides ActionButton1-12)
    local eabSlot = (eabSlotOffsets[bar] or 0) + i
    local btn = _G["EABButton" .. eabSlot]
    -- Fall back to standard Blizzard button names
    if not btn then
        local prefix = blizzBarNames[bar]
        btn = prefix and _G[prefix .. i]
    end
    if btn then actionButtonCache[cacheKey] = btn end
    return btn
end

-------------------------------------------------------------------------------
--  CDM Slot Helpers
-------------------------------------------------------------------------------
local function FindCooldown(frame)
    if not frame then return end
    local cd = frame.cooldown or frame.Cooldown
    if cd then return cd end
    for i = 1, frame:GetNumChildren() do
        local child = select(i, frame:GetChildren())
        if child and child.GetObjectType and child:GetObjectType() == "Cooldown" then
            return child
        end
    end
end

local function SlotSortComparator(a, b)
    local ax, ay = a:GetCenter()
    local bx, by = b:GetCenter()
    ax, ay, bx, by = ax or 0, ay or 0, bx or 0, by or 0
    if math.abs(ay - by) > 2 then return ay > by end
    return ax < bx
end

local cachedSlots, cacheTime = nil, 0

local function GetSortedSlots(forceRefresh)
    local now = GetTime()
    if not forceRefresh and cachedSlots and (now - cacheTime) < 0.5 then
        return cachedSlots
    end
    local root = _G.BuffIconCooldownViewer
    if not root or not root.GetChildren then cachedSlots = nil; return nil end
    local slots = {}
    for i = 1, root:GetNumChildren() do
        local c = select(i, root:GetChildren())
        if c and c.GetCenter and FindCooldown(c) then
            slots[#slots + 1] = c
        end
    end
    if #slots == 0 then cachedSlots = nil; return nil end
    table.sort(slots, SlotSortComparator)
    cachedSlots = slots
    cacheTime = now
    return slots
end

local function GetAllCDMSlots(root)
    if not root or not root.GetChildren then return {} end
    local slots = {}
    for i = 1, root:GetNumChildren() do
        local c = select(i, root:GetChildren())
        if c and c.GetWidth and c:GetWidth() > 5 then
            slots[#slots + 1] = c
        end
    end
    return slots
end

local function GetCDMBarButton(barKey, slotIndex)
    local rootName = ns.CDM_BAR_ROOTS[barKey]
    if not rootName then return nil end
    local root = _G[rootName]
    if not root or not root.GetChildren then return nil end
    local slots = {}
    for i = 1, root:GetNumChildren() do
        local c = select(i, root:GetChildren())
        if c and c.GetWidth and c:GetWidth() > 5 then
            slots[#slots + 1] = c
        end
    end
    if #slots == 0 then return nil end
    table.sort(slots, SlotSortComparator)
    return slots[slotIndex]
end

local function GetTargetButton(actionBar, actionButtonIndex)
    if type(actionBar) == "string" and ns.CDM_BAR_ROOTS[actionBar] then
        return GetCDMBarButton(actionBar, actionButtonIndex)
    end
    return GetActionButton(tonumber(actionBar) or 1, actionButtonIndex)
end

-------------------------------------------------------------------------------
--  CDM Look: Border Reskinning
-------------------------------------------------------------------------------
local cdmBorderFrames = {}

local function GetOrCreateCDMBorder(slot)
    local function SafeEq(a, b)
        return a == b
    end

    if cdmBorderFrames[slot] then return cdmBorderFrames[slot] end

    slot.__ECMEHidden   = slot.__ECMEHidden or {}
    slot.__ECMEIcon     = slot.__ECMEIcon or nil
    slot.__ECMECooldown = slot.__ECMECooldown or nil

    if not slot.__ECMEScanned then
        slot.__ECMEHidden = {}
        slot.__ECMEIcon = nil
        slot.__ECMECooldown = nil

        for ri = 1, slot:GetNumRegions() do
            local region = select(ri, slot:GetRegions())
            if region and region.GetObjectType then
                local objType = region:GetObjectType()
                if objType == "MaskTexture" then
                    slot.__ECMEHidden[#slot.__ECMEHidden + 1] = region
                elseif objType == "Texture" then
                    local ok, rawLayer = pcall(region.GetDrawLayer, region)
                    if ok and rawLayer ~= nil then
                        local okB, isBorder   = pcall(SafeEq, rawLayer, "BORDER")
                        local okO, isOverlay  = pcall(SafeEq, rawLayer, "OVERLAY")
                        local okA, isArtwork  = pcall(SafeEq, rawLayer, "ARTWORK")
                        local okG, isBG       = pcall(SafeEq, rawLayer, "BACKGROUND")
                        if (okB and isBorder) or (okO and isOverlay) then
                            slot.__ECMEHidden[#slot.__ECMEHidden + 1] = region
                        elseif not slot.__ECMEIcon and ((okA and isArtwork) or (okG and isBG)) then
                            slot.__ECMEIcon = region
                        end
                    end
                end
            end
        end

        for ci = 1, slot:GetNumChildren() do
            local child = select(ci, slot:GetChildren())
            if child and child.GetObjectType then
                local objType = child:GetObjectType()
                if objType == "MaskTexture" then
                    slot.__ECMEHidden[#slot.__ECMEHidden + 1] = child
                elseif objType == "Cooldown" then
                    slot.__ECMECooldown = child
                    for k = 1, child:GetNumChildren() do
                        local cdChild = select(k, child:GetChildren())
                        if cdChild and cdChild.GetObjectType and cdChild:GetObjectType() == "MaskTexture" then
                            slot.__ECMEHidden[#slot.__ECMEHidden + 1] = cdChild
                        end
                    end
                    for k = 1, child:GetNumRegions() do
                        local cdRegion = select(k, child:GetRegions())
                        if cdRegion and cdRegion.GetObjectType and cdRegion:GetObjectType() == "MaskTexture" then
                            slot.__ECMEHidden[#slot.__ECMEHidden + 1] = cdRegion
                        end
                    end
                end
            end
        end
        slot.__ECMEScanned = true
    end

    local iconSize = slot.__ECMEIcon and slot.__ECMEIcon:GetWidth() or slot:GetWidth() or 35
    local edgeSize = iconSize < 35 and 2 or 1

    local border = CreateFrame("Frame", nil, slot)
    if slot.__ECMEIcon then border:SetAllPoints(slot.__ECMEIcon) else border:SetAllPoints() end
    border:SetFrameLevel(slot:GetFrameLevel() + 5)
    EllesmereUI.PP.CreateBorder(border, 0, 0, 0, 1, edgeSize)

    cdmBorderFrames[slot] = border
    return border
end

local CDM_ROOT_NAMES = {
    "BuffIconCooldownViewer", "BuffBarCooldownViewer",
    "EssentialCooldownViewer", "UtilityCooldownViewer",
}

local function UpdateAllCDMBorders()
    local reskin = ECME.db and ECME.db.profile.reskinBorders
    local crop = 0.06

    for _, rootName in ipairs(CDM_ROOT_NAMES) do
        local root = _G[rootName]
        if root then
            for _, slot in ipairs(GetAllCDMSlots(root)) do
                local border = GetOrCreateCDMBorder(slot)
                if reskin then
                    border:Show()
                    if slot.__ECMEIcon then slot.__ECMEIcon:SetTexCoord(crop, 1 - crop, crop, 1 - crop) end
                    if slot.__ECMECooldown then
                        slot.__ECMECooldown:SetSwipeTexture("Interface\\Buttons\\WHITE8x8")
                    end
                    for _, h in ipairs(slot.__ECMEHidden) do
                        if h and h.Hide then h:Hide() end
                    end
                else
                    border:Hide()
                    if slot.__ECMEIcon then slot.__ECMEIcon:SetTexCoord(0, 1, 0, 1) end
                    if slot.__ECMECooldown then
                        slot.__ECMECooldown:SetSwipeTexture("Interface\\Cooldown\\cooldown-bling")
                    end
                    for _, h in ipairs(slot.__ECMEHidden) do
                        if h and h.Show then h:Show() end
                    end
                end
            end
        end
    end
end
ns.UpdateAllCDMBorders = UpdateAllCDMBorders

-------------------------------------------------------------------------------
--  Native Glow System -- engines provided by shared EllesmereUI_Glows.lua
--  CDM keeps its own GLOW_STYLES (different scale values) and Start/Stop
--  wrappers that handle CDM-specific shape glow (icon masks/borders).
-------------------------------------------------------------------------------
local _G_Glows = EllesmereUI.Glows
local GLOW_STYLES = {
    { name = "Pixel Glow",           procedural = true },
    { name = "Custom Shape Glow",    shapeGlow = true },
    { name = "Action Button Glow",   buttonGlow = true },
    { name = "Auto-Cast Shine",      autocast = true },
    { name = "GCD",                  atlas = "RotationHelper_Ants_Flipbook", texPadding = 1.6 },
    { name = "Modern WoW Glow",      atlas = "UI-HUD-ActionBar-Proc-Loop-Flipbook", texPadding = 1.4 },
    { name = "Classic WoW Glow",     texture = "Interface\\SpellActivationOverlay\\IconAlertAnts",
      rows = 5, columns = 5, frames = 25, duration = 0.3, frameW = 48, frameH = 48, texPadding = 1.25 },
}
ns.GLOW_STYLES = GLOW_STYLES

StartNativeGlow = function(overlay, style, cr, cg, cb, opts)
    if not overlay then return end
    local styleIdx = tonumber(style) or 1
    if styleIdx < 1 or styleIdx > #GLOW_STYLES then styleIdx = 1 end
    local entry = GLOW_STYLES[styleIdx]

    _G_Glows.StopAllGlows(overlay)

    local parent = overlay:GetParent()
    if not parent then return end
    local pW, pH = parent:GetWidth(), parent:GetHeight()
    local sz = math.min(pW, pH)
    if sz < 5 then sz = 36 end
    cr = cr or 1; cg = cg or 1; cb = cb or 1

    if entry.shapeGlow then
        -- CDM-specific: read shape mask/border from the icon frame
        local icon = parent
        local shape = icon._shapeApplied and icon._shapeName or nil
        local maskPath   = shape and CDM_SHAPES.masks[shape]
        local borderPath = shape and CDM_SHAPES.borders[shape]
        _G_Glows.StartShapeGlow(overlay, sz, cr, cg, cb, 1.20, {
            maskPath   = maskPath,
            borderPath = borderPath,
            shapeMask  = icon._shapeMask,
        })
    elseif entry.procedural then
        local N = opts and opts.N or 8
        local th = opts and opts.th or 2
        local period = opts and opts.period or 4
        local lineLen = math.floor((sz + sz) * (2 / N - 0.1))
        lineLen = math.min(lineLen, sz)
        if lineLen < 1 then lineLen = 1 end
        _G_Glows.StartProceduralAnts(overlay, N, th, period, lineLen, cr, cg, cb, sz)
    elseif entry.buttonGlow then
        _G_Glows.StartButtonGlow(overlay, sz, cr, cg, cb)
    elseif entry.autocast then
        _G_Glows.StartAutoCastShine(overlay, sz, cr, cg, cb, 1.0)
    else
        _G_Glows.StartFlipBookGlow(overlay, sz, entry, cr, cg, cb)
    end

    overlay._glowActive = true
    overlay:SetAlpha(1)
    overlay:Show()
end

StopNativeGlow = function(overlay)
    if not overlay then return end
    _G_Glows.StopAllGlows(overlay)
    overlay._glowActive = false
    overlay:SetAlpha(0)
end
ns.StartNativeGlow = StartNativeGlow
ns.StopNativeGlow = StopNativeGlow

-- Our bar frames (keyed by bar key)
local cdmBarFrames = {}
-- Icon frames per bar (keyed by bar key, array of icon frames)
local cdmBarIcons = {}
-- Fast barData lookup by key (rebuilt in BuildAllCDMBars, avoids linear scan per tick)
local barDataByKey = {}

-- Expose our CDM bar frames so the glow system can reference them
ns.GetCDMBarFrame = function(barKey)
    return cdmBarFrames[barKey]
end
-- Global accessor for cross-addon frame lookups
_G._ECME_GetBarFrame = function(barKey)
    return cdmBarFrames[barKey]
end
-- Global accessor: apply a spec profile to the live bars (used by profile import)
-- Loads non-spell per-spec data and rebuilds bars. Spell data is already
-- in the global store and will be read directly by BuildAllCDMBars.
_G._ECME_LoadSpecProfile = function(specKey)
    LoadSpecProfile(specKey)
    BuildAllCDMBars()
end
-- Global accessor: get the current spec key string (e.g. "250")
_G._ECME_GetCurrentSpecKey = function()
    return GetCurrentSpecKey()
end
-- Global accessor: returns a set of all spellIDs currently in the user's CDM
-- viewer (all categories, displayed + known). Used by profile import to filter
-- out spells the importing user does not have in their CDM.
_G._ECME_GetCDMSpellSet = function()
    return BuildAvailableSpellPool()
end
ns.GetCDMBarIcons = function(barKey)
    return cdmBarIcons[barKey]
end

-------------------------------------------------------------------------------
--  Proc Glow System: hooks Blizzard's SpellAlertManager to show proc glows
--  on our CDM icons when Blizzard fires ShowAlert/HideAlert on CDM children.
--  Custom bars use SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE events instead.
-------------------------------------------------------------------------------
local PROC_GLOW_STYLE = 6  -- "Modern WoW Glow" flipbook

-- Reverse lookup: Blizzard CDM viewer frame name  our bar key
local _blizzViewerToBarKey = {
    EssentialCooldownViewer = "cooldowns",
    UtilityCooldownViewer   = "utility",
    BuffIconCooldownViewer  = "buffs",
}

-- Walk up from a frame to find which Blizzard CDM viewer it belongs to.
-- Also handles reparented frames (hook system) via the _barKey field.
local function GetBarKeyForBlizzChild(frame)
    -- Fast path: reparented frame with _barKey set by hook system
    if frame._barKey then return frame._barKey, frame end
    local current = frame
    while current do
        local parent = current:GetParent()
        if not parent then return nil end
        -- Check if parent is one of our CDM bar containers
        if parent._barKey then return parent._barKey, current end
        local name = parent.GetName and parent:GetName()
        if name and _blizzViewerToBarKey[name] then
            return _blizzViewerToBarKey[name], current
        end
        current = parent
    end
    return nil
end

local ResolveBlizzChildSpellID  -- forward-declare (defined below)

-- Find our icon that mirrors a given Blizzard CDM child.
-- Falls back to spellID + override matching for proc glows on transformed spells.
-- In hook mode, the icon IS the Blizzard child (direct identity check).
local function FindOurIconForBlizzChild(barKey, blizzChild)
    local icons = cdmBarIcons[barKey]
    if not icons then return nil end
    for _, icon in ipairs(icons) do
        if icon == blizzChild or icon._blizzChild == blizzChild then return icon end
    end
    -- Fallback: match by spellID (covers override spells like HST -> Storm Stream)
    local alertSid = ResolveBlizzChildSpellID(blizzChild)
    if alertSid then
        for _, icon in ipairs(icons) do
            if icon._spellID == alertSid then return icon end
        end
        -- Check override mapping (base spell <-> override)
        for _, icon in ipairs(icons) do
            local iconSid = icon._spellID
            if iconSid and C_SpellBook and C_SpellBook.FindSpellOverrideByID then
                local ovr = C_SpellBook.FindSpellOverrideByID(iconSid)
                if ovr and ovr == alertSid then return icon end
            end
        end
    end
    return nil
end

-- Resolve spellID from a Blizzard CDM child (for IsSpellOverlayed guard and proc glow matching)
ResolveBlizzChildSpellID = function(blizzChild)
    local cdID = blizzChild.cooldownID
    if not cdID and blizzChild.cooldownInfo then
        cdID = blizzChild.cooldownInfo.cooldownID
    end
    if cdID then
        local info = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
            and C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
        if info then return ResolveInfoSpellID(info) end
    end
    return nil
end

-- Show proc glow on one of our icons (separate from active state glow)
local function ShowProcGlow(icon, cr, cg, cb)
    if not icon or not icon._glowOverlay then return end
    -- Don't double-start if already showing proc glow
    if icon._procGlowActive then return end
    -- If active state glow is running, stop it first (proc glow takes priority)
    if icon._isActive and icon._glowOverlay._glowActive then
        StopNativeGlow(icon._glowOverlay)
    end
    StartNativeGlow(icon._glowOverlay, PROC_GLOW_STYLE, cr, cg, cb)
    icon._procGlowActive = true
end

local function StopProcGlow(icon)
    if not icon or not icon._procGlowActive then return end
    StopNativeGlow(icon._glowOverlay)
    icon._procGlowActive = false
end

-- Proc glow color: hardcoded gold (#ffc923)
local PROC_GLOW_COLOR = { 1.0, 0.788, 0.137 }

-- Install hooks on ActionButtonSpellAlertManager (called once during init)
local _procGlowHooksInstalled = false
local function InstallProcGlowHooks()
    if _procGlowHooksInstalled then return end
    if not ActionButtonSpellAlertManager then return end

    hooksecurefunc(ActionButtonSpellAlertManager, "ShowAlert", function(_, frame)
        if not frame then return end
        local barKey, cdmChild = GetBarKeyForBlizzChild(frame)
        if not barKey or not cdmChild then return end

        -- Hide Blizzard's built-in SpellActivationAlert on the CDM child
        if cdmChild.SpellActivationAlert then
            cdmChild.SpellActivationAlert:SetAlpha(0)
            cdmChild.SpellActivationAlert:Hide()
        end

        -- Defer by one frame so the icon mapping from UpdateCDMBarIcons is current
        C_Timer.After(0, function()
            local ourIcon = FindOurIconForBlizzChild(barKey, cdmChild)
            if not ourIcon then return end
            -- Re-suppress Blizzard alert (may have been re-shown)
            if cdmChild.SpellActivationAlert then
                cdmChild.SpellActivationAlert:SetAlpha(0)
                cdmChild.SpellActivationAlert:Hide()
            end
            local cr, cg, cb = PROC_GLOW_COLOR[1], PROC_GLOW_COLOR[2], PROC_GLOW_COLOR[3]
            ShowProcGlow(ourIcon, cr, cg, cb)
            -- Force icon texture re-evaluation so override textures apply immediately
            ourIcon._lastTex = nil
        end)
    end)

    hooksecurefunc(ActionButtonSpellAlertManager, "HideAlert", function(_, frame)
        if not frame then return end
        local barKey, cdmChild = GetBarKeyForBlizzChild(frame)
        if not barKey or not cdmChild then return end
        local ourIcon = FindOurIconForBlizzChild(barKey, cdmChild)
        if not ourIcon or not ourIcon._procGlowActive then return end

        -- Guard: CDM may fire HideAlert during internal refresh cycles even though
        -- the spell is still procced. Check IsSpellOverlayed before killing the glow.
        local spellID = ResolveBlizzChildSpellID(cdmChild)
        if spellID and C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed then
            local ok, overlayed = pcall(C_SpellActivationOverlay.IsSpellOverlayed, spellID)
            if ok and overlayed then
                -- Spell still active  suppress Blizzard's alert again and keep our glow
                if cdmChild.SpellActivationAlert then
                    cdmChild.SpellActivationAlert:SetAlpha(0)
                    cdmChild.SpellActivationAlert:Hide()
                end
                return
            end
        end

        StopProcGlow(ourIcon)
        -- Force icon texture re-evaluation so the original texture restores immediately
        ourIcon._lastTex = nil
    end)

    _procGlowHooksInstalled = true
end

-- (OnProcGlowEvent removed -- all bars use hook-based proc glows via
-- InstallProcGlowHooks / ActionButtonSpellAlertManager now)
local function OnProcGlowEvent() end
ns.OnProcGlowEvent = OnProcGlowEvent


-------------------------------------------------------------------------------
--  CDM Bars: Our replacement for Blizzard's Cooldown Manager
--  Captures Blizzard positions on first login, then creates our own bars.
-------------------------------------------------------------------------------
local CDM_FONT_FALLBACK = "Interface\\AddOns\\EllesmereUI\\media\\fonts\\Expressway.TTF"
local function GetCDMFont()
    if EllesmereUI and EllesmereUI.GetFontPath then
        return EllesmereUI.GetFontPath("cdm")
    end
    return CDM_FONT_FALLBACK
end
local function GetCDMOutline()
    return "OUTLINE"
end
local function SetBlizzCDMFont(fs, font, size, r, g, b)
    if not (fs and fs.SetFont) then return end
    fs:SetFont(font, size, "OUTLINE")
    fs:SetShadowOffset(0, 0)
    if r then fs:SetTextColor(r, g, b) end
end

-- Blizzard CDM frame names
local BLIZZ_CDM_FRAMES = {
    cooldowns = "EssentialCooldownViewer",
    utility   = "UtilityCooldownViewer",
    buffs     = "BuffIconCooldownViewer",
}

-- BuffBarCooldownViewer is the Blizzard buff bar strip. We hide it alongside
-- the icon viewer so Blizzard's default buff display is fully suppressed when
-- the user has CDM hiding enabled. Our Tracked Buff Bars replace it.
local BLIZZ_CDM_FRAMES_SECONDARY = {
    buffs = "BuffBarCooldownViewer",
}

-- CDM category numbers per bar key (for C_CooldownViewer API)
local CDM_BAR_CATEGORIES = {
    cooldowns = { 0, 1 },    -- Essential + Utility
    utility   = { 0, 1 },    -- Essential + Utility
    buffs     = { 2, 3 },    -- Tracked Buff + Tracked Debuff
}

-- Maximum number of custom bars a user can create
local MAX_CUSTOM_BARS = 10

-- Cached player info (set once at PLAYER_LOGIN)
local _playerRace, _playerClass

-- Forward declarations
local BuildCDMBar, LayoutCDMBar, HideBlizzardCDM, RestoreBlizzardCDM
local CaptureCDMPositions, ApplyCDMBarPosition, ApplyShapeToCDMIcon

-------------------------------------------------------------------------------
--  Capture Blizzard CDM positions (first login only)
-------------------------------------------------------------------------------
CaptureCDMPositions = function()
    local captured = {}
    local uiW, uiH = UIParent:GetSize()
    local uiScale = UIParent:GetEffectiveScale()

    for barKey, frameName in pairs(BLIZZ_CDM_FRAMES) do
        local frame = _G[frameName]
        if frame then
            local data = {}

            -- Read the frame's scale (used to adjust icon size capture)
            local frameScale = frame:GetScale()
            if not frameScale or frameScale < 0.1 then frameScale = 1 end

            -- Icon size + spacing: read from child icons.
            -- Blizzard CDM icons have a base size and a per-icon scale driven
            -- by the IconSize percentage slider. Spacing is measured from the
            -- gap between two adjacent visible icons in parent coordinates.
            local childCount = frame:GetNumChildren()
            local numDistinctY = {}
            local shownIcons = {}
            for ci = 1, childCount do
                local child = select(ci, frame:GetChildren())
                if child and child.Icon then
                    local cw = child:GetWidth()
                    local cs = child:GetScale()
                    if cw and cw > 1 and not data.iconSize then
                        local visual = cw * (cs or 1)
                        data.iconSize = math.floor(visual + 0.5)
                    end
                    -- Collect shown icons for spacing measurement
                    if child:IsShown() then
                        shownIcons[#shownIcons + 1] = child
                        -- Track distinct Y positions for row counting
                        if child:GetPoint(1) then
                            local _, _, _, _, cy = child:GetPoint(1)
                            if cy then
                                numDistinctY[math.floor(cy + 0.5)] = true
                            end
                        end
                    end
                end
            end

            -- Spacing: measure gap between adjacent visible icons
            if #shownIcons >= 2 and data.iconSize then
                -- Sort by left edge so we measure truly adjacent icons
                table.sort(shownIcons, function(a, b)
                    return (a:GetLeft() or 0) < (b:GetLeft() or 0)
                end)
                -- Find the smallest step between any two consecutive sorted icons
                -- GetLeft() returns UIParent-coordinate-space values
                local bestStep = nil
                for si = 1, #shownIcons - 1 do
                    local aLeft = shownIcons[si]:GetLeft()
                    local bLeft = shownIcons[si + 1]:GetLeft()
                    if aLeft and bLeft then
                        local dist = bLeft - aLeft
                        if dist > 0 and (not bestStep or dist < bestStep) then
                            bestStep = dist
                        end
                    end
                end
                if bestStep then
                    -- bestStep is in UIParent coords; iconSize = cw * cs (visual size in parent-of-icon coords)
                    -- Convert bestStep from UIParent coords to icon-parent coords
                    -- icon-parent coord ? UIParent coord multiplier = frame.effectiveScale / UIParent.effectiveScale
                    -- So to go back: divide by that
                    local frameEff = frame:GetEffectiveScale()
                    local uiEff = UIParent:GetEffectiveScale()
                    local parentStep = bestStep * uiEff / frameEff
                    -- Now parentStep is in frame coords; but iconSize = cw * cs, and positions in frame use cw units
                    -- So step in iconSize units = parentStep * cs
                    local cs = shownIcons[1]:GetScale() or 1
                    local stepInIconUnits = parentStep * cs
                    local gap = stepInIconUnits - data.iconSize
                    if gap < 0 then gap = 0 end
                    data.spacing = math.floor(gap + 0.5)
                end
            end

            -- Rows: count distinct Y positions among visible icon children
            local rowCount = 0
            for _ in pairs(numDistinctY) do rowCount = rowCount + 1 end
            if rowCount >= 1 then
                data.numRows = rowCount
            end

            -- Orientation from frame property
            if frame.isHorizontal ~= nil then
                data.isHorizontal = frame.isHorizontal
            end

            -- Position (center-based, in UIParent coordinates)
            if frame:GetPoint(1) then
                local cx, cy = frame:GetCenter()
                if cx and cy then
                    local bScale = frame:GetEffectiveScale()
                    cx = cx * bScale / uiScale
                    cy = cy * bScale / uiScale
                    data.point = "CENTER"
                    data.relPoint = "CENTER"
                    data.x = cx - (uiW / 2)
                    data.y = cy - (uiH / 2)
                end
            end

            captured[barKey] = data
        end
    end

    return captured
end

-------------------------------------------------------------------------------
--  Hide / Restore Blizzard CDM
-------------------------------------------------------------------------------
HideBlizzardCDM = function()
    -- Shrink viewers to 1x1 and position at top-left corner.
    -- Do NOT hook SetPoint or force off-screen -- Blizzard's internal
    -- layout cycle must run unimpeded so it can call Hide() on inactive
    -- buff frames (needed for hideBuffsWhenInactive).
    -- Child frames are reparented to UIParent by CollectAndReanchor.
    local allFrameNames = {}
    for _, fn in pairs(BLIZZ_CDM_FRAMES) do allFrameNames[#allFrameNames + 1] = fn end
    for _, fn in pairs(BLIZZ_CDM_FRAMES_SECONDARY) do allFrameNames[#allFrameNames + 1] = fn end
    for _, frameName in ipairs(allFrameNames) do
        local frame = _G[frameName]
        if frame then
            local fc = FC(frame)
            if not fc.hidden then
                fc.origPoints = {}
                for i = 1, frame:GetNumPoints() do
                    fc.origPoints[i] = { frame:GetPoint(i) }
                end
                fc.hidden = true
            end
            -- Leave viewer positioned normally so Blizzard's internal
            -- layout system (including HideWhenInactive) keeps working.
            -- Make it non-interactive and invisible via alpha.
            frame:SetAlpha(0)
            frame:EnableMouse(false)
            if frame.EnableMouseMotion then frame:EnableMouseMotion(false) end
        end
    end
end

RestoreBlizzardCDM = function()
    local allFrameNames = {}
    for _, fn in pairs(BLIZZ_CDM_FRAMES) do allFrameNames[#allFrameNames + 1] = fn end
    for _, fn in pairs(BLIZZ_CDM_FRAMES_SECONDARY) do allFrameNames[#allFrameNames + 1] = fn end
    for _, frameName in ipairs(allFrameNames) do
        local frame = _G[frameName]
        local fc = frame and _ecmeFC[frame]
        if fc and fc.hidden then
            fc.restoring = true
            frame:SetAlpha(fc.origAlpha or 1)
            if fc.origPoints then
                frame:ClearAllPoints()
                for _, pt in ipairs(fc.origPoints) do
                    frame:SetPoint(pt[1], pt[2], pt[3], pt[4], pt[5])
                end
            end
            fc.hidden = false
            fc.restoring = nil
        end
    end
end

-- Restore only the Blizzard buff CDM frame (BuffIconCooldownViewer).
local function RestoreBlizzardBuffFrame()
    local frameName = BLIZZ_CDM_FRAMES.buffs
    if not frameName then return end
    local frame = _G[frameName]
    local fc = frame and _ecmeFC[frame]
    if fc and fc.hidden then
        fc.restoring = true
        frame:SetAlpha(fc.origAlpha or 1)
        if fc.origPoints then
            frame:ClearAllPoints()
            for _, pt in ipairs(fc.origPoints) do
                frame:SetPoint(pt[1], pt[2], pt[3], pt[4], pt[5])
            end
        end
        fc.hidden = false
        fc.restoring = nil
    end
end

-------------------------------------------------------------------------------
--  CDM Bar Position Helpers
-------------------------------------------------------------------------------
local function ApplyBarPositionCentered(frame, pos, barKey)
    if not pos or not pos.point then return end
    local px, py = pos.x or 0, pos.y or 0
    local anchor = pos.point

    -- If stored as CENTER/CENTER, convert to grow-direction-aware anchor
    -- so the fixed edge stays put when bar width changes across specs.
    if pos.point == "CENTER" and (pos.relPoint == "CENTER" or not pos.relPoint) then
        local bd = barKey and barDataByKey[barKey]
        local grow = bd and bd.growDirection or "CENTER"
        local fw = frame:GetWidth() or 0
        local fh = frame:GetHeight() or 0

        if grow == "RIGHT" then
            anchor = "LEFT"
            px = px - fw / 2
        elseif grow == "LEFT" then
            anchor = "RIGHT"
            px = px + fw / 2
        elseif grow == "DOWN" then
            anchor = "TOP"
            py = py + fh / 2
        elseif grow == "UP" then
            anchor = "BOTTOM"
            py = py - fh / 2
        end
        -- CENTER grow: keep anchor as CENTER (no adjustment needed)
    end

    frame:ClearAllPoints()
    frame:SetPoint(anchor, UIParent, pos.relPoint or anchor, px, py)
end

local function SaveCDMBarPosition(barKey, frame)
    if not frame then return end
    local p = ECME.db.profile
    local scale = frame:GetScale() or 1
    local uiScale = UIParent:GetEffectiveScale()
    local fScale = frame:GetEffectiveScale()
    local uiW, uiH = UIParent:GetSize()
    local ratio = fScale / uiScale

    -- Determine anchor point from grow direction so the bar's near edge
    -- stays fixed when icon count changes across specs.
    local bd = barDataByKey[barKey]
    local grow = bd and bd.growDirection or "CENTER"
    local pt
    if     grow == "RIGHT" then pt = "LEFT"
    elseif grow == "LEFT"  then pt = "RIGHT"
    elseif grow == "DOWN"  then pt = "TOP"
    elseif grow == "UP"    then pt = "BOTTOM"
    elseif grow == "CENTER" then pt = "CENTER"
    else                        pt = "LEFT"
    end

    local ax, ay
    if pt == "LEFT" then
        local lx = frame:GetLeft()
        if not lx then return end
        local cy = select(2, frame:GetCenter())
        if not cy then return end
        ax = lx * ratio
        ay = cy * ratio
    elseif pt == "RIGHT" then
        local rx = frame:GetRight()
        if not rx then return end
        local cy = select(2, frame:GetCenter())
        if not cy then return end
        ax = rx * ratio
        ay = cy * ratio
    elseif pt == "TOP" then
        local cx = frame:GetCenter()
        if not cx then return end
        local ty = frame:GetTop()
        if not ty then return end
        ax = cx * ratio
        ay = ty * ratio
    elseif pt == "BOTTOM" then
        local cx = frame:GetCenter()
        if not cx then return end
        local by = frame:GetBottom()
        if not by then return end
        ax = cx * ratio
        ay = by * ratio
    elseif pt == "CENTER" then
        local cx, cy = frame:GetCenter()
        if not cx or not cy then return end
        ax = cx * ratio
        ay = cy * ratio
    end

    -- Store relative to UIParent CENTER so offset math is consistent
    p.cdmBarPositions[barKey] = {
        point = pt, relPoint = "CENTER",
        x = (ax - uiW / 2) / scale,
        y = (ay - uiH / 2) / scale,
    }
end

-------------------------------------------------------------------------------
--  Helper: get the frame anchor point for a CDM bar.
--  Returns the near-edge center of the frame (the edge that faces away from target).
--  grow RIGHT -> near edge = LEFT, grow LEFT -> RIGHT, grow DOWN -> TOP, grow UP -> BOTTOM
-------------------------------------------------------------------------------
local function CDMFrameAnchorPoint(anchorSide, grow, centered)

    if grow == "RIGHT" then return "LEFT"   end
    if grow == "LEFT"  then return "RIGHT"  end
    if grow == "DOWN"  then return "TOP"    end
    if grow == "UP"    then return "BOTTOM" end
    if grow == "CENTER" then return "CENTER" end
    return "CENTER"
end

-------------------------------------------------------------------------------
--  Recursive click-through helper ΓÇö disables/restores mouse on a frame tree
-------------------------------------------------------------------------------
local function SetFrameClickThrough(frame, clickThrough)
    if not frame then return end
    if clickThrough then
        if frame._cdmMouseWas == nil then
            frame._cdmMouseWas = frame:IsMouseEnabled()
        end
        frame:EnableMouse(false)
        if frame.EnableMouseClicks then frame:EnableMouseClicks(false) end
        if frame.EnableMouseMotion then frame:EnableMouseMotion(false) end
    else
        if frame._cdmMouseWas ~= nil then
            frame:EnableMouse(frame._cdmMouseWas)
            frame._cdmMouseWas = nil
        end
    end
    for _, child in ipairs({ frame:GetChildren() }) do
        SetFrameClickThrough(child, clickThrough)
    end
end

-------------------------------------------------------------------------------
--  Build a single CDM bar frame
-------------------------------------------------------------------------------
BuildCDMBar = function(barIndex)
    local p = ECME.db.profile
    local bars = p.cdmBars.bars
    local barData = bars[barIndex]
    if not barData then return end

    local key = barData.key
    local frame = cdmBarFrames[key]

    if not frame then
        frame = CreateFrame("Frame", "ECME_CDMBar_" .. key, UIParent)
        frame:SetFrameStrata("LOW")
        frame:SetFrameLevel(5)
        if frame.EnableMouseClicks then frame:EnableMouseClicks(false) end
        if frame.EnableMouseMotion then frame:EnableMouseMotion(true) end
        frame._barKey = key
        frame._barIndex = barIndex
        cdmBarFrames[key] = frame
        cdmBarIcons[key] = {}
    end

    if not barData.enabled then
        if frame._mouseTrack then
            frame:SetScript("OnUpdate", nil)
            frame._mouseTrack = nil
            if frame._preMousePos and not p.cdmBarPositions[key] then
                p.cdmBarPositions[key] = frame._preMousePos
            end
            frame._preMousePos = nil
            SetFrameClickThrough(frame, false)
            if frame.EnableMouseMotion then frame:EnableMouseMotion(true) end
        end
        EllesmereUI.SetElementVisibility(frame, false)
        return
    end

    -- Scale removed -- all sizing is width/height based now
    frame:SetScale(1)

    -- Clear any previous mouse-tracking OnUpdate
    if frame._mouseTrack then
        frame:SetScript("OnUpdate", nil)
        frame._mouseTrack = nil
        -- Restore saved position from before mouse anchor
        if frame._preMousePos and not p.cdmBarPositions[key] then
            p.cdmBarPositions[key] = frame._preMousePos
        end
        frame._preMousePos = nil
        -- Restore default strata when leaving cursor anchor
        frame:SetFrameStrata("LOW")
        frame:SetFrameLevel(5)
        -- Restore mouse on frame and all children
        SetFrameClickThrough(frame, false)
        if frame.EnableMouseMotion then frame:EnableMouseMotion(true) end
    end
    frame._mouseGrow = nil

    -- Position
    local anchorKey = barData.anchorTo
    if anchorKey == "mouse" then
        -- Stash saved position so it can be restored when unanchoring
        if p.cdmBarPositions[key] then
            frame._preMousePos = p.cdmBarPositions[key]
        end
        -- Anchor position acts as build direction for mouse cursor tracking
        local anchorPos = barData.anchorPosition or "right"
        local oX = barData.anchorOffsetX or 0
        local oY = barData.anchorOffsetY or 0
        -- Determine SetPoint anchor and 15px directional nudge
        local pointFrom, baseOX, baseOY, forceGrow
        if anchorPos == "left" then
            pointFrom = "RIGHT"; forceGrow = "LEFT"
            baseOX = -15 + oX; baseOY = oY
        elseif anchorPos == "right" then
            pointFrom = "LEFT"; forceGrow = "RIGHT"
            baseOX = 15 + oX; baseOY = oY
        elseif anchorPos == "top" then
            pointFrom = "BOTTOM"; forceGrow = "UP"
            baseOX = oX; baseOY = 15 + oY
        elseif anchorPos == "bottom" then
            pointFrom = "TOP"; forceGrow = "DOWN"
            baseOX = oX; baseOY = -15 + oY
        else
            pointFrom = "LEFT"; forceGrow = "RIGHT"
            baseOX = 15 + oX; baseOY = oY
        end
        frame._mouseGrow = forceGrow
        -- Elevate to TOOLTIP strata so the bar renders above all UI
        frame:SetFrameStrata("TOOLTIP")
        frame:SetFrameLevel(9980)
        -- Make frame and all children fully click-through while following cursor
        SetFrameClickThrough(frame, true)
        local lastMX, lastMY
        frame:ClearAllPoints()
        frame:SetPoint(pointFrom, UIParent, "BOTTOMLEFT", 0, 0)
        frame._mouseTrack = true
        frame._mouseHiddenByPanel = false
        frame:SetScript("OnUpdate", function()
            -- Hide cursor-anchored bar while EUI options panel or unlock mode is open
            local panelOpen = (EllesmereUI._mainFrame and EllesmereUI._mainFrame:IsShown())
                or EllesmereUI._unlockActive
            if panelOpen then
                frame._mouseHiddenByPanel = true
                if frame:GetAlpha() > 0 then frame:SetAlpha(0) end
                return
            elseif frame._mouseHiddenByPanel then
                -- Panel just closed: restore visibility
                frame._mouseHiddenByPanel = false
                _CDMApplyVisibility()
            end
            local s = UIParent:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            cx = floor(cx / s + 0.5)
            cy = floor(cy / s + 0.5)
            if cx ~= lastMX or cy ~= lastMY then
                lastMX, lastMY = cx, cy
                frame:ClearAllPoints()
                frame:SetPoint(pointFrom, UIParent, "BOTTOMLEFT", cx + baseOX, cy + baseOY)
            end
        end)
    elseif anchorKey == "partyframe" then
        -- Anchor to the player's party frame
        local partyFrame = EllesmereUI.FindPlayerPartyFrame()
        if partyFrame then
            frame:ClearAllPoints()
            local side = barData.partyFrameSide or "LEFT"
            local oX = barData.partyFrameOffsetX or 0
            local oY = barData.partyFrameOffsetY or 0
            local grow = barData.growDirection or "CENTER"
            local centered = barData.growCentered ~= false
            local fp = CDMFrameAnchorPoint(side, grow, centered)
            frame._anchorSide = side:upper()
            if side == "LEFT" then
                frame:SetPoint(fp, partyFrame, "LEFT", oX, oY)
            elseif side == "RIGHT" then
                frame:SetPoint(fp, partyFrame, "RIGHT", oX, oY)
            elseif side == "TOP" then
                frame:SetPoint(fp, partyFrame, "TOP", oX, oY)
            elseif side == "BOTTOM" then
                frame:SetPoint(fp, partyFrame, "BOTTOM", oX, oY)
            end
        else
            -- No party frame found  fall back to saved position
            local pos = p.cdmBarPositions[key]
            if pos and pos.point then
                ApplyBarPositionCentered(frame, pos, key)
            else
                frame:ClearAllPoints()
                frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            end
        end
    elseif anchorKey == "playerframe" then
        -- Anchor to the player's unit frame
        local playerFrame = EllesmereUI.FindPlayerUnitFrame()
        if playerFrame then
            frame:ClearAllPoints()
            local side = barData.playerFrameSide or "LEFT"
            local oX = barData.playerFrameOffsetX or 0
            local oY = barData.playerFrameOffsetY or 0
            local grow = barData.growDirection or "CENTER"
            local centered = barData.growCentered ~= false
            local fp = CDMFrameAnchorPoint(side, grow, centered)
            frame._anchorSide = side:upper()
            if side == "LEFT" then
                frame:SetPoint(fp, playerFrame, "LEFT", oX, oY)
            elseif side == "RIGHT" then
                frame:SetPoint(fp, playerFrame, "RIGHT", oX, oY)
            elseif side == "TOP" then
                frame:SetPoint(fp, playerFrame, "TOP", oX, oY)
            elseif side == "BOTTOM" then
                frame:SetPoint(fp, playerFrame, "BOTTOM", oX, oY)
            end
        else
            -- No player frame found  fall back to saved position
            local pos = p.cdmBarPositions[key]
            if pos and pos.point then
                ApplyBarPositionCentered(frame, pos, key)
            else
                frame:ClearAllPoints()
                frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            end
        end
    elseif anchorKey == "erb_castbar" or anchorKey == "erb_powerbar" or anchorKey == "erb_classresource" then
        -- Anchor to EllesmereUI Resource Bars frames
        local erbFrameNames = {
            erb_castbar = "ERB_CastBarFrame",
            erb_powerbar = "ERB_PrimaryBar",
            erb_classresource = "ERB_SecondaryFrame",
        }
        local erbFrame = _G[erbFrameNames[anchorKey]]
        if erbFrame then
            local anchorPos = barData.anchorPosition or "left"
            frame:ClearAllPoints()
            local gap = barData.spacing or 2
            local oX = barData.anchorOffsetX or 0
            local oY = barData.anchorOffsetY or 0
            local grow = barData.growDirection or "CENTER"
            local centered = barData.growCentered ~= false
            local fp = CDMFrameAnchorPoint(anchorPos:upper(), grow, centered)
            frame._anchorSide = anchorPos:upper()
            local ok
            if anchorPos == "left" then
                ok = pcall(frame.SetPoint, frame, fp, erbFrame, "LEFT", -gap + oX, oY)
            elseif anchorPos == "right" then
                ok = pcall(frame.SetPoint, frame, fp, erbFrame, "RIGHT", gap + oX, oY)
            elseif anchorPos == "top" then
                ok = pcall(frame.SetPoint, frame, fp, erbFrame, "TOP", oX, gap + oY)
            elseif anchorPos == "bottom" then
                ok = pcall(frame.SetPoint, frame, fp, erbFrame, "BOTTOM", oX, -gap + oY)
            end
            -- Circular anchor detected ΓÇö fall back to center
            if not ok then
                frame:ClearAllPoints()
                frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            end
        else
            -- Resource Bars frame not available  fall back to saved position
            local pos = p.cdmBarPositions[key]
            if pos and pos.point then
                ApplyBarPositionCentered(frame, pos, key)
            else
                frame:ClearAllPoints()
                frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            end
        end
    else
        local pos = p.cdmBarPositions[key]
        if pos and pos.point then
            -- Skip for unlock-anchored bars (anchor system is authority)
            local unlockKey = "CDM_" .. key
            local anchored = EllesmereUI.IsUnlockAnchored and EllesmereUI.IsUnlockAnchored(unlockKey)
            if not anchored or not frame:GetLeft() then
                ApplyBarPositionCentered(frame, pos, key)
            end
        else
            -- Default fallback positions
            frame:ClearAllPoints()
            if key == "cooldowns" then
                frame:SetPoint("CENTER", UIParent, "CENTER", 0, -275)
            elseif key == "utility" then
                frame:SetPoint("CENTER", UIParent, "CENTER", 0, -320)
            elseif key == "buffs" then
                frame:SetPoint("CENTER", UIParent, "CENTER", 0, -365)
            else
                frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            end
        end
    end

    -- Show the frame but respect visibility mode.
    -- Always Show() so layout/children work.
    -- _CDMApplyVisibility is the single authority for alpha/hiding.
    frame:Show()
end

-- Compute stride respecting topRowCount override (only for numRows == 2)
local function ComputeTopRowStride(barData, count)
    local numRows = barData.numRows or 1
    if numRows < 1 then numRows = 1 end
    if numRows == 2 and barData.customTopRowEnabled and barData.topRowCount and barData.topRowCount > 0 then
        local topCount = math.min(barData.topRowCount, count)
        local bottomCount = count - topCount
        return math.max(topCount, bottomCount), numRows, topCount
    end
    local stride = math.ceil(count / numRows)
    local topCount = count - (numRows - 1) * stride
    if topCount < 0 then topCount = 0 end
    return stride, numRows, topCount
end

-- Empty custom bars still need a stable footprint so unlock mode can keep a
-- visible mover and convert drag positions correctly before any icons exist.
local EMPTY_CDM_BAR_SIZE = { 100, 36 }

-- Count the spell entries that contribute real icon slots for this bar.
-- Unlock mode uses this to estimate a footprint before the live frame has
-- been laid out, which is common for freshly created Misc bars.
local function CountCDMBarSpells(barKey)
    local count = 0
    local sd = ns.GetBarSpellData(barKey)
    if not sd or not sd.assignedSpells then return 0 end
    for _, sid in ipairs(sd.assignedSpells) do
        if sid and sid ~= 0 then count = count + 1 end
    end
    return count
end

local function ComputeCDMBarSize(barData, count)
    local iW = SnapForScale(barData.iconSize or 36, 1)
    local iH = iW
    if (barData.iconShape or "none") == "cropped" then
        iH = SnapForScale(math.floor((barData.iconSize or 36) * 0.80 + 0.5), 1)
    end
    local sp = SnapForScale(barData.spacing or 2, 1)
    local rows = barData.numRows or 1
    if rows < 1 then rows = 1 end
    local stride = ComputeTopRowStride(barData, count)
    local grow = barData.growDirection or "CENTER"
    local isH = (grow == "RIGHT" or grow == "LEFT" or grow == "CENTER")
    if isH then
        return stride * iW + (stride - 1) * sp,
               rows * iH + (rows - 1) * sp
    end
    return rows * iW + (rows - 1) * sp,
           stride * iH + (stride - 1) * sp
end

-- Return the authoritative footprint unlock mode should use for a CDM bar.
-- Prefer the live frame when it already has bounds; otherwise derive the size
-- from bar configuration, and fall back to a stable empty-bar placeholder.
local function GetStableCDMBarSize(barKey, frame, barData)
    if frame then
        local w, h = frame:GetWidth() or 0, frame:GetHeight() or 0
        if w > 1 and h > 1 then
            return w, h
        end
    end

    local count = CountCDMBarSpells(barKey)
    if barData and count > 0 then
        return ComputeCDMBarSize(barData, count)
    end

    return EMPTY_CDM_BAR_SIZE[1], EMPTY_CDM_BAR_SIZE[2]
end

-------------------------------------------------------------------------------
--  Layout icons within a CDM bar
-------------------------------------------------------------------------------
LayoutCDMBar = function(barKey)
    local frame = cdmBarFrames[barKey]
    local icons = cdmBarIcons[barKey]
    if not frame or not icons then return end

    local barData = barDataByKey[barKey]
    if not barData or not barData.enabled then return end

    local iconW = SnapForScale(barData.iconSize or 36, 1)
    local iconH = iconW
    local shape = barData.iconShape or "none"
    if shape == "cropped" then
        iconH = SnapForScale(math.floor((barData.iconSize or 36) * 0.80 + 0.5), 1)
    end
    local spacing = SnapForScale(barData.spacing or 2, 1)
    local grow = frame._mouseGrow or barData.growDirection or "CENTER"
    local numRows = barData.numRows or 1
    if numRows < 1 then numRows = 1 end

    -- Collect visible icons (reuse buffer to avoid garbage)
    local visibleIcons = frame._visibleIconsBuf
    if not visibleIcons then visibleIcons = {}; frame._visibleIconsBuf = visibleIcons else wipe(visibleIcons) end
    for _, icon in ipairs(icons) do
        if icon:IsShown() then
            visibleIcons[#visibleIcons + 1] = icon
        end
    end

    local count = #visibleIcons
    if count == 0 then
        local curW = frame:GetWidth() or 0
        local curH = frame:GetHeight() or 0
        if curW <= 1 or curH <= 1 then
            local fallbackW, fallbackH = GetStableCDMBarSize(barKey, nil, barData)
            frame:SetSize(fallbackW, fallbackH)
            frame._prevLayoutW = fallbackW
            frame._prevLayoutH = fallbackH
        end
        -- Keep the frame at its current size so anchor math has valid bounds.
        -- Alpha-zero hides it visually while preserving layout dimensions.
        EllesmereUI.SetElementVisibility(frame, false)
        if frame._barBg then frame._barBg:Hide() end
        -- No propagation needed: frame stays at its current size (alpha-zero),
        -- so anchored children remain in their correct positions.
        return
    end

    -- Bar has visible icons -- ensure it is visible (unless visibility is "never")
    local isHoriz = (grow == "RIGHT" or grow == "LEFT" or grow == "CENTER")
    local stride, _, customTopCount = ComputeTopRowStride(barData, count)

    -- Container size (already snapped values)
    local totalW, totalH
    if isHoriz then
        totalW = stride * iconW + (stride - 1) * spacing
        totalH = numRows * iconH + (numRows - 1) * spacing
    else
        totalW = numRows * iconW + (numRows - 1) * spacing
        totalH = stride * iconH + (stride - 1) * spacing
    end

    -- Capture the fixed edge BEFORE SetSize so it does not move when the bar
    -- grows. Only for non-center grow directions, outside unlock mode (unlock
    -- mode's RecenterBarAnchor owns positioning there), and only for bars
    -- free-floating on UIParent (anchored bars are positioned by their anchor).
    local preEdgeX, preEdgeY, preGrowAnchor
    local freeFloating = not barData.anchorTo or barData.anchorTo == "none"
    if grow ~= "CENTER" and not EllesmereUI._unlockActive and freeFloating then
        local fL = frame:GetLeft()
        local fR = frame:GetRight()
        local fT = frame:GetTop()
        local fB = frame:GetBottom()
        if fL and fR and fT and fB then
            local uiS = UIParent:GetEffectiveScale()
            local fS  = frame:GetEffectiveScale()
            local ratio = fS / uiS
            local uiW, uiH = UIParent:GetSize()
            if grow == "RIGHT" then
                preGrowAnchor = "LEFT"
                preEdgeX = fL * ratio - uiW / 2
                preEdgeY = ((fT + fB) / 2) * ratio - uiH / 2
            elseif grow == "LEFT" then
                preGrowAnchor = "RIGHT"
                preEdgeX = fR * ratio - uiW / 2
                preEdgeY = ((fT + fB) / 2) * ratio - uiH / 2
            elseif grow == "DOWN" then
                preGrowAnchor = "TOP"
                preEdgeX = ((fL + fR) / 2) * ratio - uiW / 2
                preEdgeY = fT * ratio - uiH / 2
            elseif grow == "UP" then
                preGrowAnchor = "BOTTOM"
                preEdgeX = ((fL + fR) / 2) * ratio - uiW / 2
                preEdgeY = fB * ratio - uiH / 2
            end
        end
    end

    frame:SetSize(SnapForScale(totalW, 1), SnapForScale(totalH, 1))

    -- Re-anchor from the fixed edge captured before SetSize.
    if preGrowAnchor and preEdgeX and preEdgeY then
        pcall(function()
            frame:ClearAllPoints()
            frame:SetPoint(preGrowAnchor, UIParent, "CENTER", preEdgeX, preEdgeY)
        end)
        SaveCDMBarPosition(barKey, frame)
    end

    -- Track which axes actually changed for axis-isolated propagation
    local prevW = frame._prevLayoutW or 0
    local prevH = frame._prevLayoutH or 0
    local newW = SnapForScale(totalW, 1)
    local newH = SnapForScale(totalH, 1)
    local widthChanged = (math.abs(newW - prevW) > 0.5)
    local heightChanged = (math.abs(newH - prevH) > 0.5)
    frame._prevLayoutW = newW
    frame._prevLayoutH = newH

    -- During unlock mode, skip anchor/propagation -- unlock mode owns positioning.
    if not EllesmereUI._unlockActive then
        -- Immediately reposition this bar if it's anchored to something,
        -- before the frame renders, to avoid a one-frame blink.
        if EllesmereUI.ReapplyOwnAnchor then
            EllesmereUI.ReapplyOwnAnchor("CDM_" .. barKey)
        end

        if not frame._propagatingMatch then
            frame._propagatingMatch = true
            local unlockKey = "CDM_" .. barKey

            if EllesmereUI.PropagateWidthMatch then
                EllesmereUI.PropagateWidthMatch(unlockKey)
            end
            if EllesmereUI.PropagateHeightMatch then
                EllesmereUI.PropagateHeightMatch(unlockKey)
            end
            if EllesmereUI.PropagateAnchorChain then
                -- Pass axis so TOP/BOTTOM children don't move on width-only
                -- changes and LEFT/RIGHT children don't move on height-only.
                if widthChanged and heightChanged then
                    EllesmereUI.PropagateAnchorChain(unlockKey)
                elseif widthChanged then
                    EllesmereUI.PropagateAnchorChain(unlockKey, "width")
                elseif heightChanged then
                    EllesmereUI.PropagateAnchorChain(unlockKey, "height")
                end
            end
            frame._propagatingMatch = false
        end
    end

    -- Bar background
    if barData.barBgEnabled then
        if not frame._barBg then
            frame._barBg = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
        end
        frame._barBg:ClearAllPoints()
        frame._barBg:SetPoint("TOPLEFT", 0, 0)
        frame._barBg:SetPoint("BOTTOMRIGHT", 0, 0)
        frame._barBg:SetColorTexture(barData.barBgR or 0, barData.barBgG or 0, barData.barBgB or 0, barData.barBgA or 0.5)
        frame._barBg:Show()
    elseif frame._barBg then
        frame._barBg:Hide()
    end

    local stepW = iconW + spacing
    local stepH = iconH + spacing

    -- How many icons on the top row
    local topRowCount = customTopCount
    if topRowCount < 0 then topRowCount = 0 end
    local bottomRowCount = #visibleIcons - topRowCount
    if bottomRowCount < 0 then bottomRowCount = 0 end

    -- Compute per-row centering offset (icons fewer than stride get centered)
    local function RowIconCount(row)
        if row == 0 then return topRowCount end
        return bottomRowCount
    end

    -- Position each icon: fill bottom-up so bottom rows are full,
    -- top row gets the remainder. Center any row with fewer icons than stride.
    for i, icon in ipairs(visibleIcons) do
        icon:SetSize(iconW, iconH)
        icon:ClearAllPoints()

        -- Map sequential index to bottom-up grid position.
        -- Icon 1..topRowCount fill the top row (visual row 0).
        -- Remaining icons fill rows 1..numRows-1 (bottom rows).
        local col, row
        if i <= topRowCount then
            col = i - 1
            row = 0
        else
            local bottomIdx = i - topRowCount - 1
            col = bottomIdx % stride
            row = 1 + math.floor(bottomIdx / stride)
        end

        -- Center any row that has fewer icons than stride
        local rowCount = RowIconCount(row)
        local rowHasLess = (rowCount > 0 and rowCount < stride)

        if grow == "RIGHT" then
            local rowOffset = 0
            if rowHasLess then
                rowOffset = SnapForScale((stride - rowCount) * stepW / 2, 1)
            end
            icon:SetPoint("TOPLEFT", frame, "TOPLEFT",
                col * stepW + rowOffset,
                -(row * stepH))
        elseif grow == "LEFT" then
            local rowOffset = 0
            if rowHasLess then
                rowOffset = SnapForScale((stride - rowCount) * stepW / 2, 1)
            end
            icon:SetPoint("TOPRIGHT", frame, "TOPRIGHT",
                -(col * stepW + rowOffset),
                -(row * stepH))
        elseif grow == "DOWN" then
            local rowOffset = 0
            if rowHasLess then
                rowOffset = SnapForScale((stride - rowCount) * stepH / 2, 1)
            end
            icon:SetPoint("TOPLEFT", frame, "TOPLEFT",
                row * stepW,
                -(col * stepH + rowOffset))
        elseif grow == "UP" then
            local rowOffset = 0
            if rowHasLess then
                rowOffset = SnapForScale((stride - rowCount) * stepH / 2, 1)
            end
            icon:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT",
                row * stepW,
                col * stepH + rowOffset)
        elseif grow == "CENTER" then
            local rowOffset = 0
            if rowHasLess then
                rowOffset = SnapForScale((stride - rowCount) * stepW / 2, 1)
            end
            icon:SetPoint("TOPLEFT", frame, "CENTER",
                col * stepW + rowOffset - totalW / 2,
                -(row * stepH) + totalH / 2)
        end
    end
end

-- (CreateCDMIcon removed -- all bars now use hook-based reparenting of Blizzard CDM frames)

-------------------------------------------------------------------------------
--  Open Blizzard CDM Settings to a specific tab.
--  isBuff=true opens the Auras/Buffs tab; false opens the Spells/CDs tab.
--  Hides EllesmereUI options panel first so the Blizzard UI is visible.
-------------------------------------------------------------------------------
local function OpenBlizzardCDMTab(isBuff)
    if EllesmereUI._mainFrame and EllesmereUI._mainFrame:IsShown() then
        EllesmereUI._mainFrame:Hide()
    end
    if not CooldownViewerSettings then return end
    CooldownViewerSettings:Show()
    C_Timer.After(0.1, function()
        local cvs = CooldownViewerSettings
        cvs:ClearDisplayCategories()
        if isBuff then
            cvs:SetCurrentCategories({2, 3, -2})
            cvs:SetDisplayMode("auras")
        else
            cvs:SetCurrentCategories({0, 1, -1})
            cvs:SetDisplayMode("spells")
        end
    end)
end
ns.OpenBlizzardCDMTab = OpenBlizzardCDMTab

-------------------------------------------------------------------------------
--  Lazily create or update the red "untracked" overlay on a CDM icon.
--  Shows a 60% red tint and a clickable button that opens the Blizzard CDM
--  settings to the tab matching the bar type (buffs vs spells).
-------------------------------------------------------------------------------
-- Styled tooltip for untracked overlay (self-contained, no widget dependency)
local _untrackedTooltip
local function ShowUntrackedTooltip(anchor, text)
    if not _untrackedTooltip then
        local tt = CreateFrame("Frame", nil, UIParent)
        tt:SetFrameStrata("TOOLTIP")
        tt:SetSize(250, 40)
        local bg = tt:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.067, 0.067, 0.067, 0.90)
        local PP2 = EllesmereUI and EllesmereUI.PP
        if PP2 then PP2.CreateBorder(tt, 1, 1, 1, 0.15, 1) end
        local fs = tt:CreateFontString(nil, "OVERLAY")
        fs:SetFont(GetCDMFont(), 11, "")
        fs:SetShadowOffset(1, -1)
        fs:SetTextColor(1, 1, 1, 0.80)
        fs:SetPoint("TOPLEFT", 8, -8)
        fs:SetPoint("TOPRIGHT", -8, -8)
        fs:SetWordWrap(true)
        fs:SetSpacing(3)
        tt.text = fs
        tt:Hide()
        _untrackedTooltip = tt
    end
    local tt = _untrackedTooltip
    tt:SetWidth(250)
    tt.text:SetText(text)
    tt:ClearAllPoints()
    tt:SetPoint("BOTTOM", anchor, "TOP", 0, 4)
    tt:SetAlpha(0)
    tt:Show()
    local naturalW = tt.text:GetStringWidth() + 16
    tt:SetWidth(math.min(naturalW, 250))
    tt:SetHeight(tt.text:GetStringHeight() + 16)
    tt:SetAlpha(1)
end
local function HideUntrackedTooltip()
    if _untrackedTooltip then _untrackedTooltip:Hide() end
end

local function ApplyUntrackedOverlay(ourIcon, isUntracked)
    if isUntracked then
        if not ourIcon._untrackedOverlay then
            local ov = CreateFrame("Button", nil, ourIcon)
            ov:SetAllPoints(ourIcon._tex or ourIcon)
            ov:SetFrameLevel(ourIcon:GetFrameLevel() + 4)
            local ovTex = ov:CreateTexture(nil, "OVERLAY", nil, 6)
            ovTex:SetAllPoints()
            ovTex:SetColorTexture(0.6, 0.075, 0.075, 0.8)
            -- "Click to Track" label
            local label = ov:CreateFontString(nil, "OVERLAY")
            local outFlag = EllesmereUI.GetFontOutlineFlag and EllesmereUI.GetFontOutlineFlag() or "OUTLINE"
            label:SetFont(GetCDMFont(), 10, outFlag)
            if EllesmereUI.GetFontUseShadow and EllesmereUI.GetFontUseShadow() then
                label:SetShadowOffset(1, -1)
            else
                label:SetShadowOffset(0, 0)
            end
            label:SetPoint("CENTER", ov, "CENTER", 0, 0)
            label:SetText("Not\nTracked")
            label:SetTextColor(1, 1, 1, 0.9)
            label:SetJustifyH("CENTER")
            ov._label = label
            ov:SetScript("OnClick", function(self)
                local parent = self:GetParent()
                local bk = parent and parent._barKey
                local barType = bk
                if barDataByKey and barDataByKey[bk] then
                    barType = barDataByKey[bk].barType or bk
                end
                local isBuff = (barType == "buffs")
                OpenBlizzardCDMTab(isBuff)
            end)
            ov:SetScript("OnEnter", function(self)
                local parent = self:GetParent()
                local bk = parent and parent._barKey
                local barType = bk
                if barDataByKey and barDataByKey[bk] then
                    barType = barDataByKey[bk].barType or bk
                end
                local isBuff = (barType == "buffs")
                local tabName = isBuff and "Buffs" or "Spells"
                ShowUntrackedTooltip(self,
                    "Not tracked in Blizzard CDM.\nClick to open the |cff0cd29d" .. tabName .. "|r tab.")
            end)
            ov:SetScript("OnLeave", function() HideUntrackedTooltip() end)
            ourIcon._untrackedOverlay = ov
        end
        ourIcon._untrackedOverlay:EnableMouse(true)
        ourIcon._untrackedOverlay:Show()
        ourIcon._isUntracked = true
    elseif ourIcon._untrackedOverlay then
        ourIcon._untrackedOverlay:Hide()
        ourIcon._isUntracked = false
    end
end
ns.ApplyUntrackedOverlay = ApplyUntrackedOverlay

-------------------------------------------------------------------------------
--  Toggle tooltip OnUpdate for all icons on a bar.
--  When enabled, each icon polls IsMouseOver every frame.
--  When disabled, the OnUpdate is nil -- zero performance cost.
-------------------------------------------------------------------------------
local _cdmTooltipOnUpdate = function(self)
    -- Suppress tooltips while in edit / unlock mode
    if EllesmereUI and EllesmereUI._unlockActive then
        if self._tooltipShown then
            GameTooltip:Hide()
            self._tooltipShown = false
        end
        return
    end
    local over = self:IsMouseOver()
    if over and not self._tooltipShown then
        local sid = self._spellID
        if sid and sid > 0 then
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetSpellByID(sid)
            GameTooltip:Show()
            self._tooltipShown = true
        end
    elseif not over and self._tooltipShown then
        GameTooltip:Hide()
        self._tooltipShown = false
    end
end

local function ApplyCDMTooltipState(barKey)
    local icons = cdmBarIcons[barKey]
    if not icons then return end
    local bd = barDataByKey[barKey]
    local enabled = bd and bd.showTooltip
    for _, icon in ipairs(icons) do
        if enabled then
            icon:SetScript("OnUpdate", _cdmTooltipOnUpdate)
        else
            icon:SetScript("OnUpdate", nil)
            if icon._tooltipShown then
                GameTooltip:Hide()
                icon._tooltipShown = false
            end
        end
    end
end
ns.ApplyCDMTooltipState = ApplyCDMTooltipState

-------------------------------------------------------------------------------
--  Apply custom shape to a CDM icon
-------------------------------------------------------------------------------
ApplyShapeToCDMIcon = function(icon, shape, barData)
    if not icon then return end
    local zoom = barData.iconZoom or 0.08
    local borderSz = barData.borderSize or 1
    local brdR = barData.borderR or 0
    local brdG = barData.borderG or 0
    local brdB = barData.borderB or 0
    local brdA = barData.borderA or 1
    if barData.borderClassColor then
        local cc = _playerClass and RAID_CLASS_COLORS[_playerClass]
        if cc then brdR, brdG, brdB = cc.r, cc.g, cc.b end
    end

    if shape == "none" or shape == "cropped" or not shape then
        -- Remove shape mask if previously applied
        if icon._shapeMask then
            local mask = icon._shapeMask
            if icon._tex then pcall(icon._tex.RemoveMaskTexture, icon._tex, mask) end
            if icon._bg then pcall(icon._bg.RemoveMaskTexture, icon._bg, mask) end
            if icon._cooldown then pcall(icon._cooldown.RemoveMaskTexture, icon._cooldown, mask) end
            mask:SetTexture(nil); mask:ClearAllPoints(); mask:SetSize(0.001, 0.001); mask:Hide()
        end
        if icon._shapeBorder then icon._shapeBorder:Hide() end
        icon._shapeApplied = nil
        icon._shapeName = nil

        -- Restore square borders (pixel-perfect via PP)
        if icon._ppBorders then
            EllesmereUI.PP.ShowBorder(icon)
            EllesmereUI.PP.UpdateBorder(icon, borderSz, brdR, brdG, brdB, brdA)
        end

        -- Restore icon texture coords
        if icon._tex then
            icon._tex:ClearAllPoints()
            EllesmereUI.PP.Point(icon._tex, "TOPLEFT", icon, "TOPLEFT", borderSz, -borderSz)
            EllesmereUI.PP.Point(icon._tex, "BOTTOMRIGHT", icon, "BOTTOMRIGHT", -borderSz, borderSz)
            if shape == "cropped" then
                icon._tex:SetTexCoord(zoom, 1 - zoom, zoom + 0.10, 1 - zoom - 0.10)
            else
                icon._tex:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
            end
        end

        -- Restore cooldown (full frame so swipe covers the entire icon)
        if icon._cooldown then
            icon._cooldown:ClearAllPoints()
            icon._cooldown:SetAllPoints(icon)
            pcall(icon._cooldown.SetSwipeTexture, icon._cooldown, "Interface\\Buttons\\WHITE8x8")
            if icon._cooldown.SetUseCircularEdge then pcall(icon._cooldown.SetUseCircularEdge, icon._cooldown, false) end
        end

        -- Restore background
        if icon._bg then
            icon._bg:ClearAllPoints(); icon._bg:SetAllPoints()
        end
        return
    end

    -- Custom shape
    local maskTex = CDM_SHAPES.masks[shape]
    if not maskTex then return end

    if not icon._shapeMask then
        icon._shapeMask = icon:CreateMaskTexture()
    end
    local mask = icon._shapeMask
    mask:SetTexture(maskTex, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:Show()

    -- Remove existing mask refs before re-adding
    if icon._tex then pcall(icon._tex.RemoveMaskTexture, icon._tex, mask) end
    if icon._bg then pcall(icon._bg.RemoveMaskTexture, icon._bg, mask) end
    if icon._cooldown then pcall(icon._cooldown.RemoveMaskTexture, icon._cooldown, mask) end

    -- Apply mask to icon texture and background
    if icon._tex then icon._tex:AddMaskTexture(mask) end
    if icon._bg then icon._bg:AddMaskTexture(mask) end

    -- Expand icon beyond frame for shape
    local shapeOffset = CDM_SHAPES.iconExpandOffsets[shape] or 0
    local shapeDefault = CDM_SHAPES.zoomDefaults[shape] or 0.06
    local iconExp = CDM_SHAPES.iconExpand + shapeOffset + ((zoom - shapeDefault) * 200)
    if iconExp < 0 then iconExp = 0 end
    local halfIE = iconExp / 2
    if icon._tex then
        icon._tex:ClearAllPoints()
        EllesmereUI.PP.Point(icon._tex, "TOPLEFT", icon, "TOPLEFT", -halfIE, halfIE)
        EllesmereUI.PP.Point(icon._tex, "BOTTOMRIGHT", icon, "BOTTOMRIGHT", halfIE, -halfIE)
    end

    -- Mask position (inset for border)
    mask:ClearAllPoints()
    if borderSz >= 1 then
        EllesmereUI.PP.Point(mask, "TOPLEFT", icon, "TOPLEFT", 1, -1)
        EllesmereUI.PP.Point(mask, "BOTTOMRIGHT", icon, "BOTTOMRIGHT", -1, 1)
    else
        mask:SetAllPoints(icon)
    end

    -- Expand texcoords for shape
    local insetPx = CDM_SHAPES.insets[shape] or 17
    local visRatio = (128 - 2 * insetPx) / 128
    local expand = ((1 / visRatio) - 1) * 0.5
    if icon._tex then icon._tex:SetTexCoord(-expand, 1 + expand, -expand, 1 + expand) end

    -- Hide square borders (pixel-perfect via PP)
    if icon._ppBorders then
        EllesmereUI.PP.HideBorder(icon)
    end

    -- Shape border texture (on a dedicated frame above the cooldown swipe)
    if not icon._shapeBorderFrame then
        local sbf = CreateFrame("Frame", nil, icon)
        sbf:SetAllPoints(icon)
        sbf:SetFrameLevel(icon:GetFrameLevel() + 2)
        icon._shapeBorderFrame = sbf
    end
    icon._shapeBorderFrame:SetFrameLevel(icon:GetFrameLevel() + 2)
    if not icon._shapeBorder then
        icon._shapeBorder = icon._shapeBorderFrame:CreateTexture(nil, "OVERLAY", nil, 6)
    end
    local borderTex = icon._shapeBorder
    borderTex:ClearAllPoints()
    borderTex:SetAllPoints(icon)
    if borderSz > 0 and CDM_SHAPES.borders[shape] then
        borderTex:SetTexture(CDM_SHAPES.borders[shape])
        borderTex:SetVertexColor(brdR, brdG, brdB, brdA)
        borderTex:SetSnapToPixelGrid(false)
        borderTex:SetTexelSnappingBias(0)
        borderTex:Show()
    else
        borderTex:Hide()
    end

    -- Apply mask to cooldown so swipe follows shape
    if icon._cooldown then
        icon._cooldown:ClearAllPoints()
        icon._cooldown:SetAllPoints(icon)
        pcall(icon._cooldown.AddMaskTexture, icon._cooldown, mask)
        if icon._cooldown.SetSwipeTexture then
            pcall(icon._cooldown.SetSwipeTexture, icon._cooldown, maskTex)
        end
        local useCircular = (shape ~= "square" and shape ~= "csquare")
        if icon._cooldown.SetUseCircularEdge then pcall(icon._cooldown.SetUseCircularEdge, icon._cooldown, useCircular) end
        local edgeScale = CDM_SHAPES.edgeScales[shape] or 0.60
        if icon._cooldown.SetEdgeScale then pcall(icon._cooldown.SetEdgeScale, icon._cooldown, edgeScale) end
    end

    -- Restore background to full icon
    if icon._bg then
        icon._bg:ClearAllPoints(); icon._bg:SetAllPoints()
    end

    icon._shapeApplied = true
    icon._shapeName = shape
end
ns.ApplyShapeToCDMIcon = ApplyShapeToCDMIcon

-- (UpdateCustomBarIcons removed -- all bars now use hook-based CollectAndReanchor)

-- (UpdateCDMBarIcons removed -- replaced by hook-based CollectAndReanchor)
-------------------------------------------------------------------------------
--  CDM Bar Update Tick (mirrors Blizzard CDM state to our bars)
-------------------------------------------------------------------------------
local cdmUpdateThrottle = 0

-- Refresh visual properties of existing icons (called when settings change)
local function RefreshCDMIconAppearance(barKey)
    local icons = cdmBarIcons[barKey]
    if not icons then return end

    local barData = barDataByKey[barKey]
    if not barData then return end

    local borderSize = barData.borderSize or 1
    local zoom = barData.iconZoom or 0.08

    for _, icon in ipairs(icons) do
        -- Update texture zoom
        if icon._tex then
            icon._tex:ClearAllPoints()
            EllesmereUI.PP.Point(icon._tex, "TOPLEFT", icon, "TOPLEFT", borderSize, -borderSize)
            EllesmereUI.PP.Point(icon._tex, "BOTTOMRIGHT", icon, "BOTTOMRIGHT", -borderSize, borderSize)
            icon._tex:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
        end
        -- Update cooldown (full frame so swipe covers the entire icon)
        if icon._cooldown then
            icon._cooldown:ClearAllPoints()
            icon._cooldown:SetAllPoints(icon)
            icon._cooldown:SetSwipeColor(0, 0, 0, barData.swipeAlpha or 0.7)
            icon._cooldown:SetHideCountdownNumbers(not barData.showCooldownText)
            -- Mark pending font update (applied in batch after frame renders)
            if barData.showCooldownText then
                icon._pendingFontPath = GetCDMFont()
                icon._pendingFontSize = barData.cooldownFontSize or 12
                icon._pendingFontR = barData.cooldownTextR or 1
                icon._pendingFontG = barData.cooldownTextG or 1
                icon._pendingFontB = barData.cooldownTextB or 1
            end
        end
        -- Update border (pixel-perfect via PP)
        if icon._ppBorders then
            EllesmereUI.PP.UpdateBorder(icon, borderSize, barData.borderR or 0, barData.borderG or 0, barData.borderB or 0, barData.borderA or 1)
        end
        -- Update background
        if icon._bg then
            icon._bg:SetColorTexture(barData.bgR or 0.08, barData.bgG or 0.08, barData.bgB or 0.08, barData.bgA or 0.6)
        end
        -- Style Blizzard's native stack/charge text elements
        local scFont = GetCDMFont()
        local scSize = barData.stackCountSize or 11
        local scR, scG, scB = barData.stackCountR or 1, barData.stackCountG or 1, barData.stackCountB or 1
        local scX, scY = barData.stackCountX or 0, (barData.stackCountY or 0) + 2
        -- Applications (buff stacks / aura applications)
        if icon.Applications and icon.Applications.Applications then
            local appsFS = icon.Applications.Applications
            SetBlizzCDMFont(appsFS, scFont, scSize, scR, scG, scB)
            appsFS:ClearAllPoints()
            appsFS:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", scX, scY)
        end
        -- ChargeCount (spell charges like Holy Power spenders)
        if icon.ChargeCount and icon.ChargeCount.Current then
            local chargeFS = icon.ChargeCount.Current
            SetBlizzCDMFont(chargeFS, scFont, scSize, scR, scG, scB)
            chargeFS:ClearAllPoints()
            chargeFS:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", scX, scY)
        end

        -- Update keybind text style
        if icon._keybindText then
            icon._keybindText:SetFont(GetCDMFont(), barData.keybindSize or 10, "OUTLINE")
            icon._keybindText:SetShadowOffset(0, 0)
            icon._keybindText:ClearAllPoints()
            icon._keybindText:SetPoint("TOPLEFT", icon._textOverlay, "TOPLEFT", barData.keybindOffsetX or 2, barData.keybindOffsetY or -2)
            icon._keybindText:SetTextColor(barData.keybindR or 1, barData.keybindG or 1, barData.keybindB or 1, barData.keybindA or 0.9)
        end

        -- Apply custom shape (overrides border/zoom set above)
        local shape = barData.iconShape or "none"
        ApplyShapeToCDMIcon(icon, shape, barData)

        -- Reset active state so glow type change takes effect on next tick.
        -- Preserve proc glow across rebuilds to avoid visible blink at load-in.
        local hadProcGlow = icon._procGlowActive
        if icon._glowOverlay then
            StopNativeGlow(icon._glowOverlay)
        end
        icon._isActive = false
        if hadProcGlow and icon._glowOverlay then
            StartNativeGlow(icon._glowOverlay, PROC_GLOW_STYLE, PROC_GLOW_COLOR[1], PROC_GLOW_COLOR[2], PROC_GLOW_COLOR[3])
            icon._procGlowActive = true
        else
            icon._procGlowActive = false
        end
    end
end
ns.RefreshCDMIconAppearance = RefreshCDMIconAppearance

-- Exports for extracted files (EllesmereUICdmHooks.lua, EllesmereUICdmSpellPicker.lua)
ns.MAIN_BAR_KEYS = MAIN_BAR_KEYS
ns.GetCDMFont = GetCDMFont
ns.ResolveInfoSpellID = ResolveInfoSpellID
ns.ResolveChildSpellID = ResolveChildSpellID
ns.ComputeTopRowStride = ComputeTopRowStride
ns._cdIDToCorrectSID = _cdIDToCorrectSID
ns._tickCDUtilTrackedSet = _tickCDUtilTrackedSet
ns._tickBlizzActiveCache = _tickBlizzActiveCache
ns._tickBuffIconTrackedSet = _tickBuffIconTrackedSet
ns._tickBlizzBuffChildCache = _tickBlizzBuffChildCache
ns._tickBlizzAllChildCache  = _tickBlizzAllChildCache
ns._tickBarViewerCache      = _tickBarViewerCache
ns._ecmeDurObjCache   = _ecmeDurObjCache
ns._ecmeRawStartCache = _ecmeRawStartCache
ns._ecmeRawDurCache   = _ecmeRawDurCache
ns._ecmeFC = _ecmeFC
ns.FC = FC

-- Hook-based CDM Backend loaded from EllesmereUICdmHooks.lua
local BuildCustomBarSpellSet -- forward declare (defined below)

-------------------------------------------------------------------------------
--  Build a set of all spellIDs assigned to custom bars.
--  Used to prevent custom bar spells from leaking onto main bars during
--  snapshot or reconcile.
-------------------------------------------------------------------------------
BuildCustomBarSpellSet = function()
    local set = {}
    local p = ECME.db and ECME.db.profile
    if not p or not p.cdmBars or not p.cdmBars.bars then return set end
    for _, bd in ipairs(p.cdmBars.bars) do
        if not MAIN_BAR_KEYS[bd.key] then
            local sd = ns.GetBarSpellData(bd.key)
            if sd and sd.assignedSpells then
                for _, sid in ipairs(sd.assignedSpells) do
                    if sid and sid > 0 then set[sid] = true end
                end
            end
        end
    end
    return set
end
ns.BuildCustomBarSpellSet = BuildCustomBarSpellSet

-- (SnapshotBlizzardCDM / UpdateTrackedBarIcons removed -- replaced by hook-based CollectAndReanchor)

-------------------------------------------------------------------------------
--  Tick Hot Path
--
--  The frame created during `CDMFinishSetup` drives this via `OnUpdate`.
--  Although WoW calls that every frame, the function self-throttles to 0.1s and
--  then performs the recurring runtime work:
--  1) wipe per-tick caches
--  2) rescan Blizzard CDM viewer children
--  3) refresh tracked/custom bar icons
--
--  This is the performance-sensitive path that should keep working state in
--  locals/upvalues where practical.
-------------------------------------------------------------------------------
local function UpdateAllCDMBars(dt)
    cdmUpdateThrottle = cdmUpdateThrottle + dt
    if cdmUpdateThrottle < 0.1 then return end
    cdmUpdateThrottle = 0

    -- Wipe per-tick caches used by spell picker overlays and debug
    wipe(_tickBlizzActiveCache)
    wipe(_tickBlizzAllChildCache)
    wipe(_tickBlizzBuffChildCache)
    wipe(_tickBarViewerCache)
    wipe(_tickCDUtilTrackedSet)
    wipe(_tickBuffIconTrackedSet)
    do
        for vi = 1, 4 do
            local vName = _cdmViewerNames[vi]
            local vf = _G[vName]
            local isBuffViewer = (vi == 3 or vi == 4)
            local isBuffIconViewer = (vi == 3)
            if vf then
                -- Load frames into reusable buffer from both
                -- GetChildren() and itemFramePool.  After hooks
                -- reparent frames into our containers they are no
                -- longer children of the viewer but still tracked
                -- by the pool.
                local nFrames = 0
                if vf.itemFramePool and vf.itemFramePool.EnumerateActive then
                    for frame in vf.itemFramePool:EnumerateActive() do
                        if frame then
                            nFrames = nFrames + 1
                            _viewerChildBuf[nFrames] = frame
                        end
                    end
                end
                for ci = nFrames + 1, #_viewerChildBuf do _viewerChildBuf[ci] = nil end
                for ci = 1, nFrames do
                    local ch = _viewerChildBuf[ci]
                    if ch then
                        local cdID = ch.cooldownID or (ch.cooldownInfo and ch.cooldownInfo.cooldownID)
                        if cdID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
                            -- Use cached info from previous tick if available.
                            -- GetCooldownViewerCooldownInfo allocates a new table each
                            -- call; caching the extracted values in our external table
                            -- avoids ~30 table allocs/tick across all viewers.
                            local cfc = _ecmeFC[ch]
                            local resolvedSid = cfc and cfc.resolvedSid
                            local baseSpellID = cfc and cfc.baseSpellID
                            local cachedOverride = cfc and cfc.overrideSid
                            -- Invalidate cache when cooldownID changes (child recycled
                            -- by Blizzard CDM for a different spell, e.g. Empty Barrel
                            -- proc replacing another spell's child frame).
                            -- Also invalidate when auraInstanceID changes (e.g. SLT->HST
                            -- in same totem slot share cdID but have different auras).
                            if resolvedSid and (cfc.cachedCdID ~= cdID
                                or (cfc.cachedAuraInstID ~= nil and cfc.cachedAuraInstID ~= ch.auraInstanceID)) then
                                resolvedSid = nil
                                baseSpellID = nil
                                cachedOverride = nil
                                cfc.resolvedSid = nil
                                cfc.baseSpellID = nil
                                cfc.overrideSid = nil
                                cfc.linkedSpellIDs = nil
                            end
                            if not resolvedSid then
                                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                                if info then
                                    if not cfc then cfc = {}; _ecmeFC[ch] = cfc end
                                    baseSpellID = info.spellID
                                    cachedOverride = info.overrideSpellID
                                    resolvedSid = ResolveInfoSpellID(info)
                                    cfc.baseSpellID = baseSpellID
                                    cfc.overrideSid = cachedOverride
                                    cfc.resolvedSid = resolvedSid
                                    cfc.cachedCdID = cdID
                                    cfc.cachedAuraInstID = ch.auraInstanceID
                                    -- Cache linkedSpellIDs for spells like Eclipse that
                                    -- have multiple variant auras under a single CDM child.
                                    -- Static property -- only needs to be set once.
                                    -- Only cache when values are clean (non-secret) to
                                    -- avoid taint from combat API calls after /reload.
                                    if info.linkedSpellIDs and #info.linkedSpellIDs > 0 then
                                        local firstID = info.linkedSpellIDs[1]
                                        if not (issecretvalue and issecretvalue(firstID)) then
                                            cfc.linkedSpellIDs = info.linkedSpellIDs
                                        end
                                    end
                                end
                            else
                                -- Refresh override from lightweight API (returns
                                -- a number, not a table) so runtime activation
                                -- overrides are still detected each tick.
                                if baseSpellID and C_SpellBook and C_SpellBook.FindSpellOverrideByID then
                                    local liveOverride = C_SpellBook.FindSpellOverrideByID(baseSpellID)
                                    if liveOverride and not (issecretvalue and issecretvalue(liveOverride))
                                       and liveOverride ~= 0 and liveOverride ~= cachedOverride then
                                        cachedOverride = liveOverride
                                        resolvedSid = liveOverride
                                        cfc.overrideSid = cachedOverride
                                        cfc.resolvedSid = resolvedSid
                                    end
                                end
                                cfc.cachedAuraInstID = ch.auraInstanceID
                            end
                            if resolvedSid and resolvedSid > 0 then
                                _tickBlizzAllChildCache[resolvedSid] = ch
                                if isBuffViewer then
                                    if isBuffIconViewer or not _tickBlizzBuffChildCache[resolvedSid] then
                                        _tickBlizzBuffChildCache[resolvedSid] = ch
                                    end
                                    -- Bar viewer cache (vi=4 only, for Tracking Bars)
                                    if not isBuffIconViewer then
                                        _tickBarViewerCache[resolvedSid] = ch
                                        if baseSpellID and baseSpellID > 0 then
                                            _tickBarViewerCache[baseSpellID] = ch
                                        end
                                    end
                                    -- BuffIcon tracked set (overlay + spell picker).
                                    -- Store at resolvedSid, baseSpellID, and the
                                    -- frame-cached correct spellID (ch._ecmeResolvedSid
                                    -- may differ from info-struct resolvedSid for buff
                                    -- entries where the struct returns the wrong ID).
                                    if isBuffIconViewer then
                                        _tickBuffIconTrackedSet[resolvedSid] = true
                                        if baseSpellID and baseSpellID > 0 then
                                            _tickBuffIconTrackedSet[baseSpellID] = true
                                        end
                                    end
                                    -- Linked-spell cache: for spells like Eclipse that
                                    -- have multiple variant auras under a single CDM
                                    -- child. Store at base and every linkedSpellID.
                                    local linked = cfc and cfc.linkedSpellIDs
                                    if linked then
                                        local base = baseSpellID
                                        if base and base > 0 and base ~= resolvedSid then
                                            if isBuffIconViewer or not _tickBlizzBuffChildCache[base] then
                                                _tickBlizzBuffChildCache[base] = ch
                                            end
                                            _tickBlizzAllChildCache[base] = ch
                                            if isBuffIconViewer then
                                                _tickBuffIconTrackedSet[base] = true
                                            end
                                        end
                                        for li = 1, #linked do
                                            local lsid = linked[li]
                                            if lsid and lsid > 0 and lsid ~= resolvedSid then
                                                if isBuffIconViewer or not _tickBlizzBuffChildCache[lsid] then
                                                    _tickBlizzBuffChildCache[lsid] = ch
                                                end
                                                _tickBlizzAllChildCache[lsid] = ch
                                                if isBuffIconViewer then
                                                    _tickBuffIconTrackedSet[lsid] = true
                                                end
                                            end
                                        end
                                    end
                                else
                                    -- CD/utility tracked set (overlay + spell picker)
                                    _tickCDUtilTrackedSet[resolvedSid] = true
                                    if baseSpellID and baseSpellID > 0 then
                                        _tickCDUtilTrackedSet[baseSpellID] = true
                                    end
                                end
                            end
                            -- Also map the correct spellID for buff viewer children.
                            -- Uses the persistent _cdIDToCorrectSID map (built OOC)
                            -- instead of calling ResolveChildSpellID which can fail
                            -- in combat due to secret number values.
                            if isBuffViewer and cdID then
                                local correctSid = _cdIDToCorrectSID[cdID]
                                if correctSid and resolvedSid and correctSid ~= resolvedSid then
                                    _tickBlizzAllChildCache[correctSid] = ch
                                    if isBuffIconViewer or not _tickBlizzBuffChildCache[correctSid] then
                                        _tickBlizzBuffChildCache[correctSid] = ch
                                    end
                                    if isBuffIconViewer then
                                        _tickBuffIconTrackedSet[correctSid] = true
                                    end
                                    if ch.wasSetFromAura == true or ch.auraInstanceID ~= nil then
                                        _tickBlizzActiveCache[correctSid] = true
                                    end
                                end
                            end
                            -- Active cache: Blizzard handles totem lifecycle natively
                            -- (frames leave EnumerateActive when totems expire)
                            if ch.wasSetFromAura == true or ch.auraInstanceID ~= nil then
                                if resolvedSid and resolvedSid > 0 then
                                    _tickBlizzActiveCache[resolvedSid] = true
                                    -- Also mark linked spell IDs as active so
                                    -- hideBuffsWhenInactive finds them regardless
                                    -- of which variant the tracked spell resolved to.
                                    local linked2 = cfc and cfc.linkedSpellIDs
                                    if linked2 then
                                        if baseSpellID and baseSpellID > 0 then
                                            _tickBlizzActiveCache[baseSpellID] = true
                                        end
                                        for li = 1, #linked2 do
                                            local lsid = linked2[li]
                                            if lsid and lsid > 0 then
                                                _tickBlizzActiveCache[lsid] = true
                                            end
                                        end
                                    end
                                end
                            end
                            -- Hook the child's Cooldown widget to capture DurationObjects
                            -- when Blizzard sets them. Avoids secret-value arithmetic.
                            -- Store captured values in our own tables, not on the child frame,
                            -- to avoid taint from writing to Blizzard-owned frame fields.
                            local chfc = cfc or FC(ch)
                            if ch.Cooldown and not chfc.hooked then
                                chfc.hooked = true
                                if ch.Cooldown.SetCooldownFromDurationObject then
                                    hooksecurefunc(ch.Cooldown, "SetCooldownFromDurationObject", function(_, durObj)
                                        _ecmeDurObjCache[ch] = durObj
                                        _ecmeChildHasDurObj[ch] = true
                                    end)
                                end
                                hooksecurefunc(ch.Cooldown, "SetCooldown", function(_, start, dur)
                                    if issecretvalue and (issecretvalue(dur) or issecretvalue(start)) then
                                        -- Secret values (in combat): store as-is, sink handles them
                                        _ecmeRawStartCache[ch] = start
                                        _ecmeRawDurCache[ch] = dur
                                    elseif dur and dur > 0 then
                                        _ecmeRawStartCache[ch] = start
                                        _ecmeRawDurCache[ch] = dur
                                    else
                                        -- dur=0 means inactive; wipe like Clear() (0 is truthy in Lua)
                                        _ecmeDurObjCache[ch] = nil
                                        _ecmeChildHasDurObj[ch] = nil
                                        _ecmeRawStartCache[ch] = nil
                                        _ecmeRawDurCache[ch] = nil
                                    end
                                end)
                                -- Clear hook: wipe our cached state when Blizzard clears the cooldown.
                                -- This ensures cached state is cleared after expiry.
                                if ch.Cooldown.Clear then
                                    hooksecurefunc(ch.Cooldown, "Clear", function()
                                        _ecmeDurObjCache[ch] = nil
                                        _ecmeChildHasDurObj[ch] = nil
                                        _ecmeRawStartCache[ch] = nil
                                        _ecmeRawDurCache[ch] = nil
                                    end)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local p = ECME.db.profile
    if not p.cdmBars.enabled then return end

    -- Reparent viewer frames into our containers.
    -- assignedSpells drives slot order; CollectAndReanchor matches children.
    if ns.CollectAndReanchor then ns.CollectAndReanchor() end
    if ns.UpdateOverlayVisuals then ns.UpdateOverlayVisuals() end
end

-------------------------------------------------------------------------------
--  Bar Visibility (always / in combat / mouseover / never) + Housing
-------------------------------------------------------------------------------

local function _CDMFadeTo(frame, toAlpha, duration)
    if not frame._cdmFadeAG then
        frame._cdmFadeAG = frame:CreateAnimationGroup()
        frame._cdmFadeAG:SetLooping("NONE")
        frame._cdmFadeAnim = frame._cdmFadeAG:CreateAnimation("Alpha")
        frame._cdmFadeAG:SetScript("OnFinished", function()
            frame:SetAlpha(frame._cdmFadeAG._toAlpha or toAlpha)
        end)
    end
    local ag = frame._cdmFadeAG
    local anim = frame._cdmFadeAnim
    if ag:IsPlaying() then ag:Stop() end
    ag._toAlpha = toAlpha
    anim:SetFromAlpha(frame:GetAlpha())
    anim:SetToAlpha(toAlpha)
    anim:SetDuration(duration or 0.15)
    anim:SetStartDelay(0)
    ag:Restart()
end

local function _CDMStopFade(frame)
    if frame._cdmFadeAG and frame._cdmFadeAG:IsPlaying() then
        frame._cdmFadeAG:Stop()
        frame._cdmFadeAG._toAlpha = nil
    end
end

local function _CDMAttachHoverHooks(barKey)
    local frame = cdmBarFrames[barKey]
    if not frame then return end

    local state = _cdmHoverStates[barKey]
    if not state then
        state = { isHovered = false, fadeDir = nil }
        _cdmHoverStates[barKey] = state
    end

    if not frame._cdmHoverHooked then
        frame._cdmHoverHooked = true

        local function OnEnter()
            state.isHovered = true
            local p = ECME.db and ECME.db.profile
            local barData = p and GetBarData(barKey)
            if barData and (barData.barVisibility or "always") == "mouseover" and state.fadeDir ~= "in" then
                state.fadeDir = "in"
                _CDMStopFade(frame)
                _CDMFadeTo(frame, barData.barBgAlpha or 1, 0.15)
            end
        end

        local function OnLeave()
            state.isHovered = false
            C_Timer.After(0.1, function()
                if state.isHovered then return end
                local p = ECME.db and ECME.db.profile
                local barData = p and GetBarData(barKey)
                if barData and (barData.barVisibility or "always") == "mouseover" and state.fadeDir ~= "out" then
                    state.fadeDir = "out"
                    _CDMFadeTo(frame, 0, 0.15)
                end
            end)
        end

        frame:HookScript("OnEnter", OnEnter)
        frame:HookScript("OnLeave", OnLeave)
        -- Store callbacks so we can hook new icons later
        frame._cdmHoverOnEnter = OnEnter
        frame._cdmHoverOnLeave = OnLeave
    end

    -- Hook any new child icons (CollectAndReanchor reparents fresh frames each pass)
    local icons = cdmBarIcons[barKey]
    if icons and frame._cdmHoverOnEnter then
        for _, icon in ipairs(icons) do
            if icon and not icon._cdmHoverHooked then
                icon._cdmHoverHooked = true
                icon:HookScript("OnEnter", frame._cdmHoverOnEnter)
                icon:HookScript("OnLeave", frame._cdmHoverOnLeave)
            end
        end
    end
end

local function _CDMApplyVisibility()
    local p = ECME.db and ECME.db.profile
    if not p then return end
    local inCombat = _inCombat
    -- Full vehicle UI: hide all bars
    local inVehicle = _cdmInVehicle
    -- Group state for mode checks
    local inRaid = IsInRaid and IsInRaid() or false
    local inParty = not inRaid and (IsInGroup and IsInGroup() or false)

    local unlockActive = EllesmereUI._unlockActive

    for _, barData in ipairs(p.cdmBars.bars) do
        local frame = cdmBarFrames[barData.key]
        if frame then
            -- Unlock mode: bars must stay visible for dragging
            if unlockActive then
                _CDMStopFade(frame)
                frame:SetAlpha(barData.barBgAlpha or 1)
                if frame.EnableMouseMotion then frame:EnableMouseMotion(true) end
            else

            local vis = barData.barVisibility or "always"

            -- Priority 1: vehicle always hides
            if inVehicle then
                _CDMStopFade(frame)
                frame:SetAlpha(0)
                if frame.EnableMouseMotion then frame:EnableMouseMotion(false) end
            -- Priority 2: visibility options (checkbox dropdown)
            elseif EllesmereUI.CheckVisibilityOptions(barData) then
                _CDMStopFade(frame)
                frame:SetAlpha(0)
                if frame.EnableMouseMotion then frame:EnableMouseMotion(false) end
            -- Priority 3: visibility mode dropdown
            elseif vis == "never" then
                _CDMStopFade(frame)
                frame:SetAlpha(0)
                if frame.EnableMouseMotion then frame:EnableMouseMotion(false) end
            elseif vis == "in_combat" then
                _CDMStopFade(frame)
                if inCombat then
                    frame:SetAlpha(barData.barBgAlpha or 1)
                    if frame.EnableMouseMotion then frame:EnableMouseMotion(true) end
                else
                    frame:SetAlpha(0)
                    if frame.EnableMouseMotion then frame:EnableMouseMotion(false) end
                end
            elseif vis == "out_of_combat" then
                _CDMStopFade(frame)
                if not inCombat then
                    frame:SetAlpha(barData.barBgAlpha or 1)
                    if frame.EnableMouseMotion then frame:EnableMouseMotion(true) end
                else
                    frame:SetAlpha(0)
                    if frame.EnableMouseMotion then frame:EnableMouseMotion(false) end
                end
            elseif vis == "in_raid" then
                _CDMStopFade(frame)
                if inRaid then
                    frame:SetAlpha(barData.barBgAlpha or 1)
                    if frame.EnableMouseMotion then frame:EnableMouseMotion(true) end
                else
                    frame:SetAlpha(0)
                    if frame.EnableMouseMotion then frame:EnableMouseMotion(false) end
                end
            elseif vis == "in_party" then
                _CDMStopFade(frame)
                if inParty or inRaid then
                    frame:SetAlpha(barData.barBgAlpha or 1)
                    if frame.EnableMouseMotion then frame:EnableMouseMotion(true) end
                else
                    frame:SetAlpha(0)
                    if frame.EnableMouseMotion then frame:EnableMouseMotion(false) end
                end
            elseif vis == "solo" then
                _CDMStopFade(frame)
                if not inRaid and not inParty then
                    frame:SetAlpha(barData.barBgAlpha or 1)
                    if frame.EnableMouseMotion then frame:EnableMouseMotion(true) end
                else
                    frame:SetAlpha(0)
                    if frame.EnableMouseMotion then frame:EnableMouseMotion(false) end
                end
            elseif vis == "mouseover" then
                _CDMAttachHoverHooks(barData.key)
                local state = _cdmHoverStates[barData.key]
                if not state or not state.isHovered then
                    _CDMStopFade(frame)
                    frame:SetAlpha(0)
                    if frame.EnableMouseMotion then frame:EnableMouseMotion(true) end
                end
            else -- "always"
                _CDMStopFade(frame)
                frame:SetAlpha(barData.barBgAlpha or 1)
                if frame.EnableMouseMotion then frame:EnableMouseMotion(true) end
            end

            end -- unlockActive else

            -- Icons are parented to UIParent (not the container) so they
            -- don't inherit the container's alpha. Explicitly hide/show them.
            local barHidden = frame:GetAlpha() == 0
            local icons = cdmBarIcons[barData.key]
            if icons then
                for i = 1, #icons do
                    local icon = icons[i]
                    if icon then
                        if barHidden then
                            icon:Hide()
                        else
                            icon:Show()
                        end
                    end
                end
            end
        end
    end
end
ns.CDMApplyVisibility = _CDMApplyVisibility

-- Helper to get barData by key
function GetBarData(barKey)
    return barDataByKey[barKey]
end



-------------------------------------------------------------------------------
--  Build all CDM bars
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--  Keybind cache for CDM icons
--  Built once out-of-combat by scanning all action bar slots.
--  Stored as { [spellID] = "formatted key" } so icon display is just a lookup.
--  Deferred if called during combat; fires on PLAYER_REGEN_ENABLED instead.
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
--  Keybind cache for CDM icons
--  Reads HotKey text directly from action button frames ΓÇö the same source
--  the action bar itself uses, so it's always correct regardless of bar addon.
--  Deferred if called during combat; fires on PLAYER_REGEN_ENABLED instead.
-------------------------------------------------------------------------------

-- Action bar slot ΓåÆ binding name map. Non-bar-1 entries listed first so that
-- if a spell appears on multiple bars, the more specific bar wins over bar 1.
local _barBindingDefs = {
    { prefix = "MULTIACTIONBAR1BUTTON", startSlot = 61  },  -- bar 2 bottom left
    { prefix = "MULTIACTIONBAR2BUTTON", startSlot = 49  },  -- bar 3 bottom right
    { prefix = "MULTIACTIONBAR3BUTTON", startSlot = 25  },  -- bar 4 right
    { prefix = "MULTIACTIONBAR4BUTTON", startSlot = 37  },  -- bar 5 left
    { prefix = "MULTIACTIONBAR5BUTTON", startSlot = 145 },  -- bar 6
    { prefix = "MULTIACTIONBAR6BUTTON", startSlot = 157 },  -- bar 7
    { prefix = "MULTIACTIONBAR7BUTTON", startSlot = 169 },  -- bar 8
    { prefix = "ACTIONBUTTON",          startSlot = 1   },  -- bar 1 (last = lowest priority)
}

local function FormatKeybindKey(key)
    if not key or key == "" then return nil end
    key = key:gsub("SHIFT%-", "S")
    key = key:gsub("CTRL%-",  "C")
    key = key:gsub("ALT%-",   "A")
    key = key:gsub("Mouse Button ", "M")
    key = key:gsub("MOUSEWHEELUP",   "MwU")
    key = key:gsub("MOUSEWHEELDOWN", "MwD")
    key = key:gsub("NUMPADDECIMAL",  "N.")
    key = key:gsub("NUMPADPLUS",     "N+")
    key = key:gsub("NUMPADMINUS",    "N-")
    key = key:gsub("NUMPADMULTIPLY", "N*")
    key = key:gsub("NUMPADDIVIDE",   "N/")
    key = key:gsub("NUMPAD",         "N")
    key = key:gsub("BUTTON",         "M")
    return key ~= "" and key or nil
end

local function RebuildKeybindCache()
    wipe(_cdmKeybindCache)
    for _, def in ipairs(_barBindingDefs) do
        for i = 1, 12 do
            local bindName = def.prefix .. i
            local key = GetBindingKey(bindName)
            if key then
                local slot = def.startSlot + i - 1
                if def.prefix == "ACTIONBUTTON" then
                    local btn = _G["ActionButton" .. i]
                    if btn and btn.action then slot = btn.action end
                end
                local slotType, id = GetActionInfo(slot)
                local spellID
                if slotType == "spell" then
                    spellID = id
                elseif slotType == "macro" and id then
                    -- GetMacroSpell works for macro-index based entries.
                    -- For direct spell macros, GetActionInfo returns the spell ID as id.
                    local macroSpell = GetMacroSpell(id)
                    spellID = macroSpell or (id > 0 and id) or nil
                end
                if spellID then
                    local formatted = FormatKeybindKey(key)
                    if not _cdmKeybindCache[spellID] then
                        _cdmKeybindCache[spellID] = formatted
                    end
                    local name = C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
                    if name and not _cdmKeybindCache[name] then
                        _cdmKeybindCache[name] = formatted
                    end
                end
            end
        end
    end
end

-- Apply the current cache to all visible CDM icon keybind texts
local function ApplyCachedKeybinds()
    for barKey, icons in pairs(cdmBarIcons) do
        local bd = barDataByKey[barKey]
        for _, icon in ipairs(icons) do
            if icon._keybindText then
                if bd and bd.showKeybind and icon._spellID then
                    local key = _cdmKeybindCache[icon._spellID]
                    local name = C_Spell.GetSpellName and C_Spell.GetSpellName(icon._spellID)
                    if not key and name then key = _cdmKeybindCache[name] end
                    if key then
                        icon._keybindText:SetText(key)
                        icon._keybindText:Show()
                    else
                        icon._keybindText:Hide()
                    end
                else
                    icon._keybindText:Hide()
                end
            end
        end
    end
end

-- Public entry point: rebuild cache then apply. Defers if in combat.
local function UpdateCDMKeybinds()
    if _inCombat then
        _keybindRebuildPending = true
        return
    end
    _keybindRebuildPending = false
    RebuildKeybindCache()
    _keybindCacheReady = true
    -- Defer apply by one frame so the Blizzard tick has populated icon._spellID
    C_Timer.After(0, ApplyCachedKeybinds)
end
ns.UpdateCDMKeybinds = UpdateCDMKeybinds
-- Expose apply-only for the tick loop (new spellID assigned to an icon mid-session)
ns.ApplyCachedKeybinds = ApplyCachedKeybinds
ns.CDMKeybindCache = _cdmKeybindCache

BuildAllCDMBars = function()
    -- Last-resort spec guard: if we're about to build bars with wrong spec, fix it
    if not _specValidated then
        ValidateSpec()
    end

    local p = ECME.db.profile

    -- Migration: remove misc bars and unanchor anything that referenced them
    do
        local bars = p.cdmBars and p.cdmBars.bars
        if bars then
            local miscKeys = {}
            for i = #bars, 1, -1 do
                if bars[i].barType == "misc" then
                    miscKeys[bars[i].key] = true
                    table.remove(bars, i)
                end
            end
            if next(miscKeys) then
                for _, bd in ipairs(bars) do
                    if bd.anchorTo and miscKeys[bd.anchorTo] then
                        bd.anchorTo = "none"
                    end
                end
            end
        end
    end

    if not p.cdmBars.enabled then
        -- Restore Blizzard CDM if we're disabled
        RestoreBlizzardCDM()
        for key, frame in pairs(cdmBarFrames) do
            EllesmereUI.SetElementVisibility(frame, false)
        end
        return
    end

    -- Hide ALL existing bar frames before rebuilding. This ensures bars
    -- from a previous spec that are not in the current spec get hidden.
    for key, frame in pairs(cdmBarFrames) do
        EllesmereUI.SetElementVisibility(frame, false)
    end

    -- Hide Blizzard CDM
    if p.cdmBars.hideBlizzard then
        HideBlizzardCDM()
    end

    --[[ DISABLED: useBlizzardBuffBars feature temporarily removed
    local useBlizzBuffs = p.cdmBars.useBlizzardBuffBars
    if useBlizzBuffs and p.cdmBars.hideBlizzard then
        RestoreBlizzardBuffFrame()
    end
    --]]
    local useBlizzBuffs = false

    -- Build each bar and populate fast lookup
    local hookActive = ns.IsViewerHooked and ns.IsViewerHooked()
    wipe(barDataByKey)
    for i, barData in ipairs(p.cdmBars.bars) do
        barDataByKey[barData.key] = barData
        if useBlizzBuffs and barData.key == "buffs" then
            local frame = cdmBarFrames[barData.key]
            if frame then EllesmereUI.SetElementVisibility(frame, false) end
        else
            BuildCDMBar(i)
            if hookActive and BLIZZ_CDM_FRAMES[barData.key] then
                -- Hooked default bar: skip icon state reset and layout.
                -- CollectAndReanchor will repopulate from viewer pools.
                local frame = cdmBarFrames[barData.key]
                if frame then frame._prevVisibleCount = nil end
            else
                RefreshCDMIconAppearance(barData.key)
                -- Reset cached icon state so textures re-evaluate after a character switch
                local icons = cdmBarIcons[barData.key]
                if icons then
                    for _, icon in ipairs(icons) do
                        icon._lastTex = nil
                        icon._lastDesat = nil
                        icon._spellID = nil
                        icon._blizzChild = nil
                    end
                end
                local frame = cdmBarFrames[barData.key]
                if frame then frame._prevVisibleCount = nil end
                LayoutCDMBar(barData.key)
                ApplyCDMTooltipState(barData.key)
            end
        end
    end
    -- When hooks are active, queue a reanchor to repopulate default bars
    if hookActive and ns.QueueReanchor then
        ns.QueueReanchor()
    end
    -- Re-apply saved positions now that LayoutCDMBar has set correct frame
    -- sizes. The initial BuildCDMBar call used stale dimensions for the
    -- grow-direction anchor conversion, causing position drift.
    for _, barData in ipairs(p.cdmBars.bars) do
        if barData.enabled then
            local ak = barData.anchorTo
            if not ak or ak == "none" then
                local frame = cdmBarFrames[barData.key]
                local pos = p.cdmBarPositions[barData.key]
                if frame and pos and pos.point then
                    -- Skip for unlock-anchored bars (anchor system is authority)
                    local unlockKey = "CDM_" .. barData.key
                    local anchored = EllesmereUI.IsUnlockAnchored and EllesmereUI.IsUnlockAnchored(unlockKey)
                    if not anchored or not frame:GetLeft() then
                        ApplyBarPositionCentered(frame, pos, barData.key)
                    end
                end
            end
        end
    end
    -- Second pass: reapply unlock-mode anchors now that ALL bars are
    -- positioned and sized.  The first pass (inside LayoutCDMBar) may
    -- have run ReapplyOwnAnchor before the target bar was repositioned
    -- (e.g. cooldowns processed before utility).  This corrects that.
    if EllesmereUI.ReapplyOwnAnchor then
        for _, barData in ipairs(p.cdmBars.bars) do
            EllesmereUI.ReapplyOwnAnchor("CDM_" .. barData.key)
        end
    end
    _CDMApplyVisibility()
    UpdateCDMKeybinds()

    -- Ensure vehicle/petbattle proxy exists to trigger _CDMApplyVisibility on state change
    if not _cdmVehicleProxy then
        _cdmVehicleProxy = CreateFrame("Frame", nil, UIParent, "SecureHandlerStateTemplate")
        _cdmVehicleProxy:SetAttribute("_onstate-cdmvehicle", [[
            self:CallMethod("OnVehicleStateChanged", newstate)
        ]])
        _cdmVehicleProxy.OnVehicleStateChanged = function(_, state)
            _cdmInVehicle = (state == "hide")
            _CDMApplyVisibility()
        end
        RegisterStateDriver(_cdmVehicleProxy, "cdmvehicle", "[vehicleui][petbattle] hide; show")
    end

    -- Batch-apply pending cooldown font styling (single deferred call, no per-icon closures)
    C_Timer.After(0, function()
        for _, icons in pairs(cdmBarIcons) do
            for _, icon in ipairs(icons) do
                if icon._pendingFontPath and icon._cooldown then
                    local fontPath, fontSize = icon._pendingFontPath, icon._pendingFontSize
                    local fR, fG, fB = icon._pendingFontR, icon._pendingFontG, icon._pendingFontB
                    for ri = 1, icon._cooldown:GetNumRegions() do
                        local region = select(ri, icon._cooldown:GetRegions())
                        if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                            SetBlizzCDMFont(region, fontPath, fontSize, fR, fG, fB)
                            break
                        end
                    end
                    icon._pendingFontPath = nil; icon._pendingFontSize = nil
                    icon._pendingFontR = nil; icon._pendingFontG = nil; icon._pendingFontB = nil
                end
            end
        end
    end)
end

-- Expose for options
ns.BuildAllCDMBars = BuildAllCDMBars
ns.cdmBarFrames = cdmBarFrames
ns.cdmBarIcons = cdmBarIcons
ns.barDataByKey = barDataByKey
ns.SaveCDMBarPosition = SaveCDMBarPosition
ns.LayoutCDMBar = LayoutCDMBar
ns.BLIZZ_CDM_FRAMES = BLIZZ_CDM_FRAMES
ns.CDM_BAR_CATEGORIES = CDM_BAR_CATEGORIES
ns.MAX_CUSTOM_BARS = MAX_CUSTOM_BARS
ns.FindPlayerPartyFrame = EllesmereUI.FindPlayerPartyFrame

-- Expose LayoutCDMBar globally so unlock mode can trigger rebuilds
EllesmereUI.LayoutCDMBar = LayoutCDMBar
ns.FindPlayerUnitFrame = EllesmereUI.FindPlayerUnitFrame
ns.RestoreBlizzardCDM = RestoreBlizzardCDM
ns.HideBlizzardCDM = HideBlizzardCDM

-- Interactive Preview Helpers loaded from EllesmereUICdmSpellPicker.lua

-------------------------------------------------------------------------------
--  CDM Bar: First Login Capture
-------------------------------------------------------------------------------
local function CDMFirstLoginCapture()
    local p = ECME.db.profile
    local captured = CaptureCDMPositions()

    for _, barData in ipairs(p.cdmBars.bars) do
        local cap = captured[barData.key]
        if cap then
            -- Icon size: visual size from child icon (base width * child scale).
            if cap.iconSize then
                barData.iconSize = cap.iconSize
            end
            -- Spacing (icon padding from Edit Mode setting)
            if cap.spacing then
                barData.spacing = cap.spacing
            end
            -- Rows (counted from distinct Y positions of visible icons)
            if cap.numRows then
                barData.numRows = cap.numRows
            end
            -- Orientation
            if cap.isHorizontal ~= nil then
                if not cap.isHorizontal then barData.growDirection = "DOWN" end
                barData.verticalOrientation = not cap.isHorizontal
            end
            -- Position: no scale division needed (scale is always 1)
            if cap.point then
                p.cdmBarPositions[barData.key] = {
                    point = cap.point, relPoint = cap.relPoint,
                    x = cap.x, y = cap.y,
                }
            end
        end
    end

    p._capturedOnce = nil  -- no longer per-profile
    ECME.db.sv._capturedOnce = true
end

--- Repopulate all main bars from Blizzard CDM for the current spec.
--- Wipes assignedSpells/removedSpells/dormantSpells so CollectAndReanchor
--- shows whatever Blizzard currently has, then saves the spec profile.
function ns.RepopulateFromBlizzard()
    local p = ECME.db and ECME.db.profile
    if not p or not p.cdmBars then return end
    local specKey = ns.GetActiveSpecKey()
    if not specKey or specKey == "0" then return end

    for _, barData in ipairs(p.cdmBars.bars) do
        if MAIN_BAR_KEYS[barData.key] then
            local sd = ns.GetBarSpellData(barData.key)
            if sd then
                sd.assignedSpells = nil
                sd.removedSpells = nil
                sd.dormantSpells = nil
            end
        end
    end

    if ns.RebuildSpellRouteMap then ns.RebuildSpellRouteMap() end
    BuildAllCDMBars()
    -- Run CollectAndReanchor immediately so live icons are populated
    -- before the options page refreshes the preview.
    if ns.CollectAndReanchor then ns.CollectAndReanchor() end
    _CDMApplyVisibility()

    C_Timer.After(1, function()
        local sk = ns.GetActiveSpecKey()
        if sk and sk ~= "0" then
            SaveCurrentSpecProfile()
        end
    end)
end

-------------------------------------------------------------------------------
--  Register CDM bars with unlock mode
-------------------------------------------------------------------------------
RegisterCDMUnlockElements = function()
    if not EllesmereUI or not EllesmereUI.RegisterUnlockElements then return end
    local MK = EllesmereUI.MakeUnlockElement

    -- Build a lookup of which bars are anchored to which parent
    local anchorChildren = {}  -- parentKey -> { childKey1, childKey2, ... }
    for _, barData in ipairs(ECME.db.profile.cdmBars.bars) do
        local anchorKey = barData.anchorTo
        if anchorKey and anchorKey ~= "none" and anchorKey ~= "partyframe" and anchorKey ~= "playerframe" then
            if not anchorChildren[anchorKey] then anchorChildren[anchorKey] = {} end
            anchorChildren[anchorKey][#anchorChildren[anchorKey] + 1] = barData.key
        end
    end

    local elements = {}
    for _, barData in ipairs(ECME.db.profile.cdmBars.bars) do
        local key = barData.key
        local frame = cdmBarFrames[key]
        if frame and barData.enabled then
            -- Skip bars anchored to party frame, player frame, or mouse cursor
            local isPartyAnchored = barData.anchorTo == "partyframe"
            local isPlayerFrameAnchored = barData.anchorTo == "playerframe"
            local isMouseAnchored = barData.anchorTo == "mouse"
            if not isPartyAnchored and not isPlayerFrameAnchored and not isMouseAnchored then
            local bd = barDataByKey[key]
            -- Collect linked unlock element keys (children anchored to this bar)
            local linked = nil
            if anchorChildren[key] then
                linked = {}
                for _, childKey in ipairs(anchorChildren[key]) do
                    linked[#linked + 1] = "CDM_" .. childKey
                end
            end

            elements[#elements + 1] = MK({
                key = "CDM_" .. key,
                label = "CDM: " .. barData.name,
                group = "Cooldown Manager",
                order = 600,
                linkedKeys = linked,
                isHidden = function()
                    -- If this bar key is no longer in the current profile's
                    -- barDataByKey, it is a stale registration from a previous
                    -- profile and should not get a mover.
                    return not barDataByKey[key]
                end,
                getFrame = function() return cdmBarFrames[key] end,
                getSize = function()
                    local f = cdmBarFrames[key]
                    local bd2 = barDataByKey[key]
                    return GetStableCDMBarSize(key, f, bd2)
                end,
                linkedDimensions = true,
                setWidth = function(_, newW)
                    -- Reverse-engineer iconSize from target width
                    local bd2 = barDataByKey[key]
                    if not bd2 then return end
                    local count = CountCDMBarSpells(key)
                    if count == 0 then return end
                    local rows = bd2.numRows or 1
                    if rows < 1 then rows = 1 end
                    local stride = ComputeTopRowStride(bd2, count)
                    local grow = bd2.growDirection or "CENTER"
                    local isH = (grow == "RIGHT" or grow == "LEFT" or grow == "CENTER")
                    local sp = SnapForScale(bd2.spacing or 2, 1)
                    local rawIcon
                    if isH then
                        rawIcon = (newW - (stride - 1) * sp) / stride
                    else
                        rawIcon = (newW - (rows - 1) * sp) / rows
                    end
                    if rawIcon < 8 then rawIcon = 8 end
                    bd2.iconSize = math.floor(rawIcon + 0.5)
                    LayoutCDMBar(key)
                end,
                setHeight = function(_, newH)
                    -- Reverse-engineer iconSize from target height
                    local bd2 = barDataByKey[key]
                    if not bd2 then return end
                    local count = CountCDMBarSpells(key)
                    if count == 0 then return end
                    local rows = bd2.numRows or 1
                    if rows < 1 then rows = 1 end
                    local stride = ComputeTopRowStride(bd2, count)
                    local grow = bd2.growDirection or "CENTER"
                    local isH = (grow == "RIGHT" or grow == "LEFT" or grow == "CENTER")
                    local sp = SnapForScale(bd2.spacing or 2, 1)
                    local shape = bd2.iconShape or "none"
                    local rawIcon
                    if isH then
                        rawIcon = (newH - (rows - 1) * sp) / rows
                        if shape == "cropped" then rawIcon = rawIcon / 0.80 end
                    else
                        rawIcon = (newH - (stride - 1) * sp) / stride
                        if shape == "cropped" then rawIcon = rawIcon / 0.80 end
                    end
                    if rawIcon < 8 then rawIcon = 8 end
                    bd2.iconSize = math.floor(rawIcon + 0.5)
                    LayoutCDMBar(key)
                end,
                savePos = function(_, point, relPoint, x, y)
                    local p = ECME.db.profile
                    -- Centralized system already converts to CENTER/CENTER
                    p.cdmBarPositions[key] = { point = point, relPoint = relPoint, x = x, y = y }
                    -- Skip rebuild when called from anchor propagation or while
                    -- unlock mode is active (unlock mode owns positioning then).
                    if not EllesmereUI._propagatingSave and not EllesmereUI._unlockActive then
                        BuildAllCDMBars()
                    end
                end,
                loadPos = function()
                    return ECME.db.profile.cdmBarPositions[key]
                end,
                clearPos = function()
                    ECME.db.profile.cdmBarPositions[key] = nil
                end,
                applyPos = function()
                    BuildAllCDMBars()
                end,
                isAnchored = function()
                    local bd2 = barDataByKey[key]
                    if not bd2 or not bd2.anchorTo then return false end
                    local a = bd2.anchorTo
                    -- Only valid anchor types: mouse, partyframe, playerframe, erb_*
                    if a == "mouse" or a == "partyframe" or a == "playerframe" then return true end
                    if a:sub(1, 4) == "erb_" then return true end
                    return false
                end,
            })
            end -- not isPartyAnchored
        end
    end

    if #elements > 0 then
        EllesmereUI:RegisterUnlockElements(elements)
    end
end
ns.RegisterCDMUnlockElements = RegisterCDMUnlockElements
_G._ECME_RegisterUnlock = RegisterCDMUnlockElements

-- RequestUpdate delegates to ns.RequestUpdate (defined in EllesmereUICdmBarGlows.lua).
-- Falls back to no-op if bar glows module hasn't loaded yet.
local function RequestUpdate()
    if ns.RequestUpdate then ns.RequestUpdate() end
end


-------------------------------------------------------------------------------
--  Initialization
-------------------------------------------------------------------------------
local function SetActiveSpec()
    local p = ECME.db.profile
    local specKey = GetCurrentSpecKey()
    ns.SetActiveSpecKey(specKey)
    EnsureSpec(p, specKey)
end

-------------------------------------------------------------------------------
--  Bootstrap / Addon Enable
--
--  `OnInitialize` runs once per addon load to create SavedVariables hooks and
--  expose options callbacks. `OnEnable` runs once per login/reload session to
--  load spec state, initialize helper modules, and choose between first-login
--  capture and the normal `CDMFinishSetup` path.
-------------------------------------------------------------------------------
function ECME:OnInitialize()
    self.db = EllesmereUI.Lite.NewDB("EllesmereUICooldownManagerDB", DEFAULTS, true)

    -- Migrate old pandemicR/G/B flat keys to pandemicGlowColor table
    do
        local p = self.db and self.db.profile
        if p and p.cdmBars and p.cdmBars.bars then
            for _, barData in ipairs(p.cdmBars.bars) do
                if barData.pandemicR and not barData.pandemicGlowColor then
                    barData.pandemicGlowColor = {
                        r = barData.pandemicR or 1,
                        g = barData.pandemicG or 1,
                        b = barData.pandemicB or 0,
                    }
                    barData.pandemicGlowStyle = barData.pandemicGlowStyle or 1
                end
            end
        end
    end

    -- Save spec profile before StripDefaults runs on logout
    EllesmereUI.Lite.RegisterPreLogout(function()
        local specKey = ns.GetActiveSpecKey()
        if specKey and specKey ~= "0" then
            SaveCurrentSpecProfile()
        end
    end)

    -- Check if we need first-login capture (per-install flag on SV root)
    self._needsCapture = not self.db.sv._capturedOnce

    -- Expose for options
    _G._ECME_AceDB = self.db
    _G._ECME_Apply = function()
        if ns.RebuildSpellRouteMap then ns.RebuildSpellRouteMap() end
        BuildAllCDMBars()
        if ns.QueueReanchor then ns.QueueReanchor() end
        _CDMApplyVisibility()
        if ns.RequestBarGlowUpdate then ns.RequestBarGlowUpdate() end
        if ns.BuildTrackedBuffBars then ns.BuildTrackedBuffBars() end
    end

    -- Append SharedMedia textures to TBB runtime tables
    if EllesmereUI.AppendSharedMediaTextures and ns.TBB_TEXTURE_NAMES then
        EllesmereUI.AppendSharedMediaTextures(
            ns.TBB_TEXTURE_NAMES,
            ns.TBB_TEXTURE_ORDER,
            nil,
            ns.TBB_TEXTURES
        )
    end
end

function ECME:OnEnable()
    -- Cache player race/class for trinket/racial/potion tracking
    _playerRace = select(2, UnitRace("player"))
    _playerClass = select(2, UnitClass("player"))
    ns._playerRace = _playerRace
    ns._playerClass = _playerClass
    ns._myRacialsSet = _myRacialsSet

    -- Build cached racial spell list for this character (used for render-time substitution)
    table.wipe(_myRacials)
    table.wipe(_myRacialsSet)
    local racialList = _playerRace and RACE_RACIALS[_playerRace]
    if racialList then
        for _, entry in ipairs(racialList) do
            local sid = type(entry) == "table" and entry[1] or entry
            local reqClass = type(entry) == "table" and entry.class or nil
            if not reqClass or reqClass == _playerClass then
                _myRacials[#_myRacials + 1] = sid
                _myRacialsSet[sid] = true
            end
        end
    end

    -- Enable CDM cooldown viewer (keep Blizzard CDM running in background
    -- so we can read its children even while hidden)
    if C_CVar and C_CVar.SetCVar then
        pcall(C_CVar.SetCVar, "cooldownViewerEnabled", "1")
    end

    -- Force Blizzard's Edit Mode HideWhenInactive=1 on buff viewers.
    -- This makes Blizzard natively hide inactive buff frames in the pool,
    -- so our IsShown() filter works. When our hideBuffsWhenInactive option
    -- is OFF, we override by calling Show() on all pool frames.
    C_Timer.After(1, function()
        if not C_EditMode or not C_EditMode.GetLayouts or not C_EditMode.SaveLayouts then return end
        local ok, layoutInfo = pcall(C_EditMode.GetLayouts)
        if not ok or not layoutInfo then return end
        local activeIdx = layoutInfo.activeLayout
        if not activeIdx or type(activeIdx) ~= "number" then return end
        local activeLayout = layoutInfo.layouts and layoutInfo.layouts[activeIdx]
        if not activeLayout or not activeLayout.systems then return end
        local changed = false
        local cooldownSystem = Enum.EditModeSystem and Enum.EditModeSystem.CooldownViewer
        local hideEnum = Enum.EditModeCooldownViewerSetting and Enum.EditModeCooldownViewerSetting.HideWhenInactive
        local buffIconIdx = Enum.EditModeCooldownViewerSystemIndices and Enum.EditModeCooldownViewerSystemIndices.BuffIcon
        local buffBarIdx = Enum.EditModeCooldownViewerSystemIndices and Enum.EditModeCooldownViewerSystemIndices.BuffBar
        if not cooldownSystem or not hideEnum then return end
        for _, systemInfo in ipairs(activeLayout.systems) do
            if systemInfo.system == cooldownSystem
               and (systemInfo.systemIndex == buffIconIdx or systemInfo.systemIndex == buffBarIdx)
               and type(systemInfo.settings) == "table" then
                local found = false
                for _, setting in ipairs(systemInfo.settings) do
                    if setting.setting == hideEnum then
                        found = true
                        if setting.value ~= 1 then
                            setting.value = 1
                            changed = true
                        end
                        break
                    end
                end
                if not found then
                    systemInfo.settings[#systemInfo.settings + 1] = { setting = hideEnum, value = 1 }
                    changed = true
                end
            end
        end
        if changed then
            pcall(C_EditMode.SaveLayouts, layoutInfo)
        end
    end)

    -- Detect spec/character change since last session and swap profiles
    local p = ECME.db.profile
    local oldSpecKey = ns.GetActiveSpecKey()
    local newSpecKey = GetCurrentSpecKey()
    if newSpecKey ~= "0" and oldSpecKey and oldSpecKey ~= "0" and oldSpecKey ~= newSpecKey then
        -- Spec changed (different character or respec while offline).
        -- Non-spell per-spec data needs loading.
        SetActiveSpec()
        LoadSpecProfile(newSpecKey)
        _specValidated = true
    elseif newSpecKey ~= "0" then
        SetActiveSpec()
        -- Load non-spell per-spec data for the current spec
        local specKey = ns.GetActiveSpecKey()
        local specProfiles = SpellStore.GetSpecProfiles()
        if specKey and specKey ~= "0" and specProfiles[specKey] then
            LoadSpecProfile(specKey)
        end
        _specValidated = true
    else
        -- GetSpecialization() not ready yet -- leave activeSpecKey as-is,
        -- ValidateSpec will fix it when SPELLS_CHANGED or PEW fires
        _specValidated = false
    end

    EnsureMappings(GetStore())

    -- (BarGlows + TBB init removed -- disabled pending rewrite)

    -- CDM Bars: first-login capture or normal setup
    if self._needsCapture then
        -- Defer to PLAYER_ENTERING_WORLD so Edit Mode has applied positions
        self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnCDMFirstLogin")
    else
        self:CDMFinishSetup()
    end

    if ns.ApplyPerSlotHidingAndPackSoon then ns.ApplyPerSlotHidingAndPackSoon() end
    RequestUpdate()

    if ns.HookAllCDMChildren then
        ns.HookAllCDMChildren(_G.BuffIconCooldownViewer)
        C_Timer.After(1, function() if ns.HookAllCDMChildren then ns.HookAllCDMChildren(_G.BuffIconCooldownViewer) end end)
        C_Timer.After(3, function() if ns.HookAllCDMChildren then ns.HookAllCDMChildren(_G.BuffIconCooldownViewer) end end)
    end

    -- Proc glow hooks (ShowAlert/HideAlert on Blizzard CDM children)
    InstallProcGlowHooks()
    C_Timer.After(1, InstallProcGlowHooks)

    -- Clear all proc glows after layout settles, then let Blizzard re-fire
    -- them on the correct frames. Fixes stale glows from login when frames
    -- shift positions (e.g. trinket filtering removes a slot).
    C_Timer.After(2, function()
        for _, icons in pairs(cdmBarIcons) do
            for _, icon in ipairs(icons) do
                if icon._glowOverlay and icon._glowOverlay._glowActive then
                    StopNativeGlow(icon._glowOverlay)
                    icon._procGlowActive = false
                end
            end
        end
    end)

    -- Initialize Bar Glows overlay system
    if ns.InitBarGlows then ns.InitBarGlows() end

end

function ECME:OnCDMFirstLogin()
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    CDMFirstLoginCapture()
    self._needsCapture = false
    self:CDMFinishSetup()
end

-- (ForcePopulateBlizzardViewers removed -- replaced by viewer hooks)

-------------------------------------------------------------------------------
--  Talent-Aware Reconcile
--  When talents change, instead of wiping assignedSpells and losing ordering,
--  this function:
--  1) Moves unavailable spells from the active list to dormantSpells with
--     their original slot index preserved
--  2) Re-inserts any dormant spells that became available again at their
--     saved slot position (pushing existing spells forward)
--  3) Appends genuinely new spells (not previously tracked) at the end
--  Applies to: cooldown bar, utility bar, custom cooldown/utility bars
-------------------------------------------------------------------------------
local function TalentAwareReconcile()
    local p = ECME.db and ECME.db.profile
    if not p or not p.cdmBars then return end

    local knownSet = BuildAvailableSpellPool()

    -- Helper: reconcile a single spell list (assignedSpells)
    -- Returns the new active list with dormant spells removed and returning
    -- spells re-inserted at their saved positions.
    -- classSpellSet: optional set of ALL class spellIDs (from the full CDM
    -- category set). When provided, spells in this set are never moved to
    -- dormant -- they are permanent class abilities that may appear missing
    -- from the "currently known" set during API timing gaps.
    local function ReconcileSpellList(spellList, dormant, removed, classSpellSet)
        if not spellList then return nil, dormant end
        if not dormant then dormant = {} end

        -- Phase 1: separate active list into still-known and newly-dormant
        -- Also check IsPlayerSpell as a fallback for spells the CDM viewer
        -- hasn't updated yet (e.g. choice-node talent swaps).
        local _IPS = IsPlayerSpell
        local active = {}
        local seenInActive = {}
        for i, sid in ipairs(spellList) do
            if sid and sid ~= 0 then
                if sid < 0 then
                    -- Negative IDs are items/trinkets -- always keep
                    active[#active + 1] = sid
                    seenInActive[sid] = true
                elseif seenInActive[sid] then
                    -- Duplicate already in active list -- skip silently
                elseif knownSet[sid] or (_IPS and _IPS(sid))
                       or (classSpellSet and classSpellSet[sid]) then
                    active[#active + 1] = sid
                    seenInActive[sid] = true
                else
                    -- Spell is no longer known -- save its slot index and move to dormant
                    dormant[sid] = i
                end
            end
        end

        -- Build a set of spells already in the active list for dedup
        local activeSet = seenInActive

        -- Phase 2: check dormant spells -- any that are now known get re-inserted
        -- Collect returning spells sorted by their saved slot index (lowest first)
        -- so insertions don't shift each other's target positions.
        -- Also check IsPlayerSpell directly on dormant spells as a fallback --
        -- the CDM viewer may not have updated its entries yet after a talent
        -- swap (e.g. choice-node spells like Bladestorm/Avatar share a viewer
        -- slot and the viewer may still report the old spell's ID).
        local returning = {}
        for sid, savedSlot in pairs(dormant) do
            local isKnown = knownSet[sid]
                or (_IPS and _IPS(sid))
                or (classSpellSet and classSpellSet[sid])
            if isKnown and not (removed and removed[sid]) then
                -- Only return spells that aren't already in the active list
                if not activeSet[sid] then
                    returning[#returning + 1] = { sid = sid, slot = savedSlot }
                else
                    -- Already active -- just clean it from dormant
                    dormant[sid] = nil
                end
            end
        end
        table.sort(returning, function(a, b) return a.slot < b.slot end)

        -- Insert each returning spell at its saved slot (clamped to list bounds)
        for _, entry in ipairs(returning) do
            dormant[entry.sid] = nil  -- no longer dormant
            -- Clamp insertion index: if the list is shorter now, insert at end
            local insertAt = entry.slot
            if insertAt > #active + 1 then insertAt = #active + 1 end
            if insertAt < 1 then insertAt = 1 end
            table.insert(active, insertAt, entry.sid)
        end

        -- Phase 3: clean up dormant entries for spells that are no longer in
        -- any CDM category at all (removed from game / different class)
        -- Keep dormant entries for spells that exist but are just unlearned.
        -- Store ALL related IDs (base, override, linked) so a spell stored
        -- by its base ID is still recognized even if the viewer resolves it
        -- to an override ID.
        local allSpellIDs = {}
        if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet then
            for cat = 0, 3 do
                local allIDs = C_CooldownViewer.GetCooldownViewerCategorySet(cat, true)
                if allIDs then
                    for _, cdID in ipairs(allIDs) do
                        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                        if info then
                            if info.spellID and info.spellID > 0 then
                                allSpellIDs[info.spellID] = true
                            end
                            if info.overrideSpellID and info.overrideSpellID > 0 then
                                allSpellIDs[info.overrideSpellID] = true
                            end
                            if info.linkedSpellIDs then
                                for _, lsid in ipairs(info.linkedSpellIDs) do
                                    if lsid and lsid > 0 then
                                        allSpellIDs[lsid] = true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        for sid in pairs(dormant) do
            if not allSpellIDs[sid] then
                dormant[sid] = nil
            end
        end

        return active, (next(dormant) and dormant or nil)
    end

    -- Build a set of ALL class spellIDs (regardless of current talents).
    -- Used for custom bars so permanent class abilities (e.g. Stampeding Roar)
    -- are never moved to dormant due to API timing gaps during talent swaps.
    local classSpellSet = {}
    if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet then
        for cat = 0, 3 do
            local allIDs = C_CooldownViewer.GetCooldownViewerCategorySet(cat, true)
            if allIDs then
                for _, cdID in ipairs(allIDs) do
                    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                    if info then
                        if info.spellID and info.spellID > 0 then
                            classSpellSet[info.spellID] = true
                        end
                        if info.overrideSpellID and info.overrideSpellID > 0 then
                            classSpellSet[info.overrideSpellID] = true
                        end
                        if info.linkedSpellIDs then
                            for _, lsid in ipairs(info.linkedSpellIDs) do
                                if lsid and lsid > 0 then
                                    classSpellSet[lsid] = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Process each bar
    for _, barData in ipairs(p.cdmBars.bars) do
        local sd = ns.GetBarSpellData(barData.key)
        if not sd then
            -- no spell data for this bar/spec yet, skip
        elseif MAIN_BAR_KEYS[barData.key] and TALENT_AWARE_BAR_TYPES[barData.key] then
            if sd.assignedSpells and #sd.assignedSpells > 0 then
                sd.assignedSpells, sd.dormantSpells =
                    ReconcileSpellList(sd.assignedSpells, sd.dormantSpells, sd.removedSpells, nil)
            end
        elseif TALENT_AWARE_BAR_TYPES[barData.barType] then
            if sd.assignedSpells and #sd.assignedSpells > 0 then
                sd.assignedSpells, sd.dormantSpells =
                    ReconcileSpellList(sd.assignedSpells, sd.dormantSpells, nil, classSpellSet)
            end
        end
    end

    if ns.RebuildSpellRouteMap then ns.RebuildSpellRouteMap() end
    BuildAllCDMBars()
end

function ns.RequestTalentReconcile(reason)
    if reason ~= "retry" then
        RECONCILE.retries = 0
        RECONCILE.retryToken = RECONCILE.retryToken + 1
    end
    if ns.IsReconcileReady() then
        RECONCILE.pending = false
        RECONCILE.retries = 0
        TalentAwareReconcile()
        return
    end
    RECONCILE.pending = true
    if RECONCILE.retries >= RECONCILE.retryMax then return end
    RECONCILE.retries = RECONCILE.retries + 1
    RECONCILE.retryToken = RECONCILE.retryToken + 1
    local token = RECONCILE.retryToken
    C_Timer.After(RECONCILE.retryDelay, function()
        if token ~= RECONCILE.retryToken then return end
        if not RECONCILE.pending then return end
        ns.RequestTalentReconcile("retry")
    end)
end

-- (ReconcileMainBarSpells / ForceResnapshotMainBars / StartResnapshotRetry
-- removed -- CollectAndReanchor auto-snapshots and hooks handle everything)

-------------------------------------------------------------------------------
--  One-time per-spec validation
--  Checks that the specProfile's assignedSpells belong to the current spec
--  using Blizzard CDM (GetCooldownViewerCategorySet with false) as ground
--  truth. Runs once per spec per character via a ticker, then sets a flag
--  so it never runs again for that spec. Called from CDMFinishSetup (login)
--  and after spec swaps / zone-ins.
-------------------------------------------------------------------------------
do
    local _validateTicker
    local _validateAttempts = 0
    local _validateGeneration = 0

    local function TryValidateSpec(gen)
        -- Stale ticker from a previous StartSpecValidation call
        if gen ~= _validateGeneration then
            if _validateTicker then _validateTicker:Cancel(); _validateTicker = nil end
            return
        end
        _validateAttempts = _validateAttempts + 1
        if _validateAttempts > 30 then
            if _validateTicker then _validateTicker:Cancel(); _validateTicker = nil end
            return
        end
        if not (ns.IsReconcileReady and ns.IsReconcileReady()) then return end
        if _validateTicker then _validateTicker:Cancel(); _validateTicker = nil end

        local specKey = ns.GetActiveSpecKey()
        if not specKey or specKey == "0" then return end

        -- Check if this spec was already validated for this character
        local charKey = ns.GetCharKey()
        if not EllesmereUIDB.cdmSpecValidated then EllesmereUIDB.cdmSpecValidated = {} end
        if not EllesmereUIDB.cdmSpecValidated[charKey] then EllesmereUIDB.cdmSpecValidated[charKey] = {} end
        if EllesmereUIDB.cdmSpecValidated[charKey][specKey] then
            return
        end

        local pp = ECME.db and ECME.db.profile
        if not pp or not pp.cdmBars then return end

        -- Build the full spell set for the current spec from Blizzard CDM
        -- (false = current spec only, includes displayed + not displayed)
        local specSpells = {}
        for cat = 0, 3 do
            local ids = C_CooldownViewer.GetCooldownViewerCategorySet(cat, false)
            if ids then
                for _, cdID in ipairs(ids) do
                    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                    if info then
                        if info.spellID and info.spellID > 0 then
                            specSpells[info.spellID] = true
                        end
                        if info.overrideSpellID and info.overrideSpellID > 0 then
                            specSpells[info.overrideSpellID] = true
                        end
                        if info.linkedSpellIDs then
                            for _, lsid in ipairs(info.linkedSpellIDs) do
                                if lsid and lsid > 0 then
                                    specSpells[lsid] = true
                                end
                            end
                        end
                    end
                end
            end
        end

        local mapSize = 0
        for _ in pairs(specSpells) do mapSize = mapSize + 1 end
        if mapSize == 0 then return end

        -- Check each main bar's assignedSpells against the spec set.
        -- Track which specific bars have corrupted spells.
        local corruptedBars = {}
        local corruptBar = nil
        local corruptSpell = nil
        for _, barData in ipairs(pp.cdmBars.bars) do
            if MAIN_BAR_KEYS[barData.key] then
                local sd = ns.GetBarSpellData(barData.key)
                if sd and sd.assignedSpells then
                for _, sid in ipairs(sd.assignedSpells) do
                    if sid and sid > 0 then
                        if not specSpells[sid] then
                            corruptedBars[barData.key] = true
                            if not corruptBar then
                                corruptBar = barData.key
                                corruptSpell = sid
                            end
                        end
                    end
                end
                end
            end
        end

        if corruptBar then
            -- Only wipe bars that actually contain corrupted spells.
            -- Custom bar assignedSpells are user-curated and must never be
            -- destroyed by main-bar corruption recovery.
            local specProfiles = SpellStore.GetSpecProfiles()
            local prof = specProfiles[specKey]
            if prof and prof.barSpells then
                for bk, _ in pairs(corruptedBars) do
                    local sd = prof.barSpells[bk]
                    if sd then
                        sd.assignedSpells = nil
                        -- Keep removedSpells -- those are user intent
                    end
                end
            end

            local function DoCorruptionRecovery()
                BuildAllCDMBars()
                if ns.QueueReanchor then ns.QueueReanchor() end
                C_Timer.After(3, function()
                    local sk = ns.GetActiveSpecKey()
                    if sk and sk ~= "0" then
                        SaveCurrentSpecProfile()
                        EllesmereUIDB.cdmSpecValidated[charKey][sk] = true
                    end
                end)
            end

            if InCombatLockdown() then
                local combatFrame = CreateFrame("Frame")
                combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
                combatFrame:SetScript("OnEvent", function(self)
                    self:UnregisterAllEvents()
                    DoCorruptionRecovery()
                end)
            else
                DoCorruptionRecovery()
            end
        else
            EllesmereUIDB.cdmSpecValidated[charKey][specKey] = true
        end
    end

    function ns.StartSpecValidation()
        -- Disabled: the old corruption recovery was wiping bars when spells
        -- were cross-assigned between CD/utility viewers. The unified
        -- assignedSpells system no longer needs this validation.
        return
        --[[ Original code preserved for reference:
        if _validateTicker then _validateTicker:Cancel(); _validateTicker = nil end
        _validateAttempts = 0
        _validateGeneration = _validateGeneration + 1
        local gen = _validateGeneration
        C_Timer.After(5, function()
            if gen ~= _validateGeneration then return end
            _validateTicker = C_Timer.NewTicker(0.5, function() TryValidateSpec(gen) end)
        end)
        --]]
    end
end

function ECME:CDMFinishSetup()
    -- This is the one-time construction hub for a normal login/reload enable:
    -- preload unlock helpers, build the initial bar set, spin up the periodic
    -- tick frame, then schedule any deferred reconciliation/rebuild passes
    -- needed once Blizzard's viewer children and layout have settled.
    -- Load the full unlock mode body early so anchor/propagation functions
    -- (ApplyAnchorPosition, PropagateWidthMatch, etc.) are available for
    -- the initial build pass. CDM SavedVariables are ready by this point.
    EllesmereUI:EnsureLoaded()

    -- Pre-size CDM bar frames using cached icon counts from last session.
    -- Purely cosmetic: gives anchored elements correct dimensions to compute
    -- against before the real spell data populates. BuildAllCDMBars below
    -- overwrites everything with real data.
    do
        local p = ECME.db and ECME.db.profile
        if p and p.cdmBars and p.cdmBars.enabled and EllesmereUIDB then
            local charKey = ns.GetCharKey()
            local specKey = ns.GetActiveSpecKey()
            local cache = EllesmereUIDB.cdmCachedBarSizes
            local counts = cache and cache[charKey] and cache[charKey][specKey]
            if counts then
                for i, barData in ipairs(p.cdmBars.bars) do
                    if barData.enabled then
                        local cachedCount = counts[barData.key]
                        if cachedCount and cachedCount > 0 then
                            local key = barData.key
                            local frame = cdmBarFrames[key]
                            if not frame then
                                frame = CreateFrame("Frame", "ECME_CDMBar_" .. key, UIParent)
                                frame:SetFrameStrata("LOW")
                                frame:SetFrameLevel(5)
                                if frame.EnableMouseClicks then frame:EnableMouseClicks(false) end
                                if frame.EnableMouseMotion then frame:EnableMouseMotion(true) end
                                frame._barKey = key
                                frame._barIndex = i
                                cdmBarFrames[key] = frame
                                cdmBarIcons[key] = {}
                            end
                            local iconW = SnapForScale(barData.iconSize or 36, 1)
                            local iconH = iconW
                            if (barData.iconShape or "none") == "cropped" then
                                iconH = SnapForScale(math.floor((barData.iconSize or 36) * 0.80 + 0.5), 1)
                            end
                            local spacing = SnapForScale(barData.spacing or 2, 1)
                            local grow = barData.growDirection or "CENTER"
                            local numRows = barData.numRows or 1
                            if numRows < 1 then numRows = 1 end
                            local stride = ComputeTopRowStride(barData, cachedCount)
                            local isHoriz = (grow == "RIGHT" or grow == "LEFT" or grow == "CENTER")
                            local totalW, totalH
                            if isHoriz then
                                totalW = stride * iconW + (stride - 1) * spacing
                                totalH = numRows * iconH + (numRows - 1) * spacing
                            else
                                totalW = numRows * iconW + (numRows - 1) * spacing
                                totalH = stride * iconH + (stride - 1) * spacing
                            end
                            frame:SetSize(SnapForScale(totalW, 1), SnapForScale(totalH, 1))
                            frame._prevLayoutW = SnapForScale(totalW, 1)
                            frame._prevLayoutH = SnapForScale(totalH, 1)
                            local pos = p.cdmBarPositions and p.cdmBarPositions[key]
                            if pos and pos.point then
                                frame:ClearAllPoints()
                                frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
                            end
                            frame:Show()
                        end
                    end
                end
            end
        end
    end

    BuildAllCDMBars()

    -- Initialize Tracking Bars
    do
        local pp = ECME.db.profile
        local tbb = pp.trackedBuffBars
        local hasNoBars = (not tbb) or (not tbb.bars) or (#tbb.bars == 0)
        if hasNoBars then
            pp.trackedBuffBars = { selectedBar = 1, bars = {} }
            pp.tbbPositions = nil
        end
    end
    if ns.BuildTrackedBuffBars then ns.BuildTrackedBuffBars() end

    -- Build initial spell route map and hook Blizzard CDM viewer pools
    if ns.RebuildSpellRouteMap then ns.RebuildSpellRouteMap() end
    ns.SetupViewerHooks()

    -- Save per-spec data after initial setup
    C_Timer.After(1, function()
        local specKey = ns.GetActiveSpecKey()
        if specKey and specKey ~= "0" then
            SaveCurrentSpecProfile()
        end
    end)

    -- One-time per-spec validation: check that the specProfile's
    -- assignedSpells belong to the current spec using Blizzard CDM as
    -- ground truth. Runs once per spec per character, then marks the
    -- spec as validated so it never runs again. This cleans up
    -- corrupted specProfiles from before the per-character activeSpecKey
    -- fix. Exposed on ns so it can be triggered after spec swaps too.
    ns.StartSpecValidation()

    -- Deferred keybind update: wait 3s so Blizzard's hotkey update cycle
    -- has fully run before we read HotKey text from button frames
    C_Timer.After(3, UpdateCDMKeybinds)

    -- CDM update tick frame
    if not self._cdmTickFrame then
        self._cdmTickFrame = CreateFrame("Frame")
        self._cdmTickFrame:SetScript("OnUpdate", function(_, dt)
            UpdateAllCDMBars(dt)
        end)
    end
    self._cdmTickFrame:Show()

    -- Register with unlock mode
    RegisterCDMUnlockElements()
    if ns.RegisterTBBUnlockElements then ns.RegisterTBBUnlockElements() end

    -- Deferred re-build: the initial BuildAllCDMBars may have run before
    -- Blizzard CDM populated icons (0 visible -> 1x1 frames). By the next
    -- frame, icon visibility has settled and a rebuild produces correct sizes
    -- and anchor positions.
    C_Timer.After(0, function()
        -- Ensure the full unlock mode body is loaded so propagation
        -- functions (PropagateWidthMatch, PropagateAnchorChain, etc.)
        -- are available. CDM data is ready by this point.
        EllesmereUI:EnsureLoaded()
        BuildAllCDMBars()
        -- Defer one frame so WoW flushes layout after the final bar sizes,
        -- then re-propagate width/height matches and anchor positions.
        C_Timer.After(0, function()
            if EllesmereUI.ApplyAllWidthHeightMatches then
                EllesmereUI.ApplyAllWidthHeightMatches()
            end
            if EllesmereUI._applySavedPositions then
                EllesmereUI._applySavedPositions()
            end
        end)
    end)
end

-------------------------------------------------------------------------------
--  Rotation Helper Integration (Blizzard C_AssistedCombat)
--  Highlights the currently suggested spell from the rotation assistant
--  with a glow on its CDM icon.
-------------------------------------------------------------------------------
ns._rotationGlowedIcons = {}
ns._lastSuggestedSpell = nil
ns._rotationHookInstalled = false

local function UpdateRotationHighlights()
    local p = ECME.db and ECME.db.profile
    if not p or not p.cdmBars or not p.cdmBars.rotationHelperEnabled then
        for icon in pairs(ns._rotationGlowedIcons) do
            if icon._glowOverlay then
                _G_Glows.StopAllGlows(icon._glowOverlay)
                icon._glowOverlay:SetAlpha(0)
            end
            ns._rotationGlowedIcons[icon] = nil
        end
        ns._lastSuggestedSpell = nil
        return
    end

    local suggestedSpell = C_AssistedCombat and C_AssistedCombat.GetNextCastSpell and C_AssistedCombat.GetNextCastSpell()

    if suggestedSpell == ns._lastSuggestedSpell then return end
    ns._lastSuggestedSpell = suggestedSpell

    for icon in pairs(ns._rotationGlowedIcons) do
        if icon._glowOverlay then
            _G_Glows.StopAllGlows(icon._glowOverlay)
            icon._glowOverlay:SetAlpha(0)
        end
    end
    wipe(ns._rotationGlowedIcons)

    if not suggestedSpell then return end

    local glowStyle = p.cdmBars.rotationHelperGlowStyle or 5
    for barKey, icons in pairs(cdmBarIcons) do
        for _, icon in ipairs(icons) do
            if icon._spellID and icon._spellID == suggestedSpell and icon:IsShown() then
                if icon._glowOverlay then
                    icon._glowOverlay:SetAlpha(1)
                    StartNativeGlow(icon._glowOverlay, glowStyle, 1, 0.82, 0.1)
                    ns._rotationGlowedIcons[icon] = true
                end
            end
        end
    end
end
ns.UpdateRotationHighlights = UpdateRotationHighlights

local function InstallRotationHook()
    if ns._rotationHookInstalled then return end
    ns._rotationHookInstalled = true

    if EventRegistry and EventRegistry.RegisterCallback then
        EventRegistry:RegisterCallback("AssistedCombatManager.OnAssistedHighlightSpellChange", function()
            UpdateRotationHighlights()
        end, "ECME_CDM_RotationHelper")
    end

    -- Also hook the manager's update method as a fallback
    if AssistedCombatManager and AssistedCombatManager.UpdateAllAssistedHighlightFramesForSpell then
        hooksecurefunc(AssistedCombatManager, "UpdateAllAssistedHighlightFramesForSpell", function()
            UpdateRotationHighlights()
        end)
    end
end

-------------------------------------------------------------------------------
--  Event-Driven Runtime Maintenance
--
--  This frame owns the non-tick triggers: login/world transitions, spec swaps,
--  talent changes, roster updates, binding changes, proc-glow signals, and
--  combat/visibility state. Most heavy work is deferred into rebuild helpers
--  rather than performed inline in the event callback.
-------------------------------------------------------------------------------
-- Event frame
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterUnitEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterUnitEvent("UNIT_AURA", "player")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
eventFrame:RegisterEvent("UPDATE_BINDINGS")
eventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
-- Hero talent / loadout change events
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
eventFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
-- Cinematic/cutscene end: Blizzard restores hidden frames, so re-hide ours
eventFrame:RegisterEvent("CINEMATIC_STOP")
eventFrame:RegisterEvent("STOP_MOVIE")
-- Visibility option events: mounted, target, instance zone changes
eventFrame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")

-- Debounce token for talent-change rebuilds: rapid talent clicks collapse
-- into a single deferred rebuild rather than firing once per click.
local _talentRebuildToken = 0

local function ScheduleTalentRebuild()
    _talentRebuildToken = _talentRebuildToken + 1
    local token = _talentRebuildToken
    C_Timer.After(0.5, function()
        if token ~= _talentRebuildToken then return end  -- superseded
        -- Skip if a spec switch just happened -- SwitchSpecProfile already
        -- handles the full save/load/rebuild cycle.  TalentAwareReconcile
        -- running during the transition would see stale spell data and
        -- incorrectly move the new spec's spells to dormant.
        if (GetTime() - _lastSpecSwitchTime) < 3 then return end
        -- Wipe per-spell caches that may reference stale override IDs or
        -- stale charge data from spells that changed with the talent swap.
        -- Also wipe the persisted DB entries so CacheMultiChargeSpell
        -- re-detects from live API rather than reading a stale false entry.
        -- Skip during combat: actual talent changes are combat-locked, so these
        -- events only fire mid-combat from hero talent procs (e.g. Celestial
        -- Infusion). Wiping here would clear charge data for all spells with no
        -- way to re-detect it until the next out-of-combat cache rebuild.
        if not InCombatLockdown() then
            wipe(_multiChargeSpells)
            wipe(_maxChargeCount)
            local db = ECME.db
            if db and db.sv and db.sv.multiChargeSpells then
                wipe(db.sv.multiChargeSpells)
            end
        end
        -- Reconcile bar spellIDs against the new talent set.
        -- Unavailable spells are moved to dormant slots (preserving position);
        -- returning spells are re-inserted at their saved slot index.
        ns.RequestTalentReconcile("talent")
        -- Clear cached viewer child info so the next tick re-reads from API
        -- (overrideSpellID may have changed with the new talent set)
        for _, vname in ipairs(_cdmViewerNames) do
            local vf = _G[vname]
            if vf and vf:GetNumChildren() > 0 then
                local children = { vf:GetChildren() }
                for ci = 1, #children do
                    local ch = children[ci]
                    if ch then
                        local chfc = _ecmeFC[ch]
                        if chfc then
                            chfc.resolvedSid = nil
                            chfc.baseSpellID = nil
                            chfc.overrideSid = nil
                            chfc.cachedCdID = nil
                            chfc.isChargeSpell = nil
                            chfc.maxCharges = nil
                        end
                    end
                end
            end
        end
        -- Rebuild keybind cache (talent swap may change action slot contents)
        UpdateCDMKeybinds()
    end)
end

local function ScheduleRosterRebuild()
    if EllesmereUI and EllesmereUI.InvalidateFrameCache then
        EllesmereUI.InvalidateFrameCache()
    end
    C_Timer.After(0.2, function()
        BuildAllCDMBars()
    end)
end

eventFrame:SetScript("OnEvent", function(_, event, unit, updateInfo, arg3)
    if not ECME.db then return end
    if event == "PLAYER_LOGOUT" then
        ns.SaveCachedBarSizes()
        return
    end
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        return
    end
    if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" or event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        OnProcGlowEvent(event, unit)  -- unit = spellID (first arg after event)
        return
    end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- Track health item usage for combat lockout (healthstone stays visible
        -- but grayed out until combat ends when used in combat)
        local castSpellID = arg3  -- 3rd payload arg = spellID
        if castSpellID then
            local hi = HEALTH_ITEM_BY_SPELL[castSpellID]
            if hi and hi.combatLockout and InCombatLockdown() then
                _healthCombatLockout[castSpellID] = true
            end
            -- Duration-based tracking: start a timer for buff bar preset spells
            -- that have a user-configured duration (e.g. potions with no aura)
            local p = ECME.db and ECME.db.profile
            if p and p.cdmBars and p.cdmBars.bars then
                for _, barData in ipairs(p.cdmBars.bars) do
                    local isBuffBar = (barData.key == "buffs" or barData.barType == "buffs")
                    if barData.enabled and isBuffBar then
                        local sd = ns.GetBarSpellData(barData.key)
                        if sd and sd.customSpellDurations then
                            local durations = sd.customSpellDurations
                            local primaryID = castSpellID
                            local groups = sd.customSpellGroups
                            if groups and groups[castSpellID] then
                                primaryID = groups[castSpellID]
                            end
                            local dur = durations[primaryID]
                            if dur and dur > 0 then
                                if not _customBarTimers[barData.key] then
                                    _customBarTimers[barData.key] = {}
                                end
                                _customBarTimers[barData.key][primaryID] = GetTime() + dur
                            end
                        end
                    end
                end
            end
        end
        return
    end
    if event == "UPDATE_BINDINGS" or event == "ACTIONBAR_SLOT_CHANGED" then
        C_Timer.After(0.5, UpdateCDMKeybinds)  -- defer so action slots are fully populated
        return
    end
    if event == "TRAIT_CONFIG_UPDATED" or event == "PLAYER_TALENT_UPDATE" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
        -- Hero talent or loadout change ΓÇö debounced rebuild
        ScheduleTalentRebuild()
        return
    end
    if event == "GROUP_ROSTER_UPDATE" then
        ScheduleRosterRebuild()
        _CDMApplyVisibility()
        return
    end
    if event == "CINEMATIC_STOP" or event == "STOP_MOVIE" then
        -- Blizzard restores frame positions/alpha after cinematics end.
        -- Re-hide immediately so the Blizzard CDM doesn't reappear.
        local p = ECME.db and ECME.db.profile
        if p and p.cdmBars and p.cdmBars.hideBlizzard then
            C_Timer.After(0, function()
                HideBlizzardCDM()
                --[[ DISABLED: useBlizzardBuffBars feature temporarily removed
                if p.cdmBars.useBlizzardBuffBars then
                    RestoreBlizzardBuffFrame()
                end
                --]]
            end)
        end
        return
    end
    if event == "PLAYER_MOUNT_DISPLAY_CHANGED" or event == "PLAYER_TARGET_CHANGED" or event == "UPDATE_SHAPESHIFT_FORM" then
        _CDMApplyVisibility()
        if event == "UPDATE_SHAPESHIFT_FORM" then
            C_Timer.After(0.5, UpdateCDMKeybinds)
        end
        return
    end
    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" or event == "ZONE_CHANGED_NEW_AREA" then
        _inCombat = (event == "PLAYER_REGEN_DISABLED")
        _CDMApplyVisibility()
        -- Flush deferred TBB rebuild that was queued during combat
        if event == "PLAYER_REGEN_ENABLED" and ns.IsTBBRebuildPending and ns.IsTBBRebuildPending() then
            if ns.BuildTrackedBuffBars then ns.BuildTrackedBuffBars() end
        end
        -- Flush deferred keybind rebuild that was blocked during combat
        if event == "PLAYER_REGEN_ENABLED" and _keybindRebuildPending then
            UpdateCDMKeybinds()
        end
        -- Clear health item combat lockout when leaving combat
        if event == "PLAYER_REGEN_ENABLED" then
            wipe(_healthCombatLockout)
        end
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        _inCombat = InCombatLockdown and InCombatLockdown() or false
        -- Wipe hook-captured cooldown caches so stale state from a previous
        -- character doesn't persist after alt switch or reload.
        wipe(_ecmeChildHasDurObj)
        wipe(_ecmeDurObjCache)
        wipe(_ecmeRawStartCache)
        wipe(_ecmeRawDurCache)
        RECONCILE.lastZoneInAt = GetTime()
        -- Validate spec on every zone-in (catches auto spec swaps, login, etc.)
        C_Timer.After(0.5, function()
            ValidateSpec()
            -- If spec was already correct, just rebuild bars
            if not _specValidated then return end
            local newSpecKey = GetCurrentSpecKey()
            local p = ECME.db and ECME.db.profile
            if p and newSpecKey == ns.GetActiveSpecKey() then
                BuildAllCDMBars()
                if ns.QueueReanchor then ns.QueueReanchor() end
                if RECONCILE.pending then
                    C_Timer.After(0.5, function()
                        if RECONCILE.pending then
                            ns.RequestTalentReconcile("PEW")
                        end
                    end)
                end
            end
        end)
        -- Trigger per-spec validation on zone-in (catches LFG auto spec swaps)
        if ns.StartSpecValidation then
            ns.StartSpecValidation()
        end
        -- Install rotation helper hook after CDM frames have been built
        C_Timer.After(1, function()
            InstallRotationHook()
        end)
    end
    if event == "SPELLS_CHANGED" then
        -- SPELLS_CHANGED fires reliably after spec data is available.
        -- Use it as a safety net to catch spec mismatches that OnEnable missed.
        local scheduleReconcile = RECONCILE.pending
        if not _specValidated then
            ValidateSpec()
            -- If ValidateSpec just fixed the spec, rebuild bars now.
            -- (PLAYER_ENTERING_WORLD may have bailed early because spec wasn't ready.)
            if _specValidated then
                C_Timer.After(0.3, function()
                    BuildAllCDMBars()
                    if ns.QueueReanchor then ns.QueueReanchor() end
                    if scheduleReconcile and RECONCILE.pending then
                        C_Timer.After(0.5, function()
                            if RECONCILE.pending then
                                ns.RequestTalentReconcile("SPELLS_CHANGED")
                            end
                        end)
                    end
                end)
                scheduleReconcile = false
            end
        end
        if scheduleReconcile and RECONCILE.pending then
            C_Timer.After(0.2, function()
                if RECONCILE.pending then
                    ns.RequestTalentReconcile("SPELLS_CHANGED")
                end
            end)
        end
        return
    end
    if event == "PLAYER_SPECIALIZATION_CHANGED" and unit == "player" then
        if EllesmereUI and EllesmereUI.InvalidateFrameCache then
            EllesmereUI.InvalidateFrameCache()
        end
        RECONCILE.lastSpecChangeAt = GetTime()
        local newSpecKey = GetCurrentSpecKey()
        local curSpecKey = ns.GetActiveSpecKey()
        if newSpecKey ~= "0" and newSpecKey ~= curSpecKey then
            SwitchSpecProfile(newSpecKey)
            _specValidated = true
            if RECONCILE.pending then
                C_Timer.After(0.6, function()
                    if RECONCILE.pending then
                        ns.RequestTalentReconcile("spec")
                    end
                end)
            end
        elseif newSpecKey ~= "0" then
            SetActiveSpec()
            _specValidated = true
            C_Timer.After(0.5, function()
                BuildAllCDMBars()
                -- Re-apply width/height matches after bars settle
                C_Timer.After(0.3, function()
                    if EllesmereUI.ApplyAllWidthHeightMatches then
                        EllesmereUI.ApplyAllWidthHeightMatches()
                    end
                end)
            end)
        end
        -- Trigger per-spec validation for the new spec (one-time, ticker-based)
        if ns.StartSpecValidation then
            ns.StartSpecValidation()
        end
    end
    if event == "UNIT_AURA" then return end
    if ns.ApplyPerSlotHidingAndPackSoon then ns.ApplyPerSlotHidingAndPackSoon() end
    RequestUpdate()
end)

-------------------------------------------------------------------------------
--  Slash commands
-------------------------------------------------------------------------------
SLASH_ECME1 = "/ecme"
SLASH_ECME2 = "/cdmeffects"
SLASH_ECME3 = "/cdm"
SlashCmdList.ECME = function(msg)
    if InCombatLockdown and InCombatLockdown() then return end
    if EllesmereUI and EllesmereUI.ShowModule then
        EllesmereUI:ShowModule("EllesmereUICooldownManager")
    end
end

