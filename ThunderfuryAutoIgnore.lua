-- ============================================================================
-- ThunderfuryAutoIgnore
-- Automatically ignores players who spam and removes them after a
-- configurable number of days.  The ignore list is account-wide: on login
-- every non-expired entry is re-applied to the current character's game
-- ignore list, so switching characters keeps the list in sync.
-- ============================================================================
-- ---------------------------------------------------------------------------
-- SavedVariables bootstrap (account-wide via TOC ## SavedVariables)
-- ---------------------------------------------------------------------------
ThunderfuryAutoIgnoreDB = ThunderfuryAutoIgnoreDB or {}
ThunderfuryAutoIgnoreDB.ignoredPlayers =
    ThunderfuryAutoIgnoreDB.ignoredPlayers or {}
ThunderfuryAutoIgnoreDB.settings = ThunderfuryAutoIgnoreDB.settings or {
    enabled = true,
    thunderfury = true,
    itemLink = true,
    ignoreDays = 1,
    customPhrases = {},
    useContains = true,
    minimapPos = 220,
    minimapHide = false
}
local debugMode = false

-- ---------------------------------------------------------------------------
-- Compatibility wrappers for the ignore API
-- Classic Anniversary exposes C_FriendList; older builds use globals.
-- Using the explicit Add/Del functions instead of the /ignore toggle
-- prevents accidental double-toggles.
-- ---------------------------------------------------------------------------
local function SafeAddIgnore(name)
    if C_FriendList and C_FriendList.AddIgnore then
        C_FriendList.AddIgnore(name)
    elseif AddIgnore then
        AddIgnore(name)
    end
end

local function SafeDelIgnore(name)
    if C_FriendList and C_FriendList.DelIgnore then
        C_FriendList.DelIgnore(name)
    elseif DelIgnore then
        DelIgnore(name)
    end
end

-- ---------------------------------------------------------------------------
-- Custom font for list rows
-- ---------------------------------------------------------------------------
local font = CreateFont("ThunderfuryAutoIgnoreFont")
font:CopyFontObject("GameFontNormalSmall")
font:SetFont("Fonts\\2002.TTF", 10, "")
font:SetTextColor(1, 1, 1)

-- ---------------------------------------------------------------------------
-- Main event frame
-- ---------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("VARIABLES_LOADED")

-- ---------------------------------------------------------------------------
-- Ignore-list popup frame
-- ---------------------------------------------------------------------------
local ignoreFrame = CreateFrame("Frame", "ThunderfuryAutoIgnoreFrame", UIParent,
                                "BackdropTemplate")
ignoreFrame:SetSize(300, 268)
ignoreFrame:SetPoint("CENTER")
ignoreFrame:SetMovable(true)
ignoreFrame:EnableMouse(true)
ignoreFrame:EnableKeyboard(true)
ignoreFrame:RegisterForDrag("LeftButton")
ignoreFrame:SetScript("OnDragStart", ignoreFrame.StartMoving)
ignoreFrame:SetScript("OnDragStop", ignoreFrame.StopMovingOrSizing)
ignoreFrame:SetScript("OnShow", function(self)
    SetOverrideBinding(self, false, "ESCAPE", nil)
end)
ignoreFrame:SetScript("OnHide", function(self) ClearOverrideBindings(self) end)
ignoreFrame:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" then
        self:SetPropagateKeyboardInput(false)
        self:Hide()
    else
        self:SetPropagateKeyboardInput(true)
    end
end)
ignoreFrame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = false,
    tileSize = 16,
    edgeSize = 16,
    insets = {left = 5, right = 5, top = 5, bottom = 5}
})
ignoreFrame:SetBackdropColor(0.1, 0.1, 0.1, 1)
ignoreFrame:SetBackdropBorderColor(1, 1, 1, 1)
ignoreFrame:Hide()

