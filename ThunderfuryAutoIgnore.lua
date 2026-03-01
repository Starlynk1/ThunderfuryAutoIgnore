-- ============================================================================
-- Version: 0.2.0
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
    suppressGuildRecruitment = false,
    suppressCraftingSales = false,
    minimapPos = 220,
    minimapHide = false
}
local debugMode = false
local f
local BuildGameIgnoreMap
local CleanIgnoreList

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
    local fullLink = normalised:match("(|c%x+|Hitem:%d+.-|h%[.-%]|h|r)")
    if not fullLink then
        fullLink = normalised:match("(|Hitem:%d+.-|h%[.-%]|h)")
    end

    -- Extract item ID from the link or from a Wowhead URL
    local itemId = normalised:match("|Hitem:(%d+):")
    if not itemId then itemId = text:match("wowhead%.com/.-item=(%d+)") end

    return itemId, fullLink
end

local function TFA_Print(msg) print(msg) end

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

local function GetIgnoreCount()
    return C_FriendList and C_FriendList.GetNumIgnores and
               C_FriendList.GetNumIgnores() or
               (GetNumIgnores and GetNumIgnores()) or 0
end

local function GetIgnoreMax() return MAX_IGNORE or FRIENDS_LIST_IGNORE_MAX or 50 end

local function FindOldestTemporaryInGame(gameMap)
    local oldestName
    local oldestTs
    for dbName, data in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers or {}) do
        if type(data) == "table" and not data.permanent then
            local key = string.lower((dbName:match("^([^%-]+)") or dbName))
            if gameMap[key] then
                local ts = tonumber(data.timestamp) or 0
                if not oldestName or ts < oldestTs then
                    oldestName = dbName
                    oldestTs = ts
                end
            end
        end
    end
    return oldestName
end

local function EnsureIgnoreSpaceFIFO(forceOutput)
    local current = GetIgnoreCount()
    local maxIgnores = GetIgnoreMax()
    if current < maxIgnores then return true end

    -- Try normal cleanup first in case there are expired temporary entries.
    CleanIgnoreList()
    current = GetIgnoreCount()
    if current < maxIgnores then return true end

    -- FIFO eviction from tracked temporary entries that are currently in game list.
    local gameMap = BuildGameIgnoreMap()
    local victim = FindOldestTemporaryInGame(gameMap)
    if not victim then return false end

    local victimData = ThunderfuryAutoIgnoreDB.ignoredPlayers[victim] or {}
    SafeDelIgnore(victim)
    ThunderfuryAutoIgnoreDB.ignoredPlayers[victim] = nil
    TFA_Print("|cffff8c00TFA:|r Ignore list full — evicted oldest ignore " ..
                  victim .. " (ignored " ..
                  FormatDateTime(victimData.timestamp or time()) .. ")",
              forceOutput)
    return true
end

local function IgnoreNameKey(name)
    local lower = string.lower(name or "")
    return lower:match("^([^%-]+)") or lower
end

BuildGameIgnoreMap = function()
    local map = {}
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
            map[IgnoreNameKey(ignoreName)] = ignoreName
        end
    end
    return map
end

local function FindTrackedDBNameByKey(key)
    for dbName, _ in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers or {}) do
        if IgnoreNameKey(dbName) == key then return dbName end
    end
    return nil
end

