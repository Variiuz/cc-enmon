-- installer.lua
-- ENMON installer — run this first on any new computer.
-- Downloads common files + role-specific files from the GitHub repo.
-- Writes startup.lua and optionally launches ENMON immediately.
--
-- In-game install command:
--   wget https://raw.githubusercontent.com/Variiuz/cc-enmon/refs/heads/master/installer.lua installer.lua
--   installer

local VERSION    = "0.1.0"
local BASE_URL   = "https://raw.githubusercontent.com/Variiuz/cc-enmon/refs/heads/master/"
local MANIFEST   = BASE_URL .. "manifest.json"
local BASALT_URL = "https://raw.githubusercontent.com/Pyroxenium/Basalt2/refs/heads/main/Basalt/basalt.lua"

local ROLE_LABELS = {
    controller = "Controller  (monitor + modem + optional speaker)",
    matrix     = "Matrix Node (induction_port + ender modem)",
    reactor    = "Reactor Node (reactor port + ender modem)",
    display    = "Display Node (monitor + ender modem)",
    pocket     = "Pocket Computer (ender modem only)",
}
local ROLE_ORDER = {"controller", "matrix", "reactor", "display", "pocket"}

-- ── Helpers ──────────────────────────────────────────────────────────────────────
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
    if ok then
        colored(colors.green, function() io.write("  [OK] ") end)
    else
        colored(colors.red,   function() io.write(" [ERR] ") end)
    end
    print(msg)
end

local function ensure_dir(path)
    if not fs.isDir(path) then fs.makeDir(path) end
end

-- Download a single file. Returns true on success.
local function download(url, dest)
    local ok, err = pcall(function()
        local response = http.get(url)
        if not response then error("HTTP request failed") end
        local data = response.readAll()
        response.close()
        ensure_dir(fs.getDir(dest))
        local f = fs.open(dest, "w")
        f.write(data)
        f.close()
    end)
    return ok, err
end

-- Fetch manifest JSON and parse it.
local function fetchManifest()
    local response, err = http.get(MANIFEST)
    if not response then
        return nil, "HTTP failed for: " .. MANIFEST .. "\n  (" .. tostring(err) .. ")"
    end
    local code = response.getResponseCode and response.getResponseCode() or 200
    local raw  = response.readAll()
    response.close()
    if code ~= 200 then
        return nil, "HTTP " .. code .. " for: " .. MANIFEST
    end
    local ok, data = pcall(textutils.unserializeJSON, raw)
    if not ok or type(data) ~= "table" then
        return nil, "Manifest parse error (got: " .. tostring(raw):sub(1,40) .. ")"
    end
    return data, nil
end

-- ── Role selection ───────────────────────────────────────────────────────────────
local function pickRole()
    print("Select role to install on this computer:")
    print()
    for i, role in ipairs(ROLE_ORDER) do
        colored(colors.cyan, function() io.write("  [" .. i .. "] ") end)
        print(ROLE_LABELS[role])
    end
    colored(colors.lightGray, function() print("  [q] Quit") end)
    print()
    while true do
        term.setTextColor(colors.cyan)
        io.write("Enter number: ")
        term.setTextColor(colors.white)
        local input = io.read()
        if input == nil or input:lower() == "q" then
            print("Installer cancelled.")
            error("quit", 0)
        end
        local n = tonumber(input)
        if n and ROLE_ORDER[n] then return ROLE_ORDER[n] end
        colored(colors.red, function() print("  Invalid choice.") end)
    end
end

-- ── Install flow ─────────────────────────────────────────────────────────────────
cls()
header()

if not http then
    colored(colors.red, function()
        print("HTTP API is disabled. Enable it in ComputerCraft config.")
    end)
    return
end

-- 1. Fetch manifest
io.write("Fetching manifest... ")
local manifest, merr = fetchManifest()
if not manifest then
    colored(colors.red, function() print("FAILED: " .. tostring(merr)) end)
    return
end
colored(colors.green, function() print("OK (v" .. (manifest.version or "?") .. ")") end)
print()

-- 2. Pick role
local role = pickRole()
print()
colored(colors.yellow, function() print("Installing: " .. role) end)
print()

-- 3. Build file list: common + role-specific
local files = {}
for _, f in ipairs(manifest.files.common or {}) do
    files[#files+1] = f
end
for _, f in ipairs(manifest.files[role] or {}) do
    files[#files+1] = f
end

-- 4. Download files
local failed = {}
for _, path in ipairs(files) do
    local url = manifest.base_url .. path
    local ok, err = download(url, path)
    status(ok, path)
    if not ok then failed[#failed+1] = {path=path, err=err} end
end

-- 5. Download Basalt 2
io.write("\nDownloading Basalt 2...")
local basalt_ok, basalt_err = download(BASALT_URL, "lib/basalt.lua")
status(basalt_ok, "lib/basalt.lua (Basalt 2)")
if not basalt_ok then failed[#failed+1] = {path="lib/basalt.lua", err=basalt_err} end

-- 6. Write startup.lua
local startup_content = 'shell.run("enmon.lua")\n'
local sf = fs.open("startup.lua", "w")
sf.write(startup_content)
sf.close()
status(true, "startup.lua written")

-- 7. Summary
print()
if #failed == 0 then
    colored(colors.green, function()
        print("  Installation complete! All files downloaded.")
    end)
else
    colored(colors.red, function()
        print("  " .. #failed .. " file(s) failed to download:")
    end)
    for _, f in ipairs(failed) do
        colored(colors.red, function() print("    - " .. f.path) end)
    end
    print()
    print("Check your internet/HTTP settings and re-run installer.")
    return
end

print()
-- 8. Launch setup / ENMON now?
term.setTextColor(colors.cyan)
io.write("Start ENMON now (runs setup wizard on first boot)? [Y/n/q]: ")
term.setTextColor(colors.white)
local ans = io.read()
if ans ~= nil and ans:lower() == "q" then
    print("Exiting.")
else
    if ans == nil or ans == "" or ans:lower() == "y" then
        shell.run("enmon.lua")
    end
end
