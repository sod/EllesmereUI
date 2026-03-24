-------------------------------------------------------------------------------
--  EllesmereUICdmHooks.lua
--  Hook-based CDM Backend
--  Reparents Blizzard CDM viewer pool frames to UIParent and positions them
--  over our styled containers. Blizzard retains full ownership of frame
--  lifecycle (show/hide, active state, desaturation).
-------------------------------------------------------------------------------
local _, ns = ...

-- Upvalue aliases (populated by EllesmereUICooldownManager.lua before this file loads)
local ECME                   = ns.ECME
local barDataByKey           = ns.barDataByKey
local cdmBarFrames           = ns.cdmBarFrames
local cdmBarIcons            = ns.cdmBarIcons
local MAIN_BAR_KEYS          = ns.MAIN_BAR_KEYS
local ResolveInfoSpellID     = ns.ResolveInfoSpellID
local GetCDMFont             = ns.GetCDMFont

-- Per-frame decoration state (weak-keyed: auto-cleans when frame is GCed)
local hookFrameData = setmetatable({}, { __mode = "k" })
ns._hookFrameData = hookFrameData

-- External frame cache: avoid writing custom keys to Blizzard's secure frame
-- tables (which taints them and causes "secret value" errors).
local _ecmeFC = ns._ecmeFC
local FC = ns.FC

-- Spell routing: spellID -> barKey. Rebuilt when bar config changes.
local _spellRouteMap = {}
local _spellRouteGeneration = 0

-- Reusable scratch tables (wiped each CollectAndReanchor call)
local _scratch_barLists = {}
local _scratch_seenSpell = {}
local _scratch_spellOrder = {}
local _scratch_allowSet = {}
local _scratch_filtered = {}
local _scratch_newSet = {}
local _scratch_viewerSpells = {}
local _scratch_active = {}

-- Entry pool: reuse entry tables across ticks to avoid garbage
local _entryPool = {}
local _entryPoolSize = 0
local function AcquireEntry(frame, spellID, baseSpellID, layoutIndex)
    local e
    if _entryPoolSize > 0 then
        e = _entryPool[_entryPoolSize]
        _entryPool[_entryPoolSize] = nil
        _entryPoolSize = _entryPoolSize - 1
    else
        e = {}
    end
    e.frame = frame
    e.spellID = spellID
    e.baseSpellID = baseSpellID
    e.layoutIndex = layoutIndex
    e._inactive = nil
    return e
end
local function ReleaseEntries(list)
    for i = 1, #list do
        local e = list[i]
        if e then
            e.frame = nil
            _entryPoolSize = _entryPoolSize + 1
            _entryPool[_entryPoolSize] = e
        end
        list[i] = nil
    end
end

-------------------------------------------------------------------------------
--  Preset Buff Frames
--  Self-contained system for tracking external buffs (Bloodlust, potions, etc.)
--  that don't exist in Blizzard's CDM viewer pool.
-------------------------------------------------------------------------------
local _presetFrames = {}  -- [barKey..":"..primarySpellID] = frame

-- Racial cooldown event listener: marks racial frames dirty on cooldown
-- change so the next tick refreshes their DurationObject.
local _racialCdListener = CreateFrame("Frame")
_racialCdListener:RegisterEvent("SPELL_UPDATE_COOLDOWN")
_racialCdListener:RegisterEvent("SPELL_UPDATE_CHARGES")
_racialCdListener:SetScript("OnEvent", function()
    for _, f in pairs(_presetFrames) do
        if f._isRacialFrame then f._racialCdDirty = true end
    end
end)

-- Build a reverse lookup: any variant spellID -> preset entry
local _presetLookup  -- built lazily
local function GetPresetLookup()
    if _presetLookup then return _presetLookup end
    _presetLookup = {}
    local presets = ns.BUFF_BAR_PRESETS
    if not presets then return _presetLookup end
    for _, p in ipairs(presets) do
        if p.spellIDs then
            for _, sid in ipairs(p.spellIDs) do
                _presetLookup[sid] = p
            end
        end
    end
    return _presetLookup
end

local function GetOrCreatePresetFrame(barKey, primarySID, preset)
    local fkey = barKey .. ":" .. primarySID
    local f = _presetFrames[fkey]
    if f then return f end

    f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(36, 36)
    f:Hide()

    -- Icon
    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture(preset.icon)
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.Icon = tex
    f._tex = tex

    -- Cooldown swipe
    local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    cd:SetAllPoints()
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)
    cd:SetHideCountdownNumbers(true)
    cd:SetReverse(true)
    f.Cooldown = cd
    f._cooldown = cd

    -- Mark as preset frame
    f._isPresetFrame = true
    f._presetPrimarySID = primarySID
    f._presetKey = preset.key
    f._presetDuration = preset.duration
    f._presetSpellIDs = preset.spellIDs
    f._presetGlowBased = preset.glowBased
    f._presetGlowSpellIDs = preset.glowSpellIDs

    -- Fake fields so DecorateFrame/layout code works
    f.cooldownID = nil
    f.cooldownInfo = nil
    f.layoutIndex = 99999
    f.isActive = false
    f.auraInstanceID = nil
    f.cooldownDuration = 0

    _presetFrames[fkey] = f
    return f
end

-- Check if a preset buff is active on the player.
-- Returns aura data if active, nil if not.
local function IsPresetActive(preset)
    if not preset.spellIDs then return nil end
    for _, sid in ipairs(preset.spellIDs) do
        local aura = C_UnitAuras.GetPlayerAuraBySpellID(sid)
        if aura then return aura, sid end
    end
    return nil
end

-------------------------------------------------------------------------------
--  Trinket Frames
--  Custom frames for equipped on-use trinkets (slot 13/14).
--  Shown on cooldown/utility bars.
-------------------------------------------------------------------------------
local _trinketFrames = {}  -- [slotID] = frame
local _trinketItemCache = { [13] = nil, [14] = nil }  -- cached item IDs

