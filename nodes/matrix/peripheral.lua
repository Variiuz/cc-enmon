local pmgr = require("lib/peripheral_mgr")
local util = require("lib/util")

local peripheral_logic = {}

local MATRIX_TYPES = {
    "mekanism:induction_port",
    "inductionPort",
    "mekanism.induction_port",
}

function peripheral_logic.findInductionPort(logLine)
    for _, type_name in ipairs(MATRIX_TYPES) do
        local port = pmgr.find(type_name)
        if port then
            local energy = pmgr.call(port, "getEnergy")
            if energy ~= nil then return port end
        end
    end

    for _, name in ipairs(peripheral.getNames()) do
        local ok, port = pcall(peripheral.wrap, name)
        if ok and port and type(port.getEnergy) == "function" then
            local has_capacity = type(port.getMaxEnergy) == "function"
                or type(port.getEnergyCapacity) == "function"
            local responds = pmgr.call(port, "getEnergy") ~= nil
            if has_capacity and responds then
                if logLine then
                    logLine("[matrix] Found induction port via method scan: " .. name, colors.lightBlue)
                end
                return port
            end
        end
    end

    return nil
end

function peripheral_logic.waitForPort(logLine)
    while true do
        local port = peripheral_logic.findInductionPort(logLine)
        if port then return port end
        os.sleep(1)
    end
end

function peripheral_logic.pollMatrix(port)
    local energy, energy_err = pmgr.call(port, "getEnergy")
    if energy_err then return nil, energy_err end

    local max_energy = pmgr.call(port, "getMaxEnergy")
    if max_energy == nil then
        max_energy = pmgr.call(port, "getEnergyCapacity")
    end

    local last_input = pmgr.call(port, "getLastInput") or 0
    local last_output = pmgr.call(port, "getLastOutput") or 0

    return {
        energy = util.joulesToFe(energy or 0),
        max_energy = util.joulesToFe(max_energy or 0),
        last_input = util.joulesToFe(last_input or 0),
        last_output = util.joulesToFe(last_output or 0),
    }, nil
end

return peripheral_logic