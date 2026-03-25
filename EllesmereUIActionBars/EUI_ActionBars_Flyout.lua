-------------------------------------------------------------------------------
--  EllesmereUI Action Bars - Custom Spell Flyout System
--  Replaces Blizzard's SpellFlyout for our action buttons to avoid taint.
--  Intercepts flyout-type action clicks in the secure environment and opens
--  our own flyout frame with spell-type buttons (secure casting, no taint).
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...

-- Pull shape constants from the main file (loaded before us)
local SHAPE_MASKS              = ns.SHAPE_MASKS
local SHAPE_BORDERS            = ns.SHAPE_BORDERS
local SHAPE_ZOOM_DEFAULTS      = ns.SHAPE_ZOOM_DEFAULTS
local SHAPE_ICON_EXPAND        = ns.SHAPE_ICON_EXPAND
local SHAPE_ICON_EXPAND_OFFSETS = ns.SHAPE_ICON_EXPAND_OFFSETS
local SHAPE_INSETS             = ns.SHAPE_INSETS
local ResolveBorderThickness   = ns.ResolveBorderThickness
local EAB                      = ns.EAB

-- Layout constants
local FLYOUT_SLOT_GAP = 4

-- Fallback flyout IDs (safety net for flyouts not found via action slot scan)
local EXTRA_FLYOUT_SET = {
    [1]=true,   [8]=true,   [9]=true,   [10]=true,  [11]=true,  [12]=true,
    [66]=true,  [67]=true,  [84]=true,  [92]=true,  [93]=true,  [96]=true,
    [103]=true, [106]=true, [217]=true, [219]=true, [220]=true,
    [222]=true, [223]=true, [224]=true, [225]=true, [226]=true,
    [227]=true, [229]=true,
}

-- Individual spell slot inside the flyout menu
local FlyoutSlotMixin = {}

function FlyoutSlotMixin:Setup()
    self:SetAttribute("type", "spell")
    self:RegisterForClicks("AnyUp", "AnyDown")
    self:SetScript("OnEnter", self.OnEnter)
    self:SetScript("OnLeave", self.OnLeave)
    self:SetScript("PostClick", self.PostClick)
end

function FlyoutSlotMixin:OnEnter()
    if GetCVarBool("UberTooltips") then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT", 4, 4)
        if GameTooltip:SetSpellByID(self.spellID) then
            self.UpdateTooltip = self.OnEnter
        else
            self.UpdateTooltip = nil
        end
    else
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.spellName, HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b)
        self.UpdateTooltip = nil
    end
end

function FlyoutSlotMixin:OnLeave()
    GameTooltip:Hide()
end

function FlyoutSlotMixin:OnDataChanged()
    local fid = self:GetAttribute("flyoutID")
    local idx = self:GetAttribute("flyoutIndex")
    local sid, overrideSid, known, name = GetFlyoutSlotInfo(fid, idx)
    local tex = C_Spell.GetSpellTexture(overrideSid)
    self.icon:SetTexture(tex)
    self.icon:SetDesaturated(not known)
    self.spellID = sid
    self.spellName = name
    self:RefreshAll()
end

function FlyoutSlotMixin:PostClick()
    self:RefreshChecked()
end

function FlyoutSlotMixin:RefreshAll()
    self:RefreshCooldown()
    self:RefreshChecked()
    self:RefreshUsable()
    self:RefreshCount()
end

function FlyoutSlotMixin:RefreshCooldown()
    if self.spellID then
        ActionButton_UpdateCooldown(self)
    end
end

function FlyoutSlotMixin:RefreshChecked()
    if self.spellID then
        self:SetChecked(C_Spell.IsCurrentSpell(self.spellID) and true)
    else
        self:SetChecked(false)
    end
end

function FlyoutSlotMixin:RefreshUsable()
    local ico = self.icon
    local sid = self.spellID
    if sid then
        local usable, oom = C_Spell.IsSpellUsable(sid)
        if oom then
            ico:SetDesaturated(true)
            ico:SetVertexColor(0.35, 0.4, 0.95)
        elseif usable then
            ico:SetDesaturated(false)
            ico:SetVertexColor(1, 1, 1)
        else
            ico:SetDesaturated(true)
            ico:SetVertexColor(0.45, 0.45, 0.45)
        end
    else
        ico:SetDesaturated(false)
        ico:SetVertexColor(1, 1, 1)
    end
