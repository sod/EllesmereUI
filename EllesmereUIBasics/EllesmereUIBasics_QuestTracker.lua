-------------------------------------------------------------------------------
-- EllesmereUIQuestTracker.lua
-------------------------------------------------------------------------------
local addonName, ns = ...

local C = {
    accent    = { r=0.047, g=0.824, b=0.624 },
    complete  = { r=0.25,  g=1.0,   b=0.35  },
    failed    = { r=1.0,   g=0.3,   b=0.3   },
    header    = { r=1.0,   g=1.0,   b=1.0   },
    section   = { r=0.047, g=0.824, b=0.624 },
    timer     = { r=1.0,   g=0.82,  b=0.2   },
    timerLow  = { r=1.0,   g=0.3,   b=0.3   },
    barBg     = { r=0.15,  g=0.15,  b=0.15  },
    barFill   = { r=0.047, g=0.824, b=0.624 },
    focus     = { r=0.6,   g=0.3,   b=0.9   },
}

local EQT      = {}
ns.EQT         = EQT
EQT.rows       = {}
EQT.sections   = {}
EQT.itemBtns   = {}
EQT.timerRows  = {}   -- rows with active timers (need OnUpdate)

-------------------------------------------------------------------------------
-- Dirty coalescing: replaces per-frame OnUpdate dirty check with C_Timer
-------------------------------------------------------------------------------
local _dirtyTimer = nil
local _structuralDirty = true  -- true = quest list structure changed
local _timerUpdateFrame        -- forward decl; created in Init

function EQT:SetDirty(structural)
    if structural then _structuralDirty = true end
    if _dirtyTimer then _dirtyTimer:Cancel() end
    _dirtyTimer = C_Timer.NewTimer(0.5, function()
        _dirtyTimer = nil
        local wasStructural = _structuralDirty
        _structuralDirty = false
        if wasStructural then
            EQT:Refresh()
        else
            EQT:RefreshProgress()
        end
    end)
end

-------------------------------------------------------------------------------
-- DB
-------------------------------------------------------------------------------
local function DB()
    -- Quest tracker data lives under the shared Basics Lite DB at profile.questTracker
    local basicsDB = _G._EBS_AceDB
    if basicsDB and basicsDB.profile and basicsDB.profile.questTracker then
        return basicsDB.profile.questTracker
    end
    -- Fallback: Lite hasn't initialized yet, return a temporary table
    if not EQT._tmpDB then EQT._tmpDB = {} end
    return EQT._tmpDB
end
local function Cfg(k) return DB()[k] end

-------------------------------------------------------------------------------
-- Fonts
-------------------------------------------------------------------------------
local FALLBACK_FONT = "Fonts/FRIZQT__.TTF"
local function SafeFont(p)
    if not p or p == "" then return FALLBACK_FONT end
    -- WoW only supports TTF/TGA, not OTF
    local ext = p:match("%.(%a+)$")
    if ext and ext:lower() == "otf" then return FALLBACK_FONT end
    return p
end
-- Apply shadow based on global outline mode
local function ApplyFontShadow(fs)
    if not fs then return end
    if EllesmereUI.GetFontUseShadow and EllesmereUI.GetFontUseShadow() then
        fs:SetShadowColor(0, 0, 0, 0.8)
        fs:SetShadowOffset(1, -1)
    else
        fs:SetShadowOffset(0, 0)
    end
end
local function OutlineFlag()
    if EllesmereUI.GetFontOutlineFlag then return EllesmereUI.GetFontOutlineFlag() end
    return ""
end
local function SetFontSafe(fs, path, size, flags)
    if not fs then return end
    local safePath = SafeFont(path)
    size = size or 11
    flags = flags or "NONE"
    -- Skip if font hasn't changed
    local curPath, curSize, curFlags = fs:GetFont()
    if curPath == safePath and curSize == size and (curFlags or "NONE") == flags then return end
    fs:SetFont(safePath, size, flags)
    -- Verify font was set; if not try forward-slash fallback, then Blizzard default
    if not fs:GetFont() then
        fs:SetFont("Fonts/FRIZQT__.TTF", size or 11, flags or "NONE")
    end
    if not fs:GetFont() then
        fs:SetFont("Fonts\\FRIZQT__.TTF", size or 11, flags or "NONE")
    end
    if not fs:GetFont() then
        -- Last resort: copy font from GameFontNormal which always exists
        local gf = GameFontNormal and GameFontNormal:GetFont()
        if gf then fs:SetFont(gf, size or 11, flags or "NONE") end
    end
end
local function GlobalFont()
    if EllesmereUI and EllesmereUI.GetFontPath then
        return SafeFont(EllesmereUI.GetFontPath("unitFrames"))
    end
    return FALLBACK_FONT
end
local function TitleFont() return GlobalFont(), Cfg("titleFontSize") or 11, OutlineFlag() end
local function ObjFont()   return GlobalFont(), Cfg("objFontSize")   or 10, OutlineFlag() end
local function SecFont()   return GlobalFont(), Cfg("secFontSize")   or 8,  OutlineFlag() end

-------------------------------------------------------------------------------
-- Context menu (EUI-styled popup)
-------------------------------------------------------------------------------
local ctxMenu  -- reusable context menu frame
local function ShowContextMenu(anchor, items)
    local PP = EllesmereUI and EllesmereUI.PP
    local E  = EllesmereUI
    if not E then return end

    -- Build or reuse the menu frame
    if not ctxMenu then
        ctxMenu = CreateFrame("Frame", nil, UIParent)
        ctxMenu:SetFrameStrata("FULLSCREEN_DIALOG")
        ctxMenu:SetFrameLevel(200)
        ctxMenu:SetClampedToScreen(true)
        ctxMenu:EnableMouse(true)

        -- Background
        local bg = ctxMenu:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(E.DD_BG_R, E.DD_BG_G, E.DD_BG_B, E.DD_BG_HA)
        ctxMenu._bg = bg

        -- Pixel-perfect border
        if PP then
            PP.CreateBorder(ctxMenu, 1, 1, 1, E.DD_BRD_A, 1)
        end

        ctxMenu._items = {}

        -- Close when clicking anywhere outside the menu (non-blocking)
        ctxMenu:HookScript("OnShow", function(self)
            self:SetScript("OnUpdate", function(self)
                if not self:IsMouseOver() and IsMouseButtonDown("LeftButton") then
                    self:Hide()
                end
            end)
        end)
        ctxMenu:HookScript("OnHide", function(self)
            self:SetScript("OnUpdate", nil)
        end)
    end

    -- Hide excess pooled buttons
    for _, btn in ipairs(ctxMenu._items) do
        btn:Hide()
    end

    local ITEM_H = 26
    local MENU_PAD = 4
    local maxTextW = 0

    -- Reusable measurement font string
    if not ctxMenu._measureFS then
        ctxMenu._measureFS = ctxMenu:CreateFontString(nil, "OVERLAY")
    end
    local mfs = ctxMenu._measureFS
    SetFontSafe(mfs, GlobalFont(), 12, OutlineFlag())
    for _, item in ipairs(items) do
        mfs:SetText(item.text)
        local w = mfs:GetStringWidth()
        if w > maxTextW then maxTextW = w end
    end
    mfs:SetText("")
    mfs:Hide()

    local MENU_W = math.max(140, maxTextW + 40)

    -- Acquire or create item buttons from pool
    local acR, acG, acB = C.accent.r, C.accent.g, C.accent.b
    for i, item in ipairs(items) do
        local btn = ctxMenu._items[i]
        if not btn then
            btn = CreateFrame("Button", nil, ctxMenu)
            local hl = btn:CreateTexture(nil, "BACKGROUND", nil, 1)
            hl:SetAllPoints()
            btn._hl = hl
            local lbl = btn:CreateFontString(nil, "OVERLAY")
            lbl:SetPoint("LEFT", btn, "LEFT", 10, 0)
            lbl:SetPoint("RIGHT", btn, "RIGHT", -10, 0)
            lbl:SetJustifyH("LEFT")
            btn._lbl = lbl
            btn:SetScript("OnEnter", function()
                btn._hl:SetColorTexture(1, 1, 1, E.DD_ITEM_HL_A)
                btn._lbl:SetTextColor(acR, acG, acB, 1)
            end)
            btn:SetScript("OnLeave", function()
                btn._hl:SetColorTexture(1, 1, 1, 0)
                btn._lbl:SetTextColor(1, 1, 1, 1)
            end)
            ctxMenu._items[i] = btn
        end
        btn:SetSize(MENU_W - MENU_PAD * 2, ITEM_H)
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", ctxMenu, "TOPLEFT", MENU_PAD, -(MENU_PAD + (i - 1) * ITEM_H))
        btn._hl:SetColorTexture(1, 1, 1, 0)
        SetFontSafe(btn._lbl, GlobalFont(), 12, OutlineFlag())
        btn._lbl:SetText(item.text)
        local disabled = item.isDisabled and item.isDisabled()
        if disabled then
            btn._lbl:SetTextColor(0.4, 0.4, 0.4, 0.5)
            btn._onClick = nil
            btn:SetScript("OnClick", nil)
            btn:SetScript("OnEnter", function()
                btn._lbl:SetTextColor(0.4, 0.4, 0.4, 0.5)
            end)
            btn:SetScript("OnLeave", function()
                btn._lbl:SetTextColor(0.4, 0.4, 0.4, 0.5)
            end)
        else
            btn._lbl:SetTextColor(1, 1, 1, 1)
            btn._onClick = item.onClick
            btn:SetScript("OnClick", function()
                ctxMenu:Hide()
                if btn._onClick then btn._onClick() end
            end)
            btn:SetScript("OnEnter", function()
                btn._hl:SetColorTexture(1, 1, 1, E.DD_ITEM_HL_A)
                btn._lbl:SetTextColor(acR, acG, acB, 1)
            end)
            btn:SetScript("OnLeave", function()
                btn._hl:SetColorTexture(1, 1, 1, 0)
                btn._lbl:SetTextColor(1, 1, 1, 1)
            end)
        end
        btn:Show()
    end

    ctxMenu:SetSize(MENU_W, MENU_PAD * 2 + #items * ITEM_H)

    -- Position at cursor
    local scale = ctxMenu:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    ctxMenu:ClearAllPoints()
    ctxMenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / scale, cy / scale)
    ctxMenu:Show()
end

-------------------------------------------------------------------------------
-- Timer helpers
-------------------------------------------------------------------------------
local function FormatTimeLeft(seconds)
    if seconds <= 0 then return "0:00" end
    if seconds < 60 then
        return string.format("0:%02d", math.floor(seconds))
    elseif seconds < 3600 then
        return string.format("%d:%02d", math.floor(seconds/60), math.floor(seconds%60))
    else
        return string.format("%dh %dm", math.floor(seconds/3600), math.floor((seconds%3600)/60))
    end
end

-- Scan a widget set for a ScenarioHeaderTimer widget (type 20).
-- Returns duration, startTime or nil, nil.
local function GetWidgetSetTimer(setID)
    if not setID or setID == 0 then return nil, nil end
    if not C_UIWidgetManager or not C_UIWidgetManager.GetAllWidgetsBySetID then return nil, nil end
    local ok, widgets = pcall(C_UIWidgetManager.GetAllWidgetsBySetID, setID)
    if not ok or not widgets then return nil, nil end
    for _, w in ipairs(widgets) do
        if w.widgetType == 20 and C_UIWidgetManager.GetScenarioHeaderTimerWidgetVisualizationInfo then
            local ti = C_UIWidgetManager.GetScenarioHeaderTimerWidgetVisualizationInfo(w.widgetID)
            if ti and ti.shownState == 1 then
                local tMin     = ti.timerMin   or 0
                local tMax     = ti.timerMax   or 0
                local tVal     = ti.timerValue or 0
                local duration  = tMax - tMin
                local remaining = tVal - tMin
                if remaining > 0 and duration > 0 then
                    local startTime = GetTime() - (duration - remaining)
                    return duration, startTime
                end
            end
        end
    end
    return nil, nil
end

-- Returns duration, startTime (both needed for live countdown), or nil, nil.
-- Priority: GetQuestTimeLeftData -> ScenarioHeaderTimer widget (type 20) from step widgetSetID
local function GetQuestTimer(questID)
    -- 1. Standard quest timer
    if GetQuestTimeLeftData then
        local startTime, duration = GetQuestTimeLeftData(questID)
        if startTime and startTime > 0 and duration and duration > 0 then
            local remaining = duration - (GetTime() - startTime)
            if remaining > 0 then return duration, startTime end
        end
    end
    -- 2. ScenarioHeaderTimer widget from step widgetSetID (covers Assault/Event quests)
    if C_Scenario and C_Scenario.GetStepInfo then
        local ok, _, _, _, _, _, _, _, _, _, _, widgetSetID = pcall(C_Scenario.GetStepInfo)
        if ok and widgetSetID and widgetSetID ~= 0 then
            local dur, start = GetWidgetSetTimer(widgetSetID)
            if dur and start then return dur, start end
        end
    end
    -- 3. ObjectiveTracker widget set fallback
    if C_UIWidgetManager and C_UIWidgetManager.GetObjectiveTrackerWidgetSetID then
        local otSet = C_UIWidgetManager.GetObjectiveTrackerWidgetSetID()
        if otSet and otSet ~= 0 then
            local dur, start = GetWidgetSetTimer(otSet)
            if dur and start then return dur, start end
        end
    end
    return nil, nil
end

-- GetProgressBar removed: progress bar logic now lives in BuildEntry

local RemoveWatch  -- forward declaration (used by TitleRowOnClick)

-------------------------------------------------------------------------------
-- Shared title-row click handler (avoids per-row closure creation)
-------------------------------------------------------------------------------
local function TitleRowOnClick(self, btn)
    local recipeID = self._recipeID
    if recipeID then
        local function UntrackRecipe()
            if C_TradeSkillUI and C_TradeSkillUI.SetRecipeTracked then
                C_TradeSkillUI.SetRecipeTracked(recipeID, false, self._isRecraft or false)
                EQT:SetDirty(true)
            end
        end
        if btn == "RightButton" then
            ShowContextMenu(self, {
                { text = "Untrack Recipe", onClick = UntrackRecipe },
            })
        elseif IsShiftKeyDown() then
            UntrackRecipe()
        end
        return
    end
    local qID = self._questID
    if not qID then return end
    if btn == "RightButton" then
        local isFocused = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID() == qID
        ShowContextMenu(self, {
            { text = isFocused and "Unfocus" or "Focus", onClick = function()
                if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
                    if isFocused then
                        C_SuperTrack.SetSuperTrackedQuestID(0)
                    else
                        C_SuperTrack.SetSuperTrackedQuestID(qID)
                    end
                end
            end },
            { text = "Untrack Quest", onClick = function()
                RemoveWatch(qID); EQT:SetDirty(true)
            end },
            { text = "Share Quest", onClick = function()
                if C_QuestLog.IsPushableQuest and C_QuestLog.IsPushableQuest(qID) then
                    C_QuestLog.SetSelectedQuest(qID)
                    QuestLogPushQuest()
                end
            end, isDisabled = function()
                return not IsInGroup() or not (C_QuestLog.IsPushableQuest and C_QuestLog.IsPushableQuest(qID))
            end },
            { text = "Abandon Quest", onClick = function()
                C_QuestLog.SetSelectedQuest(qID)
                C_QuestLog.SetAbandonQuest()
                local questTitle = C_QuestLog.GetTitleForQuestID(qID) or "this quest"
                EllesmereUI:ShowConfirmPopup({
                    title = "Abandon Quest",
                    message = "Are you sure you want to abandon \"" .. questTitle .. "\"?",
                    confirmText = "Abandon",
                    cancelText = "Cancel",
                    onConfirm = function()
                        C_QuestLog.AbandonQuest()
                    end,
                })
            end },
        })
    elseif IsShiftKeyDown() then
        RemoveWatch(qID); EQT:SetDirty(true)
    else
        EQT._suppressDirty = true
        if EQT._suppressTimer then EQT._suppressTimer:Cancel() end
        EQT._suppressTimer = C_Timer.NewTimer(0.5, function()
            EQT._suppressDirty = false; EQT._suppressTimer = nil
        end)
        if self._isAutoComplete and self._isComplete then
            if AutoQuestPopupTracker_RemovePopUp then
                AutoQuestPopupTracker_RemovePopUp(qID)
            end
            if TryCompleteQuest(qID) then return end
        end
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
            C_SuperTrack.SetSuperTrackedQuestID(qID)
        end
        if WorldMapFrame and WorldMapFrame:IsShown() then
            -- Use Toggle instead of protected HideUIPanel to avoid taint
            WorldMapFrame:Hide()
        else
            if C_QuestLog.SetSelectedQuest then
                C_QuestLog.SetSelectedQuest(qID)
            end
            if QuestMapFrame_OpenToQuestDetails then
                QuestMapFrame_OpenToQuestDetails(qID)
            elseif OpenQuestLog then
                OpenQuestLog(qID)
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Row pool
-------------------------------------------------------------------------------
local rowPool = {}
local function AcquireRow(parent)
    local r = table.remove(rowPool)
    if not r then
        r = {}
        r.frame = CreateFrame("Button", nil, parent)
        r.text  = r.frame:CreateFontString(nil, "OVERLAY")
        r.text:SetJustifyH("LEFT")
        r.text:SetWordWrap(true)
        r.text:SetNonSpaceWrap(false)
        r.frame:SetScript("OnEnter", function(self)
            if EQT._qtMouseoverIn then EQT._qtMouseoverIn() end
            if self._questID and r._baseR then
                local br, bg, bb = r._baseR, r._baseG, r._baseB
                r.text:SetTextColor(br + (1 - br) * 0.5, bg + (1 - bg) * 0.5, bb + (1 - bb) * 0.5)
            end
        end)
        r.frame:SetScript("OnLeave", function()
            if EQT._qtMouseoverOut then EQT._qtMouseoverOut() end
            if r._baseR then r.text:SetTextColor(r._baseR, r._baseG, r._baseB) end
        end)
    end
    r.frame:SetParent(parent); r.frame._questID = nil
    r.frame:EnableMouse(false); r.frame:Show(); r.text:Show()
    return r
