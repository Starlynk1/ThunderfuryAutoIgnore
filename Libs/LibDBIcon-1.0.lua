-- LibDBIcon-1.0
-- Minimap icon library using LibDataBroker
local DBICON10 = "LibDBIcon-1.0"
local DBICON10_MINOR = 48

assert(LibStub, DBICON10 .. " requires LibStub")
local ldb = LibStub("LibDataBroker-1.1")
local lib = LibStub:NewLibrary(DBICON10, DBICON10_MINOR)
if not lib then return end

lib.objects = lib.objects or {}
lib.callbackRegistered = lib.callbackRegistered or nil
lib.callbacks = lib.callbacks or LibStub("CallbackHandler-1.0"):New(lib)
lib.notCreated = lib.notCreated or {}

local isDraggingButton = false

function lib:IconCallback(event, name, key, value, dataobj)
    if lib.objects[name] then
        if key == "icon" then
            lib.objects[name].icon:SetTexture(value)
        elseif key == "iconCoords" then
            lib.objects[name].icon:SetTexCoord(unpack(value))
        elseif key == "iconR" then
            local _, g, b = dataobj.iconG, dataobj.iconB
            if g and b then
                lib.objects[name].icon:SetVertexColor(value, g, b)
            end
        elseif key == "iconG" then
            local r, _, b = dataobj.iconR, dataobj.iconB
            if r and b then
                lib.objects[name].icon:SetVertexColor(r, value, b)
            end
        elseif key == "iconB" then
            local r, g = dataobj.iconR, dataobj.iconG
            if r and g then
                lib.objects[name].icon:SetVertexColor(r, g, value)
            end
        end
    end
end

if not lib.callbackRegistered then
    ldb.RegisterCallback(lib, "LibDataBroker_AttributeChanged", "IconCallback")
    lib.callbackRegistered = true
end

local function getAnchors(frame)
    local x, y = frame:GetCenter()
    if not x or not y then return "CENTER" end
    local hhalf = (x > UIParent:GetWidth() * 2 / 3) and "RIGHT" or
                      (x < UIParent:GetWidth() / 3) and "LEFT" or ""
    local vhalf = (y > UIParent:GetHeight() / 2) and "TOP" or "BOTTOM"
    return vhalf .. hhalf, frame,
           (vhalf == "TOP" and "BOTTOM" or "TOP") .. hhalf
end

local function onEnter(self)
    if isDraggingButton then return end
    local obj = self.dataObject
    if obj.OnTooltipShow then
        GameTooltip:SetOwner(self, "ANCHOR_NONE")
        GameTooltip:SetPoint(getAnchors(self))
        obj.OnTooltipShow(GameTooltip)
        GameTooltip:Show()
    elseif obj.OnEnter then
        obj.OnEnter(self)
    end
end

local function onLeave(self)
    local obj = self.dataObject
    GameTooltip:Hide()
    if obj.OnLeave then obj.OnLeave(self) end
end

local function onClick(self, b)
    local obj = self.dataObject
    if obj.OnClick then obj.OnClick(self, b) end
end

local function onDragStart(self)
    self:LockHighlight()
    self.isMouseDown = true
    isDraggingButton = true
    self:SetScript("OnUpdate", function(dragSelf)
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        local angle = math.deg(math.atan2(py - my, px - mx)) % 360
        self.db.minimapPos = angle
        lib:SetButtonToPosition(dragSelf, angle)
    end)
    GameTooltip:Hide()
end

local function onDragStop(self)
    self:SetScript("OnUpdate", nil)
    self.isMouseDown = false
    isDraggingButton = false
    self:UnlockHighlight()
end

function lib:SetButtonToPosition(button, angle)
    local rad = math.rad(angle)
    local x, y = math.cos(rad) * 80, math.sin(rad) * 80
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function createButton(name, object, db)
    local button = CreateFrame("Button", "LibDBIcon10_" .. name, Minimap)
    button.dataObject = object
    button.db = db
    button:SetFrameStrata("MEDIUM")
    button:SetSize(31, 31)
    button:SetFrameLevel(8)
    button:RegisterForClicks("anyUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture(136477) -- "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"

    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture(136430) -- "Interface\\Minimap\\MiniMap-TrackingBorder"
    overlay:SetPoint("TOPLEFT")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture(136467) -- "Interface\\Minimap\\UI-Minimap-Background"
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture(object.icon)
    if object.iconCoords then icon:SetTexCoord(unpack(object.iconCoords)) end
    icon:SetPoint("TOPLEFT", 7, -6)
    button.icon = icon

    button:SetScript("OnEnter", onEnter)
    button:SetScript("OnLeave", onLeave)
    button:SetScript("OnClick", onClick)
    button:SetScript("OnDragStart", onDragStart)
    button:SetScript("OnDragStop", onDragStop)

    lib.objects[name] = button

    if db.hide then
        button:Hide()
    else
        button:Show()
    end

    lib:SetButtonToPosition(button, db.minimapPos or 220)
    lib.callbacks:Fire("LibDBIcon_IconCreated", button, name)
end

function lib:Register(name, object, db)
    if not object.icon then
        error("Can't register an LDB with no icon: " .. name, 2)
    end
    db.minimapPos = db.minimapPos or 220
    db.hide = db.hide or false
    if lib.objects[name] then return end -- already registered
    createButton(name, object, db)
end

function lib:Lock(name)
    if not lib.objects[name] then return end
    lib.objects[name]:SetScript("OnDragStart", nil)
    lib.objects[name]:SetScript("OnDragStop", nil)
end

function lib:Unlock(name)
    if not lib.objects[name] then return end
    lib.objects[name]:SetScript("OnDragStart", onDragStart)
    lib.objects[name]:SetScript("OnDragStop", onDragStop)
end

function lib:Hide(name)
    if not lib.objects[name] then return end
    lib.objects[name]:Hide()
end

function lib:Show(name)
    if not lib.objects[name] then return end
    lib.objects[name]:Show()
end

function lib:IsRegistered(name) return lib.objects[name] and true or false end

function lib:Refresh(name, db)
    if not lib.objects[name] then return end
    if db then lib.objects[name].db = db end
    lib:SetButtonToPosition(lib.objects[name],
                            lib.objects[name].db.minimapPos or 220)
    if lib.objects[name].db.hide then
        lib.objects[name]:Hide()
    else
        lib.objects[name]:Show()
    end
end

function lib:GetMinimapButton(name) return lib.objects[name] end

function lib:GetButtonList()
    local t = {}
    for name in pairs(lib.objects) do table.insert(t, name) end
    return t
end

function lib:SetButtonRadius(radius)
    -- compat stub
end

function lib:EnableLibrary()
    -- compat stub
end

function lib:DisableLibrary()
    -- compat stub
end
