-- ============================================================================
-- ThunderfuryAutoIgnore
-- Automatically ignores players who spam and removes them after a
-- configurable number of hours.  The ignore list is account-wide: on login
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
    ignoreHours = 1,
    customPhrases = {},
    minimapPos = 220,
    minimapHide = false
}
local debugMode = false

-- ---------------------------------------------------------------------------
-- Locale-aware date/time formatting
-- US realms use 12-hour AM/PM; all others use 24-hour format.
-- ---------------------------------------------------------------------------
local function IsUSRegion()
    -- GetCurrentRegion(): 1=US, 2=KR, 3=EU, 4=TW, 5=CN
    if GetCurrentRegion then return GetCurrentRegion() == 1 end
    local portal = GetCVar and GetCVar("portal") or ""
    return portal == "US"
end

local function FormatDateTime(ts)
    if IsUSRegion() then
        local h = tonumber(date("%H", ts))
        local m = date("%M", ts)
        local ampm = h >= 12 and "PM" or "AM"
        h = h % 12
        if h == 0 then h = 12 end
        return date("%m/%d/%Y", ts) .. " (" .. h .. ":" .. m .. " " .. ampm ..
                   ")"
    else
        return date("%Y-%m-%d (%H:%M)", ts)
    end
end

-- ---------------------------------------------------------------------------
-- Compatibility wrappers for the ignore API
-- Classic Anniversary exposes C_FriendList; older builds use globals.
-- Using the explicit Add/Del functions instead of the /ignore toggle
-- prevents accidental double-toggles.
-- The game API on Classic uses name-only (no realm suffix), so we strip
-- the realm before calling through.
-- ---------------------------------------------------------------------------
local function StripRealm(name) return name:match("^([^%-]+)") or name end

local function ParseItemLink(text)
    -- Normalise escaped pipes (\124 → |) that Wowhead copy-paste uses
    local normalised = text:gsub("\\124", "|")

    -- Try to extract a full item link:  |cXXXXXXXX|Hitem:ID:...|h[Name]|h|r
    -- We capture the |Hitem:...|h[...]|h portion for storage.
    local fullLink = normalised:match("(|c%%x+|Hitem:%d+.-|h%[.-%]|h|r)")
    if not fullLink then
        fullLink = normalised:match("(|Hitem:%d+.-|h%[.-%]|h)")
    end

    -- Extract item ID from the link or from a Wowhead URL
    local itemId = normalised:match("|Hitem:(%d+):")
    if not itemId then itemId = text:match("wowhead%.com/.-item=(%d+)") end

    return itemId, fullLink
end

local function SafeAddIgnore(name)
    local nameOnly = StripRealm(name)
    if C_FriendList and C_FriendList.AddIgnore then
        C_FriendList.AddIgnore(nameOnly)
    elseif AddIgnore then
        AddIgnore(nameOnly)
    end
end

local function SafeDelIgnore(name)
    local nameOnly = StripRealm(name)
    if C_FriendList and C_FriendList.DelIgnore then
        C_FriendList.DelIgnore(nameOnly)
    elseif DelIgnore then
        DelIgnore(nameOnly)
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
ignoreFrame:SetClampedToScreen(true)
ignoreFrame:SetMovable(true)
ignoreFrame:EnableMouse(true)
ignoreFrame:RegisterForDrag("LeftButton")
ignoreFrame:SetScript("OnDragStart", ignoreFrame.StartMoving)
ignoreFrame:SetScript("OnDragStop", ignoreFrame.StopMovingOrSizing)

-- Allow ESC to close without stealing keyboard input from the game
tinsert(UISpecialFrames, "ThunderfuryAutoIgnoreFrame")
ignoreFrame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = false,
    tileSize = 16,
    edgeSize = 16,
    insets = {left = 4, right = 4, top = 4, bottom = 4}
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
title:SetText("Thunderfury Auto Ignore")

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

    -- Custom phrases (per-entry contains / item-link matching)
    local phrases = settings.customPhrases or {}
    for _, entry in ipairs(phrases) do
        if type(entry) == "table" then
            if entry.itemId then
                -- Match in-game item links by item ID
                if msg:find("|Hitem:" .. entry.itemId .. ":") then
                    return true
                end
            elseif entry.text and entry.text ~= "" then
                local lowerPhrase = string.lower(entry.text)
                if entry.contains then
                    if lowerMsg:find(lowerPhrase, 1, true) then
                        return true
                    end
                else
                    if lowerMsg == lowerPhrase then
                        return true
                    end
                end
            end
        elseif type(entry) == "string" and entry ~= "" then
            -- Legacy format fallback
            local lowerPhrase = string.lower(entry)
            if lowerMsg:find(lowerPhrase, 1, true) then return true end
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
    local hours = math.max(1, settings.ignoreHours or 1)
    local expire = hours * 3600
    local toRemove = {}
    for name, data in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers or {}) do
        if not data.permanent and now - data.timestamp > expire then
            table.insert(toRemove, name)
        end
    end
    for _, name in ipairs(toRemove) do
        local data = ThunderfuryAutoIgnoreDB.ignoredPlayers[name]
        local ignoredAt = data and FormatDateTime(data.timestamp) or "?"
        SafeDelIgnore(name)
        ThunderfuryAutoIgnoreDB.ignoredPlayers[name] = nil
        print("|cffff8c00TFA:|r Auto-unignored " .. name .. " (ignored " ..
                  ignoredAt .. ", " .. hours .. "hr expiry)")
    end