end

function FlyoutSlotMixin:RefreshCount()
    local sid = self.spellID
    if sid and C_Spell.IsConsumableSpell(sid) then
        local ct = C_Spell.GetSpellCastCount(sid)
        self.Count:SetText(ct > 9999 and "*" or ct)
    else
        self.Count:SetText("")
    end
end

-- Container frame that holds all flyout spell slots
local FlyoutContainerMixin = {}

-- Secure snippet: opens/closes the flyout, positions spell slots
local SEC_OPEN_FLYOUT = [[
    local fid = ...
    local src = self:GetAttribute("caller")

    -- Close if already open on the same button
    if self:IsShown() and src == self:GetParent() then
        self:Hide()
        return
    end

    -- Lazy-sync unknown flyout data
    if not _FO_CACHE[fid] then
        self:SetAttribute("_pendingSyncID", fid)
        self:CallMethod("EnsureFlyoutSynced")
    end

    local info = _FO_CACHE[fid]
    local numEntries = info and info.numSlots or 0
    local learned = info and info.isKnown or false

    self:SetParent(src)

    if numEntries < 1 or not learned then
        self:Hide()
        return
    end

    local orient = src:GetAttribute("flyoutDirection") or "UP"
    self:SetAttribute("direction", orient)

    local bW = src:GetWidth()
    local bH = src:GetHeight()

    local anchor = nil
    local visible = 0

    for s = 1, numEntries do
        if info[s].isKnown then
            visible = visible + 1
            local slot = _FO_SLOTS[visible]
            slot:SetWidth(bW)
            slot:SetHeight(bH)
            slot:ClearAllPoints()

            if orient == "LEFT" then
                if anchor then
                    slot:SetPoint("RIGHT", anchor, "LEFT", -_FO_GAP, 0)
                else
                    slot:SetPoint("RIGHT", self, "RIGHT", 0, 0)
                end
            elseif orient == "RIGHT" then
                if anchor then
                    slot:SetPoint("LEFT", anchor, "RIGHT", _FO_GAP, 0)
                else
                    slot:SetPoint("LEFT", self, "LEFT", 0, 0)
                end
            elseif orient == "DOWN" then
                if anchor then
                    slot:SetPoint("TOP", anchor, "BOTTOM", 0, -_FO_GAP)
                else
                    slot:SetPoint("TOP", self, "TOP", 0, 0)
                end
            else -- UP (default)
                if anchor then
                    slot:SetPoint("BOTTOM", anchor, "TOP", 0, _FO_GAP)
                else
                    slot:SetPoint("BOTTOM", self, "BOTTOM", 0, 0)
                end
            end

            slot:SetAttribute("spell", info[s].spellID)
            slot:SetAttribute("flyoutID", fid)
            slot:SetAttribute("flyoutIndex", s)
            slot:Enable()
            slot:Show()
            slot:CallMethod("OnDataChanged")

            anchor = slot
        end
    end

    -- Hide surplus slots
    for s = visible + 1, #_FO_SLOTS do
        _FO_SLOTS[s]:Hide()
    end

    if visible < 1 then
        self:Hide()
        return
    end

    local isVert = (orient == "UP" or orient == "DOWN")

    self:ClearAllPoints()
    if orient == "LEFT" then
        self:SetPoint("RIGHT", src, "LEFT", -_FO_GAP, 0)
    elseif orient == "RIGHT" then
        self:SetPoint("LEFT", src, "RIGHT", _FO_GAP, 0)
    elseif orient == "DOWN" then
        self:SetPoint("TOP", src, "BOTTOM", 0, -_FO_GAP)
    else
        self:SetPoint("BOTTOM", src, "TOP", 0, _FO_GAP)
    end

    if isVert then
        self:SetWidth(bW)
        self:SetHeight((bH + _FO_GAP) * visible - _FO_GAP)
    else
        self:SetWidth((bW + _FO_GAP) * visible - _FO_GAP)
        self:SetHeight(bH)
    end

    self:CallMethod("OnFlyoutOpened")
    self:Show()
]]