-- Close button
local closeButton =
    CreateFrame("Button", nil, ignoreFrame, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", -5, -5)

-- Title
local title = ignoreFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", 0, -15)
title:SetText("Thunderfury Auto Ignore List")

-- Scroll frame
local scrollFrame = CreateFrame("ScrollFrame", "ThunderfuryAutoIgnoreScroll",
                                ignoreFrame,
                                "UIPanelScrollFrameTemplate,BackdropTemplate")
scrollFrame:SetPoint("TOPLEFT", 16, -60)
scrollFrame:SetPoint("BOTTOMRIGHT", -16, 30)
scrollFrame:SetBackdrop({
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
    insets = {left = 0, right = 0, top = 0, bottom = 0}
})
scrollFrame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

local scrollBg = scrollFrame:CreateTexture(nil, "BACKGROUND")
scrollBg:SetPoint("TOPLEFT", 1, -1)
scrollBg:SetPoint("BOTTOMRIGHT", -17, 1)
scrollBg:SetTexture("Interface\\Buttons\\WHITE8X8")
scrollBg:SetVertexColor(0.2, 0.2, 0.2, 1)

-- Scrollbar styling
local scrollBar = _G["ThunderfuryAutoIgnoreScrollScrollBar"]
if scrollBar then
    scrollBar:ClearAllPoints()
    scrollBar:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", 2, -16)
    scrollBar:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMRIGHT", 2, 15)
    scrollBar:SetWidth(20)
    local scrollBarBg = scrollBar:CreateTexture(nil, "BACKGROUND")
    scrollBarBg:SetAllPoints(scrollBar)
    scrollBarBg:SetTexture(
        "Interface\\PaperDollInfoFrame\\UI-Character-ScrollBar")
    scrollBarBg:SetTexCoord(0, 0.5, 0, 1)
end

-- Content frame inside the scroll
local content = CreateFrame("Frame", nil, scrollFrame)
content:SetSize(252, 1)
scrollFrame:SetScrollChild(content)

-- ---------------------------------------------------------------------------
-- Chat events we care about
-- ---------------------------------------------------------------------------
local chatEvents = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_CHANNEL", "CHAT_MSG_PARTY",
    "CHAT_MSG_RAID", "CHAT_MSG_GUILD", "CHAT_MSG_WHISPER"
}

-- ---------------------------------------------------------------------------
-- Register / unregister chat events based on enabled setting
-- ---------------------------------------------------------------------------
local function RegisterEvents()
    if (ThunderfuryAutoIgnoreDB.settings or {}).enabled then
        for _, evt in ipairs(chatEvents) do f:RegisterEvent(evt) end
    else
        for _, evt in ipairs(chatEvents) do f:UnregisterEvent(evt) end
    end
end

-- ---------------------------------------------------------------------------
-- Shared spam detection  (built-in rules + user custom phrases)
-- ---------------------------------------------------------------------------
local function IsSpamMessage(msg)
    local settings = ThunderfuryAutoIgnoreDB.settings or {}
    if not settings.enabled then return false end
    local lowerMsg = string.lower(msg)

    -- Built-in rules
    if settings.thunderfury and msg ==
        "Thunderfury, Blessed Blade of the Windseeker" then return true end
    if settings.itemLink and msg:find("|Hitem:19019:") then return true end

    -- Custom phrases (one per entry)
    local phrases = settings.customPhrases or {}
    for _, phrase in ipairs(phrases) do
        if phrase ~= "" then
            local lowerPhrase = string.lower(phrase)
            if settings.useContains then
                -- substring / "contains" match
                if lowerMsg:find(lowerPhrase, 1, true) then
                    return true
                end
            else
                -- exact full-message match
                if lowerMsg == lowerPhrase then return true end
            end
        end
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Clean expired ignores  (safe iteration - collects removals first)
-- ---------------------------------------------------------------------------
local function CleanIgnoreList()
    local now = time()
    local settings = ThunderfuryAutoIgnoreDB.settings or {}
    local days = math.max(1, settings.ignoreDays or 7)
    local expire = days * 86400
    local toRemove = {}
    for name, data in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers or {}) do
        if not data.permanent and now - data.timestamp > expire then
            table.insert(toRemove, name)
        end
    end
    for _, name in ipairs(toRemove) do
        SafeDelIgnore(name)
        ThunderfuryAutoIgnoreDB.ignoredPlayers[name] = nil
        print("|cffff8c00TFA:|r Auto-unignored " .. name .. " (" .. days ..
                  " day expiry)")
    end