end

-- ---------------------------------------------------------------------------
-- Verify permanent ignores  (/tfa verify)
-- Stagger-checks each permanent ignore by temporarily removing and re-adding
-- it.  If the server responds with "player not found", the entry is flagged.
-- ---------------------------------------------------------------------------
local verifyState = nil -- nil when idle, table when running

local function VerifyNextIgnore()
    if not verifyState then return end
    local idx = verifyState.idx
    local names = verifyState.names

    if idx > #names then
        -- Finished
        local flagged = verifyState.flagged
        if #flagged > 0 then
            print("|cffff8c00TFA Verify:|r " .. #flagged ..
                      " permanent ignore(s) may no longer exist:")
            for _, n in ipairs(flagged) do
                print("  |cffff4444-|r " .. n)
            end
            print("|cffff8c00TFA:|r Use '/tfa remove Name' to remove them, " ..
                      "or they may just be offline/renamed.")
        else
            print("|cffff8c00TFA Verify:|r All " .. #names ..
                      " permanent ignore(s) appear valid.")
        end
        -- Unregister the system message listener
        verifyState.frame:UnregisterEvent("CHAT_MSG_SYSTEM")
        verifyState = nil
        return
    end

    local name = names[idx]
    verifyState.currentName = name
    verifyState.waitingForResponse = true

    -- Strip realm suffix — the game ignore API uses name-only on Classic
    local nameOnly = name:match("^([^%-]+)") or name

    -- The player is already on the ignore list.  Remove then re-add to
    -- trigger a server response we can inspect.
    SafeDelIgnore(nameOnly)

    -- Small delay before re-adding so the server processes the removal
    C_Timer.After(0.5, function()
        if not verifyState then return end
        SafeAddIgnore(nameOnly)
        -- Give the server time to respond; if no error after 2s, assume valid
        C_Timer.After(2, function()
            if not verifyState then return end
            if verifyState.waitingForResponse then
                -- No error received — player exists
                verifyState.waitingForResponse = false
                verifyState.idx = verifyState.idx + 1
                print("|cffff8c00TFA Verify:|r " .. name .. " — OK (" ..
                          verifyState.idx - 1 .. "/" .. #names .. ")")
                VerifyNextIgnore()
            end
        end)
    end)
end

local function StartVerify()
    if verifyState then
        print("|cffff8c00TFA:|r Verify already in progress.")
        return
    end

    local names = {}
    for name, data in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers or {}) do
        if data.permanent then table.insert(names, name) end
    end

    if #names == 0 then
        print("|cffff8c00TFA:|r No permanent ignores to verify.")
        return
    end

    print("|cffff8c00TFA Verify:|r Checking " .. #names ..
              " permanent ignore(s)... this takes ~3s each.")

    -- Create a temporary frame to listen for system messages
    local listener = CreateFrame("Frame")
    verifyState = {
        names = names,
        idx = 1,
        flagged = {},
        currentName = nil,
        waitingForResponse = false,
        frame = listener
    }

    -- Listen for "player not found" type responses
    listener:RegisterEvent("CHAT_MSG_SYSTEM")
    listener:SetScript("OnEvent", function(_, event, msg)
        if not verifyState or not verifyState.waitingForResponse then
            return
        end

        -- Match common error strings for non-existent players
        local lowerMsg = string.lower(msg)
        if lowerMsg:find("player not found") or lowerMsg:find("not found") or
            lowerMsg:find("doesn't exist") or lowerMsg:find("unknown player") then
            local name = verifyState.currentName
            table.insert(verifyState.flagged, name)
            print("|cffff8c00TFA Verify:|r " .. name ..
                      " — |cffff4444NOT FOUND|r (" .. verifyState.idx .. "/" ..
                      #verifyState.names .. ")")
            verifyState.waitingForResponse = false
            verifyState.idx = verifyState.idx + 1
            VerifyNextIgnore()
        elseif lowerMsg:find("now ignoring") or
            lowerMsg:find("is already being ignored") or
            lowerMsg:find("already on your ignore") then
            -- Player exists
            local name = verifyState.currentName
            verifyState.waitingForResponse = false
            verifyState.idx = verifyState.idx + 1
            print("|cffff8c00TFA Verify:|r " .. name .. " — OK (" ..
                      verifyState.idx - 1 .. "/" .. #verifyState.names .. ")")
            VerifyNextIgnore()
        end
    end)

    VerifyNextIgnore()
end

-- ---------------------------------------------------------------------------
-- Sync the account-wide DB to this character's game ignore list.
-- All operations are immediate (no staggering).  A ShowFriends() call
-- at the end nudges the client to refresh the social data.
-- ---------------------------------------------------------------------------
local function SyncIgnoreList(silent)
    -- 1.  Clean expired entries out of the addon DB
    CleanIgnoreList()

    -- 2.  Build a lowercase lookup of names already on the game ignore list
    --     The game may return names with or without a realm suffix, so we
    --     store both the full name and the name-only (before the hyphen).
    local gameIgnoreLookup = {}
    local numIgnored = C_FriendList and C_FriendList.GetNumIgnores and
                           C_FriendList.GetNumIgnores() or
                           (GetNumIgnores and GetNumIgnores()) or 0
    for i = 1, numIgnored do
        local ignoreName
        if C_FriendList and C_FriendList.GetIgnoreName then
            ignoreName = C_FriendList.GetIgnoreName(i)
        elseif GetIgnoreName then
            ignoreName = GetIgnoreName(i)
        end
        if ignoreName and ignoreName ~= "" then
            local lower = string.lower(ignoreName)
            gameIgnoreLookup[lower] = true
            -- Also store the name-only portion (strip realm)
            local nameOnly = lower:match("^([^%-]+)")
            if nameOnly then gameIgnoreLookup[nameOnly] = true end
        end
    end

    -- Helper: check if a DB name matches any game ignore entry.
    -- Compares both the full "Name-Realm" and just "Name".
    local function IsAlreadyIgnored(dbName)
        local lower = string.lower(dbName)
        if gameIgnoreLookup[lower] then return true end
        local nameOnly = lower:match("^([^%-]+)")
        if nameOnly and gameIgnoreLookup[nameOnly] then return true end
        return false
    end

    -- 3.  Add only DB entries that are missing from the game ignore list
    local added = 0
    for name, _ in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers or {}) do
        if not IsAlreadyIgnored(name) then
            SafeAddIgnore(name)
            added = added + 1
        end
    end

    -- 4.  Poke the social system so the client refreshes its ignore list
    if C_FriendList and C_FriendList.ShowFriends then
        C_FriendList.ShowFriends()
    elseif ShowFriends then
        ShowFriends()
    end

    local total = 0
    for _ in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers or {}) do
        total = total + 1
    end
    if not silent then
        if added > 0 then
            print("|cffff8c00TFA:|r Added " .. added ..
                      " missing ignore(s) — " .. total .. " total tracked")
        elseif total > 0 then
            print("|cffff8c00TFA:|r Ignore list in sync — " .. total ..
                      " player(s) tracked")
        end
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
        line.dateText:SetText("(" .. dateStr .. ")")

        -- Tooltip with exact timestamp and expiry details
        line:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(name, 1, 0.8, 0)
            GameTooltip:AddLine(
                "Ignored on: " .. FormatDateTime(data.timestamp), 1, 1, 1)
            if data.permanent then
                GameTooltip:AddLine("Permanent – will not expire", 0.6, 0.6,
                                    0.6)
            else
                local settings = ThunderfuryAutoIgnoreDB.settings or {}
                local hours = math.max(1, settings.ignoreHours or 1)
                local expiresAt = data.timestamp + hours * 3600
                local remaining = expiresAt - time()
                GameTooltip:AddLine("Expires: " .. FormatDateTime(expiresAt), 1,
                                    1, 1)
                if remaining > 0 then
                    local hrs = math.floor(remaining / 3600)
                    local mins = math.floor((remaining % 3600) / 60)
                    GameTooltip:AddLine(
                        string.format("Remaining: %dh %dm", hrs, mins), 0.5, 1,
                        0.5)
                else
                    GameTooltip:AddLine("Expired – pending removal", 1, 0.3,
                                        0.3)
                end
            end
            GameTooltip:AddLine("Click to manage", 0.5, 0.5, 0.5)
            GameTooltip:Show()
        end)
        line:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
                ignoreHours = 1,
                customPhrases = {}
            }
            s = ThunderfuryAutoIgnoreDB.settings
        end
        -- Migrate old ignoreDays setting to ignoreHours
        if s.ignoreDays and not s.ignoreHours then
            s.ignoreHours = math.min(s.ignoreDays * 24, 24)
            s.ignoreDays = nil
        end
        if s.ignoreHours == nil then s.ignoreHours = 1 end
        if s.customPhrases == nil then s.customPhrases = {} end

        -- Migrate flat string custom phrases to per-phrase format
        if s.customPhrases and #s.customPhrases > 0 and type(s.customPhrases[1]) ==
            "string" then
            local newPhrases = {}
            for _, phrase in ipairs(s.customPhrases) do
                table.insert(newPhrases, {
                    text = phrase,
                    contains = s.useContains and true or false
                })
            end
            s.customPhrases = newPhrases
        end

        -- Seed default Thunderfury entries if customPhrases is empty
        -- (fresh install) or migrate from old thunderfury/itemLink settings
        local function HasThunderfuryPhrase()
            for _, e in ipairs(s.customPhrases) do
                if type(e) == "table" and e.text and e.text ==
                    "Thunderfury, Blessed Blade of the Windseeker" and
                    not e.itemId then return true end
            end
            return false
        end
        local function HasThunderfuryItem()
            for _, e in ipairs(s.customPhrases) do
                if type(e) == "table" and e.itemId == "19019" then
                    return true
                end
            end
            return false
        end

        -- Add defaults if missing (fresh install or migrating from checkbox era)
        if #s.customPhrases == 0 or
            (s.thunderfury ~= false and not HasThunderfuryPhrase()) then
            if not HasThunderfuryPhrase() then
                table.insert(s.customPhrases, 1, {
                    text = "Thunderfury, Blessed Blade of the Windseeker",
                    contains = false
                })
            end
        end
        if #s.customPhrases == 0 or
            (s.itemLink ~= false and not HasThunderfuryItem()) then
            if not HasThunderfuryItem() then
                -- Try to get the real item link from the cache
                local tfName, tfLink = GetItemInfo(19019)
                table.insert(s.customPhrases, {
                    text = tfName or
                        "Thunderfury, Blessed Blade of the Windseeker",
                    itemId = "19019",
                    itemLink = tfLink,
                    displayName = tfName or
                        "Thunderfury, Blessed Blade of the Windseeker"
                })
                -- If not cached yet, update once the server responds
                if not tfLink then
                    local tfWait = CreateFrame("Frame")
                    tfWait:RegisterEvent("GET_ITEM_INFO_RECEIVED")
                    tfWait:SetScript("OnEvent", function(self, event, queriedId)
                        if tonumber(queriedId) == 19019 then
                            self:UnregisterAllEvents()
                            local n, l = GetItemInfo(19019)
                            if n and l then
                                for _, e in ipairs(
                                                ThunderfuryAutoIgnoreDB.settings
                                                    .customPhrases) do
                                    if type(e) == "table" and e.itemId ==
                                        "19019" and not e.itemLink then
                                        e.itemLink = l
                                        e.displayName = n
                                        e.text = n
                                    end
                                end
                            end
                        end
                    end)
                end
            end
        end

        -- Clean up old settings keys
        s.thunderfury = nil
        s.itemLink = nil

        f:RegisterEvent("PLAYER_ENTERING_WORLD")
        f:UnregisterEvent("VARIABLES_LOADED")

    elseif event == "PLAYER_ENTERING_WORLD" then
        RegisterEvents()

        -- On fresh login the ignore list arrives from the server a few
        -- seconds after PLAYER_ENTERING_WORLD.  We wait for
        -- IGNORELIST_UPDATE so the game ignore list is populated before
        -- we attempt to diff it against our DB.  A 15-second safety net
        -- handles the case where the event never fires.
        local synced = false
        local ignoreListReady = false

        local function DoSync()
            if synced then return end
            synced = true
            f:UnregisterEvent("IGNORELIST_UPDATE")
            SyncIgnoreList()
        end

        -- Mark that we've seen at least one IGNORELIST_UPDATE with data,
        -- then sync after a short settle delay so the client is stable.
        local function OnIgnoreListReady()
            if synced then return end
            local numIgnored = C_FriendList and C_FriendList.GetNumIgnores and
                                   C_FriendList.GetNumIgnores() or
                                   (GetNumIgnores and GetNumIgnores()) or 0
            -- If the game list has entries (or the DB is empty), it's ready
            local dbCount = 0
            for _ in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers or {}) do
                dbCount = dbCount + 1
            end
            if numIgnored > 0 or dbCount == 0 then
                ignoreListReady = true
                if C_Timer and C_Timer.After then
                    C_Timer.After(0.5, DoSync)
                else
                    DoSync()
                end
            end
            -- else: list not loaded yet, wait for next IGNORELIST_UPDATE
        end

        f._pendingSync = OnIgnoreListReady
        f:RegisterEvent("IGNORELIST_UPDATE")

        -- Safety net: if the event never fires or never has data, sync anyway
        if C_Timer and C_Timer.After then C_Timer.After(15, DoSync) end

        f:UnregisterEvent("PLAYER_ENTERING_WORLD")

    elseif event == "IGNORELIST_UPDATE" then
        if f._pendingSync then
            -- Call the readiness check; it stays registered until it
            -- confirms the list is populated (or the safety timer fires).
            f._pendingSync()
        end

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
            local lowerNameOnly = lowerName:match("^([^%-]+)") or lowerName
            local existingName
            for storedName, _ in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers) do
                local storedLower = string.lower(storedName)
                local storedNameOnly = storedLower:match("^([^%-]+)") or
                                           storedLower
                if storedLower == lowerName or storedNameOnly == lowerNameOnly then
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

