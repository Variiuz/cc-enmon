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
    println("  reinstall     Alias of update force")
    println("  verify        Compare local files against the remote manifest")
    println("Flags:")
    println("  --yes         Skip confirmation prompts for update/reinstall")
end

local function hasArg(name)
    for _, value in ipairs(args) do
        if value == name then
            return true
        end
    end
    return false
end

local function confirmPrompt(lines)
    for _, line in ipairs(lines or {}) do
        println(line, colors.orange)
    end
    print("Proceed? [y/N]: ")
    local answer = read()
    answer = tostring(answer or ""):lower()
    return answer == "y" or answer == "yes"
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

if command ~= "update" and command ~= "reinstall" and command ~= "verify" then
    fatal("Unknown command: " .. tostring(command))
end

if not config.exists() then
    fatal("No configuration found. Run installer.lua first.")
end
config.load()

local forceUpdate = command == "reinstall" or hasArg("force") or hasArg("--force")
local assumeYes = hasArg("--yes") or hasArg("-y")

println("ENMON CLI " .. tostring(VERSION), colors.cyan)
println("Role: " .. tostring(config.get("role")))
if command == "verify" then
    println("Mode: Verify")
    println("Comparing local files against the remote manifest...")

    local ok, result = updater.verifyLocalInstallation({
        role = config.get("role"),
        logger = function(message)
            logLine(message)
        end,
    })

    if not ok then
        fatal("Verify failed: " .. tostring(result))
    end

    println("Installed version: " .. tostring(result.current_version))
    println("Remote version:    " .. tostring(result.latest_version))
    if result.needs_update then
        println("Update available: yes", colors.orange)
    else
        println("Update available: no", colors.lime)
    end

    if #result.missing > 0 then
        println("Missing files:", colors.red)
        for _, path in ipairs(result.missing) do
            println("  - " .. tostring(path), colors.red)
        end
    end

    if #result.mismatched > 0 then
        println("Changed files:", colors.orange)
        for _, path in ipairs(result.mismatched) do
            println("  - " .. tostring(path), colors.orange)
        end
    end

    if #result.stale > 0 then
        println("Stale managed files:", colors.orange)
        for _, path in ipairs(result.stale) do
            println("  - " .. tostring(path), colors.orange)
        end
    end

    if result.ok then
        println("Verification OK: local files match the remote manifest.", colors.lime)
        return
    end

    println("Verification failed: reinstall or update is recommended.", colors.red)
    error("verification failed", 0)
end

println("Mode: " .. (forceUpdate and "Force/Reinstall" or "Normal"))
println(command == "reinstall" and "Preparing reinstall from manifest..." or "Checking for updates...")

local info, infoErr = updater.checkForUpdate(config.get("role"), nil, forceUpdate)
if not info then
    fatal("Update check failed: " .. tostring(infoErr))
end

println("Installed version: " .. tostring(info.current_version))
println("Remote version:    " .. tostring(info.latest_version))

if not info.needs_update then
    println("Already up to date.", colors.lime)
    return
end

local confirmLines
if forceUpdate then
    confirmLines = {
        "About to reapply managed files from the remote manifest.",
        "This can overwrite local ENMON changes.",
    }
else
    confirmLines = {
        "About to update this node from " .. tostring(info.current_version) .. " to " .. tostring(info.latest_version) .. ".",
        "The computer will reboot after a successful update.",
    }
end

if not assumeYes and not confirmPrompt(confirmLines) then
    println("Update cancelled.", colors.orange)
    return
end

println(forceUpdate and "Reapplying files..." or "Downloading and applying update...")

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