end

-- ---------------------------------------------------------------------------
-- Sync the account-wide DB to this character's game ignore list.
-- Called on every login / PLAYER_ENTERING_WORLD so that every alt gets
-- the same ignore list applied.  Also removes anyone from the game's
-- ignore list who is NOT in the addon DB (or whose entry expired).
-- ---------------------------------------------------------------------------
local function SyncIgnoreList()
    CleanIgnoreList()

    -- Build a lowercase lookup of names still in the addon DB
    local dbLookup = {}
    for name, _ in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers or {}) do
        dbLookup[string.lower(name)] = true
    end

    -- Walk the game's ignore list and remove anyone not in the DB
    local numIgnored = C_FriendList and C_FriendList.GetNumIgnores and
                           C_FriendList.GetNumIgnores() or
                           (GetNumIgnores and GetNumIgnores()) or 0
    local toUnignore = {}
    for i = 1, numIgnored do
        local ignoreName
        if C_FriendList and C_FriendList.GetIgnoreName then
            ignoreName = C_FriendList.GetIgnoreName(i)
        elseif GetIgnoreName then
            ignoreName = GetIgnoreName(i)
        end
        if ignoreName and ignoreName ~= "" then
            if not dbLookup[string.lower(ignoreName)] then
                table.insert(toUnignore, ignoreName)
            end
        end
    end
    for _, name in ipairs(toUnignore) do
        SafeDelIgnore(name)
        print("|cffff8c00TFA:|r Removed stale ignore: " .. name)
    end

    -- Re-apply every DB entry to this character's game list
    local count = 0
    for name, _ in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers or {}) do
        SafeAddIgnore(name)
        count = count + 1
    end
    if count > 0 then
        print("|cffff8c00TFA:|r Synced " .. count ..
                  " ignored player(s) to this character")
    end
end

-- ---------------------------------------------------------------------------
-- Frame pool for ignore-list rows (avoids creating new frames every refresh)
-- ---------------------------------------------------------------------------
local linePool = {}
local activeLines = {}

local function AcquireLine()
    local line = table.remove(linePool)
    if not line then
        line = CreateFrame("Button", nil, content)
        line:SetSize(230, 16)
        line:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight",
                                 "ADD")
        line.nameText = line:CreateFontString(nil, "OVERLAY",
                                              "ThunderfuryAutoIgnoreFont")
        line.nameText:SetPoint("LEFT", 0, 0)
        line.nameText:SetJustifyH("LEFT")
        line.dateText = line:CreateFontString(nil, "OVERLAY",
                                              "ThunderfuryAutoIgnoreFont")
        line.dateText:SetPoint("RIGHT", -10, 0)
        line.dateText:SetJustifyH("CENTER")
    end
    line:Show()
    table.insert(activeLines, line)
    return line
end

local function ReleaseAllLines()
    for _, line in ipairs(activeLines) do
        line:Hide()
        line:ClearAllPoints()
        table.insert(linePool, line)
    end
    wipe(activeLines)
end