-- Ignore duration (dropdown 1-24 hours) -----------------------------------
local hoursLabel = optionsPanel:CreateFontString(nil, "OVERLAY",
                                                 "GameFontNormal")
hoursLabel:SetPoint("TOPLEFT", enableCheck, "BOTTOMLEFT", 4, -18)
hoursLabel:SetText("Hours before auto-unignore:")

local hoursDropdown = CreateFrame("Frame", "TFAHoursDropdown", optionsPanel,
                                  "UIDropDownMenuTemplate")
hoursDropdown:SetPoint("LEFT", hoursLabel, "RIGHT", -8, -2)
UIDropDownMenu_SetWidth(hoursDropdown, 50)

local function HoursDropdown_Initialize(self, level)
    for i = 1, 24 do
        local info = UIDropDownMenu_CreateInfo()
        info.text = tostring(i)
        info.value = i
        info.func = function(btn)
            ThunderfuryAutoIgnoreDB.settings.ignoreHours = btn.value
            UIDropDownMenu_SetSelectedValue(hoursDropdown, btn.value)
        end
        info.checked = (ThunderfuryAutoIgnoreDB.settings.ignoreHours == i)
        UIDropDownMenu_AddButton(info, level)
    end
end
UIDropDownMenu_Initialize(hoursDropdown, HoursDropdown_Initialize)
UIDropDownMenu_SetSelectedValue(hoursDropdown, ThunderfuryAutoIgnoreDB.settings
                                    .ignoreHours or 1)