local function ReconcileManualIgnoreChanges()
    if not ThunderfuryAutoIgnoreDB or not ThunderfuryAutoIgnoreDB.ignoredPlayers then
        return
    end

    local previous = f._lastGameIgnoreMap
    local current = BuildGameIgnoreMap()

    -- First snapshot after login/sync: establish baseline only.
    if not previous then
        f._lastGameIgnoreMap = current
        return
    end

    local imported = 0
    local removed = 0
    local now = time()

    -- Added in game ignore list outside tracked DB -> import as permanent
    for key, gameName in pairs(current) do
        if not previous[key] and not FindTrackedDBNameByKey(key) then
            ThunderfuryAutoIgnoreDB.ignoredPlayers[gameName] = {
                timestamp = now,
                permanent = true
            }
            imported = imported + 1
        end
    end

    -- Removed in game ignore list -> remove matching tracked DB entry
    for key, _ in pairs(previous) do
        if not current[key] then
            local dbName = FindTrackedDBNameByKey(key)
            if dbName then
                ThunderfuryAutoIgnoreDB.ignoredPlayers[dbName] = nil
                removed = removed + 1
            end
        end
    end

    f._lastGameIgnoreMap = current

    if imported > 0 or removed > 0 then
        TFA_Print("|cffff8c00TFA:|r Synced manual ignore changes (added " ..
                      imported .. ", removed " .. removed .. ")")
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
f = CreateFrame("Frame")
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
local function EscapeLuaPattern(text)
    return (text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

local function ContainsWholeWord(lowerMsg, lowerPhrase)
    local pattern = "%f[%w]" .. EscapeLuaPattern(lowerPhrase) .. "%f[%W]"
    return lowerMsg:find(pattern) ~= nil
end

local function MatchSpamEntry(msg)
    local settings = ThunderfuryAutoIgnoreDB.settings or {}
    if not settings.enabled then return false, false end
    local lowerMsg = string.lower(msg)

    -- Custom phrases (per-entry contains / item-link matching)
    local phrases = settings.customPhrases or {}
    for _, entry in ipairs(phrases) do
        if type(entry) == "table" then
            local action = entry.action == "suppress" and "suppress" or "ignore"
            if entry.itemId then
                -- Match in-game item links by item ID
                if msg:find("|Hitem:" .. entry.itemId .. ":") then
                    return true, action == "ignore"
                end
            elseif entry.text and entry.text ~= "" then
                local lowerPhrase = string.lower(entry.text)
                if entry.wholeWord then
                    if ContainsWholeWord(lowerMsg, lowerPhrase) then
                        return true, action == "ignore"
                    end
                elseif entry.contains then
                    if lowerMsg:find(lowerPhrase, 1, true) then
                        return true, action == "ignore"
                    end
                else
                    if lowerMsg == lowerPhrase then
                        return true, action == "ignore"
                    end
                end
            end
        elseif type(entry) == "string" and entry ~= "" then
            -- Legacy format fallback
            local lowerPhrase = string.lower(entry)
            if lowerMsg:find(lowerPhrase, 1, true) then
                return true, true
            end
        end
    end

    return false, false
end

local function IsSpamMessage(msg)
    local matched = MatchSpamEntry(msg)
    return matched
end

local filterDefs = ThunderfuryAutoIgnoreFilters or {}

local recruitmentKeywords = filterDefs.recruitmentKeywords or {}

local recruitmentStrongPhrases = filterDefs.recruitmentStrongPhrases or {}

local recruitmentExcludeKeywords = filterDefs.recruitmentExcludeKeywords or {}

local function IsLikelyTradeChannel(...)
    local candidates = {
        select(3, ...), select(4, ...), select(8, ...), select(9, ...)
    }
    for _, value in ipairs(candidates) do
        if type(value) == "string" then
            local s = string.lower(value)
            if s:find("trade", 1, true) then return true end
        end
    end

    for i = 6, 9 do
        local n = tonumber((select(i, ...)))
        if n == 2 then return true end
    end

    return false
end

local function HasGreenGuildMarker(msg)
    for rr, gg, bb in msg:gmatch("|cff(%x%x)(%x%x)(%x%x)<[^>]+>|r") do
        local r = tonumber(rr, 16) or 0
        local g = tonumber(gg, 16) or 0
        local b = tonumber(bb, 16) or 0
        if g >= 0x99 and g > r and g > b then return true end
    end

    for rr, gg, bb in msg:gmatch("|cff(%x%x)(%x%x)(%x%x)<[^>]+>") do
        local r = tonumber(rr, 16) or 0
        local g = tonumber(gg, 16) or 0
        local b = tonumber(bb, 16) or 0
        if g >= 0x99 and g > r and g > b then return true end
    end

    return false
end

local function HasAnyGuildMarker(msg)
    if HasGreenGuildMarker(msg) then return true end
    return msg:find("<[^>]+>") ~= nil
end

local function ContainsAnyKeyword(lowerMsg, keywords)
    for _, kw in ipairs(keywords) do
        if lowerMsg:find(kw, 1, true) then return true end
    end
    return false
end

local function CountKeywordMatches(lowerMsg, keywords)
    local count = 0
    for _, kw in ipairs(keywords) do
        if lowerMsg:find(kw, 1, true) then count = count + 1 end
    end
    return count
end

local function IsGuildRecruitmentMessage(event, msg, ...)
    if event ~= "CHAT_MSG_CHANNEL" and event ~= "CHAT_MSG_SAY" and event ~=
        "CHAT_MSG_YELL" then return false end

    local lowerMsg = string.lower(msg or "")
    if ContainsAnyKeyword(lowerMsg, recruitmentExcludeKeywords) then
        return false
    end

    local hasGreenMarker = HasGreenGuildMarker(msg)
    local hasAnyMarker = HasAnyGuildMarker(msg)
    local keywordHits = CountKeywordMatches(lowerMsg, recruitmentKeywords)
    local strongHits = CountKeywordMatches(lowerMsg, recruitmentStrongPhrases)

    return (hasGreenMarker and (keywordHits >= 1 or strongHits >= 1)) or
               (hasAnyMarker and (keywordHits >= 2 or strongHits >= 1))
end

local craftingSaleKeywords = filterDefs.craftingSaleKeywords or {}
local craftingContextKeywords = filterDefs.craftingContextKeywords or {}

local function HasCraftingSignal(msg)
    local lowerMsg = string.lower(msg or "")
    if msg:find("|Htrade:") then return true end
    if lowerMsg:find("%[enchanting%]") or lowerMsg:find("%[tailoring%]") or
        lowerMsg:find("%[blacksmithing%]") or
        lowerMsg:find("%[leatherworking%]") or lowerMsg:find("%[alchemy%]") or
        lowerMsg:find("%[jewelcrafting%]") or lowerMsg:find("%[engineering%]") or
        lowerMsg:find("%[inscription%]") or lowerMsg:find("%[enchant ") or
        lowerMsg:find("%[enchanting:") or lowerMsg:find("%[tailoring:") or
        lowerMsg:find("%[blacksmithing:") or lowerMsg:find("%[leatherworking:") or
        lowerMsg:find("%[alchemy:") or lowerMsg:find("%[jewelcrafting:") or
        lowerMsg:find("%[engineering:") or lowerMsg:find("%[inscription:") then
        return true
    end
    if msg:find("|Hitem:") and lowerMsg:find("craft", 1, true) then
        return true
    end
    if ContainsAnyKeyword(lowerMsg, craftingContextKeywords) then return true end
    return false
end

local function IsCraftingSalesMessage(event, msg, ...)
    if event ~= "CHAT_MSG_CHANNEL" and event ~= "CHAT_MSG_SAY" and event ~=
        "CHAT_MSG_YELL" then return false end

    if event == "CHAT_MSG_CHANNEL" and not IsLikelyTradeChannel(...) then
        return false
    end

    local lowerMsg = string.lower(msg or "")
    if not ContainsAnyKeyword(lowerMsg, craftingSaleKeywords) then
        return false
    end

    return HasCraftingSignal(msg)
end

-- ---------------------------------------------------------------------------
-- Clean expired ignores  (safe iteration - collects removals first)
-- ---------------------------------------------------------------------------
CleanIgnoreList = function()
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
        TFA_Print("|cffff8c00TFA:|r Auto-unignored " .. name .. " (ignored " ..
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
local function SyncIgnoreList(silent, forceOutput)
    -- 1.  Clean expired entries out of the addon DB
    CleanIgnoreList()

    -- 2.  Build a lowercase lookup of names already on the game ignore list
    --     The game may return names with or without a realm suffix, so we
    --     store both the full name and the name-only (before the hyphen).
    local gameIgnoreLookup = {}
    local gameIgnoreNames = {}
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
            table.insert(gameIgnoreNames, ignoreName)
            local lower = string.lower(ignoreName)
            gameIgnoreLookup[lower] = true
            -- Also store the name-only portion (strip realm)
            local nameOnly = lower:match("^([^%-]+)")
            if nameOnly then gameIgnoreLookup[nameOnly] = true end
        end
    end

    -- 3.  Build a lowercase DB lookup so we can import game-only ignores
    local dbLookup = {}
    for dbName, _ in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers or {}) do
        local lower = string.lower(dbName)
        dbLookup[lower] = true
        local nameOnly = lower:match("^([^%-]+)")
        if nameOnly then dbLookup[nameOnly] = true end
    end

    local function IsTrackedInDB(name)
        local lower = string.lower(name)
        if dbLookup[lower] then return true end
        local nameOnly = lower:match("^([^%-]+)")
        if nameOnly and dbLookup[nameOnly] then return true end
        return false
    end

    -- 4.  Import game ignores that are missing from DB as permanent entries
    local imported = 0
    local now = time()
    for _, gameName in ipairs(gameIgnoreNames) do
        if not IsTrackedInDB(gameName) then
            ThunderfuryAutoIgnoreDB.ignoredPlayers[gameName] = {
                timestamp = now,
                permanent = true
            }
            imported = imported + 1

            -- Keep lookup updated to avoid duplicates in this same sync pass
            local lower = string.lower(gameName)
            dbLookup[lower] = true
            local nameOnly = lower:match("^([^%-]+)")
            if nameOnly then dbLookup[nameOnly] = true end
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

    -- 5.  Add only DB entries that are missing from the game ignore list
    local added = 0
    local skippedFull = 0
    for name, _ in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers or {}) do
        if not IsAlreadyIgnored(name) then
            if EnsureIgnoreSpaceFIFO(forceOutput) then
                SafeAddIgnore(name)
                added = added + 1
            else
                skippedFull = skippedFull + 1
            end
        end
    end

    -- 6.  Poke the social system so the client refreshes its ignore list
    if C_FriendList and C_FriendList.ShowFriends then
        C_FriendList.ShowFriends()
    elseif ShowFriends then
        ShowFriends()
    end

    -- Update runtime snapshot used to detect manual add/remove deltas.
    f._lastGameIgnoreMap = BuildGameIgnoreMap()

    local total = 0
    for _ in pairs(ThunderfuryAutoIgnoreDB.ignoredPlayers or {}) do
        total = total + 1
    end
    if not silent then
        if imported > 0 and added > 0 then
            TFA_Print("|cffff8c00TFA:|r Imported " .. imported ..
                          " game ignore(s) as permanent, added " .. added ..
                          " DB ignore(s) to game — " .. total ..
                          " total tracked", forceOutput)
        elseif imported > 0 then
            TFA_Print("|cffff8c00TFA:|r Imported " .. imported ..
                          " game ignore(s) as permanent — " .. total ..
                          " total tracked", forceOutput)
        elseif added > 0 then
            TFA_Print("|cffff8c00TFA:|r Added " .. added ..
                          " DB ignore(s) to game — " .. total ..
                          " total tracked", forceOutput)
        elseif total > 0 then
            TFA_Print("|cffff8c00TFA:|r Ignore list in sync — " .. total ..
                          " player(s) tracked", forceOutput)
        end

        if skippedFull > 0 then
            TFA_Print("|cffff8c00TFA:|r Ignore list full — skipped " ..
                          skippedFull .. " DB entr" ..
                          (skippedFull == 1 and "y" or "ies") ..
                          " (no temporary FIFO candidate available)",
                      forceOutput)
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
    local settings = ThunderfuryAutoIgnoreDB.settings or {}
    local isGuildRecruit = settings.suppressGuildRecruitment and
                               IsGuildRecruitmentMessage(event, msg, ...)
    local isCraftingSales = settings.suppressCraftingSales and
                                IsCraftingSalesMessage(event, msg, ...)
    local shouldSuppress = isSpam or isGuildRecruit or isCraftingSales
    if shouldSuppress and debugMode then return false end
    return shouldSuppress
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
                customPhrases = {},
                suppressGuildRecruitment = false,
                suppressCraftingSales = false
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
        if s.suppressGuildRecruitment == nil then
            s.suppressGuildRecruitment = false
        end
        if s.suppressCraftingSales == nil then
            s.suppressCraftingSales = false
        end

        -- Migrate old minimap keys to nested minimap table
        if type(s.minimap) ~= "table" then
            s.minimap = {
                hide = s.minimapHide and true or false,
                minimapPos = tonumber(s.minimapPos) or 220
            }
        else
            if s.minimap.hide == nil then
                s.minimap.hide = s.minimapHide and true or false
            end
            if s.minimap.minimapPos == nil then
                s.minimap.minimapPos = tonumber(s.minimapPos) or 220
            end
        end
        s.minimapHide = nil
        s.minimapPos = nil

        -- Migrate flat string custom phrases to per-phrase format
        if s.customPhrases and #s.customPhrases > 0 and type(s.customPhrases[1]) ==
            "string" then
            local newPhrases = {}
            for _, phrase in ipairs(s.customPhrases) do
                table.insert(newPhrases, {
                    text = phrase,
                    contains = s.useContains and true or false,
                    wholeWord = false,
                    action = "ignore"
                })
            end
            s.customPhrases = newPhrases
        end

        -- Ensure all phrase entries have a valid action
        for _, e in ipairs(s.customPhrases) do
            if type(e) == "table" then
                e.action = e.action == "suppress" and "suppress" or "ignore"
                if e.wholeWord == nil then e.wholeWord = false end
            end
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
                    contains = false,
                    wholeWord = false,
                    action = "ignore"
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
                    action = "ignore",
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
        s.suppressMessages = nil
        s.guildRecruitStrictness = nil

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
            f._pendingSync = nil
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
        else
            ReconcileManualIgnoreChanges()
        end

    elseif (ThunderfuryAutoIgnoreDB.settings or {}).enabled then
        local msg, author = ...
        local isSpam, shouldIgnorePlayer = MatchSpamEntry(msg)
        if isSpam and shouldIgnorePlayer then
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
                if EnsureIgnoreSpaceFIFO(false) then
                    SafeAddIgnore(playerName)
                    ThunderfuryAutoIgnoreDB.ignoredPlayers[playerName] = {
                        timestamp = time()
                    }
                    TFA_Print("|cffff8c00TFA:|r Ignored " .. playerName ..
                                  " for spam")
                    if ignoreFrame:IsShown() then
                        UpdateIgnoreList()
                    end
                else
                    TFA_Print(
                        "|cffff8c00TFA:|r Ignore list full; no temporary " ..
                            "entry available for FIFO eviction")
                end
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
        TFA_Print("|cffff8c00TFA:|r Unignored " .. data.name)
    end,
    OnCancel = function(_, data)
        -- Button 2: Toggle Permanent
        local entry = ThunderfuryAutoIgnoreDB.ignoredPlayers[data.name]
        if entry then
            entry.permanent = not entry.permanent
            local state = entry.permanent and "permanent" or "temporary"
            TFA_Print("|cffff8c00TFA:|r " .. data.name .. " is now " .. state)
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

