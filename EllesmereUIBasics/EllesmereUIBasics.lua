-------------------------------------------------------------------------------
--  EllesmereUIBasics.lua
--  Chat, Minimap, and Friends List skinning for EllesmereUI.
-------------------------------------------------------------------------------
local ADDON_NAME = ...

local EBS = EllesmereUI.Lite.NewAddon("EllesmereUIBasics")

local PP = EllesmereUI.PP

-- Modules temporarily disabled for public release (Coming Soon).
-- Force-overrides the per-module "enabled" flag so these do absolutely nothing
-- regardless of what users have in their SavedVariables.
local TEMP_DISABLED = {
    chat    = true,
    friends = true,
    -- minimap = true,
    -- questTracker = true,
    -- cursor  = true,
}
_G._EBS_TEMP_DISABLED = TEMP_DISABLED

local defaults = {
    profile = {
        chat = {
            enabled       = false,
            bgAlpha       = 0.6,
            borderR       = 0.05, borderG = 0.05, borderB = 0.05, borderA = 1,
            useClassColor = false,
            fontSize      = 14,
            hideButtons   = false,
            hideTabFlash  = false,
            position      = nil,
            visibility    = "always",
            visOnlyInstances = false,
            visHideHousing   = false,
            visHideMounted   = false,
            visHideNoTarget  = false,
            visHideNoEnemy   = false,
            fontFace           = nil,
            fontOutline        = "",
            fontShadow         = true,
            classColorNames    = true,
            clickableURLs      = true,
            shortenChannels    = "off",
            timestamps         = "none",
            messageFadeEnabled = true,
            messageFadeTime    = 120,
            messageSpacing     = 0,
            copyButton         = false,
            copyLines          = 200,
            showSearchButton   = true,
        },
        minimap = {
            enabled       = true,
            shape         = "square",
            borderSize    = 1,
            showCoords    = false,
            coordPrecision = 0,
            borderR       = 0, borderG = 0, borderB = 0, borderA = 1,
            useClassColor = false,
            hideZoneText  = false,
            scrollZoom    = true,
            autoZoomOut   = true,
            hideZoomButtons      = true,
            hideTrackingButton   = true,
            hideGameTime         = false,
            hideMail             = false,
            hideRaidDifficulty   = false,
            hideCraftingOrder    = false,
            hideAddonCompartment = false,
            hideAddonButtons     = false,
            showClock     = true,
            clockFormat   = "12h",
            lock          = false,
            position      = nil,
            visibility    = "always",
            visOnlyInstances = false,
            visHideHousing   = false,
            visHideMounted   = false,
            visHideNoTarget  = false,
            visHideNoEnemy   = false,
        },
        friends = {
            enabled       = true,
            bgAlpha       = 0.8,
            borderR       = 0.05, borderG = 0.05, borderB = 0.05, borderA = 1,
            useClassColor = false,
            visibility    = "always",
            visOnlyInstances = false,
            visHideHousing   = false,
            visHideMounted   = false,
            visHideNoTarget  = false,
            visHideNoEnemy   = false,
        },
        cursor = {
            enabled = true,
            instanceOnly = false,
            useClassColor = true,
            hex = "0CD29D",
            texture = "ring_normal",
            scale = 1,
            gcd = {
                enabled = false,
                attached = true,
                radius = 21,
                ringTex = "light",
                scale = 100,
                hex = "FFFFFF",
                alpha = 80,
                useClassColor = false,
                instanceOnly = false,
            },
            castCircle = {
                enabled = false,
                attached = true,
                radius = 30,
                ringTex = "normal",
                scale = 100,
                hex = "3FA7FF",
                alpha = 80,
                sparkEnabled = true,
                sparkHex = nil,
                useClassColor = true,
                instanceOnly = false,
            },
            trail = false,
            visibility       = "always",
            visOnlyInstances = false,
            visHideHousing   = false,
            visHideMounted   = false,
            visHideNoTarget  = false,
            visHideNoEnemy   = false,
        },
        questTracker = {
            enabled              = true,
            pos                  = nil,
            width                = 325,
            bgAlpha              = 0.7,
            bgR                  = 0,
            bgG                  = 0,
            bgB                  = 0,
            height               = 500,
            alignment            = "top",
            titleFontSize        = 11,
            titleColor           = { r=1.0,  g=0.91, b=0.47 },
            objFontSize          = 11,
            objColor             = { r=0.72, g=0.72, b=0.72 },
            completedColor       = { r=0.25, g=1.0,  b=0.35 },
            completedFontSize    = 11,
            secFontSize          = 12,
            showZoneQuests       = true,
            showWorldQuests      = true,
            zoneCollapsed        = false,
            worldCollapsed       = false,
            showQuestItems       = true,
            questItemSize        = 22,
            secColor             = { r=0.047, g=0.824, b=0.624 },
            delveCollapsed       = false,
            questsCollapsed      = false,
            showPreyQuests       = true,
            preyCollapsed        = false,
            questItemHotkey      = nil,
            autoAccept           = false,
            autoTurnIn           = false,
            autoTurnInShiftSkip  = true,
            showTopLine          = true,
            hideBlizzardTracker  = true,
            visibility           = "always",
            visOnlyInstances     = false,
            visHideHousing       = false,
            visHideMounted       = false,
            visHideNoTarget      = false,
            visHideNoEnemy       = false,
        },
    },
}

-------------------------------------------------------------------------------
--  Utility
-------------------------------------------------------------------------------
local function GetClassColor()
    local _, classFile = UnitClass("player")
    local cc = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if cc then return cc.r, cc.g, cc.b, 1 end
    return 0.05, 0.05, 0.05, 1
end

local function GetBorderColor(cfg)
    if cfg.useClassColor then
        return GetClassColor()
    end
    return cfg.borderR, cfg.borderG, cfg.borderB, cfg.borderA or 1
end

-------------------------------------------------------------------------------
--  Combat safety
-------------------------------------------------------------------------------
local pendingApply = false
local ApplyAll  -- forward declaration

local function QueueApplyAll()
    if pendingApply then return end
    pendingApply = true
end

local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function()
    if pendingApply then
        pendingApply = false
        ApplyAll()
    end
end)

-------------------------------------------------------------------------------
--  Chat Skin
-------------------------------------------------------------------------------
local skinnedChatFrames = {}

local function StripBlizzardChat(chatFrame)
    if chatFrame._ebsStripped then return end
    chatFrame._ebsStripped = true
    local name = chatFrame:GetName()
    if not name then return end

    -- Strip tab textures
    local tab = _G[name .. "Tab"]
    if tab then
        local tabTexSuffixes = {
            "Left", "Middle", "Right",
            "SelectedLeft", "SelectedMiddle", "SelectedRight",
            "ActiveLeft", "ActiveMiddle", "ActiveRight",
            "HighlightLeft", "HighlightMiddle", "HighlightRight",
        }
        for _, suffix in ipairs(tabTexSuffixes) do
            local tex = _G[name .. "Tab" .. suffix] or (tab[suffix])
            if tex and tex.SetTexture then tex:SetTexture(nil) end
        end
        -- Strip tab glow/flash textures
        if tab.glow then tab.glow:SetTexture(nil) end
        if tab.leftGlow then tab.leftGlow:SetTexture(nil) end
        if tab.rightGlow then tab.rightGlow:SetTexture(nil) end
    end

    -- Strip edit box Blizzard borders
    local editBox = _G[name .. "EditBox"]
    if editBox then
        for _, suffix in ipairs({"Left", "Mid", "Right"}) do
            local tex = _G[name .. "EditBox" .. suffix]
            if tex then tex:SetTexture(nil); tex:SetAlpha(0) end
        end
        if editBox.focusLeft then editBox.focusLeft:SetAlpha(0) end
        if editBox.focusRight then editBox.focusRight:SetAlpha(0) end
        if editBox.focusMid then editBox.focusMid:SetAlpha(0) end
        -- Also try named focus textures
        local fl = _G[name .. "EditBoxFocusLeft"]
        local fr = _G[name .. "EditBoxFocusRight"]
        local fm = _G[name .. "EditBoxFocusMid"]
        if fl then fl:SetAlpha(0) end
        if fr then fr:SetAlpha(0) end
        if fm then fm:SetAlpha(0) end
    end

    -- Strip button frame background
    local btnBg = _G[name .. "ButtonFrameBackground"]
    if btnBg then btnBg:SetAlpha(0) end
    local btnFrame = _G[name .. "ButtonFrame"]
    if btnFrame then btnFrame:SetAlpha(0) end

    -- Hide scroll bar and scroll-to-bottom button
    if chatFrame.ScrollBar then chatFrame.ScrollBar:SetAlpha(0) end
    if chatFrame.ScrollToBottomButton then chatFrame.ScrollToBottomButton:SetAlpha(0) end

    -- Strip any remaining frame background textures
    local bg = _G[name .. "Background"]
    if bg then bg:SetAlpha(0) end

    -- Disable chat frame clamping so unlock mode can position freely
    chatFrame:SetClampedToScreen(false)
end