end
local function ReleaseRow(r)
    r.frame:Hide(); r.frame:ClearAllPoints()
    r.frame:SetScript("OnClick", nil)
    r.frame:SetScript("OnEnter", nil)
    r.frame:SetScript("OnLeave", nil)
    r.frame:EnableMouse(false)
    r.frame._questID = nil
    r.frame._isAutoComplete = nil; r.frame._isComplete = nil
    r.frame._recipeID = nil; r.frame._isRecraft = nil
    r._baseR, r._baseG, r._baseB = nil, nil, nil
    r._rowType = nil; r._objIndex = nil; r._objCount = nil
    if r.numFS then r.numFS:Hide() end
    if r.focusBg then r.focusBg:Hide() end
    -- Clean up timer/progressbar sub-widgets
    if r.timerFS     then r.timerFS:Hide()     end
    if r.barBg       then r.barBg:Hide()       end
    if r.barFill     then r.barFill:Hide()     end
    if r.pctFS       then r.pctFS:Hide()       end
    -- Clean up quest icon and LFG button
    if r._questIcon  then r._questIcon:Hide()  end
    if r._lfgBtn     then r._lfgBtn:Hide()     end
    -- Clean up banner sub-widgets
    if r.bannerBg    then r.bannerBg:Hide()    end
    if r.bannerAccent then r.bannerAccent:Hide() end
    if r.bannerIcon  then r.bannerIcon:Hide()  end
    if r.tierFS      then r.tierFS:Hide()      end
    rowPool[#rowPool + 1] = r
end
local function ReleaseAll()
    wipe(EQT.timerRows)
    for i = #EQT.rows, 1, -1 do ReleaseRow(EQT.rows[i]); EQT.rows[i] = nil end
end

-- Section pool
local secPool = {}
local function AcquireSection(parent)
    local s = table.remove(secPool)
    if not s then
        s = {}
        s.frame = CreateFrame("Button", nil, parent)
        s.label = s.frame:CreateFontString(nil, "OVERLAY")
        s.label:SetJustifyH("LEFT")
        s.arrow = s.frame:CreateFontString(nil, "OVERLAY")
        s.arrow:SetJustifyH("CENTER")
        s.line = s.frame:CreateTexture(nil, "ARTWORK")
        s.line:SetHeight(1)
        s.line:SetPoint("BOTTOMLEFT",  s.frame, "BOTTOMLEFT",  0, 0)
        s.line:SetPoint("BOTTOMRIGHT", s.frame, "BOTTOMRIGHT", 0, 0)
        -- Shared handlers set once per section frame (read color from s._scR/G/B)
        s.frame:SetScript("OnEnter", function()
            if EQT._qtMouseoverIn then EQT._qtMouseoverIn() end
            if s._scR then
                s.label:SetTextColor(s._scR + (1 - s._scR) * 0.5, s._scG + (1 - s._scG) * 0.5, s._scB + (1 - s._scB) * 0.5)
            end
        end)
        s.frame:SetScript("OnLeave", function()
            if EQT._qtMouseoverOut then EQT._qtMouseoverOut() end
            if s._scR then s.label:SetTextColor(s._scR, s._scG, s._scB) end
        end)
    end
    s.frame:SetParent(parent); s.frame:EnableMouse(true)
    s.frame:Show(); s.label:Show(); s.arrow:Show(); s.line:Show()
    return s
end
local function ReleaseSection(s)
    s.frame:Hide(); s.frame:ClearAllPoints(); s.frame:SetScript("OnClick", nil)
    s._scR, s._scG, s._scB = nil, nil, nil
    if s.line then s.line:Hide() end
    secPool[#secPool + 1] = s
end

-- Item button pool
local itemPool = {}
-- Item buttons are SecureActionButtonTemplate parented to UIParent.
-- Never reparented or pooled - reparenting secure frames causes taint.
-- Created fresh each Refresh, hidden when not needed.
local allItemBtns = {}  -- all ever-created item buttons

local function AcquireItemBtn()
    -- Find a hidden button or create new one
    for _, b in ipairs(allItemBtns) do
        if not b:IsShown() then
            b._itemID = nil; b._logIdx = nil
            return b
        end
    end
    -- Create new secure button at UIParent level
    local b = CreateFrame("Button", nil, UIParent, "SecureActionButtonTemplate")
    b:SetFrameStrata("HIGH")
    b:RegisterForClicks("AnyUp")
    b:SetAttribute("type", "item")
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(); icon:SetTexCoord(0.07, 0.93, 0.07, 0.93); b._icon = icon
    local cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    cd:SetAllPoints(); b._cd = cd
    b:SetScript("OnEnter", function(self)
        if EQT._qtMouseoverIn then EQT._qtMouseoverIn() end
        if self._itemID then
            local tip = _G.EQT_ItemTooltip
            if not tip then
                tip = CreateFrame("GameTooltip", "EQT_ItemTooltip", UIParent, "GameTooltipTemplate")
                tip:SetFrameStrata("TOOLTIP")
            end
            tip:SetOwner(self, "ANCHOR_LEFT")
            tip:SetItemByID(self._itemID)
            tip:Show()
        end
    end)
    b:SetScript("OnLeave", function()
        if EQT._qtMouseoverOut then EQT._qtMouseoverOut() end
        local tip = _G.EQT_ItemTooltip
        if tip then tip:Hide() end
    end)
    allItemBtns[#allItemBtns + 1] = b
    return b
end
local function ReleaseItemBtn(b)
    b:Hide(); b:ClearAllPoints()
    b._icon:SetTexture(nil)
    b:SetAttribute("item", nil)
end
local function ReleaseAllItems()
    for i = #EQT.itemBtns, 1, -1 do ReleaseItemBtn(EQT.itemBtns[i]); EQT.itemBtns[i] = nil end
end

-------------------------------------------------------------------------------
-- Misc helpers
-------------------------------------------------------------------------------
RemoveWatch = function(qID)
    if C_QuestLog and C_QuestLog.RemoveQuestWatch then C_QuestLog.RemoveQuestWatch(qID) end
end

local function GetQuestItem(qID)
    if not GetQuestLogSpecialItemInfo then return nil end
    local idx = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(qID)
    if not idx or idx == 0 then return nil end
    local name, tex, charges, _, t0, dur, _, _, _, itemID = GetQuestLogSpecialItemInfo(idx)
    if not name then return nil end
    return {itemID=itemID, logIdx=idx, name=name, texture=tex, charges=charges, startTime=t0, duration=dur}
end

local INTERNAL_TITLES = { ["Tracking Quest"]=true, [""]=true }
local function IsInternalTitle(t)
    if not t then return true end
    if INTERNAL_TITLES[t] then return true end
    if t:match("^Level %d+$") then return true end
    return false
end

local _obj_pool = {}
local _obj_pool_n = 0
local _entry_pool = {}
local _entry_pool_n = 0

local function AcquireObj()
    if _obj_pool_n > 0 then
        local o = _obj_pool[_obj_pool_n]
        _obj_pool[_obj_pool_n] = nil
        _obj_pool_n = _obj_pool_n - 1
        return o
    end
    return {}
end

local function AcquireEntry()
    if _entry_pool_n > 0 then
        local e = _entry_pool[_entry_pool_n]
        _entry_pool[_entry_pool_n] = nil
        _entry_pool_n = _entry_pool_n - 1
        return e
    end
    return { objectives = {} }
end

local function RecycleQuestData(lists)
    for _, list in ipairs(lists) do
        for i = 1, #list do
            local entry = list[i]
            if entry.objectives then
                for j = 1, #entry.objectives do
                    local o = entry.objectives[j]
                    _obj_pool_n = _obj_pool_n + 1
                    _obj_pool[_obj_pool_n] = o
                    entry.objectives[j] = nil
                end
            end
            _entry_pool_n = _entry_pool_n + 1
            _entry_pool[_entry_pool_n] = entry
            list[i] = nil
        end
    end
end

local function BuildEntry(info, qID, list)
    local entry = AcquireEntry()
    local objs = entry.objectives
    local objN = 0
    local ot = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(qID)
    if ot then
        for _, o in ipairs(ot) do
            local nf, nr = o.numFulfilled, o.numRequired
            if o.type == "progressbar" then
                local pct = GetQuestProgressBarPercent(qID)
                if pct then
                    nf = pct
                    nr = 100
                end
            end
            local obj = AcquireObj()
            obj.text         = o.text or ""
            obj.finished     = o.finished
            obj.objType      = o.type
            obj.numFulfilled = nf
            obj.numRequired  = nr
            objN = objN + 1
            objs[objN] = obj
        end
    end
    entry.index          = #list + 1
    entry.title          = (info and info.title) or ("Quest #"..qID)
    entry.questID        = qID
    entry.isComplete     = C_QuestLog.IsComplete and C_QuestLog.IsComplete(qID) or false
    entry.isAutoComplete = info and info.isAutoComplete or false
    entry.isFailed       = info and info.isFailed or false
    entry.isTask         = info and info.isTask or false
    list[#list + 1] = entry
end

-------------------------------------------------------------------------------
-- GetScenarioSection
-- Returns a scenario entry when in a Delve/Scenario, with banner info and objectives.
local WIDGET_TYPE_DELVE_HEADER   = (Enum and Enum.UIWidgetVisualizationType and Enum.UIWidgetVisualizationType.ScenarioHeaderDelves) or 29
local WIDGET_TYPE_SCENARIO_TIMER = 20
local WIDGET_TYPE_STATUSBAR      = (Enum and Enum.UIWidgetVisualizationType and Enum.UIWidgetVisualizationType.StatusBar) or 2

local function GetDelveLivesFromHeaderInfo(hi)
    if not hi or not hi.currencies then
        return nil, nil, nil
    end

    for _, c in ipairs(hi.currencies) do
        local tooltip = tostring(c.tooltip or "")
        if tooltip:find("Total deaths") then
            local remaining = tonumber(c.text)
            if remaining then
                local deaths = tonumber(tooltip:match("[Tt]otal deaths:%s*(%d+)")) or 0
                local maxLives = remaining + deaths
                return remaining, maxLives, deaths
            end
        end
    end

    return nil, nil, nil
end

local function AddDelveLivesObjective(objectives, seenText, remaining, maxLives, deaths)
    if not remaining then return end

    local text
    if maxLives and maxLives > 0 then
        text = string.format("Lives Remaining: %d/%d", remaining, maxLives)
    else
        text = string.format("Lives Remaining: %d", remaining)
    end

    if deaths and deaths > 0 then
        text = text .. string.format(" (Deaths: %d)", deaths)
    end

    if seenText[text] then return end
    seenText[text] = true

    table.insert(objectives, 1, {
        text     = text,
        finished = false,
    })
end

local _cachedScenario = nil
local _scenarioDirty = true

local function InvalidateScenarioCache()
    _scenarioDirty = true
end

local function GetScenarioSection()
    if not C_Scenario or not C_Scenario.IsInScenario then return nil end
    if not C_Scenario.IsInScenario() then _cachedScenario = nil; return nil end
    if not _scenarioDirty and _cachedScenario then return _cachedScenario end
    _scenarioDirty = false

    -- Step info: stageName, numCriteria, widgetSetID (index 12)
    local ok, stageName, _, numCriteria, _, _, _, _, _, _, _, widgetSetID = pcall(C_Scenario.GetStepInfo)
    if not ok then return nil end

    -- Prefer C_ScenarioInfo widgetSetID (more reliable)
    if C_ScenarioInfo and C_ScenarioInfo.GetScenarioStepInfo then
        local si = C_ScenarioInfo.GetScenarioStepInfo()
        if si and si.widgetSetID and si.widgetSetID > 0 then
            widgetSetID = si.widgetSetID
        end
    end

    -- Scenario name
    local scenarioName
    local iOk, name = pcall(C_Scenario.GetInfo)
    if iOk and name and name ~= "" then scenarioName = name end

    -- Scan widget sets for Delve header (type 29) to get banner info
    local bannerTitle, bannerIcon, bannerTier = nil, nil, nil
    local isDelve = C_PartyInfo and C_PartyInfo.IsDelveInProgress and C_PartyInfo.IsDelveInProgress()
    local delveLivesCur, delveLivesMax, delveDeathsUsed = nil, nil, nil

    local setsToScan = {}
    if widgetSetID and widgetSetID ~= 0 then setsToScan[#setsToScan+1] = widgetSetID end
    if C_UIWidgetManager and C_UIWidgetManager.GetObjectiveTrackerWidgetSetID then
        local otSet = C_UIWidgetManager.GetObjectiveTrackerWidgetSetID()
        if otSet and otSet ~= 0 and otSet ~= widgetSetID then setsToScan[#setsToScan+1] = otSet end
    end

    for _, setID in ipairs(setsToScan) do
        if C_UIWidgetManager and C_UIWidgetManager.GetAllWidgetsBySetID then
            local wOk, widgets = pcall(C_UIWidgetManager.GetAllWidgetsBySetID, setID)
            if wOk and widgets then
                for _, w in ipairs(widgets) do
                    local wType = w.widgetType
                    local wID   = w.widgetID
                    -- Delve header widget
                    if wType == WIDGET_TYPE_DELVE_HEADER and
                       C_UIWidgetManager.GetScenarioHeaderDelvesWidgetVisualizationInfo then
                        local dOk, wi = pcall(C_UIWidgetManager.GetScenarioHeaderDelvesWidgetVisualizationInfo, wID)
                        if dOk and wi then
                            bannerTitle = (wi.headerText and wi.headerText ~= "") and wi.headerText or bannerTitle
                            bannerTier  = (wi.tierText   and wi.tierText   ~= "") and wi.tierText  or bannerTier
                            bannerIcon  = wi.atlasIcon or wi.icon or bannerIcon

                            local livesCur, livesMax, deathsUsed = GetDelveLivesFromHeaderInfo(wi)
                            if livesCur ~= nil then
                                delveLivesCur = livesCur
                                delveLivesMax = livesMax
                                delveDeathsUsed = deathsUsed
                            end
                            isDelve = true
                        end
                    end
                end
            end
        end
        if bannerTitle then break end
    end

    -- Build display title
    local title
    if isDelve then
        title = bannerTitle or scenarioName or "Delve"
    elseif scenarioName and stageName and stageName ~= "" then
        title = scenarioName .. " - " .. stageName
    elseif stageName and stageName ~= "" then
        title = stageName
    else
        title = scenarioName or "Scenario"
    end

    -- Objectives from criteria
    local objectives = {}
    local seenText = {}
    local timerDuration, timerStartTime = nil, nil

    if C_ScenarioInfo then
        for i = 1, (numCriteria or 0) + 3 do
            local cOk, crit
            if C_ScenarioInfo.GetCriteriaInfoByStep then
                cOk, crit = pcall(C_ScenarioInfo.GetCriteriaInfoByStep, 1, i)
            end
            if (not cOk or not crit) and C_ScenarioInfo.GetCriteriaInfo then
                cOk, crit = pcall(C_ScenarioInfo.GetCriteriaInfo, i)
            end
            if cOk and crit then
                -- Extract timer from criteria (duration/elapsed fields)
                if not timerDuration and crit.duration and crit.duration > 0 then
                    local elapsed = math.max(0, math.min(crit.elapsed or 0, crit.duration))
                    if elapsed < crit.duration then
                        timerDuration  = crit.duration
                        timerStartTime = GetTime() - elapsed
                    end
                end

                local desc = (crit.description and crit.description ~= "") and crit.description
                          or (crit.criteriaString and crit.criteriaString ~= "") and crit.criteriaString
                          or nil
                if desc then
                local numFulfilled = crit.quantity      or 0
                local numRequired  = crit.totalQuantity or 0

                local displayText
                if crit.isWeightedProgress then
                    -- quantity is 0-100 percentage
                    local pct = math.min(100, math.max(0, math.floor(numFulfilled)))
                    displayText = desc
                    if not seenText[displayText] then
                        seenText[displayText] = true
                        table.insert(objectives, {
                            text         = displayText,
                            finished     = crit.completed or false,
                            numFulfilled = pct,
                            numRequired  = 100,
                            objType      = "progressbar",
                        })
                    end
                elseif numRequired > 0 then
                    displayText = string.format("%d/%d %s", numFulfilled, numRequired, desc)
                    if not seenText[displayText] then
                        seenText[displayText] = true
                        local isBar = numRequired > 1
                        table.insert(objectives, {
                            text         = displayText,
                            finished     = crit.completed or false,
                            numFulfilled = isBar and numFulfilled or nil,
                            numRequired  = isBar and numRequired  or nil,
                            objType      = isBar and "progressbar" or nil,
                        })
                    end
                else
                    displayText = desc
                    if not seenText[displayText] then
                        seenText[displayText] = true
                        table.insert(objectives, {
                            text     = displayText,
                            finished = crit.completed or false,
                        })
                    end
                end
                end -- if desc
            end
        end
    end

    -- Criteria timer fallback: widget timer
    if not timerDuration then
        local dur, start = GetQuestTimer(0) -- 0 = use scenario widget timer path
        -- Actually call widget timer directly
        for _, setID in ipairs(setsToScan) do
            if C_UIWidgetManager and C_UIWidgetManager.GetAllWidgetsBySetID then
                local wOk, wids = pcall(C_UIWidgetManager.GetAllWidgetsBySetID, setID)
                if wOk and wids then
                    for _, w in ipairs(wids) do
                        if w.widgetType == WIDGET_TYPE_SCENARIO_TIMER and
                           C_UIWidgetManager.GetScenarioHeaderTimerWidgetVisualizationInfo then
                            local ti = C_UIWidgetManager.GetScenarioHeaderTimerWidgetVisualizationInfo(w.widgetID)
                            if ti and ti.shownState == 1 then
                                local tMin = ti.timerMin or 0
                                local duration = (ti.timerMax or 0) - tMin
                                local remaining = (ti.timerValue or 0) - tMin
                                if remaining > 0 and duration > 0 then
                                    timerDuration  = duration
                                    timerStartTime = GetTime() - (duration - remaining)
                                end
                            end
                        end
                    end
                end
            end
            if timerDuration then break end
        end
    end

    -- StatusBar widgets as progress objectives
    for _, setID in ipairs(setsToScan) do
        if C_UIWidgetManager and C_UIWidgetManager.GetAllWidgetsBySetID then
            local wOk, widgets = pcall(C_UIWidgetManager.GetAllWidgetsBySetID, setID)
            if wOk and widgets then
                for _, w in ipairs(widgets) do
                    if w.widgetType == WIDGET_TYPE_STATUSBAR and
                       C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo then
                        local si = C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo(w.widgetID)
                        if si and si.barMax and si.barMax > 0 then
                            local text = (si.overrideBarText ~= "" and si.overrideBarText) or si.text or ""
                            if not seenText[text] then
                                seenText[text] = true
                                table.insert(objectives, {
                                    text         = text,
                                    finished     = false,
                                    numFulfilled = si.barValue,
                                    numRequired  = si.barMax,
                                    objType      = "progressbar",
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    if #objectives == 0 and title == "Scenario" then _cachedScenario = nil; return nil end

    _cachedScenario = {
        title          = title,
        objectives     = objectives,
        isDelve        = isDelve,
        bannerIcon     = bannerIcon,
        bannerTier     = bannerTier,
        delveLives     = (isDelve and delveLivesCur) and delveLivesCur or nil,
        delveLivesMax  = (isDelve and delveLivesMax) and delveLivesMax or nil,
        timerDuration  = timerDuration,
        timerStartTime = timerStartTime,
    }
    return _cachedScenario
end

-------------------------------------------------------------------------------
-- Prey quest detection
-- Prey quests: Recurring or Meta classification with "Prey" in title,
-- or weekly/recurring frequency with "Prey" in title.
-- @param qID  number  quest ID
-- @param info table   (optional) C_QuestLog.GetInfo result already fetched by caller
local function IsPreyQuest(qID, info)
    if not qID then return false end
    local title = info and info.title
        or (C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(qID))
    if not title or not title:find("Prey", 1, true) then return false end

    if C_QuestInfoSystem and C_QuestInfoSystem.GetQuestClassification and Enum and Enum.QuestClassification then
        local ok, qc = pcall(C_QuestInfoSystem.GetQuestClassification, qID)
        if ok and qc then
            if qc == Enum.QuestClassification.Recurring then return true end
            if qc == Enum.QuestClassification.Meta then return true end
        end
    end

    -- Use caller-provided info when available to avoid redundant GetInfo call
    local freq = info and info.frequency
    if freq == nil then
        local idx = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(qID)
        if idx then
            local ok, fetched = pcall(C_QuestLog.GetInfo, idx)
            if ok and fetched then freq = fetched.frequency end
        end
    end
    if freq ~= nil then
        local isWeekly = freq == 2 or freq == 3
            or (Enum and Enum.QuestFrequency and freq == Enum.QuestFrequency.Weekly)
            or (LE_QUEST_FREQUENCY_WEEKLY and freq == LE_QUEST_FREQUENCY_WEEKLY)
        if isWeekly then return true end
    end

    return false
end

-------------------------------------------------------------------------------
-- Quest type icon atlases
-------------------------------------------------------------------------------
local QUEST_ICON_ATLAS = {
    campaign   = "Crosshair_campaignquest_32",
    legendary  = "Crosshair_legendaryquest_32",
    important  = "Crosshair_important_48",
    recurring  = "Crosshair_Recurring_48",
    daily      = "Crosshair_Recurring_48",
    weekly     = "Crosshair_Recurring_48",
    meta       = "Crosshair_Wrapper_48",
}

local QUEST_TURNIN_ATLAS = {
    campaign   = "Crosshair_campaignquestturnin_32",
    legendary  = "Crosshair_legendaryquestturnin_32",
    important  = "Crosshair_importantturnin_48",
    recurring  = "Crosshair_Recurringturnin_48",
    daily      = "Crosshair_Recurringturnin_48",
    weekly     = "Crosshair_Recurringturnin_48",
    meta       = "Crosshair_Wrapperturnin_48",
}

local QUEST_ICON_SIZE_OVERRIDE = {
    recurring  = 18,
    daily      = 18,
    weekly     = 18,
    important  = 22,
}

local QUEST_ICON_SIZE   = 16
local TURNIN_ICON_SIZE  = 26  -- turn-in atlases render small natively

local function GetQuestIconAtlas(questID)
    if not questID then return nil, false end

    local logIdx = C_QuestLog.GetLogIndexForQuestID(questID)
    local info   = logIdx and C_QuestLog.GetInfo(logIdx)
    local cls    = info and info.questClassification
    local freq   = info and info.frequency or 0
    local done   = C_QuestLog.IsComplete(questID)

    local key = "normal"
    if C_CampaignInfo and C_CampaignInfo.IsCampaignQuest
       and C_CampaignInfo.IsCampaignQuest(questID) then
        key = "campaign"
    elseif cls then
        local QC = Enum.QuestClassification
        if     cls == QC.Important then key = "important"
        elseif cls == QC.Legendary then key = "legendary"
        elseif cls == QC.Campaign  then key = "campaign"
        elseif cls == QC.Calling   then key = "calling"
        elseif cls == QC.Questline then key = "questline"
        elseif cls == QC.Recurring then key = "recurring"
        end
    end

    if key == "normal" then
        if freq == 1 then key = "daily"
        elseif freq == 2 then key = "weekly"
        else
            local tag = C_QuestLog.GetQuestTagInfo(questID)
            if tag and tag.tagID then
                local id = tag.tagID
                if id == 81 or id == 85 then key = "dungeon"
                elseif id == 62 or id == 88 or id == 89 then key = "raid"
                elseif id == 83 then key = "legendary"
                end
            end
        end
    end

    if done and QUEST_TURNIN_ATLAS[key] then
        return QUEST_TURNIN_ATLAS[key], true, key
    end
    return QUEST_ICON_ATLAS[key], false, key
end

-------------------------------------------------------------------------------
-- TryCompleteQuest
-- Attempts to open the quest completion dialog for auto-complete quests.
local function TryCompleteQuest(qID)
    if not qID or not C_QuestLog then return false end
    if not C_QuestLog.IsComplete(qID) then return false end
    if C_QuestLog.SetSelectedQuest then
        C_QuestLog.SetSelectedQuest(qID)
    end
    if ShowQuestComplete and type(ShowQuestComplete) == "function" then
        local ok = pcall(ShowQuestComplete, qID)
        if ok then return true end
    end
    return false
end

-- GetQuestLists
-------------------------------------------------------------------------------
-- Cache which section each quest was last assigned to so quests don't
-- jump between sections on non-structural refreshes (progress updates, etc.)
-- Cleared on zone change or structural quest events.
local questSectionCache = {}  -- qID -> "watched" | "zone" | "world" | "prey"

-- Shared quest log scan: single iteration used by zone snapshot,
-- GetQuestLists, and UpdateQuestItemAttribute.
local _qlScanResult = {}   -- array of {info, index, questID}
local _qlScanStale = true

local function ScanQuestLog()
    if not _qlScanStale then return _qlScanResult end
    _qlScanStale = false
    local n2 = #_qlScanResult
    for k = 1, n2 do _qlScanResult[k] = nil end
    if not C_QuestLog or not C_QuestLog.GetNumQuestLogEntries then return _qlScanResult end
    local n = C_QuestLog.GetNumQuestLogEntries()
    local cnt = 0
    for i = 1, n do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and not info.isInternalOnly and info.questID then
            cnt = cnt + 1
            local e = _qlScanResult[cnt]
            if not e then e = {}; _qlScanResult[cnt] = e end
            e.info = info; e.index = i; e.questID = info.questID
        end
    end
    -- Clear excess entries from previous scan
    for k = cnt + 1, n2 do _qlScanResult[k] = nil end
    return _qlScanResult
end

local function InvalidateQuestLogCache()
    _qlScanStale = true
end

-- Stable snapshot of which quests are zone-relevant. Built from isOnMap
-- at cache-clear time only, so super-track changes can't cause flicker.
local zoneQuestSnapshot = {}  -- qID -> true

local function RebuildZoneSnapshot()
    wipe(zoneQuestSnapshot)
    local entries = ScanQuestLog()
    for _, e in ipairs(entries) do
        if e.info.isOnMap then
            zoneQuestSnapshot[e.questID] = true
        end
    end
end

function EQT:ClearSectionCache()
    wipe(questSectionCache)
    InvalidateQuestLogCache()
    RebuildZoneSnapshot()
end

local _ql_active, _ql_watched, _ql_zone, _ql_world, _ql_prey, _ql_seen = {}, {}, {}, {}, {}, {}
local _questListsCached = false

local function GetQuestLists()
    -- Return cached lists for progress-only refreshes
    if _questListsCached and not _structuralDirty then
        return _ql_active, _ql_watched, _ql_zone, _ql_world, _ql_prey
    end

    -- Recycle previous entries back to pools before wiping
    RecycleQuestData({ _ql_active, _ql_watched, _ql_zone, _ql_world, _ql_prey })
    local active  = _ql_active
    local watched = _ql_watched
    local zone    = _ql_zone
    local world   = _ql_world
    local prey    = _ql_prey
    local seen    = wipe(_ql_seen)

    if not C_QuestLog then return active, watched, zone, world, prey end
    local entries = ScanQuestLog()
    local db = DB()
    local cfgPrey  = db.showPreyQuests
    local cfgZone  = db.showZoneQuests
    local cfgWorld = db.showWorldQuests

    for _, e in ipairs(entries) do
        local info = e.info
        local qID = e.questID
        if qID and not seen[qID] then
            -- isTask quests may have isHidden=true in TWW - allow them through
            local skipHidden = info.isHidden and not info.isTask
            if not skipHidden then
                local tracked = false
                if C_QuestLog.GetQuestWatchType then
                    local wt = C_QuestLog.GetQuestWatchType(qID)
                    tracked = (wt ~= nil)
                end
                if not tracked and C_QuestLog.IsQuestWatched then
                    tracked = C_QuestLog.IsQuestWatched(qID) == true
                end

                local onMap = zoneQuestSnapshot[qID]

                -- Active world quest: task quests the player is physically inside
                local isActiveWQ = info.isTask and C_TaskQuest
                    and C_TaskQuest.IsActive and C_TaskQuest.IsActive(qID)

                local section
                if isActiveWQ then
                    section = "active"
                elseif cfgPrey and IsPreyQuest(qID, info) then
                    section = "prey"
                elseif tracked then
                    if cfgZone and onMap and not info.isTask then
                        section = "zone"
                    else
                        section = "watched"
                    end
                elseif info.isTask then
                    if cfgWorld and not IsInternalTitle(info.title) then
                        section = "world"
                    end
                elseif onMap and tracked then
                    if cfgZone then
                        section = "zone"
                    end
                end

                -- Don't cache active WQ section -- it changes dynamically
                -- as the player moves in/out of quest areas.
                local cached = questSectionCache[qID]
                if cached and not isActiveWQ then
                    section = cached
                end

                if section then
                    if section ~= "active" then
                        questSectionCache[qID] = section
                    end
                    seen[qID] = true
                    if section == "active" then
                        BuildEntry(info, qID, active)
                    elseif section == "prey" then
                        BuildEntry(info, qID, prey)
                    elseif section == "zone" then
                        BuildEntry(info, qID, zone)
                    elseif section == "world" then
                        BuildEntry(info, qID, world)
                    else
                        BuildEntry(info, qID, watched)
                    end
                end
            end
        end
    end

    _questListsCached = true
    return active, watched, zone, world, prey
end

-------------------------------------------------------------------------------
-- Tracked Recipes
-------------------------------------------------------------------------------
local _recipes = {}
local _recipe_entries = {}   -- reusable entry tables
local _reagent_pool = {}     -- reusable reagent tables
local _reagent_pool_n = 0

local function GetTrackedRecipes()
    -- Recycle reagent tables from previous call
    for i = 1, #_recipes do
        local e = _recipes[i]
        if e and e.reagents then
            for j = 1, #e.reagents do
                _reagent_pool_n = _reagent_pool_n + 1
                _reagent_pool[_reagent_pool_n] = e.reagents[j]
                e.reagents[j] = nil
            end
        end
        _recipes[i] = nil
    end

    if not C_TradeSkillUI or not C_TradeSkillUI.GetRecipesTracked then return _recipes end

    local tracked = C_TradeSkillUI.GetRecipesTracked(false)
    local recraft = C_TradeSkillUI.GetRecipesTracked(true)

    if recraft then
        for _, v in ipairs(recraft) do
            if type(v) == "table" then v._isRecraft = true end
            tracked[#tracked + 1] = v
        end
    end
    if not tracked or #tracked == 0 then return _recipes end

    local listN = 0
    for _, tracked_entry in ipairs(tracked) do
        local recipeID = type(tracked_entry) == "table" and (tracked_entry.recipeID or tracked_entry.recipeSchematicID) or tracked_entry
        if recipeID then
            local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
            if ok and schematic then
                listN = listN + 1
                local entry = _recipe_entries[listN]
                if not entry then
                    entry = { reagents = {} }
                    _recipe_entries[listN] = entry
                end
                entry.recipeID = recipeID
                entry.isRecraft = (type(tracked_entry) == "table" and tracked_entry._isRecraft) or false
                entry.name = schematic.name or ("Recipe #"..recipeID)
                local reagentN = 0
                if schematic.reagentSlotSchematics then
                    for _, slot in ipairs(schematic.reagentSlotSchematics) do
                        if slot.reagentType == 1 and slot.reagents and #slot.reagents > 0 then
                            -- One row per slot; sum owned across all quality tiers
                            local firstName, totalOwned = nil, 0
                            for _, reagent in ipairs(slot.reagents) do
                                local itemID = reagent.itemID
                                if itemID then
                                    if not firstName then
                                        firstName = C_Item.GetItemNameByID(itemID) or ("Item "..itemID)
                                    end
                                    totalOwned = totalOwned + (C_Item.GetItemCount(itemID, true) or 0)
                                end
                            end
                            if firstName then
                                local r
                                if _reagent_pool_n > 0 then
                                    r = _reagent_pool[_reagent_pool_n]
                                    _reagent_pool[_reagent_pool_n] = nil
                                    _reagent_pool_n = _reagent_pool_n - 1
                                else
                                    r = {}
                                end
                                r.name = firstName
                                r.owned = totalOwned
                                r.needed = slot.quantityRequired or 1
                                r.finished = totalOwned >= r.needed
                                reagentN = reagentN + 1
                                entry.reagents[reagentN] = r
                            end
                        end
                    end
                end
                _recipes[listN] = entry
            end
        end
    end
    return _recipes
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------
local PAD_H    = 8
local PAD_V    = 6
local TXT_PAD  = 5
local ROW_GAP  = 1
local SEC_GAP  = 5
local ITEM_PAD = 3
local BAR_H    = 9   -- progress bar height (doubled)
local BAR_PAD  = 2   -- gap between text and bar

-- Forward declaration; defined after BuildFrame
local UpdateInnerAlignment

-- Combat deferral: Refresh touches secure quest item buttons (SetAttribute),
-- which is forbidden during combat. Defer until PLAYER_REGEN_ENABLED.
local _refreshPendingAfterCombat = false
local _refreshSkipAlphaFlash = false

function EQT:Refresh(skipAlphaFlash)
    if InCombatLockdown() then
        _refreshPendingAfterCombat = true
        _refreshSkipAlphaFlash = skipAlphaFlash
        return
    end
    local f = self.frame
    if not f then return end
    -- Full rebuild: invalidate caches so data is fresh
    InvalidateQuestLogCache()
    _questListsCached = false
    _structuralDirty = false
    local content = f.content
    -- Cache DB once for entire refresh
    local db      = DB()
    local width   = db.width or 325
    local tc      = db.titleColor  or C.header
    local oc      = db.objColor    or { r=0.9, g=0.9, b=0.9 }
    local cc      = db.completedColor or C.complete
    local fc      = db.focusedColor or { r=0.871, g=0.251, b=1.0 }
    local ffs     = db.focusedFontSize
    local fbgA    = (db.focusBgOpacity or 0) / 100
    local iqSize  = db.questItemSize or 22
    local sc      = db.secColor or C.section
    local compFS  = db.completedFontSize
    local superQID = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()

    -- Hide content during teardown+rebuild to prevent single-frame flicker.
    -- Skip when triggered by resize (content is already visible at ~correct size).
    if f.inner and not skipAlphaFlash then f.inner:SetAlpha(0) end

    ReleaseAll(); ReleaseAllItems()
    for i = #self.sections, 1, -1 do ReleaseSection(self.sections[i]); self.sections[i] = nil end

    if f.bg then f.bg:SetColorTexture(db.bgR or 0, db.bgG or 0, db.bgB or 0, db.bgAlpha or 0.35) end
    if f.topLine then
        f.topLine:SetColorTexture(sc.r, sc.g, sc.b, 0.7)
    end
    f:SetWidth(width)
    local contentW = math.max(10, width - PAD_H * 2 - 10)
    content:SetWidth(contentW)
    -- Row width for explicit SetWidth before measuring text height (anchors may not resolve in time)
    local rowW = contentW - TXT_PAD

    local yOff = 0
    local sfp, sfs, sff = SecFont()
    local arrowSize = math.max(sfs + 4, 13)
    local arrowFont = SafeFont(GlobalFont())
    local scR, scG, scB = sc.r, sc.g, sc.b

    local function AddCollapsibleSection(label, isCollapsed, onToggle)
        local s = AcquireSection(content)
        s._scR, s._scG, s._scB = scR, scG, scB
        SetFontSafe(s.label, sfp, sfs, sff)
        s.label:SetTextColor(scR, scG, scB)
        ApplyFontShadow(s.label)
        s.label:SetText(label)
        s.label:ClearAllPoints()
        s.label:SetPoint("LEFT",  s.frame, "LEFT",  0, 3)
        s.label:SetPoint("RIGHT", s.frame, "RIGHT", -(arrowSize + 4), 3)
        SetFontSafe(s.arrow, arrowFont, arrowSize, OutlineFlag())
        s.arrow:SetTextColor(scR, scG, scB)
        s.arrow:SetText(isCollapsed and "+" or "-")
        s.arrow:ClearAllPoints()
        s.arrow:SetPoint("RIGHT", s.frame, "RIGHT", 0, 3)
        s.arrow:SetWidth(arrowSize + 4)
        s.line:SetColorTexture(scR, scG, scB, 0.4)
        local textH = math.max(sfs + 6, arrowSize + 2)
        local h = textH + 5 + 1
        s.frame:SetHeight(h)
        s.frame:SetPoint("TOPLEFT",  content, "TOPLEFT",  TXT_PAD, -yOff)
        s.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -yOff)
        s.frame:SetScript("OnClick", onToggle)
        yOff = yOff + h + SEC_GAP
        self.sections[#self.sections + 1] = s
    end

    local function AddPlainSection(label)
        local s = AcquireSection(content)
        s._scR, s._scG, s._scB = scR, scG, scB
        SetFontSafe(s.label, sfp, sfs, sff)
        s.label:SetTextColor(scR, scG, scB)
        s.label:SetText(label)
        s.label:ClearAllPoints()
        s.label:SetPoint("LEFT",  s.frame, "LEFT",  0, 3)
        s.label:SetPoint("RIGHT", s.frame, "RIGHT", 0, 3)
        SetFontSafe(s.arrow, sfp, sfs, sff); s.arrow:SetText("")
        s.line:SetColorTexture(scR, scG, scB, 0.4)
        local textH = math.max(sfs + 6, 12)
        local h = textH + 5 + 1
        s.frame:SetHeight(h)
        s.frame:SetPoint("TOPLEFT",  content, "TOPLEFT",  TXT_PAD, -yOff)
        s.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -yOff)
        yOff = yOff + h + SEC_GAP
        self.sections[#self.sections + 1] = s
    end

    local tfp, tfs, tff = TitleFont()
    local ofp, ofs, off = ObjFont()

    -- Timer row: countdown text + shrinking bar
    local function AddTimerRow(questID, isAutoComplete, presetDuration, presetStartTime)
        local duration = presetDuration
        local startTime = presetStartTime
        if not duration or not startTime then
            duration, startTime = GetQuestTimer(questID)
        end
        if not duration or not startTime then return end

        local TIMER_BAR_H = BAR_H + 2
        local TEXT_H      = math.max(ofs, 10)
        local TOTAL_H     = TEXT_H + 4 + TIMER_BAR_H + 4

        local r = AcquireRow(content)
        r.frame:SetHeight(TOTAL_H)
        r.frame:SetPoint("TOPLEFT",  content, "TOPLEFT",  TXT_PAD, -yOff)
        r.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -yOff)

        -- Countdown text
        SetFontSafe(r.text, ofp, TEXT_H, OutlineFlag())
        r.text:ClearAllPoints()
        r.text:SetPoint("TOPLEFT",  r.frame, "TOPLEFT",  20, 0)
        r.text:SetPoint("TOPRIGHT", r.frame, "TOPRIGHT", -4, 0)
        r.text:SetHeight(TEXT_H + 2)
        r.text:Show()

        -- Timer bar background (reuse existing texture)
        if not r.barBg then
            r.barBg = r.frame:CreateTexture(nil, "BACKGROUND")
        end
        r.barBg:SetColorTexture(C.barBg.r, C.barBg.g, C.barBg.b, 0.8)
        r.barBg:ClearAllPoints()
        r.barBg:SetPoint("TOPLEFT",  r.frame, "TOPLEFT",  14, -(TEXT_H + 4))
        r.barBg:SetPoint("TOPRIGHT", r.frame, "TOPRIGHT", -4, -(TEXT_H + 4))
        r.barBg:SetHeight(TIMER_BAR_H)
        r.barBg:Show()

        -- Timer bar fill (reuse existing texture)
        if not r.barFill then
            r.barFill = r.frame:CreateTexture(nil, "ARTWORK")
        end
        r.barFill:SetColorTexture(C.timer.r, C.timer.g, C.timer.b, 0.85)
        r.barFill:ClearAllPoints()
        r.barFill:SetPoint("TOPLEFT",    r.barBg, "TOPLEFT",    0, 0)
        r.barFill:SetPoint("BOTTOMLEFT", r.barBg, "BOTTOMLEFT", 0, 0)
        r.barFill:Show()

        local function UpdateTimer()
            if not r.text or not r.frame:IsShown() then return end
            local remaining = duration - (GetTime() - startTime)
            if remaining < 0 then remaining = 0 end
            -- Text
            r.text:SetText(FormatTimeLeft(remaining))
            if remaining < 30 then
                r.text:SetTextColor(C.timerLow.r, C.timerLow.g, C.timerLow.b)
                r.barFill:SetColorTexture(C.timerLow.r, C.timerLow.g, C.timerLow.b, 0.9)
            elseif remaining < 120 then
                r.text:SetTextColor(1, 0.9, 0.3)
                r.barFill:SetColorTexture(1, 0.9, 0.3, 0.85)
            else
                r.text:SetTextColor(C.timer.r, C.timer.g, C.timer.b)
                r.barFill:SetColorTexture(C.timer.r, C.timer.g, C.timer.b, 0.85)
            end
            -- Shrink bar proportionally
            local barW = r.barBg:GetWidth()
            if barW and barW > 0 then
                local pct = math.max(0, math.min(1, remaining / duration))
                r.barFill:SetWidth(math.max(1, barW * pct))
            end
        end
        UpdateTimer()

        yOff = yOff + TOTAL_H + ROW_GAP + 2
        self.rows[#self.rows + 1] = r
        r._updateTimer = UpdateTimer
        self.timerRows[#self.timerRows + 1] = r
    end

    local _curObjQuestID = nil  -- set by RenderList before objectives
    local _curObjIndex = 0

    -- Progress bar row
    local function AddProgressRow(cur, max)
        local r = AcquireRow(content)
        r.text:Hide()

        local pct = math.max(0, math.min(1, cur / max))
        local barW = (content:GetWidth() or width - PAD_H*2) - 14 - 30

        -- Background
        if not r.barBg then
            r.barBg = r.frame:CreateTexture(nil, "BACKGROUND")
        end
        r.barBg:SetColorTexture(C.barBg.r, C.barBg.g, C.barBg.b, 0.8)
        r.barBg:ClearAllPoints()
        r.barBg:SetPoint("TOPLEFT",  r.frame, "TOPLEFT",  14, -2)
        r.barBg:SetPoint("TOPRIGHT", r.frame, "TOPRIGHT", -30, -2)
        r.barBg:SetHeight(BAR_H)
        r.barBg:Show()

        -- Fill
        if not r.barFill then
            r.barFill = r.frame:CreateTexture(nil, "ARTWORK")
        end
        r.barFill:SetColorTexture(C.barFill.r, C.barFill.g, C.barFill.b, 0.9)
        r.barFill:ClearAllPoints()
        r.barFill:SetPoint("TOPLEFT", r.barBg, "TOPLEFT", 0, 0)
        r.barFill:SetHeight(BAR_H)
        local targetW = math.max(1, barW * pct)
        local prevW = r._barTargetW or targetW
        if prevW ~= targetW then
            local startW = r.barFill:GetWidth() or prevW
            local elapsed = 0
            local fill = r.barFill
            r.frame:SetScript("OnUpdate", function(self, dt)
                elapsed = elapsed + dt
                local t = math.min(elapsed / 0.3, 1)
                fill:SetWidth(math.max(1, startW + (targetW - startW) * t))
                if t >= 1 then self:SetScript("OnUpdate", nil) end
            end)
        else
            r.barFill:SetWidth(targetW)
            r.frame:SetScript("OnUpdate", nil)
        end
        r._barTargetW = targetW
        r.barFill:Show()

        -- Percentage text (reuse existing font string)
        if not r.pctFS then
            r.pctFS = r.frame:CreateFontString(nil, "OVERLAY")
        end
        SetFontSafe(r.pctFS, GlobalFont(), BAR_H + 2, OutlineFlag())
        r.pctFS:SetJustifyH("RIGHT")
        r.pctFS:SetJustifyV("MIDDLE")
        r.pctFS:SetTextColor(1, 1, 1)
        r.pctFS:SetText(math.floor(pct * 100 + 0.5).."%")
        r.pctFS:ClearAllPoints()
        r.pctFS:SetPoint("RIGHT",  r.frame,  "RIGHT",  0, 0)
        r.pctFS:SetPoint("TOP",    r.barBg,  "TOP",    0, 0)
        r.pctFS:SetPoint("BOTTOM", r.barBg,  "BOTTOM", 0, 0)
        r.pctFS:SetWidth(30)
        r.pctFS:Show()

        local rh = BAR_H + BAR_PAD * 2 + 2
        r.frame:SetHeight(rh)
        r.frame:SetPoint("TOPLEFT",  content, "TOPLEFT",  TXT_PAD, -yOff)
        r.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -yOff)
        r._rowType = "progress"
        r.frame._questID = _curObjQuestID
        r._objIndex = _curObjIndex
        yOff = yOff + rh + ROW_GAP
        self.rows[#self.rows + 1] = r
    end

    local function AddTitleRow(text, cr, cg, cb, qID, isAutoComplete, isComplete, recipeID, isRecraft)
        local r = AcquireRow(content)
        if r.numFS then r.numFS:Hide() end
        SetFontSafe(r.text, tfp, tfs, tff)
        r.text:SetTextColor(cr, cg, cb)
        r._baseR, r._baseG, r._baseB = cr, cg, cb
        ApplyFontShadow(r.text)
        r.text:SetText(text)
        r.text:Show()
        local item = db.showQuestItems and qID and GetQuestItem(qID)
        -- Quest type icon (separate texture, far right)
        local questAtlas, isTurnIn, questKey
        if qID then questAtlas, isTurnIn, questKey = GetQuestIconAtlas(qID) end
        local iconPad = 0
        if questAtlas then
            if not r._questIcon then
                local ico = r.frame:CreateTexture(nil, "OVERLAY")
                r._questIcon = ico
            end
            local ICON_SZ = (questKey and QUEST_ICON_SIZE_OVERRIDE[questKey]) or 20
            r._questIcon:SetSize(ICON_SZ, ICON_SZ)
            r._questIcon:SetAtlas(questAtlas)
            r._questIcon:ClearAllPoints()
            r._questIcon:SetPoint("RIGHT", r.frame, "RIGHT", -2, 0)
            r._questIcon:Show()
            iconPad = ICON_SZ + 4
        elseif r._questIcon then
            r._questIcon:Hide()
        end
        local rightPad = (item and (iqSize + ITEM_PAD * 2) or 0) + iconPad
        r.text:ClearAllPoints()
        r.text:SetPoint("TOPLEFT",  r.frame, "TOPLEFT",  2, 0)
        r.text:SetPoint("TOPRIGHT", r.frame, "TOPRIGHT", -rightPad, 0)
        r.frame:SetWidth(rowW)
        r.frame:SetPoint("TOPLEFT",  content, "TOPLEFT",  TXT_PAD, -yOff)
        r.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -yOff)
        -- Force text width so GetStringHeight respects word wrap on first layout
        r.text:SetWidth(rowW - 2 - rightPad)
        local th = r.text:GetStringHeight()
        if th < tfs then th = tfs end
        local rh = math.max(th + 4, item and iqSize or 0)
        r.frame:SetHeight(rh); r.text:SetHeight(rh)
        -- Focus highlight for super-tracked quest
        if qID and superQID and qID == superQID and fbgA > 0 then
            if not r.focusBg then
                r.focusBg = r.frame:CreateTexture(nil, "BACKGROUND")
                r.focusBg:SetAllPoints(r.frame)
            end
            r.focusBg:SetColorTexture(fc.r, fc.g, fc.b, fbgA)
            r.focusBg:Show()
        elseif r.focusBg then
            r.focusBg:Hide()
        end
        if item then
            local btn = AcquireItemBtn()
            btn:SetSize(iqSize, iqSize)
            -- Anchor to r.frame but parented to UIParent - use SetPoint with explicit frame ref
            btn:SetPoint("RIGHT", r.frame, "RIGHT", -ITEM_PAD, 0)
            btn:SetFrameLevel(r.frame:GetFrameLevel() + 2)
            btn._icon:SetTexture(item.texture); btn._itemID = item.itemID; btn._logIdx = item.logIdx
            -- Set item attribute directly (we are outside combat at Refresh time)
            if not InCombatLockdown() then btn:SetAttribute("item", item.name) end
            if item.startTime and item.startTime > 0 and item.duration and item.duration > 0 then
                btn._cd:SetCooldown(item.startTime, item.duration); btn._cd:Show()
            else btn._cd:Hide() end
            if item.charges and item.charges > 0 then
                if not btn._chargeFS then
                    btn._chargeFS = btn:CreateFontString(nil, "OVERLAY")
                    SetFontSafe(btn._chargeFS, GlobalFont(), 9, OutlineFlag())
                    btn._chargeFS:SetTextColor(1,1,1)
                    btn._chargeFS:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 2)
                end
                btn._chargeFS:SetText(item.charges); btn._chargeFS:Show()
            elseif btn._chargeFS then btn._chargeFS:Hide() end
            self.itemBtns[#self.itemBtns + 1] = btn
        end
        -- Find Group eyeball button for elite world quests
        if qID then
            local tag = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(qID)
            local showGroupFinder = tag and tag.isElite and tag.worldQuestType
            local activityID = showGroupFinder
            if activityID then
                if not r._lfgBtn then
                    local btn = CreateFrame("Button", nil, r.frame)
                    btn:SetSize(20, 20)
                    btn:SetFrameLevel(r.frame:GetFrameLevel() + 3)
                    local ico = btn:CreateTexture(nil, "ARTWORK")
                    ico:SetAllPoints()
                    ico:SetAtlas("socialqueuing-icon-eye")
                    btn._ico = ico
                    btn:SetAlpha(1)
                    btn:SetScript("OnEnter", function(self)
                        EllesmereUI.ShowWidgetTooltip(self, "Find a Group")
                    end)
                    btn:SetScript("OnLeave", function(self)
                        EllesmereUI.HideWidgetTooltip()
                    end)
                    r._lfgBtn = btn
                end
                r._lfgBtn:ClearAllPoints()
                local anchor = item and self.itemBtns[#self.itemBtns] or r.frame
                local anchorPt = item and "LEFT" or "RIGHT"
                local oX = item and -4 or -2
                r._lfgBtn:SetPoint("RIGHT", anchor, anchorPt, oX, 0)
                local capturedQID = qID
                r._lfgBtn:SetScript("OnClick", function()
                    if LFGListUtil_FindQuestGroup then
                        LFGListUtil_FindQuestGroup(capturedQID)
                    elseif C_LFGList and C_LFGList.Search then
                        -- Fallback: open group finder with quest name search
                        local title = C_QuestLog.GetTitleForQuestID(capturedQID)
                        if title then
                            C_LFGList.Search(1, title) -- 1 = Quests category
                            if PVEFrame_ToggleFrame then
                                PVEFrame_ToggleFrame("GroupFinderFrame", _G.LFGListPVEStub)
                            end
                        end
                    end
                end)
                r._lfgBtn:Show()
            elseif r._lfgBtn then
                r._lfgBtn:Hide()
            end
        elseif r._lfgBtn then
            r._lfgBtn:Hide()
        end

        if qID then
            r.frame._questID = qID; r.frame:EnableMouse(true)
            r.frame._isAutoComplete = isAutoComplete
            r.frame._isComplete = isComplete
            r.frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            r.frame:SetScript("OnClick", TitleRowOnClick)
        elseif recipeID then
            r.frame._recipeID = recipeID; r.frame:EnableMouse(true)
            r.frame._isRecraft = isRecraft or false
            r.frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            r.frame:SetScript("OnClick", TitleRowOnClick)
        end
        r._rowType = "title"
        yOff = yOff + rh + ROW_GAP
        self.rows[#self.rows + 1] = r
    end

    local function AddObjRow(text, cr, cg, cb, isFinished)
        local r = AcquireRow(content)
        local objFS = isFinished and (compFS or ofs) or ofs
        SetFontSafe(r.text, ofp, objFS, off)
        r.text:SetTextColor(cr, cg, cb)
        ApplyFontShadow(r.text)
        r.text:SetText(text)
        r.text:Show()
        r.text:ClearAllPoints()
        r.text:SetPoint("TOPLEFT",  r.frame, "TOPLEFT",  20, 0)
        r.text:SetPoint("TOPRIGHT", r.frame, "TOPRIGHT",  0, 0)
        r.frame:SetWidth(rowW)
        r.frame:SetPoint("TOPLEFT",  content, "TOPLEFT",  TXT_PAD, -yOff)
        r.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -yOff)
        -- Force text width so GetStringHeight respects word wrap on first layout
        r.text:SetWidth(rowW - 20)
        local th = r.text:GetStringHeight()
        if th < ofs then th = ofs end
        local rh = th + 4; r.frame:SetHeight(rh); r.text:SetHeight(rh)
        r._rowType = "obj"
        r.frame._questID = _curObjQuestID
        r._objIndex = _curObjIndex
        yOff = yOff + rh + ROW_GAP
        self.rows[#self.rows + 1] = r
    end

    local function RenderList(list, startIdx)
        for i, q in ipairs(list) do
            local tr, tg, tb
            local isFocused = superQID and q.questID == superQID
            if q.isFailed then tr, tg, tb = C.failed.r, C.failed.g, C.failed.b
            elseif q.isComplete then tr, tg, tb = cc.r, cc.g, cc.b
            elseif isFocused then tr, tg, tb = fc.r, fc.g, fc.b
            else tr, tg, tb = tc.r, tc.g, tc.b end
            -- Override font size for focused quest
            local prevTfs
            if isFocused and ffs then
                prevTfs = tfs
                tfs = ffs
            end
            AddTitleRow(((startIdx or 0)+i).."  "..q.title, tr, tg, tb, q.questID, q.isAutoComplete, q.isComplete)
            if prevTfs then tfs = prevTfs end

            -- Store objective count on the title row for change detection
            local titleRow = self.rows[#self.rows]
            if titleRow then titleRow._objCount = #q.objectives end

            -- Set current quest context for objective row tagging
            _curObjQuestID = q.questID
            _curObjIndex = 0

            -- Timer (for world/task quests)
            if q.isTask then
                AddTimerRow(q.questID)
            end

            -- Objectives
            for _, obj in ipairs(q.objectives) do
                _curObjIndex = _curObjIndex + 1
                if obj.objType == "progressbar" and obj.numRequired and obj.numRequired > 0 then
                    -- Show progress bar instead of text
                    AddProgressRow(obj.numFulfilled or 0, obj.numRequired)
                else
                    local cr = obj.finished and cc.r or oc.r
                    local cg = obj.finished and cc.g or oc.g
                    local cb = obj.finished and cc.b or oc.b
                    if obj.text and obj.text ~= "" then
                        AddObjRow(obj.text, cr, cg, cb, obj.finished)
                    end
                end
            end
            _curObjQuestID = nil
            yOff = yOff + 3
        end
    end

    local active, watched, zone, world, prey = GetQuestLists()
    local scenario = GetScenarioSection()
    local recipes = GetTrackedRecipes()

    -- Recipe Tracking section (top of tracker)
    if #recipes > 0 then
        local rc = db.recipesCollapsed or false
        AddCollapsibleSection("RECIPE TRACKING", rc, function()
            DB().recipesCollapsed = not DB().recipesCollapsed; EQT:Refresh()
        end)
        if not rc then
            for _, recipe in ipairs(recipes) do
                AddTitleRow(recipe.name, tc.r, tc.g, tc.b, nil, nil, nil, recipe.recipeID, recipe.isRecraft)
                for _, reagent in ipairs(recipe.reagents) do
                    local cr = reagent.finished and cc.r or oc.r
                    local cg = reagent.finished and cc.g or oc.g
                    local cb = reagent.finished and cc.b or oc.b
                    AddObjRow(reagent.owned.."/"..reagent.needed.." "..reagent.name, cr, cg, cb, reagent.finished)
                end
                yOff = yOff + 3
            end
        end
    end

    -- Scenario / Delve section
    local anyAboveScenario = #recipes > 0
    if scenario then
        if anyAboveScenario or #watched > 0 or #zone > 0 or #world > 0 then yOff = yOff + 4 end

        -- Collapsible "DELVES" section header (only for delves, plain for other scenarios)
        local dc = false
        if scenario.isDelve then
            dc = db.delveCollapsed or false
            AddCollapsibleSection("DELVES", dc, function()
                DB().delveCollapsed = not DB().delveCollapsed; EQT:Refresh()
            end)
        end

        if not dc then
        -- Delve banner: icon + title + tier badge
        if scenario.isDelve then
            local BANNER_H = 42
            local ICON_SIZE = 36
            local r = AcquireRow(content)
            r.frame:SetPoint("TOPLEFT",  content, "TOPLEFT",  TXT_PAD, -yOff)
            r.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -yOff)
            r.frame:SetHeight(BANNER_H)

            -- Dark background with subtle border
            if not r.bannerBg then
                r.bannerBg = r.frame:CreateTexture(nil, "BACKGROUND")
            end
            r.bannerBg:SetAllPoints()
            r.bannerBg:SetColorTexture(0.05, 0.04, 0.08, 0.8)
            r.bannerBg:Show()

            -- Accent border on left
            if not r.bannerAccent then
                r.bannerAccent = r.frame:CreateTexture(nil, "BORDER")
            end
            r.bannerAccent:SetWidth(2)
            r.bannerAccent:SetPoint("TOPRIGHT",    r.frame, "TOPRIGHT",  0, 0)
            r.bannerAccent:SetPoint("BOTTOMRIGHT", r.frame, "BOTTOMRIGHT", 0, 0)
            r.bannerAccent:SetColorTexture(C.accent.r, C.accent.g, C.accent.b, 0.9)
            r.bannerAccent:Show()

            -- Icon (large, right-aligned, slightly faded)
            if scenario.bannerIcon then
                if not r.bannerIcon then
                    r.bannerIcon = r.frame:CreateTexture(nil, "ARTWORK")
                    r.bannerIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                end
                r.bannerIcon:SetSize(ICON_SIZE, ICON_SIZE)
                r.bannerIcon:SetTexture(scenario.bannerIcon)
                r.bannerIcon:SetPoint("RIGHT", r.frame, "RIGHT", -6, 0)
                r.bannerIcon:SetAlpha(0.55)
                r.bannerIcon:Show()
            end

            -- Tier badge (top-right)
            local tierAnchor = r.frame
            local tierOffX = -13
            if scenario.bannerTier then
                if not r.tierFS then
                    r.tierFS = r.frame:CreateFontString(nil, "OVERLAY")
                    r.tierFS:SetJustifyH("CENTER")
                end
                SetFontSafe(r.tierFS, GlobalFont(), tfs + 4, OutlineFlag())
                r.tierFS:SetTextColor(C.accent.r, C.accent.g, C.accent.b)
                r.tierFS:SetText(scenario.bannerTier)
                r.tierFS:ClearAllPoints()
                r.tierFS:SetPoint("RIGHT", r.frame, "RIGHT", tierOffX, 0)
                r.tierFS:Show()
                tierAnchor = r.tierFS
            end

            -- Delve lives: heart icon + count to the left of tier
            if scenario.delveLives then
                if not r.livesFS then
                    r.livesFS = r.frame:CreateFontString(nil, "OVERLAY")
                    r.livesFS:SetJustifyH("RIGHT")
                end
                if not r.heartIcon then
                    r.heartIcon = r.frame:CreateTexture(nil, "OVERLAY")
                    r.heartIcon:SetAtlas("delves-scenario-heart-icon")
                end
                local livesText = scenario.delveLivesMax
                    and string.format("%d/%d", scenario.delveLives, scenario.delveLivesMax)
                    or tostring(scenario.delveLives)
                SetFontSafe(r.livesFS, GlobalFont(), tfs, OutlineFlag())
                r.livesFS:SetTextColor(0.9, 0.9, 0.9)
                r.livesFS:SetText(livesText)
                r.livesFS:ClearAllPoints()
                r.livesFS:SetPoint("RIGHT", tierAnchor, "LEFT", -16, 0)
                r.livesFS:Show()
                r.heartIcon:SetSize(14, 14)
                r.heartIcon:ClearAllPoints()
                r.heartIcon:SetPoint("RIGHT", r.livesFS, "LEFT", -3, 0)
                r.heartIcon:Show()
            elseif r.livesFS then
                r.livesFS:Hide()
                if r.heartIcon then r.heartIcon:Hide() end
            end

            -- Title text (vertically centered in banner)
            local bc = tc
            local leftPad = 10
            SetFontSafe(r.text, tfp, tfs + 2, tff)
            r.text:SetTextColor(bc.r, bc.g, bc.b)
            r.text:SetText(scenario.title)
            r.text:ClearAllPoints()
            r.text:SetPoint("LEFT",  r.frame, "LEFT",  leftPad, 0)
            r.text:SetPoint("RIGHT", r.frame, "RIGHT", -(ICON_SIZE + 10), 0)
            r.text:SetJustifyV("MIDDLE")
            r.text:SetHeight(BANNER_H)
            r.text:Show()
            ApplyFontShadow(r.text)

            yOff = yOff + BANNER_H + 6  -- extra gap below banner
            self.rows[#self.rows + 1] = r
        else
            AddPlainSection(scenario.title)
        end

        -- Timer row (if scenario has a countdown)
        if scenario.timerDuration and scenario.timerStartTime then
            AddTimerRow(nil, false, scenario.timerDuration, scenario.timerStartTime)
        end

        -- Objectives
        for _, obj in ipairs(scenario.objectives) do
            local cr = obj.finished and cc.r or oc.r
            local cg = obj.finished and cc.g or oc.g
            local cb = obj.finished and cc.b or oc.b
            if obj.objType == "progressbar" and obj.numRequired and obj.numRequired > 0 then
                if obj.text and obj.text ~= "" then
                    AddObjRow(obj.text, cr, cg, cb)
                end
                AddProgressRow(obj.numFulfilled or 0, obj.numRequired)
            else
                if obj.text and obj.text ~= "" then
                    AddObjRow(obj.text, cr, cg, cb)
                end
            end
        end
        end -- if not dc
        yOff = yOff + 10
    end

    -- Order: Recipes (top), Delves, Active WQ, Prey, Zone, World, Quests (bottom)
    local anyAbove = #recipes > 0 or scenario ~= nil

    if #active > 0 then
        if anyAbove then yOff = yOff + 4 end; anyAbove = true
        AddCollapsibleSection("ACTIVE WORLD QUEST", false)
        RenderList(active, 0)
    end

    if db.showPreyQuests and #prey > 0 then
        if anyAbove then yOff = yOff + 4 end; anyAbove = true
        local pc = db.preyCollapsed or false
        AddCollapsibleSection("PREYS", pc, function()
            DB().preyCollapsed = not DB().preyCollapsed; EQT:Refresh()
        end)
        if not pc then RenderList(prey, 0) end
    end
    if db.showZoneQuests and #zone > 0 then
        if anyAbove then yOff = yOff + 4 end; anyAbove = true
        local zc = db.zoneCollapsed or false
        AddCollapsibleSection("ZONE QUESTS", zc, function()
            DB().zoneCollapsed = not DB().zoneCollapsed; EQT:Refresh()
        end)
        if not zc then RenderList(zone, 0) end
    end
    if db.showWorldQuests and #world > 0 then
        if anyAbove then yOff = yOff + 4 end; anyAbove = true
        local wc = db.worldCollapsed or false
        AddCollapsibleSection("WORLD QUESTS", wc, function()
            DB().worldCollapsed = not DB().worldCollapsed; EQT:Refresh()
        end)
        if not wc then RenderList(world, 0) end
    end
    if #watched > 0 then
        if anyAbove then yOff = yOff + 4 end
        local qc = db.questsCollapsed or false
        AddCollapsibleSection("QUESTS", qc, function()
            DB().questsCollapsed = not DB().questsCollapsed; EQT:Refresh()
        end)
        if not qc then RenderList(watched, 0) end
    end
    local hasContent = scenario or #active > 0 or #watched > 0 or #zone > 0 or #world > 0 or #prey > 0 or #recipes > 0
    if not hasContent then
        if f.inner then f.inner:Hide() end
        if f.bg then f.bg:Hide() end
        if f.topLine then f.topLine:Hide() end
        return
    end
    if f.inner then f.inner:Show() end
    if f.bg then f.bg:Show() end
    if f.topLine and (db.showTopLine ~= false) then f.topLine:Show() end

    content:SetHeight(math.max(yOff, 1))
    local totalH = PAD_V + 2 + yOff + PAD_V + 5
    local maxH = db.height or 500
    -- Outer frame stays at max height (consistent with unlock mode)
    f:SetHeight(maxH)
    -- Inner frame auto-collapses to content
    if f.inner then
        f.inner:SetHeight(math.min(totalH, maxH))
        UpdateInnerAlignment(f)
    end
    -- Clamp scroll position to valid range (don't reset to 0)
    if f.sf then
        local maxScroll = EllesmereUI.SafeScrollRange(f.sf)
        local cur = f.sf:GetVerticalScroll()
        if cur > maxScroll then
            f.sf:SetVerticalScroll(maxScroll)
        end
        if f._updateScrollThumb then f._updateScrollThumb() end
    end

    -- Restore visibility after rebuild is complete (prevents teardown flicker)
    if f.inner and not skipAlphaFlash then f.inner:SetAlpha(1) end

    -- Show/hide timer update frame
    if _timerUpdateFrame then
        if #self.timerRows > 0 then _timerUpdateFrame:Show()
        else _timerUpdateFrame:Hide() end
    end
end

-------------------------------------------------------------------------------
-- RefreshProgress: lightweight in-place update for non-structural changes
-- Re-queries objective data and updates existing row text/colors without
-- tearing down and rebuilding the entire UI.
-------------------------------------------------------------------------------
function EQT:RefreshProgress()
    local f = self.frame
    if not f then return end
    if #self.rows == 0 then self:Refresh(); return end

    InvalidateQuestLogCache()

    local db      = DB()
    local tc      = db.titleColor  or C.header
    local oc      = db.objColor    or { r=0.9, g=0.9, b=0.9 }
    local cc      = db.completedColor or C.complete
    local fc      = db.focusedColor or { r=0.871, g=0.251, b=1.0 }
    local ffs     = db.focusedFontSize
    local fbgA    = (db.focusBgOpacity or 0) / 100
    local compFS  = db.completedFontSize
    local superQID = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()

    -- Build a map of qID -> fresh objectives
    local freshObjs = {}
    local freshComplete = {}
    local freshFailed = {}
    local objCountChanged = false
    if C_QuestLog and C_QuestLog.GetQuestObjectives then
        for _, r in ipairs(self.rows) do
            local qID = r.frame._questID
            if qID and not freshObjs[qID] then
                local ot = C_QuestLog.GetQuestObjectives(qID)
                freshObjs[qID] = ot or {}
                freshComplete[qID] = C_QuestLog.IsComplete and C_QuestLog.IsComplete(qID) or false
                -- Get isFailed from quest log info
                local idx = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(qID)
                if idx and idx > 0 then
                    local info = C_QuestLog.GetInfo(idx)
                    freshFailed[qID] = info and info.isFailed or false
                end
                -- Check if objective count changed (structural change via progress event)
                local oldCount = r._objCount
                if oldCount and ot and #ot ~= oldCount then
                    objCountChanged = true
                end
            end
        end
    end

    -- If objective count changed, fall through to full rebuild
    if objCountChanged then
        _structuralDirty = true
        self:Refresh()
        return
    end

    -- Update rows in-place
    local tfp, tfs, tff = TitleFont()
    local ofp, ofs, off = ObjFont()

    for _, r in ipairs(self.rows) do
        local qID = r.frame._questID
        if qID and r._rowType == "title" then
            local isFocused = superQID and qID == superQID
            local isComp = freshComplete[qID]
            local isFail = freshFailed[qID]
            local tr, tg, tb
            if isFail then tr, tg, tb = C.failed.r, C.failed.g, C.failed.b
            elseif isComp then tr, tg, tb = cc.r, cc.g, cc.b
            elseif isFocused then tr, tg, tb = fc.r, fc.g, fc.b
            else tr, tg, tb = tc.r, tc.g, tc.b end
            r.text:SetTextColor(tr, tg, tb)
            r._baseR, r._baseG, r._baseB = tr, tg, tb
            if isFocused and ffs then
                SetFontSafe(r.text, tfp, ffs, tff)
            else
                SetFontSafe(r.text, tfp, tfs, tff)
            end
            if isFocused and fbgA > 0 then
                if not r.focusBg then
                    r.focusBg = r.frame:CreateTexture(nil, "BACKGROUND")
                    r.focusBg:SetAllPoints(r.frame)
                end
                r.focusBg:SetColorTexture(fc.r, fc.g, fc.b, fbgA)
                r.focusBg:Show()
            elseif r.focusBg then
                r.focusBg:Hide()
            end
        elseif qID and r._rowType == "obj" then
            local objs = freshObjs[qID]
            local objIdx = r._objIndex
            if objs and objIdx and objs[objIdx] then
                local o = objs[objIdx]
                local finished = o.finished
                local cr = finished and cc.r or oc.r
                local cg = finished and cc.g or oc.g
                local cb = finished and cc.b or oc.b
                r.text:SetTextColor(cr, cg, cb)
                if o.text and o.text ~= "" then
                    r.text:SetText(o.text)
                end
                local objFS = finished and (compFS or ofs) or ofs
                SetFontSafe(r.text, ofp, objFS, off)
            end
        elseif qID and r._rowType == "progress" then
            local objs = freshObjs[qID]
            local objIdx = r._objIndex
            if objs and objIdx and objs[objIdx] then
                local o = objs[objIdx]
                local nf = o.numFulfilled or 0
                local nr = o.numRequired or 1
                if o.type == "progressbar" or o.objType == "progressbar" then
                    local pct = GetQuestProgressBarPercent(qID)
                    if pct then nf = pct; nr = 100 end
                end
                local pct = math.max(0, math.min(1, nf / nr))
                if r.barFill and r.barBg then
                    local barW = r.barBg:GetWidth()
                    if barW and barW > 0 then
                        r.barFill:SetWidth(math.max(1, barW * pct))
                    end
                end
                if r.pctFS then
                    r.pctFS:SetText(math.floor(pct * 100 + 0.5).."%")
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Frame
-------------------------------------------------------------------------------
UpdateInnerAlignment = function(f)
    local inner = f.inner
    if not inner then return end
    inner:ClearAllPoints()
    local align = DB().alignment or "top"
    if align == "bottom" then
        inner:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  0, 0)
        inner:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    elseif align == "center" then
        inner:SetPoint("LEFT",  f, "LEFT",  0, 0)
        inner:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    else -- top (default)
        inner:SetPoint("TOPLEFT",  f, "TOPLEFT",  0, 0)
        inner:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    end
end
EQT.UpdateInnerAlignment = UpdateInnerAlignment
EQT.PAD_V = PAD_V

local function BuildFrame()
    local f = CreateFrame("Frame", "EUI_QuestTrackerFrame", UIParent)
    f:SetFrameStrata("MEDIUM"); f:SetClampedToScreen(false)

    -- Inner frame holds all visual content; aligns within f based on setting
    local inner = CreateFrame("Frame", nil, f)
    inner:EnableMouse(false)
    f.inner = inner

    local bg = inner:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(); bg:SetColorTexture(Cfg("bgR") or 0, Cfg("bgG") or 0, Cfg("bgB") or 0, Cfg("bgAlpha") or 0.35); f.bg = bg

    local topLine = inner:CreateTexture(nil, "ARTWORK")
    topLine:SetHeight(1)
    topLine:SetPoint("TOPLEFT",  inner, "TOPLEFT",  0, 0)
    topLine:SetPoint("TOPRIGHT", inner, "TOPRIGHT", 0, 0)
    local sc = Cfg("secColor") or C.section
    topLine:SetColorTexture(sc.r, sc.g, sc.b, 0.7)
    if not Cfg("showTopLine") then topLine:Hide() end
    f.topLine = topLine

    local sf = CreateFrame("ScrollFrame", "EUI_QuestTrackerScroll", inner)
    sf:SetPoint("TOPLEFT",     inner, "TOPLEFT",     PAD_H, -(PAD_V + 2))
    sf:SetPoint("BOTTOMRIGHT", inner, "BOTTOMRIGHT", -(PAD_H + 10), PAD_V + 5)
    sf:EnableMouseWheel(true)
    sf:EnableMouse(false)
    sf:SetClipsChildren(true)
    f.sf = sf

    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(math.max(10, (Cfg("width") or 325) - PAD_H*2 - 10))
    content:SetHeight(1)
    sf:SetScrollChild(content); f.content = content

    -- Thin scrollbar (parented to inner so it isn't clipped by ScrollFrame)
    local scrollTrack = CreateFrame("Frame", nil, inner)
    scrollTrack:SetWidth(4)
    scrollTrack:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -4, -(PAD_V + 2 + 4))
    scrollTrack:SetPoint("BOTTOMRIGHT", inner, "BOTTOMRIGHT", -4, PAD_V + 5 + 4)
    scrollTrack:SetFrameLevel(sf:GetFrameLevel() + 3)

    local trackBg = scrollTrack:CreateTexture(nil, "BACKGROUND")
    trackBg:SetAllPoints()
    trackBg:SetColorTexture(1, 1, 1, 0.02)

    local scrollThumb = CreateFrame("Button", nil, scrollTrack)
    scrollThumb:SetWidth(4)
    scrollThumb:SetHeight(60)
    scrollThumb:SetPoint("TOP", scrollTrack, "TOP", 0, 0)
    scrollThumb:SetFrameLevel(scrollTrack:GetFrameLevel() + 1)
    scrollThumb:EnableMouse(true)
    scrollThumb:RegisterForDrag("LeftButton")
    scrollThumb:SetScript("OnDragStart", function() end)
    scrollThumb:SetScript("OnDragStop", function() end)

    local scrollHitArea = CreateFrame("Button", nil, inner)
    scrollHitArea:SetWidth(16)
    scrollHitArea:SetPoint("TOPRIGHT", inner, "TOPRIGHT", 0, -(PAD_V + 2 + 4))
    scrollHitArea:SetPoint("BOTTOMRIGHT", inner, "BOTTOMRIGHT", 0, PAD_V + 5 + 4)
    scrollHitArea:SetFrameLevel(scrollTrack:GetFrameLevel() + 2)
    scrollHitArea:EnableMouse(true)
    scrollHitArea:RegisterForDrag("LeftButton")
    scrollHitArea:SetScript("OnDragStart", function() end)
    scrollHitArea:SetScript("OnDragStop", function() end)
    scrollHitArea:SetScript("OnEnter", function()
        if EQT._qtMouseoverIn then EQT._qtMouseoverIn() end
    end)
    scrollHitArea:SetScript("OnLeave", function()
        if EQT._qtMouseoverOut then EQT._qtMouseoverOut() end
    end)

    local thumbTex = scrollThumb:CreateTexture(nil, "ARTWORK")
    thumbTex:SetAllPoints()
    thumbTex:SetColorTexture(1, 1, 1, 0.27)

    local SCROLL_STEP = 60
    local SMOOTH_SPEED = 12
    local isDragging = false
    local dragStartY, dragStartScroll
    local scrollTarget = 0
    local isSmoothing = false

    local function StopScrollDrag()
        if not isDragging then return end
        isDragging = false
        scrollThumb:SetScript("OnUpdate", nil)
    end

    local SCROLLBAR_ALPHA = 0.35

    local function UpdateScrollThumb()
        local maxScroll = EllesmereUI.SafeScrollRange(sf)
        if maxScroll <= 0 then scrollTrack:SetAlpha(0); return end
        scrollTrack:SetAlpha(SCROLLBAR_ALPHA)
        local trackH = scrollTrack:GetHeight()
        local visH   = sf:GetHeight()
        local visibleRatio = visH / (visH + maxScroll)
        local thumbH = math.max(30, trackH * visibleRatio)
        scrollThumb:SetHeight(thumbH)
        local scrollRatio = (tonumber(sf:GetVerticalScroll()) or 0) / maxScroll
        local maxThumbTravel = trackH - thumbH
        scrollThumb:ClearAllPoints()
        scrollThumb:SetPoint("TOP", scrollTrack, "TOP", 0, -(scrollRatio * maxThumbTravel))
    end
    f._updateScrollThumb = UpdateScrollThumb

    -- Smooth scroll OnUpdate
    local smoothFrame = CreateFrame("Frame")
    smoothFrame:Hide()
    smoothFrame:SetScript("OnUpdate", function(_, elapsed)
        local cur = sf:GetVerticalScroll()
        local maxScroll = EllesmereUI.SafeScrollRange(sf)
        local scale = sf:GetEffectiveScale()
        maxScroll = math.floor(maxScroll * scale) / scale
        scrollTarget = math.max(0, math.min(maxScroll, scrollTarget))
        local diff = scrollTarget - cur
        if math.abs(diff) < 0.3 then
            sf:SetVerticalScroll(scrollTarget)
            UpdateScrollThumb()
            isSmoothing = false
            smoothFrame:Hide()
            return
        end
        local newScroll = cur + diff * math.min(1, SMOOTH_SPEED * elapsed)
        newScroll = math.max(0, math.min(maxScroll, newScroll))
        if diff > 0 then
            newScroll = math.ceil(newScroll * scale) / scale
        else
            newScroll = math.floor(newScroll * scale) / scale
        end
        newScroll = math.max(0, math.min(maxScroll, newScroll))
        sf:SetVerticalScroll(newScroll)
        UpdateScrollThumb()
    end)

    local function SmoothScrollTo(target)
        local maxScroll = EllesmereUI.SafeScrollRange(sf)
        local scale = sf:GetEffectiveScale()
        maxScroll = math.floor(maxScroll * scale) / scale
        scrollTarget = math.max(0, math.min(maxScroll, target))
        scrollTarget = math.floor(scrollTarget * scale + 0.5) / scale
        scrollTarget = math.min(scrollTarget, maxScroll)
        if not isSmoothing then
            isSmoothing = true
            smoothFrame:Show()
        end
    end

    sf:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = EllesmereUI.SafeScrollRange(self)
        if maxScroll <= 0 then return end
        local base = isSmoothing and scrollTarget or self:GetVerticalScroll()
        SmoothScrollTo(base - delta * SCROLL_STEP)
    end)
    sf:SetScript("OnScrollRangeChanged", function() UpdateScrollThumb() end)

    local function ScrollThumbOnUpdate(self)
        if not IsMouseButtonDown("LeftButton") then StopScrollDrag(); return end
        isSmoothing = false; smoothFrame:Hide()
        local _, cursorY = GetCursorPosition()
        cursorY = cursorY / self:GetEffectiveScale()
        local deltaY = dragStartY - cursorY
        local trackH = scrollTrack:GetHeight()
        local maxThumbTravel = trackH - self:GetHeight()
        if maxThumbTravel <= 0 then return end
        local maxScroll = EllesmereUI.SafeScrollRange(sf)
        local newScroll = math.max(0, math.min(maxScroll, dragStartScroll + (deltaY / maxThumbTravel) * maxScroll))
        local scale = sf:GetEffectiveScale()
        newScroll = math.floor(newScroll * scale + 0.5) / scale
        scrollTarget = newScroll
        sf:SetVerticalScroll(newScroll)
        UpdateScrollThumb()
    end

    scrollThumb:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        isSmoothing = false; smoothFrame:Hide()
        isDragging = true
        local _, cursorY = GetCursorPosition()
        dragStartY = cursorY / self:GetEffectiveScale()
        dragStartScroll = sf:GetVerticalScroll()
        self:SetScript("OnUpdate", ScrollThumbOnUpdate)
    end)
    scrollThumb:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        StopScrollDrag()
    end)

    scrollHitArea:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        isSmoothing = false; smoothFrame:Hide()
        local maxScroll = EllesmereUI.SafeScrollRange(sf)
        if maxScroll <= 0 then return end
        local _, cy = GetCursorPosition()
        cy = cy / scrollTrack:GetEffectiveScale()
        local top = scrollTrack:GetTop() or 0
        local trackH = scrollTrack:GetHeight()
        local thumbH = scrollThumb:GetHeight()
        if trackH <= thumbH then return end
        local frac = (top - cy - thumbH / 2) / (trackH - thumbH)
        frac = math.max(0, math.min(1, frac))
        local newScroll = frac * maxScroll
        local scale = sf:GetEffectiveScale()
        newScroll = math.floor(newScroll * scale + 0.5) / scale
        scrollTarget = newScroll
        sf:SetVerticalScroll(newScroll)
        UpdateScrollThumb()
        isDragging = true
        dragStartY = cy
        dragStartScroll = newScroll
        scrollThumb:SetScript("OnUpdate", ScrollThumbOnUpdate)
    end)
    scrollHitArea:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        StopScrollDrag()
    end)

    f:HookScript("OnSizeChanged", function(self, w)
        if EQT._widthDragging then return end
        local cw = math.max(10, w - PAD_H*2 - 10)
        content:SetWidth(cw); sf:SetWidth(cw)
        UpdateScrollThumb()
    end)

    -- f is the full-height wrapper used by unlock mode and must NOT
    -- intercept mouse events in the empty space below content.
    f:EnableMouse(false)

    -- Stop all standalone frames when hidden (M+, raids, disabled, etc.)
    f:HookScript("OnHide", function()
        smoothFrame:Hide()
        isSmoothing = false
    end)

    UpdateInnerAlignment(f)

    return f
end

-------------------------------------------------------------------------------
-- Position / Slash / Init / Load
-------------------------------------------------------------------------------
function EQT:ApplyPosition()
    local f = self.frame; if not f then return end
    -- Skip if unlock mode owns the position
    if EllesmereUI and EllesmereUI.IsUnlockAnchored
        and EllesmereUI.IsUnlockAnchored("EQT_Tracker") and f:GetLeft() then
        return
    end
    f:ClearAllPoints()
    -- Migrate legacy xPos/yPos to new pos format
    local db = DB()
    if db.xPos and db.yPos and not db.pos then
        local uiW, uiH = UIParent:GetSize()
        local fW, fH = f:GetSize()
        local cx = db.xPos + fW / 2
        local cy = (db.yPos + uiH) - fH / 2
        db.pos = {
            point = "CENTER", relPoint = "CENTER",
            x = cx - uiW / 2, y = cy - uiH / 2,
        }
        db.xPos = nil; db.yPos = nil
    end
    local pos = db.pos
    if pos and pos.point then
        f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -30, -200)
    end
end

local function RegisterSlash()
    SLASH_EUIQUEST1 = "/euiqt"
    SlashCmdList["EUIQUEST"] = function(msg)
        msg = strtrim(msg or ""):lower()
        if msg == "" or msg == "toggle" then
            local f = EQT.frame
            if f and not InCombatLockdown() then if f:IsShown() then f:Hide() else f:Show(); EQT:Refresh() end end
        elseif msg == "reset" then
            DB().pos = nil; EQT:ApplyPosition()
        end
    end
end

-------------------------------------------------------------------------------
-- Snapshot Blizzard ObjectiveTrackerFrame position on first install
-- Captures position, width, and font size so our tracker starts where the
-- user had Blizzard's tracker in Edit Mode. Only runs once per install.
-------------------------------------------------------------------------------
local function CaptureBlizzardTracker()
    local ot = _G.ObjectiveTrackerFrame
    if not ot then return end
    local db = DB()
    local uiW, uiH = UIParent:GetSize()
    local uiScale = UIParent:GetEffectiveScale()
    -- Get center position, scale-adjusted to UIParent coords
    local cx, cy = ot:GetCenter()
    if not cx or not cy then return end
    local bScale = ot:GetEffectiveScale()
    cx = cx * bScale / uiScale
    cy = cy * bScale / uiScale
    -- Store as CENTER/CENTER offset
    db.pos = {
        point = "CENTER", relPoint = "CENTER",
        x = cx - (uiW / 2), y = cy - (uiH / 2),
    }
    -- Width and height not captured -- Blizzard's tracker is anchored on both
    -- axes so GetWidth()/GetHeight() return the full stretch, not content size.
    -- Defaults of 325 width and 500 height are used instead.
    -- Capture text size from Blizzard's edit mode setting (index 2)
    if ot.GetSettingValue then
        local ok, val = pcall(ot.GetSettingValue, ot, 2)
        if ok and val and val > 0 then
            local s = math.floor(val + 0.5)
            db.titleFontSize = s
            db.objFontSize   = math.max(s - 1, 6)
            db.secFontSize   = s + 1
        end
    end
    db._capturedOnce = true
end

-- Returns true if the player is in a Normal+ raid or M+ dungeon
local function IsInHiddenInstance()
    local _, iType, diffID = GetInstanceInfo()
    diffID = tonumber(diffID) or 0
    -- Raid difficulties: Normal(14), Heroic(15), Mythic(16), LFR(17)
    if iType == "raid" and diffID >= 14 then return true end
    -- Mythic+ dungeon: difficultyID 8 (Mythic Keystone)
    if iType == "party" and diffID == 8 then return true end
    return false
end

function EQT:Init()
    if _G._EBS_TEMP_DISABLED and _G._EBS_TEMP_DISABLED.questTracker then return end
    DB()
    EQT.sections  = EQT.sections  or {}
    EQT.itemBtns  = EQT.itemBtns  or {}
    EQT.timerRows = EQT.timerRows or {}
    if not Cfg("enabled") then return end
    self._needsCapture = not DB()._capturedOnce
    self.frame = BuildFrame()
    self.frame:SetWidth(Cfg("width") or 325)
    self.frame:SetHeight(Cfg("height") or 500)
    self:ApplyPosition()

    -- Hide/show Blizzard ObjectiveTrackerFrame based on setting
    -- We move it far off-screen so its children can't intercept clicks.
    if not EQT._hiddenFrame then
        EQT._hiddenFrame = CreateFrame("Frame")
        EQT._hiddenFrame:Hide()
    end
    local function ApplyBlizzardTrackerVisibility()
        local ot = _G.ObjectiveTrackerFrame
        if not ot then return end
        -- Never hide Blizzard's tracker during M+ keystones -- the
        -- scenario timer (M+ timer, death count, affixes) lives inside
        -- ObjectiveTrackerFrame and must remain visible.
        local inMPlus = C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
            and C_ChallengeMode.IsChallengeModeActive()
        -- Use alpha + mouse disable instead of SetParent to avoid tainting
        -- the ObjectiveTracker frame hierarchy. SetParent on a Blizzard frame
        -- taints its ancestry and causes LayoutFrame/MoneyFrame taint errors.
        if Cfg("hideBlizzardTracker") and Cfg("enabled") ~= false and not inMPlus then
            ot:SetAlpha(0)
            ot:EnableMouse(false)
            if ot.EnableMouseMotion then ot:EnableMouseMotion(false) end
            ot._eqtHidden = true
            -- Persistent enforcer: Blizzard restores alpha on various updates.
            -- Poll at low frequency to re-suppress.
            if not ot._eqtEnforcer then
                ot._eqtEnforcer = CreateFrame("Frame")
            end
            ot._eqtEnforcer:SetScript("OnUpdate", function()
                if ot:GetAlpha() > 0 then
                    ot:SetAlpha(0)
                    ot:EnableMouse(false)
                    if ot.EnableMouseMotion then ot:EnableMouseMotion(false) end
                end
            end)
            ot._eqtEnforcer:Show()
        else
            if ot._eqtHidden then
                ot:SetAlpha(1)
                ot:EnableMouse(true)
                if ot.EnableMouseMotion then ot:EnableMouseMotion(true) end
                ot._eqtHidden = false
                if ot._eqtEnforcer then
                    ot._eqtEnforcer:SetScript("OnUpdate", nil)
                    ot._eqtEnforcer:Hide()
                end
            end
        end
    end
    EQT.ApplyBlizzardTrackerVisibility = ApplyBlizzardTrackerVisibility
    -- Re-suppress when Blizzard restores alpha (e.g. Edit Mode, cinematic end).
    -- Use a lightweight alpha watch instead of hooking Show (which taints the
    -- secure frame's execution context).
    local ot = _G.ObjectiveTrackerFrame
    if ot then
        local suppressFrame = CreateFrame("Frame")
        suppressFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
        suppressFrame:RegisterEvent("CINEMATIC_STOP")
        suppressFrame:RegisterEvent("STOP_MOVIE")
        suppressFrame:SetScript("OnEvent", function()
            C_Timer.After(0, ApplyBlizzardTrackerVisibility)
        end)
    end
    C_Timer.After(1, ApplyBlizzardTrackerVisibility)

    -- SplashFrame taint fix: Blizzard's SplashFrame:OnHide calls
    -- ObjectiveTrackerFrame:Update() which taints the Quest Button and
    -- downstream layout/money frames. Replace OnHide with a clone that
    -- omits the ObjectiveTrackerFrame:Update() call.
    do
        local sf = _G.SplashFrame
        if sf then
            sf:SetScript("OnHide", function(frame)
                local fromGameMenu = frame.screenInfo and frame.screenInfo.gameMenuRequest
                frame.screenInfo = nil
                if C_TalkingHead_SetConversationsDeferred then C_TalkingHead_SetConversationsDeferred(false) end
                if _G.AlertFrame and _G.AlertFrame.SetAlertsEnabled then
                    _G.AlertFrame:SetAlertsEnabled(true, "splashFrame")
                end
                -- ObjectiveTrackerFrame:Update() intentionally omitted (causes taint)
                if fromGameMenu and not frame.showingQuestDialog and not InCombatLockdown() then
                    if _G.GameMenuFrame then
                        ShowUIPanel(_G.GameMenuFrame)
                    end
                end
                frame.showingQuestDialog = nil
            end)
        end
    end

    -- Visibility system: check mode + options + instance hiding
    local qtMouseoverActive = false
    local qtMouseoverShown = false
    local qtMouseoverPoller = CreateFrame("Frame")
    qtMouseoverPoller:Hide()
    qtMouseoverPoller:SetScript("OnUpdate", function(_, dt)
        if not qtMouseoverActive then
            qtMouseoverPoller:Hide()
            return
        end
        if EQT.frame:IsMouseOver() then
            if not qtMouseoverShown then
                qtMouseoverShown = true
                EQT.frame:SetAlpha(1)
            end
        else
            if qtMouseoverShown then
                qtMouseoverShown = false
                EQT.frame:SetAlpha(0)
            end
        end
    end)
    -- Child OnEnter/OnLeave still call these to immediately show on
    -- hover of interactive elements (buttons, scroll area). The poller
    -- handles the fade-out so it doesn't get stuck.
    local function QTMouseoverIn()
        if not qtMouseoverActive then return end
        qtMouseoverShown = true
        EQT.frame:SetAlpha(1)
        qtMouseoverPoller:Show()
    end
    local function QTMouseoverOut()
        -- Poller will handle fade-out via IsMouseOver check
    end
    EQT._qtMouseoverIn = QTMouseoverIn
    EQT._qtMouseoverOut = QTMouseoverOut

    local function UpdateQTVisibility()
        if not EQT.frame then return end
        if Cfg("enabled") == false then EQT.frame:Hide(); qtMouseoverActive = false; return end
        -- Instance hiding (raids, M+) works even in combat -- EQT.frame is
        -- our own unprotected frame, so Hide() is always safe.
        if IsInHiddenInstance() then EQT.frame:Hide(); qtMouseoverActive = false; return end
        if InCombatLockdown() then return end
        local qt = DB()
        if EllesmereUI.CheckVisibilityOptions and EllesmereUI.CheckVisibilityOptions(qt) then
            EQT.frame:Hide(); qtMouseoverActive = false; return
        end
        local mode = qt.visibility or "always"
        if mode == "mouseover" then
            qtMouseoverActive = true
            EQT.frame:Show()
            EQT.frame:SetAlpha(0)
            qtMouseoverPoller:Show()
            return
        end
        qtMouseoverActive = false
        qtMouseoverPoller:Hide()
        EQT.frame:SetAlpha(1)
        local show = true
        if mode == "never" then
            show = false
        elseif mode == "in_combat" then
            show = _G._EBS_InCombat and _G._EBS_InCombat() or false
        elseif mode == "out_of_combat" then
            show = not (_G._EBS_InCombat and _G._EBS_InCombat())
        elseif mode == "in_raid" then
            show = IsInRaid()
        elseif mode == "in_party" then
            show = IsInGroup() and not IsInRaid()
        elseif mode == "solo" then
            show = not IsInGroup()
        end
        if show then EQT.frame:Show() else EQT.frame:Hide() end
    end
    _G._EBS_UpdateQTVisibility = UpdateQTVisibility

    local QUEST_EVENTS = {
        "QUEST_LOG_UPDATE","QUEST_ACCEPTED","QUEST_REMOVED","QUEST_TURNED_IN",
        "UNIT_QUEST_LOG_CHANGED",
    }
    local QUEST_EVENTS_SAFE = {
        "QUEST_WATCH_LIST_CHANGED","QUEST_WATCH_UPDATE","QUEST_TASK_PROGRESS_UPDATE",
        "TASK_PROGRESS_UPDATE","WORLD_QUEST_UPDATE",
        "TASK_IS_TOO_DIFFERENT","SCENARIO_CRITERIA_UPDATE","SCENARIO_UPDATE",
        "SCENARIO_COMPLETED","CRITERIA_COMPLETE","CHALLENGE_MODE_START","CHALLENGE_MODE_COMPLETED",
        "UI_WIDGET_UNIT_CHANGED","UPDATE_UI_WIDGET",
        "QUEST_DATA_LOAD_RESULT","QUEST_POI_UPDATE","AREA_POIS_UPDATED",
        "SUPER_TRACKING_CHANGED",
        "TRACKED_RECIPE_UPDATE",
        "TRADE_SKILL_LIST_UPDATE",
    }
    local ZONE_EVENTS = {"ZONE_CHANGED_NEW_AREA","ZONE_CHANGED"}

    local w = CreateFrame("Frame")
    local zoneFrame = CreateFrame("Frame")

    local function RegisterQTEvents()
        w:RegisterEvent("PLAYER_ENTERING_WORLD")
        for _, ev in ipairs(QUEST_EVENTS) do w:RegisterEvent(ev) end
        for _, ev in ipairs(QUEST_EVENTS_SAFE) do pcall(w.RegisterEvent, w, ev) end
        for _, ev in ipairs(ZONE_EVENTS) do zoneFrame:RegisterEvent(ev) end
    end
    local function UnregisterQTEvents()
        for _, ev in ipairs(QUEST_EVENTS) do w:UnregisterEvent(ev) end
        for _, ev in ipairs(QUEST_EVENTS_SAFE) do pcall(w.UnregisterEvent, w, ev) end
        for _, ev in ipairs(ZONE_EVENTS) do zoneFrame:UnregisterEvent(ev) end
        -- Keep PLAYER_ENTERING_WORLD so visibility is re-evaluated on zone transitions
    end

    RegisterQTEvents()

    zoneFrame:SetScript("OnEvent", function()
        -- Zone changed: clear section cache so quests re-categorize
        EQT:ClearSectionCache()
        EQT:SetDirty(true)
        C_Timer.After(0.5,  function() InvalidateQuestLogCache(); RebuildZoneSnapshot(); EQT:SetDirty(true) end)
        C_Timer.After(2.0,  function() InvalidateQuestLogCache(); RebuildZoneSnapshot(); EQT:SetDirty(true) end)
    end)

    -- Structural events always trigger a rebuild (quest actually added/removed)
    local STRUCTURAL_EVENTS = {
        PLAYER_ENTERING_WORLD = true,
        QUEST_ACCEPTED = true,
        QUEST_REMOVED = true,
        QUEST_TURNED_IN = true,
        QUEST_WATCH_LIST_CHANGED = true,
        SCENARIO_COMPLETED = true,
        SCENARIO_UPDATE = true,
        SCENARIO_CRITERIA_UPDATE = true,
        TRACKED_RECIPE_UPDATE = true,
    }
    local SCENARIO_EVENTS = {
        SCENARIO_CRITERIA_UPDATE = true,
        SCENARIO_UPDATE = true,
        SCENARIO_COMPLETED = true,
        PLAYER_ENTERING_WORLD = true,
        ZONE_CHANGED = true,
        ZONE_CHANGED_NEW_AREA = true,
        UPDATE_UI_WIDGET = true,
    }
    w:SetScript("OnEvent", function(_, event)
        -- M+ start/end: re-evaluate both Blizzard tracker visibility (so
        -- the M+ timer shows) and EQT visibility (so our tracker hides).
        -- Delayed re-check because GetInstanceInfo may not return diffID 8
        -- until a tick after CHALLENGE_MODE_START fires.
        if event == "CHALLENGE_MODE_START" or event == "CHALLENGE_MODE_COMPLETED" then
            if ApplyBlizzardTrackerVisibility then ApplyBlizzardTrackerVisibility() end
            UpdateQTVisibility()
            C_Timer.After(0.5, function()
                if ApplyBlizzardTrackerVisibility then ApplyBlizzardTrackerVisibility() end
                UpdateQTVisibility()
            end)
        end
        -- Super-tracking changes only need a visual refresh (focused highlight),
        -- NOT a full quest re-sort, because isOnMap flags shift with focus and
        -- would cause quests to jump between sections.
        if event == "SUPER_TRACKING_CHANGED" then
            EQT:RefreshProgress()
            return
        end
        -- World quest / task progress events: invalidate caches and refresh
        -- so %-based world quests update their progress bars correctly.
        if event == "TASK_PROGRESS_UPDATE" or event == "WORLD_QUEST_UPDATE" then
            InvalidateQuestLogCache()
            _questListsCached = false
            -- Structural dirty: active world quest section depends on
            -- C_TaskQuest.IsActive which changes with task progress.
            EQT:SetDirty(true)
            if EQT.UpdateQuestItemAttribute then EQT.UpdateQuestItemAttribute() end
            return
        end
        -- Non-structural events (progress, selection, POI) are suppressible
        if EQT._suppressDirty and not STRUCTURAL_EVENTS[event] then
            return
        end
        -- Structural events clear section cache so quests re-categorize
        local isStructural = STRUCTURAL_EVENTS[event]
        if isStructural then
            _questListsCached = false
            EQT:ClearSectionCache()
        end
        -- Invalidate scenario cache on scenario-related events.
        -- Force structural so the full Refresh() re-reads the scenario cache
        -- (RefreshProgress only handles quest objectives, not scenarios).
        if SCENARIO_EVENTS[event] then
            InvalidateScenarioCache()
            isStructural = true
        end
        -- Invalidate quest log cache so next scan re-reads
        InvalidateQuestLogCache()
        EQT:SetDirty(isStructural)
        if event == "PLAYER_ENTERING_WORLD" then
            -- First install: snapshot Blizzard tracker position before we hide it
            if EQT._needsCapture then
                EQT._needsCapture = false
                CaptureBlizzardTracker()
                if EQT.frame then
                    EQT.frame:SetWidth(Cfg("width") or 325)
                end
            end
            EQT:ApplyPosition()
            UpdateQTVisibility()
        end
        if EQT.UpdateQuestItemAttribute then EQT.UpdateQuestItemAttribute() end
    end)

    -- Fully suspend/resume quest tracking when hidden/shown
    self.frame:HookScript("OnHide", function()
        UnregisterQTEvents()
        if _dirtyTimer then _dirtyTimer:Cancel(); _dirtyTimer = nil end
        if _timerUpdateFrame then _timerUpdateFrame:Hide() end
    end)
    self.frame:HookScript("OnShow", function()
        RegisterQTEvents()
        EQT:SetDirty(true)
    end)

    -------------------------------------------------------------------------------
    -- Auto Accept / Auto Turn-in
    -------------------------------------------------------------------------------
    local autoFrame = CreateFrame("Frame")
    local autoPreventNPCGUID = nil  -- tracks NPC where prevent-multi was triggered
    -- QUEST_DETAIL: fires when a quest offer is shown to the player (NPC or item)
    -- QUEST_COMPLETE: fires when the turn-in dialog opens
    -- QUEST_AUTOCOMPLETE: fires when an auto-complete quest finishes (no NPC needed)
    -- GOSSIP_SHOW / GOSSIP_CLOSED: track NPC interaction boundaries
    autoFrame:RegisterEvent("QUEST_DETAIL")
    autoFrame:RegisterEvent("QUEST_COMPLETE")
    autoFrame:RegisterEvent("QUEST_AUTOCOMPLETE")
    autoFrame:RegisterEvent("GOSSIP_SHOW")
    autoFrame:SetScript("OnEvent", function(self, event, ...)
        if event == "GOSSIP_SHOW" then
            if C_GossipInfo then
                -- Auto turn-in: select the first completed active quest
                if Cfg("autoTurnIn") and C_GossipInfo.GetActiveQuests then
                    local active = C_GossipInfo.GetActiveQuests()
                    if active then
                        for _, quest in ipairs(active) do
                            if quest.questID and quest.isComplete then
                                C_GossipInfo.SelectActiveQuest(quest.questID)
                                return
                            end
                        end
                    end
                end
                -- Auto accept: select available quests from gossip
                if Cfg("autoAccept") and C_GossipInfo.GetAvailableQuests then
                    local available = C_GossipInfo.GetAvailableQuests()
                    if available and #available > 0 then
                        local npcGUID = UnitGUID("npc")
                        -- Prevent multi: skip if NPC originally had multiple quests
                        if Cfg("autoAcceptPreventMulti") then
                            if #available > 1 then
                                -- Remember this NPC had multiple quests
                                autoPreventNPCGUID = npcGUID
                            end
                            if autoPreventNPCGUID == npcGUID then
                                -- do nothing; let user pick manually
                            elseif available[1].questID then
                                C_GossipInfo.SelectAvailableQuest(available[1].questID)
                                return
                            end
                        elseif available[1].questID then
                            C_GossipInfo.SelectAvailableQuest(available[1].questID)
                            return
                        end
                    end
                end
            end
            return
        end
        if event == "QUEST_AUTOCOMPLETE" then
            -- Blizzard's popup is hidden because we reparented ObjectiveTrackerFrame.
            -- Show the completion dialog directly so the player can turn in.
            local qID = ...
            if qID then
                if ShowQuestComplete and type(ShowQuestComplete) == "function" then
                    pcall(ShowQuestComplete, qID)
                end
            end
            return
        end
        if event == "QUEST_DETAIL" then
            if not Cfg("autoAccept") then return end
            AcceptQuest()
        elseif event == "QUEST_COMPLETE" then
            if not Cfg("autoTurnIn") then return end
            if Cfg("autoTurnInShiftSkip") and IsShiftKeyDown() then return end
            local numChoices = GetNumQuestChoices()
            if numChoices <= 1 then
                GetQuestReward(numChoices)
            end
        end
    end)

    -- Dedicated timer update frame: only runs when timer rows exist
    _timerUpdateFrame = CreateFrame("Frame")
    _timerUpdateFrame:Hide()
    local timerElapsed = 0
    _timerUpdateFrame:SetScript("OnUpdate", function(_, dt)
        timerElapsed = timerElapsed + dt
        if timerElapsed >= 1.0 then
            timerElapsed = 0
            if #EQT.timerRows == 0 then
                _timerUpdateFrame:Hide()
                return
            end
            for _, r in ipairs(EQT.timerRows) do
                if r._updateTimer then r._updateTimer() end
            end
        end
    end)

    RegisterSlash()
    C_Timer.After(1.5, function() EQT:SetDirty(true) end)

    -------------------------------------------------------------------------------
    -- Quest item hotkey using SecureHandlerAttributeTemplate pattern (no taint)
    -- _onattributechanged runs in the secure environment and calls SetBindingClick
    -- The binding name 'EUI_QUESTITEM' is set via SetBinding/SaveBinding in options
    -------------------------------------------------------------------------------
    local qItemBtn = CreateFrame("Button", "EUI_QuestItemHotkeyBtn", UIParent,
        "SecureActionButtonTemplate, SecureHandlerAttributeTemplate")
    qItemBtn:SetSize(32, 32)
    qItemBtn:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    qItemBtn:SetAlpha(0)
    qItemBtn:EnableMouse(false)
    qItemBtn:RegisterForClicks("LeftButtonUp")

    -- Secure attribute setup must be deferred if we loaded during combat
    -- (e.g. /reload while in combat), otherwise the restricted environment
    -- handles are not yet valid and SetAttribute triggers an error.
    local function InitSecureAttributes()
        qItemBtn:SetAttribute("type", "item")
        qItemBtn:SetAttribute("_onattributechanged", [[
            if name == 'item' then
                self:ClearBindings()
                if value then
                    local key1, key2 = GetBindingKey('EUI_QUESTITEM')
                    if key1 then self:SetBindingClick(false, key1, self, 'LeftButton') end
                    if key2 then self:SetBindingClick(false, key2, self, 'LeftButton') end
                end
            end
        ]])
    end
    if InCombatLockdown() then
        local initFrame = CreateFrame("Frame")
        initFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        initFrame:SetScript("OnEvent", function(f)
            f:UnregisterAllEvents()
            InitSecureAttributes()
            if EQT.ApplyQuestItemHotkey then EQT.ApplyQuestItemHotkey() end
            if EQT.UpdateQuestItemAttribute then EQT.UpdateQuestItemAttribute() end
        end)
    else
        InitSecureAttributes()
    end

    EQT.qItemBtn = qItemBtn

    -- Set the WoW binding so GetBindingKey('EUI_QUESTITEM') works
    -- This uses SaveBindings which is the standard API
    local _applyingQuestItemHotkey = false

    local function ApplyQuestItemHotkey()
        if InCombatLockdown() then return end
        if _applyingQuestItemHotkey then return end

        _applyingQuestItemHotkey = true

        local ok, err = pcall(function()
            local key = Cfg("questItemHotkey")
            local old1, old2 = GetBindingKey("EUI_QUESTITEM")
            local hasOld = old1 or old2
            local hasNew = key and key ~= ""

            if not hasOld and not hasNew then
                return
            end

            local changed = false

            if hasOld then
                if old1 and old1 ~= key then
                    SetBinding(old1)
                    changed = true
                end
                if old2 and old2 ~= key then
                    SetBinding(old2)
                    changed = true
                end
            end

            if hasNew then
                local alreadyBound = (old1 == key or old2 == key)
                if not alreadyBound then
                    SetBinding(key, "EUI_QUESTITEM")
                    changed = true
                end
            end

            if changed then
                local bindingSet = GetCurrentBindingSet()
                if bindingSet and bindingSet >= 1 and bindingSet <= 2 then
                    SaveBindings(bindingSet)
                end
            end

            local cur = qItemBtn:GetAttribute("item")
            qItemBtn:SetAttribute("item", nil)
            qItemBtn:SetAttribute("item", cur)
        end)

        _applyingQuestItemHotkey = false

        if not ok and err then
            geterrorhandler()(err)
        end
    end
    EQT.ApplyQuestItemHotkey = ApplyQuestItemHotkey

    -- Register the binding name globally so WoW knows about it
    _G["BINDING_NAME_EUI_QUESTITEM"] = "Use Quest Item"

    local cachedQuestItemName = nil
    local questItemDirty = true

    local function UpdateQuestItemAttribute()
        if InCombatLockdown() then return end
        if not questItemDirty then return end
        questItemDirty = false

        local entries = ScanQuestLog()
        local found = nil
        for pass = 1, 3 do
            for _, e in ipairs(entries) do
                local info = e.info
                local qID = e.questID
                local wt = C_QuestLog.GetQuestWatchType and C_QuestLog.GetQuestWatchType(qID)
                local isRelevant = (pass == 1 and wt ~= nil)
                    or (pass == 2 and info.isOnMap and not info.isTask)
                    or (pass == 3 and info.isTask)
                if isRelevant and not (info.isHidden and not info.isTask) then
                    local item = GetQuestItem(qID)
                    if item and item.name then
                        found = item.name
                        break
                    end
                end
            end
            if found then break end
        end
        if found ~= cachedQuestItemName then
            cachedQuestItemName = found
            qItemBtn:SetAttribute("item", found)
        end
    end
    EQT.UpdateQuestItemAttribute = UpdateQuestItemAttribute

    local qItemFrame = CreateFrame("Frame")
    qItemFrame:RegisterEvent("QUEST_LOG_UPDATE")
    qItemFrame:RegisterEvent("QUEST_ACCEPTED")
    qItemFrame:RegisterEvent("QUEST_REMOVED")
    qItemFrame:RegisterEvent("QUEST_TURNED_IN")
    qItemFrame:RegisterEvent("UPDATE_BINDINGS")
    qItemFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    qItemFrame:SetScript("OnEvent", function(_, event)
        if InCombatLockdown() then return end

        if event == "PLAYER_REGEN_ENABLED" then
            ApplyQuestItemHotkey()
            questItemDirty = true
            UpdateQuestItemAttribute()
            if _refreshPendingAfterCombat then
                _refreshPendingAfterCombat = false
                C_Timer.After(0, function()
                    EQT:Refresh(_refreshSkipAlphaFlash)
                end)
            end
            return
        end

        if event == "UPDATE_BINDINGS" then
            local cur = qItemBtn:GetAttribute("item")
            qItemBtn:SetAttribute("item", nil)
            qItemBtn:SetAttribute("item", cur)
            return
        end

        questItemDirty = true
        UpdateQuestItemAttribute()
    end)

    C_Timer.After(1.5, function()
        if InCombatLockdown() then return end
        ApplyQuestItemHotkey()
        UpdateQuestItemAttribute()
    end)

    ---------------------------------------------------------------------------
    -- Register unlock mode element
    ---------------------------------------------------------------------------
    if EllesmereUI and EllesmereUI.RegisterUnlockElements then
        local MK = EllesmereUI.MakeUnlockElement
        local f = self.frame
        EllesmereUI:RegisterUnlockElements({
            MK({
                key   = "EQT_Tracker",
                label = "Quest Tracker",
                group = "Basics",
                order = 510,
                noResize = false,
                noAnchorTo = true,
                getFrame = function() return f end,
                getSize  = function()
                    return f:GetWidth(), f:GetHeight()
                end,
                setWidth = function(_, w)
                    w = math.max(120, math.floor(w + 0.5))
                    DB().width = w
                    EQT:Refresh(true)
                end,
                setHeight = function(_, h)
                    h = math.max(60, math.floor(h + 0.5))
                    DB().height = h
                    f:SetHeight(h)
                    if f.inner then
                        local totalH = (f.content and f.content:GetHeight() or 0) + PAD_V * 2 + 7
                        f.inner:SetHeight(math.min(totalH, h))
                        UpdateInnerAlignment(f)
                    end
                    if f._updateScrollThumb then f._updateScrollThumb() end
                end,
                savePos = function(_, point, relPoint, x, y)
                    DB().pos = { point = point, relPoint = relPoint, x = x, y = y }
                    if not EllesmereUI._unlockActive then
                        EQT:ApplyPosition()
                    end
                end,
                loadPos = function()
                    return DB().pos
                end,
                clearPos = function()
                    DB().pos = nil
                end,
                applyPos = function()
                    EQT:ApplyPosition()
                end,
            }),
        })
    end
end

-- Re-apply quest tracker after UI scale changes so position and layout stay correct
do
    local scaleFrame = CreateFrame("Frame")
    scaleFrame:RegisterEvent("UI_SCALE_CHANGED")
    scaleFrame:RegisterEvent("DISPLAY_SIZE_CHANGED")
    scaleFrame:SetScript("OnEvent", function()
        if not EQT.frame then return end
        C_Timer.After(0, function()
            EQT:ApplyPosition()
            EQT:Refresh(true)
        end)
    end)
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
local _loaderSawSelf, _loaderSawOT = false, false
loader:SetScript("OnEvent", function(self, _, loaded)
    if loaded == addonName then
        _loaderSawSelf = true
        EQT:Init()
    end
    -- Catch Blizzard's tracker loading: capture position then hide it
    if loaded == "Blizzard_ObjectiveTracker" then
        _loaderSawOT = true
        if EQT._needsCapture then
            EQT._needsCapture = false
            CaptureBlizzardTracker()
            if EQT.frame then
                EQT.frame:SetWidth(Cfg("width") or 325)
                EQT:ApplyPosition()
            end
        end
        if EQT.ApplyBlizzardTrackerVisibility then
            EQT.ApplyBlizzardTrackerVisibility()
        end
    end
    -- Once both addons have loaded, unregister to stop processing future ADDON_LOADED
    if _loaderSawSelf and _loaderSawOT then
        self:UnregisterAllEvents()
    end
end)