local function AttachOptionTooltip(widget, title, lines)
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, 1, 0.8, 0)
        if type(lines) == "table" then
            for _, line in ipairs(lines) do
                GameTooltip:AddLine(line, 1, 1, 1, true)
            end
        elseif type(lines) == "string" and lines ~= "" then
            GameTooltip:AddLine(lines, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

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
    TFA_Print("|cffff8c00TFA:|r " ..
                  (ThunderfuryAutoIgnoreDB.settings.enabled and "Enabled" or
                      "Disabled"))
end)
AttachOptionTooltip(enableCheck, "Enable Auto-Ignore", {
    "Turns all automatic filtering/ignoring on or off.",
    "When disabled, TFA does not auto-suppress messages."
})

local suppressGuildRecruitCheck = CreateFrame("CheckButton", nil, optionsPanel,
                                              "InterfaceOptionsCheckButtonTemplate")
suppressGuildRecruitCheck:SetPoint("TOPLEFT", enableCheck, "BOTTOMLEFT", 0, -4)
suppressGuildRecruitCheck.label = suppressGuildRecruitCheck:CreateFontString(
                                      nil, "OVERLAY", "GameFontNormal")
suppressGuildRecruitCheck.label:SetPoint("LEFT", suppressGuildRecruitCheck,
                                         "RIGHT", 5, 0)
