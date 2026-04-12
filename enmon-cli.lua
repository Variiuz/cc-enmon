-- enmon-cli.lua
-- Dedicated CLI entrypoint for ENMON maintenance commands.

local _dir = fs.getDir(shell.getRunningProgram())
if _dir == "" then _dir = "/" end
package.path = _dir .. "/?.lua;" .. _dir .. "/?/init.lua;" .. package.path

local args = {...}

local config = require("lib/config")
local updater = require("lib/updater")
local version = require("lib/version")

local VERSION = version.getVersion()

local function println(text, color)
    if color then
        term.setTextColor(color)
    end
    print(tostring(text or ""))
    term.setTextColor(colors.white)
end

local function logLine(message)
    println("[ENMON CLI] " .. tostring(message), colors.lightBlue)
end

local function fatal(msg)
    println("[ENMON CLI] ERROR: " .. tostring(msg), colors.red)
    error(msg, 0)
end

local function showUsage()
    println("ENMON CLI " .. tostring(VERSION), colors.cyan)
    println("Usage: enmon-cli <command>")
    println("Commands:")
    println("  update        Refresh only if remote version is newer")
    println("  update force  Reapply files even if the version is unchanged")
end

local resumed, resumeErr = updater.resumeInterruptedUpdate(function(message)
    logLine(message)
end)

if not resumed then
    fatal("Interrupted update recovery failed: " .. tostring(resumeErr))
end

local command = args[1]
if not command or command == "help" or command == "--help" or command == "-h" then
    showUsage()
    return
end

if command ~= "update" then
    fatal("Unknown command: " .. tostring(command))
end

if not config.exists() then
    fatal("No configuration found. Run installer.lua first.")
end
config.load()

local forceUpdate = args[2] == "force" or args[2] == "--force"

println("ENMON CLI " .. tostring(VERSION), colors.cyan)
println("Role: " .. tostring(config.get("role")))
println("Mode: " .. (forceUpdate and "Force" or "Normal"))
println("Checking for updates...")

local ok, result = updater.applyLocalUpdate({
    role = config.get("role"),
    force = forceUpdate,
    logger = function(message)
        logLine(message)
    end,
})

if not ok then
    fatal("Update failed: " .. tostring(result))
end

if not result.updated then
    println("Already up to date.", colors.lime)
    return
end

println("Updated: " .. tostring(result.from_version) .. " -> " .. tostring(result.to_version), colors.lime)
println("Rebooting...")
os.sleep(0.3)
os.reboot()