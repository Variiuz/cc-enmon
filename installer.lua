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

-- Match config editor / installer-full chrome.
local STYLE = {
    root_bg      = colors.lightGray,
    root_fg      = colors.black,
    header_bg    = colors.gray,
    header_fg    = colors.white,
    section_bg   = colors.lime,
    section_fg   = colors.black,
    hint_fg      = colors.gray,
    highlight_bg = colors.blue,
    highlight_fg = colors.white,
    next_bg      = colors.blue,
    exit_bg      = colors.red,
    button_fg    = colors.black,
    ok_fg        = colors.lime,
    err_fg       = colors.red,
}

local ROOT = term.current()

local function truncate(text, width)
    text = tostring(text or "")
    if width <= 0 then return "" end
    if #text <= width then return text end
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
end

local function fillLine(y, bg, fg)
    local w = select(1, ROOT.getSize())
    ROOT.setCursorPos(1, y)
    ROOT.setBackgroundColor(bg)
    ROOT.setTextColor(fg or STYLE.root_fg)
    ROOT.write(string.rep(" ", w))
end

local function writeAt(x, y, text, fg, bg)
    local w = select(1, ROOT.getSize())
    if y < 1 or x > w then return end
    text = tostring(text or "")
    if x < 1 then
        text = text:sub(2 - x)
        x = 1
    end
    ROOT.setCursorPos(x, y)
    if bg then ROOT.setBackgroundColor(bg) end
    if fg then ROOT.setTextColor(fg) end
    ROOT.write(truncate(text, w - x + 1))
end