-- ---------------------------------------------------------------------------
-- Refresh the ignore-list popup
-- ---------------------------------------------------------------------------
local function UpdateIgnoreList()
    CleanIgnoreList()
    ReleaseAllLines()
    local yOffset = 0

    local sorted = {}
    for name, data in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers or {}) do
        table.insert(sorted, {name = name, timestamp = data.timestamp})
    end
    table.sort(sorted, function(a, b) return a.timestamp < b.timestamp end)

    for _, entry in ipairs(sorted) do
        local name = entry.name
        local data = ThunderfuryAutoIgnoreDB.ignoredPlayers[name]
        local line = AcquireLine()
        line:SetPoint("TOPLEFT", 10, yOffset)
        line:SetScript("OnClick", function()
            StaticPopup_Show("THUNDERFURYAUTOIGNORE_CONFIRM", name, nil,
                             {name = name})
        end)
        local prefix = data.permanent and "|cffff4444[P]|r " or ""
        local displayName = name:match("^([^%-]+)") or name
        line.nameText:SetText(prefix .. displayName)
        local dateStr = date("%Y-%m-%d", data.timestamp)
        local suffix = data.permanent and " perm" or ""
        line.dateText:SetText("(" .. dateStr .. suffix .. ")")
        yOffset = yOffset - 20
    end
    content:SetHeight(math.max(1, -yOffset))
end

-- ---------------------------------------------------------------------------
-- Chat filter  (hides spam messages from the chat window)
-- ---------------------------------------------------------------------------
local function ChatFilter(self, event, msg, ...)
    local isSpam = IsSpamMessage(msg)
    if isSpam and debugMode then return false end
    return isSpam
end

-- ---------------------------------------------------------------------------
-- Main event handler
-- ---------------------------------------------------------------------------
f:SetScript("OnEvent", function(self, event, ...)
    if event == "VARIABLES_LOADED" then
        -- Ensure defaults for settings fields added after first install
        local s = ThunderfuryAutoIgnoreDB.settings
        if s == nil then
            ThunderfuryAutoIgnoreDB.settings = {
                enabled = true,
                thunderfury = true,
                itemLink = true,
                ignoreDays = 1,
                customPhrases = {},
                useContains = true
            }
            s = ThunderfuryAutoIgnoreDB.settings
        end
        if s.ignoreDays == nil then s.ignoreDays = 1 end
        if s.customPhrases == nil then s.customPhrases = {} end
        if s.useContains == nil then s.useContains = true end

        f:RegisterEvent("PLAYER_ENTERING_WORLD")
        f:UnregisterEvent("VARIABLES_LOADED")

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Re-apply every non-expired ignore to this character's game list
        SyncIgnoreList()
        RegisterEvents()

        -- Periodic cleanup every 5 minutes
        if C_Timer and C_Timer.NewTicker then
            C_Timer.NewTicker(300, CleanIgnoreList)
        end

        f:UnregisterEvent("PLAYER_ENTERING_WORLD")

    elseif (ThunderfuryAutoIgnoreDB.settings or {}).enabled then
        local msg, author = ...
        if IsSpamMessage(msg) then
            local playerName = author
            local guid = select(12, ...) or ""
            if guid and guid ~= "" then
                local _, _, _, _, _, guidName, guidRealm =
                    GetPlayerInfoByGUID(guid)
                if guidName and guidName ~= "" then
                    local fullGuidName =
                        guidRealm and guidRealm ~= "" and
                            (guidName .. "-" .. guidRealm) or guidName
                    if not string.find(playerName, "-") then
                        playerName = fullGuidName
                    end
                end
            end

            local lowerName = string.lower(playerName)
            local existingName
            for storedName, _ in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers) do
                if string.lower(storedName) == lowerName then
                    existingName = storedName
                    break
                end
            end

            if not existingName then
                SafeAddIgnore(playerName)
                ThunderfuryAutoIgnoreDB.ignoredPlayers[playerName] = {
                    timestamp = time()
                }
                print("|cffff8c00TFA:|r Ignored " .. playerName .. " for spam")
                if ignoreFrame:IsShown() then UpdateIgnoreList() end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Confirmation popup for manual un-ignore
