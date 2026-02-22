-- LibDataBroker-1.1
-- Data broker library for passing data between addons
assert(LibStub, "LibDataBroker-1.1 requires LibStub")

local lib, oldminor = LibStub:NewLibrary("LibDataBroker-1.1", 4)
if not lib then return end
oldminor = oldminor or 0

lib.callbacks = lib.callbacks or LibStub("CallbackHandler-1.0"):New(lib)
lib.attributestorage, lib.namestorage, lib.proxystorage =
    lib.attributestorage or {}, lib.namestorage or {}, lib.proxystorage or {}
local attributestorage, namestorage, proxystorage, callbacks =
    lib.attributestorage, lib.namestorage, lib.proxystorage, lib.callbacks

if oldminor < 2 then
    lib.domt = {
        __metatable = "access denied",
        __index = function(self, key)
            return attributestorage[self] and attributestorage[self][key]
        end
    }
end

if oldminor < 3 then
    lib.domt.__newindex = function(self, key, value)
        if not attributestorage[self] then attributestorage[self] = {} end
        if attributestorage[self][key] == value then return end
        attributestorage[self][key] = value
        local name = namestorage[self]
        if name then
            callbacks:Fire("LibDataBroker_AttributeChanged", name, key, value,
                           self)
            callbacks:Fire("LibDataBroker_AttributeChanged_" .. name, name, key,
                           value, self)
            callbacks:Fire("LibDataBroker_AttributeChanged_" .. name .. "_" ..
                               key, name, key, value, self)
            callbacks:Fire("LibDataBroker_AttributeChanged__" .. key, name, key,
                           value, self)
        end
    end
end

if oldminor < 2 then
    function lib:NewDataObject(name, dataobj)
        if proxystorage[name] then return end

        if dataobj then
            assert(type(dataobj) == "table",
                   "Invalid dataobj, must be nil or a table")
            attributestorage[dataobj] = {}
            for i, v in pairs(dataobj) do
                attributestorage[dataobj][i] = v
                dataobj[i] = nil
            end
        end
        dataobj = dataobj or {}
        proxystorage[name] = dataobj
        namestorage[dataobj] = name
        setmetatable(dataobj, lib.domt)
        callbacks:Fire("LibDataBroker_DataObjectCreated", name, dataobj)
        return dataobj
    end
end

if oldminor < 1 then
    function lib:DataObjectIterator() return pairs(proxystorage) end

    function lib:GetDataObjectByName(dataobjectname)
        return proxystorage[dataobjectname]
    end

    function lib:GetNameByDataObject(dataobject)
        return namestorage[dataobject]
    end
end

if oldminor < 4 then
    local next = pairs(attributestorage)
    function lib:pairs(dataobject_or_name)
        local t = type(dataobject_or_name)
        assert(t == "string" or t == "table",
               "Usage: ldb:pairs('dataobjectname') or ldb:pairs(dataobject)")
        local dataobj = t == "string" and proxystorage[dataobject_or_name] or
                            dataobject_or_name
        assert(attributestorage[dataobj], "Data object not found")
        return next, attributestorage[dataobj], nil
    end

    local ipairs_iter = ipairs({})
    function lib:ipairs(dataobject_or_name)
        local t = type(dataobject_or_name)
        assert(t == "string" or t == "table",
               "Usage: ldb:ipairs('dataobjectname') or ldb:ipairs(dataobject)")
        local dataobj = t == "string" and proxystorage[dataobject_or_name] or
                            dataobject_or_name
        assert(attributestorage[dataobj], "Data object not found")
        return ipairs_iter, attributestorage[dataobj], 0
    end
end