local function centerText(y, text, fg, bg)
    local w = select(1, ROOT.getSize())
    local x = math.max(1, math.floor((w - #text) / 2) + 1)
    writeAt(x, y, text, fg, bg)
end

local function drawChrome(section)
    local w, h = ROOT.getSize()
    ROOT.setBackgroundColor(STYLE.root_bg)
    ROOT.setTextColor(STYLE.root_fg)
    ROOT.clear()
    fillLine(1, STYLE.header_bg, STYLE.header_fg)
    centerText(1, "ENMON Bootstrap", STYLE.header_fg, STYLE.header_bg)
    fillLine(2, STYLE.section_bg, STYLE.section_fg)
    writeAt(2, 2, section, STYLE.section_fg, STYLE.section_bg)
    fillLine(h - 1, STYLE.root_bg, STYLE.hint_fg)
    fillLine(h, STYLE.root_bg, STYLE.root_fg)
    return w, h
end

local function drawButton(x, y, text, bg)
    local body = " " .. text .. " "
    writeAt(x, y, body, STYLE.button_fg, bg)
    return { x = x, y = y, w = #body }
end

local function inRegion(region, x, y)
    return region and y == region.y and x >= region.x and x < (region.x + region.w)
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

local function promptCustomBranch()
    local w, h = drawChrome("Custom Branch")
    writeAt(2, 4, "Enter any GitHub branch name to install from.", STYLE.root_fg, STYLE.root_bg)
    writeAt(2, 6, "Branch name:", STYLE.root_fg, STYLE.root_bg)
    writeAt(2, h - 1, "Leave blank to cancel.", STYLE.hint_fg, STYLE.root_bg)
    local box = window.create(ROOT, 2, 7, math.max(1, w - 2), 1, true)
    box.setBackgroundColor(colors.white)
    box.setTextColor(colors.black)
    box.clear()
    local previous = term.redirect(box)
    box.setCursorPos(1, 1)
    local value = read()
    term.redirect(previous)
    value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return nil end
    return value
end

local function chooseBranch(installedBranch)
    local items = {}
    for _, entry in ipairs(BRANCHES) do
        items[#items + 1] = {
            branch = entry.branch,
            label = branchSummary(entry),
            note = entry.note,
        }
    end
    items[#items + 1] = {
        branch = "__custom__",
        label = "Custom branch",
        note = "Enter any branch name manually",
    }

    local selected = 1
    for index, entry in ipairs(BRANCHES) do
        if entry.branch == installedBranch then
            selected = index
            break
        end
    end

    while true do
        local w, h = drawChrome("Branch Selection")
        local row = 4
        writeAt(2, row, "Choose the branch to install from.", STYLE.root_fg, STYLE.root_bg)
        row = row + 1
        if installedBranch then
            writeAt(2, row, "Installed: " .. tostring(installedBranch), STYLE.ok_fg, STYLE.root_bg)
        else
            writeAt(2, row, "Installed: none", STYLE.hint_fg, STYLE.root_bg)
        end
        row = row + 2

        local list_start = row
        for i, item in ipairs(items) do
            local isSelected = i == selected
            local fg = isSelected and STYLE.highlight_fg or STYLE.root_fg
            local bg = isSelected and STYLE.highlight_bg or STYLE.root_bg
            writeAt(2, row, truncate((isSelected and "> " or "  ") .. item.label, w - 3), fg, bg)
            row = row + 1
            writeAt(4, row, truncate(item.note, w - 5), STYLE.hint_fg, STYLE.root_bg)
            row = row + 1
        end

        writeAt(2, h - 1, "Up/down: select   Enter: confirm   Q: exit", STYLE.hint_fg, STYLE.root_bg)
        local exitBtn = drawButton(2, h, "Exit", STYLE.exit_bg)
        local selectLabel = "Select " .. string.char(26)
        local selectBtn = drawButton(math.max(exitBtn.x + exitBtn.w + 2, w - (#selectLabel + 3)), h, selectLabel, STYLE.next_bg)

        local event, a, b, c = os.pullEvent()
        if event == "key" then
            if a == keys.up then
                selected = math.max(1, selected - 1)
            elseif a == keys.down then
                selected = math.min(#items, selected + 1)
            elseif a == keys.enter or a == keys.right then
                local choice = items[selected]
                if choice.branch == "__custom__" then
                    local custom = promptCustomBranch()
                    if custom then return custom end
                else
                    return choice.branch
                end
            elseif a == keys.q then
                return nil
            end
        elseif event == "char" then
            local ch = string.lower(a)
            if ch == "q" then
                return nil
            end
            local idx = tonumber(ch)
            if idx and items[idx] then
                selected = idx
            end
        elseif event == "mouse_click" then
            if inRegion(exitBtn, b, c) then
                return nil
            elseif inRegion(selectBtn, b, c) then
                local choice = items[selected]
                if choice.branch == "__custom__" then
                    local custom = promptCustomBranch()
                    if custom then return custom end
                else
                    return choice.branch
                end
            elseif c >= list_start and c < list_start + (#items * 2) then
                local index = math.floor((c - list_start) / 2) + 1
                if items[index] then
                    selected = index
                end
            end
        end
    end
end

local function cls()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

cls()

if not http then
    drawChrome("HTTP Disabled")
    writeAt(2, 4, "HTTP is disabled in ComputerCraft.", STYLE.err_fg, STYLE.root_bg)
    writeAt(2, 6, "Enable it before running the installer.", STYLE.root_fg, STYLE.root_bg)
    writeAt(2, select(2, ROOT.getSize()) - 1, "Press any key to exit.", STYLE.hint_fg, STYLE.root_bg)
    os.pullEvent("key")
    cls()
    return
end

local installedBranch = readInstalledBranch()
local selectedBranch = chooseBranch(installedBranch)
if not selectedBranch then
    cls()
    return
end

local w, h = drawChrome("Downloading")
writeAt(2, 4, "Selected branch: " .. tostring(selectedBranch), STYLE.root_fg, STYLE.root_bg)
writeAt(2, 6, "Downloading full installer...", STYLE.hint_fg, STYLE.root_bg)

local installerUrl = RAW_ROOT .. selectedBranch .. "/" .. FULL_INSTALLER_NAME
local ok, err = download(installerUrl, TEMP_INSTALLER_PATH)
if not ok then
    writeAt(2, 8, "Download failed: " .. tostring(err), STYLE.err_fg, STYLE.root_bg)
    writeAt(2, 10, truncate("URL: " .. installerUrl, w - 3), STYLE.hint_fg, STYLE.root_bg)
    writeAt(2, h - 1, "Press any key to exit.", STYLE.hint_fg, STYLE.root_bg)
    os.pullEvent("key")
    cls()
    return
end

writeAt(2, 8, "Running full installer...", STYLE.ok_fg, STYLE.root_bg)
local runOk, runErr = shell.run(TEMP_INSTALLER_PATH, selectedBranch)
if fs.exists(TEMP_INSTALLER_PATH) then
    fs.delete(TEMP_INSTALLER_PATH)
end

if runOk == false then
    cls()
    print("Installer failed: " .. tostring(runErr))
end