local function GetOrCreateTrinketFrame(slotID)
    local f = _trinketFrames[slotID]
    if f then return f end

    f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(36, 36)
    f:Hide()

    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.Icon = tex
    f._tex = tex

    local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    cd:SetAllPoints()
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)
    cd:SetHideCountdownNumbers(true)
    f.Cooldown = cd
    f._cooldown = cd

    f._isTrinketFrame = true
    f._trinketSlot = slotID
    f.cooldownID = nil
    f.cooldownInfo = nil
    f.layoutIndex = slotID == 13 and 99990 or 99991
    f.isActive = false
    f.auraInstanceID = nil
    f.cooldownDuration = 0

    _trinketFrames[slotID] = f
    return f
end

local function UpdateTrinketFrame(slotID)
    local f = _trinketFrames[slotID]
    if not f then return end
    local itemID = GetInventoryItemID("player", slotID)
    _trinketItemCache[slotID] = itemID
    if not itemID then
        f:Hide()
        return
    end
    -- Update icon
    local icon = C_Item.GetItemIconByID(itemID)
    if icon and f._tex then f._tex:SetTexture(icon) end
    -- Check on-use with minimum cooldown threshold (20s)
    local _, spellID = C_Item.GetItemSpell(itemID)
    f._trinketSpellID = spellID
    local isRealOnUse = false
    if spellID and spellID > 0 then
        -- Parse tooltip for cooldown text to determine real on-use (>= 20s CD)
        local tipData = C_TooltipInfo and C_TooltipInfo.GetItemByID(itemID)
        if tipData and tipData.lines then
            for _, tipLine in ipairs(tipData.lines) do
                local lt = tipLine.leftText
                if lt and lt:find("Cooldown%)") then
                    local cdStr = lt:match("%((.+Cooldown)%)")
                    if cdStr then
                        local totalSec = 0
                        for num, unit in cdStr:gmatch("(%d+)%s*(%a+)") do
                            local n = tonumber(num)
                            if n then
                                local u = unit:lower()
                                if u == "min" then totalSec = totalSec + n * 60
                                elseif u == "sec" then totalSec = totalSec + n
                                elseif u == "hr" or u == "hour" then totalSec = totalSec + n * 3600
                                end
                            end
                        end
                        if totalSec >= 20 then isRealOnUse = true end
                    end
                end
            end
        end
    end
    f._trinketIsOnUse = isRealOnUse
end

local function UpdateTrinketCooldown(slotID)
    local f = _trinketFrames[slotID]
    if not f or not f._trinketIsOnUse then return false end
    local start, dur, enable = GetInventoryItemCooldown("player", slotID)
    if start and dur and dur > 1.5 and enable == 1 then
        f._cooldown:SetCooldown(start, dur)
        return true
    else
        f._cooldown:Clear()
        return false
    end
end

-- Event frame for trinket updates
local _trinketEventFrame = CreateFrame("Frame")
_trinketEventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
_trinketEventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
_trinketEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
_trinketEventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_EQUIPMENT_CHANGED" then
        if arg1 == 13 or arg1 == 14 then
            UpdateTrinketFrame(arg1)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        UpdateTrinketFrame(13)
        UpdateTrinketFrame(14)
    end
    -- Cooldown updates handled per-tick in CollectAndReanchor
end)

-- Sort comparator (hoisted to avoid closure creation per tick)
local function _sortBySpellOrder(a, b)
    local ai = _scratch_spellOrder[a.baseSpellID] or _scratch_spellOrder[a.spellID] or 10000
    local bi = _scratch_spellOrder[b.baseSpellID] or _scratch_spellOrder[b.spellID] or 10000
    if ai ~= bi then return ai < bi end
    return a.layoutIndex < b.layoutIndex
end

-- Reanchor queue state
local reanchorDirty = false
local reanchorFrame = nil
local viewerHooksInstalled = false

-- Maps Blizzard viewer name <-> our bar key
local HOOK_VIEWER_TO_BAR = {
    EssentialCooldownViewer = "cooldowns",
    UtilityCooldownViewer   = "utility",
    BuffIconCooldownViewer  = "buffs",
}
local HOOK_BAR_TO_VIEWER = {}
for vn, bk in pairs(HOOK_VIEWER_TO_BAR) do HOOK_BAR_TO_VIEWER[bk] = vn end

-- Secret boolean helper (guards against restricted combat API return values)
local function IsPublicTrue(value)
    if type(value) ~= "boolean" then return false end
    if type(issecretvalue) == "function" and issecretvalue(value) then return false end
    return value == true
end

--- Resolve spellID from a Blizzard CDM pool frame.
local function ResolveFrameSpellID(frame)
    local cdID = frame.cooldownID
    if not cdID and frame.cooldownInfo then
        cdID = frame.cooldownInfo.cooldownID
    end
    if not cdID or not C_CooldownViewer then return nil end
    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
    return info and ResolveInfoSpellID(info) or nil
end
ns.ResolveFrameSpellID = ResolveFrameSpellID

