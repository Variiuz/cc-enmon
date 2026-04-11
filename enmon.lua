-- enmon.lua
-- Entry point for ENMON - Energy Network Monitor.
-- Run this file directly (or via startup.lua).
-- Reads enmon.cfg written by installer.lua and dispatches to the role module.
-- If no config exists, print an error and exit (run installer.lua first).

local VERSION = "0.1.0"

-- Inject the script's directory into the package path so require() works
-- regardless of where the file lives on the CC filesystem.
local _dir = fs.getDir(shell.getRunningProgram())
if _dir == "" then _dir = "/" end
package.path = _dir .. "/?.lua;" .. _dir .. "/?/init.lua;" .. package.path

local config = require("lib/config")

local function cls() term.clear(); term.setCursorPos(1, 1) end

local function fatal(msg)
    term.setTextColor(colors.red)
    print("[ENMON] FATAL: " .. tostring(msg))
    term.setTextColor(colors.white)
    print("Press any key to exit.")
    os.pullEvent("key")
    error(msg, 0)
end

-- ── Bootstrap ──────────────────────────────────────────────────────────────────
cls()
term.setTextColor(colors.yellow)
print("ENMON v" .. VERSION .. "  -  Energy Network Monitor")
term.setTextColor(colors.white)
print()

-- First run: no config found
if not config.exists() then
    term.setTextColor(colors.red)
    print("No configuration found.")
    print("Run installer.lua to set up this node.")
    term.setTextColor(colors.white)
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

term.setTextColor(colors.cyan)
print("Starting as: " .. role .. "  (node: " .. tostring(config.get("node_id")) .. ")")
term.setTextColor(colors.white)
print()

-- Small delay so the user can read the role line before UI takes over
os.sleep(0.5)

local ok, err = pcall(function()
    local node = require(mod_path)
    node.run(config)
end)

if not ok then
    fatal("Node crashed: " .. tostring(err))
end
