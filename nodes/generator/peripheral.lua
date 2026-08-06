local pmgr = require("lib/peripheral_mgr")

local peripheral_logic = {}

local GENERATOR_TYPES = {
    "diesel_generator",
    "ie_diesel_generator",
    "capacitor_lv",
    "capacitor_mv",
    "capacitor_hv",
}

local function callOptional(port, methods, ...)
    local names = type(methods) == "table" and methods or { methods }
    local last_err = nil
    for _, method in ipairs(names) do
        local value, err = pmgr.call(port, method, ...)
        if not err then
            return value, method, nil
        end
        if not tostring(err):find("missing method", 1, true) then
            last_err = err
        end
    end
    return nil, nil, last_err
end

function peripheral_logic.findGenerator(logLine, boundName)
    if type(boundName) == "string" and boundName ~= "" then
        local port = pmgr.wrap(boundName)
        if port then
            if logLine then
                logLine("[generator] Using bound peripheral: " .. boundName, colors.lime)
            end
            return port, peripheral.getType(boundName) or boundName
        end
        if logLine then
            logLine("[generator] Bound peripheral missing (" .. boundName .. "); falling back to auto-find", colors.orange)
        end
    end

    for _, type_name in ipairs(GENERATOR_TYPES) do
        local port = pmgr.find(type_name)
        if port then
            if logLine then
                logLine("[generator] Found peripheral type: " .. type_name, colors.lime)
            end
            return port, type_name
        end
    end

    for _, name in ipairs(peripheral.getNames()) do
        local ok, port = pcall(peripheral.wrap, name)
        if ok and port then
            local controllable = type(port.setEnabled) == "function" or type(port.isActive) == "function" or type(port.isRunning) == "function"
            local energy = type(port.getEnergyStored) == "function"
            if controllable or energy then
                local ptype = peripheral.getType(name)
                local lower = string.lower(tostring(ptype or name))
                if lower:find("diesel", 1, true) or lower:find("generator", 1, true) or lower:find("capacitor", 1, true) then
                    if logLine then
                        logLine("[generator] Found via method scan: " .. name .. " (" .. tostring(ptype) .. ")", colors.lightBlue)
                    end
                    return port, ptype or name
                end
            end
        end
    end

    return nil, nil
end

function peripheral_logic.waitForGenerator(logLine, boundName)
    if logLine then
        logLine("[generator] Waiting for IE diesel generator / capacitor...", colors.orange)
        logLine("[generator] Note: Powah has no CC peripheral in this pack build.", colors.orange)
    end
    while true do
        local port, type_name = peripheral_logic.findGenerator(logLine, boundName)
        if port then
            return port, type_name
        end
        os.sleep(1)
    end
end

function peripheral_logic.pollGenerator(port)
    local active = callOptional(port, { "isActive", "isRunning", "getEnabled", "isEnabled" })
    local energy_stored = callOptional(port, { "getEnergyStored" })
    local energy_max = callOptional(port, { "getMaxEnergyStored" })
    local produced = callOptional(port, { "getEnergyProducedLastTick", "getAveragePower", "getOutputLastTick" })

    -- Capacitors: treat stored energy delta is not available; report capacity fill only.
    energy_stored = tonumber(energy_stored)
    energy_max = tonumber(energy_max)
    produced = tonumber(produced) or 0

    local is_active = active == true
    if active == nil and energy_stored ~= nil and energy_max ~= nil then
        -- Passive storage peripheral: "active" when not empty
        is_active = energy_stored > 0
    end

    return {
        active = is_active,
        produced_last_t = produced,
        energy_stored = energy_stored or 0,
        energy_capacity = energy_max or 0,
        controllable = type(port.setEnabled) == "function" or type(port.setActive) == "function",
    }, nil
end

function peripheral_logic.applyCommand(port, payload, logLine)
    payload = payload or {}
    local changed = false
    local want_active = payload.active

    if want_active ~= nil then
        if type(want_active) ~= "boolean" then
            logLine("[generator] Ignoring malformed CMD_GENERATOR_SET (active must be bool)", colors.red)
        else
            local _, method, err = callOptional(port, { "setEnabled", "setActive" }, want_active)
            if not method then
                logLine("[generator] setActive/setEnabled failed: " .. tostring(err or "unsupported"), colors.red)
            else
                logLine("[generator] " .. method .. "(" .. tostring(want_active) .. ") OK", colors.lightBlue)
                changed = true
            end
        end
    end

    if not changed then
        logLine("[generator] CMD_GENERATOR_SET produced no valid changes", colors.orange)
    end
end

return peripheral_logic
