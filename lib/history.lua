local history = {}

local function cloneValue(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = cloneValue(item)
    end
    return copy
end

local function newStore(maxEntries)
    return {
        data = {},
        max_entries = math.max(1, math.floor(tonumber(maxEntries) or 1)),
        next_index = 1,
        count = 0,
    }
end

local function append(store, value)
    store.data[store.next_index] = cloneValue(value)
    store.next_index = (store.next_index % store.max_entries) + 1
    if store.count < store.max_entries then
        store.count = store.count + 1
    end
end

local function recent(store, limit)
    local count = store.count
    if count <= 0 then return {} end

    local wanted = math.max(1, math.floor(tonumber(limit) or count))
    local take = math.min(count, wanted)
    local start = store.next_index - take
    if start <= 0 then start = start + store.max_entries end

    local result = {}
    for index = 1, take do
        local slot = ((start + index - 2) % store.max_entries) + 1
        result[index] = cloneValue(store.data[slot])
    end
    return result
end

local function findDiskMount()
    if not disk or type(disk.getMountPath) ~= "function" then return nil end

    for _, name in ipairs(peripheral.getNames()) do
        local ptype = peripheral.getType(name)
        if ptype == "drive" and disk.isPresent(name) then
            local mount = disk.getMountPath(name)
            if type(mount) == "string" and mount ~= "" then
                return mount, name
            end
        end
    end

    return nil
end

function history.detectDisk()
    return findDiskMount()
end

local function ensureDir(path)
    if not fs.exists(path) then
        fs.makeDir(path)
    end
end

local function readSerialized(path)
    if not fs.exists(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local raw = file.readAll()
    file.close()
    local ok, parsed = pcall(textutils.unserialize, raw)
    if ok and type(parsed) == "table" then
        return parsed
    end
    return nil
end

local function writeSerialized(path, value)
    local file = fs.open(path, "w")
    if not file then return false end
    file.write(textutils.serialize(value))
    file.close()
    return true
end

function history.new(options)
    options = options or {}
    return {
        samples = newStore(options.max_samples or 180),
        logs = newStore(options.max_logs or 256),
        persist = options.persist == true,
        persist_dir_name = tostring(options.persist_dir_name or "enmon-history"),
        persist_id = tostring(options.persist_id or "default"),
        flush_every = math.max(1, math.floor(tonumber(options.flush_every) or 30)),
        writes_since_flush = 0,
        disk_side = nil,
        disk_mount = nil,
    }
end

function history.recordSample(buffer, sample)
    append(buffer.samples, sample)
    buffer.writes_since_flush = buffer.writes_since_flush + 1
end

function history.recordLog(buffer, entry)
    append(buffer.logs, entry)
    buffer.writes_since_flush = buffer.writes_since_flush + 1
end

function history.getRecentSamples(buffer, limit)
    return recent(buffer.samples, limit)
end

function history.getRecentLogs(buffer, limit)
    return recent(buffer.logs, limit)
end

function history.flush(buffer)
    if not buffer.persist then return false, "persistence disabled" end

    local mount, side = findDiskMount()
    if not mount then
        buffer.disk_side = nil
        buffer.disk_mount = nil
        return false, "no floppy mounted"
    end

    buffer.disk_side = side
    buffer.disk_mount = mount

    local dir = fs.combine(mount, buffer.persist_dir_name)
    ensureDir(dir)
    local path = fs.combine(dir, buffer.persist_id .. ".db")
    local payload = {
        version = 1,
        saved_at = os.clock(),
        samples = history.getRecentSamples(buffer, buffer.samples.max_entries),
        logs = history.getRecentLogs(buffer, buffer.logs.max_entries),
    }

    local ok = writeSerialized(path, payload)
    if ok then
        buffer.writes_since_flush = 0
        return true, path
    end

    return false, "write failed"
end

function history.maybeFlush(buffer)
    if not buffer.persist then return false, "persistence disabled" end
    if buffer.writes_since_flush < buffer.flush_every then
        return false, "flush not due"
    end
    return history.flush(buffer)
end

function history.restore(buffer)
    if not buffer.persist then return false, "persistence disabled" end

    local mount, side = findDiskMount()
    if not mount then
        buffer.disk_side = nil
        buffer.disk_mount = nil
        return false, "no floppy mounted"
    end

    buffer.disk_side = side
    buffer.disk_mount = mount

    local path = fs.combine(fs.combine(mount, buffer.persist_dir_name), buffer.persist_id .. ".db")
    local parsed = readSerialized(path)
    if not parsed then return false, "no persisted history" end

    buffer.samples = newStore(buffer.samples.max_entries)
    for _, sample in ipairs(parsed.samples or {}) do
        append(buffer.samples, sample)
    end

    buffer.logs = newStore(buffer.logs.max_entries)
    for _, entry in ipairs(parsed.logs or {}) do
        append(buffer.logs, entry)
    end

    buffer.writes_since_flush = 0
    return true, path
end

return history