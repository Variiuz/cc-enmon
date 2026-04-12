-- lib/version.lua
-- Shared version + manifest metadata helpers.

local version = {}

local MANIFEST_PATH = "manifest.json"
local SOURCE_PATH = "enmon-source.json"
local RAW_ROOT = "https://raw.githubusercontent.com/Variiuz/cc-enmon/"
local FALLBACK = {
    version = "0.3.9",
    manifest_revision = 0,
    base_url = "https://raw.githubusercontent.com/Variiuz/cc-enmon/development/",
    rollout_policy = "controller-first",
}

local function branchFromBaseUrl(url)
    local trimmed = tostring(url or ""):gsub("/+$", "")
    return trimmed:match("^https?://raw%.githubusercontent%.com/[^/]+/[^/]+/([^/]+)$")
        or trimmed:match("^https?://github%.com/[^/]+/[^/]+/raw/([^/]+)$")
        or trimmed:match("/([^/]+)$")
end

local function branchToBaseUrl(branch)
    if type(branch) ~= "string" or branch == "" then return nil end
    return RAW_ROOT .. branch:gsub("^/+", ""):gsub("/+$", "") .. "/"
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
        rollout_policy = raw:match('"rollout_policy"%s*:%s*"([^"]+)"'),
    }
    if parsed.version or parsed.base_url or parsed.rollout_policy or parsed.manifest_revision ~= 0 then
        return parsed
    end
    return nil
end

function version.loadManifest(path)
    local manifestPath = path or MANIFEST_PATH
    if not fs.exists(manifestPath) then return nil end

    local file = fs.open(manifestPath, "r")
    if not file then return nil end
    local raw = file.readAll()
    file.close()

    return parseManifest(raw)
end

function version.parseManifest(raw)
    return parseManifest(raw)
end

function version.loadSource(path)
    local sourcePath = path or SOURCE_PATH
    if not fs.exists(sourcePath) then return nil end

    local file = fs.open(sourcePath, "r")
    if not file then return nil end
    local raw = file.readAll()
    file.close()

    return parseSource(raw)
end

function version.composeRelease(rawVersion, manifestRevision)
    local base = tostring(rawVersion or FALLBACK.version)
    local revision = tonumber(manifestRevision) or 0
    if revision > 0 then
        return base .. "+r" .. tostring(math.floor(revision))
    end
    return base
end

function version.getBaseVersion(path)
    local manifest = version.loadManifest(path)
    return (manifest and manifest.version) or FALLBACK.version
end

function version.getManifestRevision(path)
    local manifest = version.loadManifest(path)
    return tonumber(manifest and manifest.manifest_revision) or FALLBACK.manifest_revision
end

function version.getVersion(path)
    return version.composeRelease(version.getBaseVersion(path), version.getManifestRevision(path))
end

function version.getBaseUrl(path)
    local source = version.loadSource(path)
    if source and type(source.branch) == "string" and source.branch ~= "" then
        return branchToBaseUrl(source.branch) or FALLBACK.base_url
    end

    local manifest = version.loadManifest(path)
    return (manifest and manifest.base_url) or FALLBACK.base_url
end

function version.getBranch(path)
    local source = version.loadSource(path)
    if source and type(source.branch) == "string" and source.branch ~= "" then
        return source.branch
    end

    local branch = branchFromBaseUrl(version.getBaseUrl(path))

    if branch == nil or branch == "" then
        return "unknown"
    end
    return branch
end

function version.getBranchLabel(path)
    local branch = version.getBranch(path)
    if branch == "master" or branch == "main" then
        return "stable"
    end
    return branch
end

function version.getRolloutPolicy(path)
    local manifest = version.loadManifest(path)
    return (manifest and manifest.rollout_policy) or FALLBACK.rollout_policy
end

local function splitVersion(raw)
    local parts = {}
    for chunk in tostring(raw or "0"):gmatch("%d+") do
        parts[#parts + 1] = tonumber(chunk) or 0
    end
    if #parts == 0 then parts[1] = 0 end
    return parts
end

function version.compare(left, right)
    local a = splitVersion(left)
    local b = splitVersion(right)
    local maxParts = math.max(#a, #b)

    for i = 1, maxParts do
        local av = a[i] or 0
        local bv = b[i] or 0
        if av < bv then return -1 end
        if av > bv then return 1 end
    end

    return 0
end

function version.isNewer(candidate, current)
    return version.compare(candidate, current) > 0
end

return version





















