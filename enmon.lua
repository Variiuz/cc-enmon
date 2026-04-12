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

local config = require("lib/config")
local updater = require("lib/updater")
local version = require("lib/version")

local resumed, resumeErr = updater.resumeInterruptedUpdate()

local runtime_panel = require("ui/runtime_panel")

local VERSION = version.getVersion()
local unpackArgs = table.unpack or unpack

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
boot_ui = runtime_panel.new("Launcher", { interactive_scroll = true })
boot_ui.setSummary({
    { "Version", VERSION },
    { "Computer", tostring(os.getComputerID()) },
    { "Status", "Loading configuration..." },
})
boot_ui.setHint("Run installer.lua if this node is not configured")

if not resumed then
    fatal("Interrupted update recovery failed: " .. tostring(resumeErr))
end

local args = {...}
if args[1] ~= nil then
    local ok, err = shell.run(fs.combine(_dir, "enmon-cli.lua"), unpackArgs(args))
    if ok == false then
        fatal("CLI command failed: " .. tostring(err))
    end
    return
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