-- ---------------------------------------------------------------------------
StaticPopupDialogs["THUNDERFURYAUTOIGNORE_CONFIRM"] = {
    text = "Manage ignore for %s",
    button1 = "Unignore",
    button2 = "Toggle Permanent",
    button3 = "Cancel",
    OnAccept = function(_, data)
        -- Button 1: Unignore
        SafeDelIgnore(data.name)
        ThunderfuryAutoIgnoreDB.ignoredPlayers[data.name] = nil
        UpdateIgnoreList()
        print("|cffff8c00TFA:|r Unignored " .. data.name)
    end,
    OnCancel = function(_, data)
        -- Button 2: Toggle Permanent
        local entry = ThunderfuryAutoIgnoreDB.ignoredPlayers[data.name]
        if entry then
            entry.permanent = not entry.permanent
            local state = entry.permanent and "permanent" or "temporary"
            print("|cffff8c00TFA:|r " .. data.name .. " is now " .. state)
            UpdateIgnoreList()
        end
    end,
    OnAlt = function()
        -- Button 3: Cancel — do nothing
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true
}

-- ---------------------------------------------------------------------------
-- Register chat message filters
-- ---------------------------------------------------------------------------
for _, evt in ipairs(chatEvents) do
    ChatFrame_AddMessageEventFilter(evt, ChatFilter)
end

-- ===========================================================================
-- OPTIONS PANEL
-- ===========================================================================
local optionsPanel = CreateFrame("Frame")
optionsPanel.name = "Thunderfury Auto Ignore"
local optionsCategory -- stored for Settings.OpenToCategory

if InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(optionsPanel)
else
    optionsCategory = Settings.RegisterCanvasLayoutCategory(optionsPanel,
                                                            optionsPanel.name,
                                                            optionsPanel.name)
    Settings.RegisterAddOnCategory(optionsCategory)
end

local titleIcon = optionsPanel:CreateTexture(nil, "ARTWORK")
titleIcon:SetTexture("Interface\\Icons\\INV_Sword_39")
titleIcon:SetSize(20, 20)
titleIcon:SetPoint("TOPLEFT", 16, -16)

local titleText = optionsPanel:CreateFontString(nil, "ARTWORK",
                                                "GameFontNormalLarge")
titleText:SetPoint("LEFT", titleIcon, "RIGHT", 6, 0)
titleText:SetText("Thunderfury Auto Ignore Options")

local subtitle = optionsPanel:CreateFontString(nil, "ARTWORK",
                                               "GameFontHighlight")
subtitle:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -8)
subtitle:SetText("Configure spam detection and auto-ignore behavior")

-- Enable overall ---------------------------------------------------------
local enableCheck = CreateFrame("CheckButton", nil, optionsPanel,
                                "InterfaceOptionsCheckButtonTemplate")
enableCheck:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", -2, -16)
enableCheck.label = enableCheck:CreateFontString(nil, "OVERLAY",
                                                 "GameFontNormal")
enableCheck.label:SetPoint("LEFT", enableCheck, "RIGHT", 5, 0)
enableCheck.label:SetText("Enable Auto-Ignore")
enableCheck:SetScript("OnClick", function(self)
    ThunderfuryAutoIgnoreDB.settings.enabled = self:GetChecked()
    RegisterEvents()
    print("|cffff8c00TFA:|r " ..
              (ThunderfuryAutoIgnoreDB.settings.enabled and "Enabled" or
                  "Disabled"))
end)

-- Ignore duration (dropdown 1-10 days) ------------------------------------
local daysLabel =
    optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
daysLabel:SetPoint("TOPLEFT", enableCheck, "BOTTOMLEFT", 4, -18)
daysLabel:SetText("Days before auto-unignore:")

local daysDropdown = CreateFrame("Frame", "TFADaysDropdown", optionsPanel,
                                 "UIDropDownMenuTemplate")
daysDropdown:SetPoint("LEFT", daysLabel, "RIGHT", -8, -2)
UIDropDownMenu_SetWidth(daysDropdown, 50)

local function DaysDropdown_Initialize(self, level)
    for i = 1, 10 do
        local info = UIDropDownMenu_CreateInfo()
        info.text = tostring(i)
        info.value = i
        info.func = function(btn)
            ThunderfuryAutoIgnoreDB.settings.ignoreDays = btn.value
            UIDropDownMenu_SetSelectedValue(daysDropdown, btn.value)
        end
        info.checked = (ThunderfuryAutoIgnoreDB.settings.ignoreDays == i)
        UIDropDownMenu_AddButton(info, level)
    end
