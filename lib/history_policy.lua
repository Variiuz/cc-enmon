local history_policy = {}

local DEFAULT_MODE = "prompt_when_disk_detected"

local function normalizeMode(mode)
    local value = tostring(mode or DEFAULT_MODE)
    if value == "memory_only" or value == "disk_enabled" or value == "prompt_when_disk_detected" then
        return value
    end
    return DEFAULT_MODE
end

function history_policy.promptForDiskPersistence(side)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("ENMON detected a mounted disk on " .. tostring(side) .. ".")
    print("")
    print("Enable disk-backed history persistence?")
    print("Y = save history to disk")
    print("N = keep memory-only mode")

    while true do
        local event, value = os.pullEvent()
        if event == "char" then
            local choice = string.lower(tostring(value or ""))
            if choice == "y" then
                return "disk_enabled"
            elseif choice == "n" then
                return "memory_only"
            end
        elseif event == "key" then
            if value == keys.y then
                return "disk_enabled"
            elseif value == keys.n then
                return "memory_only"
            end
        end
    end
end

function history_policy.resolvePersistenceMode(cfg, detectDisk)
    local mode = normalizeMode(cfg.get("history_persistence_mode"))
    if mode ~= DEFAULT_MODE then
        return mode
    end

    local mount, side = detectDisk()
    if not mount then
        return mode
    end

    local resolved = history_policy.promptForDiskPersistence(side)
    cfg.set("history_persistence_mode", resolved)
    cfg.save()
    return resolved
end

function history_policy.applyToBuffer(cfg, buffer, detectDisk)
    local mode = history_policy.resolvePersistenceMode(cfg, detectDisk)
    buffer.persist = mode == "disk_enabled"
    return mode
end

return history_policy