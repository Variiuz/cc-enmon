-- lib/updater.lua
-- Manifest-driven staged updater with interrupted-update recovery.

local hmac = require("lib/hmac")
local version = require("lib/version")

local updater = {}

local STAGE_DIR = ".enmon_update_stage"
local SENTINEL_PATH = ".enmon_update_state"
local MANAGED_STATE_PATH = ".enmon_managed_files"
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

local function readLocalFile(path)
    if not fs.exists(path) then
        return nil, "missing"
    end

    local file = fs.open(path, "r")
    if not file then
        return nil, "Unable to open local file: " .. tostring(path)
    end

    local raw = file.readAll()
    file.close()
    return raw
end

local function normalizeText(raw)
    return tostring(raw or ""):gsub("\r\n", "\n")
end

local function hashContent(raw)
    return hmac.sha256(normalizeText(raw))
end

local function contentMatchesHash(raw, expected)
    return type(expected) == "string" and expected ~= "" and hashContent(raw) == string.lower(expected)
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

local function readManagedFiles()
    if not fs.exists(MANAGED_STATE_PATH) then return {} end

    local file = fs.open(MANAGED_STATE_PATH, "r")
    if not file then return {} end
    local raw = file.readAll()
    file.close()

    local ok, state = pcall(textutils.unserialize, raw)
    if ok and type(state) == "table" and type(state.files) == "table" then
        return state.files
    end

    return {}
end

local function writeManagedFiles(paths)
    return writeFile(MANAGED_STATE_PATH, textutils.serialize({ files = paths or {} }))
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
    local hashes = type(manifest.hashes) == "table" and manifest.hashes or {}
    local files = {
        { path = "manifest.json", url = cacheBust(base .. "manifest.json", token), hash = hashes["manifest.json"] },
        { path = "installer.lua", url = cacheBust(base .. "installer.lua", token), hash = hashes["installer.lua"] },
        { path = "lib/basalt.lua", url = cacheBust(BASALT_URL, token), hash = hashes["lib/basalt.lua"] },
    }

    for _, relPath in ipairs(manifest.files.common or {}) do
        files[#files + 1] = { path = relPath, url = cacheBust(base .. relPath, token), hash = hashes[relPath] }
    end
    for _, relPath in ipairs(roleFiles) do
        files[#files + 1] = { path = relPath, url = cacheBust(base .. relPath, token), hash = hashes[relPath] }
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
        rollout_policy = manifest.rollout_policy or version.getRolloutPolicy(),
        manifest = manifest,
    }
end

local function stageFiles(entries, logger, force)
    clearPath(STAGE_DIR)
    fs.makeDir(STAGE_DIR)

    local stagedPaths = {}
    for _, entry in ipairs(entries) do
        local localRaw = nil
        if force ~= true then
            localRaw = readLocalFile(entry.path)
            if localRaw and contentMatchesHash(localRaw, entry.hash) then
                log(logger, "Skipping up-to-date " .. entry.path .. " (hash match)")
                goto continue
            end
        end

        log(logger, "Downloading " .. entry.path)
        local raw, err = readHttp(entry.url)
        if not raw then
            clearPath(STAGE_DIR)
            return nil, "Failed to download " .. entry.path .. ": " .. tostring(err)
        end

        if entry.hash and not contentMatchesHash(raw, entry.hash) then
            clearPath(STAGE_DIR)
            return nil, "Downloaded hash mismatch for " .. entry.path
        end

        if force ~= true then
            if localRaw and normalizeText(localRaw) == normalizeText(raw) then
                log(logger, "Skipping unchanged " .. entry.path)
                goto continue
            end
        end

        local stagePath = fs.combine(STAGE_DIR, entry.path)
        local ok, writeErr = writeFile(stagePath, raw)
        if not ok then
            clearPath(STAGE_DIR)
            return nil, writeErr
        end
        stagedPaths[#stagedPaths + 1] = entry.path
        ::continue::
    end

    return stagedPaths
end

function updater.finalizeSwap(state, logger)
    if type(state) ~= "table" then
        return false, "invalid update state"
    end
    if type(state.stage_dir) ~= "string" or type(state.files) ~= "table" or type(state.managed_files) ~= "table" then
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

    local desired = {}
    for _, relPath in ipairs(state.managed_files) do
        desired[relPath] = true
    end

    for _, relPath in ipairs(readManagedFiles()) do
        if not desired[relPath] and fs.exists(relPath) then
            log(logger, "Removing stale " .. relPath)
            fs.delete(relPath)
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
    local ok, err = writeManagedFiles(state.managed_files)
    if not ok then
        return false, err
    end
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

    local stagedPaths, stageErr = stageFiles(files, options.logger, force)
    if not stagedPaths then return false, stageErr end

    local state = {
        stage_dir = STAGE_DIR,
        files = stagedPaths,
        managed_files = (function()
            local result = {}
            for _, entry in ipairs(files) do
                result[#result + 1] = entry.path
            end
            return result
        end)(),
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

function updater.verifyLocalInstallation(options)
    options = options or {}
    local role = options.role
    if not role or role == "" then
        return false, "role is required for verify"
    end

    local info, err = updater.checkForUpdate(role, options.base_url, false)
    if not info then return false, err end

    local files, fileErr = updater.collectFiles(info.manifest, role)
    if not files then return false, fileErr end

    local missing = {}
    local mismatched = {}

    for _, entry in ipairs(files) do
        log(options.logger, "Verifying " .. tostring(entry.path))
        local localRaw, localErr = readLocalFile(entry.path)
        if not localRaw then
            if localErr == "missing" then
                missing[#missing + 1] = entry.path
            else
                mismatched[#mismatched + 1] = entry.path .. " (" .. tostring(localErr) .. ")"
            end
        elseif entry.hash then
            if not contentMatchesHash(localRaw, entry.hash) then
                mismatched[#mismatched + 1] = entry.path
            end
        else
            local remoteRaw, remoteErr = readHttp(entry.url)
            if not remoteRaw then
                return false, "Failed to download " .. tostring(entry.path) .. " for verify: " .. tostring(remoteErr)
            end

            if normalizeText(localRaw) ~= normalizeText(remoteRaw) then
                mismatched[#mismatched + 1] = entry.path
            end
        end
    end

    local desired = {}
    for _, entry in ipairs(files) do
        desired[entry.path] = true
    end

    local stale = {}
    for _, path in ipairs(readManagedFiles()) do
        if not desired[path] then
            stale[#stale + 1] = path
        end
    end

    return true, {
        role = role,
        current_version = info.current_version,
        latest_version = info.latest_version,
        needs_update = info.needs_update,
        missing = missing,
        mismatched = mismatched,
        stale = stale,
        ok = #missing == 0 and #mismatched == 0 and #stale == 0,
    }
end

return updater