end
UIDropDownMenu_Initialize(daysDropdown, DaysDropdown_Initialize)
UIDropDownMenu_SetSelectedValue(daysDropdown, ThunderfuryAutoIgnoreDB.settings
                                    .ignoreDays or 1)

-- Thunderfury exact text -------------------------------------------------
local tfCheck = CreateFrame("CheckButton", nil, optionsPanel,
                            "InterfaceOptionsCheckButtonTemplate")
tfCheck:SetPoint("TOPLEFT", daysLabel, "BOTTOMLEFT", -4, -12)
tfCheck.label = tfCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
tfCheck.label:SetPoint("LEFT", tfCheck, "RIGHT", 5, 0)
tfCheck.label:SetText(
    "Ignore 'Thunderfury, Blessed Blade of the Windseeker' spam")
tfCheck:SetScript("OnClick", function(self)
    ThunderfuryAutoIgnoreDB.settings.thunderfury = self:GetChecked()
end)

-- Thunderfury item link ---------------------------------------------------
local itemCheck = CreateFrame("CheckButton", nil, optionsPanel,
                              "InterfaceOptionsCheckButtonTemplate")
itemCheck:SetPoint("TOPLEFT", tfCheck, "BOTTOMLEFT", 0, -8)
itemCheck.label = itemCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
itemCheck.label:SetPoint("LEFT", itemCheck, "RIGHT", 5, 0)
itemCheck.label:SetText("Ignore Thunderfury item link spam")
itemCheck:SetScript("OnClick", function(self)
    ThunderfuryAutoIgnoreDB.settings.itemLink = self:GetChecked()
end)

-- Contains matching for custom phrases ------------------------------------
local containsCheck = CreateFrame("CheckButton", nil, optionsPanel,
                                  "InterfaceOptionsCheckButtonTemplate")
containsCheck:SetPoint("TOPLEFT", itemCheck, "BOTTOMLEFT", 0, -8)
containsCheck.label = containsCheck:CreateFontString(nil, "OVERLAY",
                                                     "GameFontNormal")
containsCheck.label:SetPoint("LEFT", containsCheck, "RIGHT", 5, 0)
containsCheck.label:SetText(
    "Custom phrases use 'contains' matching (uncheck for exact match)")
containsCheck:SetScript("OnClick", function(self)
    ThunderfuryAutoIgnoreDB.settings.useContains = self:GetChecked()
end)

-- ---------------------------------------------------------------------------
-- Custom phrases  (multiline editor)
-- ---------------------------------------------------------------------------
local phrasesLabel = optionsPanel:CreateFontString(nil, "OVERLAY",
                                                   "GameFontNormal")
phrasesLabel:SetPoint("TOPLEFT", containsCheck, "BOTTOMLEFT", 0, -20)
phrasesLabel:SetText("Custom blocked phrases (one per line, case-insensitive):")

local phrasesScrollFrame = CreateFrame("ScrollFrame", "TFAPhrasesScroll",
                                       optionsPanel,
                                       "UIPanelScrollFrameTemplate,BackdropTemplate")
phrasesScrollFrame:SetPoint("TOPLEFT", phrasesLabel, "BOTTOMLEFT", 0, -8)
phrasesScrollFrame:SetSize(350, 120)
phrasesScrollFrame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = false,
    tileSize = 16,
    edgeSize = 12,
    insets = {left = 4, right = 4, top = 4, bottom = 4}
})
phrasesScrollFrame:SetBackdropColor(0.05, 0.05, 0.05, 1)
phrasesScrollFrame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

-- The EditBox lives inside a plain container frame that is the scroll child.
-- This guarantees the EditBox gets proper layout and click-to-focus works.
local phrasesContent = CreateFrame("Frame", nil, phrasesScrollFrame)
phrasesContent:SetSize(326, 500)

