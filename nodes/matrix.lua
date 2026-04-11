-- nodes/matrix.lua
-- Induction Matrix sensor node.
-- Wraps the Mekanism induction_port peripheral, polls data every 2 seconds,
-- and broadcasts MATRIX_DATA to the network.
--
-- Expected config keys: node_id, channel, shared_secret
-- Hardware: ender modem + wired connection to induction_port

local net  = require("lib/network")
local pmgr = require("lib/peripheral_mgr")
local util = require("lib/util")

local POLL_INTERVAL = 2   -- seconds between broadcasts
local MODEM_TYPE    = "ender_modem"
-- Known peripheral type strings for Mekanism induction port across versions
local MATRIX_TYPES  = {
    "mekanism:induction_port",
    "inductionPort",
    "mekanism.induction_port",
}

local matrix = {}

-- Try each known type string, validating the peripheral actually responds.
-- Falls back to scanning all peripherals for any with the Mekanism energy API.
local function findInductionPort()
    for _, t in ipairs(MATRIX_TYPES) do
        local p = pmgr.find(t)
        -- Confirm it actually responds (peripheral.find can return stale entries)
        if p and pcall(p.getEnergy, p) then return p end
    end
    -- Method-based fallback: scan everything, require getEnergy + some capacity method
    for _, name in ipairs(peripheral.getNames()) do
        local ok, p = pcall(peripheral.wrap, name)
        if ok and p and type(p.getEnergy) == "function" then
            local has_cap = type(p.getMaxEnergy)      == "function"
                         or type(p.getEnergyCapacity) == "function"
            local responds = pcall(p.getEnergy, p)
            if has_cap and responds then
                print("[matrix] Found induction port via method scan: " .. name)
                return p
            end
        end
    end
    return nil
end

local function waitForPort()
    while true do
        local p = findInductionPort()
        if p then return p end
        os.sleep(1)
    end
end

local function findModem()
    local m = pmgr.find(MODEM_TYPE)
    if not m then
        -- Fallback: any wireless modem
        m = pmgr.find("modem")
    end
    return m
end

local function openNet(cfg)
    local modem = findModem()
    if not modem then
        error("No ender modem found. Attach one and reboot.")
    end
    net.open(modem, cfg.get("channel"), cfg.get("shared_secret"), cfg.get("node_id"))
end

local function pollMatrix(port)
    -- Energy stored — required
    local energy, e_err = pmgr.call(port, "getEnergy")
    if e_err then return nil, e_err end

    -- Max capacity: Mekanism <10 uses getMaxEnergy, >=10 uses getEnergyCapacity
    local maxEnergy = pmgr.call(port, "getMaxEnergy")
    if maxEnergy == nil then
        maxEnergy = pmgr.call(port, "getEnergyCapacity")
    end

    -- I/O rates: soft-fail if absent in this modpack version
    local lastInput  = pmgr.call(port, "getLastInput")  or 0
    local lastOutput = pmgr.call(port, "getLastOutput") or 0

    return {
        energy      = energy     or 0,
        max_energy  = maxEnergy  or 0,
        last_input  = lastInput,
        last_output = lastOutput,
    }, nil
end

function matrix.run(cfg)
    print("[matrix] Starting matrix node: " .. cfg.get("node_id"))

    openNet(cfg)

    -- Wait for the induction port to become available
    print("[matrix] Waiting for induction port...")
    local port = waitForPort()
    if not port then
        error("Induction port not found.")
    end
    print("[matrix] Induction port connected. Broadcasting every " .. POLL_INTERVAL .. "s.")

    local consecutive_errors = 0
    local MAX_ERRORS = 10

    while true do
        local data, err = pollMatrix(port)

        if data then
            consecutive_errors = 0
            net.send(net.MSG.MATRIX_DATA, data)
        else
            consecutive_errors = consecutive_errors + 1
            print("[matrix] Poll error (" .. consecutive_errors .. "): " .. tostring(err))

            if consecutive_errors >= MAX_ERRORS then
                -- Peripheral likely disconnected; attempt to reconnect
                print("[matrix] Too many errors — waiting for induction port to reconnect...")
                port = waitForPort()
                if port then
                    consecutive_errors = 0
                    print("[matrix] Reconnected.")
                end
            end
        end

        os.sleep(POLL_INTERVAL)
    end
end

return matrix