local function SkinChatFrame(chatFrame, p)
    if not chatFrame then return end
    local name = chatFrame:GetName()
    if not name then return end

    -- Strip all Blizzard decoration first
    StripBlizzardChat(chatFrame)

    -- Dark background
    if not chatFrame._ebsBg then
        chatFrame._ebsBg = chatFrame:CreateTexture(nil, "BACKGROUND", nil, -7)
        chatFrame._ebsBg:SetColorTexture(0, 0, 0)
        chatFrame._ebsBg:SetPoint("TOPLEFT", -4, 4)
        chatFrame._ebsBg:SetPoint("BOTTOMRIGHT", 4, -4)
    end
    chatFrame._ebsBg:SetAlpha(p.bgAlpha)

    -- Border
    local r, g, b, a = GetBorderColor(p)
    if not chatFrame._ppBorders then
        PP.CreateBorder(chatFrame, r, g, b, a, 1, "OVERLAY", 7)
    else
        PP.SetBorderColor(chatFrame, r, g, b, a)
    end

    -- Edit box skin
    local editBox = _G[name .. "EditBox"]
    if editBox then
        if not editBox._ebsBg then
            editBox._ebsBg = editBox:CreateTexture(nil, "BACKGROUND", nil, -7)
            editBox._ebsBg:SetColorTexture(0, 0, 0)
            editBox._ebsBg:SetPoint("TOPLEFT", -2, 2)
            editBox._ebsBg:SetPoint("BOTTOMRIGHT", 2, -2)
        end
        editBox._ebsBg:SetAlpha(p.bgAlpha)

        if not editBox._ppBorders then
            PP.CreateBorder(editBox, r, g, b, a, 1, "OVERLAY", 7)
        else
            PP.SetBorderColor(editBox, r, g, b, a)
        end
    end

    -- Font: face, size, outline, shadow
    do
        local fontObj = chatFrame:GetFontObject()
        if fontObj then
            local curFont, _, curFlags = fontObj:GetFont()
            -- Face: use configured LSM font or preserve current
            local face = curFont
            if p.fontFace then
                local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
                if lsm then
                    local lsmPath = lsm:Fetch("font", p.fontFace)
                    if lsmPath then face = lsmPath end
                end
            end
            -- Outline
            local outline = p.fontOutline or ""
            -- Apply
            chatFrame:SetFont(face, p.fontSize, outline)
            -- Shadow
            if p.fontShadow then
                chatFrame:SetShadowOffset(1, -1)
                chatFrame:SetShadowColor(0, 0, 0, 1)
            else
                chatFrame:SetShadowOffset(0, 0)
                chatFrame:SetShadowColor(0, 0, 0, 0)
            end
        end
    end

    -- Message spacing
    if chatFrame.SetSpacing then
        chatFrame:SetSpacing(p.messageSpacing or 0)
    end

    -- Message fade
    if chatFrame.SetTimeVisible then
        if p.messageFadeEnabled then
            chatFrame:SetTimeVisible(p.messageFadeTime or 120)
            chatFrame:SetFadeDuration(3)
        else
            chatFrame:SetTimeVisible(9999)
            chatFrame:SetFadeDuration(0)
        end
    end

    skinnedChatFrames[chatFrame] = true
end

local chatButtonsHidden = false
local chatButtonHooks = {}

local function HideChatButton(btn)
    if not btn then return end
    btn:Hide()
    btn:SetAlpha(0)
    if not chatButtonHooks[btn] then
        hooksecurefunc(btn, "Show", function(self)
            if InCombatLockdown() then return end
            if _G._EBS_AceDB and _G._EBS_AceDB.profile.chat.hideButtons then
                self:SetAlpha(0)
                self:EnableMouse(false)
            end
        end)
        chatButtonHooks[btn] = true
    end
end

local function ShowChatButton(btn)
    if not btn then return end
    btn:SetAlpha(1)
    btn:Show()
end

local tabFlashHooked = false

local function UnskinChatFrame(chatFrame)
    if not chatFrame then return end
    if chatFrame._ebsBg then chatFrame._ebsBg:SetAlpha(0) end
    if chatFrame._ppBorders then PP.SetBorderColor(chatFrame, 0, 0, 0, 0) end

    local name = chatFrame:GetName()
    if name then
        local editBox = _G[name .. "EditBox"]
        if editBox then
            if editBox._ebsBg then editBox._ebsBg:SetAlpha(0) end
            if editBox._ppBorders then PP.SetBorderColor(editBox, 0, 0, 0, 0) end
        end
    end
end

local function ApplyChat()
    if InCombatLockdown() then QueueApplyAll(); return end
    if TEMP_DISABLED.chat then return end

    local p = EBS.db.profile.chat

    if not p.enabled then
        -- Revert all skinned chat frames
        for chatFrame in pairs(skinnedChatFrames) do
            UnskinChatFrame(chatFrame)
        end
        -- Restore buttons
        if chatButtonsHidden then
            local buttons = { ChatFrameMenuButton, ChatFrameChannelButton, QuickJoinToastButton }
            for _, btn in ipairs(buttons) do ShowChatButton(btn) end
            chatButtonsHidden = false
        end
        return
    end

    -- Install chat message filters/hooks on first enable
    if _G._EBS_InitChatFilters then _G._EBS_InitChatFilters() end

    local numWindows = NUM_CHAT_WINDOWS or 10
    for i = 1, numWindows do
        local chatFrame = _G["ChatFrame" .. i]
        SkinChatFrame(chatFrame, p)
    end

    -- Hook dynamic windows
    if not EBS._chatHookDone then
        EBS._chatHookDone = true
        hooksecurefunc("FCF_OpenNewWindow", function()
            C_Timer.After(0.1, function()
                if not EBS.db then return end
                local cp = EBS.db.profile.chat
                if not cp.enabled then return end
                for j = 1, NUM_CHAT_WINDOWS or 10 do
                    local cf = _G["ChatFrame" .. j]
                    if cf and not skinnedChatFrames[cf] then
                        SkinChatFrame(cf, cp)
                    end
                end
            end)
        end)
    end

    -- Hide/show buttons
    local buttons = {
        ChatFrameMenuButton,
        ChatFrameChannelButton,
        QuickJoinToastButton,
    }
    if p.hideButtons then
        for _, btn in ipairs(buttons) do
            HideChatButton(btn)
        end
        chatButtonsHidden = true
    elseif chatButtonsHidden then
        for _, btn in ipairs(buttons) do
            ShowChatButton(btn)
        end
        chatButtonsHidden = false
    end

    -- Hide tab flash
    if p.hideTabFlash and not tabFlashHooked then
        tabFlashHooked = true
        if FCF_StartAlertFlash then
            hooksecurefunc("FCF_StartAlertFlash", function(chatF)
                if EBS.db and EBS.db.profile.chat.hideTabFlash then
                    FCF_StopAlertFlash(chatF)
                end
            end)
        end
    end

    -- Apply timestamps (from EllesmereUIBasics_Chat.lua)
    if _G._EBS_ApplyTimestamps then _G._EBS_ApplyTimestamps() end

    -- Update copy/search buttons (from EllesmereUIBasics_Chat.lua)
    if _G._EBS_UpdateCopyButtons then _G._EBS_UpdateCopyButtons() end
    if _G._EBS_UpdateSearchButtons then _G._EBS_UpdateSearchButtons() end

    -- Restore saved position (managed by unlock mode)
    local cf1 = ChatFrame1
    if cf1 and p.position then
        cf1:SetUserPlaced(true)
        cf1:ClearAllPoints()
        cf1:SetPoint(p.position.point, UIParent, p.position.relPoint, p.position.x, p.position.y)
    end
end

-------------------------------------------------------------------------------
--  Minimap Skin
-------------------------------------------------------------------------------
local minimapDecorations = {
    "MinimapBorder",
    "MinimapBorderTop",
    "MinimapBackdrop",
    "MinimapNorthTag",
    "MinimapCompassTexture",
    "TimeManagerClockButton",
}

local minimapButtonMap = {
    { key = "hideZoomButtons",      names = { "MinimapZoomIn", "MinimapZoomOut" } },
    { key = "hideTrackingButton",   names = { "MiniMapTrackingButton" } },
    { key = "hideGameTime",         names = { "GameTimeFrame" } },
    { key = "hideMail",             names = { "MiniMapMailFrame" } },
    { key = "hideRaidDifficulty",   names = { "MiniMapInstanceDifficulty", "GuildInstanceDifficulty" } },
    { key = "hideCraftingOrder",    names = { "MiniMapCraftingOrderFrame" } },
    { key = "hideAddonCompartment", names = { "AddonCompartmentFrame" } },
}

local minimapButtonHooks = {}

local function HideMinimapButton(name)
    local btn = _G[name]
    if not btn then return end
    btn:Hide()
    btn:SetAlpha(0)
    if not minimapButtonHooks[name] then
        hooksecurefunc(btn, "Show", function(self)
            if InCombatLockdown() then return end
            local mp = _G._EBS_AceDB and _G._EBS_AceDB.profile.minimap
            if not mp then return end
            for _, entry in ipairs(minimapButtonMap) do
                for _, btnName in ipairs(entry.names) do
                    if btnName == name and mp[entry.key] then
                        self:SetAlpha(0)
                        return
                    end
                end
            end
        end)
        minimapButtonHooks[name] = true
    end
end

local function ShowMinimapButton(name)
    local btn = _G[name]
    if not btn then return end
    btn:SetAlpha(1)
    btn:EnableMouse(true)
    btn:Show()
end

-- Forward declarations for flyout system
local addonButtonPoll = nil
local cachedAddonButtons = {}
local flyoutOwnedFrames = {}

-------------------------------------------------------------------------------
--  Minimap Button Flyout
-------------------------------------------------------------------------------
local flyoutToggle = nil   -- the square trigger button
local flyoutPanel  = nil   -- the popup grid container
local flyoutSavedParents = {}  -- original parent/point data for restore
local flyoutSavedRegions = {}  -- original region states for restore

local FLYOUT_BTN_SIZE = 21
local FLYOUT_PADDING  = 4
local FLYOUT_COLS     = 4