local phrasesEditBox = CreateFrame("EditBox", "TFAPhrasesEditBox",
                                   phrasesContent)
phrasesEditBox:SetMultiLine(true)
phrasesEditBox:SetAutoFocus(false)
phrasesEditBox:SetFontObject("ChatFontNormal")
phrasesEditBox:SetAllPoints(phrasesContent)
phrasesEditBox:SetTextInsets(6, 6, 4, 4)
phrasesEditBox:EnableMouse(true)
phrasesEditBox:SetScript("OnMouseDown", function(self) self:SetFocus() end)
phrasesEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
phrasesEditBox:SetScript("OnCursorChanged", function(self, x, y, w, h)
    local sf = phrasesScrollFrame
    local vs = sf:GetVerticalScroll()
    local sfh = sf:GetHeight()
    local cursorY = -y
    if cursorY < vs then
        sf:SetVerticalScroll(cursorY)
    elseif cursorY + h > vs + sfh then
        sf:SetVerticalScroll(cursorY + h - sfh)
    end
end)
phrasesEditBox:SetScript("OnTextChanged", function(self)
    -- Grow the content frame to fit text so the scrollbar works
    local _, textH = self:GetFont()
    local numLines = self:GetNumLetters() > 0 and
                         select(2, self:GetText():gsub("\n", "\n")) + 2 or 2
    local newH = math.max(120, numLines * (textH + 2))
    phrasesContent:SetHeight(newH)
end)
phrasesScrollFrame:SetScrollChild(phrasesContent)

local phrasesSaveBtn = CreateFrame("Button", nil, optionsPanel,
                                   "UIPanelButtonTemplate")
phrasesSaveBtn:SetSize(120, 24)
phrasesSaveBtn:SetPoint("TOPLEFT", phrasesScrollFrame, "BOTTOMLEFT", 0, -6)
phrasesSaveBtn:SetText("Save Phrases")
phrasesSaveBtn:SetScript("OnClick", function()
    local text = phrasesEditBox:GetText() or ""
    local phrases = {}
    for line in text:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then table.insert(phrases, trimmed) end
    end
    ThunderfuryAutoIgnoreDB.settings.customPhrases = phrases
    print("|cffff8c00TFA:|r Saved " .. #phrases .. " custom phrase(s)")
end)

-- ---------------------------------------------------------------------------
-- Refresh every control when the panel is shown
-- ---------------------------------------------------------------------------
optionsPanel:SetScript("OnShow", function()
    local s = ThunderfuryAutoIgnoreDB.settings or {}
    enableCheck:SetChecked(s.enabled)
    tfCheck:SetChecked(s.thunderfury)
    itemCheck:SetChecked(s.itemLink)
    containsCheck:SetChecked(s.useContains)
    UIDropDownMenu_SetSelectedValue(daysDropdown, s.ignoreDays or 1)
    UIDropDownMenu_SetText(daysDropdown, tostring(s.ignoreDays or 1))
    -- Populate the phrases editor
    local phrases = s.customPhrases or {}
    phrasesEditBox:SetText(table.concat(phrases, "\n"))
end)

-- ===========================================================================
-- SLASH COMMAND  /tfa
-- ===========================================================================
SLASH_THUNDERFURYAUTOIGNORE1 = "/tfa"
SlashCmdList["THUNDERFURYAUTOIGNORE"] = function(cmd)
    cmd = (cmd or ""):lower()
    local command, arg = cmd:match("^(%S+)%s*(.*)$")
    command = command or cmd

    if command == "" then
        UpdateIgnoreList()
        ignoreFrame:Show()

    elseif command == "options" then
        if InterfaceOptionsFrame_OpenToCategory then
            -- Classic often needs two calls to actually navigate
            InterfaceOptionsFrame_OpenToCategory(optionsPanel)
            InterfaceOptionsFrame_OpenToCategory(optionsPanel)
        elseif Settings and Settings.OpenToCategory and optionsCategory then
            Settings.OpenToCategory(optionsCategory:GetID())
        end

    elseif command == "enable" then
        ThunderfuryAutoIgnoreDB.settings.enabled = true
        enableCheck:SetChecked(true)
        RegisterEvents()
        print("|cffff8c00TFA:|r Enabled")

    elseif command == "disable" then
        ThunderfuryAutoIgnoreDB.settings.enabled = false
        enableCheck:SetChecked(false)
        RegisterEvents()
        print("|cffff8c00TFA:|r Disabled")

    elseif command == "add" and arg ~= "" then
        local playerName = arg:gsub("^%l", string.upper)
        local lowerName = string.lower(playerName)
        local exists
        for n in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers) do
            if string.lower(n) == lowerName then
                exists = n
                break
            end
        end
        if not exists then
            SafeAddIgnore(playerName)
            ThunderfuryAutoIgnoreDB.ignoredPlayers[playerName] = {
                timestamp = time()
            }
            print("|cffff8c00TFA:|r Added " .. playerName)
            if ignoreFrame:IsShown() then UpdateIgnoreList() end
        else
            print("|cffff8c00TFA:|r " .. exists .. " already ignored")
        end

    elseif command == "sync" then
        SyncIgnoreList()

    elseif command == "help" then
        print("|cffff8c00TFA Help:|r")
        print("  /tfa          - show ignore list")
        print("  /tfa options  - open settings panel")
        print("  /tfa enable   - turn on auto-ignore")
        print("  /tfa disable  - turn off auto-ignore")
        print("  /tfa add Name - manually add a player")
        print("  /tfa sync     - re-sync DB to this character")
        print("  /tfa help     - this message")

    else
        print("|cffff8c00TFA:|r Unknown command. Type /tfa help")
    end