function FlyoutContainerMixin:Init()
    self.slots = {}

    -- Initialize secure environment tables
    self:Execute(([[
        _FO_CACHE = newtable()
        _FO_SLOTS = newtable()
        _FO_GAP = %d
    ]]):format(FLYOUT_SLOT_GAP))

    self:SetAttribute("Toggle", SEC_OPEN_FLYOUT)
    self:SetAttribute("_onhide", [[ self:Hide(true) ]])

    self:SyncAllFlyouts()
end

function FlyoutContainerMixin:SyncAllFlyouts()
    -- Discover flyout IDs from all action slots (covers any flyout, including new ones)
    local seen = {}
    local maxEntries = 0
    for slot = 1, 180 do
        local aType, aID = GetActionInfo(slot)
        if aType == "flyout" and aID and not seen[aID] then
            seen[aID] = true
            local n = self:SyncFlyoutData(aID)
            if n > maxEntries then maxEntries = n end
        end
    end
    -- Also sync the fallback set as a safety net for unbound flyouts
    for fid in pairs(EXTRA_FLYOUT_SET) do
        if not seen[fid] then
            local n = self:SyncFlyoutData(fid)
            if n > maxEntries then maxEntries = n end
        end
    end
    self:EnsureSlots(maxEntries)
end

function FlyoutContainerMixin:SyncSingleFlyout(flyoutID)
    local n = self:SyncFlyoutData(flyoutID)
    if n > #self.slots then
        self:EnsureSlots(n)
        return true
    end
    return false
end

