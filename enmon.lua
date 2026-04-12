-- enmon.lua
-- Entry point for ENMON - Energy Network Monitor.
-- Run this file directly (or via startup.lua).
-- Reads enmon.cfg written by installer.lua and dispatches to the role module.
-- If no config exists, print an error and exit (run installer.lua first).

-- Inject the script's directory into the package path so require() works
-- regardless of where the file lives on the CC filesystem.
local _dir = fs.getDir(shell.getRunningProgram())
if _dir == "" then _dir = "/" end
package.path = _dir .. "/?.lua;" .. _dir .. "/?/init.lua;" .. package.path

local args = {...}

local config = require("lib/config")
local updater = require("lib/updater")
local version = require("lib/version")

local resumed, resumeErr = updater.resumeInterruptedUpdate()

local runtime_panel = require("ui/runtime_panel")

local VERSION = version.getVersion()

local function cls() term.clear(); term.setCursorPos(1, 1) end

local boot_ui = nil

local function fatal(msg)
    if boot_ui then
        boot_ui.setSection("Fatal Error")
        boot_ui.setSummary({
            { "Version", VERSION },
            { "Computer", tostring(os.getComputerID()) },
            { "Error", tostring(msg), colors.red, colors.white },
        })
        boot_ui.setHint("Press any key to exit")
        os.pullEvent("key")
    else
        term.setTextColor(colors.red)
        print("[ENMON] FATAL: " .. tostring(msg))
        term.setTextColor(colors.white)
        print("Press any key to exit.")
        os.pullEvent("key")
    end
    error(msg, 0)
end

-- ── Bootstrap ──────────────────────────────────────────────────────────────────
cls()
boot_ui = runtime_panel.new("Launcher")
boot_ui.setSummary({
    { "Version", VERSION },
    { "Computer", tostring(os.getComputerID()) },
    { "Status", "Loading configuration..." },
})
boot_ui.setHint("Run installer.lua if this node is not configured")

if not resumed then
    fatal("Interrupted update recovery failed: " .. tostring(resumeErr))
end

-- First run: no config found
if not config.exists() then
    boot_ui.setSection("Configuration Missing")
    boot_ui.setSummary({
        { "Version", VERSION },
        { "Computer", tostring(os.getComputerID()) },
        { "Status", "No configuration found", colors.red, colors.white },
    })
    boot_ui.setHint("Run installer.lua to set up this node")
    return
end
config.load()

if args[1] == "update" then
    boot_ui.setSection("Updater")
    boot_ui.setSummary({
        { "Version", VERSION },
        { "Role", tostring(config.get("role")) },
        { "Status", "Checking for updates..." },
    })
    boot_ui.setHint("Local self-update from manifest")

    local ok, result = updater.applyLocalUpdate({
        role = config.get("role"),
        logger = function(message)
            if boot_ui then
                boot_ui.log(message, colors.lightBlue)
            end
        end,
    })

    if not ok then
        fatal("Update failed: " .. tostring(result))
    end

    if not result.updated then
        boot_ui.setSummary({
            { "Version", VERSION },
            { "Role", tostring(config.get("role")) },
            { "Status", "Already up to date", colors.lime, colors.white },
        })
        boot_ui.setHint("Press any key to exit")
        os.pullEvent("key")
        return
    end

    boot_ui.setSummary({
        { "From", tostring(result.from_version) },
        { "To", tostring(result.to_version) },
        { "Status", "Update complete - rebooting", colors.lime, colors.white },
    })
    os.sleep(0.3)
    os.reboot()
end

-- ── Role dispatch ──────────────────────────────────────────────────────────────
local role = config.get("role")
if not role then
    fatal("No role configured. Delete enmon.cfg and re-run to reconfigure.")
end

local role_modules = {
    controller = "nodes/controller",
    matrix     = "nodes/matrix",
    reactor    = "nodes/reactor",
    display    = "nodes/display",
    pocket     = "nodes/pocket",
}

local mod_path = role_modules[role]
if not mod_path then
    fatal("Unknown role: " .. tostring(role))
end

boot_ui.setSection("Launching")
boot_ui.setSummary({
    { "Version", VERSION },
    { "Role", tostring(role) },
    { "Node", tostring(config.get("node_id")) },
    { "Channel", tostring(config.get("channel")) },
})
boot_ui.setHint("Preparing runtime UI...")

-- Small delay so the user can read the role line before UI takes over
os.sleep(0.5)

local ok, err = pcall(function()
    local node = require(mod_path)
    node.run(config)
end)

if not ok then
    fatal("Node crashed: " .. tostring(err))
end
