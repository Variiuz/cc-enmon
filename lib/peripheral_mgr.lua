-- lib/peripheral_mgr.lua
-- Safe peripheral wrapping with reconnect support.
-- Decouples node code from hard peripheral crashes on disconnect.

local mgr = {}

-- Attempt to find and wrap a peripheral by type.
-- Returns the wrapped peripheral or nil if not found.
function mgr.find(ptype)
    local ok, p = pcall(peripheral.find, ptype)
    if ok and p then return p end
    return nil
end

-- Wrap a peripheral by name (side or modem name).
-- Returns the wrapped peripheral or nil on failure.
function mgr.wrap(name)
    if not peripheral.isPresent(name) then return nil end
    local ok, p = pcall(peripheral.wrap, name)
    if ok and p then return p end
    return nil
end

-- Find a peripheral by type, blocking until it appears or timeout (seconds) expires.
-- Pass timeout = nil to wait indefinitely.
-- Prints a waiting message while polling.
-- Returns the peripheral, or nil on timeout.
function mgr.waitFor(ptype, timeout)
    local deadline = timeout and (os.clock() + timeout) or nil
    while true do
        local p = mgr.find(ptype)
        if p then return p end
        if deadline and os.clock() >= deadline then return nil end
        os.sleep(1)
    end
end

-- Safe call on a peripheral method. Returns value, nil on success or nil, err on failure.
-- Automatically returns nil, "disconnected" if the peripheral is no longer present.
function mgr.call(p, method, ...)
    if not p then return nil, "no peripheral" end
    local ok, result = pcall(p[method], p, ...)
    if ok then
        return result, nil
    else
        return nil, result
    end
end

-- Returns a list of all connected peripheral names of a given type.
function mgr.listByType(ptype)
    local results = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == ptype then
            results[#results + 1] = name
        end
    end
    return results
end

return mgr
