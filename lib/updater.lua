-- lib/updater.lua
-- Manifest-driven staged updater with interrupted-update recovery.

local version = require("lib/version")

local updater = {}

local STAGE_DIR = ".enmon_update_stage"
local SENTINEL_PATH = ".enmon_update_state"
local BASALT_URL = "https://raw.githubusercontent.com/Pyroxenium/Basalt2/main/release/basalt-core.lua"

local function log(logger, message)
    if type(logger) == "function" then
        logger(message)
    end
end

local function ensureParent(path)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function writeFile(path, content)
    ensureParent(path)
    local file = fs.open(path, "w")
    if not file then
        return false, "Unable to open file for write: " .. tostring(path)
    end
    file.write(content)
    file.close()
    return true
end

local function readHttp(url)
    if not http or type(http.get) ~= "function" then
        return nil, "HTTP API unavailable"
    end

    local handle, err = http.get(url)
    if not handle then
        return nil, err or ("Download failed: " .. tostring(url))
    end

    local raw = handle.readAll()
    handle.close()
    return raw
end

local function cacheBust(url, token)
    local sep = url:find("?", 1, true) and "&" or "?"
    return url .. sep .. "_enmon=" .. tostring(token)
end

local function clearPath(path)
    if fs.exists(path) then
        fs.delete(path)
    end
end

local function uniquePaths(entries)
    local seen = {}
    local result = {}
    for _, entry in ipairs(entries or {}) do
        if entry.path and not seen[entry.path] then
            seen[entry.path] = true
            result[#result + 1] = entry
        end
    end
    return result
end

local function readSentinel()
    if not fs.exists(SENTINEL_PATH) then return nil end

    local file = fs.open(SENTINEL_PATH, "r")
    if not file then return nil end
    local raw = file.readAll()
    file.close()

    local ok, state = pcall(textutils.unserialize, raw)
    if ok and type(state) == "table" then
        return state
    end
    return nil
end

local function writeSentinel(state)
    return writeFile(SENTINEL_PATH, textutils.serialize(state))
end

function updater.fetchRemoteManifest(base_url)
    local root = base_url or version.getBaseUrl()
    local raw, err = readHttp(cacheBust(root .. "manifest.json", tostring(os.epoch and os.epoch("utc") or os.clock())))
    if not raw then return nil, err end

    local manifest = version.parseManifest(raw)
    if type(manifest) ~= "table" then
        return nil, "Remote manifest parse error"
    end
    manifest.base_url = manifest.base_url or root
    return manifest
end

function updater.collectFiles(manifest, role)
    if type(manifest) ~= "table" then
        return nil, "manifest missing"
    end
    if type(manifest.files) ~= "table" then
        return nil, "manifest files missing"
    end

    local roleFiles = manifest.files[role]
    if type(roleFiles) ~= "table" then
        return nil, "unknown role: " .. tostring(role)
    end

    local base = manifest.base_url or version.getBaseUrl()
    local token = manifest.version or version.getVersion()
    local files = {
        { path = "manifest.json", url = cacheBust(base .. "manifest.json", token) },
        { path = "installer.lua", url = cacheBust(base .. "installer.lua", token) },
        { path = "lib/basalt.lua", url = cacheBust(BASALT_URL, token) },
    }

    for _, relPath in ipairs(manifest.files.common or {}) do
        files[#files + 1] = { path = relPath, url = cacheBust(base .. relPath, token) }
    end
    for _, relPath in ipairs(roleFiles) do
        files[#files + 1] = { path = relPath, url = cacheBust(base .. relPath, token) }
    end

    return uniquePaths(files)
end

function updater.checkForUpdate(role, base_url, force)
    local manifest, err = updater.fetchRemoteManifest(base_url)
    if not manifest then return nil, err end

    local current = version.getVersion()
    return {
        role = role,
        current_version = current,
        latest_version = manifest.version or current,
        needs_update = force == true or version.isNewer(manifest.version, current),
        force = force == true,
        manifest = manifest,
    }
end

local function stageFiles(entries, logger)
    clearPath(STAGE_DIR)
    fs.makeDir(STAGE_DIR)

    local stagedPaths = {}
    for _, entry in ipairs(entries) do
        log(logger, "Downloading " .. entry.path)
        local raw, err = readHttp(entry.url)
        if not raw then
            clearPath(STAGE_DIR)
            return nil, "Failed to download " .. entry.path .. ": " .. tostring(err)
        end

        local stagePath = fs.combine(STAGE_DIR, entry.path)
        local ok, writeErr = writeFile(stagePath, raw)
        if not ok then
            clearPath(STAGE_DIR)
            return nil, writeErr
        end
        stagedPaths[#stagedPaths + 1] = entry.path
    end

    return stagedPaths
end

function updater.finalizeSwap(state, logger)
    if type(state) ~= "table" then
        return false, "invalid update state"
    end
    if type(state.stage_dir) ~= "string" or type(state.files) ~= "table" then
        return false, "update state incomplete"
    end
    if not fs.exists(state.stage_dir) then
        return false, "staging directory missing"
    end

    for _, relPath in ipairs(state.files) do
        local stagedPath = fs.combine(state.stage_dir, relPath)
        if not fs.exists(stagedPath) then
            return false, "missing staged file: " .. relPath
        end
    end

    for _, relPath in ipairs(state.files) do
        local stagedPath = fs.combine(state.stage_dir, relPath)
        log(logger, "Activating " .. relPath)
        ensureParent(relPath)
        if fs.exists(relPath) then
            fs.delete(relPath)
        end
        fs.copy(stagedPath, relPath)
    end

    clearPath(state.stage_dir)
    clearPath(SENTINEL_PATH)
    return true
end

function updater.resumeInterruptedUpdate(logger)
    local state = readSentinel()
    if not state then
        return true, nil
    end

    log(logger, "Resuming interrupted update to " .. tostring(state.to_version or "unknown"))
    return updater.finalizeSwap(state, logger)
end

function updater.applyLocalUpdate(options)
    options = options or {}
    local role = options.role
    local force = options.force == true
    if not role or role == "" then
        return false, "role is required for update"
    end

    local info, err = updater.checkForUpdate(role, options.base_url, force)
    if not info then return false, err end
    if not info.needs_update then
        return true, {
            updated = false,
            role = role,
            current_version = info.current_version,
            latest_version = info.latest_version,
            forced = false,
        }
    end

    local files, fileErr = updater.collectFiles(info.manifest, role)
    if not files then return false, fileErr end

    local stagedPaths, stageErr = stageFiles(files, options.logger)
    if not stagedPaths then return false, stageErr end

    local state = {
        stage_dir = STAGE_DIR,
        files = stagedPaths,
        from_version = info.current_version,
        to_version = info.latest_version,
        role = role,
    }
    local ok, sentinelErr = writeSentinel(state)
    if not ok then
        clearPath(STAGE_DIR)
        return false, sentinelErr
    end

    local swapped, swapErr = updater.finalizeSwap(state, options.logger)
    if not swapped then return false, swapErr end

    return true, {
        updated = true,
        role = role,
        from_version = info.current_version,
        to_version = info.latest_version,
        forced = force,
    }
end

return updater