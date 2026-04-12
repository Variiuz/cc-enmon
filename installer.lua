-- installer.lua
-- ENMON bootstrap installer.
--
-- This file stays intentionally small: it lets the user choose a branch,
-- downloads installer-full.lua from that branch, and runs the full wizard.

local RAW_ROOT = "https://raw.githubusercontent.com/Variiuz/cc-enmon/"
local FULL_INSTALLER_NAME = "installer-full.lua"
local TEMP_INSTALLER_PATH = ".enmon-installer-full.lua"
local SOURCE_PATH = "enmon-source.json"

local BRANCHES = {
    {
        branch = "master",
        label = "Stable",
        note = "Production branch",
    },
    {
        branch = "development",
        label = "Development",
        note = "Testing branch",
    },
}

local function cls()
    term.clear()
    term.setCursorPos(1, 1)
end

local function composeReleaseLabel(baseVersion, manifestRevision)
    local revision = tonumber(manifestRevision) or 0
    if revision > 0 then
        return tostring(baseVersion) .. "+r" .. tostring(math.floor(revision))
    end
    return tostring(baseVersion)
end

local function parseManifest(raw)
    if type(raw) ~= "string" or raw == "" then return nil end

    if type(textutils.unserializeJSON) == "function" then
        local ok, data = pcall(textutils.unserializeJSON, raw)
        if ok and type(data) == "table" then
            return data
        end
    end

    local parsed = {
        version = raw:match('"version"%s*:%s*"([^"]+)"'),
        manifest_revision = tonumber(raw:match('"manifest_revision"%s*:%s*(%d+)')) or 0,
        base_url = raw:match('"base_url"%s*:%s*"([^"]+)"'),
    }
    if parsed.version or parsed.base_url or parsed.manifest_revision ~= 0 then
        return parsed
    end
    return nil
end

local function parseSource(raw)
    if type(raw) ~= "string" or raw == "" then return nil end

    if type(textutils.unserializeJSON) == "function" then
        local ok, data = pcall(textutils.unserializeJSON, raw)
        if ok and type(data) == "table" then
            return data
        end
    end

    local branch = raw:match('"branch"%s*:%s*"([^"]+)"')
    if branch then
        return { branch = branch }
    end
    return nil
end

local function branchFromBaseUrl(url)
    local trimmed = tostring(url or ""):gsub("/+$", "")
    local branch = trimmed:match("^https?://raw%.githubusercontent%.com/[^/]+/[^/]+/([^/]+)$")
        or trimmed:match("^https?://github%.com/[^/]+/[^/]+/raw/([^/]+)$")
        or trimmed:match("/([^/]+)$")
    return branch
end

local function readInstalledBranch()
    if fs.exists(SOURCE_PATH) then
        local file = fs.open(SOURCE_PATH, "r")
        if file then
            local raw = file.readAll()
            file.close()
            local source = parseSource(raw)
            if source and type(source.branch) == "string" and source.branch ~= "" then
                return source.branch
            end
        end
    end

    if fs.exists("manifest.json") then
        local file = fs.open("manifest.json", "r")
        if file then
            local raw = file.readAll()
            file.close()

            local manifest = parseManifest(raw)
            if manifest then
                return branchFromBaseUrl(manifest.base_url)
            end
        end
    end

    return nil
end

local function cacheBust(url)
    local token
    if os.epoch then
        token = tostring(os.epoch("utc"))
    else
        token = tostring(math.floor(os.clock() * 1000))
    end
    local separator = url:find("?", 1, true) and "&" or "?"
    return url .. separator .. "t=" .. token
end

local function fetchBranchRelease(branch)
    local manifestUrl = cacheBust(RAW_ROOT .. branch .. "/manifest.json")
    local response, err = http.get(manifestUrl)
    if not response then
        return nil, err or "HTTP request failed"
    end

    local raw = response.readAll()
    response.close()

    local manifest = parseManifest(raw)
    if not manifest then
        return nil, "invalid manifest"
    end

    return composeReleaseLabel(manifest.version or "?", manifest.manifest_revision or 0), nil
end

local function branchSummary(entry)
    local release, err = fetchBranchRelease(entry.branch)
    if release then
        return string.format("%s [%s]  %s", entry.label, entry.branch, release)
    end
    return string.format("%s [%s]  unavailable (%s)", entry.label, entry.branch, tostring(err))
end

local function download(url, path)
    local response, err = http.get(cacheBust(url))
    if not response then
        return false, err or "HTTP request failed"
    end

    local body = response.readAll()
    response.close()

    local handle = fs.open(path, "w")
    if not handle then
        return false, "failed to open " .. tostring(path)
    end
    handle.write(body)
    handle.close()
    return true
end

local function chooseBranch(installedBranch)
    while true do
        cls()
        print("ENMON Bootstrap Installer")
        print("")
        if installedBranch then
            print("Installed branch: " .. tostring(installedBranch))
        else
            print("Installed branch: none")
        end
        print("")
        print("Choose the branch to install from:")
        print("")

        for index, entry in ipairs(BRANCHES) do
            print(string.format("  %d. %s", index, branchSummary(entry)))
            print("     " .. tostring(entry.note))
        end

        local customIndex = #BRANCHES + 1
        print(string.format("  %d. Custom branch", customIndex))
        print("     Enter any branch name manually")
        print("")

        local defaultIndex = 1
        for index, entry in ipairs(BRANCHES) do
            if entry.branch == installedBranch then
                defaultIndex = index
                break
            end
        end

        write(string.format("Select branch [%d]: ", defaultIndex))
        local answer = tostring(read() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if answer == "" then
            return BRANCHES[defaultIndex].branch
        end

        local lowered = answer:lower()
        if lowered == "q" or lowered == "quit" or lowered == "exit" then
            return nil
        end

        local numeric = tonumber(answer)
        if numeric and BRANCHES[numeric] then
            return BRANCHES[numeric].branch
        end
        if numeric == customIndex then
            write("Branch name: ")
            local custom = tostring(read() or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if custom ~= "" then
                return custom
            end
        end

        for _, entry in ipairs(BRANCHES) do
            if lowered == entry.branch:lower() or lowered == entry.label:lower() then
                return entry.branch
            end
        end

        print("")
        print("Invalid selection. Press any key to try again.")
        os.pullEvent("key")
    end
end

cls()

if not http then
    print("HTTP is disabled in ComputerCraft.")
    print("Enable it before running the installer.")
    return
end

local installedBranch = readInstalledBranch()
local selectedBranch = chooseBranch(installedBranch)
if not selectedBranch then
    cls()
    print("Installer cancelled.")
    return
end

cls()
print("ENMON Bootstrap Installer")
print("")
print("Selected branch: " .. tostring(selectedBranch))
print("Downloading full installer...")

local installerUrl = RAW_ROOT .. selectedBranch .. "/" .. FULL_INSTALLER_NAME
local ok, err = download(installerUrl, TEMP_INSTALLER_PATH)
if not ok then
    print("Download failed: " .. tostring(err))
    print("URL: " .. installerUrl)
    return
end

print("Running full installer...")
local runOk, runErr = shell.run(TEMP_INSTALLER_PATH, selectedBranch)
if fs.exists(TEMP_INSTALLER_PATH) then
    fs.delete(TEMP_INSTALLER_PATH)
end

if runOk == false then
    print("Installer failed: " .. tostring(runErr))
end
