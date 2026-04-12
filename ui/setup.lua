-- ui/setup.lua
-- Text-mode first-run wizard. No Basalt dependency.
-- Collects role, node_id, channel, hardware bindings, and controller-specific
-- threshold/auto-ctrl/update-check settings.
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

local function pickModemSide()
    local wireless = pmgr.listWirelessModems()
    local found = pmgr.listModems()
    if #wireless == 1 then
        term.setTextColor(colors.green)
        print("  Auto-selected ender modem: " .. pmgr.describeModem(wireless[1]))
        term.setTextColor(colors.white)
        return wireless[1]
    end

    if #found == 0 then
        term.setTextColor(colors.red)
        print("  WARNING: No modem detected. Make sure the ender modem is attached.")
        term.setTextColor(colors.white)
        return prompt("Ender modem side/name", "top")
    end

    term.setTextColor(colors.green)
    print("  Detected modems:")
    for _, name in ipairs(found) do
        print("    - " .. pmgr.describeModem(name))
    end
    term.setTextColor(colors.white)
    if #wireless > 1 then
        print("  Multiple wireless-class modems were found. Choose the ender modem side ENMON should use.")
        return prompt("Ender modem side/name", wireless[1])
    end

    print("  No wireless-class modem was detected automatically. Enter the ender modem side/name manually.")
    return prompt("Ender modem side/name", found[1])
end

-- Check that the peripherals required for a given role are present.
-- Prints warnings but does not block — lets the user proceed and fix later.
local ROLE_REQUIREMENTS = {
    controller = {
        { types = {"ender_modem", "modem"},               label = "Ender modem",       required = true  },
        { types = {"monitor"},                             label = "Monitor",            required = true  },
        { types = {"speaker"},                             label = "Speaker (optional)", required = false },
    },
    matrix = {
        { types = {"ender_modem", "modem"},               label = "Ender modem",        required = true },
        { types = {"mekanism:induction_port"},            label = "Induction Port",      required = true },
    },
    reactor = {
        { types = {"ender_modem", "modem"},               label = "Ender modem",         required = true },
        { types = {"BigReactors-Reactor",
                   "bigger_reactors:reactor_access_port",
                   "bigreactors:reactor_access_port"},    label = "Reactor Port",        required = true },
    },
    display = {
        { types = {"ender_modem", "modem"},               label = "Ender modem",         required = true },
        { types = {"monitor"},                            label = "Monitor",             required = true },
    },
    pocket = {
        { types = {"ender_modem", "modem"},               label = "Ender modem",         required = true },
    },
}

local function checkPeripherals(role)
    local reqs = ROLE_REQUIREMENTS[role]
    if not reqs then return end

    -- Build a flat set of all connected peripheral types
    local connected = {}
    for _, name in ipairs(peripheral.getNames()) do
        local t = peripheral.getType(name)
        if t then connected[t] = true end
    end

    print()
    term.setTextColor(colors.yellow)
    print("-- Peripheral check for role: " .. role .. " --")
    term.setTextColor(colors.white)

    local any_missing = false
    for _, req in ipairs(reqs) do
        local found = false
        for _, t in ipairs(req.types) do
            if connected[t] then found = true; break end
        end
        if found then
            term.setTextColor(colors.green)
            print("  [OK]   " .. req.label)
        elseif req.required then
            term.setTextColor(colors.red)
            print("  [MISS] " .. req.label .. "  <-- REQUIRED")
            any_missing = true
        else
            term.setTextColor(colors.yellow)
            print("  [--]   " .. req.label .. "  (not connected)")
        end
    end
    term.setTextColor(colors.white)

    if any_missing then
        print()
        term.setTextColor(colors.red)
        print("  WARNING: Required peripherals are missing.")
        print("  Connect them and reboot before running ENMON.")
        term.setTextColor(colors.white)
        print()
        local cont = promptYesNo("Continue setup anyway?", false)
        if not cont then
            print("Setup cancelled. Reconnect peripherals and re-run enmon.lua.")
            error("peripheral check failed", 0)
        end
    end
    print()
end

function setup.run()
    cls()
    header()

    print("This wizard will configure this computer's role in the ENMON network.")
    print("Results are saved to enmon.cfg.")
    print()

    local role = pickRole()
    config.set("role", role)

    checkPeripherals(role)

    -- Node ID
    local default_id = role .. "_" .. tostring(os.getComputerID())
    local node_id = prompt("Node ID (unique name for this node)", default_id)
    config.set("node_id", node_id)

    -- Channel
    local channel = promptNumber("Network channel", 42, 1, 65535)
    config.set("channel", channel)

    print()
    local modem_side = pickModemSide()
    config.set("modem_side", modem_side)

    if role ~= "controller" then
        print()
        term.setTextColor(colors.yellow)
        print("  This node will appear as unlinked on the chosen channel until a controller adopts it.")
        print("  No controller ID or shared secret is required during setup.")
        term.setTextColor(colors.white)
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

        print()
        print("-- Automatic update checks --")
        local interval = promptNumber("Manifest check interval in seconds", 90, 15)
        config.set("update_check_interval", interval)
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