suppressGuildRecruitCheck.label:SetText(
    "Suppress guild recruitment (Trade/Say/Yell)")
suppressGuildRecruitCheck:SetScript("OnClick", function(self)
    ThunderfuryAutoIgnoreDB.settings.suppressGuildRecruitment =
        self:GetChecked() and true or false
end)
AttachOptionTooltip(suppressGuildRecruitCheck, "Suppress Guild Recruitment", {
    "Suppresses likely guild recruitment ads in Trade/Say/Yell.",
    "Uses guild-marker and recruitment-phrase heuristics."
})

local suppressCraftingSalesCheck = CreateFrame("CheckButton", nil, optionsPanel,
                                               "InterfaceOptionsCheckButtonTemplate")
suppressCraftingSalesCheck:SetPoint("TOPLEFT", suppressGuildRecruitCheck,
                                    "BOTTOMLEFT", 0, -4)
suppressCraftingSalesCheck.label = suppressCraftingSalesCheck:CreateFontString(
                                       nil, "OVERLAY", "GameFontNormal")
suppressCraftingSalesCheck.label:SetPoint("LEFT", suppressCraftingSalesCheck,
                                          "RIGHT", 5, 0)
suppressCraftingSalesCheck.label:SetText(
    "Suppress crafting sales (profession/enchant ads)")