end

-- ===========================================================================
-- MINIMAP BUTTON (LibDBIcon / LibDataBroker)
-- Compatible with Leatrix Plus minimap button management.
-- ===========================================================================
local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")

local tfaLDB = LDB:NewDataObject("ThunderfuryAutoIgnore", {
    type = "launcher",
    text = "Thunderfury Auto Ignore",
    icon = "Interface\\Icons\\INV_Sword_39",
    OnClick = function(self, button)
        if button == "LeftButton" then
            if ignoreFrame:IsShown() then
                ignoreFrame:Hide()
            else
                UpdateIgnoreList()
                ignoreFrame:Show()
            end
        elseif button == "RightButton" then
            if InterfaceOptionsFrame_OpenToCategory then
                InterfaceOptionsFrame_OpenToCategory(optionsPanel)
                InterfaceOptionsFrame_OpenToCategory(optionsPanel)
            elseif Settings and Settings.OpenToCategory and optionsCategory then
                Settings.OpenToCategory(optionsCategory:GetID())
            end
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("Thunderfury Auto Ignore", 1, 0.55, 0)
        tooltip:AddLine("|cffffffffLeft-click:|r Toggle ignore list", 1, 1, 1)
        tooltip:AddLine("|cffffffffRight-click:|r Open options", 1, 1, 1)
        local count = 0
        for _ in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers or {}) do
            count = count + 1
        end
        tooltip:AddLine(" ")
        tooltip:AddLine(count .. " player(s) ignored", 0.7, 0.7, 0.7)
    end
})

-- Register the minimap icon (deferred until DB is loaded)
local mmInit = CreateFrame("Frame")
mmInit:RegisterEvent("PLAYER_ENTERING_WORLD")
mmInit:SetScript("OnEvent", function(self)
    if not ThunderfuryAutoIgnoreDB.settings.minimap then
        ThunderfuryAutoIgnoreDB.settings.minimap = {
            hide = false,
            minimapPos = 220
        }
    end
    LDBIcon:Register("ThunderfuryAutoIgnore", tfaLDB,
                     ThunderfuryAutoIgnoreDB.settings.minimap)
    self:UnregisterAllEvents()
end)

-- ---------------------------------------------------------------------------
print("|cffff8c00TFA:|r loaded")
