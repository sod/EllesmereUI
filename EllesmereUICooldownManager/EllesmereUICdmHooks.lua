-------------------------------------------------------------------------------
--  EllesmereUICdmHooks.lua  (v5 -- Mixin Hook Architecture)
--
--  CORE PRINCIPLE: Blizzard manages all cooldown/buff state.
--  We ONLY restyle (borders, shapes, fonts) and reposition (into our bars).
--
--  Hook strategy:
--    - OnCooldownIDSet on all 4 Blizzard CDM mixins -> QueueReanchor
--    - Pool Acquire on all viewers -> QueueReanchor
--    - Viewer Layout hooks -> QueueReanchor (catches frame removals)
--
--  Taint prevention:
--    - Never SetParent/SetScale/Hide/Show on Blizzard frames
--    - Never move Blizzard frames offscreen
--    - Never write custom keys to Blizzard frame tables
--    - All per-frame data in external weak-keyed tables
--    - Unclaimed frames: SetAlpha(0). Claimed: SetAlpha(1).
-------------------------------------------------------------------------------
local _, ns = ...

local ECME               = ns.ECME
local barDataByKey        = ns.barDataByKey
local cdmBarFrames        = ns.cdmBarFrames
local cdmBarIcons         = ns.cdmBarIcons
local MAIN_BAR_KEYS       = ns.MAIN_BAR_KEYS
local ResolveInfoSpellID  = ns.ResolveInfoSpellID
local GetCDMFont          = ns.GetCDMFont

local floor   = math.floor
local GetTime = GetTime

-------------------------------------------------------------------------------
--  Memory Profiling (temporary)
-------------------------------------------------------------------------------
local _memProf = {}
local _memProfLast = 0
local function MemSnap(label)
    local kb = collectgarbage("count")
    if not _memProf[label] then _memProf[label] = { total = 0, calls = 0, peak = 0 } end
    _memProf[label]._pre = kb
end
local function MemDelta(label)
    local p = _memProf[label]
    if not p or not p._pre then return end
    local delta = collectgarbage("count") - p._pre
    p.total = p.total + delta
    p.calls = p.calls + 1
    if delta > p.peak then p.peak = delta end
    p._pre = nil
