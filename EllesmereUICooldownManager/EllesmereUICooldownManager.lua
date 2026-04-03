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
    return math.floor(x + 0.5)
end

local floor = math.floor
local GetTime = GetTime

ns.DEFAULT_MAPPING_NAME = "Buff Name (eg: Divine Purpose)"
ns.CDM_DIVIDER_ID = -1  -- Sentinel value for visual space dividers in CDM bars

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

-- Side-effect caches are now maintained by EllesmereUICdmHooks.lua
-- (rebuilt once per reanchor, not per tick). These locals are populated
-- after the hooks file loads, in CDMFinishSetup.
local _tickBlizzActiveCache   = {}
local _tickBlizzAllChildCache = {}
local _tickBlizzBuffChildCache = {}
local _tickBarViewerCache     = {}
local _tickCDUtilTrackedSet   = {}
local _tickBuffIconTrackedSet = {}

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

-- Access decoration data stored externally by EllesmereUICdmHooks.lua
-- Populated at runtime (hooks file loads after this file)
local function _getFD(f) return ns._hookFrameData and ns._hookFrameData[f] end



-- cooldownID -> corrected spellID (used by SpellPicker for local matching)
local _cdIDToCorrectSID = {}
ns._cdIDToCorrectSID = _cdIDToCorrectSID