suppressCraftingSalesCheck:SetScript("OnClick", function(self)
    ThunderfuryAutoIgnoreDB.settings.suppressCraftingSales =
        self:GetChecked() and true or false
end)
AttachOptionTooltip(suppressCraftingSalesCheck, "Suppress Crafting Sales", {
    "Suppresses crafting/enchant sale advertisements.",
    "Targets profession links/tags and selling language."
})

-- Ignore duration (dropdown 1-24 hours) -----------------------------------
local hoursLabel = optionsPanel:CreateFontString(nil, "OVERLAY",
                                                 "GameFontNormal")
hoursLabel:SetPoint("TOPLEFT", suppressCraftingSalesCheck, "BOTTOMLEFT", 4, -14)
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
AttachOptionTooltip(hoursDropdown, "Auto-Unignore Duration", {
    "How long temporary ignores stay before TFA removes them.",
    "Permanent ignores are never auto-removed."
})

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

local OpenPhraseEditor

local function RefreshPhraseList()
    ReleaseAllPhraseLines()
    local phrases = ThunderfuryAutoIgnoreDB.settings.customPhrases or {}
    local yOffset = 0
    for i, entry in ipairs(phrases) do
        local line = AcquirePhraseLine()
        line:SetPoint("TOPLEFT", 0, yOffset)
        if type(entry) == "table" then
            local action = entry.action == "suppress" and "suppress" or "ignore"
            local actionTag = action == "ignore" and "|cffff6666[Ignore]|r " or
                                  "|cff66ccff[Suppress]|r "
            if entry.itemId then
                -- Try to get the real item link from the game for display
                local displayLink = entry.itemLink
                if not displayLink then
                    local _, link = GetItemInfo(tonumber(entry.itemId))
                    displayLink = link
                end
                if displayLink then
                    line.text:SetText(actionTag .. "|cff00ccff[Item]|r " ..
                                          displayLink)
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
                    line.text:SetText(actionTag .. "|cff00ccff[Item:" ..
                                          entry.itemId .. "]|r " ..
                                          (entry.displayName or "loading..."))
                end
            else
                local tag
                if entry.wholeWord then
                    tag = "|cff66ff66[Word]|r "
                elseif entry.contains then
                    tag = "|cff00ff00[Contains]|r "
                else
                    tag = "|cffffcc00[Exact]|r "
                end
                line.text:SetText(actionTag .. tag .. (entry.text or ""))
            end
        else
            line.text:SetText(tostring(entry))
        end
        local idx = i
        line:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and OpenPhraseEditor then
                OpenPhraseEditor(idx, entry)
            end
        end)
        line.removeBtn:SetScript("OnClick", function()
            table.remove(ThunderfuryAutoIgnoreDB.settings.customPhrases, idx)
            RefreshPhraseList()
            TFA_Print("|cffff8c00TFA:|r Removed custom phrase")
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
            contains = false,
            action = "ignore"
        })
        added = added + 1
    end
    if not hasItem then
        local tfName, tfLink = GetItemInfo(19019)
        local newEntry = {
            text = tfName or "Thunderfury, Blessed Blade of the Windseeker",
            itemId = "19019",
            itemLink = tfLink,
            action = "ignore",
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
        TFA_Print("|cffff8c00TFA:|r Added Thunderfury filters (" .. added ..
                      " entries)")
    else
        TFA_Print("|cffff8c00TFA:|r Thunderfury filters already exist")
    end
end)