-- ---------------------------------------------------------------------------
-- Custom Phrases — list + Add popup
-- ---------------------------------------------------------------------------
local phraseSectionLabel = optionsPanel:CreateFontString(nil, "OVERLAY",
                                                         "GameFontNormal")
phraseSectionLabel:SetPoint("TOPLEFT", hoursLabel, "BOTTOMLEFT", -4, -20)
phraseSectionLabel:SetText("Blocked Phrases/Items:")

-- Scroll frame for phrase list
local phraseListScroll = CreateFrame("ScrollFrame", "TFAPhraseListScroll",
                                     optionsPanel,
                                     "UIPanelScrollFrameTemplate,BackdropTemplate")
phraseListScroll:SetPoint("TOPLEFT", phraseSectionLabel, "BOTTOMLEFT", 0, -6)
phraseListScroll:SetSize(370, 100)
phraseListScroll:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = false,
    tileSize = 16,
    edgeSize = 12,
    insets = {left = 4, right = 4, top = 4, bottom = 4}
})
phraseListScroll:SetBackdropColor(0.05, 0.05, 0.05, 1)
phraseListScroll:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

-- Move the scrollbar inside the frame
local phraseScrollBar = _G["TFAPhraseListScrollScrollBar"]
if phraseScrollBar then
    phraseScrollBar:ClearAllPoints()
    phraseScrollBar:SetPoint("TOPRIGHT", phraseListScroll, "TOPRIGHT", -4, -18)
    phraseScrollBar:SetPoint("BOTTOMRIGHT", phraseListScroll, "BOTTOMRIGHT", -4,
                             18)
