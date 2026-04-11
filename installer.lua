-- installer.lua
-- ENMON installer — run this first on any new computer.
--
-- Flow:
--   1. Select role
--   2. Peripheral check (non-blocking warnings)
--   3. Full config wizard (all questions for this role)
--   4. Download common + role-specific files
--   5. Download Basalt 2
--   6. Write enmon.cfg + startup.lua
--   7. Optionally launch ENMON
--
-- In-game install command:
--   wget https://raw.githubusercontent.com/Variiuz/cc-enmon/refs/heads/master/installer.lua installer.lua
--   installer

local VERSION    = "0.1.0"
local BASE_URL   = "https://raw.githubusercontent.com/Variiuz/cc-enmon/refs/heads/master/"
local MANIFEST   = BASE_URL .. "manifest.json"
local BASALT_URL = "https://raw.githubusercontent.com/Pyroxenium/Basalt2/refs/heads/main/release/basalt-core.lua"

local ROLE_LABELS = {
    controller = "Controller  (monitor + modem + optional speaker)",
    matrix     = "Matrix Node (induction_port + ender modem)",
    reactor    = "Reactor Node (reactor port + ender modem)",
    display    = "Display Node (monitor + ender modem)",
    pocket     = "Pocket Computer (ender modem only)",
}
local ROLE_ORDER = {"controller", "matrix", "reactor", "display", "pocket"}

local ROLE_REQUIREMENTS = {
    controller = {
        { types = {"ender_modem", "modem"},            label = "Ender modem",        required = true  },
        { types = {"monitor"},                         label = "Monitor",             required = true  },
        { types = {"speaker"},                         label = "Speaker (optional)",  required = false },
    },
    matrix = {
        { types = {"ender_modem", "modem"},            label = "Ender modem",         required = true },
        { types = {"mekanism:induction_port"},         label = "Induction Port",      required = true },
    },
    reactor = {
        { types = {"ender_modem", "modem"},            label = "Ender modem",         required = true },
        { types = {"BigReactors-Reactor",
                   "bigger_reactors:reactor_access_port",
                   "bigreactors:reactor_access_port"}, label = "Reactor Port",        required = true },
    },
    display = {
        { types = {"ender_modem", "modem"},            label = "Ender modem",         required = true },
        { types = {"monitor"},                         label = "Monitor",             required = true },
    },
    pocket = {
        { types = {"ender_modem", "modem"},            label = "Ender modem",         required = true },
    },
}

-- ── UI helpers ────────────────────────────────────────────────────────────────

local function cls() term.clear(); term.setCursorPos(1, 1) end

local function colored(color, fn)
    term.setTextColor(color)
    fn()
    term.setTextColor(colors.white)
end

local function header()
    local w = term.getSize()
    colored(colors.yellow, function()
        print(string.rep("=", w))
        print("  ENMON v" .. VERSION .. "  -  Installer")
        print(string.rep("=", w))
    end)
    print()
end

local function status(ok, msg)
    if ok then colored(colors.green, function() io.write("  [OK]  ") end)
    else       colored(colors.red,   function() io.write("  [ERR] ") end) end
    print(msg)
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
        if n and (not min or n >= min) and (not max or n <= max) then return n end
        colored(colors.red, function() print("  Please enter a valid number.") end)
    end
end

local function promptYesNo(msg, default)
    local d = default and "y" or "n"
    while true do
        local raw = prompt(msg .. " (y/n)", d)
        if raw == nil then raw = d end
        raw = raw:lower()
        if raw == "y" or raw == "yes" then return true  end
        if raw == "n" or raw == "no"  then return false end
        colored(colors.red, function() print("  Please enter y or n.") end)
    end
end

-- ── Step 1: Role selection ────────────────────────────────────────────────────

