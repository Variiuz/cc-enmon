local pmgr = require("lib/peripheral_mgr")

local peripheral_logic = {}

local REACTOR_TYPES = {
    "BigReactors-Reactor",
    "bigger_reactors:reactor_access_port",
    "bigreactors:reactor_access_port",
}

local function clamp(value, min_value, max_value)
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end

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

local function collectControlRodLevels(port, count)
    if type(count) ~= "number" or count <= 0 then return nil end

    for _, base in ipairs({0, 1}) do
        local levels = {}
        local complete = true
        for index = 1, count do
            local value, _, err = callOptional(port, "getControlRodLevel", base + index - 1)
            if err or value == nil then
                complete = false
                break
            end
            levels[index] = tonumber(value) or 0
        end
        if complete then
            return levels
        end
    end

    return nil
end

local function average(values)
    if type(values) ~= "table" or #values == 0 then return nil end
    local total = 0
    for _, value in ipairs(values) do
        total = total + (tonumber(value) or 0)
    end
    return total / #values
end

function peripheral_logic.findReactor(boundName)
    if type(boundName) == "string" and boundName ~= "" then
        local port = pmgr.wrap(boundName)
        if port then
            return port, peripheral.getType(boundName) or boundName
        end
    end

    for _, type_name in ipairs(REACTOR_TYPES) do
        local port = pmgr.find(type_name)
        if port then return port, type_name end
    end
    return nil, nil
end

function peripheral_logic.waitForReactor(logLine, boundName)
    if logLine then
        logLine("[reactor] Waiting for reactor peripheral...", colors.orange)
    end
    while true do
        local port, type_name = peripheral_logic.findReactor(boundName)
        if port then
            if logLine then
                if boundName and type_name then
                    logLine("[reactor] Using bound peripheral: " .. tostring(boundName), colors.lime)
                else
                    logLine("[reactor] Found: " .. tostring(type_name), colors.lime)
                end
            end
            return port
        end
        if boundName and logLine then
            logLine("[reactor] Bound peripheral missing (" .. tostring(boundName) .. "); waiting / falling back", colors.orange)
            boundName = nil
        end
        os.sleep(1)
    end
end

function peripheral_logic.pollReactor(port)
    local active, active_err = callOptional(port, { "getActive", "active" })
    local produced = callOptional(port, { "getEnergyProducedLastTick", "getOutputLastTick" })

    if active_err then return nil, active_err end

    -- Do not fall back to capacity: that makes fill look ~100% and breaks auto-control.
    local energy_stored = callOptional(port, { "getEnergyStored" })
    local fuel_temp = callOptional(port, { "getFuelTemperature", "getTemperature" })
    local casing_temp = callOptional(port, { "getCasingTemperature" })
    local fuel_amount = callOptional(port, { "getFuelAmount" })
    local fuel_max = callOptional(port, { "getFuelAmountMax" })
    local waste_amount = callOptional(port, { "getWasteAmount" })
    local fuel_consumed_last_t = callOptional(port, { "getFuelConsumedLastTick" })
    local control_rod_count = callOptional(port, { "getNumberOfControlRods" })
    local connected = callOptional(port, { "getConnected" })
    local levels = nil
    if tonumber(control_rod_count) and tonumber(control_rod_count) > 0 then
        levels = collectControlRodLevels(port, tonumber(control_rod_count))
    end

    fuel_amount = tonumber(fuel_amount) or 0
    fuel_max = tonumber(fuel_max) or 0

    return {
        active = active == true,
        produced_last_t = tonumber(produced) or 0,
        energy_stored = tonumber(energy_stored) or 0,
        fuel_temp = tonumber(fuel_temp) or nil,
        casing_temp = tonumber(casing_temp) or nil,
        fuel_amount = fuel_amount,
        fuel_amount_max = fuel_max,
        fuel_fill = fuel_max > 0 and clamp(fuel_amount / fuel_max, 0, 1) or nil,
        waste_amount = tonumber(waste_amount) or 0,
        fuel_consumed_last_t = tonumber(fuel_consumed_last_t) or 0,
        control_rod_count = tonumber(control_rod_count) or 0,
        control_rod_level = average(levels),
        connected = connected == nil and nil or connected == true,
    }, nil
end

function peripheral_logic.applyCommand(port, payload, logLine)
    payload = payload or {}
    local changed = false

    local want_active = payload.active
    if want_active ~= nil then
        if type(want_active) ~= "boolean" then
            logLine("[reactor] Ignoring malformed CMD_REACTOR_SET (active must be bool)", colors.red)
        else
            local _, err = pmgr.call(port, "setActive", want_active)
            if err then
                logLine("[reactor] setActive failed: " .. tostring(err), colors.red)
            else
                logLine("[reactor] setActive(" .. tostring(want_active) .. ") OK", colors.lightBlue)
                changed = true
            end
        end
    end

    local target_level = payload.control_rod_level
    if target_level ~= nil then
        local normalized = tonumber(target_level)
        if not normalized then
            logLine("[reactor] Ignoring malformed CMD_REACTOR_SET (control_rod_level must be number)", colors.red)
        else
            normalized = math.floor(clamp(normalized, 0, 100) + 0.5)
            local _, method, err = callOptional(port, { "setAllControlRodLevels" }, normalized)
            if not method then
                local rod_count = tonumber(callOptional(port, { "getNumberOfControlRods" })) or 0
                local applied = false
                if rod_count > 0 then
                    for _, base in ipairs({0, 1}) do
                        local complete = true
                        for index = 1, rod_count do
                            local _, set_err = pmgr.call(port, "setControlRodLevel", base + index - 1, normalized)
                            if set_err then
                                complete = false
                                break
                            end
                        end
                        if complete then
                            applied = true
                            break
                        end
                    end
                end
                if not applied then
                    logLine("[reactor] set control rods failed: " .. tostring(err or "unsupported"), colors.red)
                else
                    logLine("[reactor] control rods -> " .. tostring(normalized) .. "%", colors.lightBlue)
                    changed = true
                end
            else
                logLine("[reactor] control rods -> " .. tostring(normalized) .. "%", colors.lightBlue)
                changed = true
            end
        end
    end

    if not changed then
        logLine("[reactor] CMD_REACTOR_SET produced no valid changes", colors.orange)
    end
end

return peripheral_logic