end
local function MemReport()
    local now = GetTime()
    if now - _memProfLast < 10 then return end
    _memProfLast = now
    local sorted = {}
    for k, v in pairs(_memProf) do
        sorted[#sorted + 1] = { name = k, total = v.total, calls = v.calls, peak = v.peak }
    end
    table.sort(sorted, function(a, b) return a.total > b.total end)
    -- print("|cff00ffff[CDM MEM]|r Top allocators (last 10s):")
    -- for i = 1, math.min(8, #sorted) do
    --     local e = sorted[i]
    --     print(string.format("  %s: %.1f KB total, %d calls, %.2f KB peak",
    --         e.name, e.total, e.calls, e.peak))
    -- end
    for k in pairs(_memProf) do _memProf[k] = { total = 0, calls = 0, peak = 0 } end
end
ns._MemSnap = MemSnap
ns._MemDelta = MemDelta

-- Per-frame decoration state (weak-keyed)
local hookFrameData = setmetatable({}, { __mode = "k" })
ns._hookFrameData = hookFrameData

-- External frame cache from main file
local _ecmeFC = ns._ecmeFC
local FC = ns.FC

local function FD(f)
    local d = hookFrameData[f]
    if not d then d = {}; hookFrameData[f] = d end
    return d
end
ns.FD = FD

-------------------------------------------------------------------------------
--  Constants
-------------------------------------------------------------------------------
local VIEWER_NAMES = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
}

local VIEWER_TO_BAR = {
    EssentialCooldownViewer = "cooldowns",
    UtilityCooldownViewer   = "utility",
    BuffIconCooldownViewer  = "buffs",
}

-- Master guard: suspend ALL hook logic while Blizzard CDM settings is open.
-- Any interaction with frames during settings editing causes taint.
local function IsCDMSettingsOpen()
    return CooldownViewerSettings and CooldownViewerSettings:IsShown()
end

-------------------------------------------------------------------------------
--  Spell ID Resolution
-------------------------------------------------------------------------------
local function ResolveFrameSpellID(frame)
    local cdID = frame.cooldownID
    if not cdID and frame.cooldownInfo then
        cdID = frame.cooldownInfo.cooldownID
    end
    if not cdID or not C_CooldownViewer then return nil, nil end

    local fc = _ecmeFC[frame]
    if fc and fc.resolvedSid and fc.cachedCdID == cdID then
        local baseSID = fc.baseSpellID
        if baseSID and C_SpellBook and C_SpellBook.FindSpellOverrideByID then
            local liveOvr = C_SpellBook.FindSpellOverrideByID(baseSID)
            if liveOvr and liveOvr ~= 0 and liveOvr ~= fc.overrideSid then
                fc.overrideSid = liveOvr
                fc.resolvedSid = liveOvr
            end
        end
        return fc.resolvedSid, fc.baseSpellID
    end

    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
    if not info then return nil, nil end
    local displaySID = ResolveInfoSpellID(info)
    if not displaySID or displaySID <= 0 then return nil, nil end
    local baseSID = info.spellID
    if not baseSID or baseSID <= 0 then baseSID = displaySID end

    if not fc then fc = {}; _ecmeFC[frame] = fc end
    fc.resolvedSid = displaySID
    fc.baseSpellID = baseSID
    fc.overrideSid = info.overrideSpellID
    fc.cachedCdID  = cdID
    fc.cachedAuraInstID = frame.auraInstanceID

    if info.linkedSpellIDs and #info.linkedSpellIDs > 0 then
        fc.linkedSpellIDs = info.linkedSpellIDs
    else
        fc.linkedSpellIDs = nil
    end

    return displaySID, baseSID
end
ns.ResolveFrameSpellID = ResolveFrameSpellID

-------------------------------------------------------------------------------
--  Spell Route Map + CooldownID Route Map
--
--  _spellRouteMap: spellID -> barKey (used by options/preview/picker)
--  _cdidRouteMap:  cooldownID -> barKey (used at runtime by CategorizeFrame)
--
--  The cdidRouteMap is built by iterating all CDM cooldownIDs from the
--  category API and matching against assignedSpells. Runtime routing is
--  a single table lookup on frame.cooldownID -- no spell ID resolution
--  needed, no taint risk.
-------------------------------------------------------------------------------
local _spellRouteMap = {}
local _cdidRouteMap = {}

function ns.RebuildSpellRouteMap()
    wipe(_spellRouteMap)
    wipe(_cdidRouteMap)
    local p = ECME.db and ECME.db.profile
    if not p or not p.cdmBars then return end

    -- Step 1: build spellID -> barKey from assignedSpells (for options/preview)
    local spellToBar = {}
    local _FindOverride = C_SpellBook and C_SpellBook.FindSpellOverrideByID
    for _, bd in ipairs(p.cdmBars.bars) do
        if bd.enabled and bd.key ~= "buffs" and bd.barType ~= "custom_buff" then
            local sd = ns.GetBarSpellData(bd.key)
            if sd and sd.assignedSpells then
                for _, sid in ipairs(sd.assignedSpells) do
                    if type(sid) == "number" and sid > 0 then
                        _spellRouteMap[sid] = bd.key
                        spellToBar[sid] = bd.key
                        -- Forward: stored spell -> current override
                        if _FindOverride then
                            local ovr = _FindOverride(sid)
                            if ovr and ovr > 0 and ovr ~= sid then
                                _spellRouteMap[ovr] = bd.key
                                spellToBar[ovr] = bd.key
                            end
                        end
                        -- Reverse: stored spell may be the override form
                        -- (added while transformed). Resolve the base spell
                        -- so the cooldownID lookup can match via info.spellID.
                        if C_Spell and C_Spell.GetBaseSpell then
                            local base = C_Spell.GetBaseSpell(sid)
                            if base and base > 0 and base ~= sid then
                                _spellRouteMap[base] = bd.key
                                spellToBar[base] = bd.key
                            end
                        end
                    end
                end
            end
        end
    end

    -- Step 2: build cooldownID -> barKey by cross-referencing the category
    -- API against the spellToBar table we just built.
    local gcs = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
    local gci = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
    local evc = Enum and Enum.CooldownViewerCategory
    if gcs and gci and evc then
        -- Resolve a single cooldownID against spellToBar
        local function MatchCooldownToBar(cdID)
            local info = gci(cdID)
            if not info then return end
            -- Gather all candidate spell IDs from this cooldown entry
            local candidates = {}
            if info.overrideSpellID and info.overrideSpellID > 0
                and info.overrideSpellID ~= info.spellID then
                candidates[#candidates + 1] = info.overrideSpellID
            end
            if info.spellID and info.spellID > 0 then
                candidates[#candidates + 1] = info.spellID
            end
            if info.linkedSpellIDs then
                for _, lid in ipairs(info.linkedSpellIDs) do
                    if lid and lid > 0 then
                        candidates[#candidates + 1] = lid
                    end
                end
            end
            for _, sid in ipairs(candidates) do
                if spellToBar[sid] then return spellToBar[sid] end
            end
        end

        local viewerCategories = { evc.Essential, evc.Utility, evc.TrackedBuff }
        for _, cat in ipairs(viewerCategories) do
            local ids = gcs(cat, true)
            if ids then
                for _, cdID in ipairs(ids) do
                    local barKey = MatchCooldownToBar(cdID)
                    if barKey then _cdidRouteMap[cdID] = barKey end
                end
            end
        end
    end
end
ns._spellRouteMap = _spellRouteMap
ns._cdidRouteMap = _cdidRouteMap

-------------------------------------------------------------------------------
--  Side-Effect Caches (consumed by options, spell picker, bar glows)
-------------------------------------------------------------------------------
local _activeCache      = {}
local _barViewerCache   = {}
local _cdUtilTrackedSet = {}
local _buffIconTrackedSet = {}
local _allChildCache    = {}
local _buffChildCache   = {}

ns._tickBlizzActiveCache    = _activeCache
ns._tickBarViewerCache      = _barViewerCache
ns._tickCDUtilTrackedSet    = _cdUtilTrackedSet
ns._tickBuffIconTrackedSet  = _buffIconTrackedSet
ns._tickBlizzAllChildCache  = _allChildCache
ns._tickBlizzBuffChildCache = _buffChildCache

local function RebuildSideEffectCaches()
    wipe(_activeCache)
    wipe(_barViewerCache)
    wipe(_cdUtilTrackedSet)
    wipe(_buffIconTrackedSet)
    wipe(_allChildCache)
    wipe(_buffChildCache)

    for vi = 1, 4 do
        local vf = _G[VIEWER_NAMES[vi]]
        local isBuffViewer     = (vi == 3 or vi == 4)
        local isBuffIconViewer = (vi == 3)
        if vf and vf.itemFramePool and vf.itemFramePool.EnumerateActive then
            for frame in vf.itemFramePool:EnumerateActive() do
                local displaySID, baseSID = ResolveFrameSpellID(frame)
                if displaySID and displaySID > 0 then
                    _allChildCache[displaySID] = frame
                    if baseSID and baseSID > 0 and baseSID ~= displaySID then
                        _allChildCache[baseSID] = frame
                    end

                    if isBuffViewer then
                        if isBuffIconViewer or not _buffChildCache[displaySID] then
                            _buffChildCache[displaySID] = frame
                        end
                        if not isBuffIconViewer then
                            _barViewerCache[displaySID] = frame
                            if baseSID and baseSID > 0 then
                                _barViewerCache[baseSID] = frame
                            end
                        end
                        if isBuffIconViewer then
                            _buffIconTrackedSet[displaySID] = true
                            if baseSID and baseSID > 0 then
                                _buffIconTrackedSet[baseSID] = true
                            end
                        end
                        local fc = _ecmeFC[frame]
                        local linked = fc and fc.linkedSpellIDs
                        if linked then
                            for li = 1, #linked do
                                local lsid = linked[li]
                                if lsid and lsid > 0 then
                                    _allChildCache[lsid] = frame
                                    if isBuffIconViewer or not _buffChildCache[lsid] then
                                        _buffChildCache[lsid] = frame
                                    end
                                    if isBuffIconViewer then
                                        _buffIconTrackedSet[lsid] = true
                                    end
                                    if not isBuffIconViewer then
                                        _barViewerCache[lsid] = frame
                                    end
                                end
                            end
                        end
                    else
                        _cdUtilTrackedSet[displaySID] = true
                        if baseSID and baseSID > 0 then
                            _cdUtilTrackedSet[baseSID] = true
                        end
                        local fc3 = _ecmeFC[frame]
                        local linked3 = fc3 and fc3.linkedSpellIDs
                        if linked3 then
                            for li = 1, #linked3 do
                                local lsid = linked3[li]
                                if lsid and lsid > 0 then
                                    _cdUtilTrackedSet[lsid] = true
                                end
                            end
                        end
                    end

                    if frame.wasSetFromAura == true or frame.auraInstanceID ~= nil then
                        _activeCache[displaySID] = true
                        if baseSID and baseSID > 0 then
                            _activeCache[baseSID] = true
                        end
                        local fc2 = _ecmeFC[frame]
                        local linked2 = fc2 and fc2.linkedSpellIDs
                        if linked2 then
                            for li = 1, #linked2 do
                                local lsid = linked2[li]
                                if lsid and lsid > 0 then
                                    _activeCache[lsid] = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
--  IsFrameIncluded
--  Include if shown OR has cooldownInfo (catches transitional frames).
-------------------------------------------------------------------------------
local function IsFrameIncluded(frame)
    if not frame then return false end
    return frame:IsShown() or (frame.cooldownInfo ~= nil)
end

-------------------------------------------------------------------------------
--  HideBlizzardDecorations
--  Strip Blizzard visual chrome from a CDM frame (one-time per frame).
-------------------------------------------------------------------------------
local function HideBlizzardDecorations(frame)
    local fc = FC(frame)
    if fc.blizzHidden then return end
    fc.blizzHidden = true

    local function alphaZero(child)
        if child then child:SetAlpha(0) end
    end
    alphaZero(frame.Border)
    if frame.SpellActivationAlert then
        frame.SpellActivationAlert:SetAlpha(0)
        frame.SpellActivationAlert:Hide()
    end
    alphaZero(frame.Shadow)
    alphaZero(frame.IconShadow)
    alphaZero(frame.DebuffBorder)
    alphaZero(frame.CooldownFlash)

    local iconWidget = frame.Icon
    local regions = { frame:GetRegions() }
    for ri = 1, #regions do
        local rgn = regions[ri]
        if rgn and rgn.IsObjectType and rgn:IsObjectType("MaskTexture") then
            pcall(function() rgn:SetTexture("Interface\\Buttons\\WHITE8X8") end)
        end
    end
    if frame.Cooldown then
        local cdRegions = { frame.Cooldown:GetRegions() }
        for ri = 1, #cdRegions do
            local rgn = cdRegions[ri]
            if rgn and rgn.IsObjectType and rgn:IsObjectType("MaskTexture") then
                pcall(function() rgn:SetTexture("Interface\\Buttons\\WHITE8X8") end)
            end
        end
    end

    local OVERLAY_ATLAS = "UI-HUD-CoolDownManager-IconOverlay"
    local OVERLAY_FILE  = 6707800
    for ri = 1, #regions do
        local rgn = regions[ri]
        if rgn and rgn ~= iconWidget and rgn.IsObjectType and rgn:IsObjectType("Texture") then
            local atlas = rgn.GetAtlas and rgn:GetAtlas()
            local tex = rgn.GetTexture and rgn:GetTexture()
            if atlas == OVERLAY_ATLAS or tex == OVERLAY_FILE then
                rgn:SetAlpha(0)
                rgn:Hide()
            end
        end
    end

    -- Do NOT call SetHideCountdownNumbers. Use SetCountdownFont
    -- to control countdown text display instead of hiding numbers entirely.
end

-------------------------------------------------------------------------------
--  DecorateFrame
--  Add our visual overlays to a CDM frame (one-time per frame).
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
    fd.tex = iconWidget
    fd.cooldown = frame.Cooldown

    HideBlizzardDecorations(frame)

    -- Hook SetPoint: when Blizzard repositions this frame (via Layout,
    -- RefreshLayout, or internal updates), force it back to the stored
    -- CDM anchor position if Blizzard tries to reposition it.
    if not fd._setPointHooked then
        fd._setPointHooked = true
        hooksecurefunc(frame, "SetPoint", function(_, point, relativeTo)
            local anchor = fd._cdmAnchor
            if not anchor then return end
            -- If relativeTo is already our bar container, this is our own
            -- SetPoint call from LayoutCDMBar. Don't intercept.
            if relativeTo == anchor[2] then return end
            -- Blizzard is trying to move us. Force back to CDM position.
            frame:ClearAllPoints()
            frame:SetPoint(anchor[1], anchor[2], anchor[3], anchor[4], anchor[5])
        end)
    end

    -- Hook SetDesaturated on the icon texture: when hideActive is enabled,
    -- force desaturation back immediately if Blizzard tries to un-desaturate.
    -- Same pattern as the SetSwipeColor hook -- prevents 1-frame flash.
    if iconWidget and iconWidget.SetDesaturated and not fd._desatHooked then
        fd._desatHooked = true
        hooksecurefunc(iconWidget, "SetDesaturated", function()
            if fd._inDesatHook then return end
            local fc2 = _ecmeFC[frame]
            local bk = fc2 and fc2.barKey
            local bd2 = bk and barDataByKey[bk]
            if not bd2 then return end
            local anim = bd2.activeStateAnim or "blizzard"
            if anim ~= "hideActive" then return end
            -- Only override when the spell is actually active (swipe color
            -- red channel != 0). Normal cooldown desat is left alone.
            local swipeColor = frame.cooldownSwipeColor
            if not swipeColor or type(swipeColor) == "number" then return end
            if not swipeColor.GetRGBA then return end
            local r = swipeColor:GetRGBA()
            if not r or type(r) ~= "number" or issecretvalue(r) then return end
            if r == 0 then return end
            -- Spell is active: force desat + suppress alert
            fd._inDesatHook = true
            iconWidget:SetDesaturated(true)
            if frame.SpellActivationAlert then
                frame.SpellActivationAlert:SetAlpha(0)
                frame.SpellActivationAlert:Hide()
            end
            fd._inDesatHook = false
        end)
    end

    if not fd.bg then
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(barData.bgR or 0.08, barData.bgG or 0.08,
            barData.bgB or 0.08, barData.bgA or 0.6)
        fd.bg = bg
    end

    if not fd.glowOverlay then
        local go = CreateFrame("Frame", nil, frame)
        go:SetAllPoints(frame)
        go:SetFrameLevel(frame:GetFrameLevel() + 2)
        go:SetAlpha(0)
        go:EnableMouse(false)
        fd.glowOverlay = go
    end

    if not fd.textOverlay then
        local txo = CreateFrame("Frame", nil, frame)
        txo:SetAllPoints(frame)
        txo:SetFrameLevel(frame:GetFrameLevel() + 3)
        txo:EnableMouse(false)
        fd.textOverlay = txo
    end

    if not fd.keybindText then
        local kt = fd.textOverlay:CreateFontString(nil, "OVERLAY")
        local kbScale = frame:GetScale() or 1
        if kbScale < 0.01 then kbScale = 1 end
        kt:SetFont(GetCDMFont(), (barData.keybindSize or 10) / kbScale, "OUTLINE")
        kt:SetShadowOffset(0, 0)
        kt:SetPoint("TOPLEFT", fd.textOverlay, "TOPLEFT",
            barData.keybindOffsetX or 2, barData.keybindOffsetY or -2)
        kt:SetJustifyH("LEFT")
        kt:SetTextColor(barData.keybindR or 1, barData.keybindG or 1,
            barData.keybindB or 1, barData.keybindA or 0.9)
        kt:Hide()
        fd.keybindText = kt
    end

    fd.tooltipShown = false

    local fc = FC(frame)
    if not fc.tooltipHooked then
        fc.tooltipHooked = true
        frame:HookScript("OnEnter", function()
            local ffc = _ecmeFC[frame]
            local bd = ffc and ffc.barKey and barDataByKey[ffc.barKey]
            if bd and not bd.showTooltip then
                GameTooltip:Hide()
            end
        end)
    end

    if not fd.borderFrame then
        local bf = CreateFrame("Frame", nil, frame)
        bf:SetAllPoints(frame)
        bf:SetFrameLevel(frame:GetFrameLevel())
        fd.borderFrame = bf
        EllesmereUI.PP.CreateBorder(bf,
            barData.borderR or 0, barData.borderG or 0,
            barData.borderB or 0, barData.borderA or 1,
            barData.borderSize or 1, "OVERLAY", 7)
    end

    fd.isActive = false
    fd.procGlowActive = false

    if fd.cooldown then
        fd.cooldown:SetDrawEdge(false)
        -- Swipe starts disabled. CollectAndReanchor enables it once the
        -- frame is claimed and positioned on a bar. This prevents a flash
        -- of black swipe at the Blizzard viewer's default position before
        -- our reanchor runs.
        fd.cooldown:SetDrawSwipe(false)
        fd.cooldown:SetDrawBling(false)
        fd.cooldown:SetSwipeColor(0, 0, 0, barData.swipeAlpha or 0.7)
        fd.cooldown:SetSwipeTexture("Interface\\Buttons\\WHITE8x8")
        -- Hook SetSwipeColor: when Blizzard changes the swipe color (e.g.
        -- red for active state), force it back to our color immediately.
        -- Without this, Blizzard's colored swipe renders for 1 frame before
        -- the ticker catches it.
        if not fd._swipeColorHooked then
            fd._swipeColorHooked = true
            local cd = fd.cooldown
            hooksecurefunc(cd, "SetSwipeColor", function(_, r, g, b, a)
                if fd._inSwipeHook then return end
                local fc2 = _ecmeFC[frame]
                local bk = fc2 and fc2.barKey
                local bd2 = bk and barDataByKey[bk]
                local anim = bd2 and bd2.activeStateAnim or "blizzard"
                if anim ~= "hideActive" then return end
                local sa = bd2 and bd2.swipeAlpha or 0.7
                if r == 0 and g == 0 and b == 0 and a == sa then return end
                fd._inSwipeHook = true
                cd:SetSwipeColor(0, 0, 0, sa)
                fd._inSwipeHook = false
            end)
            -- Force swipe always visible. Blizzard disables swipe on charge
            -- spells while recharging. We always want it shown.
            hooksecurefunc(cd, "SetDrawSwipe", function(_, show)
                if fd._inSwipeHook then return end
                if show then return end
                fd._inSwipeHook = true
                cd:SetDrawSwipe(true)
                fd._inSwipeHook = false
            end)
        end
        local isBuff = (barData.barType == "buffs" or barData.key == "buffs" or barData.barType == "custom_buff")
        fd.cooldown:SetReverse(isBuff)

        -- NOTE: Do NOT hook SetCooldown or Clear on the Cooldown widget.
        -- Hooking these runs our code inside Blizzard's secure cooldown update
        -- chain, which propagates taint to frame properties like isActive and
        -- allowAvailableAlert. Active state animations are handled during
        -- reanchor instead.
    end

    hookFrameData[frame] = fd
    return fd
end

-------------------------------------------------------------------------------
--  CategorizeFrame
-------------------------------------------------------------------------------
local function CategorizeFrame(frame, viewerBarKey)
    local displaySID, baseSID = ResolveFrameSpellID(frame)
    if not displaySID or displaySID <= 0 then return nil, nil, nil end

    -- Route by cooldownID first, fall back to spellID if the
    -- cdidRouteMap hasn't been rebuilt since this cooldownID appeared.
    local cdID = frame.cooldownID
    local claimBarKey = cdID and _cdidRouteMap[cdID]
    if not claimBarKey then
        claimBarKey = _spellRouteMap[baseSID] or _spellRouteMap[displaySID]
        -- Backfill the cdidRouteMap so future lookups are instant
        if claimBarKey and cdID then
            _cdidRouteMap[cdID] = claimBarKey
        end
    end
    if claimBarKey then
        local claimBD = barDataByKey[claimBarKey]
        local claimType = claimBD and claimBD.barType or claimBarKey
        local viewerIsBuff = (viewerBarKey == "buffs")
        local claimIsBuff  = (claimType == "buffs")
        if viewerIsBuff == claimIsBuff then
            return claimBarKey, displaySID, baseSID
        end
    end
    return viewerBarKey, displaySID, baseSID
end

-------------------------------------------------------------------------------
--  Trinket Frames
-------------------------------------------------------------------------------
local _trinketFrames = {}
ns._trinketFrames = _trinketFrames
local _trinketItemCache = { [13] = nil, [14] = nil }

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
    local icon = C_Item.GetItemIconByID(itemID)
    if icon and f._tex then f._tex:SetTexture(icon) end
    local _, spellID = C_Item.GetItemSpell(itemID)
    f._trinketSpellID = spellID
    local isRealOnUse = false
    if spellID and spellID > 0 then
        local locale = GetLocale()
        if locale == "enUS" or locale == "enGB" then
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
        else
            isRealOnUse = true
        end
    end
    f._trinketIsOnUse = isRealOnUse
end
ns.UpdateTrinketFrame = UpdateTrinketFrame

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

local _trinketEventFrame = CreateFrame("Frame")
_trinketEventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
_trinketEventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
_trinketEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
_trinketEventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_EQUIPMENT_CHANGED" then
        if arg1 == 13 or arg1 == 14 then
            UpdateTrinketFrame(arg1)
            if ns.QueueReanchor then ns.QueueReanchor() end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        UpdateTrinketFrame(13)
        UpdateTrinketFrame(14)
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        for _, slot in ipairs({13, 14}) do
            if _trinketFrames[slot] and _trinketFrames[slot]._trinketIsOnUse then
                UpdateTrinketCooldown(slot)
            end
        end
    end
end)

-------------------------------------------------------------------------------
--  Preset/Custom Frames
-------------------------------------------------------------------------------
local _presetFrames = {}
ns._presetFrames = _presetFrames

local _racialCdListener = CreateFrame("Frame")
_racialCdListener:RegisterEvent("SPELL_UPDATE_COOLDOWN")
_racialCdListener:RegisterEvent("SPELL_UPDATE_CHARGES")
_racialCdListener:RegisterEvent("BAG_UPDATE_COOLDOWN")
_racialCdListener:SetScript("OnEvent", function()
    -- Directly update cooldowns on existing preset frames instead of
    -- waiting for CollectAndReanchor (which only runs on viewer changes).
    for fkey, f in pairs(_presetFrames) do
        if f:IsShown() then
            if (f._isRacialFrame or f._isCustomSpellFrame) and not f._isCustomBuffFrame then
                local sid = fkey:match(":(%d+)$")
                sid = sid and tonumber(sid)
                if sid then
                    local durObj = C_Spell.GetSpellCooldownDuration and C_Spell.GetSpellCooldownDuration(sid)
                    if durObj and f._cooldown and f._cooldown.SetCooldownFromDurationObject then
                        f._cooldown:SetCooldownFromDurationObject(durObj, true)
                    end
                end
            elseif f._isItemPresetFrame and f._presetItemID then
                local itemID = f._presetItemID
                local getContainerCD = C_Container and C_Container.GetItemCooldown
                local start, dur
                if getContainerCD then
                    start, dur = getContainerCD(itemID)
                end
                if not (start and dur and dur > 1.5) then
                    start, dur = C_Item.GetItemCooldown(itemID)
                end
                if not (start and dur and dur > 1.5) and f._presetData and f._presetData.altItemIDs then
                    for _, altID in ipairs(f._presetData.altItemIDs) do
                        if getContainerCD then start, dur = getContainerCD(altID) end
                        if not (start and dur and dur > 1.5) then start, dur = C_Item.GetItemCooldown(altID) end
                        if start and dur and dur > 1.5 then break end
                    end
                end
                if start and dur and dur > 1.5 then
                    f._cooldown:SetCooldown(start, dur)
                    f._cdStart = start; f._cdDur = dur
                elseif not (f._cdStart and f._cdDur and GetTime() < f._cdStart + f._cdDur) then
                    f._cooldown:Clear()
                    f._cdStart = nil; f._cdDur = nil
                end
            end
        end
    end
    if QueueCustomBuffUpdate then QueueCustomBuffUpdate() end
end)

-- Custom aura bar cast detection
local _pendingCastIDs = {}
local _customBuffDirty = false
local _customBuffFrame = CreateFrame("Frame")
_customBuffFrame:Hide()
local CUSTOM_BUFF_THROTTLE = 0.05
local _lastCustomBuffTime = 0
_customBuffFrame:SetScript("OnUpdate", function(self)
    if not _customBuffDirty then self:Hide(); return end
    local now = GetTime()
    if now - _lastCustomBuffTime < CUSTOM_BUFF_THROTTLE then return end
    _customBuffDirty = false
    _lastCustomBuffTime = now
    if ns.UpdateCustomBuffBars then ns.UpdateCustomBuffBars() end
end)

local function QueueCustomBuffUpdate()
    _customBuffDirty = true
    _customBuffFrame:Show()
end

local _spellCastListener = CreateFrame("Frame")
_spellCastListener:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
_spellCastListener:SetScript("OnEvent", function(_, _, _, _, spellID)
    if spellID then
        _pendingCastIDs[spellID] = true
        QueueCustomBuffUpdate()
    end
end)

-------------------------------------------------------------------------------
--  Entry Pool + Sorting
-------------------------------------------------------------------------------
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

local _scratch_barLists  = {}
local _scratch_seenSpell = {}
local _scratch_spellOrder = {}
local _scratch_allowSet  = {}
local _scratch_activeFrames = {}
local _scratch_entryBySpell = {}
local _scratch_filtered  = {}
local _scratch_usedFrames = {}

local function _sortBySpellOrder(a, b)
    local ai = _scratch_spellOrder[a.baseSpellID] or _scratch_spellOrder[a.spellID] or 10000
    local bi = _scratch_spellOrder[b.baseSpellID] or _scratch_spellOrder[b.spellID] or 10000
    if ai ~= bi then return ai < bi end
    return (a.layoutIndex or 0) < (b.layoutIndex or 0)
end
local function _sortByLayoutIndex(a, b)
    return (a.layoutIndex or 0) < (b.layoutIndex or 0)
end

-------------------------------------------------------------------------------
--  CollectAndReanchor  (THE CORE)
--
--  1. EnumerateActive on all viewers
--  2. Route each frame to the correct bar
--  3. Filter by assignedSpells, inject custom frames
--  4. Decorate, sort, assign to icon slots, layout
--  5. Alpha 0 for unclaimed, alpha 1 for claimed
-------------------------------------------------------------------------------
local reanchorDirty = false
local reanchorFrame = nil
local viewerHooksInstalled = false

local function CollectAndReanchor()
    -- Block reanchors during spec transitions
    if ns._specChangePending then return end

    local p = ECME.db and ECME.db.profile
    if not p or not p.cdmBars or not p.cdmBars.enabled then return end

    MemSnap("RebuildSideEffectCaches")
    RebuildSideEffectCaches()
    if ns.RebuildCDMSpellCaches then ns.RebuildCDMSpellCaches() end
    MemDelta("RebuildSideEffectCaches")

    -- 1. Collect frames from all viewers via EnumerateActive
    local barLists = _scratch_barLists
    local seenSpell = _scratch_seenSpell
    for k, list in pairs(barLists) do ReleaseEntries(list) end
    for k, sub in pairs(seenSpell) do wipe(sub) end
    wipe(_scratch_usedFrames)
    wipe(_scratch_activeFrames)
    local allActiveFrames = _scratch_activeFrames

    MemSnap("Enumerate+Categorize")
    for viewerName, defaultBarKey in pairs(VIEWER_TO_BAR) do
        local viewer = _G[viewerName]
        if viewer and viewer.itemFramePool and viewer.itemFramePool.EnumerateActive then
            for frame in viewer.itemFramePool:EnumerateActive() do
                if IsFrameIncluded(frame) then
                    allActiveFrames[frame] = true
                    local isBuff = (defaultBarKey == "buffs")
                    if isBuff and not frame:IsShown() then
                        -- Blizzard hid this buff. Skip it.
                    else
                    local targetBar, displaySID, baseSID = CategorizeFrame(frame, defaultBarKey)
                    if targetBar and displaySID and displaySID > 0 then
                        local skip = false
                        if not isBuff and ns.IsSpellKnownInCDM then
                            skip = not ns.IsSpellKnownInCDM(displaySID)
                            -- Don't skip frames whose cooldownID is routed to a bar
                            -- (spell transforms change the displaySID but the base is known)
                            if skip and frame.cooldownID and _cdidRouteMap[frame.cooldownID] then
                                skip = false
                            end
                        end
                        if not skip then
                            local barSeen = seenSpell[targetBar]
                            if not barSeen then barSeen = {}; seenSpell[targetBar] = barSeen end
                            local dedupKey = isBuff and frame.cooldownID or displaySID
                            if dedupKey and not barSeen[dedupKey] then
                                if not barLists[targetBar] then barLists[targetBar] = {} end
                                barLists[targetBar][#barLists[targetBar] + 1] =
                                    AcquireEntry(frame, displaySID, baseSID or displaySID, frame.layoutIndex or 0)
                                barSeen[dedupKey] = true
                            end
                        end
                    end
                    end -- buff inclusion check
                end
            end
        end
    end
    MemDelta("Enumerate+Categorize")

    MemSnap("ProcessBars")
    local LayoutCDMBar = ns.LayoutCDMBar
    local RefreshCDMIconAppearance = ns.RefreshCDMIconAppearance
    local ApplyCDMTooltipState = ns.ApplyCDMTooltipState
    local _FindOverride = C_SpellBook and C_SpellBook.FindSpellOverrideByID

    -- Ensure custom-frame-only bars get processed
    for _, bd in ipairs(p.cdmBars.bars) do
        if bd.enabled and not barLists[bd.key] then
            local sd = ns.GetBarSpellData(bd.key)
            if sd and sd.assignedSpells and #sd.assignedSpells > 0 then
                barLists[bd.key] = {}
            end
        end
    end

    -- 2-4. Process each bar (skip custom_buff)
    for barKey, list in pairs(barLists) do
        local barData = barDataByKey[barKey]
        if barData and barData.enabled and barData.barType ~= "custom_buff" then
            local container = cdmBarFrames[barKey]
            if container then
                local sd = ns.GetBarSpellData(barKey)
                local spellList = sd and sd.assignedSpells
                local barType = barData.barType or barKey
                local isBuff = (barType == "buffs")

                -- Spell order for sorting (CD/utility only).
                -- Buff bars use Blizzard's layoutIndex -- no custom ordering.
                local spellOrder = _scratch_spellOrder; wipe(spellOrder)
                if not isBuff and spellList then
                    local idx = 0
                    for _, sid in ipairs(spellList) do
                        if sid and sid ~= 0 then
                            idx = idx + 1
                            spellOrder[sid] = idx
                        end
                    end
                end

                -- Filter by assignedSpells (CD/utility only).
                -- Buff bars show everything Blizzard provides -- no filtering.
                if not isBuff and spellList and #spellList > 0 then
                    local allowSet = _scratch_allowSet; wipe(allowSet)
                    for _, sid in ipairs(spellList) do
                        if sid and sid > 0 then
                            allowSet[sid] = true
                            if _FindOverride then
                                local ovr = _FindOverride(sid)
                                if ovr and ovr > 0 then allowSet[ovr] = true end
                            end
                            local nm = C_Spell.GetSpellName(sid)
                            if nm then allowSet[nm] = true end
                        end
                    end
                    local filtered = _scratch_filtered; wipe(filtered)
                    for _, entry in ipairs(list) do
                        local pass = allowSet[entry.spellID] or allowSet[entry.baseSpellID]
                        if not pass then
                            local nm = C_Spell.GetSpellName(entry.spellID)
                            if nm and allowSet[nm] then pass = true end
                        end
                        if pass then filtered[#filtered + 1] = entry end
                    end
                    list = filtered
                end

                -- Inject custom frames (trinkets, racials, items, custom buffs)
                -- Buff bars never inject -- they only show Blizzard-provided frames.
                local isCustomBuff = (barType == "custom_buff")
                if spellList and not isBuff then
                    for _, sid in ipairs(spellList) do
                        if sid and (sid == -13 or sid == -14) then
                            local slot = -sid
                            local tf = _trinketFrames[slot]
                            if not tf then tf = GetOrCreateTrinketFrame(slot); UpdateTrinketFrame(slot) end
                            if _trinketItemCache[slot] and tf._trinketIsOnUse then
                                UpdateTrinketCooldown(slot)
                                DecorateFrame(tf, barData)
                                tf:Show()
                                list[#list + 1] = AcquireEntry(tf, sid, sid, spellOrder[sid] or 99999)
                            else
                                tf:Hide()
                            end
                        elseif sid and sid <= -100 then
                            local itemID = -sid
                            local fkey = barKey .. ":item:" .. itemID
                            local f = _presetFrames[fkey]
                            if not f then
                                local itemPresets = ns.CDM_ITEM_PRESETS
                                local preset
                                if itemPresets then
                                    for _, pr in ipairs(itemPresets) do
                                        if pr.itemID == itemID then preset = pr; break end
                                        if pr.altItemIDs then
                                            for _, alt in ipairs(pr.altItemIDs) do
                                                if alt == itemID then preset = pr; break end
                                            end
                                        end
                                    end
                                end
                                local icon = preset and preset.icon or C_Item.GetItemIconByID(itemID)
                                if icon then
                                    f = CreateFrame("Frame", nil, UIParent)
                                    f:SetSize(36, 36); f:Hide()
                                    local tex = f:CreateTexture(nil, "ARTWORK")
                                    tex:SetAllPoints(); tex:SetTexture(icon)
                                    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                                    f.Icon = tex; f._tex = tex
                                    local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
                                    cd:SetAllPoints(); cd:SetDrawEdge(false); cd:SetDrawBling(false)
                                    cd:SetHideCountdownNumbers(true)
                                    f.Cooldown = cd; f._cooldown = cd
                                    f._isItemPresetFrame = true
                                    f._presetItemID = itemID; f._presetData = preset
                                    f.cooldownID = nil; f.cooldownInfo = nil
                                    f.layoutIndex = 99999
                                    local countFS = f:CreateFontString(nil, "OVERLAY")
                                    countFS:SetFont(GetCDMFont(), 11, "OUTLINE")
                                    countFS:SetShadowOffset(0, 0)
                                    countFS:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 2)
                                    f._itemCountText = countFS
                                    _presetFrames[fkey] = f
                                end
                            end
                            if f then
                                local getContainerCD = C_Container and C_Container.GetItemCooldown
                                local start, dur, enable
                                if getContainerCD then
                                    start, dur, enable = getContainerCD(itemID)
                                end
                                if not (start and dur and dur > 1.5) then
                                    start, dur, enable = C_Item.GetItemCooldown(itemID)
                                end
                                if not (start and dur and dur > 1.5) and f._presetData and f._presetData.altItemIDs then
                                    for _, altID in ipairs(f._presetData.altItemIDs) do
                                        if getContainerCD then
                                            start, dur, enable = getContainerCD(altID)
                                        end
                                        if not (start and dur and dur > 1.5) then
                                            start, dur, enable = C_Item.GetItemCooldown(altID)
                                        end
                                        if start and dur and dur > 1.5 then break end
                                    end
                                end
                                if start and dur and dur > 1.5 and enable then
                                    f._cooldown:SetCooldown(start, dur)
                                    f._cdStart = start; f._cdDur = dur
                                elseif f._cdStart and f._cdDur and (GetTime() < f._cdStart + f._cdDur) then
                                    -- keep cached cooldown
                                else
                                    f._cooldown:Clear()
                                    f._cdStart = nil; f._cdDur = nil
                                end
                                if f._presetData and (f._presetData.key == "healthstone" or f._presetData.key == "demonic_healthstone") then
                                    local inBags = C_Item.GetItemCount(itemID) > 0
                                    if not inBags and f._presetData.altItemIDs then
                                        for _, altID in ipairs(f._presetData.altItemIDs) do
                                            if C_Item.GetItemCount(altID) > 0 then inBags = true; break end
                                        end
                                    end
                                    if f._tex then f._tex:SetDesaturated(not inBags) end
                                end
                                if f._itemCountText then
                                    local total = C_Item.GetItemCount(itemID) or 0
                                    if f._presetData and f._presetData.altItemIDs then
                                        for _, altID in ipairs(f._presetData.altItemIDs) do
                                            total = total + (C_Item.GetItemCount(altID) or 0)
                                        end
                                    end
                                    if total > 1 then
                                        f._itemCountText:SetText(total)
                                        f._itemCountText:Show()
                                    else
                                        f._itemCountText:SetText("")
                                        f._itemCountText:Hide()
                                    end
                                    if f._tex then f._tex:SetDesaturated(total == 0) end
                                end
                                DecorateFrame(f, barData); f:Show()
                                list[#list + 1] = AcquireEntry(f, sid, sid, spellOrder[sid] or 99999)
                            end
                        elseif sid and sid > 0 then
                            local hasClaim = false
                            if not isCustomBuff then
                                for _, e in ipairs(list) do
                                    if e.spellID == sid or e.baseSpellID == sid then hasClaim = true; break end
                                end
                            end
                            if not hasClaim then
                                if isCustomBuff then
                                    local euiOpen = EllesmereUI._mainFrame and EllesmereUI._mainFrame:IsShown()
                                    local aura = C_UnitAuras.GetPlayerAuraBySpellID(sid)
                                    if not aura and sd and sd.presetVariants and sd.presetVariants[sid] then
                                        for _, varSid in ipairs(sd.presetVariants[sid]) do
                                            aura = C_UnitAuras.GetPlayerAuraBySpellID(varSid)
                                            if aura then break end
                                        end
                                    end
                                    if not aura and not euiOpen then
                                        local fkey = barKey .. ":custombuff:" .. sid
                                        local f = _presetFrames[fkey]
                                        if f then f:Hide() end
                                    else
                                        local fkey = barKey .. ":custombuff:" .. sid
                                        local f = _presetFrames[fkey]
                                        if not f then
                                            f = CreateFrame("Frame", nil, UIParent)
                                            f:SetSize(36, 36); f:Hide()
                                            local tex = f:CreateTexture(nil, "ARTWORK")
                                            tex:SetAllPoints(); tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                                            f.Icon = tex; f._tex = tex
                                            local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
                                            cd:SetAllPoints(); cd:SetDrawEdge(false); cd:SetDrawBling(false)
                                            cd:SetHideCountdownNumbers(true); cd:SetReverse(true)
                                            f.Cooldown = cd; f._cooldown = cd
                                            f._isCustomSpellFrame = true
                                            f.cooldownID = nil; f.cooldownInfo = nil
                                            f.layoutIndex = 99999
                                            _presetFrames[fkey] = f
                                            local spInfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
                                            if spInfo and spInfo.iconID and f._tex then f._tex:SetTexture(spInfo.iconID) end
                                        end
                                        if aura and aura.duration and aura.duration > 0 and aura.expirationTime then
                                            local aStart = aura.expirationTime - aura.duration
                                            f._cooldown:SetCooldown(aStart, aura.duration)
                                        else
                                            f._cooldown:Clear()
                                        end
                                        DecorateFrame(f, barData); f:Show()
                                        list[#list + 1] = AcquireEntry(f, sid, sid, spellOrder[sid] or 99999)
                                    end
                                else
                                    -- Skip spells the player doesn't currently know (e.g. talented out)
                                    local isRacial = ns._myRacialsSet and ns._myRacialsSet[sid]
                                    if not isRacial and ns.IsSpellKnownInCDM and not ns.IsSpellKnownInCDM(sid) then
                                        -- pass: don't inject frame for unknown spell
                                    else
                                    local fkey = barKey .. ":" .. (isRacial and "racial" or "custom") .. ":" .. sid
                                    local f = _presetFrames[fkey]
                                    if not f then
                                        f = CreateFrame("Frame", nil, UIParent)
                                        f:SetSize(36, 36); f:Hide()
                                        local tex = f:CreateTexture(nil, "ARTWORK")
                                        tex:SetAllPoints(); tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                                        f.Icon = tex; f._tex = tex
                                        local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
                                        cd:SetAllPoints(); cd:SetDrawEdge(false); cd:SetDrawBling(false)
                                        cd:SetHideCountdownNumbers(true)
                                        f.Cooldown = cd; f._cooldown = cd
                                        f._isRacialFrame = isRacial or nil
                                        f._isCustomSpellFrame = not isRacial or nil
                                        f.cooldownID = nil; f.cooldownInfo = nil
                                        f.layoutIndex = 99999
                                        _presetFrames[fkey] = f
                                    end
                                    local spInfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
                                    if spInfo and spInfo.iconID and f._tex then f._tex:SetTexture(spInfo.iconID) end
                                    if not f._cdSet or f._racialCdDirty then
                                        local durObj = C_Spell.GetSpellCooldownDuration and C_Spell.GetSpellCooldownDuration(sid)
                                        if durObj and f._cooldown.SetCooldownFromDurationObject then
                                            f._cooldown:SetCooldownFromDurationObject(durObj, true)
                                        end
                                        f._cdSet = true; f._racialCdDirty = false
                                    end
                                    DecorateFrame(f, barData); f:Show()
                                    list[#list + 1] = AcquireEntry(f, sid, sid, spellOrder[sid] or 99999)
                                end
                            end
                                    end -- IsSpellKnownInCDM check
                        end
                    end
                end

                -- Sort: buff bars use Blizzard's layoutIndex, CD/utility use spellOrder
                if isBuff then
                    table.sort(list, _sortByLayoutIndex)
                else
                    table.sort(list, _sortBySpellOrder)
                end

                -- Assign to icon slots
                local icons = cdmBarIcons[barKey]
                if not icons then icons = {}; cdmBarIcons[barKey] = icons end
                local count = 0
                local usedFrames = _scratch_usedFrames

                if not isBuff and spellList and #spellList > 0 then
                    -- CD/utility: assign in spellList order (matching by ID/name)
                    local entryBySpell = _scratch_entryBySpell; wipe(entryBySpell)
                    for _, entry in ipairs(list) do
                        if entry.spellID and not entryBySpell[entry.spellID] then entryBySpell[entry.spellID] = entry end
                        if entry.baseSpellID and not entryBySpell[entry.baseSpellID] then entryBySpell[entry.baseSpellID] = entry end
                        local nm = C_Spell.GetSpellName(entry.spellID)
                        if nm and not entryBySpell[nm] then entryBySpell[nm] = entry end
                    end
                    for _, sid in ipairs(spellList) do
                        if sid and sid ~= 0 then
                            local entry = entryBySpell[sid]
                            if not entry and sid > 0 and _FindOverride then
                                local ovr = _FindOverride(sid)
                                if ovr and ovr > 0 then entry = entryBySpell[ovr] end
                            end
                            if not entry and sid > 0 and C_Spell.GetBaseSpell then
                                local base = C_Spell.GetBaseSpell(sid)
                                if base and base > 0 and base ~= sid then entry = entryBySpell[base] end
                            end
                            if not entry and sid > 0 then
                                local nm = C_Spell.GetSpellName(sid)
                                if nm then entry = entryBySpell[nm] end
                            end
                            if entry and not usedFrames[entry.frame] then
                                count = count + 1
                                local frame = entry.frame
                                usedFrames[frame] = true
                                DecorateFrame(frame, barData)
                                FC(frame).barKey = barKey
                                FC(frame).spellID = entry.baseSpellID or entry.spellID
                                icons[count] = frame
                                local barHidden = container and container._visHidden
                                frame:SetAlpha(barHidden and 0 or 1)
                                frame:Show()
                                if frame.Cooldown and frame.Cooldown.SetDrawSwipe then
                                    frame.Cooldown:SetDrawSwipe(true)
                                end
                                -- Reparent custom frames (trinkets, racials, etc.)
                                -- to our container. Never parent to Blizzard viewers
                                -- as that taints the secure frame tree.
                                if frame._isRacialFrame or frame._isTrinketFrame
                                    or frame._isPresetFrame or frame._isItemPresetFrame
                                    or frame._isCustomSpellFrame then
                                    if frame:GetParent() ~= container then
                                        frame:SetParent(container)
                                    end
                                end
                            end
                        end
                    end
                else
                    -- Buff bars: assign in list order (Blizzard's layoutIndex).
                    -- No spellList matching, no filtering. Just take everything.
                    for _, entry in ipairs(list) do
                        count = count + 1
                        local frame = entry.frame
                        usedFrames[frame] = true
                        DecorateFrame(frame, barData)
                        FC(frame).barKey = barKey
                        FC(frame).spellID = entry.baseSpellID or entry.spellID
                        icons[count] = frame
                        local barHidden = container and container._visHidden
                        frame:SetAlpha(barHidden and 0 or 1)
                        frame:Show()
                        if frame.Cooldown and frame.Cooldown.SetDrawSwipe then
                            frame.Cooldown:SetDrawSwipe(true)
                        end
                        -- Kill any stale untracked overlay on buff bar frames
                        local ov = frame._untrackedOverlay
                        if not ov then
                            local fd = hookFrameData[frame]
                            ov = fd and fd.untrackedOverlay
                        end
                        if ov then ov:Hide() end
                    end
                end

                -- Clear excess icons. Buff frames: Blizzard owns their
                -- lifecycle, only disable swipe. CD/utility: hide.
                for i = count + 1, #icons do
                    local icon = icons[i]
                    if icon then
                        -- Clear stored anchor so SetPoint hook stops intercepting
                        local efd = hookFrameData[icon]
                        if efd then efd._cdmAnchor = nil end
                        if isBuff then
                            if icon.Cooldown and icon.Cooldown.SetDrawSwipe then
                                icon.Cooldown:SetDrawSwipe(false)
                            end
                        else
                            icon:ClearAllPoints()
                            icon:Hide()
                            if icon.Cooldown and icon.Cooldown.SetDrawSwipe then
                                icon.Cooldown:SetDrawSwipe(false)
                            end
                        end
                    end
                    icons[i] = nil
                end

                -- Mark unclaimed frames as used so the alpha-0 cleanup
                -- doesn't hide them. Blizzard controls twin-frame visibility
                -- during spell transforms (e.g. Wings → Sentinel).
                for _, entry in ipairs(list) do
                    if entry.frame and not usedFrames[entry.frame] then
                        usedFrames[entry.frame] = true
                    end
                end

                -- Only refresh/layout if icon set changed
                local prevCount = container._prevVisibleCount or 0
                local iconsChanged = count ~= prevCount
                if not iconsChanged and container._prevIconRefs then
                    for idx = 1, count do
                        if container._prevIconRefs[idx] ~= icons[idx] then
                            iconsChanged = true; break
                        end
                    end
                else
                    iconsChanged = true
                end
                if iconsChanged then
                    if RefreshCDMIconAppearance then RefreshCDMIconAppearance(barKey) end
                    if LayoutCDMBar then LayoutCDMBar(barKey) end
                    if ApplyCDMTooltipState then ApplyCDMTooltipState(barKey) end
                    if not container._prevIconRefs then container._prevIconRefs = {} end
                    for idx = 1, count do container._prevIconRefs[idx] = icons[idx] end
                    for idx = count + 1, #container._prevIconRefs do container._prevIconRefs[idx] = nil end
                end
                container._prevVisibleCount = count
            end
        end
    end

    -- Clean up empty bars
    for _, bd in ipairs(p.cdmBars.bars) do
        if bd.enabled and not barLists[bd.key] then
            local isBuff_cleanup = (bd.barType == "buffs" or bd.key == "buffs")
            local icons = cdmBarIcons[bd.key]
            if icons then
                for i = 1, #icons do
                    if icons[i] then
                        local efd = hookFrameData[icons[i]]
                        if efd then efd._cdmAnchor = nil end
                        if isBuff_cleanup then
                            -- Buff: only disable swipe, Blizzard owns the rest
                            if icons[i].Cooldown and icons[i].Cooldown.SetDrawSwipe then
                                icons[i].Cooldown:SetDrawSwipe(false)
                            end
                        else
                            icons[i]:ClearAllPoints()
                            icons[i]:Hide()
                            if icons[i].Cooldown and icons[i].Cooldown.SetDrawSwipe then
                                icons[i].Cooldown:SetDrawSwipe(false)
                            end
                        end
                    end
                    icons[i] = nil
                end
            end
            local container = cdmBarFrames[bd.key]
            if container and (container._prevVisibleCount or 0) > 0 then
                container._prevVisibleCount = 0
                if LayoutCDMBar then LayoutCDMBar(bd.key) end
            end
        end
    end

    -- 5. Cleanup unclaimed frames.
    -- Buff frames: Blizzard fully owns their lifecycle. Only disable the
    -- swipe to prevent ghost swipe artifacts. Never ClearAllPoints, SetAlpha,
    -- or Hide -- Blizzard needs the frame intact to re-show on aura updates.
    -- CD/utility frames: we own these, hide immediately.
    local buffViewer = _G["BuffIconCooldownViewer"]
    local barViewer  = _G["BuffBarCooldownViewer"]
    for frame in pairs(allActiveFrames) do
        if _scratch_usedFrames[frame] then
            -- Claimed: leave alone
        elseif frame._isRacialFrame or frame._isTrinketFrame
               or frame._isPresetFrame or frame._isItemPresetFrame
               or frame._isCustomSpellFrame then
            -- Custom frames: managed by their own systems
        else
            -- Clear stored anchor so SetPoint hook stops intercepting
            local efd = hookFrameData[frame]
            if efd then efd._cdmAnchor = nil end
            local vf = frame.viewerFrame
            if vf == buffViewer or vf == barViewer then
                -- Buff frame: only disable swipe, touch nothing else
                if frame.Cooldown and frame.Cooldown.SetDrawSwipe then
                    frame.Cooldown:SetDrawSwipe(false)
                end
            else
                frame:ClearAllPoints()
                frame:Hide()
                if frame.Cooldown and frame.Cooldown.SetDrawSwipe then
                    frame.Cooldown:SetDrawSwipe(false)
                end
            end
        end
    end

    if not ns._initialReanchorDone then ns._initialReanchorDone = true end

    if ns.UpdateOverlayVisuals then ns.UpdateOverlayVisuals() end
    ns.RefreshAllOverlays()
    MemDelta("ProcessBars")
    MemReport()
end
ns.CollectAndReanchor = CollectAndReanchor

-------------------------------------------------------------------------------
--  UpdateCustomBuffBars
--  Custom Aura bars use UNIT_SPELLCAST_SUCCEEDED to detect usage,
--  then show icon with hardcoded duration (reverse cooldown swipe).
-------------------------------------------------------------------------------
local _customAuraTimers = {}

local function UpdateCustomBuffBars()
    -- if CooldownViewerSettings and CooldownViewerSettings:IsShown() then return end
    local p = ECME.db and ECME.db.profile
    if not p or not p.cdmBars or not p.cdmBars.bars then return end
    local LayoutCDMBar = ns.LayoutCDMBar
    local RefreshCDMIconAppearance = ns.RefreshCDMIconAppearance
    local euiOpen = EllesmereUI._mainFrame and EllesmereUI._mainFrame:IsShown()
    local now = GetTime()

    for _, barData in ipairs(p.cdmBars.bars) do
        if barData.enabled and barData.barType == "custom_buff" then
            local barKey = barData.key
            local container = cdmBarFrames[barKey]
            if container then
                local sd = ns.GetBarSpellData(barKey)
                local spellList = sd and sd.assignedSpells or {}
                local icons = cdmBarIcons[barKey]
                if not icons then icons = {}; cdmBarIcons[barKey] = icons end
                local count = 0

                for _, sid in ipairs(spellList) do
                    if type(sid) == "number" and sid > 0 then
                        local duration = sd.spellDurations and sd.spellDurations[sid] or 0
                        if duration > 0 then
                            local timerKey = barKey .. ":" .. sid
                            local timer = _customAuraTimers[timerKey]

                            if _pendingCastIDs[sid] and duration > 0 then
                                _customAuraTimers[timerKey] = {
                                    start = now,
                                    duration = duration,
                                }
                                timer = _customAuraTimers[timerKey]
                            end

                            local isActive = timer and duration > 0
                                and (now - timer.start) < timer.duration

                            if isActive or euiOpen then
                                local fkey = barKey .. ":custombuff:" .. sid
                                local f = _presetFrames[fkey]
                                if not f then
                                    f = CreateFrame("Frame", nil, UIParent)
                                    f:SetSize(36, 36); f:Hide()
                                    local tex = f:CreateTexture(nil, "ARTWORK")
                                    tex:SetAllPoints(); tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                                    f.Icon = tex; f._tex = tex
                                    local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
                                    cd:SetAllPoints(); cd:SetDrawEdge(false); cd:SetDrawBling(false)
                                    cd:SetHideCountdownNumbers(not barData.showCooldownText)
                                    cd:SetReverse(true)
                                    f.Cooldown = cd; f._cooldown = cd
                                    f._isCustomSpellFrame = true
                                    f._isCustomBuffFrame = true
                                    f.cooldownID = nil; f.cooldownInfo = nil
                                    f.layoutIndex = 99999
                                    _presetFrames[fkey] = f
                                    cd:HookScript("OnCooldownDone", function()
                                        C_Timer.After(0, QueueCustomBuffUpdate)
                                    end)
                                    local spInfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
                                    if spInfo and spInfo.iconID and f._tex then f._tex:SetTexture(spInfo.iconID) end
                                end
                                if isActive then
                                    f._cooldown:SetCooldown(timer.start, timer.duration)
                                else
                                    f._cooldown:Clear()
                                end
                                DecorateFrame(f, barData); f:Show()
                                count = count + 1
                                icons[count] = f
                            else
                                local fkey = barKey .. ":custombuff:" .. sid
                                local f = _presetFrames[fkey]
                                if f then f:Hide() end
                                if timer and not isActive then
                                    _customAuraTimers[timerKey] = nil
                                end
                            end
                        end
                    end
                end

                for i = count + 1, #icons do
                    if icons[i] then icons[i]:Hide() end
                    icons[i] = nil
                end

                local prevCount = container._prevVisibleCount or 0
                if count ~= prevCount then
                    if RefreshCDMIconAppearance then RefreshCDMIconAppearance(barKey) end
                    if LayoutCDMBar then LayoutCDMBar(barKey) end
                end
                container._prevVisibleCount = count
            end
        end
    end
    wipe(_pendingCastIDs)
end
ns.UpdateCustomBuffBars = UpdateCustomBuffBars

function ns.UpdateCustomBuffAuraTracking() end

-------------------------------------------------------------------------------
--  RefreshAllOverlays
-------------------------------------------------------------------------------
function ns.RefreshAllOverlays()
    local p = ECME.db and ECME.db.profile
    if not p or not p.cdmBars then return end
    local ApplyOverlay = ns.ApplyUntrackedOverlay
    if not ApplyOverlay then return end

    for _, barData in ipairs(p.cdmBars.bars) do
        if barData.enabled then
            local icons = cdmBarIcons[barData.key]
            if icons then
                local barType = barData.barType or barData.key
                local isBuff = (barType == "buffs")
                -- Buff bars: no overlays. They only contain tracked CDM buffs.
                if isBuff then
                    for _, icon in ipairs(icons) do
                        ApplyOverlay(icon, false)
                    end
                else
                    for _, icon in ipairs(icons) do
                        if icon._isRacialFrame or icon._isTrinketFrame
                           or icon._isPresetFrame or icon._isItemPresetFrame
                           or icon._isCustomSpellFrame then
                            ApplyOverlay(icon, false)
                        else
                            local fc = _ecmeFC[icon]
                            local sid = fc and fc.spellID
                            if sid and sid > 0 then
                                local untracked = not _cdUtilTrackedSet[sid]
                                -- Skip overlay for untalented spells
                                if untracked and not IsSpellKnown(sid) then
                                    untracked = false
                                end
                                ApplyOverlay(icon, untracked)
                            end
                        end
                    end
                end
            end
        end
    end

    -- TBB overlays: cache lookup (rebuilt at top of reanchor, always fresh here)
    local ShowTBB = ns.ShowTBBUntrackedOverlay
    local HideTBB = ns.HideTBBUntrackedOverlay
    if ShowTBB and HideTBB then
        local tbb = ns.GetTrackedBuffBars and ns.GetTrackedBuffBars()
        local bars = tbb and tbb.bars
        if bars then
            for i, cfg in ipairs(bars) do
                local bar = ns.GetTBBFrame and ns.GetTBBFrame(i)
                if bar and cfg.enabled ~= false then
                    local hasSpell = (cfg.spellID and cfg.spellID > 0) or (cfg.spellIDs and #cfg.spellIDs > 0)
                    local isNonCDM = false
                    if cfg.spellID and cfg.spellID > 0 then
                        isNonCDM = (ns._myRacialsSet and ns._myRacialsSet[cfg.spellID])
                    end
                    if hasSpell and not cfg.popularKey and not isNonCDM then
                        local tracked = false
                        if cfg.spellIDs then
                            for _, sid in ipairs(cfg.spellIDs) do
                                if _barViewerCache[sid] then tracked = true; break end
                            end
                        elseif cfg.spellID and cfg.spellID > 0 then
                            tracked = _barViewerCache[cfg.spellID]
                        end
                        if not tracked then
                            -- Don't show overlay for untalented spells -- the user
                            -- can't add them to tracked bars, so the overlay is misleading.
                            local isUnlearned = false
                            if cfg.spellID and cfg.spellID > 0 then
                                isUnlearned = not IsSpellKnown(cfg.spellID)
                            end
                            if isUnlearned then
                                HideTBB(bar)
                            else
                                ShowTBB(bar, cfg)
                            end
                        else
                            HideTBB(bar)
                        end
                    else
                        HideTBB(bar)
                    end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
--  Lightweight position re-snap: re-applies stored _cdmAnchor on all claimed
--  icons without re-enumerating viewers or re-categorizing frames.
--  Used by OnActiveStateChanged where Blizzard may move frames but the icon
--  list hasn't changed.
-------------------------------------------------------------------------------
local function ReapplyPositions()
    for barKey, icons in pairs(cdmBarIcons) do
        if icons then
            for i = 1, #icons do
                local frame = icons[i]
                if frame then
                    local fd = hookFrameData[frame]
                    local anchor = fd and fd._cdmAnchor
                    if anchor then
                        frame:ClearAllPoints()
                        frame:SetPoint(anchor[1], anchor[2], anchor[3], anchor[4], anchor[5])
                    end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
--  Reanchor Queue
-------------------------------------------------------------------------------
local REANCHOR_THROTTLE = 0.2
local _lastReanchorTime = 0

local function QueueReanchor()
    if ns._specChangePending then return end
    reanchorDirty = true
    if reanchorFrame then reanchorFrame:Show() end
end
ns.QueueReanchor = QueueReanchor

local function ProcessReanchorQueue(self)
    if not reanchorDirty then self:Hide(); return end
    local now = GetTime()
    if now - _lastReanchorTime < REANCHOR_THROTTLE then return end
    reanchorDirty = false
    _lastReanchorTime = now
    CollectAndReanchor()
end

-------------------------------------------------------------------------------
--  SetupViewerHooks (mixin hooks)
--
--  Hook strategy:
--    1. OnCooldownIDSet on all 4 Blizzard CDM mixins -> QueueReanchor
--    2. Pool Acquire on all viewers -> QueueReanchor
--    3. Viewer Layout -> QueueReanchor (catches frame removals)
--    4. Buff ticker (0.1s) for staleness + glow
-------------------------------------------------------------------------------
function ns.SetupViewerHooks()
    if viewerHooksInstalled then return end
    viewerHooksInstalled = true

    -- Reanchor queue frame
    reanchorFrame = CreateFrame("Frame")
    reanchorFrame:SetScript("OnUpdate", ProcessReanchorQueue)
    reanchorFrame:Hide()

    -- 1. Mixin hooks: detect spell changes on CDM frames.
    --    Reset frame spell cache so the next reanchor re-resolves the spellID
    --    (handles spell transforms like Avenging Crusader -> Crusader Strike).
    local function ResetFrameAndReanchor(frame)
        if ns._specChangePending then return end
        if frame then
            local fc = _ecmeFC[frame]
            if fc then
                fc.resolvedSid = nil
                fc.baseSpellID = nil
                fc.overrideSid = nil
                fc.cachedCdID = nil
            end
            -- Don't clear fd.decorated or _cdidRouteMap here.
            -- Decoration only needs to happen once per frame.
            -- The cdidRouteMap entry is still valid (cooldownID doesn't
            -- change on transforms, only the spell behind it changes).
            -- CategorizeFrame will re-resolve the spell via baseSID.
        end
        QueueReanchor()
    end
    if CooldownViewerBuffIconItemMixin and CooldownViewerBuffIconItemMixin.OnCooldownIDSet then
        hooksecurefunc(CooldownViewerBuffIconItemMixin, "OnCooldownIDSet", ResetFrameAndReanchor)
    end
    if CooldownViewerEssentialItemMixin and CooldownViewerEssentialItemMixin.OnCooldownIDSet then
        hooksecurefunc(CooldownViewerEssentialItemMixin, "OnCooldownIDSet", ResetFrameAndReanchor)
    end
    if CooldownViewerUtilityItemMixin and CooldownViewerUtilityItemMixin.OnCooldownIDSet then
        hooksecurefunc(CooldownViewerUtilityItemMixin, "OnCooldownIDSet", ResetFrameAndReanchor)
    end
    if CooldownViewerBuffBarItemMixin and CooldownViewerBuffBarItemMixin.OnCooldownIDSet then
        hooksecurefunc(CooldownViewerBuffBarItemMixin, "OnCooldownIDSet", function(frame)
            if ns.InvalidateTBBFrameCache then ns.InvalidateTBBFrameCache() end
            ResetFrameAndReanchor(frame)
        end)
    end

    -- 2. Pool acquire hooks: detect new frames + install per-frame hooks
    -- Track which frames have been hooked (weak-keyed, no taint)
    local _activeStateHooked = setmetatable({}, { __mode = "k" })
    local _activeStateReanchorPending = false

    local function InstallBuffFrameHooks(viewer)
        if not viewer or not viewer.itemFramePool then return end
        for frame in viewer.itemFramePool:EnumerateActive() do
            if not _activeStateHooked[frame] then
                _activeStateHooked[frame] = true
                -- Hook OnActiveStateChanged: Blizzard calls this when a buff
                -- becomes active/inactive. Run a full reanchor so new/removed
                -- icons get collected and centered. Batched via C_Timer to
                -- collapse the spam (fires many times per frame).
                if frame.OnActiveStateChanged then
                    hooksecurefunc(frame, "OnActiveStateChanged", function()
                        ReapplyPositions()
                        if _activeStateReanchorPending then return end
                        _activeStateReanchorPending = true
                        C_Timer.After(0, function()
                            _activeStateReanchorPending = false
                            CollectAndReanchor()
                        end)
                    end)
                end
            end
        end
    end

    for vi, vName in ipairs(VIEWER_NAMES) do
        local v = _G[vName]
        if v and v.itemFramePool then
            local isBuff = (vi == 3 or vi == 4) -- BuffIcon or BuffBar
            local isBarViewer = (vi == 4) -- BuffBarCooldownViewer
            hooksecurefunc(v.itemFramePool, "Acquire", function()
                if isBuff then InstallBuffFrameHooks(v) end
                if isBarViewer and ns.InvalidateTBBFrameCache then
                    ns.InvalidateTBBFrameCache()
                end
                QueueReanchor()
            end)
            -- Hook existing frames too
            if isBuff then InstallBuffFrameHooks(v) end

            -- Intercept newly acquired frames the instant Blizzard creates
            -- them, before they render at the viewer's default position.
            -- Alpha 0 until our reanchor claims and positions them.
            -- Skip during init: on /reload ALL frames are acquired at once
            -- and our reanchor hasn't run yet, so blanking them would hide
            -- all buffs until the first buff change.
            if v.OnAcquireItemFrame then
                hooksecurefunc(v, "OnAcquireItemFrame", function(_, itemFrame)
                    if not ns._initialReanchorDone then return end
                    if itemFrame then
                        itemFrame:SetAlpha(0)
                        if itemFrame.Cooldown and itemFrame.Cooldown.SetDrawSwipe then
                            itemFrame.Cooldown:SetDrawSwipe(false)
                        end
                    end
                end)
            end
        end
    end

    -- 3. Viewer Layout hooks (Essential + Utility only).
    -- Buff viewers are dynamic and positioned per-frame by CollectAndReanchor;
    -- hooking Layout on them causes taint when Blizzard calls it internally.
    local SYNC_VIEWERS = {
        EssentialCooldownViewer = "cooldowns",
        UtilityCooldownViewer   = "utility",
    }
    for viewerName, barKey in pairs(SYNC_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            if viewer.RefreshLayout then
                hooksecurefunc(viewer, "RefreshLayout", function()
                    QueueReanchor()
                end)
            end
            -- Re-apply our icon positions immediately when Blizzard
            -- re-layouts so frames don't flash to Blizzard positions.
            -- Re-layout ALL bars (including custom bars that share this viewer).
            hooksecurefunc(viewer, "Layout", function()
                local LCB = ns.LayoutCDMBar
                if LCB then
                    for bk, icons in pairs(cdmBarIcons) do
                        if icons and #icons > 0 then
                            LCB(bk)
                        end
                    end
                end
            end)
            local function SyncViewerToBar()
                if InCombatLockdown() then return end
                local container = cdmBarFrames[barKey]
                if not container then return end
                viewer:ClearAllPoints()
                viewer:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
                viewer:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
            end
            hooksecurefunc(viewer, "Layout", SyncViewerToBar)
            hooksecurefunc(viewer, "SetPoint", function(_, _, relativeTo)
                if InCombatLockdown() then return end
                local container = cdmBarFrames[barKey]
                if relativeTo == container then return end
                SyncViewerToBar()
            end)
            SyncViewerToBar()
        end
    end

    -- 3b. Buff viewer RefreshLayout hooks: run an IMMEDIATE reanchor (not
    -- queued) so icons are repositioned before the frame renders. Without
    -- this, new buff icons flash at Blizzard's default viewer position for
    -- up to 0.2s until the throttled reanchor fires.
    local buffViewer = _G["BuffIconCooldownViewer"]
    if buffViewer and buffViewer.RefreshLayout then
        hooksecurefunc(buffViewer, "RefreshLayout", function()
            if ns._specChangePending then return end
            CollectAndReanchor()
        end)
    end
    local buffBarViewer = _G["BuffBarCooldownViewer"]
    if buffBarViewer and buffBarViewer.RefreshLayout then
        hooksecurefunc(buffBarViewer, "RefreshLayout", function()
            if ns._specChangePending then return end
            CollectAndReanchor()
        end)
    end

    -- 4. CooldownViewerSettings show/hide: force reanchor.
    -- When CDM settings panel closes, Blizzard may re-layout its viewers.
    -- Queue a reanchor to re-sync our bar positions.
    if EventRegistry and EventRegistry.RegisterCallback then
        local cdmSettingsOwner = {}
        EventRegistry:RegisterCallback("CooldownViewerSettings.OnShow",
            QueueReanchor, cdmSettingsOwner)
        EventRegistry:RegisterCallback("CooldownViewerSettings.OnHide", function()
            C_Timer.After(0.1, QueueReanchor)
        end, cdmSettingsOwner)
    end

    -- 4b. Delayed reanchor on load: catch frames created after initial setup.
    -- Some buff frames (e.g. Dread Plague) may not exist until Blizzard's
    -- viewer finishes its deferred layout pass. Also invalidate TBB cache
    -- so tracking bars re-scan for late-loading BuffBar viewer frames.
    local function DelayedFullRefresh()
        if ns.InvalidateTBBFrameCache then ns.InvalidateTBBFrameCache() end
        QueueReanchor()
    end
    C_Timer.After(1, DelayedFullRefresh)
    C_Timer.After(3, DelayedFullRefresh)
    C_Timer.After(6, DelayedFullRefresh)

    -- 5. Buff ticker: staleness check + buff/pandemic glow (0.1s)
    do
        local cdmBuffTickFrame = CreateFrame("Frame")
        local cdmBuffAccum = 0
        cdmBuffTickFrame:SetScript("OnUpdate", function(_, elapsed)
            cdmBuffAccum = cdmBuffAccum + elapsed
            if cdmBuffAccum < 0.1 then return end
            cdmBuffAccum = 0
            MemSnap("BuffTicker")
            local p = ECME and ECME.db and ECME.db.profile
            if not p or not p.cdmBars or not p.cdmBars.bars then return end
            local needsReanchor = false
            for _, bd in ipairs(p.cdmBars.bars) do
                if bd.enabled then
                    local isBuff = (bd.barType == "buffs" or bd.key == "buffs")
                    local icons = cdmBarIcons[bd.key]
                    if icons then
                        for fi = 1, #icons do
                            local frame = icons[fi]
                            if frame and frame:IsShown() then
                                local fc = _ecmeFC[frame]
                                local sid = fc and fc.resolvedSid
                                local fd = hookFrameData[frame]

                                -- Buff glow
                                local buffGlowType = isBuff and (bd.buffGlowType or 0) or 0
                                if buffGlowType > 0 and fd then
                                    if not fd.buffGlowActive then
                                        if not fd.buffGlowOverlay then
                                            local ov = CreateFrame("Frame", nil, frame)
                                            ov:SetAllPoints(frame)
                                            ov:SetFrameLevel(frame:GetFrameLevel() + 7)
                                            ov:EnableMouse(false)
                                            fd.buffGlowOverlay = ov
                                        end
                                        local cr, cg, cb = bd.buffGlowR or 1.0, bd.buffGlowG or 0.776, bd.buffGlowB or 0.376
                                        if bd.buffGlowClassColor then
                                            local _, ct = UnitClass("player")
                                            if ct then
                                                local cc = RAID_CLASS_COLORS[ct]
                                                if cc then cr, cg, cb = cc.r, cc.g, cc.b end
                                            end
                                        end
                                        fd.buffGlowOverlay:SetAlpha(1)
                                        ns.StartNativeGlow(fd.buffGlowOverlay, buffGlowType, cr, cg, cb)
                                        fd.buffGlowActive = true
                                    end
                                elseif fd and fd.buffGlowActive and fd.buffGlowOverlay then
                                    ns.StopNativeGlow(fd.buffGlowOverlay)
                                    fd.buffGlowActive = false
                                end

                                -- Pandemic glow
                                if bd.pandemicGlow and sid and sid > 0 and fd then
                                    -- Check our own detection + Blizzard's native
                                    -- PandemicIcon (covers debuffs on target)
                                    local inPandemic = ns.IsInPandemicWindow(sid)
                                        or (frame.PandemicIcon and frame.PandemicIcon:IsShown())
                                    if inPandemic then
                                        if not fd.pandemicGlowActive then
                                            if not fd.pandemicOverlay then
                                                local ov = CreateFrame("Frame", nil, frame)
                                                ov:SetAllPoints(frame)
                                                ov:SetFrameLevel(frame:GetFrameLevel() + 8)
                                                ov:EnableMouse(false)
                                                fd.pandemicOverlay = ov
                                            end
                                            local c = bd.pandemicGlowColor or { r = 1, g = 1, b = 0 }
                                            local style = bd.pandemicGlowStyle or 1
                                            local glowOpts = (style == 1) and {
                                                N      = bd.pandemicGlowLines or 8,
                                                th     = bd.pandemicGlowThickness or 2,
                                                period = bd.pandemicGlowSpeed or 4,
                                            } or nil
                                            fd.pandemicOverlay:SetAlpha(1)
                                            ns.StartNativeGlow(fd.pandemicOverlay, style, c.r or 1, c.g or 1, c.b or 0, glowOpts)
                                            fd.pandemicGlowActive = true
                                        end
                                    elseif fd.pandemicGlowActive and fd.pandemicOverlay then
                                        ns.StopNativeGlow(fd.pandemicOverlay)
                                        fd.pandemicGlowActive = false
                                    end
                                end

                                -- Active state animation (CD/utility only, polled).
                                -- Detection uses cooldownSwipeColor:
                                -- Blizzard sets a non-zero red channel when a spell
                                -- is active (proc, buff). No wasSetFromAura/auraInstanceID
                                -- reads -- those are secret values that cause taint.
                                if not isBuff and fd then
                                    local anim = bd.activeStateAnim or "blizzard"
                                    if anim ~= "blizzard" then
                                        local swipeColor = frame.cooldownSwipeColor
                                        local isActive = false
                                        if swipeColor and type(swipeColor) ~= "number"
                                            and swipeColor.GetRGBA then
                                            local r = swipeColor:GetRGBA()
                                            if r and type(r) == "number"
                                                and not issecretvalue(r) then
                                                isActive = (r ~= 0)
                                            end
                                        end

                                        if anim == "hideActive" then
                                            -- Suppress active visuals: desat + black swipe
                                            if isActive then
                                                if fd.cooldown then
                                                    fd.cooldown:SetReverse(false)
                                                    fd.cooldown:SetSwipeColor(0, 0, 0, bd.swipeAlpha or 0.7)
                                                end
                                                if fd.tex then fd.tex:SetDesaturated(true) end
                                            elseif fd.isActive then
                                                -- Transition to inactive: restore
                                                if fd.tex then fd.tex:SetDesaturated(bd.desaturateOnCD or false) end
                                            end
                                        else
                                            -- Custom glow modes (1, 3, 4, 5, 7)
                                            local glowIdx = tonumber(anim)
                                            if glowIdx and fd.glowOverlay then
                                                if isActive and not fd.isActive then
                                                    local cr, cg, cb = 1.0, 0.85, 0.0
                                                    if bd.activeAnimClassColor then
                                                        local _, ct = UnitClass("player")
                                                        if ct then local cc = RAID_CLASS_COLORS[ct]; if cc then cr, cg, cb = cc.r, cc.g, cc.b end end
                                                    elseif bd.activeAnimR then
                                                        cr, cg, cb = bd.activeAnimR, bd.activeAnimG or 0.85, bd.activeAnimB or 0.0
                                                    end
                                                    fd.glowOverlay:SetAlpha(1)
                                                    ns.StartNativeGlow(fd.glowOverlay, glowIdx, cr, cg, cb)
                                                elseif not isActive and fd.isActive then
                                                    ns.StopNativeGlow(fd.glowOverlay)
                                                end
                                            end
                                        end
                                        fd.isActive = isActive
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if needsReanchor then QueueReanchor() end
            MemDelta("BuffTicker")
        end)
    end

    ns.SyncViewerToContainer = function() end

    -- CDM settings panel: reanchor when user finishes editing
    if CooldownViewerSettings then
        CooldownViewerSettings:HookScript("OnHide", function()
            C_Timer.After(0.3, QueueReanchor)
        end)
    end

    -- EUI options panel: reanchor on show/hide
    EllesmereUI:RegisterOnShow(function()
        C_Timer.After(0.1, function()
            QueueReanchor()
            UpdateCustomBuffBars()
        end)
    end)
    EllesmereUI:RegisterOnHide(function()
        C_Timer.After(0.1, function()
            QueueReanchor()
            UpdateCustomBuffBars()
        end)
    end)

    -- Edit Mode close: full rebuild to restore CDM after Blizzard repositioned viewers.
    -- FullCDMRebuild is combat-safe (only touches our own frames).
    do
        local emf = _G.EditModeManagerFrame
        if emf then
            hooksecurefunc(emf, "Hide", function()
                C_Timer.After(0.1, function()
                    if ns.FullCDMRebuild then ns.FullCDMRebuild("editmode_close") end
                end)
            end)
        end
    end

    -- Lock EditMode for CDM frames (prevent user changes, avoid taint)
    ns.SetupEditModeLock()

    -- Initial reanchor
    C_Timer.After(0.2, function()
        QueueReanchor()
        UpdateCustomBuffBars()
    end)
end

function ns.IsViewerHooked()
    return viewerHooksInstalled
end

-------------------------------------------------------------------------------
--  EditMode Lock
--  Prevents users from changing CDM viewer settings via EditMode.
--  Hides the settings dialog, disables dragging, shows a lock notice.
-------------------------------------------------------------------------------
local _editModeLockInstalled = false
local _editModeLockNoticeShown = false

local function IsCooldownViewerSystemFrame(frame)
    local cooldownSystem = Enum and Enum.EditModeSystem and Enum.EditModeSystem.CooldownViewer
    return cooldownSystem and frame and frame.system == cooldownSystem
end

local function ShowEditModeLockNotice()
    if not _editModeLockNoticeShown then
        print("|cff0cd29fEllesmereUI CDM:|r Cooldown Viewer settings are managed by EllesmereUI. Edit Mode changes are disabled.")
        _editModeLockNoticeShown = true
    end
end

local function LockCooldownViewerFrames()
    for _, vName in ipairs(VIEWER_NAMES) do
        local frame = _G[vName]
        if IsCooldownViewerSystemFrame(frame) then
            frame:SetMovable(false)
            local selection = frame.Selection
            if selection then
                selection:SetScript("OnDragStart", nil)
                selection:SetScript("OnDragStop", nil)
            end
        end
    end
end

function ns.SetupEditModeLock()
    if _editModeLockInstalled then return end

    local function TrySetup()
        local dialog = _G.EditModeSystemSettingsDialog
        if not (dialog and Enum and Enum.EditModeSystem) then
            return false
        end

        -- When EditMode tries to show the settings dialog for a CDM frame, hide it
        hooksecurefunc(dialog, "AttachToSystemFrame", function(dlg, systemFrame)
            if not IsCooldownViewerSystemFrame(systemFrame) then return end
            dlg:Hide()
            ShowEditModeLockNotice()
        end)

        -- When a CDM frame is selected in EditMode, lock it
        for _, vName in ipairs(VIEWER_NAMES) do
            local frame = _G[vName]
            if IsCooldownViewerSystemFrame(frame) then
                hooksecurefunc(frame, "SelectSystem", function(sf)
                    sf:SetMovable(false)
                    if dialog.attachedToSystem == sf then
                        dialog:Hide()
                    end
                    ShowEditModeLockNotice()
                end)

                hooksecurefunc(frame, "HighlightSystem", function() end)

                hooksecurefunc(frame, "ClearHighlight", function() end)
            end
        end

        _editModeLockInstalled = true
        LockCooldownViewerFrames()
        return true
    end

    if not TrySetup() then
        EventUtil.ContinueOnAddOnLoaded("Blizzard_EditMode", function()
            TrySetup()
        end)
    end
end
