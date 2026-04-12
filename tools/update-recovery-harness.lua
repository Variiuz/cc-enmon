local updater = require("lib/updater")

local root = ".tmp_update_harness"
local original_dir = shell and shell.dir and shell.dir() or "."
local paths = {
    stage_dir = "stage",
    sentinel_path = "state",
    managed_state_path = "managed",
    backup_dir = "backup",
}

local function resetRoot()
    if shell and shell.setDir then
        shell.setDir(original_dir)
    end
    if fs.exists(root) then
        fs.delete(root)
    end
    fs.makeDir(root)
    if shell and shell.setDir then
        shell.setDir(root)
    end
end

local function write(path, content)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local file = fs.open(path, "w")
    file.write(content)
    file.close()
end

local function read(path)
    local file = fs.open(path, "r")
    local raw = file.readAll()
    file.close()
    return raw
end

local function assertTrue(value, message)
    if not value then
        error(message or "assertion failed")
    end
end

local function assertEq(left, right, message)
    if left ~= right then
        error((message or "values differ") .. ": " .. tostring(left) .. " ~= " .. tostring(right))
    end
end

local function testResumeCompletesInterruptedSwap()
    resetRoot()
    updater.overridePaths(paths)

    write(fs.combine(paths.stage_dir, "lib/example.lua"), "return 'new'\n")
    write("lib/example.lua", "return 'old'\n")
    write(paths.sentinel_path, textutils.serialize({
        stage_dir = paths.stage_dir,
        backup_dir = paths.backup_dir,
        files = { "lib/example.lua" },
        managed_files = { "lib/example.lua" },
        to_version = "test+r1",
    }))

    local ok, err = updater.resumeInterruptedUpdate(print)
    assertTrue(ok, err)
    assertEq(read("lib/example.lua"), "return 'new'\n", "staged file should become live")
    assertTrue(not fs.exists(paths.sentinel_path), "sentinel should be removed")
    assertTrue(not fs.exists(paths.backup_dir), "backup dir should be cleaned")
end

local function testFinalizeArchivesStaleManagedFiles()
    resetRoot()
    updater.overridePaths(paths)

    write(fs.combine(paths.stage_dir, "manifest.json"), "{}\n")
    write("stale.lua", "return 'stale'\n")
    write(paths.managed_state_path, textutils.serialize({ files = { "stale.lua", "manifest.json" } }))

    local ok, err = updater.finalizeSwap({
        stage_dir = paths.stage_dir,
        backup_dir = paths.backup_dir,
        files = { "manifest.json" },
        managed_files = { "manifest.json" },
        to_version = "test+r1",
    }, print)
    assertTrue(ok, err)
    assertTrue(not fs.exists("stale.lua"), "stale managed file should be removed from live tree")
    assertTrue(fs.exists("manifest.json"), "new manifest should be activated")
end

testResumeCompletesInterruptedSwap()
testFinalizeArchivesStaleManagedFiles()
updater.overridePaths(nil)
if shell and shell.setDir then
    shell.setDir(original_dir)
end
print("update recovery harness passed")