local function pickRole()
    print("Select this computer's role:")
    print()
    for i, role in ipairs(ROLE_ORDER) do
        colored(colors.cyan, function() io.write("  [" .. i .. "] ") end)
        print(ROLE_LABELS[role])
    end
    colored(colors.lightGray, function() print("  [q] Quit") end)
    print()
    while true do
        local input = prompt("Enter number")
        if input == nil or input:lower() == "q" then
            print("Cancelled.")
            error("quit", 0)
        end
        local n = tonumber(input)
        if n and ROLE_ORDER[n] then return ROLE_ORDER[n] end
        colored(colors.red, function() print("  Invalid choice.") end)
    end
end

-- ── Step 2: Peripheral check ──────────────────────────────────────────────────

local function checkPeripherals(role)
    local reqs = ROLE_REQUIREMENTS[role]
    if not reqs then return end

    local connected = {}
    for _, name in ipairs(peripheral.getNames()) do
        local t = peripheral.getType(name)
        if t then connected[t] = true end
    end

    print()
    colored(colors.yellow, function() print("-- Peripheral check: " .. role .. " --") end)

    local any_missing = false
    for _, req in ipairs(reqs) do
        local found = false
        for _, t in ipairs(req.types) do
            if connected[t] then found = true; break end
        end
        if found then
            colored(colors.green, function() print("  [OK]   " .. req.label) end)
        elseif req.required then
            colored(colors.red,   function() print("  [MISS] " .. req.label .. "  <-- REQUIRED") end)
            any_missing = true
        else
            colored(colors.yellow, function() print("  [--]   " .. req.label .. "  (optional)") end)
        end
    end

    if any_missing then
        print()
        colored(colors.red, function()
            print("  WARNING: Required peripherals are missing.")
            print("  Connect them before starting ENMON.")
        end)
        print()
        if not promptYesNo("Continue anyway?", false) then
            print("Cancelled. Reconnect peripherals and re-run.")
            error("quit", 0)
        end
    end
    print()
end

-- ── Step 3: Config wizard ─────────────────────────────────────────────────────