-- ---------------------------------------------------------------------------
-- Add Phrase popup frame
-- ---------------------------------------------------------------------------
local addPhrasePopup = CreateFrame("Frame", "TFAAddPhrasePopup", UIParent,
                                   "BackdropTemplate")
addPhrasePopup:SetSize(340, 220)
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
    local editBox = _G.TFAPopupEditBox
    if addPhrasePopup:IsShown() and editBox and editBox:HasFocus() then
        editBox:SetText(link)
    end
end)

-- Popup title
local popupTitle = addPhrasePopup:CreateFontString(nil, "OVERLAY",
                                                   "GameFontNormal")
popupTitle:SetPoint("TOP", 0, -12)
popupTitle:SetText("Add Custom Phrase")

local phraseEditorState = {index = nil, entry = nil}

local function SaveCustomPhraseEntry(entry, editIndex)
    if editIndex and ThunderfuryAutoIgnoreDB.settings.customPhrases[editIndex] then
        ThunderfuryAutoIgnoreDB.settings.customPhrases[editIndex] = entry
    else
        table.insert(ThunderfuryAutoIgnoreDB.settings.customPhrases, entry)
    end
end

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
AttachOptionTooltip(popupContainsCheck, "Contains Match", {
    "Matches when the phrase appears anywhere in the message.",
    "Example: LF matches LFG/LFM."
})

