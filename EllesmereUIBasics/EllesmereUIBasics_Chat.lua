-------------------------------------------------------------------------------
--  EllesmereUIBasics_Chat.lua
--  Message-level chat enhancements: class colors, URLs, channel shortening,
--  timestamps, copy dialog, and search.
-------------------------------------------------------------------------------
local ADDON_NAME = ...

local function GetChatDB()
    local db = _G._EBS_AceDB
    return db and db.profile and db.profile.chat
end

-------------------------------------------------------------------------------
--  Channel Shortening
-------------------------------------------------------------------------------
local CHANNEL_ABBREVS = {
    ["General"]         = "G",
    ["Trade"]           = "T",
    ["LocalDefense"]    = "LD",
    ["LookingForGroup"] = "LFG",
    ["WorldDefense"]    = "WD",
    ["Newcomer"]        = "N",
    ["Services"]        = "S",
}

local function ShortenChannelName(channelName, mode)
    if mode == "off" then return nil end
    -- Match "N. ChannelName" pattern (e.g., "2. Trade - City")
    local num, name = channelName:match("^(%d+)%.%s*(.+)")
    if not num then return nil end
    -- Strip region suffix: "Trade - City" → "Trade"
    local baseName = name:match("^(%S+)") or name
    local short = CHANNEL_ABBREVS[baseName]
    if short then
        if mode == "minimal" then
            return short
        else
            return num .. ". " .. short
        end
    end
    return nil
end

-- Filter: rewrite channel headers in chat messages
local CHANNEL_EVENTS = {
    "CHAT_MSG_CHANNEL",
}

local function ChannelFilter(self, event, msg, author, lang, channelName, ...)
    local p = GetChatDB()
    if not p or p.shortenChannels == "off" then return false end
    local short = ShortenChannelName(channelName, p.shortenChannels)
    if short then
        return false, msg, author, lang, short, ...
    end
    return false
end

for _, event in ipairs(CHANNEL_EVENTS) do
    ChatFrame_AddMessageEventFilter(event, ChannelFilter)
end

-------------------------------------------------------------------------------
--  Class-Colored Names
--  Hook GetColoredName() which is called by ChatFrame_MessageEventHandler
--  to produce the display name shown in chat. This runs AFTER message filters
--  but BEFORE the final AddMessage, so it's the correct place to inject
--  class color codes into the player name.
-------------------------------------------------------------------------------
local origGetColoredName

local function ClassColoredGetColoredName(event, ...)
    local p = GetChatDB()
    if not p or not p.classColorNames then
        return origGetColoredName(event, ...)
    end

    -- GetColoredName args: event, arg1(msg), arg2(author), ... arg12(guid)
    local guid = select(12, ...)
    if guid and guid ~= "" then
        local _, engClass = GetPlayerInfoByGUID(guid)
        if engClass then
            local cc = RAID_CLASS_COLORS[engClass]
            if cc then
                local name = origGetColoredName(event, ...)
                -- Strip any existing color codes from the name
                local plainName = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                return ("|cff%02x%02x%02x%s|r"):format(
                    math.floor(cc.r * 255 + 0.5),
                    math.floor(cc.g * 255 + 0.5),
                    math.floor(cc.b * 255 + 0.5),
                    plainName)
            end
        end
    end
    return origGetColoredName(event, ...)
end

-- Install hook once at load time
if GetColoredName then
    origGetColoredName = GetColoredName
    GetColoredName = ClassColoredGetColoredName
end

-------------------------------------------------------------------------------
--  Clickable URLs
-------------------------------------------------------------------------------
local URL_PATTERNS = {
    -- protocol://anything
    "(https?://[%w_.~!*'();:@&=+$,/?#%%%-]+)",
    -- www.domain.tld/path
    "(www%.[%w_%-]+%.%w+[%w_.~!*'();:@&=+$,/?#%%%-]*)",
}

local function LinkifyURLs(msg)
    for _, pat in ipairs(URL_PATTERNS) do
        msg = msg:gsub(pat, function(url)
            return "|Heuiurl:" .. url .. "|h|cff3399FF[" .. url .. "]|r|h"
        end)
    end
    return msg
end

local URL_EVENTS = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE",
    "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_BN_WHISPER", "CHAT_MSG_BN_WHISPER_INFORM",
    "CHAT_MSG_CHANNEL",
}

