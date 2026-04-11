-- ui/setup.lua
-- Text-mode first-run wizard. No Basalt dependency.
-- Collects role, node_id, channel, controller_id, monitor side, speaker side,
-- shared_secret, and controller-specific threshold/auto-ctrl settings.
-- Writes enmon.cfg and returns the loaded config module.

local config = require("lib/config")
local pmgr   = require("lib/peripheral_mgr")

local setup = {}

local function cls() term.clear(); term.setCursorPos(1, 1) end

local function header()
    local w = term.getSize()
    term.setTextColor(colors.yellow)
    print(string.rep("=", w))
    print("  ENMON  -  Energy Network Monitor  -  Setup")
    print(string.rep("=", w))
    term.setTextColor(colors.white)
    print()
end

local function prompt(msg, default)
    term.setTextColor(colors.cyan)
    io.write(msg)
    if default ~= nil then io.write(" [" .. tostring(default) .. "]") end
    io.write(": ")
    term.setTextColor(colors.white)
    local input = io.read()
    if input == nil or input == "" then return default end
    return input
end

local function promptNumber(msg, default, min, max)
    while true do
        local raw = prompt(msg, default)
        local n = tonumber(raw)
        if n and (not min or n >= min) and (not max or n <= max) then
            return n
        end
        term.setTextColor(colors.red)
        print("  Please enter a number" ..
            (min and max and string.format(" between %d and %d.", min, max) or "."))
        term.setTextColor(colors.white)
    end
end

local function promptYesNo(msg, default)
    local d = default and "y" or "n"
    while true do
        local raw = prompt(msg .. " (y/n)", d):lower()
        if raw == "y" or raw == "yes"  then return true  end
        if raw == "n" or raw == "no"   then return false end
        term.setTextColor(colors.red)
        print("  Please enter y or n.")
        term.setTextColor(colors.white)
    end
end

local function pickRole()
    local roles = {
        { key = "1", id = "controller", label = "Controller  (monitor + modem + optional speaker)" },
        { key = "2", id = "matrix",     label = "Matrix Node (induction port + ender modem)"      },
        { key = "3", id = "reactor",    label = "Reactor Node (extreme reactor port + ender modem)"},
        { key = "4", id = "display",    label = "Display Node (monitor + ender modem)"            },
        { key = "5", id = "pocket",     label = "Pocket Computer (ender modem only)"              },
    }
    print("Select this computer's role:")
    print()
    for _, r in ipairs(roles) do
        term.setTextColor(colors.cyan)
        io.write("  [" .. r.key .. "] ")
        term.setTextColor(colors.white)
        print(r.label)
    end
    print()

    while true do
        local choice = prompt("Enter number")
        for _, r in ipairs(roles) do
            if choice == r.key then return r.id end
        end
        term.setTextColor(colors.red)
        print("  Invalid choice.")
        term.setTextColor(colors.white)
    end
end

local function pickMonitorSide()
    -- List available monitors so the user can verify
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            found[#found + 1] = name
        end
    end
    if #found == 0 then
        term.setTextColor(colors.red)
        print("  WARNING: No monitor detected. Make sure it is connected.")
        term.setTextColor(colors.white)
    else
        term.setTextColor(colors.green)
        io.write("  Detected monitors: ")
        print(table.concat(found, ", "))
        term.setTextColor(colors.white)
    end
    return prompt("Monitor peripheral name/side", found[1] or "top")
end

local function pickSpeakerSide()
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "speaker" then
            found[#found + 1] = name
        end
    end
    if #found > 0 then
        term.setTextColor(colors.green)
        io.write("  Detected speakers: ")
        print(table.concat(found, ", "))
        term.setTextColor(colors.white)
        local use = promptYesNo("Use speaker for alerts?", true)
        if use then return prompt("Speaker peripheral name/side", found[1]) end
    end
    return nil
end

function setup.run()
    cls()
    header()

    print("This wizard will configure this computer's role in the ENMON network.")
    print("Results are saved to enmon.cfg.")
    print()

    local role = pickRole()
    config.set("role", role)

    -- Node ID
    local default_id = role .. "_" .. tostring(os.getComputerID())
    local node_id = prompt("Node ID (unique name for this node)", default_id)
    config.set("node_id", node_id)

    -- Channel
    local channel = promptNumber("Network channel", 42, 1, 65535)
    config.set("channel", channel)

    -- Shared secret
    print()
    term.setTextColor(colors.yellow)
    print("  All nodes must share the same secret for HMAC authentication.")
    term.setTextColor(colors.white)
    local secret = prompt("Shared secret", "enmon_default")
    config.set("shared_secret", secret)

    -- Controller ID (non-controller nodes need to know where to send data)
    if role ~= "controller" then
        print()
        local ctrl_id = promptNumber("Controller computer ID", nil, 0)
        config.set("controller_id", ctrl_id)
    end

    -- Monitor side (controller + display)
    if role == "controller" or role == "display" then
        print()
        local mon = pickMonitorSide()
        config.set("monitor_side", mon)
    end

    -- Speaker (controller only)
    if role == "controller" then
        print()
        local spk = pickSpeakerSide()
        if spk then config.set("speaker_side", spk) end
    end

    -- Auto-control thresholds (controller only)
    if role == "controller" then
        print()
        print("-- Auto reactor control --")
        local auto = promptYesNo("Enable automatic reactor control based on matrix fill?", true)
        config.set("auto_ctrl", auto)
        if auto then
            local lo = promptNumber("Start reactor when matrix below (%):", 25, 1, 99) / 100
            local hi = promptNumber("Stop reactor when matrix above (%): ", 90, 1, 99) / 100
            config.set("threshold_low",  lo)
            config.set("threshold_high", hi)
        end
    end

    -- Save
    config.save()

    print()
    term.setTextColor(colors.green)
    print("  Configuration saved to enmon.cfg.")
    term.setTextColor(colors.white)
    print()

    local launch = promptYesNo("Start ENMON now?", true)
    return launch
end

return setup
