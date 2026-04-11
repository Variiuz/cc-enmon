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
local MATRIX_TYPE   = "mekanism:induction_port"

local matrix = {}

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
    local energy,   e_err = pmgr.call(port, "getEnergy")
    local maxEnergy, m_err = pmgr.call(port, "getMaxEnergy")
    local lastInput, i_err = pmgr.call(port, "getLastInput")
    local lastOutput,o_err = pmgr.call(port, "getLastOutput")

    if e_err or m_err then
        return nil, e_err or m_err
    end

    return {
        energy      = energy      or 0,
        max_energy  = maxEnergy   or 0,
        last_input  = lastInput   or 0,
        last_output = lastOutput  or 0,
    }, nil
end

function matrix.run(cfg)
    print("[matrix] Starting matrix node: " .. cfg.get("node_id"))

    openNet(cfg)

    -- Wait for the induction port to become available
    print("[matrix] Waiting for induction port...")
    local port = pmgr.waitFor(MATRIX_TYPE)
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
                port = pmgr.waitFor(MATRIX_TYPE)
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