-- Textures that are decorative borders/backgrounds on minimap buttons
local MINIMAP_BTN_JUNK = {
    [136467] = true,  -- UI-Minimap-Background
    [136430] = true,  -- MiniMap-TrackingBorder
    [136477] = true,  -- UI-Minimap-ZoomButton-Highlight (used on some buttons)
}
local MINIMAP_BTN_JUNK_PATH = {
    ["Interface\\Minimap\\MiniMap%-TrackingBorder"] = true,
    ["Interface\\Minimap\\UI%-Minimap%-Background"] = true,
    ["Interface\\Minimap\\UI%-Minimap%-ZoomButton%-Highlight"] = true,
}

local function IsJunkTexture(region)
    if not region or not region.IsObjectType or not region:IsObjectType("Texture") then
        return false
    end
    local texID = region.GetTextureFileID and region:GetTextureFileID()
    if texID and MINIMAP_BTN_JUNK[texID] then return true end
    local texPath = region:GetTexture()
    if texPath and type(texPath) == "string" then
        for pattern in pairs(MINIMAP_BTN_JUNK_PATH) do
            if texPath:match(pattern) then return true end
        end
    end
    return false
end

local function StripButtonDecorations(btn)
    local saved = {}
    for _, region in ipairs({ btn:GetRegions() }) do
        if IsJunkTexture(region) then
            saved[#saved + 1] = { region = region, alpha = region:GetAlpha(), shown = region:IsShown() }
            region:SetAlpha(0)
            region:Hide()
        end
    end
    -- Also hide highlight/pushed overlays that have junk textures
    local hl = btn.GetHighlightTexture and btn:GetHighlightTexture()
    if hl and IsJunkTexture(hl) then
        saved[#saved + 1] = { region = hl, alpha = hl:GetAlpha(), shown = hl:IsShown() }
        hl:SetAlpha(0)
        hl:Hide()
    end
    flyoutSavedRegions[btn] = saved
end

local function RestoreButtonDecorations(btn)
    local saved = flyoutSavedRegions[btn]
    if not saved then return end
    for _, info in ipairs(saved) do
        info.region:SetAlpha(info.alpha)
        if info.shown then info.region:Show() end
    end
    flyoutSavedRegions[btn] = nil
end

local function CollectFlyoutButtons()
    -- Return all collected minimap buttons (populated by GatherMinimapButtons)
    local collected = {}
    for _, btn in ipairs(cachedAddonButtons) do
        collected[#collected + 1] = btn
    end
    return collected
end

local function LayoutFlyoutButtons()
    if not flyoutPanel then return end
    local buttons = CollectFlyoutButtons()
    local count = #buttons
    if count == 0 then
        flyoutPanel:SetSize(1, 1)
        return
    end

    local cols = math.min(count, FLYOUT_COLS)
    local rows = math.ceil(count / cols)
    local pw = FLYOUT_PADDING + cols * (FLYOUT_BTN_SIZE + FLYOUT_PADDING)
    local ph = FLYOUT_PADDING + rows * (FLYOUT_BTN_SIZE + FLYOUT_PADDING)
    flyoutPanel:SetSize(pw, ph)

    for i, btn in ipairs(buttons) do
        -- Save original parent/points for restore
        if not flyoutSavedParents[btn] then
            local p1, rel, p2, ox, oy = btn:GetPoint(1)
            flyoutSavedParents[btn] = {
                parent = btn:GetParent(),
                strata = btn:GetFrameStrata(),
                point = p1, relTo = rel, relPoint = p2, x = ox, y = oy,
            }
        end

        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local xOff = FLYOUT_PADDING + col * (FLYOUT_BTN_SIZE + FLYOUT_PADDING)
        local yOff = -(FLYOUT_PADDING + row * (FLYOUT_BTN_SIZE + FLYOUT_PADDING))

        btn:SetParent(flyoutPanel)
        -- Unlock fixed strata/level first (LibDBIcon locks these)
        if btn.SetFixedFrameStrata then btn:SetFixedFrameStrata(false) end
        if btn.SetFixedFrameLevel then btn:SetFixedFrameLevel(false) end
        btn:SetFrameStrata("DIALOG")
        if btn.SetFixedFrameStrata then btn:SetFixedFrameStrata(true) end
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", flyoutPanel, "TOPLEFT", xOff, yOff)
        btn:SetSize(FLYOUT_BTN_SIZE, FLYOUT_BTN_SIZE)
        btn:SetAlpha(1)
        btn:Show()
        btn:SetFrameLevel(flyoutPanel:GetFrameLevel() + 5)
        if btn.SetFixedFrameLevel then btn:SetFixedFrameLevel(true) end
        -- Strip decorative border/background textures
        StripButtonDecorations(btn)
        -- Also force all child frames up to the same strata/level
        for _, child in ipairs({ btn:GetChildren() }) do
            child:SetFrameStrata("DIALOG")
            child:SetFrameLevel(flyoutPanel:GetFrameLevel() + 6)
        end
        -- Normalize icon region to fill the button cleanly
        local icon = btn.icon or btn.Icon
        if not icon then
            for _, region in ipairs({ btn:GetRegions() }) do
                if region:IsObjectType("Texture") and region:IsShown()
                   and region:GetAlpha() > 0 and not IsJunkTexture(region) then
                    icon = region
                    break
                end
            end
        end
        if icon then
            icon:ClearAllPoints()
            icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
            icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
            icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
        end
        -- Add atlas ring border overlay
        if not btn._flyoutRing then
            local ring = btn:CreateTexture(nil, "OVERLAY", nil, 7)
            ring:SetAtlas("AdventureMap-combatally-ring")
            ring:SetPoint("TOPLEFT", btn, "TOPLEFT", -3, 3)
            ring:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 3, -3)
            btn._flyoutRing = ring
        end
        btn._flyoutRing:Show()
    end
end

local function RestoreFlyoutButtons()
    for btn, saved in pairs(flyoutSavedParents) do
        RestoreButtonDecorations(btn)
        if btn._flyoutRing then btn._flyoutRing:Hide() end
        if btn.SetFixedFrameStrata then btn:SetFixedFrameStrata(false) end
        if btn.SetFixedFrameLevel then btn:SetFixedFrameLevel(false) end
        btn:SetParent(saved.parent)
        btn:SetFrameStrata(saved.strata)
        btn:ClearAllPoints()
        if saved.point and saved.relTo then
            btn:SetPoint(saved.point, saved.relTo, saved.relPoint, saved.x, saved.y)
        end
        -- Re-hide on the minimap surface
        btn:Hide()
        btn:SetAlpha(0)
    end
    wipe(flyoutSavedParents)
end

local function ShowFlyoutPanel()
    if not flyoutPanel then
        flyoutPanel = CreateFrame("Frame", nil, Minimap, "BackdropTemplate")
        flyoutPanel:SetFrameStrata("DIALOG")
        flyoutPanel:SetBackdrop({
            bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeSize = 1,
        })
        flyoutPanel:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
        flyoutPanel:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        flyoutPanel:SetPoint("BOTTOMLEFT", flyoutToggle, "TOPLEFT", 0, 2)
        flyoutPanel:SetClampedToScreen(true)
        flyoutOwnedFrames[flyoutPanel] = true
    end
    LayoutFlyoutButtons()
    flyoutPanel:Show()
end

local function HideFlyoutPanel()
    if flyoutPanel then
        flyoutPanel:Hide()
        RestoreFlyoutButtons()
    end
end

local function ToggleFlyoutPanel()
    if flyoutPanel and flyoutPanel:IsShown() then
        HideFlyoutPanel()
    else
        ShowFlyoutPanel()
    end
end

local function CreateFlyoutToggle()
    if flyoutToggle then return flyoutToggle end

    local btn = CreateFrame("Button", nil, Minimap)
    local iconSize = (MinimapCluster and MinimapCluster.Tracking)
        and MinimapCluster.Tracking:GetHeight() or 22
    btn:SetSize(iconSize, iconSize)
    btn:SetPoint("BOTTOMRIGHT", Minimap, "BOTTOMLEFT", 0, 0)
    btn:SetFrameLevel(Minimap:GetFrameLevel() + 10)

    local norm = btn:CreateTexture(nil, "ARTWORK")
    norm:SetAllPoints()
    norm:SetAtlas("Map-Filter-Button")
    btn:SetNormalTexture(norm)

    local pushed = btn:CreateTexture(nil, "ARTWORK")
    pushed:SetAllPoints()
    pushed:SetAtlas("Map-Filter-Button-down")
    btn:SetPushedTexture(pushed)

    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetAtlas("Map-Filter-Button")
    hl:SetAlpha(0.3)
    btn:SetHighlightTexture(hl)

    -- Black background to match indicator icons
    local bg = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    bg:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground" })
    bg:SetBackdropColor(0, 0, 0, 0.8)
    bg:SetAllPoints(btn)
    bg:SetFrameLevel(btn:GetFrameLevel() - 1)

    btn:SetScript("OnClick", ToggleFlyoutPanel)

    -- Safety: ensure mouse stays enabled. Some Blizzard code or addon hooks
    -- on minimap children can disable mouse input. Re-assert on every Show.
    btn:HookScript("OnShow", function(self)
        if not self:IsMouseEnabled() then
            self:EnableMouse(true)
        end
    end)

    flyoutToggle = btn
    flyoutOwnedFrames[btn] = true
    return btn
end

local coordFrame, coordTicker
local clockFrame, clockTicker, clockBg
local locationFrame, locationBg

local function GetMinimapFont()
    local path = EllesmereUI.GetFontPath and EllesmereUI.GetFontPath() or STANDARD_TEXT_FONT
    local flag = EllesmereUI.GetFontOutlineFlag and EllesmereUI.GetFontOutlineFlag() or "OUTLINE"
    return path, flag
end

local function ApplyMinimapFont(fs, size)
    local path, flag = GetMinimapFont()
    fs:SetFont(path, size, flag)
    if EllesmereUI.GetFontUseShadow and EllesmereUI.GetFontUseShadow() then
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0, 0, 0, 0.8)
    else
        fs:SetShadowOffset(0, 0)
    end
end

-- Cache clock CVars so we don't read them every second
local cachedUse24h, cachedUseLocal
local function RefreshClockCVars()
    cachedUse24h = GetCVar("timeMgrUseMilitaryTime") == "1"
    cachedUseLocal = GetCVar("timeMgrUseLocalTime") == "1"
end

local function UpdateClock()
    if not clockFrame then return end
    if cachedUse24h == nil then RefreshClockCVars() end
    if cachedUseLocal then
        local fmt = cachedUse24h and "%H:%M" or "%I:%M %p"
        clockFrame:SetText(date(fmt))
    else
        local h, m = GetGameTime()
        if cachedUse24h then
            clockFrame:SetText(format("%02d:%02d", h, m))
        else
            local ampm = h >= 12 and "PM" or "AM"
            h = h % 12
            if h == 0 then h = 12 end
            clockFrame:SetText(format("%d:%02d %s", h, m, ampm))
        end
    end
end

-- Cache coord format string so we don't rebuild it every 0.5s
local cachedCoordPrec, cachedCoordFmt
local function UpdateCoords()
    if not coordFrame then return end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then coordFrame:SetText(""); return end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then coordFrame:SetText(""); return end
    local x, y = pos:GetXY()
    local p = EBS.db and EBS.db.profile.minimap
    local prec = p and p.coordPrecision or 1
    if prec ~= cachedCoordPrec then
        cachedCoordPrec = prec
        cachedCoordFmt = format("%%.%df, %%.%df", prec, prec)
    end
    coordFrame:SetText(format(cachedCoordFmt, x * 100, y * 100))
end

local lastLocationText
local function UpdateLocation()
    if not locationFrame then return end
    if InCombatLockdown() then return end
    local sub = GetSubZoneText()
    local text = (sub and sub ~= "") and sub or (GetZoneText() or "")
    if text == lastLocationText then return end
    lastLocationText = text
    locationFrame:SetText(text)
    if locationBg then
        local tw = locationFrame:GetStringWidth() or 0
        locationBg:SetSize(tw + 20, 18)
    end
end

local autoZoomTimer = nil

local function CancelAutoZoom()
    if autoZoomTimer then
        autoZoomTimer:Cancel()
        autoZoomTimer = nil
    end
end

local function ScheduleAutoZoom()
    CancelAutoZoom()
    local p = _G._EBS_AceDB and _G._EBS_AceDB.profile.minimap
    if not p or not p.autoZoomOut then return end
    if Minimap:GetZoom() == 0 then return end
    autoZoomTimer = C_Timer.NewTimer(10, function()
        Minimap:SetZoom(0)
        autoZoomTimer = nil
    end)
end

-- Blizzard structural frames that should NOT go into the flyout
local flyoutBlacklist = {
    MinimapZoomIn    = true,
    MinimapZoomOut   = true,
    MinimapBackdrop  = true,
    GameTimeFrame    = true,
}

-- Persistently hide a minimap button via Show hook
local addonButtonHooks = {}

local function HideMinimapChild(btn)
    btn:Hide()
    btn:SetAlpha(0)
    if not addonButtonHooks[btn] then
        hooksecurefunc(btn, "Show", function(self)
            if InCombatLockdown() then return end
            -- Allow showing when parented to the flyout panel
            if self:GetParent() == flyoutPanel then return end
            local mp = _G._EBS_AceDB and _G._EBS_AceDB.profile.minimap
            if mp and mp.enabled and not flyoutOwnedFrames[self] then
                self:SetAlpha(0)
            end
        end)
        addonButtonHooks[btn] = true
    end
end

local function ShowMinimapChild(btn)
    btn:SetAlpha(1)
    btn:EnableMouse(true)
    btn:Show()
end

-- Pin/POI frame patterns to exclude from the flyout (HandyNotes, TomTom, etc.)
local flyoutPinPatterns = {
    "^HandyNotes",
    "^TomTom",
    "^HereBeDragons",
    "^Questie",
    "^GatherMate",
    "^pin",
    "^Pin",
}

local function IsPinFrame(name)
    if not name then return false end
    for _, pat in ipairs(flyoutPinPatterns) do
        if name:match(pat) then return true end
    end
    return false
end

-- Gather all minimap buttons (Blizzard + addon) into cachedAddonButtons
local function GatherMinimapButtons()
    wipe(cachedAddonButtons)
    if not Minimap then return end
    for _, child in ipairs({ Minimap:GetChildren() }) do
        if not flyoutOwnedFrames[child] then
            local name = child:GetName()
            -- Skip blacklisted structural frames and map pin frames
            if flyoutBlacklist[name] then
                -- skip
            elseif IsPinFrame(name) then
                -- skip pin/POI frames (HandyNotes, TomTom, etc.)
            elseif child:IsObjectType("Button") and name then
                -- Skip tiny frames (map pins are typically < 20px, real buttons are 25+)
                local w = child:GetWidth() or 0
                if w >= 20 then
                    cachedAddonButtons[#cachedAddonButtons + 1] = child
                end
            elseif not child:IsObjectType("Button") and name and name:match("^LibDBIcon10_") then
                -- LibDBIcon sometimes uses Frame instead of Button
                cachedAddonButtons[#cachedAddonButtons + 1] = child
            end
        end
    end
end

-- Hide all collected minimap buttons from the map surface
local function HideAllMinimapButtons()
    GatherMinimapButtons()
    for _, btn in ipairs(cachedAddonButtons) do
        HideMinimapChild(btn)
    end
end

local function ShowAllMinimapButtons()
    for _, btn in ipairs(cachedAddonButtons) do
        ShowMinimapChild(btn)
    end
    wipe(cachedAddonButtons)
end

-------------------------------------------------------------------------------
--  Minimap Indicator Frames (top-left outer: Tracking, Calendar, Mail, Crafting)
-------------------------------------------------------------------------------
local indicatorBg = nil
local indicatorIconBgs = {}

local function GetIconBg(frame)
    if indicatorIconBgs[frame] then return indicatorIconBgs[frame] end
    local bg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    bg:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground" })
    bg:SetBackdropColor(0, 0, 0, 0.8)
    bg:SetAllPoints(frame)
    bg:SetFrameLevel(frame:GetFrameLevel() - 1)
    indicatorIconBgs[frame] = bg
    return bg
end

local function ShrinkTrackingIcon(tracking)
    local tBtn = tracking.Button
    if tBtn then
        tBtn:ClearAllPoints()
        tBtn:SetPoint("CENTER", tracking, "CENTER", 0, 0)
        local tw2 = (tracking:GetWidth() or 22) - 3
        local th2 = (tracking:GetHeight() or 22) - 3
        tBtn:SetSize(tw2, th2)
    end
end

local function LayoutIndicatorFrames(minimap, p, circleMode)
    local flvl = minimap:GetFrameLevel() + 10

    local tracking = MinimapCluster and MinimapCluster.Tracking
    local gameTime = _G.GameTimeFrame
    local indicator = MinimapCluster and MinimapCluster.IndicatorFrame
    local mailFrame = indicator and indicator.MailFrame
    local craftingFrame = indicator and indicator.CraftingOrderFrame

    -- Reparent indicator children onto minimap (cluster is hidden).
    -- Guard with InCombatLockdown to avoid tainting during protected operations.
    if not InCombatLockdown() then
        if tracking then tracking:SetParent(minimap); tracking:SetFrameLevel(flvl + 1) end
        if gameTime then gameTime:SetParent(minimap); gameTime:SetFrameLevel(flvl + 1) end
        if mailFrame then mailFrame:SetParent(minimap); mailFrame:SetFrameLevel(flvl + 1) end
        if craftingFrame then craftingFrame:SetParent(minimap); craftingFrame:SetFrameLevel(flvl + 1) end
    end
    -- Difficulty flag (instance type/size indicator)
    local diffFrame = (MinimapCluster and MinimapCluster.InstanceDifficulty) or _G.MiniMapInstanceDifficulty
    if diffFrame then
        diffFrame:SetParent(minimap)
        diffFrame:SetFrameLevel(flvl + 2)
        diffFrame:ClearAllPoints()
        diffFrame:SetPoint("TOPRIGHT", minimap, "TOPRIGHT", 2, 1)
        if p.hideRaidDifficulty then
            diffFrame:SetAlpha(0)
        else
            diffFrame:SetAlpha(1)
        end
    end
    -- Blizzard indicator children call self:GetParent():Layout() on events;
    -- provide a no-op so reparented frames don't error
    if not minimap.Layout then minimap.Layout = function() end end

    if circleMode then
        -----------------------------------------------------------------------
        -- Circle layout: horizontal row around the clock
        -- [crafting][mail][tracking] [CLOCK] [calendar]
        -----------------------------------------------------------------------

        -- Tracking -- flush left of clock
        if tracking then
            tracking:ClearAllPoints()
            if clockBg and p.showClock then
                tracking:SetPoint("RIGHT", clockBg, "LEFT", 0, 0)
            else
                tracking:SetPoint("TOP", minimap, "TOP", -20, -3)
            end
            tracking:Show()
            ShrinkTrackingIcon(tracking)
        end

        -- Calendar -- flush right of clock
        if gameTime then
            if not p.hideGameTime then
                gameTime:ClearAllPoints()
                if clockBg and p.showClock then
                    gameTime:SetPoint("LEFT", clockBg, "RIGHT", 0, 0)
                else
                    gameTime:SetPoint("TOP", minimap, "TOP", 20, -3)
                end
                gameTime:SetAlpha(1)
                gameTime:Show()
                gameTime:SetFrameLevel(flvl + 1)
            else
                gameTime:Hide()
            end
        end

        -- Mail -- left of tracking, building left
        if mailFrame then
            mailFrame:ClearAllPoints()
            if tracking then
                mailFrame:SetPoint("RIGHT", tracking, "LEFT", 0, 0)
            elseif clockBg and p.showClock then
                mailFrame:SetPoint("RIGHT", clockBg, "LEFT", 0, 0)
            end
        end

        -- Crafting Order -- left of mail, building left
        if craftingFrame then
            craftingFrame:ClearAllPoints()
            if mailFrame then
                craftingFrame:SetPoint("RIGHT", mailFrame, "LEFT", 0, 0)
            elseif tracking then
                craftingFrame:SetPoint("RIGHT", tracking, "LEFT", 0, 0)
            end
        end

        -- Individual black backgrounds behind each icon
        if tracking then GetIconBg(tracking):Show() end
        if gameTime and not p.hideGameTime then GetIconBg(gameTime):Show() end
        if mailFrame then
            local bg = GetIconBg(mailFrame)
            if mailFrame:IsShown() then bg:Show() else bg:Hide() end
        end
        if craftingFrame then
            local bg = GetIconBg(craftingFrame)
            if craftingFrame:IsShown() then bg:Show() else bg:Hide() end
        end
        if indicatorBg then indicatorBg:Hide() end

    else
        -----------------------------------------------------------------------
        -- Square layout: vertical stack on the left side, building down
        -- [tracking] [calendar] [mail] [crafting]
        -----------------------------------------------------------------------
        local y = 0
        local w = 0
        local visCount = 0

        if tracking then
            tracking:ClearAllPoints()
            tracking:SetPoint("TOPRIGHT", minimap, "TOPLEFT", -1, y)
            tracking:Show()
            ShrinkTrackingIcon(tracking)
            local tw = tracking:GetWidth() or 22
            y = y - (tracking:GetHeight() or 22)
            if tw > w then w = tw end
            visCount = visCount + 1
        end

        if gameTime then
            if not p.hideGameTime then
                gameTime:ClearAllPoints()
                gameTime:SetPoint("TOPRIGHT", minimap, "TOPLEFT", 2, y)
                gameTime:SetAlpha(1)
                gameTime:Show()
                gameTime:SetFrameLevel(flvl + 1)
                local gw = gameTime:GetWidth() or 22
                y = y - (gameTime:GetHeight() or 22)
                if gw > w then w = gw end
                visCount = visCount + 1
            else
                gameTime:Hide()
            end
        end

        if mailFrame then
            mailFrame:ClearAllPoints()
            mailFrame:SetPoint("TOPRIGHT", minimap, "TOPLEFT", 0, y)
            if mailFrame:IsShown() then
                local mw = mailFrame:GetWidth() or 22
                y = y - (mailFrame:GetHeight() or 22)
                if mw > w then w = mw end
                visCount = visCount + 1
            end
        end

        if craftingFrame then
            craftingFrame:ClearAllPoints()
            craftingFrame:SetPoint("TOPRIGHT", minimap, "TOPLEFT", 0, y)
            if craftingFrame:IsShown() then
                local cw = craftingFrame:GetWidth() or 22
                y = y - (craftingFrame:GetHeight() or 22)
                if cw > w then w = cw end
                visCount = visCount + 1
            end
        end

        -- Hide individual icon backgrounds (square uses the combined one)
        for frame, bg in pairs(indicatorIconBgs) do bg:Hide() end

        -- Black background sized to visible icons only
        local totalH = -y
        if visCount > 0 and totalH > 0 then
            if not indicatorBg then
                indicatorBg = CreateFrame("Frame", nil, minimap, "BackdropTemplate")
                indicatorBg:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground" })
                indicatorBg:SetBackdropColor(0, 0, 0, 0.8)
            end
            indicatorBg:SetParent(minimap)
            indicatorBg:ClearAllPoints()
            indicatorBg:SetPoint("TOPRIGHT", minimap, "TOPLEFT", 0, 0)
            indicatorBg:SetSize(w, totalH)
            indicatorBg:SetFrameLevel(flvl)
            indicatorBg:Show()
        elseif indicatorBg then
            indicatorBg:Hide()
        end
    end
end

local function RestoreIndicatorFrames()
    local tracking = MinimapCluster and MinimapCluster.Tracking
    if tracking then
        tracking:SetParent(MinimapCluster)
        tracking:ClearAllPoints()
        tracking:Show()
    end

    local indicator = MinimapCluster and MinimapCluster.IndicatorFrame
    if indicator then
        indicator:Show()
        if indicator.MailFrame then
            indicator.MailFrame:SetParent(indicator)
            indicator.MailFrame:ClearAllPoints()
        end
        if indicator.CraftingOrderFrame then
            indicator.CraftingOrderFrame:SetParent(indicator)
            indicator.CraftingOrderFrame:ClearAllPoints()
        end
        -- Trigger Blizzard's layout so children get their default anchors back
        if indicator.Layout then indicator:Layout() end
    end

    local gameTime = _G.GameTimeFrame
    if gameTime then
        if indicator then
            gameTime:SetParent(indicator)
        elseif MinimapCluster then
            gameTime:SetParent(MinimapCluster)
        end
        gameTime:ClearAllPoints()
        gameTime:SetAlpha(1)
        gameTime:Show()
    end

    -- Remove the no-op Layout we added to the minimap
    if Minimap and Minimap.Layout then Minimap.Layout = nil end

    -- Trigger MinimapCluster layout to restore all default positions
    if MinimapCluster and MinimapCluster.Layout then
        MinimapCluster:Layout()
    end

    if indicatorBg then indicatorBg:Hide() end
end

-------------------------------------------------------------------------------
-- Snapshot Blizzard minimap size and position on first install.
-- Captures the native size and center position so our module starts matching
-- whatever the user had via Edit Mode. Only runs once per profile.
-------------------------------------------------------------------------------
local function CaptureBlizzardMinimap()
    local minimap = Minimap
    if not minimap then return end
    local p = EBS.db.profile.minimap
    if p._capturedOnce then return end

    local uiScale = UIParent:GetEffectiveScale()
    local mScale  = minimap:GetEffectiveScale()
    local ratio   = mScale / uiScale

    -- Capture size (use the larger dimension to keep it square)
    local w, h = minimap:GetWidth(), minimap:GetHeight()
    if w and w > 10 then
        local sz = math.floor(math.max(w, h) * ratio + 0.5)
        p.mapSize = sz
    end

    -- Capture center position as CENTER/CENTER offset from UIParent
    local cx, cy = minimap:GetCenter()
    if cx and cy then
        local uiW, uiH = UIParent:GetSize()
        cx = cx * ratio
        cy = cy * ratio
        p.position = {
            point = "CENTER", relPoint = "CENTER",
            x = cx - (uiW / 2), y = cy - (uiH / 2),
        }
    end

    p._capturedOnce = true
end

local function ApplyMinimap()
    if TEMP_DISABLED.minimap then return end
    if InCombatLockdown() then QueueApplyAll(); return end

    local p = EBS.db.profile.minimap

    local minimap = Minimap
    if not minimap then return end

    if not p.enabled then
        -- If we never touched the minimap this session, do absolutely nothing.
        -- This ensures zero interference with other minimap addons.
        if not minimap._ebsActive then return end
        -- Module was active but is now disabled; a reload is required to
        -- cleanly hand control back to Blizzard. The options toggle handles
        -- prompting the user for a reload.
        return
    end

    -- Snapshot Blizzard's native size/position before we modify anything
    CaptureBlizzardMinimap()

    -- Reparent minimap to UIParent so MinimapCluster layout cannot override our size.
    -- Deferred via C_Timer.After(0) to avoid tainting the secure frame environment
    -- when ApplyMinimap fires during a ShowUIPanel/World Map open sequence, which
    -- would cause ADDON_ACTION_BLOCKED when Blizzard's dungeon pin data provider
    -- later calls the protected SetPropagateMouseClicks() on map pins.
    local needsReparent = minimap:GetParent() ~= UIParent
    local needsClusterHide = MinimapCluster and MinimapCluster:IsShown()
    if needsReparent or needsClusterHide then
        C_Timer.After(0, function()
            if InCombatLockdown() then return end
            if needsReparent and minimap:GetParent() ~= UIParent then
                minimap:SetParent(UIParent)
            end
            if needsClusterHide and MinimapCluster then
                MinimapCluster:SetAlpha(0)
                MinimapCluster:EnableMouse(false)
            end
        end)
    end
    minimap:Show()

    -- Hide default decorations
    for _, name in ipairs(minimapDecorations) do
        local frame = _G[name]
        if frame then frame:Hide() end
    end

    -- Hide AddonCompartmentFrame by reparenting to a hidden frame
    local compartment = _G.AddonCompartmentFrame
    if compartment then
        if not EBS._hiddenFrame then
            EBS._hiddenFrame = CreateFrame("Frame")
            EBS._hiddenFrame:Hide()
        end
        compartment._ebsOrigParent = compartment._ebsOrigParent or compartment:GetParent()
        compartment:SetParent(EBS._hiddenFrame)
    end

    local isCircle = (p.shape == "circle" or p.shape == "textured_circle")

    -- Hide background (no black bg behind minimap)
    if minimap._ebsBg then minimap._ebsBg:SetAlpha(0) end

    -- Border
    local r, g, b = GetBorderColor(p)
    if p.shape == "square" then
        -- Square: pixel-perfect border
        local bs = p.borderSize or 1
        if not minimap._ppBorders then
            PP.CreateBorder(minimap, r, g, b, 1, bs, "OVERLAY", 7)
        else
            PP.SetBorderColor(minimap, r, g, b, 1)
        end
        PP.SetBorderSize(minimap, bs)
        if minimap._circBorder then minimap._circBorder:Hide() end
        if minimap._texCircBorder then minimap._texCircBorder:Hide() end
    elseif p.shape == "circle" then
        -- Circle: solid colored disc behind the minimap, slightly larger = border ring
        if minimap._ppBorders then PP.SetBorderSize(minimap, 0); PP.SetBorderColor(minimap, 0, 0, 0, 0) end
        if not minimap._circBorder then
            local disc = CreateFrame("Frame", nil, minimap)
            disc:SetFrameLevel(minimap:GetFrameLevel() - 1)
            local tex = disc:CreateTexture(nil, "BACKGROUND")
            tex:SetAllPoints(disc)
            tex:SetTexture("Interface\\Common\\CommonMaskCircle")
            disc._tex = tex
            minimap._circBorder = disc
        end
        local bs = p.borderSize or 1
        minimap._circBorder:ClearAllPoints()
        minimap._circBorder:SetPoint("TOPLEFT", minimap, "TOPLEFT", -bs, bs)
        minimap._circBorder:SetPoint("BOTTOMRIGHT", minimap, "BOTTOMRIGHT", bs, -bs)
        minimap._circBorder._tex:SetVertexColor(r, g, b, 1)
        minimap._circBorder:Show()
        if minimap._texCircBorder then minimap._texCircBorder:Hide() end
    elseif p.shape == "textured_circle" then
        -- Textured Circle: void ring border, hide the solid circle border
        if minimap._ppBorders then PP.SetBorderSize(minimap, 0); PP.SetBorderColor(minimap, 0, 0, 0, 0) end
        if minimap._circBorder then minimap._circBorder:Hide() end
        if not minimap._texCircBorder then
            local ring = minimap:CreateTexture(nil, "OVERLAY", nil, 7)
            ring:SetAtlas("wowlabs_minimapvoid-ring-single")
            minimap._texCircBorder = ring
        end
        local inset = 2
        minimap._texCircBorder:ClearAllPoints()
        minimap._texCircBorder:SetPoint("TOPLEFT", minimap, "TOPLEFT", -inset, inset)
        minimap._texCircBorder:SetPoint("BOTTOMRIGHT", minimap, "BOTTOMRIGHT", inset, -inset)
        minimap._texCircBorder:SetVertexColor(r, g, b, 1)
        minimap._texCircBorder:Show()
    end

    -- Size
    minimap:SetScale(1.0)
    local mapSize = p.mapSize or 140
    minimap:SetSize(mapSize, mapSize)
    -- Shape mask
    minimap:SetMaskTexture(isCircle and 186178 or 130937)
    -- Clamp to screen so the border never extends off-screen
    minimap:SetClampedToScreen(true)
    local bInset = isCircle and (p.borderSize or 1) or 0
    minimap:SetClampRectInsets(-bInset, bInset, bInset, -bInset)
    -- Force the minimap engine to re-render at the new size. Nudge the zoom
    -- to a different value now, then restore it on the next rendered frame.
    -- Doing both in the same frame gets optimized away by the engine.
    local savedZoom = minimap:GetZoom()
    local nudgeZoom = savedZoom < minimap:GetZoomLevels() and savedZoom + 1 or savedZoom - 1
    minimap:SetZoom(nudgeZoom)
    if not minimap._zoomRestoreFrame then
        minimap._zoomRestoreFrame = CreateFrame("Frame")
    end
    minimap._zoomRestoreFrame._targetZoom = savedZoom
    minimap._zoomRestoreFrame:SetScript("OnUpdate", function(self)
        self:SetScript("OnUpdate", nil)
        minimap:SetZoom(self._targetZoom)
    end)

    -- Reposition zoom buttons to bottom-right corner of the minimap.
    -- Parent to minimap, raise frame level above the map surface, and
    -- hook SetPoint to prevent Blizzard from re-anchoring them.
    -- Midnight uses Minimap.ZoomIn/ZoomOut (not global MinimapZoomIn).
    local zoomIn = minimap.ZoomIn or _G.MinimapZoomIn
    local zoomOut = minimap.ZoomOut or _G.MinimapZoomOut
    if zoomIn then
        zoomIn:SetParent(minimap)
        zoomIn:SetFrameLevel(minimap:GetFrameLevel() + 10)
        zoomIn:ClearAllPoints()
        zoomIn:SetPoint("BOTTOMRIGHT", minimap, "BOTTOMRIGHT", -2, 20)
        zoomIn:EnableMouse(true)
        zoomIn:Show()
        if not zoomIn._ebsHooked then
            hooksecurefunc(zoomIn, "SetPoint", function(self)
                if self._ebsInHook then return end
                self._ebsInHook = true
                self:ClearAllPoints()
                self:SetPoint("BOTTOMRIGHT", minimap, "BOTTOMRIGHT", -2, 20)
                self._ebsInHook = false
            end)
            zoomIn._ebsHooked = true
        end
    end
    if zoomOut then
        zoomOut:SetParent(minimap)
        zoomOut:SetFrameLevel(minimap:GetFrameLevel() + 10)
        zoomOut:ClearAllPoints()
        zoomOut:SetPoint("BOTTOMRIGHT", minimap, "BOTTOMRIGHT", -2, 2)
        zoomOut:EnableMouse(true)
        zoomOut:Show()
        if not zoomOut._ebsHooked then
            hooksecurefunc(zoomOut, "SetPoint", function(self)
                if self._ebsInHook then return end
                self._ebsInHook = true
                self:ClearAllPoints()
                self:SetPoint("BOTTOMRIGHT", minimap, "BOTTOMRIGHT", -2, 2)
                self._ebsInHook = false
            end)
            zoomOut._ebsHooked = true
        end
    end

    -- Mark zoom buttons so GatherMinimapButtons skips them
    if zoomIn then flyoutOwnedFrames[zoomIn] = true end
    if zoomOut then flyoutOwnedFrames[zoomOut] = true end

    -- Flyout toggle button (bottom-left corner) -- create before hiding children
    CreateFlyoutToggle()
    flyoutToggle:Show()

    -- Hide ALL minimap child frames from the map surface
    HideAllMinimapButtons()

    -- Poll for late-loading addons that attach buttons after ADDON_LOADED
    if not addonButtonPoll then
        addonButtonPoll = CreateFrame("Frame")
        addonButtonPoll:RegisterEvent("ADDON_LOADED")
        local pollPending = false
        addonButtonPoll:SetScript("OnEvent", function()
            if pollPending then return end
            pollPending = true
            C_Timer.After(0.1, function()
                pollPending = false
                HideAllMinimapButtons()
            end)
        end)
    end
    addonButtonPoll:Show()

    -- Close the flyout if it was open (layout may have changed)
    HideFlyoutPanel()

    -- Hide Blizzard zone text (we use our own location bar)
    local zoneBtn = MinimapZoneTextButton
    if zoneBtn then zoneBtn:Hide() end
    if MinimapCluster and MinimapCluster.ZoneTextButton then
        MinimapCluster.ZoneTextButton:Hide()
    end
    if MinimapZoneText then MinimapZoneText:Hide() end

    -- Refresh cached clock CVars when settings are applied
    RefreshClockCVars()

    -- Clock -- top center, text vertically centered on the top edge
    if p.showClock then
        if not clockBg then
            clockBg = CreateFrame("Button", nil, minimap, "BackdropTemplate")
            clockBg:SetSize(80, 16)
            clockBg:SetPoint("TOP", minimap, "TOP", 0, 7)
            clockBg:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground" })
            clockBg:SetFrameLevel(minimap:GetFrameLevel() + 5)
            clockBg:RegisterForClicks("AnyUp")
            clockBg:SetScript("OnClick", function()
                if ToggleTimeManager then ToggleTimeManager() end
            end)
        end
        if not clockFrame then
            clockFrame = clockBg:CreateFontString(nil, "OVERLAY")
            ApplyMinimapFont(clockFrame, 10)
            clockFrame:SetPoint("CENTER", clockBg, "CENTER", 0, 0)
            clockFrame:SetTextColor(1, 1, 1, 0.9)
        end
        do
            local ar, ag, ab = GetBorderColor(p)
            clockBg:SetBackdropColor(ar, ag, ab, 1)
        end
        local clockYOff = isCircle and -3 or 7
        clockBg:ClearAllPoints()
        clockBg:SetPoint("TOP", minimap, "TOP", 0, clockYOff)
        clockBg:Show()
        clockFrame:Show()
        if not clockTicker then
            clockTicker = CreateFrame("Frame")
            local elapsed = 0
            clockTicker:SetScript("OnUpdate", function(_, dt)
                elapsed = elapsed + dt
                if elapsed < 1 then return end
                elapsed = 0
                UpdateClock()
            end)
            clockTicker:RegisterEvent("CVAR_UPDATE")
            clockTicker:SetScript("OnEvent", function(_, _, cvarName)
                if cvarName == "timeMgrUseMilitaryTime" or cvarName == "timeMgrUseLocalTime" then
                    RefreshClockCVars()
                    UpdateClock()
                end
            end)
        end
        clockTicker:Show()
        UpdateClock()
    else
        if clockBg then clockBg:Hide() end
        if clockFrame then clockFrame:Hide() end
        if clockTicker then clockTicker:Hide() end
    end

    -- Indicator frames (tracking, calendar, mail, crafting)
    LayoutIndicatorFrames(minimap, p, isCircle)

    -- Location bar -- bottom center, shows subzone/zone name
    if not p.hideZoneText then
        if not locationBg then
            locationBg = CreateFrame("Frame", nil, minimap, "BackdropTemplate")
            locationBg:SetSize(120, 18)
            locationBg:SetPoint("BOTTOM", minimap, "BOTTOM", 0, -7)
            locationBg:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground" })
            locationBg:SetFrameLevel(minimap:GetFrameLevel() + 5)
            locationBg:RegisterEvent("ZONE_CHANGED")
            locationBg:RegisterEvent("ZONE_CHANGED_INDOORS")
            locationBg:RegisterEvent("ZONE_CHANGED_NEW_AREA")
            locationBg:RegisterEvent("PLAYER_REGEN_ENABLED")
            locationBg:SetScript("OnEvent", function() UpdateLocation() end)
        end
        if not locationFrame then
            locationFrame = locationBg:CreateFontString(nil, "OVERLAY")
            ApplyMinimapFont(locationFrame, 10)
            locationFrame:SetPoint("CENTER", locationBg, "CENTER", 0, 0)
            locationFrame:SetTextColor(1, 1, 1, 0.9)
        end
        do
            local ar, ag, ab = GetBorderColor(p)
            locationBg:SetBackdropColor(ar, ag, ab, 1)
        end
        local locYOff = isCircle and 3 or -7
        locationBg:ClearAllPoints()
        locationBg:SetPoint("BOTTOM", minimap, "BOTTOM", 0, locYOff)
        locationBg:Show()
        locationFrame:Show()
        UpdateLocation()
    else
        if locationBg then locationBg:Hide() end
        if locationFrame then locationFrame:Hide() end
    end

    -- Coordinates -- top-right, always visible on hover
    if not coordFrame then
        coordFrame = minimap:CreateFontString(nil, "OVERLAY")
        ApplyMinimapFont(coordFrame, 11)
        coordFrame:SetPoint("TOPRIGHT", minimap, "TOPRIGHT", -4, -4)
        coordFrame:SetTextColor(1, 1, 1, 0.9)
    end
    coordFrame:Hide()  -- hidden by default, shown on hover
    if not coordTicker then
        coordTicker = CreateFrame("Frame")
        local elapsed = 0
        coordTicker:SetScript("OnUpdate", function(_, dt)
            elapsed = elapsed + dt
            if elapsed < 0.5 then return end
            elapsed = 0
            UpdateCoords()
        end)
    end
    coordTicker:Show()
    UpdateCoords()
    if not minimap._ebsCoordsHooked then
        minimap:HookScript("OnEnter", function(self)
            if not self._ebsActive then return end
            if coordFrame then coordFrame:Show() end
        end)
        minimap:HookScript("OnLeave", function(self)
            if not self._ebsActive then return end
            if coordFrame and not self:IsMouseOver() then coordFrame:Hide() end
        end)
        minimap._ebsCoordsHooked = true
    end

    -- Mousewheel zoom
    if p.scrollZoom then
        minimap:EnableMouseWheel(true)
        if not minimap._ebsZoomHooked then
            minimap._ebsZoomHooked = true
            minimap:HookScript("OnMouseWheel", function(self, delta)
                local mp = _G._EBS_AceDB and _G._EBS_AceDB.profile.minimap
                if not mp or not mp.scrollZoom then return end
                local zoom = self:GetZoom()
                if delta > 0 then
                    zoom = min(zoom + 1, 5)
                else
                    zoom = max(zoom - 1, 0)
                end
                self:SetZoom(zoom)
                ScheduleAutoZoom()
            end)
        end
    else
        minimap:EnableMouseWheel(false)
    end

    -- Cancel auto-zoom if disabled
    if not p.autoZoomOut then
        CancelAutoZoom()
    end

    -- Position: only set on first activation; after that, unlock mode owns positioning.
    if not minimap._ebsActive then
        minimap:ClearAllPoints()
        if p.position then
            minimap:SetPoint(p.position.point, UIParent, p.position.relPoint, p.position.x, p.position.y)
        else
            minimap:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -10, -10)
        end
    end

    -- Mark module as active so persistent hooks know they can fire
    minimap._ebsActive = true
end

-------------------------------------------------------------------------------
--  Friends List Skin
-------------------------------------------------------------------------------
local friendsSkinned = false

-- One-time structural setup (background, NineSlice hide, border creation)
local function SkinFriendsFrame()
    local frame = FriendsFrame
    if not frame or friendsSkinned then return end
    friendsSkinned = true

    -- Dark background
    if not frame._ebsBg then
        frame._ebsBg = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
        frame._ebsBg:SetColorTexture(0, 0, 0)
        frame._ebsBg:SetPoint("TOPLEFT", 0, 0)
        frame._ebsBg:SetPoint("BOTTOMRIGHT", 0, 0)
    end

    -- Hide NineSlice
    if frame.NineSlice then
        frame.NineSlice:Hide()
    end

    -- Create border + tab borders (colors applied by ApplyFriends)
    local p = EBS.db.profile.friends
    local r, g, b, a = GetBorderColor(p)
    PP.CreateBorder(frame, r, g, b, a, 1, "OVERLAY", 7)
    for i = 1, 4 do
        local tab = _G["FriendsFrameTab" .. i]
        if tab then
            PP.CreateBorder(tab, r, g, b, a, 1, "OVERLAY", 7)
        end
    end
end

-- Live updates: colors, opacity — safe to call repeatedly
local function ApplyFriends()
    if InCombatLockdown() then QueueApplyAll(); return end
    if TEMP_DISABLED.friends then return end

    local p = EBS.db.profile.friends

    if not p.enabled then
        if FriendsFrame and friendsSkinned then
            if FriendsFrame._ebsBg then FriendsFrame._ebsBg:SetAlpha(0) end
            if FriendsFrame._ppBorders then PP.SetBorderColor(FriendsFrame, 0, 0, 0, 0) end
            if FriendsFrame.NineSlice then FriendsFrame.NineSlice:Show() end
            for i = 1, 4 do
                local tab = _G["FriendsFrameTab" .. i]
                if tab and tab._ppBorders then PP.SetBorderColor(tab, 0, 0, 0, 0) end
            end
        end
        return
    end

    -- FriendsFrame is load-on-demand — ensure structural setup first
    if not FriendsFrame then return end
    SkinFriendsFrame()

    -- Re-show our elements in case they were hidden by disable
    if FriendsFrame.NineSlice then FriendsFrame.NineSlice:Hide() end

    local r, g, b, a = GetBorderColor(p)
    PP.SetBorderColor(FriendsFrame, r, g, b, a)
    if FriendsFrame._ebsBg then
        FriendsFrame._ebsBg:SetAlpha(p.bgAlpha)
    end
    for i = 1, 4 do
        local tab = _G["FriendsFrameTab" .. i]
        if tab and tab._ppBorders then
            PP.SetBorderColor(tab, r, g, b, a)
        end
    end
end

-------------------------------------------------------------------------------
--  Visibility
-------------------------------------------------------------------------------
local _ebsInCombat = false

-- Returns true = show, false = hide, "mouseover" = mouseover mode
local function EvalVisibility(cfg)
    if not cfg or not cfg.enabled then return false end
    if EllesmereUI.CheckVisibilityOptions and EllesmereUI.CheckVisibilityOptions(cfg) then
        return false
    end
    local mode = cfg.visibility or "always"
    if mode == "mouseover" then return "mouseover" end
    if mode == "always" then return true end
    if mode == "never" then return false end
    if mode == "in_combat" then return _ebsInCombat end
    if mode == "out_of_combat" then return not _ebsInCombat end
    local inGroup = IsInGroup()
    local inRaid  = IsInRaid()
    if mode == "in_raid"  then return inRaid end
    if mode == "in_party" then return inGroup and not inRaid end
    if mode == "solo"     then return not inGroup end
    return true
end

-- Mouseover poll: single lightweight frame, only runs when needed
-- Cached state avoids redundant SetAlpha calls; only fires API on change
local mouseoverTargets = {}  -- { { frame=, visible= }, ... }
local mouseoverPoll = CreateFrame("Frame")
mouseoverPoll:Hide()
local moElapsed = 0
mouseoverPoll:SetScript("OnUpdate", function(_, dt)
    moElapsed = moElapsed + dt
    if moElapsed < 0.15 then return end
    moElapsed = 0
    for i = 1, #mouseoverTargets do
        local t = mouseoverTargets[i]
        local frame = t.frame
        if frame and frame:IsShown() then
            local over = frame:IsMouseOver()
            if over and not t.visible then
                t.visible = true
                frame:SetAlpha(1)
            elseif not over and t.visible then
                t.visible = false
                frame:SetAlpha(0)
            end
        end
    end
end)

-- Pre-allocated tables for mouseoverTargets (avoids creating new tables every call)
local _moCache = {}
local function _moEntry(f)
    if not _moCache[f] then _moCache[f] = { frame = f } end
    return _moCache[f]
end

local function RebuildMouseoverTargets()
    wipe(mouseoverTargets)
    if not EBS.db then return end
    local prof = EBS.db.profile
    -- Chat: use first skinned chat frame as hover anchor, apply alpha to all
    if not TEMP_DISABLED.chat and prof.chat and prof.chat.enabled and prof.chat.visibility == "mouseover" then
        for chatFrame in pairs(skinnedChatFrames) do
            mouseoverTargets[#mouseoverTargets + 1] = _moEntry(chatFrame)
        end
    end
    -- Minimap
    if prof.minimap and prof.minimap.enabled and prof.minimap.visibility == "mouseover" then
        if Minimap then
            mouseoverTargets[#mouseoverTargets + 1] = _moEntry(Minimap)
        end
    end
    -- Friends
    if not TEMP_DISABLED.friends and prof.friends and prof.friends.enabled and prof.friends.visibility == "mouseover" then
        if FriendsFrame then
            mouseoverTargets[#mouseoverTargets + 1] = _moEntry(FriendsFrame)
        end
    end
    if #mouseoverTargets > 0 then
        mouseoverPoll:Show()
    else
        mouseoverPoll:Hide()
    end
end

local function UpdateChatVisibility()
    if TEMP_DISABLED.chat then return end
    local p = EBS.db and EBS.db.profile and EBS.db.profile.chat
    if not p or not p.enabled then return end
    local vis = EvalVisibility(p)
    if vis == "mouseover" then
        -- Start hidden; poll will handle show on hover
        for chatFrame in pairs(skinnedChatFrames) do
            chatFrame:SetAlpha(0)
        end
    else
        for chatFrame in pairs(skinnedChatFrames) do
            chatFrame:SetAlpha(vis and 1 or 0)
        end
    end
end

local function UpdateMinimapVisibility()
    local p = EBS.db and EBS.db.profile and EBS.db.profile.minimap
    if not p or not p.enabled then return end
    local vis = EvalVisibility(p)
    local minimap = Minimap
    if not minimap then return end
    if vis == "mouseover" then
        minimap:SetAlpha(0)
        minimap:Show()
    elseif vis then
        minimap:SetAlpha(1)
        minimap:Show()
    else
        minimap:Hide()
    end
end

local function UpdateFriendsVisibility()
    if TEMP_DISABLED.friends then return end
    local p = EBS.db and EBS.db.profile and EBS.db.profile.friends
    if not p or not p.enabled then return end
    if not FriendsFrame or not FriendsFrame:IsShown() then return end
    local vis = EvalVisibility(p)
    if vis == "mouseover" then
        FriendsFrame:SetAlpha(0)
    else
        FriendsFrame:SetAlpha(vis and 1 or 0)
    end
end

-- Check if ANY module uses a non-"always" visibility mode that requires event updates
local function AnyVisibilityActive()
    if not EBS.db then return false end
    local prof = EBS.db.profile
    local function needs(cfg)
        if not cfg or not cfg.enabled then return false end
        local m = cfg.visibility or "always"
        return m ~= "always"
    end
    if not TEMP_DISABLED.chat and needs(prof.chat) then return true end
    if needs(prof.minimap) then return true end
    if not TEMP_DISABLED.friends and needs(prof.friends) then return true end
    if needs(prof.questTracker) then return true end
    if needs(prof.cursor) then return true end
    return false
end

-- These high-frequency events are only needed when a module uses conditional visibility
local visFrame = CreateFrame("Frame")
-- Always track combat state (cheap: only fires on enter/leave combat)
visFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
visFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

local VIS_EVENTS = {
    "PLAYER_TARGET_CHANGED",
    "PLAYER_MOUNT_DISPLAY_CHANGED",
    "ZONE_CHANGED_NEW_AREA",
    "GROUP_ROSTER_UPDATE",
    "UPDATE_SHAPESHIFT_FORM",
}
local visEventsRegistered = false

local function UpdateVisEventRegistration()
    local need = AnyVisibilityActive()
    if need and not visEventsRegistered then
        for _, ev in ipairs(VIS_EVENTS) do visFrame:RegisterEvent(ev) end
        visEventsRegistered = true
    elseif not need and visEventsRegistered then
        for _, ev in ipairs(VIS_EVENTS) do visFrame:UnregisterEvent(ev) end
        visEventsRegistered = false
    end
end
_G._EBS_UpdateVisEventRegistration = UpdateVisEventRegistration

local function UpdateAllVisibility()
    if not EBS.db then return end
    UpdateChatVisibility()
    UpdateMinimapVisibility()
    UpdateFriendsVisibility()
    if _G._EBS_UpdateQTVisibility then _G._EBS_UpdateQTVisibility() end
    if _G._ECL_UpdateVisibility then _G._ECL_UpdateVisibility() end
    RebuildMouseoverTargets()
    UpdateVisEventRegistration()
end

-- Expose globals for options/quest tracker/cursor
_G._EBS_InCombat = function() return _ebsInCombat end
_G._EBS_UpdateVisibility = UpdateAllVisibility
_G._EBS_EvalVisibility = EvalVisibility

-- Shared callback avoids creating a new closure on every event fire
local function DeferredUpdateAllVisibility()
    UpdateAllVisibility()
end

visFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        _ebsInCombat = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        _ebsInCombat = false
    end
    C_Timer.After(0, DeferredUpdateAllVisibility)
end)

-------------------------------------------------------------------------------
--  Apply All
-------------------------------------------------------------------------------
ApplyAll = function()
    ApplyChat()
    ApplyMinimap()
    ApplyFriends()
    C_Timer.After(0, DeferredUpdateAllVisibility)
    UpdateVisEventRegistration()
end

-------------------------------------------------------------------------------
--  Lifecycle
-------------------------------------------------------------------------------
function EBS:OnInitialize()
    EBS.db = EllesmereUI.Lite.NewDB("EllesmereUIBasicsDB", defaults)

    -- Migrate old hideButtons to individual keys
    local mp = EBS.db.profile.minimap
    if mp.hideButtons ~= nil then
        if mp.hideButtons == true then
            mp.hideZoomButtons    = true
            mp.hideTrackingButton = true
            mp.hideGameTime       = true
        else
            mp.hideZoomButtons    = false
            mp.hideTrackingButton = false
            mp.hideGameTime       = false
        end
        mp.hideButtons = nil
    end

    -- Migrate old "round" shape to "circle"
    if mp.shape == "round" then
        mp.shape = "circle"
    end

    -- Scale removed in favor of direct sizing via snapshot; clean up stale key
    mp.scale = nil

    -- Global bridge for options <-> main communication
    _G._EBS_AceDB        = EBS.db
    _G._EBS_ApplyAll     = ApplyAll
    _G._EBS_ApplyChat    = ApplyChat
    _G._EBS_ApplyMinimap = ApplyMinimap
    _G._EBS_ApplyFriends = ApplyFriends
end

function EBS:OnEnable()
    ApplyAll()

    -- Hook FriendsFrame for load-on-demand (only if friends module is enabled)
    if not TEMP_DISABLED.friends and EBS.db.profile.friends.enabled then
        if not FriendsFrame then
            local hookFrame = CreateFrame("Frame")
            hookFrame:RegisterEvent("ADDON_LOADED")
            hookFrame:SetScript("OnEvent", function(self, event, addon)
                if addon == "Blizzard_SocialUI" then
                    C_Timer.After(0.1, function()
                        if FriendsFrame and EBS.db.profile.friends.enabled then
                            SkinFriendsFrame()
                        end
                    end)
                    -- Hook FriendsFrame's own OnShow as fallback for future opens.
                    -- Do NOT hook the global ShowUIPanel — that taints every panel
                    -- open (World Map, etc.) causing ADDON_ACTION_BLOCKED.
                    if FriendsFrame then
                        FriendsFrame:HookScript("OnShow", function()
                            if not friendsSkinned and EBS.db.profile.friends.enabled then
                                C_Timer.After(0, SkinFriendsFrame)
                            end
                        end)
                    end
                end
            end)
        else
            SkinFriendsFrame()
        end
    end

    -- Register minimap with unlock mode
    if EllesmereUI and EllesmereUI.RegisterUnlockElements then
        local MK = EllesmereUI.MakeUnlockElement
        local function MDB() return EBS.db and EBS.db.profile.minimap end
        local function CDB() return EBS.db and EBS.db.profile.chat end
        EllesmereUI:RegisterUnlockElements({
            MK({
                key   = "EBS_Minimap",
                label = "Minimap",
                group = "Basics",
                order = 500,
                noResize = true,
                noAnchorTo = true,
                getFrame = function() return Minimap end,
                getSize  = function()
                    return Minimap:GetWidth(), Minimap:GetHeight()
                end,
                isHidden = function()
                    local m = MDB()
                    return not m or not m.enabled
                end,
                savePos = function(_, point, relPoint, x, y)
                    local m = MDB(); if not m then return end
                    m.position = { point = point, relPoint = relPoint, x = x, y = y }
                    if not EllesmereUI._unlockActive then
                        ApplyMinimap()
                    end
                end,
                loadPos = function()
                    local m = MDB()
                    if not m or not m.enabled then return nil end
                    return m.position
                end,
                clearPos = function()
                    local m = MDB(); if not m then return end
                    m.position = nil
                end,
                applyPos = function()
                    local m = MDB()
                    if not m or not m.enabled then return end
                    ApplyMinimap()
                end,
            }),
            MK({
                key   = "EBS_Chat",
                label = "Chat",
                group = "Basics",
                order = 510,
                getFrame = function() return ChatFrame1 end,
                getSize  = function()
                    return ChatFrame1:GetWidth(), ChatFrame1:GetHeight()
                end,
                isHidden = function()
                    local c = CDB()
                    return not c or not c.enabled
                end,
                savePos = function(_, point, relPoint, x, y)
                    local c = CDB(); if not c then return end
                    c.position = { point = point, relPoint = relPoint, x = x, y = y }
                    if not EllesmereUI._unlockActive then
                        ApplyChat()
                    end
                end,
                loadPos = function()
                    local c = CDB()
                    return c and c.position
                end,
                clearPos = function()
                    local c = CDB(); if not c then return end
                    c.position = nil
                end,
                applyPos = function()
                    ApplyChat()
                end,
            }),
        })
    end
end