-- Called from the secure toggle via CallMethod when an unknown flyout ID is encountered.
-- Reads the pending ID from an attribute (secure env can't pass args to CallMethod).
function FlyoutContainerMixin:EnsureFlyoutSynced()
    local fid = self:GetAttribute("_pendingSyncID")
    if not fid then return end
    self:SyncSingleFlyout(fid)
end

function FlyoutContainerMixin:SyncFlyoutData(flyoutID)
    local _, _, numSlots, isKnown = GetFlyoutInfo(flyoutID)

    self:Execute(([[
        local id = %d
        local ct = %d
        local kn = %q == "true"
        local rec = _FO_CACHE[id] or newtable()
        rec.numSlots = ct
        rec.isKnown = kn
        _FO_CACHE[id] = rec
        for j = ct + 1, #rec do rec[j].isKnown = false end
    ]]):format(flyoutID, numSlots, tostring(isKnown)))

    for slot = 1, numSlots do
        local sid, _, slotKnown = GetFlyoutSlotInfo(flyoutID, slot)
        if slotKnown then
            local petIdx, petName = GetCallPetSpellInfo(sid)
            if petIdx and not (petName and petName ~= "") then
                slotKnown = false
            end
        end
        self:Execute(([[
            local rec = _FO_CACHE[%d][%d] or newtable()
            rec.spellID = %d
            rec.isKnown = %q == "true"
            _FO_CACHE[%d][%d] = rec
        ]]):format(flyoutID, slot, sid, tostring(slotKnown), flyoutID, slot))
    end

    return numSlots
end

function FlyoutContainerMixin:EnsureSlots(count)
    for i = #self.slots + 1, count do
        local btn = self:CreateFlyoutSlot(i)
        self:SetFrameRef("_eabFlySlot", btn)
        self:Execute([[ tinsert(_FO_SLOTS, self:GetFrameRef("_eabFlySlot")) ]])
        self.slots[i] = btn
    end
end

-- Secure snippet for spell slot clicks: dismiss flyout on key-up
local SEC_SLOT_PRE  = [[ if not down then return nil, "dismiss" end ]]
local SEC_SLOT_POST = [[ if message == "dismiss" then control:Hide() end ]]

function FlyoutContainerMixin:CreateFlyoutSlot(idx)
    local name = "EABFlyoutBtn" .. idx
    local btn = CreateFrame("CheckButton", name, self,
        "SmallActionButtonTemplate, SecureActionButtonTemplate")
    Mixin(btn, FlyoutSlotMixin)
    btn:Setup()
    self:WrapScript(btn, "OnClick", SEC_SLOT_PRE, SEC_SLOT_POST)
    return btn
end

function FlyoutContainerMixin:ForVisible(method, ...)
    for _, btn in ipairs(self.slots) do
        if btn:IsShown() then btn[method](btn, ...) end
    end
end

-- Style flyout slots to match the parent bar's appearance.
-- Called from the secure toggle via CallMethod after the flyout opens.
function FlyoutContainerMixin:OnFlyoutOpened()
    local caller = self:GetParent()
    if not caller then return end

    -- Find the bar key from the caller button
    local barKey = caller._eabBarKey
    if not barKey then return end

    local prof = EAB.db and EAB.db.profile
    if not prof then return end
    local s = prof.bars and prof.bars[barKey]
    if not s then return end

    local PP = EllesmereUI and EllesmereUI.PP
    local shape = s.buttonShape or "none"
    local zoom = ((s.iconZoom or prof.iconZoom or 5.5)) / 100
    local brdSz = ResolveBorderThickness(s)
    local brdOn = brdSz > 0
    local brdColor = s.borderColor or { r = 0, g = 0, b = 0, a = 1 }
    local cr, cg, cb, ca = brdColor.r, brdColor.g, brdColor.b, brdColor.a or 1
    if s.borderClassColor then
        local _, ct = UnitClass("player")
        if ct then
            local cc = RAID_CLASS_COLORS[ct]
            if cc then cr, cg, cb = cc.r, cc.g, cc.b end
        end
    end
    local shapeBrdColor = s.shapeBorderColor or brdColor
    local sbR, sbG, sbB, sbA = shapeBrdColor.r, shapeBrdColor.g, shapeBrdColor.b, shapeBrdColor.a or 1
    if s.borderClassColor then
        local _, ct = UnitClass("player")
        if ct then
            local cc = RAID_CLASS_COLORS[ct]
            if cc then sbR, sbG, sbB = cc.r, cc.g, cc.b end
        end
    end

    for _, btn in ipairs(self.slots) do
        if btn:IsShown() then
            -- Strip default SmallActionButton art
            self:StripSlotArt(btn)

            if shape ~= "none" and shape ~= "cropped" and SHAPE_MASKS[shape] then
                -- Apply shape mask to flyout slot
                self:ApplySlotShape(btn, shape, brdOn, sbR, sbG, sbB, sbA, brdSz, zoom)
            else
                -- Square/cropped: apply borders and zoom
                self:ApplySlotSquare(btn, brdOn, cr, cg, cb, ca, brdSz, zoom, shape == "cropped")
            end

            -- Apply pushed/highlight/misc texture animations to match the bar
            -- Only outside combat SetPushedTexture is restricted on secure buttons in combat.
            -- The textures persist after being set, so this only needs to run once per slot.
            if not InCombatLockdown() then
                self:ApplySlotAnimations(btn, prof)
            end
        end
    end
end

-- Apply pushed/highlight/misc button texture animations to a flyout slot,
-- matching the global animation settings used on all action bar buttons.
function FlyoutContainerMixin:ApplySlotAnimations(btn, prof)
    local useCC = prof.pushedUseClassColor
    local customC = prof.pushedCustomColor or { r = 0.973, g = 0.839, b = 0.604, a = 1 }
    local cr, cg, cb, ca = customC.r, customC.g, customC.b, customC.a or 1
    if useCC then
        local _, ct = UnitClass("player")
        if ct then local cc = RAID_CLASS_COLORS[ct]; if cc then cr, cg, cb = cc.r, cc.g, cc.b end end
    end

    local mediaDir = "Interface\\AddOns\\EllesmereUIActionBars\\Media\\"
    local hlTex = {
        mediaDir .. "highlight-2.png",
        mediaDir .. "highlight-3.png",
        mediaDir .. "highlight-4.png",
    }
    local function ApplyTex(tex, path)
        if not tex then return end
        tex:SetAtlas(nil)
        tex:SetTexture(path)
        tex:SetTexCoord(0, 1, 0, 1)
        tex:ClearAllPoints()
        tex:SetAllPoints(btn)
    end

    -- Pushed texture
    local pType = prof.pushedTextureType or 2
    if pType == 6 then
        btn:SetPushedTexture("")
        local pt = btn:GetPushedTexture()
        if pt then pt:SetAlpha(0) end
    else
        local texPath
        if pType <= 3 then
            texPath = hlTex[pType] or hlTex[2]
        elseif pType == 4 then
            texPath = "Interface\\Buttons\\WHITE8X8"
        else -- pType == 5
            texPath = hlTex[1]
        end
        btn:SetPushedTexture(texPath)
        local pt = btn:GetPushedTexture()
        if pt then
            pt:SetAlpha(1)
            pt:SetTexCoord(0, 1, 0, 1)
            pt:ClearAllPoints()
            pt:SetAllPoints(btn)
            if pType == 4 then
                pt:SetVertexColor(cr, cg, cb, 0.35)
            else
                pt:SetVertexColor(cr, cg, cb, 1)
            end
        end
    end

    -- Highlight texture
    local hType = prof.highlightTextureType or 2
    local hUseCC = prof.highlightUseClassColor
    local hCustomC = prof.highlightCustomColor or { r = 0.973, g = 0.839, b = 0.604, a = 1 }
    local hr, hg, hb = hCustomC.r, hCustomC.g, hCustomC.b
    if hUseCC then
        local _, ct = UnitClass("player")
        if ct then local cc = RAID_CLASS_COLORS[ct]; if cc then hr, hg, hb = cc.r, cc.g, cc.b end end
    end
    if btn.HighlightTexture then
        if hType == 6 then
            btn.HighlightTexture:SetAlpha(0)
        else
            btn.HighlightTexture:SetAlpha(1)
            if hType <= 3 then
                ApplyTex(btn.HighlightTexture, hlTex[hType] or hlTex[1])
                btn.HighlightTexture:SetVertexColor(hr, hg, hb, 1)
            elseif hType == 4 then
                btn.HighlightTexture:SetColorTexture(hr, hg, hb, 0.35)
            elseif hType == 5 then
                ApplyTex(btn.HighlightTexture, hlTex[1])
                btn.HighlightTexture:SetVertexColor(hr, hg, hb, 1)
            end
        end
    end

    -- NewActionTexture (uses pushed color)
    if btn.NewActionTexture then
        btn.NewActionTexture:SetDesaturated(true)
        btn.NewActionTexture:SetVertexColor(cr, cg, cb, ca)
    end
end

-- Remove default SmallActionButton template art from a flyout slot
function FlyoutContainerMixin:StripSlotArt(btn)
    if btn._eabFlyStripped then return end
    local nt = btn.NormalTexture or btn:GetNormalTexture()
    if nt then nt:SetAlpha(0) end
    if btn.SlotBackground then btn.SlotBackground:Hide() end
    if btn.SlotArt then btn.SlotArt:Hide() end
    if btn.IconMask then
        btn.IconMask:Hide()
        btn.IconMask:SetTexture(nil)
        btn.IconMask:ClearAllPoints()
        btn.IconMask:SetSize(0.001, 0.001)
    end
    if btn.FlyoutBorderShadow then btn.FlyoutBorderShadow:SetAlpha(0) end
    -- Ensure icon fills the slot
    local icon = btn.icon or btn.Icon
    if icon then
        icon:ClearAllPoints()
        icon:SetAllPoints(btn)
    end
    btn._eabFlyStripped = true
end

-- Apply square borders and zoom to a flyout slot
function FlyoutContainerMixin:ApplySlotSquare(btn, brdOn, cr, cg, cb, ca, brdSz, zoom, cropped)
    local PP = EllesmereUI and EllesmereUI.PP
    -- Remove shape mask if previously applied
    if btn._eabShapeMask then
        local icon = btn.icon or btn.Icon
        if icon then pcall(icon.RemoveMaskTexture, icon, btn._eabShapeMask) end
        if btn.cooldown and not btn.cooldown:IsForbidden() then
            pcall(btn.cooldown.RemoveMaskTexture, btn.cooldown, btn._eabShapeMask)
            pcall(btn.cooldown.SetSwipeTexture, btn.cooldown, "")
        end
        btn._eabShapeMask:Hide()
    end
    if btn._eabShapeBorder then btn._eabShapeBorder:Hide() end

    local icon = btn.icon or btn.Icon
    if icon then
        icon:ClearAllPoints()
        icon:SetAllPoints(btn)
        if cropped then
            local z = zoom or 0
            icon:SetTexCoord(z, 1 - z, z + 0.10, 1 - z - 0.10)
        elseif zoom > 0 then
            icon:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
        else
            icon:SetTexCoord(0, 1, 0, 1)
        end
    end

    if PP then
        if brdOn then
            if not btn._eabBorders then
                PP.CreateBorder(btn, 0, 0, 0, 1, 1, "OVERLAY", -1)
                btn._eabBorders = btn._ppBorders
            end
            PP.UpdateBorder(btn, brdSz, cr, cg, cb, ca)
            PP.ShowBorder(btn)
        elseif btn._eabBorders then
            PP.HideBorder(btn)
        end
    end
end

-- Apply shape mask, border, and zoom to a flyout slot
function FlyoutContainerMixin:ApplySlotShape(btn, shape, brdOn, brdR, brdG, brdB, brdA, brdSz, zoom)
    local PP = EllesmereUI and EllesmereUI.PP
    local maskTex = SHAPE_MASKS[shape]
    if not maskTex then return end

    -- Hide square borders when using shapes
    if btn._eabBorders and PP then PP.HideBorder(btn) end

    -- Create or reuse shape mask
    if not btn._eabShapeMask then
        btn._eabShapeMask = btn:CreateMaskTexture()
    end
    local mask = btn._eabShapeMask
    mask:SetTexture(maskTex, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:ClearAllPoints()
    if brdSz and brdSz >= 1 then
        if PP then
            PP.Point(mask, "TOPLEFT", btn, "TOPLEFT", 1, -1)
            PP.Point(mask, "BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
        else
            mask:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
            mask:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
        end
    else
        mask:SetAllPoints(btn)
    end
    mask:Show()

    local icon = btn.icon or btn.Icon
    if icon then
        pcall(icon.RemoveMaskTexture, icon, mask)
        icon:AddMaskTexture(mask)
    end

    -- Expand icon for shape inset
    local shapeOffset = SHAPE_ICON_EXPAND_OFFSETS[shape] or 0
    local shapeDefault = (SHAPE_ZOOM_DEFAULTS[shape] or 6.0) / 100
    local iconExp = SHAPE_ICON_EXPAND + shapeOffset + ((zoom or 0) - shapeDefault) * 200
    if iconExp < 0 then iconExp = 0 end
    local halfIE = iconExp / 2
    if icon and PP then
        icon:ClearAllPoints()
        PP.Point(icon, "TOPLEFT", btn, "TOPLEFT", -halfIE, halfIE)
        PP.Point(icon, "BOTTOMRIGHT", btn, "BOTTOMRIGHT", halfIE, -halfIE)
    end

    -- Expand texcoords for shape
    local insetPx = SHAPE_INSETS[shape] or 17
    local visRatio = (128 - 2 * insetPx) / 128
    local expand = ((1 / visRatio) - 1) * 0.5
    if icon then icon:SetTexCoord(-expand, 1 + expand, -expand, 1 + expand) end

    -- Mask cooldown frame
    if btn.cooldown and not btn.cooldown:IsForbidden() then
        pcall(btn.cooldown.RemoveMaskTexture, btn.cooldown, mask)
        pcall(btn.cooldown.AddMaskTexture, btn.cooldown, mask)
        if btn.cooldown.SetSwipeTexture then
            pcall(btn.cooldown.SetSwipeTexture, btn.cooldown, maskTex)
        end
        local useCircular = (shape ~= "square" and shape ~= "csquare")
        if btn.cooldown.SetUseCircularEdge then
            pcall(btn.cooldown.SetUseCircularEdge, btn.cooldown, useCircular)
        end
    end

    -- Shape border overlay
    if not btn._eabShapeBorder then
        btn._eabShapeBorder = btn:CreateTexture(nil, "OVERLAY", nil, 6)
    end
    local borderTex = btn._eabShapeBorder
    pcall(borderTex.RemoveMaskTexture, borderTex, mask)
    borderTex:ClearAllPoints()
    borderTex:SetAllPoints(btn)
    if brdOn and SHAPE_BORDERS[shape] then
        borderTex:SetTexture(SHAPE_BORDERS[shape])
        borderTex:SetVertexColor(brdR, brdG, brdB, brdA)
        borderTex:Show()
    else
        borderTex:Hide()
    end
end

-------------------------------------------------------------------------------
--  Flyout Manager
--  Creates the frame on demand, registers buttons, handles events
-------------------------------------------------------------------------------
local EABFlyout = CreateFrame("Frame")

-- Secure snippet: intercepts flyout-type action clicks on registered buttons.
-- Computes the action slot inline (mirroring CalculateAction) so it works for
-- both native-dispatch buttons (ID > 0, page-based) and legacy buttons (ID == 0,
-- explicit action attribute).
local SEC_CLICK_HOOK = [[
    local id = self:GetID()
    local action
    if id > 0 then
        local page = self:GetEffectiveAttribute("actionpage", button)
        if not page then page = GetActionBarPage() end
        action = id + ((page - 1) * 12)
    else
        action = self:GetEffectiveAttribute("action", button) or 0
    end

    local actionKind, actionVal = GetActionInfo(action)
    if actionKind == "flyout" then
        if not down then
            control:SetAttribute("caller", self:GetFrameRef("_eabFlyOwner") or self)
            control:RunAttribute("Toggle", actionVal)
        end
        return false
    end
]]

function EABFlyout:GetFrame()
    if self._frame then return self._frame end

    local f = CreateFrame("Frame", nil, nil, "SecureHandlerShowHideTemplate")
    Mixin(f, FlyoutContainerMixin)
    f:Init()
    f:HookScript("OnShow", function() self:OnShown() end)
    f:HookScript("OnHide", function() self:OnHidden() end)

    self:RegisterEvent("SPELL_FLYOUT_UPDATE")
    self:RegisterEvent("PET_STABLE_UPDATE")
    self:SetScript("OnEvent", self.OnEvent)

    self._frame = f
    return f
end

function EABFlyout:RegisterButton(button, owner)
    local f = self:GetFrame()
    -- Store a reference to the "real" parent button so the secure env
    -- can reparent the flyout to the correct visual button
    if owner then
        SecureHandlerSetFrameRef(button, "_eabFlyOwner", owner)
    end
    f:WrapScript(button, "OnClick", SEC_CLICK_HOOK)
end

function EABFlyout:OnEvent(event, arg1)
    if event == "SPELL_FLYOUT_UPDATE" then
        if arg1 then
            if InCombatLockdown() then
                self._pendingSync = true
                self:RegisterEvent("PLAYER_REGEN_ENABLED")
            else
                self._frame:SyncSingleFlyout(arg1)
            end
        end
        if self._frame then self._frame:ForVisible("RefreshAll") end
    elseif event == "PET_STABLE_UPDATE" then
        if InCombatLockdown() then
            self._pendingSync = true
            self:RegisterEvent("PLAYER_REGEN_ENABLED")
        else
            self._frame:SyncAllFlyouts()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if self._pendingSync then
            self._frame:SyncAllFlyouts()
            self._pendingSync = nil
        end
        self:UnregisterEvent("PLAYER_REGEN_ENABLED")
    elseif event == "CURRENT_SPELL_CAST_CHANGED" then
        if self._frame then self._frame:ForVisible("RefreshChecked") end
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        if self._frame then self._frame:ForVisible("RefreshCooldown") end
    elseif event == "SPELL_UPDATE_USABLE" then
        if self._frame then self._frame:ForVisible("RefreshUsable") end
    end
end

function EABFlyout:OnShown()
    if not self._flyoutVisible then
        self._flyoutVisible = true
        self:RegisterEvent("CURRENT_SPELL_CAST_CHANGED")
        self:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        self:RegisterEvent("SPELL_UPDATE_USABLE")
    end
end

function EABFlyout:OnHidden()
    if self._flyoutVisible then
        self._flyoutVisible = nil
        self:UnregisterEvent("CURRENT_SPELL_CAST_CHANGED")
        self:UnregisterEvent("SPELL_UPDATE_COOLDOWN")
        self:UnregisterEvent("SPELL_UPDATE_USABLE")
    end
end

-- Public API for checking flyout visibility (used by mouseover fade logic)
function EABFlyout:IsVisible()
    return self._frame and self._frame:IsVisible()
end

function EABFlyout:IsMouseOver(...)
    return self._frame and self._frame:IsMouseOver(...)
end

function EABFlyout:GetParent()
    return self._frame and self._frame:GetParent()
end

-- Export for the main file and options
ns.EABFlyout = EABFlyout