end

local phraseListContent = CreateFrame("Frame", nil, phraseListScroll)
phraseListContent:SetSize(346, 1)
phraseListScroll:SetScrollChild(phraseListContent)

-- Row pool for phrase list display
local phraseLinePool = {}
local activePhraseLines = {}

local function AcquirePhraseLine()
    local line = table.remove(phraseLinePool)
    if not line then
        line = CreateFrame("Frame", nil, phraseListContent)
        line:SetSize(340, 18)
        line:EnableMouse(true)
        line.text = line:CreateFontString(nil, "OVERLAY",
                                          "ThunderfuryAutoIgnoreFont")
        line.text:SetPoint("LEFT", 4, 0)
        line.text:SetPoint("RIGHT", -24, 0)
        line.text:SetJustifyH("LEFT")
        line.text:SetWordWrap(false)
        line.removeBtn = CreateFrame("Button", nil, line)
        line.removeBtn:SetSize(16, 16)
        line.removeBtn:SetPoint("RIGHT", -2, 0)
        line.removeBtn.label = line.removeBtn:CreateFontString(nil, "OVERLAY",
                                                               "GameFontNormalSmall")
        line.removeBtn.label:SetAllPoints()
        line.removeBtn.label:SetText("|cffff4444X|r")
        line.removeBtn:SetHighlightTexture(
            "Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    end
    -- Clear any previous tooltip scripts
    line:SetScript("OnEnter", nil)
    line:SetScript("OnLeave", nil)
    line:Show()
    table.insert(activePhraseLines, line)
    return line
end

local function ReleaseAllPhraseLines()
    for _, line in ipairs(activePhraseLines) do
        line:Hide()
        line:ClearAllPoints()
        table.insert(phraseLinePool, line)
    end
    wipe(activePhraseLines)
end

local function RefreshPhraseList()
    ReleaseAllPhraseLines()
    local phrases = ThunderfuryAutoIgnoreDB.settings.customPhrases or {}
    local yOffset = 0
    for i, entry in ipairs(phrases) do
        local line = AcquirePhraseLine()
        line:SetPoint("TOPLEFT", 0, yOffset)
        if type(entry) == "table" then
            if entry.itemId then
                -- Try to get the real item link from the game for display
                local displayLink = entry.itemLink
                if not displayLink then
                    local _, link = GetItemInfo(tonumber(entry.itemId))
                    displayLink = link
                end
                if displayLink then
                    line.text:SetText("|cff00ccff[Item]|r " .. displayLink)
                    -- Tooltip on hover
                    local storedLink = displayLink
                    line:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetHyperlink(storedLink)
                        GameTooltip:Show()
                    end)
                    line:SetScript("OnLeave", function()
                        GameTooltip:Hide()
                    end)
                else
                    line.text:SetText("|cff00ccff[Item:" .. entry.itemId ..
                                          "]|r " ..
                                          (entry.displayName or "loading..."))
                end
            else
                local tag = entry.contains and "|cff00ff00[Contains]|r " or
                                "|cffffcc00[Exact]|r "
                line.text:SetText(tag .. (entry.text or ""))
            end
        else
            line.text:SetText(tostring(entry))
        end
        local idx = i
        line.removeBtn:SetScript("OnClick", function()
            table.remove(ThunderfuryAutoIgnoreDB.settings.customPhrases, idx)
            RefreshPhraseList()
            print("|cffff8c00TFA:|r Removed custom phrase")
        end)
        yOffset = yOffset - 20
    end
    phraseListContent:SetHeight(math.max(1, -yOffset))