local popupWholeWordCheck = CreateFrame("CheckButton", nil, addPhrasePopup,
                                        "InterfaceOptionsCheckButtonTemplate")
popupWholeWordCheck:SetPoint("TOPLEFT", popupContainsCheck, "BOTTOMLEFT", 0, -2)
popupWholeWordCheck:SetChecked(false)
popupWholeWordCheck.label = popupWholeWordCheck:CreateFontString(nil, "OVERLAY",
                                                                 "GameFontNormal")
popupWholeWordCheck.label:SetPoint("LEFT", popupWholeWordCheck, "RIGHT", 5, 0)
popupWholeWordCheck.label:SetText("Match whole word only")
AttachOptionTooltip(popupWholeWordCheck, "Whole Word Match", {
    "Matches only standalone words, not substrings.",
    "Example: anal matches 'anal' but not 'analogy'."
})

popupWholeWordCheck:SetScript("OnClick", function(self)
    if self:GetChecked() then popupContainsCheck:SetChecked(true) end
end)

popupContainsCheck:SetScript("OnClick", function(self)
    if not self:GetChecked() then popupWholeWordCheck:SetChecked(false) end
end)

local popupIgnoreCheck = CreateFrame("CheckButton", nil, addPhrasePopup,
                                     "InterfaceOptionsCheckButtonTemplate")
popupIgnoreCheck:SetPoint("TOPLEFT", popupWholeWordCheck, "BOTTOMLEFT", 0, -4)
popupIgnoreCheck:SetChecked(true)
popupIgnoreCheck.label = popupIgnoreCheck:CreateFontString(nil, "OVERLAY",
                                                           "GameFontNormal")
popupIgnoreCheck.label:SetPoint("LEFT", popupIgnoreCheck, "RIGHT", 5, 0)
popupIgnoreCheck.label:SetText(
    "Ignore matching player (otherwise suppress only)")