-- Racial ability data
local RACE_RACIALS = {
    Scourge            = { 7744 },
    Tauren             = { 20549 },
    Orc                = { 20572, 33697, 33702 },
    BloodElf           = { 202719, 50613, 25046, 69179, 80483, 155145, 129597, 232633, 28730 },
    Dwarf              = { 20594 },
    Troll              = { 26297 },
    Draenei            = { 28880, 59543, 59545, 121093, 59544, 370626, 59547, 59548, 59542, 416250 },
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


-- Custom Aura Bar presets (potions with hardcoded durations).
-- Detection: SPELL_UPDATE_COOLDOWN (spell goes on CD = just used).
-- Display: reverse cooldown swipe for the duration.
-- Bloodlust/Time Spiral/warlock pets removed — they can't be tracked
-- via cooldown detection (they're cast by OTHER players or have no CD).
local BUFF_BAR_PRESETS = {
    {
        key      = "lights_potential",
        name     = "Light's Potential",
        icon     = 7548911,
        spellIDs = { 1236616 },
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
    {
        key      = "healthstone",
        name     = "Healthstone",
        icon     = 538745,
        itemID   = 5512,
        spellID  = 6262,
        altItemIDs = { 224464 },
    },
    {
        key      = "demonic_healthstone",
        name     = "Demonic Healthstone",
        itemID   = 224464,
        spellID  = 452930,
        altItemIDs = { 5512 },
    },
}
ns.CDM_ITEM_PRESETS = CDM_ITEM_PRESETS


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
            hideBuffsWhenInactive = true,
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
                    verticalOrientation = false, barBgEnabled = false,                    barBgR = 0, barBgG = 0, barBgB = 0,
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
                    verticalOrientation = false, barBgEnabled = false,                    barBgR = 0, barBgG = 0, barBgB = 0,
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
                    verticalOrientation = false, barBgEnabled = false,                    barBgR = 0, barBgG = 0, barBgB = 0,
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

-- Ghost buff bar: a hidden routing sink for buff spells the user removes.
-- Icons routed here get alpha 0 via the _visHidden mechanism.
local GHOST_BUFF_BAR_KEY = "__ghost_buffs"
MAIN_BAR_KEYS[GHOST_BUFF_BAR_KEY] = true

-- Ghost CD bar: same concept for CD/utility spells. When the user "removes"
-- a spell from a CD or utility bar, it routes here instead of being deleted.
-- This means every spell in Blizzard's viewer pool always has a route,
-- eliminating the need for allowSet filtering during collection.
local GHOST_CD_BAR_KEY = "__ghost_cd"
MAIN_BAR_KEYS[GHOST_CD_BAR_KEY] = true

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

    -- Bar Glows and Tracked Buff Bars are stored directly in
    -- specProfiles[specKey] (not in profile). No copying needed --
    -- GetBarGlows() and GetTrackedBuffBars() read/write there directly.

    -- Snapshot visible icon counts for pre-sizing on next login
    ns.SaveCachedBarSizes()
end

--- Restore non-spell per-spec data for a spec.
--- Spell data is read directly from the global store by all consumers.
local function LoadSpecProfile(specKey)
    local p = ECME.db.profile
    local specProfiles = SpellStore.GetSpecProfiles()
    local prof = specProfiles[specKey]

    -- Bar Glows and Tracked Buff Bars are stored directly in
    -- specProfiles[specKey]. GetBarGlows() and GetTrackedBuffBars()
    -- read/write there directly. No copying needed on spec switch.
    -- (If no spec profile exists yet, these functions auto-initialize.)
end

-- Timestamp of the last spec switch. Used to suppress TalentAwareReconcile
-- during the transition window where spell data may be stale.
local _lastSpecSwitchTime = 0

-- Version token: incremented on each spec swap. All deferred timers check
-- this so a newer spec swap cancels stale callbacks from an older one.
local _specSwapVersion = 0

--- Full spec switch: save non-spell data, update active spec, rebuild everything.
--- Spell data is already in the global store keyed by spec -- switching the
--- active spec key is all that's needed for spells to "switch".
local function SwitchSpecProfile(newSpecKey)
    _lastSpecSwitchTime = GetTime()
    _specSwapVersion = _specSwapVersion + 1
    local myVersion = _specSwapVersion

    -- Block reanchors so stale data doesn't cause flicker.
    -- QueueReanchor still queues (never drops), but
    -- ProcessReanchorQueue holds until this flag clears.
    ns._specChangePending = true

    -- Hide TBB bars immediately so stale spell data doesn't flash
    ns._tbbSpecSwapPending = true
    if ns.HideAllTBB then ns.HideAllTBB() end

    local p = ECME.db.profile
    local oldSpecKey = ns.GetActiveSpecKey()

    -- Save old spec, switch to new spec, load new spec
    if oldSpecKey and oldSpecKey ~= "0" then
        SaveCurrentSpecProfile()
    end
    ns.SetActiveSpecKey(newSpecKey)
    EnsureSpec(p, newSpecKey)
    LoadSpecProfile(newSpecKey)

    -- Deferred spec swap: rebuild data, unblock, queue.
    -- The normal reanchor handles everything else -- no special clearing.
    C_Timer.After(0.5, function()
        if _specSwapVersion ~= myVersion then return end  -- superseded
        if EllesmereUI then EllesmereUI._specProfileSwitching = false end

        -- 1. Rebuild data for the new spec
        if ns.MarkCDMSpellCacheDirty then ns.MarkCDMSpellCacheDirty() end
        if ns.InvalidateTBBFrameCache then ns.InvalidateTBBFrameCache() end

        -- If the new spec has no assignedSpells (first time on this spec),
        -- snapshot from Blizzard's active viewer frames to populate bars.
        local needsSnapshot = false
        for _, bk in ipairs({"cooldowns", "utility"}) do
            local sd = ns.GetBarSpellData(bk)
            if not sd or not sd.assignedSpells or #sd.assignedSpells == 0 then
                needsSnapshot = true; break
            end
        end
        if needsSnapshot then
            local gci = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
            local viewerToBar = {
                EssentialCooldownViewer = "cooldowns",
                UtilityCooldownViewer   = "utility",
            }
            for vName, bk in pairs(viewerToBar) do
                local vf = _G[vName]
                local sd = ns.GetBarSpellData(bk)
                if vf and sd then
                    if not sd.assignedSpells then sd.assignedSpells = {} end
                    if #sd.assignedSpells == 0 then
                        local seen = {}
                        if vf.itemFramePool and vf.itemFramePool.EnumerateActive then
                            for frame in vf.itemFramePool:EnumerateActive() do
                                local cdID = frame.cooldownID
                                if cdID and gci then
                                    local info = gci(cdID)
                                    if info then
                                        local sid = ResolveInfoSpellID(info)
                                        if sid and sid > 0 and not seen[sid] then
                                            seen[sid] = true
                                            sd.assignedSpells[#sd.assignedSpells + 1] = sid
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        if ns.RebuildSpellRouteMap then ns.RebuildSpellRouteMap() end

        -- 2. Clear FC caches so ResolveFrameSpellID re-reads from API
        for _, vname in ipairs(_cdmViewerNames) do
            local vf = _G[vname]
            if vf and vf.GetNumChildren and vf:GetNumChildren() > 0 then
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
                            chfc.sortOrder = nil
                        end
                    end
                end
            end
        end

        -- 3. Clear preset frames so injection recreates fresh
        if ns._presetFrames then
            for _, f in pairs(ns._presetFrames) do
                f:Hide(); f:ClearAllPoints()
            end
            wipe(ns._presetFrames)
        end

        -- 4. Unblock reanchors, then queue
        ns._specChangePending = false
        if ns.QueueReanchor then ns.QueueReanchor() end

        -- Stage 2: catch late-populating frames
        C_Timer.After(0.3, function()
            if _specSwapVersion ~= myVersion then return end
            if ns.MarkCDMSpellCacheDirty then ns.MarkCDMSpellCacheDirty() end
            if ns.QueueReanchor then ns.QueueReanchor() end
        end)

        -- Stage 3: population failsafe
        C_Timer.After(1.0, function()
            if _specSwapVersion ~= myVersion then return end
            if ns.MarkCDMSpellCacheDirty then ns.MarkCDMSpellCacheDirty() end
            if ns.QueueReanchor then ns.QueueReanchor() end
        end)

        -- TBB
        C_Timer.After(0, function()
            if _specSwapVersion ~= myVersion then return end
            ns._tbbSpecSwapPending = false
            if ns.BuildTrackedBuffBars then ns.BuildTrackedBuffBars() end
        end)

        -- Post-swap work (lightweight, no frame creation)
        if _CDMApplyVisibility then _CDMApplyVisibility()
        elseif ns.CDMApplyVisibility then ns.CDMApplyVisibility() end
        RegisterCDMUnlockElements()
        if ns.RegisterTBBUnlockElements then ns.RegisterTBBUnlockElements() end
        if ns.UpdateCDMKeybinds then ns.UpdateCDMKeybinds() end
        if ns.RequestBarGlowUpdate then ns.RequestBarGlowUpdate() end
        if EllesmereUI.ResyncAnchorOffsets then EllesmereUI.ResyncAnchorOffsets() end
        if EllesmereUI.ApplyAllWidthHeightMatches then EllesmereUI.ApplyAllWidthHeightMatches() end
        if EllesmereUI and EllesmereUI._mainFrame and EllesmereUI._mainFrame:IsShown() then
            if EllesmereUI.InvalidateContentHeaderCache then EllesmereUI:InvalidateContentHeaderCache() end
            if EllesmereUI.RefreshPage then EllesmereUI:RefreshPage(true) end
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
    -- buttons are unavailable, e.g. when another addon hides ActionButton1-12)
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
    if pW < 5 then pW = 36 end
    if pH < 5 then pH = 36 end
    cr = cr or 1; cg = cg or 1; cb = cb or 1

    if entry.shapeGlow then
        -- CDM-specific: read shape mask/border from the icon frame
        local icon = parent
        local shape = icon._shapeApplied and icon._shapeName or nil
        local maskPath   = shape and CDM_SHAPES.masks[shape]
        local borderPath = shape and CDM_SHAPES.borders[shape]
        _G_Glows.StartShapeGlow(overlay, math.min(pW, pH), cr, cg, cb, 1.20, {
            maskPath   = maskPath,
            borderPath = borderPath,
            shapeMask  = icon._shapeMask,
        })
    elseif entry.procedural then
        local N = opts and opts.N or 8
        local th = opts and opts.th or 2
        local period = opts and opts.period or 4
        local lineLen = math.floor((pW + pH) * (2 / N - 0.1))
        lineLen = math.min(lineLen, math.min(pW, pH))
        if lineLen < 1 then lineLen = 1 end
        _G_Glows.StartProceduralAnts(overlay, N, th, period, lineLen, cr, cg, cb, pW, pH)
    elseif entry.buttonGlow then
        _G_Glows.StartButtonGlow(overlay, pW, cr, cg, cb, nil, pH)
    elseif entry.autocast then
        _G_Glows.StartAutoCastShine(overlay, pW, cr, cg, cb, 1.0, pH)
    else
        _G_Glows.StartFlipBookGlow(overlay, pW, entry, cr, cg, cb, pH)
    end

    overlay._glowActive = true
    overlay:SetAlpha(1)
    -- No Show()/Hide() — overlay is always shown (created in DecorateFrame).
    -- Toggling visibility on a child of a Blizzard viewer frame triggers
    -- Layout hooks and causes position cascades.
end

StopNativeGlow = function(overlay)
    if not overlay then return end
    _G_Glows.StopAllGlows(overlay)
    overlay._glowActive = false
    overlay:SetAlpha(0)
    -- No Hide() — just alpha 0. Same reason as above.
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
    ns.FullCDMRebuild("profile_import")
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
    -- Fast path: reparented frame with barKey set by hook system (external cache) or CDM frame
    local fc = _ecmeFC[frame]
    if (fc and fc.barKey) or frame._barKey then return (fc and fc.barKey) or frame._barKey, frame end
    local current = frame
    while current do
        local parent = current:GetParent()
        if not parent then return nil end
        -- Check if parent is one of our CDM bar containers (external cache or direct)
        local pfc = _ecmeFC[parent]
        if (pfc and pfc.barKey) or parent._barKey then return (pfc and pfc.barKey) or parent._barKey, current end
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
        local bc = (_ecmeFC[icon] and _ecmeFC[icon].blizzChild) or icon._blizzChild
        if icon == blizzChild or bc == blizzChild then return icon end
    end
    -- Fallback: match by spellID (covers override spells like HST -> Storm Stream)
    local alertSid = ResolveBlizzChildSpellID(blizzChild)
    if alertSid then
        for _, icon in ipairs(icons) do
            local ifc = _ecmeFC[icon]
            if (ifc and ifc.spellID or icon._spellID) == alertSid then return icon end
        end
        -- Check override mapping (base spell <-> override)
        for _, icon in ipairs(icons) do
            local ifc = _ecmeFC[icon]
            local iconSid = ifc and ifc.spellID or icon._spellID
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

-- Show proc glow on one of our icons. Uses per-spell settings if available.
local function ShowProcGlow(icon, cr, cg, cb)
    if not icon then return end
    local fd = _getFD(icon)
    local glow = fd and fd.glowOverlay or icon._glowOverlay
    if not glow then return end
    if fd and fd.procGlowActive then return end

    -- Per-spell proc glow settings
    local style = PROC_GLOW_STYLE
    local fc = _ecmeFC[icon]
    local sid = fc and fc.spellID
    if sid then
        local bk = fc and fc.barKey
        local sd = bk and ns.GetBarSpellData(bk)
        local ss = sd and sd.spellSettings and sd.spellSettings[sid]
        if ss then
            if ss.procGlow == 0 then return end -- proc glow disabled
            if ss.procGlow and ss.procGlow > 0 then style = ss.procGlow end
            if ss.procGlowClassColor then
                local _, ct = UnitClass("player")
                if ct then
                    local cc = RAID_CLASS_COLORS[ct]
                    if cc then cr, cg, cb = cc.r, cc.g, cc.b end
                end
            elseif ss.procGlowR then
                cr, cg, cb = ss.procGlowR, ss.procGlowG or 0.788, ss.procGlowB or 0.137
            end
        end
    end

    -- Stop active glow if running (proc takes priority)
    if glow._glowActive then StopNativeGlow(glow) end
    StartNativeGlow(glow, style, cr, cg, cb)
    if fd then fd.procGlowActive = true end
end

local function StopProcGlow(icon)
    local fd = icon and _getFD(icon)
    if not icon or not (fd and fd.procGlowActive) then return end
    local glow = fd and fd.glowOverlay or icon._glowOverlay
    StopNativeGlow(glow)
    if fd then fd.procGlowActive = false end
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

        -- Apply immediately: find our icon and show the proc glow.
        -- No defer needed -- icon mapping is current from the last reanchor.
        local ourIcon = FindOurIconForBlizzChild(barKey, cdmChild)
        if not ourIcon then return end
        local cr, cg, cb = PROC_GLOW_COLOR[1], PROC_GLOW_COLOR[2], PROC_GLOW_COLOR[3]
        ShowProcGlow(ourIcon, cr, cg, cb)
        -- Force icon texture re-evaluation so override textures apply immediately
        local ofc = _ecmeFC[ourIcon]; if ofc then ofc.lastTex = nil end
        ourIcon._lastTex = nil
    end)

    hooksecurefunc(ActionButtonSpellAlertManager, "HideAlert", function(_, frame)
        if not frame then return end
        local barKey, cdmChild = GetBarKeyForBlizzChild(frame)
        if not barKey or not cdmChild then return end
        local ourIcon = FindOurIconForBlizzChild(barKey, cdmChild)
        local fd = ourIcon and _getFD(ourIcon)
        if not ourIcon or not (fd and fd.procGlowActive) then return end

        -- Trust Blizzard's HideAlert: stop our glow immediately.
        -- If Blizzard re-fires ShowAlert during an internal refresh,
        -- the glow restarts naturally on the next frame.
        StopProcGlow(ourIcon)
        -- Force icon texture re-evaluation so the original texture restores immediately
        local ofc = _ecmeFC[ourIcon]; if ofc then ofc.lastTex = nil end
        ourIcon._lastTex = nil
    end)

    _procGlowHooksInstalled = true
end

-- Scan all Blizzard CDM children for already-active proc alerts and apply
-- our proc glow. Called after hooks install and after the 2s reset so we
-- pick up procs that were active before our hooks were in place.
local function ScanExistingProcGlows()
    -- No-op: proc glows are now fully hook-driven. ShowAlert hooks installed
    -- at file load time catch Blizzard's login re-fire. This function kept
    -- as a callable no-op so existing call sites don't error.
end
ns.ScanExistingProcGlows = ScanExistingProcGlows

-- (OnProcGlowEvent removed -- all bars use hook-based proc glows via
-- InstallProcGlowHooks / ActionButtonSpellAlertManager now)
local function OnProcGlowEvent() end
ns.OnProcGlowEvent = OnProcGlowEvent

-- Install proc glow hooks at file-load time (earliest possible).
-- Blizzard re-fires ShowAlert during PLAYER_LOGIN for active procs.
-- Hooks must be in place before that to catch them.
InstallProcGlowHooks()


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
local _CDMApplyVisibility

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
--  Force Blizzard EditMode CooldownViewer settings
--  Ensures viewers are set to "Always Visible" so Blizzard's hideWhenInactive
--  and visibility modes don't interfere with CDM's frame management.
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--  EnforceCooldownViewerEditModeSettings (one-shot)
--  Runs ONCE on initialization to set desired Edit Mode settings:
--    - VisibleSetting = Always on ALL viewers
--    - HideWhenInactive = 1 on buff viewers (BuffIcon + BuffBar)
--  SaveLayouts is called at most once, during init. Never at runtime.
--  This prevents tainting Blizzard frame properties (isActive, etc.)
--  which happens when SaveLayouts triggers a layout reapply from addon code.
-------------------------------------------------------------------------------
local _editModePolicyApplied = false
local function EnforceCooldownViewerEditModeSettings()
    if _editModePolicyApplied then return end
    if not (C_EditMode and C_EditMode.GetLayouts and C_EditMode.SaveLayouts
            and Enum and Enum.EditModeSystem and Enum.EditModeSystem.CooldownViewer
            and Enum.EditModeCooldownViewerSetting and Enum.CooldownViewerVisibleSetting
            and Enum.EditModeCooldownViewerSystemIndices) then
        return
    end

    local layoutInfo = C_EditMode.GetLayouts()
    if type(layoutInfo) ~= "table" or type(layoutInfo.layouts) ~= "table" then return end

    -- Merge preset layouts so activeLayout index resolves correctly
    if EditModePresetLayoutManager and EditModePresetLayoutManager.GetCopyOfPresetLayouts then
        local presets = EditModePresetLayoutManager:GetCopyOfPresetLayouts()
        if type(presets) == "table" then
            tAppendAll(presets, layoutInfo.layouts)
            layoutInfo.layouts = presets
        end
    end

    local activeLayout = type(layoutInfo.activeLayout) == "number"
        and layoutInfo.layouts[layoutInfo.activeLayout]
    if not activeLayout or type(activeLayout.systems) ~= "table" then return end

    local changed = false
    local cooldownSystem = Enum.EditModeSystem.CooldownViewer
    local visSetting  = Enum.EditModeCooldownViewerSetting.VisibleSetting
    local visAlways   = Enum.CooldownViewerVisibleSetting.Always
    local hideEnum    = Enum.EditModeCooldownViewerSetting.HideWhenInactive
    local buffIconIdx = Enum.EditModeCooldownViewerSystemIndices.BuffIcon
    local buffBarIdx  = Enum.EditModeCooldownViewerSystemIndices.BuffBar

    local function UpsertSetting(settings, settingEnum, desiredValue)
        for _, s in ipairs(settings) do
            if s.setting == settingEnum then
                if s.value ~= desiredValue then
                    s.value = desiredValue
                    return true
                end
                return false
            end
        end
        settings[#settings + 1] = { setting = settingEnum, value = desiredValue }
        return true
    end

    for _, sysInfo in ipairs(activeLayout.systems) do
        if sysInfo.system == cooldownSystem and type(sysInfo.settings) == "table" then
            -- VisibleSetting=Always on ALL viewers
            if UpsertSetting(sysInfo.settings, visSetting, visAlways) then
                changed = true
            end
            -- HideWhenInactive=1 on buff viewers only
            if sysInfo.systemIndex == buffIconIdx or sysInfo.systemIndex == buffBarIdx then
                if UpsertSetting(sysInfo.settings, hideEnum, 1) then
                    changed = true
                end
            end
        end
    end

    _editModePolicyApplied = true
    if not changed then return end

    -- Save the corrected layout. Blizzard won't visually apply this until
    -- the next login/reload, so we force a reload via popup.
    C_EditMode.SaveLayouts(layoutInfo)

    -- Show a forced (non-dismissable) reload popup
    C_Timer.After(0, function()
        if not EllesmereUI or not EllesmereUI.ShowConfirmPopup then
            ReloadUI()
            return
        end
        EllesmereUI:ShowConfirmPopup({
            title = "Edit Mode Update",
            message = "EllesmereUI has updated your Cooldown Manager Edit Mode settings to ensure cooldown tracking works correctly.\n\nA UI reload is required for the changes to take effect.",
            confirmText = "Reload UI",
            onConfirm = function() ReloadUI() end,
        })
        -- Force: no cancel, no escape, no click-outside dismiss
        local popup = _G["EUIConfirmPopup"]
        if popup then
            -- Hide cancel button
            if popup._cancelBtn then popup._cancelBtn:Hide() end
            -- Center the confirm button
            if popup._confirmBtn then
                popup._confirmBtn:ClearAllPoints()
                popup._confirmBtn:SetPoint("BOTTOM", popup, "BOTTOM", 0, 13)
            end
            -- Block escape key
            popup:SetScript("OnKeyDown", function(self, key)
                self:SetPropagateKeyboardInput(key ~= "ESCAPE")
            end)
            -- Block click-outside dismiss
            if popup._dimmer then
                popup._dimmer:SetScript("OnMouseDown", nil)
            end
        end
    end)
end

-------------------------------------------------------------------------------
--  Hide / Restore Blizzard CDM
-------------------------------------------------------------------------------
HideBlizzardCDM = function()
    -- Anchor each viewer to our corresponding bar container.
    -- Frames stay parented to viewers (no reparenting = no taint).
    -- The viewer becomes an invisible shell overlapping our container;
    -- CollectAndReanchor re-anchors individual icons within it.
    -- Viewer alpha stays at 1 so child frames inherit visibility.
    local viewerToBar = {
        [BLIZZ_CDM_FRAMES.cooldowns] = "cooldowns",
        [BLIZZ_CDM_FRAMES.utility]   = "utility",
        [BLIZZ_CDM_FRAMES.buffs]     = "buffs",
    }
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
            -- Don't reposition primary viewers (Essential/Utility/BuffIcon) —
            -- individual icon anchoring handles positioning.
            -- BuffBarCooldownViewer is secondary: hide it via alpha since
            -- TBB renders its own bars and we don't hook its Cooldown widgets.
            local isSecondary = (frameName == BLIZZ_CDM_FRAMES_SECONDARY.buffs)
            if isSecondary then
                frame:SetAlpha(0)
                frame:ClearAllPoints()
                frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10000, 10000)
            end
            pcall(frame.EnableMouse, frame, false)
            if frame.EnableMouseMotion then pcall(frame.EnableMouseMotion, frame, false) end
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
            -- Restore original anchor points
            if fc.origPoints then
                frame:ClearAllPoints()
                for _, pt in ipairs(fc.origPoints) do
                    frame:SetPoint(pt[1], pt[2], pt[3], pt[4], pt[5])
                end
            end
            -- Restore mouse interaction
            frame:EnableMouse(true)
            if frame.EnableMouseMotion then frame:EnableMouseMotion(true) end
            fc.hidden = false
            fc.restoring = nil
        end
    end
end

-- Restore Blizzard's BuffBarCooldownViewer (the bar-style buff tracking strip)
-- so it reappears when TBB is disabled via "Use Blizzard CDM Bars".
-- Only touches the secondary bar viewer; CDM icon bars are never affected.
local function RestoreBlizzardBuffFrame()
    local frameName = BLIZZ_CDM_FRAMES_SECONDARY.buffs
    if not frameName then return end
    local frame = _G[frameName]
    local fc = frame and _ecmeFC[frame]
    if fc and fc.hidden then
        fc.restoring = true
        if fc.origPoints then
            frame:ClearAllPoints()
            for _, pt in ipairs(fc.origPoints) do
                frame:SetPoint(pt[1], pt[2], pt[3], pt[4], pt[5])
            end
        end
        frame:SetAlpha(1)
        frame:EnableMouse(true)
        if frame.EnableMouseMotion then frame:EnableMouseMotion(true) end
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
    -- Skip conversion for dynamic bars (buffs/custom_buff) whose icon count
    -- varies at runtime -- using frame:GetWidth() would produce a different
    -- offset every time the count changes, causing the bar to jump.
    if pos.point == "CENTER" and (pos.relPoint == "CENTER" or not pos.relPoint) then
        local bd = barKey and barDataByKey[barKey]
        local isDynamic = bd and (bd.barType == "buffs" or barKey == "buffs" or bd.barType == "custom_buff")
        if not isDynamic then
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
        end
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
    -- Dynamic bars (buffs/custom_buff) always save as CENTER -- their icon
    -- count varies at runtime, so edge-based anchors would drift.
    local bd = barDataByKey[barKey]
    local isDynamic = bd and (bd.barType == "buffs" or barKey == "buffs" or bd.barType == "custom_buff")
    local grow = bd and bd.growDirection or "CENTER"
    local pt
    if isDynamic then
        pt = "CENTER"
    elseif grow == "RIGHT" then pt = "LEFT"
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
                -- Reset icon strata while panel is open
                local icons = cdmBarIcons[key]
                if icons then
                    for ii = 1, #icons do
                        if icons[ii] and icons[ii]:GetFrameStrata() == "TOOLTIP" then
                            icons[ii]:SetFrameStrata("LOW")
                            icons[ii]:SetFrameLevel(5 + ii)
                        end
                    end
                end
                return
            elseif frame._mouseHiddenByPanel then
                -- Panel just closed: restore visibility and icon strata
                frame._mouseHiddenByPanel = false
                local icons = cdmBarIcons[key]
                if icons then
                    for ii = 1, #icons do
                        if icons[ii] then
                            icons[ii]:SetFrameStrata("TOOLTIP")
                            icons[ii]:SetFrameLevel(9980 + ii)
                        end
                    end
                end
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
        -- Counts dividers (CDM_DIVIDER_ID = -1) too: they occupy one visual slot.
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
-- Build a table mapping icon index → accumulated fractional step offset from
-- preceding dividers.  dividerWidth (0.0–1.0) is stored in barData and controls
-- how wide each divider is as a fraction of one (iconSize + spacing) step.
-- Returns: offsets table, integer divider count, total fractional step width.
local function BuildDividerOffsets(barKey)
    local sd = ns.GetBarSpellData(barKey)
    local spells = sd and sd.assignedSpells
    if not spells then return {}, 0, 0 end
    local barData = barDataByKey[barKey]
    local divW = (barData and barData.dividerWidth) or 0.5
    local offsets, iconIdx, divCount, accumFrac = {}, 0, 0, 0
    for _, sid in ipairs(spells) do
        if sid == ns.CDM_DIVIDER_ID then
            divCount  = divCount  + 1
            accumFrac = accumFrac + divW
        elseif sid and sid ~= 0 then
            iconIdx = iconIdx + 1
            offsets[iconIdx] = accumFrac  -- fractional step offset before this icon
        end
    end
    return offsets, divCount, accumFrac
end

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
    local grow = frame._mouseGrow or barData.growDirection or "CENTER"
    local numRows = barData.numRows or 1
    if numRows < 1 then numRows = 1 end
    -- Use match-adjusted fractional spacing if stride still matches
    -- and the bar still has an active width match. Otherwise revert
    -- to the user's configured integer spacing.
    local isHoriz = (grow == "RIGHT" or grow == "LEFT" or grow == "CENTER")
    local spacing
    local hasWidthMatch = EllesmereUI.GetWidthMatchTarget
        and EllesmereUI.GetWidthMatchTarget("CDM_" .. barKey) ~= nil
    if hasWidthMatch and barData._matchSpacing and barData._matchStride then
        local curDim = isHoriz and ComputeTopRowStride(barData, #icons) or numRows
        if curDim == barData._matchStride then
            spacing = barData._matchSpacing
        else
            barData._matchSpacing = nil
            barData._matchStride = nil
            spacing = SnapForScale(barData.spacing or 2, 1)
        end
    else
        barData._matchSpacing = nil
        barData._matchStride = nil
        spacing = SnapForScale(barData.spacing or 2, 1)
    end

    -- Use ALL icons in the array (not just IsShown). CollectAndReanchor
    -- already filtered to only include frames we claimed. Blizzard may
    -- toggle IsShown independently -- we position everything we own.
    local visibleIcons = icons
    local count = #visibleIcons
    -- For non-dynamic bars (cd/utility), use assignedSpells count as minimum
    -- size so the bar never shrinks during transitional states.
    -- Skip trinket slots whose trinket isn't on-use (they don't render).
    local isDynamic = (barData.barType == "buffs" or barKey == "buffs" or barData.barType == "custom_buff")
    local sizeCount = count
    if not isDynamic then
        local sd = ns.GetBarSpellData(barKey)
        if sd and sd.assignedSpells then
            local visibleAssigned = 0
            for _, sid in ipairs(sd.assignedSpells) do
                if sid == -13 or sid == -14 then
                    local slot = -sid
                    local tf = ns._trinketFrames and ns._trinketFrames[slot]
                    local hasItem = GetInventoryItemID("player", slot) ~= nil
                    if hasItem and tf and tf._trinketIsOnUse then visibleAssigned = visibleAssigned + 1 end
                elseif sid == ns.CDM_DIVIDER_ID then
                    visibleAssigned = visibleAssigned + 1  -- dividers occupy one visual slot
                elseif sid and sid ~= 0 then
                    visibleAssigned = visibleAssigned + 1
                end
            end
            sizeCount = math.max(count, visibleAssigned)
        end
    end
    if count == 0 then
        local curW = frame:GetWidth() or 0
        local curH = frame:GetHeight() or 0
        if curW <= 1 or curH <= 1 then
            local fallbackW, fallbackH = GetStableCDMBarSize(barKey, nil, barData)
            frame:SetSize(fallbackW, fallbackH)
            frame._prevLayoutW = fallbackW
            frame._prevLayoutH = fallbackH
        end
        -- Never permanently hide containers on transient count=0. Spec
        -- swaps and viewer pool churn can produce brief 0-count states.
        -- The next reanchor refills the bar. Hiding the container would
        -- require an explicit re-show that nothing guarantees.
        if frame._barBg then frame._barBg:Hide() end
        return
    end

    -- Bar has visible icons -- ensure it is visible (unless visibility is "never")
    local stride, _, customTopCount = ComputeTopRowStride(barData, sizeCount)
    local dividerOffsets, totalDividers, totalFrac = BuildDividerOffsets(barKey)
    -- visualStride corrects integer stride for fractional divider widths:
    -- each integer-counted divider slot is replaced by its actual fraction.
    local visualStride = stride - totalDividers + totalFrac

    -- Container size (already snapped values)
    local totalW, totalH
    if isHoriz then
        totalW = visualStride * iconW + math.max(0, visualStride - 1) * spacing
        totalH = numRows * iconH + (numRows - 1) * spacing
    else
        totalW = numRows * iconW + (numRows - 1) * spacing
        totalH = visualStride * iconH + math.max(0, visualStride - 1) * spacing
    end

    -- Just resize the container. Never re-anchor, save position, or
    -- propagate here. Bar position is set by BuildCDMBar / unlock mode.
    -- LayoutCDMBar's job is ONLY: resize container + position icons inside.
    frame:SetSize(SnapForScale(totalW, 1), SnapForScale(totalH, 1))

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

    -- Elevate icon strata for cursor-anchored bars (icons aren't parented
    -- to the container, so they don't inherit its TOOLTIP strata).
    local isMouseBar = barData.anchorTo == "mouse"

    -- Position each icon: fill bottom-up so bottom rows are full,
    -- top row gets the remainder. Center any row with fewer icons than stride.
    for i, icon in ipairs(visibleIcons) do
        -- Compensate for Blizzard's per-icon scale so visual size matches.
        -- Both SetSize and SetPoint offsets are in the frame's scaled space,
        -- so divide everything by the scale factor.
        local iconScale = icon:GetScale() or 1
        if iconScale < 0.01 then iconScale = 1 end
        local iS = 1 / iconScale
        icon:SetSize(iconW * iS, iconH * iS)
        local scaledStepW = stepW * iS
        local scaledStepH = stepH * iS
        if isMouseBar then
            icon:SetFrameStrata("TOOLTIP")
            icon:SetFrameLevel(9980 + i)
        elseif icon:GetFrameStrata() == "TOOLTIP" then
            icon:SetFrameStrata("LOW")
            icon:SetFrameLevel(5 + i)
        end
        icon:ClearAllPoints()

        -- Map sequential index to bottom-up grid position.
        -- Icon 1..topRowCount fill the top row (visual row 0).
        -- Remaining icons fill rows 1..numRows-1 (bottom rows).
        -- dividerOffsets[i] shifts each icon right by the number of dividers before it.
        local col, row
        if i <= topRowCount then
            col = (i - 1) + (dividerOffsets[i] or 0)
            row = 0
        else
            local bottomIdx = (i - topRowCount - 1) + (dividerOffsets[i] or 0)
            col = bottomIdx % stride
            row = 1 + math.floor(bottomIdx / stride)
        end

        -- Center any row that has fewer icons than stride
        local rowCount = RowIconCount(row)
        local rowHasLess = (rowCount > 0 and rowCount < stride)

        local snap = SnapForScale
        if grow == "RIGHT" then
            local rowOffset = 0
            if rowHasLess then
                rowOffset = snap((stride - rowCount) * scaledStepW / 2, 1)
            end
            icon:SetPoint("TOPLEFT", frame, "TOPLEFT",
                snap(col * scaledStepW + rowOffset, 1),
                snap(-(row * scaledStepH), 1))
        elseif grow == "LEFT" then
            local rowOffset = 0
            if rowHasLess then
                rowOffset = snap((stride - rowCount) * scaledStepW / 2, 1)
            end
            icon:SetPoint("TOPRIGHT", frame, "TOPRIGHT",
                snap(-(col * scaledStepW + rowOffset), 1),
                snap(-(row * scaledStepH), 1))
        elseif grow == "DOWN" then
            local rowOffset = 0
            if rowHasLess then
                rowOffset = snap((stride - rowCount) * scaledStepH / 2, 1)
            end
            icon:SetPoint("TOPLEFT", frame, "TOPLEFT",
                snap(row * scaledStepW, 1),
                snap(-(col * scaledStepH + rowOffset), 1))
        elseif grow == "UP" then
            local rowOffset = 0
            if rowHasLess then
                rowOffset = snap((stride - rowCount) * scaledStepH / 2, 1)
            end
            icon:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT",
                snap(row * scaledStepW, 1),
                snap(col * scaledStepH + rowOffset, 1))
        elseif grow == "CENTER" then
            local rowOffset = 0
            if rowHasLess then
                rowOffset = snap((stride - rowCount) * scaledStepW / 2, 1)
            end
            icon:SetPoint("TOPLEFT", frame, "CENTER",
                snap(col * scaledStepW + rowOffset - (totalW / 2) * iS, 1),
                snap(-(row * scaledStepH) + (totalH / 2) * iS, 1))
        end

        -- Store the anchor we just set so the SetPoint hook can force
        -- Blizzard back to this position if it tries to move the icon.
        local fd = _getFD(icon)
        if fd then
            local pt, _, rp, ox, oy = icon:GetPoint(1)
            if pt then
                fd._cdmAnchor = { pt, frame, rp, ox, oy }
            end
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
    -- Just toggle Blizzard's CDM settings panel.
    -- Do NOT call SetCurrentCategories/SetDisplayMode/ClearDisplayCategories
    -- after opening -- those taint the CDM frame pool.
    if not CooldownViewerSettings then return end
    if EllesmereUI._mainFrame and EllesmereUI._mainFrame:IsShown() then
        EllesmereUI._mainFrame:Hide()
    end
    if CooldownViewerSettings:IsShown() then
        CooldownViewerSettings:Hide()
    else
        CooldownViewerSettings:Show()
    end
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
    local fd = _getFD(ourIcon)
    local utOv = fd and fd.untrackedOverlay or ourIcon._untrackedOverlay
    if isUntracked then
        if not utOv then
            local tex = fd and fd.tex or ourIcon._tex
            local ov = CreateFrame("Button", nil, ourIcon)
            ov:RegisterForClicks("LeftButtonUp", "RightButtonDown", "MiddleButtonDown")
            ov:SetAllPoints(tex or ourIcon)
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
            label:SetText("Click to\nTrack")
            label:SetTextColor(1, 1, 1, 0.9)
            label:SetJustifyH("CENTER")
            ov._label = label
            ov:SetScript("OnClick", function(self, button)
                -- Left click: open Blizzard CDM to track the spell
                -- Right/Middle click: pass through to parent slot for remove/picker
                if button == "RightButton" or button == "MiddleButton" then
                    local parent = self:GetParent()
                    if parent and parent.GetScript and parent:GetScript("OnClick") then
                        parent:GetScript("OnClick")(parent, button)
                    end
                    return
                end
                local parent = self:GetParent()
                local pfc = parent and _ecmeFC[parent]
                local bk = (pfc and pfc.barKey) or (parent and parent._barKey)
                local barType = bk
                if barDataByKey and barDataByKey[bk] then
                    barType = barDataByKey[bk].barType or bk
                end
                local isBuff = (barType == "buffs")
                OpenBlizzardCDMTab(isBuff)
            end)
            ov:SetScript("OnEnter", function(self)
                local parent = self:GetParent()
                local pfc = parent and _ecmeFC[parent]
                local bk = (pfc and pfc.barKey) or (parent and parent._barKey)
                local barType = bk
                if barDataByKey and barDataByKey[bk] then
                    barType = barDataByKey[bk].barType or bk
                end
                local isBuff = (barType == "buffs")
                local tabName = isBuff and "Buffs" or "Spells"
                -- Include spell name in tooltip
                local spellName = ""
                local sid = pfc and pfc.spellID or (parent and parent._spellID)
                if sid and sid > 0 then
                    spellName = C_Spell.GetSpellName(sid) or ""
                end
                if spellName ~= "" then spellName = "|cff0cd29d" .. spellName .. "|r " end
                ShowUntrackedTooltip(self,
                    spellName .. "not tracked in Blizzard CDM.\nClick to open the |cff0cd29d" .. tabName .. "|r tab.")
            end)
            ov:SetScript("OnLeave", function() HideUntrackedTooltip() end)
            if fd then fd.untrackedOverlay = ov else ourIcon._untrackedOverlay = ov end
            utOv = ov
        end
        utOv:EnableMouse(true)
        utOv:Show()
        ourIcon._isUntracked = true
    elseif utOv then
        utOv:Hide()
        ourIcon._isUntracked = false
    end
end
ns.ApplyUntrackedOverlay = ApplyUntrackedOverlay


-------------------------------------------------------------------------------
--  CDM Tooltip System
--  Single global OnUpdate handler instead of per-icon. Checks which icon
--  (if any) the mouse is over, only when at least one bar has tooltips on.
-------------------------------------------------------------------------------
local _tooltipBars = {}  -- [barKey] = true for bars with tooltips enabled
local _tooltipFrame = CreateFrame("Frame")
_tooltipFrame:Hide()
local _tooltipCurrentIcon = nil

_tooltipFrame:SetScript("OnUpdate", function()
    if EllesmereUI and EllesmereUI._unlockActive then
        if _tooltipCurrentIcon then
            GameTooltip:Hide()
            _tooltipCurrentIcon = nil
        end
        return
    end
    -- Find the icon under the mouse
    local found = nil
    for barKey in pairs(_tooltipBars) do
        local icons = cdmBarIcons[barKey]
        if icons then
            for i = 1, #icons do
                local icon = icons[i]
                if icon and icon:IsShown() and icon:IsMouseOver() then
                    found = icon
                    break
                end
            end
            if found then break end
        end
    end
    if found and found ~= _tooltipCurrentIcon then
        local sfc = _ecmeFC[found]
        local sid = sfc and sfc.spellID or found._spellID
        if sid and sid > 0 then
            GameTooltip:SetOwner(found, "ANCHOR_CURSOR")
            GameTooltip:SetSpellByID(sid)
            GameTooltip:Show()
            _tooltipCurrentIcon = found
        end
    elseif not found and _tooltipCurrentIcon then
        GameTooltip:Hide()
        _tooltipCurrentIcon = nil
    end
end)

local function ApplyCDMTooltipState(barKey)
    local bd = barDataByKey[barKey]
    local enabled = bd and bd.showTooltip
    if enabled then
        _tooltipBars[barKey] = true
    else
        _tooltipBars[barKey] = nil
        -- Clear tooltip if it's showing for an icon on this bar
        if _tooltipCurrentIcon then
            local sfc = _ecmeFC[_tooltipCurrentIcon]
            if sfc and sfc.barKey == barKey then
                GameTooltip:Hide()
                _tooltipCurrentIcon = nil
            end
        end
    end
    -- Show/hide the global tooltip frame based on whether any bar wants tooltips
    if next(_tooltipBars) then
        _tooltipFrame:Show()
    else
        _tooltipFrame:Hide()
    end
end
ns.ApplyCDMTooltipState = ApplyCDMTooltipState

-------------------------------------------------------------------------------
--  Apply custom shape to a CDM icon
-------------------------------------------------------------------------------
ApplyShapeToCDMIcon = function(icon, shape, barData)
    if not icon then return end
    local fd = _getFD(icon)
    local tex = fd and fd.tex or icon._tex
    local cd = fd and fd.cooldown or icon._cooldown
    local bg = fd and fd.bg or icon._bg
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
            if tex then pcall(tex.RemoveMaskTexture, tex, mask) end
            if bg then pcall(bg.RemoveMaskTexture, bg, mask) end
            if cd then pcall(cd.RemoveMaskTexture, cd, mask) end
            mask:SetTexture(nil); mask:ClearAllPoints(); mask:SetSize(0.001, 0.001); mask:Hide()
        end
        if icon._shapeBorder then icon._shapeBorder:Hide() end
        icon._shapeApplied = nil
        icon._shapeName = nil

        -- Restore square borders (pixel-perfect via PP)
        -- Border lives on fd.borderFrame (child of icon) to avoid tainting
        -- Blizzard's secure frames. Fall back to icon._ppBorders for
        -- CDM-owned frames that don't go through DecorateFrame's child wrapper.
        local bdrTarget = (fd and fd.borderFrame) or icon
        if fd and fd.borderFrame or icon._ppBorders then
            EllesmereUI.PP.ShowBorder(bdrTarget)
            EllesmereUI.PP.UpdateBorder(bdrTarget, borderSz, brdR, brdG, brdB, brdA)
        end

        -- Restore icon texture coords
        if tex then
            tex:ClearAllPoints()
            EllesmereUI.PP.Point(tex, "TOPLEFT", icon, "TOPLEFT", borderSz, -borderSz)
            EllesmereUI.PP.Point(tex, "BOTTOMRIGHT", icon, "BOTTOMRIGHT", -borderSz, borderSz)
            if shape == "cropped" then
                tex:SetTexCoord(zoom, 1 - zoom, zoom + 0.10, 1 - zoom - 0.10)
            else
                tex:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
            end
        end

        -- Restore cooldown (full frame so swipe covers the entire icon)
        if cd then
            cd:ClearAllPoints()
            cd:SetAllPoints(icon)
            pcall(cd.SetSwipeTexture, cd, "Interface\\Buttons\\WHITE8x8")
            if cd.SetUseCircularEdge then pcall(cd.SetUseCircularEdge, cd, false) end
        end

        -- Restore background
        if bg then
            bg:ClearAllPoints(); bg:SetAllPoints()
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
    if tex then pcall(tex.RemoveMaskTexture, tex, mask) end
    if bg then pcall(bg.RemoveMaskTexture, bg, mask) end
    if cd then pcall(cd.RemoveMaskTexture, cd, mask) end

    -- Apply mask to icon texture and background
    if tex then tex:AddMaskTexture(mask) end
    if bg then bg:AddMaskTexture(mask) end

    -- Expand icon beyond frame for shape
    local shapeOffset = CDM_SHAPES.iconExpandOffsets[shape] or 0
    local shapeDefault = CDM_SHAPES.zoomDefaults[shape] or 0.06
    local iconExp = CDM_SHAPES.iconExpand + shapeOffset + ((zoom - shapeDefault) * 200)
    if iconExp < 0 then iconExp = 0 end
    local halfIE = iconExp / 2
    if tex then
        tex:ClearAllPoints()
        EllesmereUI.PP.Point(tex, "TOPLEFT", icon, "TOPLEFT", -halfIE, halfIE)
        EllesmereUI.PP.Point(tex, "BOTTOMRIGHT", icon, "BOTTOMRIGHT", halfIE, -halfIE)
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
    if tex then tex:SetTexCoord(-expand, 1 + expand, -expand, 1 + expand) end

    -- Hide square borders (pixel-perfect via PP)
    local bdrTarget2 = (fd and fd.borderFrame) or icon
    if fd and fd.borderFrame or icon._ppBorders then
        EllesmereUI.PP.HideBorder(bdrTarget2)
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
    if cd then
        cd:ClearAllPoints()
        cd:SetAllPoints(icon)
        pcall(cd.AddMaskTexture, cd, mask)
        if cd.SetSwipeTexture then
            pcall(cd.SetSwipeTexture, cd, maskTex)
        end
        local useCircular = (shape ~= "square" and shape ~= "csquare")
        if cd.SetUseCircularEdge then pcall(cd.SetUseCircularEdge, cd, useCircular) end
        local edgeScale = CDM_SHAPES.edgeScales[shape] or 0.60
        if cd.SetEdgeScale then pcall(cd.SetEdgeScale, cd, edgeScale) end
    end

    -- Restore background to full icon
    if bg then
        bg:ClearAllPoints(); bg:SetAllPoints()
    end

    icon._shapeApplied = true
    icon._shapeName = shape
end
ns.ApplyShapeToCDMIcon = ApplyShapeToCDMIcon

-- (UpdateCustomBarIcons removed -- all bars now use hook-based CollectAndReanchor)

-- (UpdateCDMBarIcons removed -- replaced by hook-based CollectAndReanchor)
-- (UpdateAllCDMBars tick loop removed -- replaced by event-driven hooks)

-- Refresh visual properties of existing icons (called when settings change)
local function RefreshCDMIconAppearance(barKey)
    local icons = cdmBarIcons[barKey]
    if not icons then return end

    local barData = barDataByKey[barKey]
    if not barData then return end

    local borderSize = barData.borderSize or 1
    local zoom = barData.iconZoom or 0.08

    for _, icon in ipairs(icons) do
        local fd = _getFD(icon)
        local tex = fd and fd.tex or icon._tex
        local cd = fd and fd.cooldown or icon._cooldown
        local bg = fd and fd.bg or icon._bg
        local glowOv = fd and fd.glowOverlay or icon._glowOverlay
        local kbText = fd and fd.keybindText or icon._keybindText
        local txOverlay = fd and fd.textOverlay or icon._textOverlay
        -- Scale compensation: fonts render at the frame's native scale,
        -- so multiply sizes by 1/scale to match the visual icon size.
        local iconScale = icon:GetScale() or 1
        if iconScale < 0.01 then iconScale = 1 end
        local fontScale = 1 / iconScale
        -- Update texture zoom
        if tex then
            tex:ClearAllPoints()
            EllesmereUI.PP.Point(tex, "TOPLEFT", icon, "TOPLEFT", borderSize, -borderSize)
            EllesmereUI.PP.Point(tex, "BOTTOMRIGHT", icon, "BOTTOMRIGHT", -borderSize, borderSize)
            tex:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
        end
        -- Update cooldown (full frame so swipe covers the entire icon)
        if cd then
            cd:ClearAllPoints()
            cd:SetAllPoints(icon)
            cd:SetSwipeColor(0, 0, 0, barData.swipeAlpha or 0.7)
            cd:SetHideCountdownNumbers(not barData.showCooldownText)
            -- Apply cooldown text font directly (old tick loop is gone)
            if barData.showCooldownText then
                local cdFont = GetCDMFont()
                local cdSize = (barData.cooldownFontSize or 12) * fontScale
                local cdR = barData.cooldownTextR or 1
                local cdG = barData.cooldownTextG or 1
                local cdB = barData.cooldownTextB or 1
                -- Find Blizzard's countdown text FontString on the Cooldown widget
                for _, rgn in pairs({ cd:GetRegions() }) do
                    if rgn and rgn.GetObjectType and rgn:GetObjectType() == "FontString" then
                        rgn:SetFont(cdFont, cdSize, "OUTLINE")
                        rgn:SetShadowOffset(0, 0)
                        rgn:SetTextColor(cdR, cdG, cdB)
                    end
                end
            end
        end
        -- Update border (pixel-perfect via PP)
        local bdrTgt = (fd and fd.borderFrame) or icon
        if fd and fd.borderFrame or icon._ppBorders then
            EllesmereUI.PP.UpdateBorder(bdrTgt, borderSize, barData.borderR or 0, barData.borderG or 0, barData.borderB or 0, barData.borderA or 1)
        end
        -- Update background
        if bg then
            bg:SetColorTexture(barData.bgR or 0.08, barData.bgG or 0.08, barData.bgB or 0.08, barData.bgA or 0.6)
        end
        -- Style Blizzard's native stack/charge text elements
        local scFont = GetCDMFont()
        local scSize = (barData.stackCountSize or 11) * fontScale
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
        -- Item count text (potions/healthstones)
        if icon._itemCountText then
            SetBlizzCDMFont(icon._itemCountText, scFont, scSize, scR, scG, scB)
            icon._itemCountText:ClearAllPoints()
            icon._itemCountText:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", scX, scY)
        end

        -- Update keybind text style
        if kbText then
            kbText:SetFont(GetCDMFont(), (barData.keybindSize or 10) * fontScale, "OUTLINE")
            kbText:SetShadowOffset(0, 0)
            kbText:ClearAllPoints()
            kbText:SetPoint("TOPLEFT", txOverlay, "TOPLEFT", barData.keybindOffsetX or 2, barData.keybindOffsetY or -2)
            kbText:SetTextColor(barData.keybindR or 1, barData.keybindG or 1, barData.keybindB or 1, barData.keybindA or 0.9)
        end

        -- Apply custom shape (overrides border/zoom set above)
        local shape = barData.iconShape or "none"
        ApplyShapeToCDMIcon(icon, shape, barData)

        -- Reset glow so glow type change takes effect on next tick.
        -- Do NOT reset isActive -- that causes a 1-frame flash where the
        -- ticker sees the transition as "inactive" and un-desaturates the
        -- icon before re-detecting active on the next frame.
        -- Preserve proc glow and active state glow across rebuilds.
        local ifd = _getFD(icon)
        local hadProcGlow = ifd and ifd.procGlowActive
        local hadActiveGlow = ifd and ifd._activeGlowOn
        if hadProcGlow and glowOv then
            -- Stop then restart with per-spell settings
            StopNativeGlow(glowOv)
            if ifd then ifd.procGlowActive = false end
            ShowProcGlow(icon, PROC_GLOW_COLOR[1], PROC_GLOW_COLOR[2], PROC_GLOW_COLOR[3])
        elseif hadActiveGlow then
            -- Don't touch: active glow is managed by the SetSwipeColor hook.
            -- Stopping it here causes a visible blink.
        elseif glowOv then
            StopNativeGlow(glowOv)
            if ifd then ifd.procGlowActive = false end
        end
    end
end
ns.RefreshCDMIconAppearance = RefreshCDMIconAppearance

-- Ghost bars: ensure both buff and CD ghost bars exist in the bars array.
-- Called from BuildAllCDMBars before iterating bars.
ns.GHOST_BUFF_BAR_KEY = GHOST_BUFF_BAR_KEY
ns.GHOST_CD_BAR_KEY = GHOST_CD_BAR_KEY
local function EnsureGhostBars()
    local p = ECME.db and ECME.db.profile
    if not p or not p.cdmBars or not p.cdmBars.bars then return end
    local hasBuff, hasCD = false, false
    for _, b in ipairs(p.cdmBars.bars) do
        if b.key == GHOST_BUFF_BAR_KEY then hasBuff = true end
        if b.key == GHOST_CD_BAR_KEY then hasCD = true end
    end
    if not hasBuff then
        p.cdmBars.bars[#p.cdmBars.bars + 1] = {
            key = GHOST_BUFF_BAR_KEY,
            name = "Hidden Buffs",
            barType = "buffs",
            isGhostBar = true,
            enabled = true,
            barVisibility = "never",
            iconSize = 1,
            spacing = 0,
            numRows = 1,
            growDirection = "RIGHT",
        }
    end
    if not hasCD then
        p.cdmBars.bars[#p.cdmBars.bars + 1] = {
            key = GHOST_CD_BAR_KEY,
            name = "Hidden CDs",
            barType = "cooldowns",
            isGhostBar = true,
            enabled = true,
            barVisibility = "never",
            iconSize = 1,
            spacing = 0,
            numRows = 1,
            growDirection = "RIGHT",
        }
    end
    -- Migration: move existing removedSpells to the ghost CD bar.
    -- Before the ghost bar existed, removed spells were tracked via a
    -- per-bar removedSpells set and filtered by allowSet. Now they route
    -- to the ghost bar instead.
    -- Iterate ALL spec profiles (not just active spec) so every spec's
    -- removedSpells are migrated on first load after this update.
    local specProfiles = SpellStore.GetSpecProfiles()
    if specProfiles then
        for specKey, prof in pairs(specProfiles) do
            local barSpells = prof and prof.barSpells
            if barSpells then
                local ghostBS = barSpells[GHOST_CD_BAR_KEY]
                if not ghostBS then
                    ghostBS = {}
                    barSpells[GHOST_CD_BAR_KEY] = ghostBS
                end
                if not ghostBS.assignedSpells then ghostBS.assignedSpells = {} end
                for barKey, bs in pairs(barSpells) do
                    if barKey ~= GHOST_CD_BAR_KEY and barKey ~= GHOST_BUFF_BAR_KEY
                       and bs.removedSpells and next(bs.removedSpells) then
                        for sid in pairs(bs.removedSpells) do
                            local found = false
                            for _, existing in ipairs(ghostBS.assignedSpells) do
                                if existing == sid then found = true; break end
                            end
                            if not found then
                                ghostBS.assignedSpells[#ghostBS.assignedSpells + 1] = sid
                            end
                        end
                        wipe(bs.removedSpells)
                    end
                end
            end
        end
    end
    -- One-time cleanup: remove preset/trinket IDs (negative) and custom
    -- spell IDs from ghost CD bar. Only Blizzard viewer spells belong there.
    if specProfiles then
        for specKey, prof in pairs(specProfiles) do
            if not prof._ghostBarCleaned3 then
                local barSpells = prof and prof.barSpells
                local ghostBS = barSpells and barSpells[GHOST_CD_BAR_KEY]
                if ghostBS and ghostBS.assignedSpells then
                    -- Build set of all spells on real (non-ghost) bars
                    local realBarSpells = {}
                    local customSet = {}
                    for bk, bs in pairs(barSpells) do
                        if bk ~= GHOST_CD_BAR_KEY and bk ~= GHOST_BUFF_BAR_KEY then
                            if bs.assignedSpells then
                                for _, sid in ipairs(bs.assignedSpells) do
                                    if sid and sid > 0 then realBarSpells[sid] = true end
                                end
                            end
                            if bs.customSpellIDs then
                                for sid in pairs(bs.customSpellIDs) do
                                    customSet[sid] = true
                                end
                            end
                        end
                    end
                    local racialsSet = ns._myRacialsSet
                    for i = #ghostBS.assignedSpells, 1, -1 do
                        local sid = ghostBS.assignedSpells[i]
                        if sid <= 0 or customSet[sid]
                           or (racialsSet and racialsSet[sid])
                           or realBarSpells[sid] then
                            table.remove(ghostBS.assignedSpells, i)
                        end
                    end
                end
                prof._ghostBarCleaned3 = true
            end
        end
    end
end
ns.EnsureGhostBars = EnsureGhostBars

-- Exports for extracted files (EllesmereUICdmHooks.lua, EllesmereUICdmSpellPicker.lua)
ns.MAIN_BAR_KEYS = MAIN_BAR_KEYS
ns.GetCDMFont = GetCDMFont
ns.ResolveInfoSpellID = ResolveInfoSpellID
ns.ResolveChildSpellID = ResolveChildSpellID
ns.ComputeTopRowStride = ComputeTopRowStride
-- Side-effect caches are now owned by EllesmereUICdmHooks.lua.
-- The hooks file writes to ns._tick* tables directly; these locals
-- are populated from ns after the hooks file loads (in CDMFinishSetup).
-- The ns._ecmeFC external frame cache is still owned by this file.
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
-- UpdateAllCDMBars: REMOVED. All work is now event-driven via hooks in
-- EllesmereUICdmHooks.lua. CollectAndReanchor runs only when Blizzard
-- fires OnCooldownIDSet, OnActiveStateChanged, Layout, or pool events.
-- The following stub exists only so any stale references don't error.
local function UpdateAllCDMBars(dt) end

-------------------------------------------------------------------------------
--  Bar Visibility (always / in combat / mouseover / never) + Housing
-------------------------------------------------------------------------------

local function _CDMFadeTo(frame, toAlpha, duration)
    if not frame._cdmFadeAG then
        frame._cdmFadeAG = frame:CreateAnimationGroup()
        frame._cdmFadeAG:SetLooping("NONE")
        frame._cdmFadeAnim = frame._cdmFadeAG:CreateAnimation("Alpha")
        frame._cdmFadeAG:SetScript("OnFinished", function()
            local a = frame._cdmFadeAG._toAlpha or toAlpha
            frame:SetAlpha(a)
            -- Sync viewer alpha so all child icons inherit it at once
            local vn = BLIZZ_CDM_FRAMES[frame._barKey]
            local vf = vn and _G[vn]
            if vf then vf:SetAlpha(a > 0 and 1 or 0) end
            frame._cdmFadeSyncing = nil
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
    -- Sync icon alpha each frame during the fade animation
    frame._cdmFadeSyncing = true
    if not frame._cdmFadeSyncUpdate then
        frame._cdmFadeSyncUpdate = true
        frame:HookScript("OnUpdate", function(self)
            if not self._cdmFadeSyncing then return end
            -- Sync viewer alpha each frame so icons fade with the container
            local a = self:GetAlpha()
            local vn = BLIZZ_CDM_FRAMES[self._barKey]
            local vf = vn and _G[vn]
            if vf then vf:SetAlpha(a > 0 and 1 or 0) end
        end)
    end
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
                _CDMFadeTo(frame, 1, 0.15)
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

_CDMApplyVisibility = function()
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
            -- Ghost bar stays hidden even in unlock mode
            if unlockActive and not barData.isGhostBar then
                _CDMStopFade(frame)
                frame:SetAlpha(1)
                if frame.EnableMouseMotion then pcall(frame.EnableMouseMotion, frame, true) end
                frame._visHidden = false
            else

            local vis = barData.barVisibility or "always"
            local shouldHide = false

            -- Priority 1: vehicle always hides
            if inVehicle then
                shouldHide = true
            -- Priority 2: visibility options (checkbox dropdown)
            elseif EllesmereUI.CheckVisibilityOptions(barData) then
                shouldHide = true
            -- Priority 3: visibility mode dropdown
            elseif vis == "never" then
                shouldHide = true
            elseif vis == "in_combat" then
                shouldHide = not inCombat
            elseif vis == "out_of_combat" then
                shouldHide = inCombat
            elseif vis == "in_raid" then
                shouldHide = not inRaid
            elseif vis == "in_party" then
                shouldHide = not (inParty or inRaid)
            elseif vis == "solo" then
                shouldHide = inRaid or inParty
            elseif vis == "mouseover" then
                _CDMAttachHoverHooks(barData.key)
                local state = _cdmHoverStates[barData.key]
                shouldHide = not state or not state.isHovered
            end

            if shouldHide then
                if vis ~= "mouseover" then _CDMStopFade(frame) end
                frame:SetAlpha(0)
                if frame.EnableMouseMotion then pcall(frame.EnableMouseMotion, frame, vis == "mouseover") end
                frame._visHidden = true
                -- Hide this bar's icons individually. The viewer may stay
                -- at alpha 1 (other bars need it), so icon alpha must be
                -- managed per-bar.
                local icons = cdmBarIcons[barData.key]
                if icons then
                    for ii = 1, #icons do
                        if icons[ii] then icons[ii]:SetAlpha(0) end
                    end
                end
            else
                local wasHidden = frame._visHidden
                _CDMStopFade(frame)
                frame:SetAlpha(1)
                if frame.EnableMouseMotion then pcall(frame.EnableMouseMotion, frame, true) end
                frame._visHidden = false
                -- Restore icon alpha and reposition
                if wasHidden then
                    local icons = cdmBarIcons[barData.key]
                    if icons then
                        for ii = 1, #icons do
                            if icons[ii] then icons[ii]:SetAlpha(1) end
                        end
                    end
                    LayoutCDMBar(barData.key)
                end
            end

            end -- unlockActive else
        end
    end

    -- Viewer alpha: icons are parented to Blizzard viewers and inherit
    -- their alpha. Only hide a viewer if ALL bars that use its icons are
    -- hidden. Otherwise a hidden default bar (e.g. "buffs" set to "never")
    -- would kill icons on visible custom bars that share the same viewer.
    for viewerBarKey, viewerName in pairs(BLIZZ_CDM_FRAMES) do
        local viewer = _G[viewerName]
        if viewer then
            -- Check if ANY bar that routes icons from this viewer is visible
            -- Each bar has independent visibility. The viewer must stay
            -- visible if ANY bar that uses its icons is visible.
            -- Viewer-to-bar mapping: cooldowns/utility bars use
            -- Essential/Utility viewers. Buff bars use BuffIcon viewer.
            -- custom_buff bars use their own frames (not the viewer).
            local anyVisible = false
            for _, barData in ipairs(p.cdmBars.bars) do
                if barData.enabled then
                    local frame = cdmBarFrames[barData.key]
                    if frame and not frame._visHidden then
                        local bk = barData.key
                        -- Does this bar use this viewer's icons?
                        if bk == viewerBarKey then
                            -- Default bar matches its viewer directly
                            anyVisible = true; break
                        end
                        -- Custom bars: check which viewer they route from.
                        -- CD/utility custom bars route from Essential or
                        -- Utility viewer based on their assigned spells.
                        -- Custom buffs bars route from the BuffIcon viewer.
                        -- custom_buff (aura timer) bars use own frames, not viewers.
                        local bt = barData.barType
                        if bt ~= "custom_buff" then
                            if bt == "buffs" and viewerBarKey == "buffs" then
                                anyVisible = true; break
                            elseif bt ~= "buffs" and (viewerBarKey == "cooldowns" or viewerBarKey == "utility") then
                                anyVisible = true; break
                            end
                        end
                    end
                end
            end
            viewer:SetAlpha(anyVisible and 1 or 0)
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
                    -- Also store under override/base so talent-swapped spells find the keybind
                    local ovr = C_Spell.GetOverrideSpell and C_Spell.GetOverrideSpell(spellID)
                    if ovr and ovr ~= spellID and not _cdmKeybindCache[ovr] then
                        _cdmKeybindCache[ovr] = formatted
                    end
                    local base = C_Spell.GetBaseSpell and C_Spell.GetBaseSpell(spellID)
                    if base and base ~= spellID and not _cdmKeybindCache[base] then
                        _cdmKeybindCache[base] = formatted
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
            local ifd = _getFD(icon)
            local kbText = ifd and ifd.keybindText or icon._keybindText
            if kbText then
                local ifc = _ecmeFC[icon]
                local sid = ifc and ifc.spellID or icon._spellID
                if bd and bd.showKeybind and sid then
                    local key = _cdmKeybindCache[sid]
                    if not key then
                        local ovr = C_Spell.GetOverrideSpell and C_Spell.GetOverrideSpell(sid)
                        if ovr and ovr ~= sid then key = _cdmKeybindCache[ovr] end
                    end
                    if not key then
                        local base = C_Spell.GetBaseSpell and C_Spell.GetBaseSpell(sid)
                        if base and base ~= sid then key = _cdmKeybindCache[base] end
                    end
                    local name = C_Spell.GetSpellName and C_Spell.GetSpellName(sid)
                    if not key and name then key = _cdmKeybindCache[name] end
                    if key then
                        kbText:SetText(key)
                        kbText:Show()
                    else
                        kbText:Hide()
                    end
                else
                    kbText:Hide()
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

    -- Ensure ghost bars exist before iterating bars
    EnsureGhostBars()

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

    -- Migration: "none" (No Animation) -> "hideActive" (Hide Active State)
    for _, bd in ipairs(p.cdmBars.bars) do
        if bd.activeStateAnim == "none" then
            bd.activeStateAnim = "hideActive"
        end
    end

    -- Migration: per-bar activeStateAnim="hideActive" -> per-icon activeSwipeMode="none"
    -- Old system had a per-bar "Hide Active State" setting. New system is per-icon.
    -- For bars with hideActive, set all their spells to "Hide Active State" mode
    -- across ALL spec profiles, then clear the bar-level setting.
    for _, bd in ipairs(p.cdmBars.bars) do
        if bd.activeStateAnim == "hideActive" and not bd.isGhostBar then
            local specProfiles = SpellStore.GetSpecProfiles()
            if specProfiles then
                for specKey, prof in pairs(specProfiles) do
                    local barSpells = prof and prof.barSpells
                    local bs = barSpells and barSpells[bd.key]
                    if bs and bs.assignedSpells then
                        if not bs.spellSettings then bs.spellSettings = {} end
                        for _, sid in ipairs(bs.assignedSpells) do
                            if sid and sid > 0 then
                                if not bs.spellSettings[sid] then bs.spellSettings[sid] = {} end
                                local ss = bs.spellSettings[sid]
                                -- Only migrate if user hasn't already set per-icon active state
                                if not ss.activeSwipeMode and not ss.activeSwipeR then
                                    ss.activeSwipeMode = "none"
                                end
                            end
                        end
                    end
                end
            end
            -- Clear old per-bar setting so migration doesn't run again
            bd.activeStateAnim = "blizzard"
        end
    end

    -- Migration: repair bars missing `key` field.
    -- Lite DB delta-save can strip `key` when it matches the default template.
    -- If the merge fails to restore it, bars become identity-less stubs and
    -- visibility/routing breaks. Assign missing core keys in order.
    do
        local bars = p.cdmBars and p.cdmBars.bars
        if bars then
            local CORE_KEYS = { "cooldowns", "utility", "buffs" }
            local CORE_NAMES = { cooldowns = "Cooldowns", utility = "Utility", buffs = "Buffs" }
            local present = {}
            for _, bd in ipairs(bars) do
                if bd.key then present[bd.key] = true end
            end
            local missing = {}
            for _, ck in ipairs(CORE_KEYS) do
                if not present[ck] then missing[#missing + 1] = ck end
            end
            if #missing > 0 then
                local mi = 1
                for _, bd in ipairs(bars) do
                    if not bd.key and mi <= #missing then
                        bd.key = missing[mi]
                        bd.name = bd.name or CORE_NAMES[missing[mi]]
                        if bd.enabled == nil then bd.enabled = true end
                        mi = mi + 1
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

    -- Detach BUFF icons only before rebuilding. CD/utility icons are
    -- managed entirely by CollectAndReanchor's simplified flow which
    -- handles cleanup via excess icon clearing. Detaching CD/utility
    -- icons here causes a 1-frame blink because the reanchor is deferred.
    local buffViewer = _G["BuffIconCooldownViewer"]
    local barViewer  = _G["BuffBarCooldownViewer"]
    for key, icons in pairs(cdmBarIcons) do
        for i = 1, #icons do
            local icon = icons[i]
            if icon then
                local vf = icon.viewerFrame
                if vf == buffViewer or vf == barViewer then
                    icon:ClearAllPoints()
                end
            end
        end
    end

    -- Force Blizzard's EditMode CooldownViewer to "Always Visible" so
    -- hideWhenInactive and other viewer settings don't fight with CDM.
    EnforceCooldownViewerEditModeSettings()

    -- Hide Blizzard CDM
    if p.cdmBars.hideBlizzard then
        HideBlizzardCDM()
    end

    -- If user wants Blizzard's tracking bars instead of TBB, restore the
    -- secondary BuffBarCooldownViewer that HideBlizzardCDM moved offscreen.
    -- This only affects the bar-style buff viewer; CDM icon bars are untouched.
    if p.cdmBars.useBlizzardBuffBars and p.cdmBars.hideBlizzard then
        RestoreBlizzardBuffFrame()
    end

    -- Build each bar and populate fast lookup
    local hookActive = ns.IsViewerHooked and ns.IsViewerHooked()
    wipe(barDataByKey)
    for i, barData in ipairs(p.cdmBars.bars) do
        barDataByKey[barData.key] = barData
        BuildCDMBar(i)
        if hookActive and BLIZZ_CDM_FRAMES[barData.key] then
                -- Hooked default bar: skip icon state reset and layout.
                -- CollectAndReanchor will repopulate from viewer pools.
                local frame = cdmBarFrames[barData.key]
                if frame then
                    frame._prevVisibleCount = nil
                end
            else
                RefreshCDMIconAppearance(barData.key)
                -- Reset cached icon state so textures re-evaluate after a character switch
                local icons = cdmBarIcons[barData.key]
                if icons then
                    for _, icon in ipairs(icons) do
                        local iifc = _ecmeFC[icon]
                        if iifc then iifc.lastTex = nil; iifc.lastDesat = nil; iifc.blizzChild = nil end
                        icon._lastTex = nil
                        icon._lastDesat = nil
                        if iifc then iifc.spellID = nil end
                        icon._spellID = nil
                        icon._blizzChild = nil
                    end
                end
                local frame = cdmBarFrames[barData.key]
                if frame then
                    frame._prevVisibleCount = nil
                end
                LayoutCDMBar(barData.key)
                ApplyCDMTooltipState(barData.key)
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
    UpdateCDMKeybinds()

    -- Re-hide bars whose visibility setting says they should be hidden.
    -- Only hides -- never shows or changes alpha on bars that should be visible.
    -- Without this, rebuilds leave all icons at alpha 1 even when the bar
    -- is set to "in combat only", "never", etc.
    for _, barData in ipairs(p.cdmBars.bars) do
        local frame = cdmBarFrames[barData.key]
        if frame and barData.enabled then
            local vis = barData.barVisibility or "always"
            local shouldHide = false
            if _cdmInVehicle then
                shouldHide = true
            elseif EllesmereUI.CheckVisibilityOptions and EllesmereUI.CheckVisibilityOptions(barData) then
                shouldHide = true
            elseif vis == "never" then
                shouldHide = true
            elseif vis == "in_combat" then
                shouldHide = not _inCombat
            elseif vis == "out_of_combat" then
                shouldHide = _inCombat
            elseif vis == "in_raid" then
                shouldHide = not (IsInRaid and IsInRaid() or false)
            elseif vis == "in_party" then
                local inRaid = IsInRaid and IsInRaid() or false
                shouldHide = not ((not inRaid and (IsInGroup and IsInGroup() or false)) or inRaid)
            elseif vis == "solo" then
                shouldHide = (IsInRaid and IsInRaid()) or (IsInGroup and IsInGroup()) or false
            end
            if shouldHide then
                frame:SetAlpha(0)
                frame._visHidden = true
                local icons = cdmBarIcons[barData.key]
                if icons then
                    for ii = 1, #icons do
                        if icons[ii] then icons[ii]:SetAlpha(0) end
                    end
                end
            else
                frame._visHidden = false
                frame:SetAlpha(1)
                local icons = cdmBarIcons[barData.key]
                if icons then
                    for ii = 1, #icons do
                        if icons[ii] then icons[ii]:SetAlpha(1) end
                    end
                end
            end
        end
    end

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
                local ifc = _ecmeFC[icon]
                local pendFP = ifc and ifc.pendingFontPath or icon._pendingFontPath
                if pendFP then
                    local ifd = _getFD(icon)
                    local cd = ifd and ifd.cooldown or icon._cooldown
                    if cd then
                        local fontPath, fontSize = pendFP, (ifc and ifc.pendingFontSize or icon._pendingFontSize)
                        local fR = ifc and ifc.pendingFontR or icon._pendingFontR
                        local fG = ifc and ifc.pendingFontG or icon._pendingFontG
                        local fB = ifc and ifc.pendingFontB or icon._pendingFontB
                        for ri = 1, cd:GetNumRegions() do
                            local region = select(ri, cd:GetRegions())
                            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                                SetBlizzCDMFont(region, fontPath, fontSize, fR, fG, fB)
                                break
                            end
                        end
                        if ifc then ifc.pendingFontPath = nil; ifc.pendingFontSize = nil; ifc.pendingFontR = nil; ifc.pendingFontG = nil; ifc.pendingFontB = nil end
                        icon._pendingFontPath = nil; icon._pendingFontSize = nil
                        icon._pendingFontR = nil; icon._pendingFontG = nil; icon._pendingFontB = nil
                    end
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

-------------------------------------------------------------------------------
--  FullCDMRebuild
--  The ONE function for "something changed". Treats every call the same:
--  wipe all caches, clear stale frames, rebuild bars, rebuild TBB,
--  reanchor, reapply visibility, update keybinds. Identical result to
--  a fresh login. Use this for spec switch, talent change, zone
--  transition, profile import, equipment change, etc.
--  For cosmetic-only changes (icon size, fonts, glows) call
--  BuildAllCDMBars() directly.
-------------------------------------------------------------------------------
local _rebuildGen = 0

function ns.FullCDMRebuild(reason)
    _rebuildGen = _rebuildGen + 1
    local isSpecSwap = (reason == "spec_switch" or reason == "talent_reconcile" or reason == "spec_same_key")

    -- 1. Wipe all caches
    if ns.MarkCDMSpellCacheDirty then ns.MarkCDMSpellCacheDirty() end
    if ns.InvalidateTBBFrameCache then ns.InvalidateTBBFrameCache() end

    -- 2. Clear old preset frames (trinkets, racials, custom spells)
    if ns._presetFrames then
        for _, f in pairs(ns._presetFrames) do
            f:Hide()
            f:ClearAllPoints()
        end
        wipe(ns._presetFrames)
    end

    -- 3. Rebuild route maps (must happen before BuildAllCDMBars)
    if ns.RebuildSpellRouteMap then ns.RebuildSpellRouteMap() end

    -- 4. Rebuild all bar frames
    BuildAllCDMBars()

    -- 5. Rebuild tracked buff bars
    if ns.BuildTrackedBuffBars then ns.BuildTrackedBuffBars() end

    -- 6. On spec swap: wipe everything and reanchor directly.
    -- _specChangePending is still true at this point (cleared by the
    -- caller AFTER we return), so no queued reanchors can interfere.
    -- The direct CollectAndReanchor call uses bypassSpecGuard=true.
    if isSpecSwap then
        -- Wipe all icon arrays
        for bk, icons in pairs(cdmBarIcons) do
            for i = 1, #icons do icons[i] = nil end
        end
        -- Clear change detection so layout runs fresh
        for bk, frame in pairs(cdmBarFrames) do
            if frame then
                frame._prevIconRefs = nil
                frame._prevVisibleCount = nil
            end
        end
        -- Clear all stale anchors so SetPoint hook doesn't fight
        if ns._hookFrameData then
            for _, efd in pairs(ns._hookFrameData) do
                efd._cdmAnchor = nil
            end
        end
        -- Clear all FC caches so ResolveFrameSpellID re-reads from API.
        -- Spells behind cooldownIDs change on spec swap; stale caches
        -- would return the old spec's spell IDs.
        for _, vname in ipairs(_cdmViewerNames) do
            local vf = _G[vname]
            if vf and vf.GetNumChildren and vf:GetNumChildren() > 0 then
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
                            chfc.sortOrder = nil
                        end
                    end
                end
            end
        end
        -- Direct reanchor, bypassing the _specChangePending guard
        if ns.CollectAndReanchor then ns.CollectAndReanchor(true) end

    else
        if ns.QueueReanchor then ns.QueueReanchor() end
    end

    -- 7. Glows
    if ns.RequestBarGlowUpdate then ns.RequestBarGlowUpdate() end
end

function ns.GetRebuildGen()
    return _rebuildGen
end

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
    ECME.db.sv._capturedOnce_CDM = true
end

--- Repopulate all main bars from Blizzard CDM for the current spec.
--- Wipes assignedSpells/removedSpells/dormantSpells, re-snapshots from
--- Blizzard's CDM categories, then rebuilds route maps and reanchors.
function ns.RepopulateFromBlizzard()
    local p = ECME.db and ECME.db.profile
    if not p or not p.cdmBars then return end
    local specKey = ns.GetActiveSpecKey()
    if not specKey or specKey == "0" then return end

    -- Wipe spell data on all CD/utility bars (main + custom)
    for _, barData in ipairs(p.cdmBars.bars) do
        if not barData.isGhostBar and barData.key ~= "buffs"
           and (barData.barType == "cooldowns" or barData.barType == "utility"
                or MAIN_BAR_KEYS[barData.key]) then
            local sd = ns.GetBarSpellData(barData.key)
            if sd then
                sd.assignedSpells = nil
                sd.removedSpells = nil
                sd.dormantSpells = nil
                sd.spellSettings = nil
            end
        end
    end

    -- Also wipe the ghost CD bar so removed spells come back
    local ghostSD = ns.GetBarSpellData(GHOST_CD_BAR_KEY)
    if ghostSD then
        ghostSD.assignedSpells = nil
        ghostSD.removedSpells = nil
        ghostSD.dormantSpells = nil
    end

    -- Re-snapshot: populate assignedSpells from Blizzard's active viewer
    -- frames. Only spells that Blizzard currently displays are included
    -- (excludes "Not Displayed" spells the user hid in Blizzard's CDM).
    local gci = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
    local viewerToBar = {
        EssentialCooldownViewer = "cooldowns",
        UtilityCooldownViewer   = "utility",
    }
    for vName, barKey in pairs(viewerToBar) do
        local vf = _G[vName]
        local sd = ns.GetBarSpellData(barKey)
        if vf and sd then
            if not sd.assignedSpells then sd.assignedSpells = {} end
            local seen = {}
            if vf.itemFramePool and vf.itemFramePool.EnumerateActive then
                for frame in vf.itemFramePool:EnumerateActive() do
                    local cdID = frame.cooldownID
                    if cdID and gci then
                        local info = gci(cdID)
                        if info then
                            local sid = ResolveInfoSpellID(info)
                            if sid and sid > 0 and not seen[sid] then
                                seen[sid] = true
                                sd.assignedSpells[#sd.assignedSpells + 1] = sid
                            end
                        end
                    end
                end
            end
        end
    end

    ns.FullCDMRebuild("repopulate")
    if ns.CollectAndReanchor then ns.CollectAndReanchor() end

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
        if frame and barData.enabled and not barData.isGhostBar then
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

            -- Buff-type bars can't be anchor targets (their icon count changes
            -- dynamically with auras, causing cascading position shifts).
            local isBuff = (barData.barType == "buffs" or key == "buffs")
            local isDynamic = isBuff or (barData.barType == "custom_buff")
            elements[#elements + 1] = MK({
                key = "CDM_" .. key,
                label = "CDM: " .. barData.name,
                group = "Cooldown Manager",
                order = 600,
                linkedKeys = linked,
                noAnchorTarget = isDynamic,
                noResize = isDynamic,
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
                    local dim = isH and stride or rows
                    local rawIcon = (newW - (dim - 1) * sp) / dim
                    if rawIcon < 8 then rawIcon = 8 end
                    bd2.iconSize = math.floor(rawIcon + 0.5)
                    -- Back-solve exact fractional spacing to hit target width.
                    -- Per-offset snapping in LayoutCDMBar distributes the
                    -- sub-pixel difference as +/-1px across individual gaps.
                    local iconW = SnapForScale(bd2.iconSize, 1)
                    local gaps = dim - 1
                    bd2._matchSpacing = nil
                    bd2._matchStride = nil
                    if gaps > 0 then
                        local exactSp = (newW - dim * iconW) / gaps
                        if exactSp >= 0 and math.abs(exactSp - sp) <= 1 then
                            bd2._matchSpacing = exactSp
                            bd2._matchStride = dim
                        end
                    end
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

    -- Migration: repair bars missing `key` across ALL profiles (not just active).
    -- The BuildAllCDMBars migration only fixes the active profile. Inactive
    -- profiles with keyless stubs stay broken until switched to.
    if EllesmereUIDB and EllesmereUIDB.profiles then
        local CORE_KEYS = { "cooldowns", "utility", "buffs" }
        local CORE_NAMES = { cooldowns = "Cooldowns", utility = "Utility", buffs = "Buffs" }
        for _, profileData in pairs(EllesmereUIDB.profiles) do
            local cdmData = profileData.addons and profileData.addons["EllesmereUICooldownManager"]
            local bars = cdmData and cdmData.cdmBars and cdmData.cdmBars.bars
            if bars then
                local present = {}
                for _, bd in ipairs(bars) do
                    if bd.key then present[bd.key] = true end
                end
                local missing = {}
                for _, ck in ipairs(CORE_KEYS) do
                    if not present[ck] then missing[#missing + 1] = ck end
                end
                if #missing > 0 then
                    local mi = 1
                    for _, bd in ipairs(bars) do
                        if not bd.key and mi <= #missing then
                            bd.key = missing[mi]
                            bd.name = bd.name or CORE_NAMES[missing[mi]]
                            if bd.enabled == nil then bd.enabled = true end
                            mi = mi + 1
                        end
                    end
                end
            end
        end
    end

    -- Migration: strip stale _linkedFrame/_linkedCdID/_linkedGen from TBB
    -- bar configs inside spellAssignments. These are vestiges of removed code
    -- that serialized entire Blizzard frame trees (800-1200 lines each),
    -- causing performance issues on any deep-copy or iteration of spec data.
    do
        local sa = EllesmereUIDB and EllesmereUIDB.spellAssignments
        local specProfiles = sa and sa.specProfiles
        if specProfiles then
            for _, specData in pairs(specProfiles) do
                local tbb = specData.trackedBuffBars
                local tbbBars = tbb and tbb.bars
                if tbbBars then
                    for _, barCfg in ipairs(tbbBars) do
                        barCfg._linkedFrame = nil
                        barCfg._linkedCdID = nil
                        barCfg._linkedGen = nil
                    end
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
    -- Migrate old shared flag to per-addon key (v5.9.6+)
    if self.db.sv._capturedOnce and not self.db.sv._capturedOnce_CDM then
        self.db.sv._capturedOnce_CDM = true
    end
    self._needsCapture = not self.db.sv._capturedOnce_CDM

    -- Expose for options
    _G._ECME_AceDB = self.db
    _G._ECME_Apply = function()
        -- Skip FullCDMRebuild if a CD/utility spell change just happened
        -- (AddTrackedSpell/RemoveTrackedSpell already handled routes + reanchor).
        -- The _skipNextApplyRebuild flag prevents the double-reanchor that
        -- causes icon 1 to disappear.
        if ns._skipNextApplyRebuild then
            ns._skipNextApplyRebuild = false
        else
            ns.FullCDMRebuild("apply")
        end
        if ns.UpdateCustomBuffAuraTracking then ns.UpdateCustomBuffAuraTracking() end
        if ns.UpdateCustomBuffBars then ns.UpdateCustomBuffBars() end
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

    -- Proc glow hooks: install immediately + retry. Hooks must be in place
    -- before Blizzard re-fires ShowAlert at PLAYER_LOGIN for active procs.
    InstallProcGlowHooks()
    C_Timer.After(0.5, InstallProcGlowHooks)

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

    -- Build a reverse override map from CDM cooldownInfo:
    -- overrideSpellID -> base spellID. Handles conditional overrides
    -- (e.g. Glacial Spike -> Frostbolt) where C_Spell.GetBaseSpell
    -- may not work because the relationship is state-dependent.
    local overrideToBase = {}
    if C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
       and C_CooldownViewer.GetCooldownViewerCooldownInfo then
        for cat = 0, 3 do
            local allIDs = C_CooldownViewer.GetCooldownViewerCategorySet(cat, true)
            if allIDs then
                for _, cdID in ipairs(allIDs) do
                    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                    if info and info.overrideSpellID and info.overrideSpellID > 0
                       and info.spellID and info.spellID > 0
                       and info.overrideSpellID ~= info.spellID then
                        overrideToBase[info.overrideSpellID] = info.spellID
                    end
                end
            end
        end
    end

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
        -- For conditional overrides (e.g. Glacial Spike from Frostbolt),
        -- also check the base spell -- the override may not be "known" when
        -- its condition isn't met (e.g. icicles = 0 on reload/zone change).
        local _IPS = IsPlayerSpell
        local _GBS = C_Spell and C_Spell.GetBaseSpell
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
                    -- Check if this is an override whose base spell is known
                    -- (e.g. Glacial Spike stored while Frostbolt is the base).
                    -- Try C_Spell.GetBaseSpell first, fall back to CDM
                    -- cooldownInfo reverse map for conditional overrides.
                    local base = _GBS and _GBS(sid)
                    if base == sid then base = nil end
                    if not base then base = overrideToBase[sid] end
                    if base and base > 0 and base ~= sid
                       and (knownSet[base] or (_IPS and _IPS(base))
                            or (classSpellSet and classSpellSet[base])) then
                        active[#active + 1] = sid
                        seenInActive[sid] = true
                    else
                        -- Spell is no longer known -- save its slot index and move to dormant
                        dormant[sid] = i
                    end
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
            -- Also check base spell for conditional overrides
            if not isKnown then
                local base = _GBS and _GBS(sid)
                if base == sid then base = nil end
                if not base then base = overrideToBase[sid] end
                if base and base > 0 and base ~= sid then
                    isKnown = knownSet[base] or (_IPS and _IPS(base))
                        or (classSpellSet and classSpellSet[base])
                end
            end
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
                    ReconcileSpellList(sd.assignedSpells, sd.dormantSpells, sd.removedSpells, nil)
            end
        end
    end

    ns._lastReconciledSpec = ns.GetActiveSpecKey()
    ns.FullCDMRebuild("talent_reconcile")
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
            if MAIN_BAR_KEYS[barData.key] and TALENT_AWARE_BAR_TYPES[barData.key] then
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
                ns.FullCDMRebuild("corruption_recovery")
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
    -- ONE-TIME MIGRATION: wipe all buff bar data across ALL specs.
    -- Removes extra buff bars from the bar list and clears assignedSpells
    -- for all buff-type bars in every spec profile. The new system has the
    -- main "buffs" bar auto-show everything from CDM with no assignments.
    do
        if not EllesmereUIDB then EllesmereUIDB = {} end
        if not EllesmereUIDB._buffBarMigrationV2Done then
            EllesmereUIDB._buffBarMigrationV2Done = true

            -- Collect the keys of all extra buff bars being removed so we
            -- can also clean their spell assignments. Custom bars use keys
            -- like "custom_5_1234" so we can't rely on name patterns.
            local removedBuffBarKeys = {}

            -- 1. Remove extra buff bars from the bar list (all profiles)
            local function WipeBuffBarsFromProfile(p)
                if not p or not p.cdmBars or not p.cdmBars.bars then return end
                local kept = {}
                for _, bd in ipairs(p.cdmBars.bars) do
                    if bd.barType == "buffs" and bd.key ~= "buffs" then
                        removedBuffBarKeys[bd.key] = true
                    else
                        kept[#kept + 1] = bd
                    end
                end
                p.cdmBars.bars = kept
            end

            -- Current profile
            WipeBuffBarsFromProfile(self.db and self.db.profile)

            -- All other profiles in the DB
            if EllesmereUIDB and EllesmereUIDB.profiles then
                for _, prof in pairs(EllesmereUIDB.profiles) do
                    WipeBuffBarsFromProfile(prof)
                end
            end

            -- 2. Clear spell assignments for all buff-type bars
            local store = EllesmereUIDB.spellAssignments
            if store and store.specProfiles then
                for _, specProf in pairs(store.specProfiles) do
                    if specProf.barSpells then
                        -- Clear main buffs bar assignments (auto-populated now)
                        if specProf.barSpells["buffs"] then
                            specProf.barSpells["buffs"].assignedSpells = nil
                        end
                        -- Remove spell data for every extra buff bar we deleted
                        for removedKey in pairs(removedBuffBarKeys) do
                            specProf.barSpells[removedKey] = nil
                        end
                    end
                end
            end
        end
    end

    -- Migrate: clear stale assignedSpells on the main buffs bar.
    -- The main bar is Blizzard-owned and should never have assignedSpells.
    do
        if not EllesmereUIDB._buffsBarCleanupV2 then
            EllesmereUIDB._buffsBarCleanupV2 = true
            local store = EllesmereUIDB.spellAssignments
            if store and store.specProfiles then
                for _, specProf in pairs(store.specProfiles) do
                    if specProf.barSpells and specProf.barSpells.buffs then
                        specProf.barSpells.buffs.assignedSpells = nil
                    end
                end
            end
        end
    end

    -- Migrate: mouseover visibility is no longer supported on CDM bars.
    -- Move any bars using it to "always".
    do
        local p = self.db and self.db.profile
        if p and p.cdmBars and p.cdmBars.bars then
            for _, bd in ipairs(p.cdmBars.bars) do
                if bd.barVisibility == "mouseover" then
                    bd.barVisibility = "always"
                end
            end
        end
    end

    -- Migrate: de-anchor anything anchored to a buff-type bar.
    -- Buff bars resize dynamically with auras, causing cascading position
    -- shifts. Anchoring to them is no longer supported.
    do
        local p = self.db and self.db.profile
        if p and p.cdmBars and p.cdmBars.bars then
            -- Build set of buff bar keys
            local buffKeys = {}
            for _, bd in ipairs(p.cdmBars.bars) do
                if bd.barType == "buffs" or bd.key == "buffs" or bd.barType == "custom_buff" then
                    buffKeys["CDM_" .. bd.key] = true
                end
            end
            -- Also include AuraBuff Reminders (dynamic icon count)
            buffKeys["EABR_Reminders"] = true
            -- Check unlock anchors and clear any pointing to dynamic bars
            local anchors = EllesmereUIDB and EllesmereUIDB.unlockAnchors
            if anchors then
                for childKey, info in pairs(anchors) do
                    if info.target and buffKeys[info.target] then
                        anchors[childKey] = nil
                    end
                end
            end
        end
    end

    -- Migrate: bar glows and TBB from old locations to spec-specific storage.
    -- Old locations:
    --   barGlows: EllesmereUIDB.spellAssignments.barGlows (global)
    --             or specProfiles[specKey].barGlows (from old save/load cycle)
    --   trackedBuffBars: ECME.db.profile.trackedBuffBars
    --   tbbPositions: ECME.db.profile.tbbPositions
    -- New location: specProfiles[specKey].barGlows / .trackedBuffBars / .tbbPositions
    do
        local specKey = ns.GetActiveSpecKey()
        if specKey and specKey ~= "0" and EllesmereUIDB and EllesmereUIDB.spellAssignments then
            local sa = EllesmereUIDB.spellAssignments
            if not sa.specProfiles then sa.specProfiles = {} end
            if not sa.specProfiles[specKey] then sa.specProfiles[specKey] = { barSpells = {} } end
            local prof = sa.specProfiles[specKey]

            -- Migrate barGlows: old global -> spec profile (one-time)
            if not prof.barGlows and sa.barGlows and next(sa.barGlows) then
                prof.barGlows = DeepCopy(sa.barGlows)
            end

            -- Migrate trackedBuffBars: old profile -> spec profile (one-time)
            local p = self.db and self.db.profile
            if p then
                if not prof.trackedBuffBars and p.trackedBuffBars and p.trackedBuffBars.bars and #p.trackedBuffBars.bars > 0 then
                    prof.trackedBuffBars = DeepCopy(p.trackedBuffBars)
                end
                if not prof.tbbPositions and p.tbbPositions and next(p.tbbPositions) then
                    prof.tbbPositions = DeepCopy(p.tbbPositions)
                end
            end
        end
    end

    -- Migrate: remove Bloodlust/Time Spiral/warlock presets from all bars
    -- (these can't be tracked via cooldown detection). Only removes preset
    -- versions (customSpellDurations entry), not real class spells like a
    -- Shaman's Heroism or a Warlock's pet summons. Safe to run every login
    -- because these presets were removed from the picker entirely.
    do
        local removedPresets = { [2825] = true, [32182] = true, [80353] = true,
            [264667] = true, [390386] = true, [381301] = true, [444062] = true, [444257] = true, -- Bloodlust variants
            [104316] = true, [265187] = true, [264119] = true, [111898] = true, -- Warlock pets
        }
        local removedPopularKeys = { bloodlust = true, time_spiral = true,
            call_dreadstalkers = true, demonic_tyrant = true,
            summon_vilefiend = true, grimoire_felguard = true }
        local sa = EllesmereUIDB and EllesmereUIDB.spellAssignments
        if sa and sa.specProfiles then
            for _, prof in pairs(sa.specProfiles) do
                -- Clean preset versions of these spells from ALL bars.
                -- Only remove if customSpellDurations has an entry for the
                -- spell (meaning it was added as a preset, not a real class
                -- spell like a Shaman's Heroism or a Warlock's pet summons).
                if prof.barSpells then
                    for bk, bs in pairs(prof.barSpells) do
                        if bs.assignedSpells and bs.customSpellDurations then
                            for i = #bs.assignedSpells, 1, -1 do
                                local sid = bs.assignedSpells[i]
                                if removedPresets[sid] and bs.customSpellDurations[sid] then
                                    table.remove(bs.assignedSpells, i)
                                    bs.customSpellDurations[sid] = nil
                                end
                            end
                        end
                        bs.presetVariants = nil
                    end
                end
                -- Clean only removed presets from TBB (bloodlust, time spiral,
                -- warlock pets). Other popular presets (potions etc.) are kept.
                if prof.trackedBuffBars and prof.trackedBuffBars.bars then
                    for i = #prof.trackedBuffBars.bars, 1, -1 do
                        local bar = prof.trackedBuffBars.bars[i]
                        if bar.popularKey and removedPopularKeys[bar.popularKey] then
                            table.remove(prof.trackedBuffBars.bars, i)
                        end
                    end
                end
            end
        end
    end

    -- Migrate: cleanse custom spells (presets, custom spell IDs) off ALL
    -- buff-type bars across ALL spec profiles. Buff bars are now exclusively
    -- (Old buff bar cleanse migration removed -- the main buffs bar no longer
    -- uses assignedSpells. Secondary buff bars are user-created and should
    -- not be auto-cleansed.)

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

    ns.FullCDMRebuild("init")

    -- Initialize Tracking Bars
    -- GetTrackedBuffBars auto-initializes empty bars if none exist.
    -- No validation/removal: TBB bars can track any buff (procs,
    -- external buffs, food, etc.) not just CDM viewer spells.
    -- Bars with no active aura simply stay hidden at runtime.
    ns.GetTrackedBuffBars()

    -- Fix misattributed buff spells: if a user has a spellID that shares
    -- a name with another spellID on the same bar, keep the one that's
    -- actually in Blizzard's BuffIcon viewer and remove the other.
    do
        -- Build tracked set directly from viewer pool (tick cache may
        -- not be populated yet at startup).
        local buffIconTracked = {}
        local biv = _G["BuffIconCooldownViewer"]
        if biv and biv.itemFramePool and biv.itemFramePool.EnumerateActive then
            for frame in biv.itemFramePool:EnumerateActive() do
                local sid = ns.ResolveChildSpellID and ns.ResolveChildSpellID(frame)
                if sid and sid > 0 then buffIconTracked[sid] = true end
                -- Also check cooldownInfo for base/override IDs
                local info = frame.cooldownInfo
                if info then
                    if info.spellID and info.spellID > 0 then buffIconTracked[info.spellID] = true end
                    if info.overrideSpellID and info.overrideSpellID > 0 then buffIconTracked[info.overrideSpellID] = true end
                end
            end
        end
        -- Merge with tick cache if available
        local tickSet = ns._tickBuffIconTrackedSet
        if tickSet then
            for sid in pairs(tickSet) do buffIconTracked[sid] = true end
        end

        -- Helper: clean a spell list by removing non-tracked dupes by name
        local function CleanSpellList(spellList)
            if not spellList or #spellList == 0 then return end
            -- Build name groups: name -> { {idx, sid, tracked}, ... }
            local byName = {}
            for i, sid in ipairs(spellList) do
                if sid and sid > 0 then
                    local name = C_Spell.GetSpellName(sid)
                    if name then
                        if not byName[name] then byName[name] = {} end
                        local group = byName[name]
                        group[#group + 1] = { idx = i, sid = sid, tracked = buffIconTracked[sid] and true or false }
                    end
                end
            end
            -- For each name with multiple entries, keep only the tracked one
            local removeSet = {}
            for name, group in pairs(byName) do
                if #group > 1 then
                    local hasTracked = false
                    for _, e in ipairs(group) do
                        if e.tracked then hasTracked = true; break end
                    end
                    if hasTracked then
                        for _, e in ipairs(group) do
                            if not e.tracked then removeSet[e.idx] = true end
                        end
                    end
                end
            end
            -- Remove marked entries (reverse order to preserve indices)
            if next(removeSet) then
                for i = #spellList, 1, -1 do
                    if removeSet[i] then
                        table.remove(spellList, i)
                    end
                end
            end
            -- Also dedup exact same spellID (keep first)
            local seen = {}
            for i = #spellList, 1, -1 do
                local sid = spellList[i]
                if sid and seen[sid] then
                    table.remove(spellList, i)
                elseif sid then
                    seen[sid] = true
                end
            end
        end

        -- Fix CDM buff bar assignedSpells (secondary buff bars only).
        -- The main "buffs" bar no longer uses assignedSpells.
        local p = ECME.db.profile
        for _, barData in ipairs(p.cdmBars.bars) do
            if (barData.barType == "buffs" or barData.key == "buffs") and barData.key ~= "buffs" then
                local sd = ns.GetBarSpellData(barData.key)
                if sd then CleanSpellList(sd.assignedSpells) end
            end
        end

        -- Fix TBB bars (single-spell entries): remove wrong-version entries
        local tbb = ns.GetTrackedBuffBars()
        if tbb and tbb.bars then
            local tbbByName = {}
            for i, bar in ipairs(tbb.bars) do
                if bar.spellID and bar.spellID > 0 and not bar.popularKey then
                    local name = C_Spell.GetSpellName(bar.spellID)
                    if name then
                        if not tbbByName[name] then tbbByName[name] = {} end
                        tbbByName[name][#tbbByName[name] + 1] = { idx = i, tracked = buffIconTracked[bar.spellID] and true or false }
                    end
                end
            end
            local removeIdxs = {}
            for name, group in pairs(tbbByName) do
                if #group > 1 then
                    local hasTracked = false
                    for _, e in ipairs(group) do
                        if e.tracked then hasTracked = true; break end
                    end
                    if hasTracked then
                        for _, e in ipairs(group) do
                            if not e.tracked then removeIdxs[e.idx] = true end
                        end
                    end
                end
            end
            if next(removeIdxs) then
                for i = #tbb.bars, 1, -1 do
                    if removeIdxs[i] then table.remove(tbb.bars, i) end
                end
            end
        end
    end
    if ns.BuildTrackedBuffBars then ns.BuildTrackedBuffBars() end

    -- Hook Blizzard CDM viewer pools (route map already built by FullCDMRebuild)
    ns.SetupViewerHooks()

    -- Edit mode close: no forced rebuild needed. The reanchor naturally skips
    -- inactive buff frames with hideWhenInactive (ghost frames from Edit Mode)
    -- and alpha-0s them as unclaimed. Normal hooks handle the rest.

    -- Register UNIT_AURA tracking if custom buff bars have spells
    if ns.UpdateCustomBuffAuraTracking then ns.UpdateCustomBuffAuraTracking() end

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

    -- (Tick frame removed -- all CDM updates are now event-driven via hooks.
    -- CollectAndReanchor runs only when Blizzard fires lifecycle hooks.)

    -- Register with unlock mode
    RegisterCDMUnlockElements()
    if ns.RegisterTBBUnlockElements then ns.RegisterTBBUnlockElements() end
    -- TBB registers late (after _applySavedPositions already ran).
    -- Re-apply anchors for TBB elements only.
    C_Timer.After(0, function()
        local tbb = ns.GetTrackedBuffBars()
        local bars = tbb and tbb.bars
        if not bars then return end
        for i = 1, #bars do
            if EllesmereUI.ReapplyOwnAnchor then
                EllesmereUI.ReapplyOwnAnchor("TBB_" .. tostring(i))
            end
        end
    end)

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
            local ifd = _getFD(icon)
            local glowOv = ifd and ifd.glowOverlay or icon._glowOverlay
            if glowOv then
                _G_Glows.StopAllGlows(glowOv)
                glowOv:SetAlpha(0)
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
        local ifd = _getFD(icon)
        local glowOv = ifd and ifd.glowOverlay or icon._glowOverlay
        if glowOv then
            _G_Glows.StopAllGlows(glowOv)
            glowOv:SetAlpha(0)
        end
    end
    wipe(ns._rotationGlowedIcons)

    if not suggestedSpell then return end

    local glowStyle = p.cdmBars.rotationHelperGlowStyle or 5
    for barKey, icons in pairs(cdmBarIcons) do
        for _, icon in ipairs(icons) do
            local ifc = _ecmeFC[icon]
            local sid = ifc and ifc.spellID or icon._spellID
            if sid and sid == suggestedSpell and icon:IsShown() then
                local ifd = _getFD(icon)
                local glowOv = ifd and ifd.glowOverlay or icon._glowOverlay
                if glowOv then
                    glowOv:SetAlpha(1)
                    StartNativeGlow(glowOv, glowStyle, 1, 0.82, 0.1)
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
-- Equipment changes: trinket/weapon swaps update trinket frames and reanchor
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
-- Visibility option events: mounted, target, instance zone changes
eventFrame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
-- UPDATE_SHAPESHIFT_FORM not needed: OnCooldownIDSet hooks handle form shifts

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
        -- Invalidate TBB frame cache + spell caches, then reanchor so
        -- overlays re-evaluate against the new viewer pool state.
        if ns.InvalidateTBBFrameCache then ns.InvalidateTBBFrameCache() end
        if ns.MarkCDMSpellCacheDirty then ns.MarkCDMSpellCacheDirty() end
        if ns.QueueReanchor then ns.QueueReanchor() end
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
                if p.cdmBars.useBlizzardBuffBars then
                    RestoreBlizzardBuffFrame()
                end
            end)
        end
        return
    end
    if event == "PLAYER_EQUIPMENT_CHANGED" then
        if InCombatLockdown() then return end
        BuildAllCDMBars()
        if ns.QueueReanchor then ns.QueueReanchor() end
        return
    end
    if event == "PLAYER_MOUNT_DISPLAY_CHANGED" or event == "PLAYER_TARGET_CHANGED" then
        _CDMApplyVisibility()
        return
    end
    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" or event == "ZONE_CHANGED_NEW_AREA" then
        if event == "PLAYER_REGEN_DISABLED" then
            _inCombat = true
            _CDMApplyVisibility()
        elseif event == "PLAYER_REGEN_ENABLED" then
            -- Buffer combat exit: brief out-of-combat blips (mob dies,
            -- re-aggro) shouldn't flash visibility changes.
            C_Timer.After(0.1, function()
                if not InCombatLockdown() then
                    _inCombat = false
                    _CDMApplyVisibility()
                end
            end)
        else
            -- Zone transition (e.g. BG exit): Blizzard viewer frames may have
            -- been recycled. Re-collect and re-apply visibility after a brief
            -- delay to let the viewer state settle.
            _CDMApplyVisibility()
            C_Timer.After(0.5, function()
                if ns.QueueReanchor then ns.QueueReanchor() end
                _CDMApplyVisibility()
            end)
        end
        -- Flush deferred TBB rebuild that was queued during combat
        if event == "PLAYER_REGEN_ENABLED" and ns.IsTBBRebuildPending and ns.IsTBBRebuildPending() then
            if ns.BuildTrackedBuffBars then ns.BuildTrackedBuffBars() end
        end
        -- Flush deferred keybind rebuild that was blocked during combat
        if event == "PLAYER_REGEN_ENABLED" and _keybindRebuildPending then
            UpdateCDMKeybinds()
        end
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        _inCombat = InCombatLockdown and InCombatLockdown() or false
        RECONCILE.lastZoneInAt = GetTime()
        -- Validate spec on every zone-in (catches auto spec swaps, login, etc.)
        local gen = ns.GetRebuildGen()
        C_Timer.After(0.5, function()
            if ns.GetRebuildGen() ~= gen then return end  -- another rebuild already ran
            ValidateSpec()
            if not _specValidated then return end
            local newSpecKey = GetCurrentSpecKey()
            local p = ECME.db and ECME.db.profile
            if p and newSpecKey == ns.GetActiveSpecKey() then
                ns.FullCDMRebuild("zone_in")
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
                    ns.FullCDMRebuild("spells_changed")
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
            -- Only reconcile if the spec actually changed, not for
            -- equipment swaps that temporarily remove spells.
            local currentSpec = ns.GetActiveSpecKey()
            local lastSpec = ns._lastReconciledSpec
            if currentSpec ~= lastSpec then
                C_Timer.After(0.2, function()
                    if RECONCILE.pending then
                        ns.RequestTalentReconcile("SPELLS_CHANGED")
                    end
                end)
            end
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
                if EllesmereUI then EllesmereUI._specProfileSwitching = false end
                ns.FullCDMRebuild("spec_same_key")
                if EllesmereUI and EllesmereUI.ResyncAnchorOffsets then
                    EllesmereUI.ResyncAnchorOffsets()
                end
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
-- DEBUG: /cdmwatchbuffs to trace everything touching the buff bar

SLASH_ECME1 = "/ecme"
SLASH_ECME2 = "/cdmeffects"
SLASH_ECME3 = "/cdm"
SlashCmdList.ECME = function(msg)
    if InCombatLockdown and InCombatLockdown() then return end
    if EllesmereUI and EllesmereUI.ShowModule then
        EllesmereUI:ShowModule("EllesmereUICooldownManager")
    end
end