-------------------------------------------------------------------------------
--  HideBlizzardDecorations
--  Strips Blizzard's visual chrome from a CDM pool frame (one-time per frame).
-------------------------------------------------------------------------------
local function HideBlizzardDecorations(frame)
    local fc = FC(frame)
    if fc.blizzHidden then return end
    fc.blizzHidden = true

    -- Named children: hide + hook to stay hidden
    local hideAndHook = function(child)
        if not child then return end
        child:SetAlpha(0)
        child:Hide()
        hooksecurefunc(child, "Show", function(self) self:Hide() end)
    end
    hideAndHook(frame.Border)
    hideAndHook(frame.SpellActivationAlert)
    hideAndHook(frame.DebuffBorder)
    hideAndHook(frame.Shadow)
    hideAndHook(frame.IconShadow)
    hideAndHook(frame.CooldownFlash)

    -- Applications (stack count): left visible -- Blizzard manages natively

    -- Remove mask textures (alpha=0 doesn't stop clipping)
    local iconWidget = frame.Icon
    if iconWidget then
        if frame.MaskTexture then
            pcall(function() iconWidget:RemoveMaskTexture(frame.MaskTexture) end)
            frame.MaskTexture:Hide()
        end
        if frame.IconMask then
            pcall(function() iconWidget:RemoveMaskTexture(frame.IconMask) end)
            frame.IconMask:Hide()
        end
    end
    if frame.Cooldown then
        if frame.MaskTexture then pcall(function() frame.Cooldown:RemoveMaskTexture(frame.MaskTexture) end) end
        if frame.IconMask then pcall(function() frame.Cooldown:RemoveMaskTexture(frame.IconMask) end) end
    end

    -- Hide Blizzard decoration textures (overlays, shadows) but preserve
    -- FontStrings (stack counts, timers) which Blizzard manages natively.
    local regions = { frame:GetRegions() }
    for ri = 1, #regions do
        local rgn = regions[ri]
        if rgn and rgn ~= iconWidget and rgn.IsObjectType and rgn:IsObjectType("Texture") then
            rgn:SetAlpha(0)
            rgn:Hide()
            hooksecurefunc(rgn, "Show", function(self) self:Hide() end)
        end
    end

    if frame.Cooldown then
        frame.Cooldown:SetHideCountdownNumbers(true)
    end
end

-------------------------------------------------------------------------------
--  DecorateFrame
--  Add our visual overlays to a Blizzard CDM frame (one-time per frame).
-------------------------------------------------------------------------------
local function DecorateFrame(frame, barData)
    local fd = hookFrameData[frame]
    if fd and fd.decorated then return fd end
    if not fd then fd = {}; hookFrameData[frame] = fd end
    fd.decorated = true

    local iconWidget = frame.Icon
    if iconWidget and not iconWidget.GetTexture then
        if iconWidget.Icon then iconWidget = iconWidget.Icon end
    end
    frame._tex = iconWidget
    frame._cooldown = frame.Cooldown

    frame:SetScale(1)
    HideBlizzardDecorations(frame)

    -- Background
    if not frame._bg then
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(barData.bgR or 0.08, barData.bgG or 0.08,
            barData.bgB or 0.08, barData.bgA or 0.6)
        frame._bg = bg
    end

    -- Glow overlay
    if not frame._glowOverlay then
        local go = CreateFrame("Frame", nil, frame)
        go:SetAllPoints(frame)
        go:SetFrameLevel(frame:GetFrameLevel() + 2)
        go:SetAlpha(0)
        go:EnableMouse(false)
        frame._glowOverlay = go
    end

    -- Text overlay
    if not frame._textOverlay then
        local txo = CreateFrame("Frame", nil, frame)
        txo:SetAllPoints(frame)
        txo:SetFrameLevel(frame:GetFrameLevel() + 3)
        txo:EnableMouse(false)
        frame._textOverlay = txo
    end

    -- Keybind text
    if not frame._keybindText then
        local kt = frame._textOverlay:CreateFontString(nil, "OVERLAY")
        kt:SetFont(GetCDMFont(), barData.keybindSize or 10, "OUTLINE")
        kt:SetShadowOffset(0, 0)
        kt:SetPoint("TOPLEFT", frame._textOverlay, "TOPLEFT",
            barData.keybindOffsetX or 2, barData.keybindOffsetY or -2)
        kt:SetJustifyH("LEFT")
        kt:SetTextColor(barData.keybindR or 1, barData.keybindG or 1,
            barData.keybindB or 1, barData.keybindA or 0.9)
        kt:Hide()
        frame._keybindText = kt
    end

    frame._tooltipShown = false

    -- Suppress Blizzard's built-in tooltip when showTooltip is off.
    -- HookScript fires after Blizzard's OnEnter which shows GameTooltip.
    local fc = FC(frame)
    if not fc.tooltipHooked then
        fc.tooltipHooked = true
        frame:HookScript("OnEnter", function()
            local bd = frame._barKey and barDataByKey[frame._barKey]
            if bd and not bd.showTooltip then
                GameTooltip:Hide()
            end
        end)
    end

    -- Range overlay hook: block Blizzard's red tint when option is off
    if iconWidget and not fc.rangeHooked then
        fc.rangeHooked = true
        local inVC = false
        hooksecurefunc(iconWidget, "SetVertexColor", function(self, r, g, b, a)
            if inVC then return end
            local bd = frame._barKey and barDataByKey[frame._barKey]
            if bd and not bd.outOfRangeOverlay then
                if r < 0.95 or g < 0.95 or b < 0.95 then
                    inVC = true
                    self:SetVertexColor(1, 1, 1, a or 1)
                    inVC = false
                end
            end
        end)
    end

    -- PP border
    if not frame._ppBorderCreated then
        EllesmereUI.PP.CreateBorder(frame,
            barData.borderR or 0, barData.borderG or 0,
            barData.borderB or 0, barData.borderA or 1,
            barData.borderSize or 1, "OVERLAY", 7)
        frame._ppBorderCreated = true
    end

    frame._isActive = false
    frame._procGlowActive = false
    frame._edges = {}

    -- Cooldown widget styling
    if frame._cooldown then
        frame._cooldown:SetDrawEdge(false)
        frame._cooldown:SetDrawSwipe(true)
        frame._cooldown:SetDrawBling(false)
        frame._cooldown:SetSwipeColor(0, 0, 0, barData.swipeAlpha or 0.7)
        frame._cooldown:SetSwipeTexture("Interface\\Buttons\\WHITE8x8")
        frame._cooldown:SetHideCountdownNumbers(not barData.showCooldownText)
        local isBuff = (barData.barType == "buffs" or barData.key == "buffs")
        frame._cooldown:SetReverse(isBuff)
    end

    return fd
end

-- Hoisted buff active check (avoids per-tick closure allocation)
local _issecretFn = type(issecretvalue) == "function" and issecretvalue or nil
local function IsBuffActive(f)
    if f._isPresetFrame then return f:IsShown() end
    local v = f.isActive
    if _issecretFn and _issecretFn(v) then
        local aid = f.auraInstanceID
        if aid ~= nil then
            if _issecretFn(aid) then return true end
            return aid ~= nil
        end
        return false
    end
    return v == true
end

-------------------------------------------------------------------------------
--  CategorizeFrame
--  Resolve which bar a viewer frame belongs to.
-------------------------------------------------------------------------------
local function CategorizeFrame(frame, viewerBarKey)
    -- Cache resolved spell IDs on the frame. Invalidated when
    -- OnCooldownIDSet fires (hooks queue reanchor + clear cache),
    -- or when the frame's cooldownID no longer matches the cached value
    -- (Blizzard recycled the frame for a different spell).
    local cdID = frame.cooldownID
    if not cdID and frame.cooldownInfo then
        cdID = frame.cooldownInfo.cooldownID
    end
    if not cdID or not C_CooldownViewer then return nil, nil, nil end

    local fc = _ecmeFC[frame]
    local displaySID = fc and fc.resolvedSid
    local baseSID = fc and fc.baseSpellID
    -- Invalidate cache if cooldownID changed (pool recycling)
    if displaySID and fc.cachedCdID ~= cdID then
        displaySID = nil
        baseSID = nil
        fc.resolvedSid = nil
        fc.baseSpellID = nil
    end
    if not displaySID then
        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
        if not info then return nil, nil, nil end
        displaySID = ResolveInfoSpellID(info)
        if not displaySID or displaySID <= 0 then return nil, nil, nil end
        baseSID = info.spellID
        if not baseSID or baseSID <= 0 then baseSID = displaySID end
        if not fc then fc = {}; _ecmeFC[frame] = fc end
        fc.resolvedSid = displaySID
        fc.baseSpellID = baseSID
        fc.cachedCdID = cdID
    end

    -- Check if any bar claims this spell (cross-viewer routing).
    -- CD/utility can share; buffs stay separate.
    local claimBarKey = _spellRouteMap[baseSID] or _spellRouteMap[displaySID]
    if claimBarKey then
        local claimBD = barDataByKey[claimBarKey]
        local claimType = claimBD and claimBD.barType or claimBarKey
        local viewerIsBuff = (viewerBarKey == "buffs")
        local claimIsBuff = (claimType == "buffs")
        if viewerIsBuff == claimIsBuff then
            return claimBarKey, displaySID, baseSID
        end
    end
    return viewerBarKey, displaySID, baseSID
end

-------------------------------------------------------------------------------
--  RebuildSpellRouteMap
--  Called from _ECME_Apply (options changes) and on bar config changes.
--  Not called per-tick -- the map is stable between config changes.
-------------------------------------------------------------------------------
function ns.RebuildSpellRouteMap()
    wipe(_spellRouteMap)
    local p = ECME.db and ECME.db.profile
    if not p or not p.cdmBars then return end
    local _FindOverride = C_SpellBook and C_SpellBook.FindSpellOverrideByID
    for _, bd in ipairs(p.cdmBars.bars) do
        if bd.enabled then
            local sd = ns.GetBarSpellData(bd.key)
            if sd and sd.assignedSpells then
                for _, sid in ipairs(sd.assignedSpells) do
                    if sid and sid > 0 then
                        _spellRouteMap[sid] = bd.key
                        if _FindOverride then
                            local ovr = _FindOverride(sid)
                            if ovr and ovr > 0 and ovr ~= sid then
                                _spellRouteMap[ovr] = bd.key
                            end
                        end
                    end
                end
            end
        end
    end
    _spellRouteGeneration = _spellRouteGeneration + 1
end

-------------------------------------------------------------------------------
--  CollectAndReanchor (core tick function)
-------------------------------------------------------------------------------
local function CollectAndReanchor()
    local p = ECME.db and ECME.db.profile
    if not p or not p.cdmBars or not p.cdmBars.enabled then return end

    -- Collect active frames from each viewer pool (reuse scratch tables)
    local barLists = _scratch_barLists
    local seenSpell = _scratch_seenSpell
    -- Release previous tick's entries back to pool, then clear lists
    for k, list in pairs(barLists) do
        ReleaseEntries(list)
    end
    -- Wipe seenSpell sub-tables (keep table references to avoid realloc)
    for k, sub in pairs(seenSpell) do wipe(sub) end

    for viewerName, defaultBarKey in pairs(HOOK_VIEWER_TO_BAR) do
        local viewer = _G[viewerName]
        if viewer and viewer.itemFramePool then
            for frame in viewer.itemFramePool:EnumerateActive() do
                local targetBar, displaySID, baseSID = CategorizeFrame(frame, defaultBarKey)
                if targetBar and displaySID and displaySID > 0 then
                    -- Dedup: two-level lookup avoids string concat
                    local barSeen = seenSpell[targetBar]
                    if not barSeen then barSeen = {}; seenSpell[targetBar] = barSeen end
                    local existing = barSeen[displaySID]
                    if existing then
                        if frame:GetParent() == UIParent and existing.frame:GetParent() ~= UIParent then
                            existing.frame = frame
                        end
                        if frame ~= existing.frame then
                            frame:Hide()
                        end
                    else
                        if not barLists[targetBar] then barLists[targetBar] = {} end
                        local list = barLists[targetBar]
                        local entry = AcquireEntry(frame, displaySID, baseSID or displaySID, frame.layoutIndex or 0)
                        list[#list + 1] = entry
                        barSeen[displaySID] = entry
                    end
                end
            end
        end
    end

    -- Deferred-access aliases
    local LayoutCDMBar = ns.LayoutCDMBar
    local RefreshCDMIconAppearance = ns.RefreshCDMIconAppearance
    local ApplyCDMTooltipState = ns.ApplyCDMTooltipState

    -- Ensure bars with negative-ID spells (trinkets/items) get processed
    -- even when they have no Blizzard viewer pool frames.
    for _, bd in ipairs(p.cdmBars.bars) do
        if bd.enabled and not barLists[bd.key] then
            local sd = ns.GetBarSpellData(bd.key)
            local sl = sd and sd.assignedSpells
            if sl then
                for _, sid in ipairs(sl) do
                    if sid and sid < 0 then
                        barLists[bd.key] = {}
                        break
                    end
                end
            end
        end
    end

    -- Process each bar
    for barKey, list in pairs(barLists) do
        local barData = barDataByKey[barKey]
        if barData and barData.enabled then
            local container = cdmBarFrames[barKey]
            if container then
                -- Bar hidden by visibility mode: hide icons and skip processing
                local barHidden = container:GetAlpha() == 0
                local sd = ns.GetBarSpellData(barKey)

                -- Build spell order for sorting (reuse scratch)
                local spellList = sd and sd.assignedSpells
                local spellOrder = _scratch_spellOrder; wipe(spellOrder)
                if spellList then
                    local orderIdx = 0
                    for _, sid in ipairs(spellList) do
                        if sid and sid ~= 0 then
                            -- Skip inactive trinket slots
                            local skipTrinket = false
                            if sid == -13 or sid == -14 then
                                local tf = _trinketFrames[-sid]
                                if not tf or not tf._trinketIsOnUse then skipTrinket = true end
                            end
                            if not skipTrinket then
                                orderIdx = orderIdx + 1
                                spellOrder[sid] = orderIdx
                            end
                        end
                    end
                end

                -- Filter by assignedSpells or removedSpells (reuse scratch)
                -- An existing but empty assignedSpells means "show nothing"
                -- (user removed all spells). nil means "show all" (fresh state).
                if spellList and #spellList > 0 then
                    local allowSet = _scratch_allowSet; wipe(allowSet)
                    local _FindOverride = C_SpellBook and C_SpellBook.FindSpellOverrideByID
                    for _, sid in ipairs(spellList) do
                        if sid and sid > 0 then
                            allowSet[sid] = true
                            if _FindOverride then
                                local ovr = _FindOverride(sid)
                                if ovr and ovr > 0 and ovr ~= sid then allowSet[ovr] = true end
                            end
                        end
                    end
                    local filtered = _scratch_filtered; wipe(filtered)
                    for _, entry in ipairs(list) do
                        if allowSet[entry.spellID] or allowSet[entry.baseSpellID] then
                            filtered[#filtered + 1] = entry
                        end
                    end
                    list = filtered
                elseif spellList then
                    -- assignedSpells exists but is empty = user removed all
                    list = _scratch_filtered; wipe(list)
                elseif sd and sd.removedSpells then
                    local removed = sd.removedSpells
                    local filtered = _scratch_filtered; wipe(filtered)
                    for _, entry in ipairs(list) do
                        if not removed[entry.spellID] and not removed[entry.baseSpellID] then
                            filtered[#filtered + 1] = entry
                        end
                    end
                    list = filtered
                end

                -- Shared state for buff display logic
                local barType = barData.barType or barKey
                local euiOpen = EllesmereUI._mainFrame and EllesmereUI._mainFrame:IsShown()

                -- Inject preset frames for buff bars.
                -- Presets are in assignedSpells but have no viewer pool frame.
                -- Create custom frames and add them to the list when active.
                if barType == "buffs" and sd and sd.customSpellDurations then
                    local activeCache = ns._tickBlizzActiveCache
                    local presets = ns.BUFF_BAR_PRESETS
                    if presets and spellList then
                        for _, sid in ipairs(spellList) do
                            if sid and sid > 0 and sd.customSpellDurations[sid] then
                                -- Check if this spell has a viewer frame already
                                local hasViewer = false
                                for _, entry in ipairs(list) do
                                    if entry.spellID == sid or entry.baseSpellID == sid then
                                        hasViewer = true; break
                                    end
                                end
                                if not hasViewer then
                                    -- Find preset (cached on frame after first lookup)
                                    local fkey = barKey .. ":preset:" .. sid
                                    local f = _presetFrames[fkey]
                                    if not f then
                                        local preset
                                        for _, p in ipairs(presets) do
                                            if p.spellIDs and p.spellIDs[1] == sid then
                                                preset = p; break
                                            end
                                            if p.spellIDs then
                                                for _, psid in ipairs(p.spellIDs) do
                                                    if psid == sid then preset = p; break end
                                                end
                                            end
                                            if preset then break end
                                        end
                                        if preset then
                                            f = GetOrCreatePresetFrame(barKey, sid, preset)
                                        end
                                    end
                                    if f then
                                        -- Use activeCache for lightweight detection
                                        local isActive = activeCache and activeCache[sid]
                                        local hideInactive = barData.hideBuffsWhenInactive
                                        if isActive then
                                            f:Show()
                                            f:SetAlpha(1)
                                            list[#list + 1] = AcquireEntry(f, sid, sid, spellOrder[sid] or 99999)
                                        elseif not hideInactive or euiOpen then
                                            f:Show()
                                            f:SetAlpha(euiOpen and 0.5 or 1)
                                            local entry = AcquireEntry(f, sid, sid, spellOrder[sid] or 99999)
                                            if euiOpen then entry._inactive = true end
                                            list[#list + 1] = entry
                                        else
                                            f:Hide()
                                        end
                                    end
                                end
                            end
                        end
                    end
                end

                -- Inject custom frames for items in assignedSpells
                -- (trinkets = negative slot IDs, potions = spell IDs with customSpellDurations)
                if barType ~= "buffs" and spellList then
                    for _, sid in ipairs(spellList) do
                        if sid and sid < 0 then
                            if sid == -13 or sid == -14 then
                                -- Trinket slot (frame already updated on PLAYER_EQUIPMENT_CHANGED)
                                local slot = -sid
                                local tf = _trinketFrames[slot]
                                if not tf then
                                    tf = GetOrCreateTrinketFrame(slot)
                                    UpdateTrinketFrame(slot)
                                end
                                if _trinketItemCache[slot] and tf._trinketIsOnUse then
                                    UpdateTrinketCooldown(slot)
                                    DecorateFrame(tf, barData)
                                    tf:Show()
                                    list[#list + 1] = AcquireEntry(tf, sid, sid, spellOrder[sid] or 99999)
                                else
                                    tf:Hide()
                                end
                            elseif sid <= -100 then
                                -- Item preset (negated itemID)
                                local itemID = -sid
                                -- Reuse trinket frame system with itemID as key
                                local fkey = barKey .. ":item:" .. itemID
                                local f = _presetFrames[fkey]
                                if not f then
                                    -- Find the preset for this itemID
                                    local preset
                                    local itemPresets = ns.CDM_ITEM_PRESETS
                                    if itemPresets then
                                        for _, p in ipairs(itemPresets) do
                                            if p.itemID == itemID then preset = p; break end
                                            if p.altItemIDs then
                                                for _, alt in ipairs(p.altItemIDs) do
                                                    if alt == itemID then preset = p; break end
                                                end
                                            end
                                        end
                                    end
                                    local icon = preset and preset.icon or C_Item.GetItemIconByID(itemID)
                                    if icon then
                                        f = CreateFrame("Frame", nil, UIParent)
                                        f:SetSize(36, 36)
                                        f:Hide()
                                        local tex = f:CreateTexture(nil, "ARTWORK")
                                        tex:SetAllPoints()
                                        tex:SetTexture(icon)
                                        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                                        f.Icon = tex; f._tex = tex
                                        local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
                                        cd:SetAllPoints(); cd:SetDrawEdge(false); cd:SetDrawBling(false)
                                        cd:SetHideCountdownNumbers(true)
                                        f.Cooldown = cd; f._cooldown = cd
                                        f._isItemPresetFrame = true
                                        f._presetItemID = itemID
                                        f._presetData = preset
                                        f.cooldownID = nil; f.cooldownInfo = nil
                                        f.layoutIndex = 99999
                                        f.isActive = false; f.auraInstanceID = nil; f.cooldownDuration = 0
                                        _presetFrames[fkey] = f
                                    end
                                end
                                if f then
                                    -- Check cooldown - try base itemID and all alts
                                    local start, dur, enable = C_Item.GetItemCooldown(itemID)
                                    if not (start and dur and dur > 1.5) then
                                        -- Try alt item IDs
                                        local preset = f._presetData
                                        if preset and preset.altItemIDs then
                                            for _, altID in ipairs(preset.altItemIDs) do
                                                start, dur, enable = C_Item.GetItemCooldown(altID)
                                                if start and dur and dur > 1.5 then break end
                                            end
                                        end
                                    end
                                    if start and dur and dur > 1.5 and enable then
                                        f._cooldown:SetCooldown(start, dur)
                                        f._cdDbgDone = nil  -- reset debug for next use
                                    else
                                        f._cooldown:Clear()
                                    end
                                    DecorateFrame(f, barData)
                                    f:Show()
                                    list[#list + 1] = AcquireEntry(f, sid, sid, spellOrder[sid] or 99999)
                                end
                            end
                        end
                    end
                end

                -- Sort by saved order (hoisted comparator, zero alloc)
                table.sort(list, _sortBySpellOrder)

                ---------------------------------------------------------------
                --  Build entryBySpell lookup BEFORE hideInactive filter.
                --  The lookup must contain ALL entries (including inactive)
                --  so the assignedSpells loop can find them. hideInactive
                --  state is tracked on entry._inactive instead.
                ---------------------------------------------------------------
                local entryBySpell = {}
                for _, entry in ipairs(list) do
                    local sid = entry.spellID
                    if sid and not entryBySpell[sid] then entryBySpell[sid] = entry end
                    local bsid = entry.baseSpellID
                    if bsid and bsid ~= sid and not entryBySpell[bsid] then entryBySpell[bsid] = entry end
                end

                -- hideBuffsWhenInactive: mark entries as inactive but keep them
                -- in the lookup. The assignedSpells loop uses _inactive to hide.
                local hideInactive = barData.hideBuffsWhenInactive and barType == "buffs"
                if hideInactive and not euiOpen then
                    for _, entry in ipairs(list) do
                        entry._inactive = not IsBuffActive(entry.frame)
                    end
                elseif hideInactive and euiOpen then
                    for _, entry in ipairs(list) do
                        entry._inactive = not IsBuffActive(entry.frame)
                    end
                end

                local icons = cdmBarIcons[barKey]
                if not icons then icons = {}; cdmBarIcons[barKey] = icons end

                ---------------------------------------------------------------
                --  Assign icons: assignedSpells drives slot order.
                --  Blizzard children are matched by spellID from the lookup.
                --  Missing spells get lightweight placeholder frames + overlay.
                --  Bars without assignedSpells fall back to list order.
                ---------------------------------------------------------------
                local useAssigned = spellList and #spellList > 0
                local count = 0
                local noRange = not barData.outOfRangeOverlay
                local _FindOverride = C_SpellBook and C_SpellBook.FindSpellOverrideByID
                local usedFrames = {}  -- track which viewer frames we claimed

                if useAssigned then
                    for _, sid in ipairs(spellList) do
                        if sid and sid ~= 0 then
                            local entry = nil
                            if sid > 0 then
                                entry = entryBySpell[sid]
                                if not entry and _FindOverride then
                                    local ovr = _FindOverride(sid)
                                    if ovr and ovr > 0 then entry = entryBySpell[ovr] end
                                end
                            else
                                entry = entryBySpell[sid]
                            end
                            -- Don't claim the same Blizzard child twice
                            if entry and usedFrames[entry.frame] then entry = nil end

                            count = count + 1
                            local frame
                            local isPlaceholder = false
                            local entryInactive = false

                            if entry then
                                frame = entry.frame
                                entryInactive = entry._inactive
                                usedFrames[frame] = true
                                -- Hide placeholder for this spell if one exists
                                local phKey = barKey .. ":ph:" .. (sid > 0 and sid or -sid)
                                local ph = _presetFrames[phKey]
                                if ph then ph:Hide() end
                            elseif sid > 0 and ns._myRacialsSet and ns._myRacialsSet[sid] then
                                -- Racial ability: custom frame with own cooldown.
                                -- Racials are not in Blizzard CDM viewers.
                                local fkey = barKey .. ":racial:" .. sid
                                frame = _presetFrames[fkey]
                                if not frame then
                                    frame = CreateFrame("Frame", nil, UIParent)
                                    frame:SetSize(36, 36); frame:Hide()
                                    local tex = frame:CreateTexture(nil, "ARTWORK")
                                    tex:SetAllPoints(); tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                                    frame.Icon = tex; frame._tex = tex
                                    local cd = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
                                    cd:SetAllPoints(); cd:SetDrawEdge(false); cd:SetDrawBling(false)
                                    cd:SetHideCountdownNumbers(true)
                                    frame.Cooldown = cd; frame._cooldown = cd
                                    frame.cooldownID = nil; frame.cooldownInfo = nil
                                    frame.layoutIndex = 99999; frame.isActive = false
                                    frame.auraInstanceID = nil; frame.cooldownDuration = 0
                                    frame._isRacialFrame = true
                                    _presetFrames[fkey] = frame
                                end
                                local spInfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
                                if spInfo and spInfo.iconID and frame._tex then
                                    frame._tex:SetTexture(spInfo.iconID)
                                end
                                -- Cooldown is event-driven (SPELL_UPDATE_COOLDOWN).
                                -- Only update on first show or when dirty flag is set.
                                if not frame._racialCdSet or frame._racialCdDirty then
                                    local durObj = C_Spell.GetSpellCooldownDuration and C_Spell.GetSpellCooldownDuration(sid)
                                    if durObj and frame._cooldown.SetCooldownFromDurationObject then
                                        frame._cooldown:SetCooldownFromDurationObject(durObj)
                                    else
                                        frame._cooldown:Clear()
                                    end
                                    frame._racialCdSet = true
                                    frame._racialCdDirty = nil
                                end
                                usedFrames[frame] = true
                            elseif sid > 0 and C_Spell.IsSpellKnownOrOverridesKnown and C_Spell.IsSpellKnownOrOverridesKnown(sid) then
                                -- Known spell but no Blizzard child: placeholder with overlay
                                local fkey = barKey .. ":ph:" .. sid
                                frame = _presetFrames[fkey]
                                if not frame then
                                    frame = CreateFrame("Frame", nil, UIParent)
                                    frame:SetSize(36, 36); frame:Hide()
                                    local tex = frame:CreateTexture(nil, "ARTWORK")
                                    tex:SetAllPoints(); tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                                    frame.Icon = tex; frame._tex = tex
                                    local cd = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
                                    cd:SetAllPoints(); cd:SetDrawEdge(false); cd:SetDrawBling(false)
                                    cd:SetHideCountdownNumbers(true)
                                    frame.Cooldown = cd; frame._cooldown = cd
                                    frame.cooldownID = nil; frame.cooldownInfo = nil
                                    frame.layoutIndex = 99999; frame.isActive = false
                                    frame.auraInstanceID = nil; frame.cooldownDuration = 0
                                    frame._isPlaceholder = true
                                    _presetFrames[fkey] = frame
                                end
                                if sid > 0 then
                                    local spInfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
                                    if spInfo and spInfo.iconID and frame._tex then
                                        frame._tex:SetTexture(spInfo.iconID)
                                    end
                                end
                                isPlaceholder = true
                                usedFrames[frame] = true
                            else
                                -- Untalented spell: skip slot (disappears from bar)
                                count = count - 1
                                frame = nil
                            end

                            if frame then
                            if frame:GetParent() ~= UIParent then frame:SetParent(UIParent) end
                            DecorateFrame(frame, barData)
                            if frame:GetScale() ~= 1 then frame:SetScale(1) end
                            frame._barKey = barKey
                            frame._spellID = entry and (entry.baseSpellID or entry.spellID) or sid
                            if noRange and frame._tex then frame._tex:SetVertexColor(1, 1, 1, 1) end
                            icons[count] = frame

                            -- hideInactive: hide inactive real frames (not placeholders)
                            -- barHidden: bar is invisible via visibility mode
                            if barHidden then
                                frame:Hide()
                            elseif hideInactive and not euiOpen and entryInactive and not isPlaceholder then
                                frame:Hide()
                            else
                                frame:Show()
                            end

                            if isPlaceholder then
                                frame:SetAlpha(1)
                                ns.ApplyUntrackedOverlay(frame, true)
                            else
                                frame:SetAlpha(entryInactive and 0.5 or 1)
                                if frame._untrackedOverlay then frame._untrackedOverlay:Hide() end
                                -- Hide old placeholder for this spell
                                local phKey = barKey .. ":ph:" .. (sid > 0 and sid or -sid)
                                local ph = _presetFrames[phKey]
                                if ph then ph:Hide() end
                            end

                            -- Active state glow (CD/utility bars)
                            if not isPlaceholder and barType ~= "buffs" and frame._glowOverlay then
                                local anim = barData.activeStateAnim or "blizzard"
                                local isInActiveState = false
                                if frame.auraInstanceID ~= nil then
                                    local dur = frame.cooldownDuration
                                    if _issecretFn and dur ~= nil and _issecretFn(dur) then
                                        isInActiveState = true
                                    elseif dur ~= nil and dur ~= 0 then
                                        isInActiveState = true
                                    end
                                end
                                local glowStyle = tonumber(anim)
                                local ffc = FC(frame)
                                if anim == "hideActive" then
                                    if isInActiveState then frame:SetAlpha(0) end
                                elseif glowStyle and glowStyle > 0 and isInActiveState then
                                    if not frame._glowOverlay._glowActive or ffc.activeGlowStyle ~= glowStyle then
                                        local gr, gg, gb
                                        if barData.activeAnimClassColor then
                                            local _, cf = UnitClass("player")
                                            local cc = cf and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cf]
                                            if cc then gr, gg, gb = cc.r, cc.g, cc.b end
                                        end
                                        gr = gr or barData.activeAnimR or 1.0
                                        gg = gg or barData.activeAnimG or 0.85
                                        gb = gb or barData.activeAnimB or 0.0
                                        ns.StartNativeGlow(frame._glowOverlay, glowStyle, gr, gg, gb)
                                        ffc.activeGlowStyle = glowStyle
                                    end
                                elseif anim == "none" and isInActiveState then
                                    if frame._glowOverlay._glowActive then
                                        ns.StopNativeGlow(frame._glowOverlay)
                                        ffc.activeGlowStyle = nil
                                    end
                                else
                                    if frame._glowOverlay._glowActive and ffc.activeGlowStyle then
                                        ns.StopNativeGlow(frame._glowOverlay)
                                        ffc.activeGlowStyle = nil
                                    end
                                end
                            end
                            -- Buff glow
                            if not isPlaceholder and barType == "buffs" and frame._glowOverlay then
                                local glowType = barData.buffGlowType or 0
                                if glowType > 0 and not entryInactive then
                                    if not frame._glowOverlay._glowActive then
                                        local gr, gg, gb
                                        if barData.buffGlowClassColor then
                                            local _, cf = UnitClass("player")
                                            local cc = cf and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cf]
                                            if cc then gr, gg, gb = cc.r, cc.g, cc.b end
                                        end
                                        gr = gr or barData.buffGlowR or 1.0
                                        gg = gg or barData.buffGlowG or 0.776
                                        gb = gb or barData.buffGlowB or 0.376
                                        ns.StartNativeGlow(frame._glowOverlay, glowType, gr, gg, gb)
                                    end
                                else
                                    if frame._glowOverlay._glowActive then
                                        ns.StopNativeGlow(frame._glowOverlay)
                                    end
                                end
                            end
                        end -- if frame then
                        end
                    end
                else
                    -- No assignedSpells: list-driven layout (fresh state)
                    for _, entry in ipairs(list) do
                        local frame = entry.frame
                        count = count + 1
                        if frame:GetParent() ~= UIParent then frame:SetParent(UIParent) end
                        DecorateFrame(frame, barData)
                        if frame:GetScale() ~= 1 then frame:SetScale(1) end
                        frame._barKey = barKey
                        frame._spellID = entry.baseSpellID or entry.spellID
                        if noRange and frame._tex then frame._tex:SetVertexColor(1, 1, 1, 1) end
                        icons[count] = frame
                        if barHidden then
                            frame:Hide()
                        else
                            frame:Show()
                        end
                        frame:SetAlpha(entry._inactive and 0.5 or 1)
                        usedFrames[frame] = true
                    end
                end

                -- Return unused viewer frames back to their viewer
                for _, entry in ipairs(list) do
                    if not usedFrames[entry.frame] then
                        entry.frame:Hide()
                        entry.frame:ClearAllPoints()
                        local vn = HOOK_BAR_TO_VIEWER[barKey] or HOOK_BAR_TO_VIEWER[barData.barType]
                        local viewer = vn and _G[vn]
                        if viewer and entry.frame:GetParent() ~= viewer then
                            entry.frame:SetParent(viewer)
                        end
                    end
                end
                -- Return old icons no longer in use
                for _, oldFrame in ipairs(icons) do
                    if oldFrame and not usedFrames[oldFrame] and not oldFrame._isPlaceholder then
                        oldFrame:Hide()
                        oldFrame:ClearAllPoints()
                        local vn = HOOK_BAR_TO_VIEWER[barKey] or HOOK_BAR_TO_VIEWER[barData.barType]
                        local viewer = vn and _G[vn]
                        if viewer and oldFrame:GetParent() ~= viewer then
                            oldFrame:SetParent(viewer)
                        end
                    end
                end

                -- Hide excess icons
                for i = count + 1, #icons do
                    if icons[i] then
                        if not icons[i]._isPlaceholder then icons[i]:Hide() end
                    end
                    icons[i] = nil
                end

                -- Refresh appearance on frame set change
                local prevCount = container._prevVisibleCount or 0
                local needRefresh = count ~= prevCount
                if not needRefresh and container._prevIconRefs then
                    for idx = 1, count do
                        if container._prevIconRefs[idx] ~= icons[idx] then
                            needRefresh = true; break
                        end
                    end
                end
                if needRefresh then
                    RefreshCDMIconAppearance(barKey)
                    if not container._prevIconRefs then container._prevIconRefs = {} end
                    for idx = 1, count do container._prevIconRefs[idx] = icons[idx] end
                    for idx = count + 1, #container._prevIconRefs do container._prevIconRefs[idx] = nil end
                end
                LayoutCDMBar(barKey)
                ApplyCDMTooltipState(barKey)
                container._prevVisibleCount = count
            end
        end
    end

    -- Clean up empty bars
    for _, bd in ipairs(p.cdmBars.bars) do
        if bd.enabled and not barLists[bd.key] then
            local icons = cdmBarIcons[bd.key]
            if icons then
                for i = 1, #icons do
                    if icons[i] then icons[i]:Hide() end
                    icons[i] = nil
                end
            end
            local container = cdmBarFrames[bd.key]
            if container and (container._prevVisibleCount or 0) > 0 then
                container._prevVisibleCount = 0
                LayoutCDMBar(bd.key)
            end
        end
    end

end
ns.CollectAndReanchor = CollectAndReanchor

--- Queue a reanchor for the next OnUpdate frame.
local function QueueReanchor()
    reanchorDirty = true
    if reanchorFrame then reanchorFrame:Show() end
end
ns.QueueReanchor = QueueReanchor

local function ProcessReanchorQueue(self)
    if not reanchorDirty then self:Hide(); return end
    reanchorDirty = false
    CollectAndReanchor()
end

--- Install hooks on Blizzard CDM viewer mixins and frame pools.
function ns.SetupViewerHooks()
    if viewerHooksInstalled then return end
    viewerHooksInstalled = true

    reanchorFrame = CreateFrame("Frame")
    reanchorFrame:SetScript("OnUpdate", ProcessReanchorQueue)
    reanchorFrame:Hide()

    for viewerName in pairs(HOOK_VIEWER_TO_BAR) do
        local viewer = _G[viewerName]
        if viewer then
            if viewer.Layout then hooksecurefunc(viewer, "Layout", QueueReanchor) end
            if viewer.RefreshLayout then hooksecurefunc(viewer, "RefreshLayout", QueueReanchor) end
            if viewer.itemFramePool then
                if viewer.itemFramePool.Acquire then hooksecurefunc(viewer.itemFramePool, "Acquire", QueueReanchor) end
                if viewer.itemFramePool.ReleaseAll then hooksecurefunc(viewer.itemFramePool, "ReleaseAll", QueueReanchor) end
            end
        end
    end

    local mixinNames = {
        "CooldownViewerEssentialItemMixin",
        "CooldownViewerUtilityItemMixin",
        "CooldownViewerBuffIconItemMixin",
    }
    for _, mName in ipairs(mixinNames) do
        local mixin = _G[mName]
        if mixin then
            if mixin.OnCooldownIDSet then hooksecurefunc(mixin, "OnCooldownIDSet", function(frame)
                -- Clear cached spell IDs so CategorizeFrame re-resolves
                local ffc = _ecmeFC[frame]
                if ffc then
                    ffc.resolvedSid = nil
                    ffc.baseSpellID = nil
                end
                QueueReanchor()
            end) end
            if mixin.OnActiveStateChanged then hooksecurefunc(mixin, "OnActiveStateChanged", QueueReanchor) end
        end
    end

    C_Timer.After(0.2, QueueReanchor)
end

function ns.IsViewerHooked()
    return viewerHooksInstalled
end