end

-- "Add" button below the list (left-aligned)
local addPhraseBtn = CreateFrame("Button", nil, optionsPanel,
                                 "UIPanelButtonTemplate")
addPhraseBtn:SetSize(60, 24)
addPhraseBtn:SetPoint("TOPLEFT", phraseListScroll, "BOTTOMLEFT", 0, -6)
addPhraseBtn:SetText("Add")

-- "Add Thunderfury" button (right-aligned)
local addTFBtn = CreateFrame("Button", nil, optionsPanel,
                             "UIPanelButtonTemplate")
addTFBtn:SetSize(120, 24)
addTFBtn:SetPoint("TOPRIGHT", phraseListScroll, "BOTTOMRIGHT", 0, -6)
addTFBtn:SetText("Add Thunderfury")
addTFBtn:SetScript("OnClick", function()
    local phrases = ThunderfuryAutoIgnoreDB.settings.customPhrases
    -- Check if they already exist
    local hasPhrase, hasItem = false, false
    for _, e in ipairs(phrases) do
        if type(e) == "table" then
            if e.text == "Thunderfury, Blessed Blade of the Windseeker" and
                not e.itemId then hasPhrase = true end
            if e.itemId == "19019" then hasItem = true end
        end
    end
    local added = 0
    if not hasPhrase then
        table.insert(phrases, {
            text = "Thunderfury, Blessed Blade of the Windseeker",
            contains = false
        })
        added = added + 1
    end
    if not hasItem then
        local tfName, tfLink = GetItemInfo(19019)
        local newEntry = {
            text = tfName or "Thunderfury, Blessed Blade of the Windseeker",
            itemId = "19019",
            itemLink = tfLink,
            displayName = tfName or
                "Thunderfury, Blessed Blade of the Windseeker"
        }
        table.insert(phrases, newEntry)
        added = added + 1
        -- If not cached, resolve once server responds
        if not tfLink then
            local tfWait = CreateFrame("Frame")
            tfWait:RegisterEvent("GET_ITEM_INFO_RECEIVED")
            tfWait:SetScript("OnEvent", function(self, event, queriedId)
                if tonumber(queriedId) == 19019 then
                    self:UnregisterAllEvents()
                    local n, l = GetItemInfo(19019)
                    if n and l then
                        newEntry.itemLink = l
                        newEntry.displayName = n
                        newEntry.text = n
                        RefreshPhraseList()
                    end
                end
            end)
        end
    end
    if added > 0 then
        RefreshPhraseList()
        print("|cffff8c00TFA:|r Added Thunderfury filters (" .. added ..
                  " entries)")
    else
        print("|cffff8c00TFA:|r Thunderfury filters already exist")
    end
end)

