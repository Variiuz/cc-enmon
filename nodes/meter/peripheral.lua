local pmgr = require("lib/peripheral_mgr")

local peripheral_logic = {}

local METER_TYPES = {
    "energymeter",
    "current_transformer",
    "ie_current_transformer",
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

function peripheral_logic.findMeter(logLine, boundName)
    if type(boundName) == "string" and boundName ~= "" then
        local port = pmgr.wrap(boundName)
        if port then
            if logLine then
                logLine("[meter] Using bound peripheral: " .. boundName, colors.lime)
            end
            return port, peripheral.getType(boundName) or boundName
        end
        if logLine then
            logLine("[meter] Bound peripheral missing (" .. boundName .. "); falling back to auto-find", colors.orange)
        end
    end

    for _, type_name in ipairs(METER_TYPES) do
        local port = pmgr.find(type_name)
        if port then
            if logLine then
                logLine("[meter] Found peripheral type: " .. type_name, colors.lime)
            end
            return port, type_name
        end
    end

    for _, name in ipairs(peripheral.getNames()) do
        local ok, port = pcall(peripheral.wrap, name)
        if ok and port then
            local has_rate = type(port.getEnergyRate) == "function"
                or type(port.getAveragePower) == "function"
                or type(port.getTransferRate) == "function"
            if has_rate then
                local ptype = peripheral.getType(name)
                if logLine then
                    logLine("[meter] Found via method scan: " .. name .. " (" .. tostring(ptype) .. ")", colors.lightBlue)
                end
                return port, ptype or name
            end
        end
    end

    return nil, nil
end

function peripheral_logic.waitForMeter(logLine, boundName)
    if logLine then
        logLine("[meter] Waiting for energy meter peripheral...", colors.orange)
    end
    while true do
        local port, type_name = peripheral_logic.findMeter(logLine, boundName)
        if port then
            return port, type_name
        end
        os.sleep(1)
    end
end

function peripheral_logic.pollMeter(port)
    local rate = callOptional(port, { "getEnergyRate", "getAveragePower", "getTransferRate" })
    local total = callOptional(port, { "getTotalEnergy" })
    local limit = callOptional(port, { "getTransferLimit", "getTransferRateLimit" })
    local transfer_mode = callOptional(port, { "getTransferMode" })
    local measure_mode = callOptional(port, { "getMeasureMode" })
    local has_input = callOptional(port, { "hasInput" })
    local has_output = callOptional(port, { "hasOutput" })
    local status = callOptional(port, { "getConnectionStatus" })

    rate = tonumber(rate) or 0
    total = tonumber(total) or 0
    limit = tonumber(limit)

    return {
        rate = rate,
        total_energy = total,
        transfer_limit = limit,
        transfer_mode = transfer_mode,
        measure_mode = measure_mode,
        has_input = has_input == true,
        has_output = has_output == true,
        connection_status = status,
        -- Normalized aliases used by HUD / aggregation
        last_input = rate > 0 and rate or 0,
        last_output = rate < 0 and (-rate) or 0,
    }, nil
end

return peripheral_logic
