-- enmon-cli.lua
-- Dedicated CLI entrypoint for ENMON maintenance commands.

local _dir = fs.getDir(shell.getRunningProgram())
if _dir == "" then _dir = "/" end
package.path = _dir .. "/?.lua;" .. _dir .. "/?/init.lua;" .. package.path

local args = {...}

local config = require("lib/config")
local updater = require("lib/updater")
local version = require("lib/version")
local runtime_panel = require("ui/runtime_panel")

local VERSION = version.getVersion()

local function cls() term.clear(); term.setCursorPos(1, 1) end

local cli_ui = nil

local function fatal(msg)
    if cli_ui then
        cli_ui.setSection("CLI Error")
        cli_ui.setSummary({
            { "Version", VERSION },
            { "Command", table.concat(args, " ") ~= "" and table.concat(args, " ") or "--" },
            { "Error", tostring(msg), colors.red, colors.white },
        })
        cli_ui.setHint("Press any key to exit")
        os.pullEvent("key")
    else
        term.setTextColor(colors.red)
        print("[ENMON CLI] ERROR: " .. tostring(msg))
        term.setTextColor(colors.white)
    end
    error(msg, 0)
end

local function showUsage()
    cli_ui.setSection("CLI Help")
    cli_ui.setSummary({
        { "Version", VERSION },
        { "Usage", "enmon-cli <command>" },
        { "Commands", "update [force]" },
    })
    cli_ui.log("update        Refresh only if remote version is newer", colors.lightBlue)
    cli_ui.log("update force  Reapply files even if the version is unchanged", colors.lightBlue)
    cli_ui.setHint("Press any key to exit")
    os.pullEvent("key")
end

cls()
cli_ui = runtime_panel.new("CLI", { interactive_scroll = true })
cli_ui.setSummary({
    { "Version", VERSION },
    { "Command", table.concat(args, " ") ~= "" and table.concat(args, " ") or "help" },
    { "Status", "Preparing..." },
})
cli_ui.setHint("F3 logs. Use enmon-cli update [force]")

local resumed, resumeErr = updater.resumeInterruptedUpdate(function(message)
    if cli_ui then
        cli_ui.log(message, colors.lightBlue)
    end
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

cli_ui.setSection("Updater")
cli_ui.setSummary({
    { "Version", VERSION },
    { "Role", tostring(config.get("role")) },
    { "Mode", forceUpdate and "Force" or "Normal" },
    { "Status", "Checking for updates..." },
})
cli_ui.setHint(forceUpdate and "Forced local self-update from manifest" or "Local self-update from manifest")

local ok, result = updater.applyLocalUpdate({
    role = config.get("role"),
    force = forceUpdate,
    logger = function(message)
        if cli_ui then
            cli_ui.log(message, colors.lightBlue)
        end
    end,
})

if not ok then
    fatal("Update failed: " .. tostring(result))
end

if not result.updated then
    cli_ui.setSummary({
        { "Version", VERSION },
        { "Role", tostring(config.get("role")) },
        { "Status", "Already up to date", colors.lime, colors.white },
    })
    cli_ui.setHint("Press any key to exit")
    os.pullEvent("key")
    return
end

cli_ui.setSummary({
    { "From", tostring(result.from_version) },
    { "To", tostring(result.to_version) },
    { "Status", "Update complete - rebooting", colors.lime, colors.white },
})
os.sleep(0.3)
os.reboot()