-- ---------------------------------------------------------------------------
-- Add Phrase popup frame
-- ---------------------------------------------------------------------------
local addPhrasePopup = CreateFrame("Frame", "TFAAddPhrasePopup", UIParent,
                                   "BackdropTemplate")
addPhrasePopup:SetSize(340, 170)
addPhrasePopup:SetPoint("CENTER")
addPhrasePopup:SetFrameStrata("DIALOG")
addPhrasePopup:SetClampedToScreen(true)
addPhrasePopup:SetMovable(true)
addPhrasePopup:EnableMouse(true)
addPhrasePopup:RegisterForDrag("LeftButton")
addPhrasePopup:SetScript("OnDragStart", addPhrasePopup.StartMoving)
addPhrasePopup:SetScript("OnDragStop", addPhrasePopup.StopMovingOrSizing)
addPhrasePopup:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = false,
    tileSize = 16,
    edgeSize = 16,
    insets = {left = 4, right = 4, top = 4, bottom = 4}
})
addPhrasePopup:SetBackdropColor(0.1, 0.1, 0.1, 1)
addPhrasePopup:SetBackdropBorderColor(1, 1, 1, 1)
addPhrasePopup:Hide()
tinsert(UISpecialFrames, "TFAAddPhrasePopup")

-- Hook shift-click item linking so it pastes into our edit box
hooksecurefunc("ChatEdit_InsertLink", function(link)
    if addPhrasePopup:IsShown() and popupEditBox:HasFocus() then
        popupEditBox:SetText(link)
    end
end)

-- Popup title
local popupTitle = addPhrasePopup:CreateFontString(nil, "OVERLAY",
                                                   "GameFontNormal")
popupTitle:SetPoint("TOP", 0, -12)
popupTitle:SetText("Add Custom Phrase")

-- Popup close button
local popupClose = CreateFrame("Button", nil, addPhrasePopup,
                               "UIPanelCloseButton")
popupClose:SetPoint("TOPRIGHT", -2, -2)

-- Text input label
local popupInputLabel = addPhrasePopup:CreateFontString(nil, "OVERLAY",
                                                        "GameFontNormal")
popupInputLabel:SetPoint("TOPLEFT", 16, -36)
popupInputLabel:SetText("Phrase or item link:")

-- Text input
local popupEditBox = CreateFrame("EditBox", "TFAPopupEditBox", addPhrasePopup,
                                 "BackdropTemplate")
popupEditBox:SetPoint("TOPLEFT", popupInputLabel, "BOTTOMLEFT", 0, -4)
popupEditBox:SetSize(308, 24)
popupEditBox:SetAutoFocus(false)
popupEditBox:SetFontObject("ChatFontNormal")
popupEditBox:SetTextInsets(6, 6, 0, 0)
popupEditBox:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = false,
    tileSize = 16,
    edgeSize = 12,
    insets = {left = 4, right = 4, top = 4, bottom = 4}
})
popupEditBox:SetBackdropColor(0.05, 0.05, 0.05, 1)
popupEditBox:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
popupEditBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
    addPhrasePopup:Hide()
end)

-- Match type: Contains checkbox (only applies to text phrases, not item links)
local popupContainsCheck = CreateFrame("CheckButton", nil, addPhrasePopup,
                                       "InterfaceOptionsCheckButtonTemplate")
popupContainsCheck:SetPoint("TOPLEFT", popupEditBox, "BOTTOMLEFT", -4, -6)
popupContainsCheck:SetChecked(true)
popupContainsCheck.label = popupContainsCheck:CreateFontString(nil, "OVERLAY",
                                                               "GameFontNormal")
popupContainsCheck.label:SetPoint("LEFT", popupContainsCheck, "RIGHT", 5, 0)
popupContainsCheck.label:SetText("Use 'contains' matching (for text phrases)")

-- Cancel button (anchored to bottom-right of popup)
local popupCancelBtn = CreateFrame("Button", nil, addPhrasePopup,
                                   "UIPanelButtonTemplate")
popupCancelBtn:SetSize(80, 24)
popupCancelBtn:SetPoint("BOTTOMRIGHT", -16, 12)
popupCancelBtn:SetText("Cancel")
popupCancelBtn:SetScript("OnClick", function() addPhrasePopup:Hide() end)

-- OK button (left of Cancel)
local popupOkBtn = CreateFrame("Button", nil, addPhrasePopup,
                               "UIPanelButtonTemplate")
popupOkBtn:SetSize(80, 24)
popupOkBtn:SetPoint("RIGHT", popupCancelBtn, "LEFT", -6, 0)
popupOkBtn:SetText("OK")