AttachOptionTooltip(popupIgnoreCheck, "Action", {
    "Checked: suppress message and ignore sender.",
    "Unchecked: suppress message only."
})

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
    local editIndex = phraseEditorState.index
    local itemId, fullLink = ParseItemLink(text)
    local action = popupIgnoreCheck:GetChecked() and "ignore" or "suppress"
    if itemId then
        -- Detected an item link — validate it exists on the server
        local itemName, itemLink = GetItemInfo(tonumber(itemId))
        if itemName and itemLink then
            -- Item is cached and valid
            entry = {
                text = itemName,
                itemId = itemId,
                itemLink = itemLink,
                action = action,
                displayName = itemName
            }
            SaveCustomPhraseEntry(entry, editIndex)
            RefreshPhraseList()
            addPhrasePopup:Hide()
            TFA_Print("|cffff8c00TFA:|r Added item link filter: " .. itemLink)
        else
            -- Item not cached yet — request it and wait for GET_ITEM_INFO_RECEIVED
            TFA_Print("|cffff8c00TFA:|r Querying server for item " .. itemId ..
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
                            action = action,
                            displayName = name2
                        }
                        SaveCustomPhraseEntry(entry, editIndex)
                        RefreshPhraseList()
                        addPhrasePopup:Hide()
                        TFA_Print("|cffff8c00TFA:|r Added item link filter: " ..
                                      link2)
                    else
                        TFA_Print("|cffff8c00TFA:|r Item " .. itemId ..
                                      " not found on server.")
                    end
                end
            end)
            -- Timeout after 5 seconds
            timer = C_Timer.NewTimer(5, function()
                waitFrame:UnregisterAllEvents()
                TFA_Print("|cffff8c00TFA:|r Timed out looking up item " ..
                              itemId .. ". It may not exist.")
            end)
        end
    else
        -- Plain text phrase
        entry = {
            text = text,
            contains = popupContainsCheck:GetChecked() and true or false,
            wholeWord = popupWholeWordCheck:GetChecked() and true or false,
            action = action
        }
        SaveCustomPhraseEntry(entry, editIndex)
        RefreshPhraseList()
        addPhrasePopup:Hide()
        local mode = entry.wholeWord and "whole word" or
                         (entry.contains and "contains" or "exact")
        TFA_Print("|cffff8c00TFA:|r Added custom phrase (" .. mode .. " match)")
    end
end)

-- Enter in the edit box triggers OK
popupEditBox:SetScript("OnEnterPressed", function() popupOkBtn:Click() end)

-- Reset popup state when shown
addPhrasePopup:SetScript("OnShow", function()
    local editEntry = phraseEditorState.entry
    if editEntry then
        popupTitle:SetText("Edit Blocked Phrase")
        popupOkBtn:SetText("Save")
        if editEntry.itemId then
            popupEditBox:SetText(editEntry.itemLink or editEntry.text or "")
        else
            popupEditBox:SetText(editEntry.text or "")
        end
        popupContainsCheck:SetChecked(editEntry.contains and true or false)
        popupWholeWordCheck:SetChecked(editEntry.wholeWord and true or false)
        popupIgnoreCheck:SetChecked((editEntry.action ~= "suppress") and true or
                                        false)
    else
        popupTitle:SetText("Add Custom Phrase")
        popupOkBtn:SetText("Add")
        popupEditBox:SetText("")
        popupContainsCheck:SetChecked(true)
        popupWholeWordCheck:SetChecked(false)
        popupIgnoreCheck:SetChecked(true)
    end
    popupEditBox:SetFocus()
end)

addPhrasePopup:SetScript("OnHide", function()
    phraseEditorState.index = nil
    phraseEditorState.entry = nil
end)

-- Wire up the Add Phrase button to open the popup
OpenPhraseEditor = function(index, entry)
    phraseEditorState.index = index
    phraseEditorState.entry = entry
    addPhrasePopup:Show()
end

addPhraseBtn:SetScript("OnClick", function()
    phraseEditorState.index = nil
    phraseEditorState.entry = nil
    addPhrasePopup:Show()
end)

-- ---------------------------------------------------------------------------
-- Refresh every control when the panel is shown
-- ---------------------------------------------------------------------------
optionsPanel:SetScript("OnShow", function()
    local s = ThunderfuryAutoIgnoreDB.settings or {}
    enableCheck:SetChecked(s.enabled)
    suppressGuildRecruitCheck:SetChecked(
        s.suppressGuildRecruitment and true or false)
    suppressCraftingSalesCheck:SetChecked(
        s.suppressCraftingSales and true or false)
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
    local rawCmd = cmd or ""
    local command, arg = rawCmd:match("^(%S+)%s*(.*)$")
    command = (command or rawCmd):lower()
    arg = arg or ""

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
            if EnsureIgnoreSpaceFIFO(true) then
                SafeAddIgnore(playerName)
                ThunderfuryAutoIgnoreDB.ignoredPlayers[playerName] = {
                    timestamp = time()
                }
                print("|cffff8c00TFA:|r Added " .. playerName)
                if ignoreFrame:IsShown() then UpdateIgnoreList() end
            else
                print("|cffff8c00TFA:|r Ignore list full; no temporary " ..
                          "entry available for FIFO eviction")
            end
        else
            print("|cffff8c00TFA:|r " .. exists .. " already ignored")
        end

    elseif command == "sync" then
        SyncIgnoreList(false, true)

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