local function URLFilter(self, event, msg, ...)
    local p = GetChatDB()
    if not p or not p.clickableURLs then return false end
    if msg:find("|Heuiurl:") then return false end
    local linked = LinkifyURLs(msg)
    if linked ~= msg then
        return false, linked, ...
    end
    return false
end

for _, event in ipairs(URL_EVENTS) do
    ChatFrame_AddMessageEventFilter(event, URLFilter)
end

-- Hook SetItemRef via hooksecurefunc to handle euiurl clicks → copy dialog
-- hooksecurefunc is a post-hook: the original runs first. For unknown link
-- types like "euiurl:", the original is a no-op, so our post-hook can safely
-- open the popup without taint concerns.
local function ShowURLPopup(url)
    local popup = _G["EBS_URLCopyDialog"]
    if not popup then
        popup = CreateFrame("Frame", "EBS_URLCopyDialog", UIParent, "BackdropTemplate")
        popup:SetSize(450, 80)
        popup:SetPoint("CENTER")
        popup:SetFrameStrata("DIALOG")
        popup:SetBackdrop({
            bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        popup:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
        popup:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

        local title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        title:SetPoint("TOPLEFT", 12, -8)
        title:SetText("Copy URL (Ctrl+C)")
        title:SetTextColor(0.7, 0.7, 0.7)

        local eb = CreateFrame("EditBox", nil, popup, "InputBoxTemplate")
        eb:SetSize(420, 20)
        eb:SetPoint("BOTTOM", 0, 16)
        eb:SetAutoFocus(true)
        eb:SetScript("OnEscapePressed", function() popup:Hide() end)
        eb:SetScript("OnEnterPressed", function() popup:Hide() end)
        popup._editBox = eb

        popup:SetScript("OnShow", function(self)
            self._editBox:SetText(self._url or "")
            self._editBox:HighlightText()
            self._editBox:SetFocus()
        end)
        popup:EnableMouse(true)
        popup:SetMovable(true)
        popup:RegisterForDrag("LeftButton")
        popup:SetScript("OnDragStart", popup.StartMoving)
        popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
        tinsert(UISpecialFrames, "EBS_URLCopyDialog")
    end
    popup._url = url
    popup:Show()
end

hooksecurefunc("SetItemRef", function(link)
    local url = link:match("^euiurl:(.+)")
    if url then
        ShowURLPopup(url)
    end
end)

-------------------------------------------------------------------------------
--  Timestamps
-------------------------------------------------------------------------------
local TIMESTAMP_FORMATS = {
    ["none"]         = "none",
    ["HH:MM"]        = "[%H:%M] ",
    ["HH:MM:SS"]     = "[%H:%M:%S] ",
    ["HH:MM AP"]     = "[%I:%M %p] ",
    ["HH:MM:SS AP"]  = "[%I:%M:%S %p] ",
}

local function ApplyTimestamps()
    local p = GetChatDB()
    if not p then return end
    local fmt = p.timestamps or "none"
    local cvarFmt = TIMESTAMP_FORMATS[fmt] or "none"
    SetCVar("showTimestamps", cvarFmt)
end

_G._EBS_ApplyTimestamps = ApplyTimestamps

local tsFrame = CreateFrame("Frame")
tsFrame:RegisterEvent("PLAYER_LOGIN")
tsFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    C_Timer.After(0.5, ApplyTimestamps)
end)

-------------------------------------------------------------------------------
--  Copy Chat
-------------------------------------------------------------------------------
local function StripHyperlinks(text)
    -- Remove texture escapes
    text = text:gsub("|T.-|t", "")
    -- Remove atlas escapes
    text = text:gsub("|A.-|a", "")
    -- Convert hyperlinks to plain text: |Htype:data|h[text]|h → text
    text = text:gsub("|H.-|h%[?(.-)]?|h", "%1")
    -- Remove color codes
    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|r", "")
    -- Remove any remaining escape sequences
    text = text:gsub("|n", "\n")
    return text
end

local function GetChatMessages(chatFrame, numLines)
    local messages = {}
    local total = chatFrame:GetNumMessages()
    local start = math.max(1, total - numLines + 1)
    for i = start, total do
        local msg = chatFrame:GetMessageInfo(i)
        if msg then
            messages[#messages + 1] = StripHyperlinks(msg)
        end
    end
    return table.concat(messages, "\n")
end

local copyFrame

local function ShowCopyDialog(chatFrame)
    local p = GetChatDB()
    local numLines = (p and p.copyLines) or 200

    if not copyFrame then
        copyFrame = CreateFrame("Frame", "EBS_CopyChatDialog", UIParent, "BackdropTemplate")
        copyFrame:SetSize(600, 400)
        copyFrame:SetPoint("CENTER")
        copyFrame:SetFrameStrata("DIALOG")
        copyFrame:SetBackdrop({
            bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        copyFrame:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
        copyFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        copyFrame:EnableMouse(true)
        copyFrame:SetMovable(true)
        copyFrame:RegisterForDrag("LeftButton")
        copyFrame:SetScript("OnDragStart", copyFrame.StartMoving)
        copyFrame:SetScript("OnDragStop", copyFrame.StopMovingOrSizing)
        tinsert(UISpecialFrames, "EBS_CopyChatDialog")

        -- Title
        local title = copyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", 12, -12)
        title:SetText("Copy Chat")
        title:SetTextColor(0.8, 0.8, 0.8)

        -- Close button
        local close = CreateFrame("Button", nil, copyFrame, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -2, -2)

        -- Scroll frame
        local scroll = CreateFrame("ScrollFrame", "EBS_CopyChatScroll", copyFrame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -36)
        scroll:SetPoint("BOTTOMRIGHT", -30, 12)

        local editBox = CreateFrame("EditBox", nil, scroll)
        editBox:SetMultiLine(true)
        editBox:SetFontObject("ChatFontNormal")
        editBox:SetWidth(540)
        editBox:SetAutoFocus(false)
        editBox:SetScript("OnEscapePressed", function() copyFrame:Hide() end)
        scroll:SetScrollChild(editBox)
        copyFrame._editBox = editBox
    end

    local text = GetChatMessages(chatFrame or ChatFrame1, numLines)
    copyFrame._editBox:SetText(text)
    copyFrame:Show()
    copyFrame._editBox:HighlightText()
    copyFrame._editBox:SetFocus()
end

_G._EBS_ShowCopyDialog = ShowCopyDialog

-- Slash command
SLASH_EUICOPY1 = "/copy"
SlashCmdList["EUICOPY"] = function()
    local chatFrame = SELECTED_CHAT_FRAME or ChatFrame1
    ShowCopyDialog(chatFrame)
end

-------------------------------------------------------------------------------
--  Copy Button (optional, shown on chat frame toolbar)
-------------------------------------------------------------------------------
local copyButtons = {}

local function CreateCopyButton(chatFrame)
    if copyButtons[chatFrame] then return copyButtons[chatFrame] end
    local btn = CreateFrame("Button", nil, chatFrame)
    btn:SetSize(20, 20)
    btn:SetPoint("TOPRIGHT", chatFrame, "TOPRIGHT", -2, -2)
    btn:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")
    btn:SetHighlightTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")
    btn:GetHighlightTexture():SetAlpha(0.3)
    btn:SetScript("OnClick", function()
        ShowCopyDialog(chatFrame)
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Copy Chat", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", GameTooltip_Hide)
    copyButtons[chatFrame] = btn
    return btn
end

-- Called from ApplyChat or options refresh
function _G._EBS_UpdateCopyButtons()
    local p = GetChatDB()
    if not p or not p.enabled then return end
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local cf = _G["ChatFrame" .. i]
        if cf then
            if p.copyButton then
                local btn = CreateCopyButton(cf)
                btn:Show()
            elseif copyButtons[cf] then
                copyButtons[cf]:Hide()
            end
        end
    end
end

-------------------------------------------------------------------------------
--  Chat Search
-------------------------------------------------------------------------------
local searchFrame

local function CreateSearchFrame()
    if searchFrame then return searchFrame end

    searchFrame = CreateFrame("Frame", "EBS_ChatSearchDialog", UIParent, "BackdropTemplate")
    searchFrame:SetSize(600, 400)
    searchFrame:SetPoint("CENTER")
    searchFrame:SetFrameStrata("DIALOG")
    searchFrame:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    searchFrame:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    searchFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    searchFrame:EnableMouse(true)
    searchFrame:SetMovable(true)
    searchFrame:RegisterForDrag("LeftButton")
    searchFrame:SetScript("OnDragStart", searchFrame.StartMoving)
    searchFrame:SetScript("OnDragStop", searchFrame.StopMovingOrSizing)
    tinsert(UISpecialFrames, "EBS_ChatSearchDialog")

    -- Title
    local title = searchFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText("Search Chat")
    title:SetTextColor(0.8, 0.8, 0.8)

    -- Close button
    local close = CreateFrame("Button", nil, searchFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    -- Search input
    local input = CreateFrame("EditBox", nil, searchFrame, "InputBoxTemplate")
    input:SetSize(520, 20)
    input:SetPoint("TOPLEFT", 14, -36)
    input:SetAutoFocus(true)
    searchFrame._input = input

    -- Search button
    local searchBtn = CreateFrame("Button", nil, searchFrame, "UIPanelButtonTemplate")
    searchBtn:SetSize(50, 22)
    searchBtn:SetPoint("LEFT", input, "RIGHT", 4, 0)
    searchBtn:SetText("Go")

    -- Results scroll
    local scroll = CreateFrame("ScrollFrame", "EBS_ChatSearchScroll", searchFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -64)
    scroll:SetPoint("BOTTOMRIGHT", -30, 12)

    local results = CreateFrame("EditBox", nil, scroll)
    results:SetMultiLine(true)
    results:SetFontObject("ChatFontNormal")
    results:SetWidth(540)
    results:SetAutoFocus(false)
    results:SetScript("OnEscapePressed", function() searchFrame:Hide() end)
    scroll:SetScrollChild(results)
    searchFrame._results = results

    local function DoSearch()
        local query = input:GetText()
        if not query or query == "" then return end
        local chatFrame = SELECTED_CHAT_FRAME or ChatFrame1
        local total = chatFrame:GetNumMessages()
        local matches = {}
        local lowerQuery = query:lower()
        for i = 1, total do
            local msg = chatFrame:GetMessageInfo(i)
            if msg then
                local plain = StripHyperlinks(msg)
                if plain:lower():find(lowerQuery, 1, true) then
                    matches[#matches + 1] = plain
                end
            end
        end
        if #matches == 0 then
            results:SetText("No results found for: " .. query)
        else
            results:SetText(table.concat(matches, "\n"))
        end
        results:SetCursorPosition(0)
    end

    searchBtn:SetScript("OnClick", DoSearch)
    input:SetScript("OnEnterPressed", DoSearch)
    input:SetScript("OnEscapePressed", function() searchFrame:Hide() end)

    return searchFrame
end

local function ShowSearchDialog()
    local frame = CreateSearchFrame()
    frame:Show()
    frame._input:SetText("")
    frame._results:SetText("")
    frame._input:SetFocus()
end

_G._EBS_ShowSearchDialog = ShowSearchDialog

-- Search button on chat frames
local searchButtons = {}

local function AnchorSearchButton(btn, chatFrame)
    btn:ClearAllPoints()
    local copyBtn = copyButtons[chatFrame]
    if copyBtn and copyBtn:IsShown() then
        btn:SetPoint("RIGHT", copyBtn, "LEFT", -2, 0)
    else
        btn:SetPoint("TOPRIGHT", chatFrame, "TOPRIGHT", -2, -2)
    end
end

local function CreateSearchButton(chatFrame)
    if searchButtons[chatFrame] then return searchButtons[chatFrame] end
    local btn = CreateFrame("Button", nil, chatFrame)
    btn:SetSize(20, 20)
    AnchorSearchButton(btn, chatFrame)
    btn:SetNormalTexture("Interface\\Common\\UI-Searchbox-Icon")
    btn:SetHighlightTexture("Interface\\Common\\UI-Searchbox-Icon")
    btn:GetHighlightTexture():SetAlpha(0.3)
    btn:SetScript("OnClick", ShowSearchDialog)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Search Chat", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", GameTooltip_Hide)
    searchButtons[chatFrame] = btn
    return btn
end

function _G._EBS_UpdateSearchButtons()
    local p = GetChatDB()
    if not p or not p.enabled then return end
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local cf = _G["ChatFrame" .. i]
        if cf then
            if p.showSearchButton then
                local btn = CreateSearchButton(cf)
                AnchorSearchButton(btn, cf)
                btn:Show()
            elseif searchButtons[cf] then
                searchButtons[cf]:Hide()
            end
        end
    end
end