-- OK handler — auto-detect item link vs text phrase
popupOkBtn:SetScript("OnClick", function()
    local text = (popupEditBox:GetText() or ""):match("^%s*(.-)%s*$")
    if not text or text == "" then return end

    local entry
    local itemId, fullLink = ParseItemLink(text)
    if itemId then
        -- Detected an item link — validate it exists on the server
        local itemName, itemLink = GetItemInfo(tonumber(itemId))
        if itemName and itemLink then
            -- Item is cached and valid
            entry = {
                text = itemName,
                itemId = itemId,
                itemLink = itemLink,
                displayName = itemName
            }
            table.insert(ThunderfuryAutoIgnoreDB.settings.customPhrases, entry)
            RefreshPhraseList()
            addPhrasePopup:Hide()
            print("|cffff8c00TFA:|r Added item link filter: " .. itemLink)
        else
            -- Item not cached yet — request it and wait for GET_ITEM_INFO_RECEIVED
            print("|cffff8c00TFA:|r Querying server for item " .. itemId ..
                      "...")
            local waitFrame = CreateFrame("Frame")
            waitFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
            local timer
            waitFrame:SetScript("OnEvent", function(self, event, queriedId)
                if tostring(queriedId) == itemId then
                    self:UnregisterAllEvents()
                    if timer then
                        timer:Cancel();
                        timer = nil
                    end
                    local name2, link2 = GetItemInfo(tonumber(itemId))
                    if name2 and link2 then
                        entry = {
                            text = name2,
                            itemId = itemId,
                            itemLink = link2,
                            displayName = name2
                        }
                        table.insert(ThunderfuryAutoIgnoreDB.settings
                                         .customPhrases, entry)
                        RefreshPhraseList()
                        addPhrasePopup:Hide()
                        print("|cffff8c00TFA:|r Added item link filter: " ..
                                  link2)
                    else
                        print("|cffff8c00TFA:|r Item " .. itemId ..
                                  " not found on server.")
                    end
                end
            end)
            -- Timeout after 5 seconds
            timer = C_Timer.NewTimer(5, function()
                waitFrame:UnregisterAllEvents()
                print("|cffff8c00TFA:|r Timed out looking up item " .. itemId ..
                          ". It may not exist.")
            end)
        end
    else
        -- Plain text phrase
        entry = {
            text = text,
            contains = popupContainsCheck:GetChecked() and true or false
        }
        table.insert(ThunderfuryAutoIgnoreDB.settings.customPhrases, entry)
        RefreshPhraseList()
        addPhrasePopup:Hide()
        local mode = entry.contains and "contains" or "exact"
        print("|cffff8c00TFA:|r Added custom phrase (" .. mode .. " match)")
    end
end)

-- Enter in the edit box triggers OK
popupEditBox:SetScript("OnEnterPressed", function() popupOkBtn:Click() end)

-- Reset popup state when shown
addPhrasePopup:SetScript("OnShow", function()
    popupEditBox:SetText("")
    popupContainsCheck:SetChecked(true)
    popupEditBox:SetFocus()
end)

-- Wire up the Add Phrase button to open the popup
addPhraseBtn:SetScript("OnClick", function() addPhrasePopup:Show() end)

-- ---------------------------------------------------------------------------
-- Refresh every control when the panel is shown
-- ---------------------------------------------------------------------------
optionsPanel:SetScript("OnShow", function()
    local s = ThunderfuryAutoIgnoreDB.settings or {}
    enableCheck:SetChecked(s.enabled)
    UIDropDownMenu_SetSelectedValue(hoursDropdown, s.ignoreHours or 1)
    UIDropDownMenu_SetText(hoursDropdown, tostring(s.ignoreHours or 1))
    -- Refresh the phrase list display
    RefreshPhraseList()
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
        SyncIgnoreList(true)
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

    elseif command == "verify" then
        StartVerify()

    elseif command == "remove" and arg ~= "" then
        local targetName = arg:gsub("^%l", string.upper)
        local lowerTarget = string.lower(targetName)
        local found
        for n in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers) do
            if string.lower(n) == lowerTarget or
                string.lower(n:match("^([^%-]+)") or n) == lowerTarget then
                found = n
                break
            end
        end
        if found then
            local nameOnly = found:match("^([^%-]+)") or found
            SafeDelIgnore(nameOnly)
            ThunderfuryAutoIgnoreDB.ignoredPlayers[found] = nil
            print("|cffff8c00TFA:|r Removed " .. found)
            if ignoreFrame:IsShown() then UpdateIgnoreList() end
        else
            print("|cffff8c00TFA:|r " .. targetName .. " not found in DB")
        end

    elseif command == "help" then
        print("|cffff8c00TFA Help:|r")
        print("  /tfa          - show ignore list")
        print("  /tfa options  - open settings panel")
        print("  /tfa enable   - turn on auto-ignore")
        print("  /tfa disable  - turn off auto-ignore")
        print("  /tfa add Name    - manually add a player")
        print("  /tfa remove Name - remove a player from DB")
        print("  /tfa sync        - re-sync DB to this character")
        print("  /tfa verify      - check if permanent ignores still exist")
        print("  /tfa help        - this message")

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
                SyncIgnoreList(true)
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
