-- CallbackHandler-1.0
-- Callback registration and dispatching library
local MAJOR, MINOR = "CallbackHandler-1.0", 7
local CallbackHandler = LibStub:NewLibrary(MAJOR, MINOR)
if not CallbackHandler then return end

local meta = {
    __index = function(tbl, key)
        tbl[key] = {}
        return tbl[key]
    end
}

function CallbackHandler:New(target, RegisterName, UnregisterName,
                             UnregisterAllName)
    RegisterName = RegisterName or "RegisterCallback"
    UnregisterName = UnregisterName or "UnregisterCallback"
    UnregisterAllName = UnregisterAllName or "UnregisterAllCallbacks"

    local events = setmetatable({}, meta)
    local registry = {recurse = 0, events = events}

    function registry:Fire(eventname, ...)
        if not rawget(events, eventname) or not next(events[eventname]) then
            return
        end
        local oldrecurse = registry.recurse
        registry.recurse = oldrecurse + 1
        for selfarg, func in pairs(events[eventname]) do
            if type(func) == "string" then
                if type(selfarg[func]) == "function" then
                    selfarg[func](selfarg, eventname, ...)
                end
            elseif func then
                func(eventname, ...)
            end
        end
        registry.recurse = oldrecurse
    end

    target[RegisterName] = function(self, eventname, method, ...)
        if type(method) ~= "string" and type(method) ~= "function" then
            error("Usage: " .. RegisterName ..
                      "(eventname, \"methodname\") or (eventname, function)", 2)
        end
        if type(method) == "string" and type(self[method]) ~= "function" then
            error("Usage: " .. RegisterName ..
                      "(\"eventname\", \"methodname\"): '" .. method ..
                      "' - method not found on target object.", 2)
        end
        events[eventname][self] = method
    end

    target[UnregisterName] = function(self, eventname)
        if rawget(events, eventname) then events[eventname][self] = nil end
    end

    target[UnregisterAllName] = function(self)
        for eventname, callbacks in pairs(events) do
            callbacks[self] = nil
        end
    end

    return registry
end