local function listPeripheralsOfType(ptype)
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == ptype then found[#found+1] = name end
    end
    return found
end

local function runWizard(role)
    local cfg = { role = role }

    colored(colors.yellow, function() print("-- Configuration --") end)
    print()

    -- Node ID
    local default_id = role .. "_" .. tostring(os.getComputerID())
    cfg.node_id = prompt("Node ID (unique name for this node)", default_id)

    -- Channel
    cfg.channel = promptNumber("Network channel", 42, 1, 65535)

    -- Shared secret
    print()
    colored(colors.yellow, function() print("  All nodes must share the same secret.") end)
    cfg.shared_secret = prompt("Shared secret", "enmon_default")

    -- Controller ID (non-controller roles)
    if role ~= "controller" then
        print()
        cfg.controller_id = promptNumber("Controller computer ID", nil, 0)
    end

    -- Monitor side (controller + display)
    if role == "controller" or role == "display" then
        print()
        local monitors = listPeripheralsOfType("monitor")
        if #monitors > 0 then
            colored(colors.green, function() print("  Monitors found: " .. table.concat(monitors, ", ")) end)
        else
            colored(colors.red, function() print("  No monitor detected.") end)
        end
        cfg.monitor_side = prompt("Monitor peripheral name/side", monitors[1] or "top")
    end

    -- Speaker (controller only)
    if role == "controller" then
        print()
        local speakers = listPeripheralsOfType("speaker")
        if #speakers > 0 then
            colored(colors.green, function() print("  Speakers found: " .. table.concat(speakers, ", ")) end)
            if promptYesNo("Use speaker for alerts?", true) then
                cfg.speaker_side = prompt("Speaker peripheral name/side", speakers[1])
            end
        end
    end

    -- Auto-control thresholds (controller only)
    if role == "controller" then
        print()
        colored(colors.yellow, function() print("-- Auto reactor control --") end)
        cfg.auto_ctrl = promptYesNo("Enable automatic reactor on/off based on matrix fill?", true)
        if cfg.auto_ctrl then
            cfg.threshold_low  = promptNumber("Start reactors when matrix below (%)", 25, 1, 99) / 100
            cfg.threshold_high = promptNumber("Stop reactors when matrix above (%)",  90, 1, 99) / 100
        else
            cfg.threshold_low  = 0.25
            cfg.threshold_high = 0.90
        end
    end

    return cfg
end

-- ── Download helpers ──────────────────────────────────────────────────────────

local function ensureDir(path)
    if path ~= "" and not fs.isDir(path) then fs.makeDir(path) end
end

local function download(url, dest)
    local ok, err = pcall(function()
        local response, herr = http.get(url)
        if not response then error(tostring(herr) or "request failed") end
        local code = response.getResponseCode and response.getResponseCode() or 200
        local data = response.readAll()
        response.close()
        if code ~= 200 then error("HTTP " .. code) end
        ensureDir(fs.getDir(dest))
        local f = fs.open(dest, "w")
        f.write(data)
        f.close()
    end)
    return ok, err
end

local function fetchManifest()
    local response, herr = http.get(MANIFEST)
    if not response then
        return nil, "HTTP failed: " .. tostring(herr) .. "\nURL: " .. MANIFEST
    end
    local code = response.getResponseCode and response.getResponseCode() or 200
    local raw  = response.readAll()
    response.close()
    if code ~= 200 then return nil, "HTTP " .. code .. " for manifest" end
    local ok, data = pcall(textutils.unserializeJSON, raw)
    if not ok or type(data) ~= "table" then
        return nil, "Manifest parse error"
    end
    return data, nil
end

-- ── Main ───────────────────────────────────────────────────────────────────────

cls()
header()

if not http then
    colored(colors.red, function() print("HTTP is disabled. Enable it in server config.") end)
    return
end

-- 1. Role
local role = pickRole()

-- 2. Peripheral check
checkPeripherals(role)

-- 3. Config wizard
local cfg = runWizard(role)

-- 4. Confirm before downloading
print()
colored(colors.yellow, function() print("-- Ready to download --") end)
print("  Role:    " .. cfg.role)
print("  Node ID: " .. cfg.node_id)
print("  Channel: " .. cfg.channel)
print()
if not promptYesNo("Download files and complete installation?", true) then
    print("Cancelled.")
    return
end

-- 5. Fetch manifest
print()
io.write("Fetching manifest... ")
local manifest, merr = fetchManifest()
if not manifest then
    colored(colors.red, function() print("FAILED\n  " .. tostring(merr)) end)
    return
end
colored(colors.green, function() print("OK") end)
print()

-- 6. Download common + role files
local files = {}
for _, f in ipairs(manifest.files.common or {}) do files[#files+1] = f end
for _, f in ipairs(manifest.files[role]  or {}) do files[#files+1] = f end

local failed = {}
for _, path in ipairs(files) do
    local ok, err = download(manifest.base_url .. path, path)
    status(ok, path)
    if not ok then failed[#failed+1] = {path=path, err=err} end
end

-- 7. Download Basalt 2
print()
io.write("Downloading Basalt 2... ")
local basalt_ok, basalt_err = download(BASALT_URL, "lib/basalt.lua")
status(basalt_ok, "lib/basalt.lua")
if not basalt_ok then failed[#failed+1] = {path="lib/basalt.lua", err=basalt_err} end

if #failed > 0 then
    print()
    colored(colors.red, function()
        print("  " .. #failed .. " file(s) failed to download:")
        for _, f in ipairs(failed) do print("    - " .. f.path) end
    end)
    print("Check HTTP settings and re-run installer.")
    return
end

-- 8. Write enmon.cfg  (write directly; lib/config is now present but avoid require during install)
local f = fs.open("enmon.cfg", "w")
f.write(textutils.serialize(cfg))
f.close()
status(true, "enmon.cfg written")

-- 9. Write startup.lua
local sf = fs.open("startup.lua", "w")
sf.write('shell.run("enmon.lua")\n')
sf.close()
status(true, "startup.lua written")

-- 10. Done
print()
colored(colors.green, function() print("  Installation complete!") end)
print()

if promptYesNo("Start ENMON now?", true) then
    shell.run("enmon.lua")
end
