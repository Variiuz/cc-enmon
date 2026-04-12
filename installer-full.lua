-- installer-full.lua
-- Full ENMON installer wizard downloaded by installer.lua.
--
-- Flow:
--   1. Select role
--   2. Check peripherals
--   3. Configure node settings
--   4. Review config
--   5. Download files
--   6. Write enmon.cfg + startup.lua
--   7. Prompt to reboot into ENMON
--
-- Entry path:
--   installer.lua bootstrap -> choose branch -> download this file -> run wizard

local _dir = fs.getDir(shell.getRunningProgram())
if _dir == "" then _dir = "/" end
package.path = _dir .. "/?.lua;" .. _dir .. "/?/init.lua;" .. package.path

local args = {...}

local function wrapPeripheral(name)
    if not peripheral.isPresent(name) then return nil end
    local ok, p = pcall(peripheral.wrap, name)
    if ok and p then return p end
    return nil
end

local function isWirelessModem(peripheralRef)
    if not peripheralRef or type(peripheralRef.isWireless) ~= "function" then
        return nil
    end

    local ok, result = pcall(peripheralRef.isWireless, peripheralRef)
    if ok then return result == true end

    ok, result = pcall(peripheralRef.isWireless)
    if ok then return result == true end
    return nil
end

local function listModems()
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        local ptype = peripheral.getType(name)
        if ptype == "ender_modem" or ptype == "modem" then
            found[#found + 1] = name
        end
    end
    return found
end

local function listWirelessModems()
    local found = {}
    for _, name in ipairs(listModems()) do
        local peripheralRef = wrapPeripheral(name)
        if isWirelessModem(peripheralRef) == true then
            found[#found + 1] = name
        end
    end
    return found
end

local function composeReleaseLabel(baseVersion, manifestRevision)
    local revision = tonumber(manifestRevision) or 0
    if revision > 0 then
        return tostring(baseVersion) .. "+r" .. tostring(math.floor(revision))
    end
    return tostring(baseVersion)
end

local VERSION    = composeReleaseLabel("0.3.9", 6)
local DEFAULT_BASE_URL = "https://raw.githubusercontent.com/Variiuz/cc-enmon/development/"
local SOURCE_PATH = "enmon-source.json"
local BASALT_URL = "https://raw.githubusercontent.com/Pyroxenium/Basalt2/main/release/basalt-core.lua"

local function branchFromBaseUrl(url)
    local trimmed = tostring(url or ""):gsub("/+$", "")
    local branch = trimmed:match("^https?://raw%.githubusercontent%.com/[^/]+/[^/]+/([^/]+)$")
        or trimmed:match("^https?://github%.com/[^/]+/[^/]+/raw/([^/]+)$")
        or trimmed:match("/([^/]+)$")
    if branch == "master" or branch == "main" then
        return "stable"
    end
    return branch or "unknown"
end

local function branchToBaseUrl(branch)
    if type(branch) ~= "string" or branch == "" then
        return DEFAULT_BASE_URL
    end
    local normalized = branch:gsub("^/+", ""):gsub("/+$", "")
    return "https://raw.githubusercontent.com/Variiuz/cc-enmon/" .. normalized .. "/"
end

local INSTALL_BRANCH = tostring(args[1] or branchFromBaseUrl(DEFAULT_BASE_URL))
local BASE_URL   = branchToBaseUrl(INSTALL_BRANCH)
local MANIFEST   = BASE_URL .. "manifest.json"

local ROLE_LABELS = {
    controller = "Controller  (monitor + modem + optional speaker)",
    matrix     = "Matrix Node (induction port + ender modem)",
    reactor    = "Reactor Node (reactor port + ender modem)",
    display    = "Display Node (monitor + ender modem)",
    pocket     = "Pocket Computer (ender modem only)",
}
local ROLE_ORDER = {"controller", "matrix", "reactor", "display", "pocket"}

local ROLE_REQUIREMENTS = {
    controller = {
        { types = {"ender_modem", "modem"},            label = "Ender modem",     required = true  },
        { types = {"monitor"},                           label = "Monitor",         required = true  },
        { types = {"speaker"},                           label = "Speaker",         required = false },
    },
    matrix = {
        { types = {"ender_modem", "modem"},            label = "Ender modem",     required = true },
        { types = {"mekanism:induction_port", "inductionPort",
                   "mekanism.induction_port"},           label = "Induction Port",  required = true },
    },
    reactor = {
        { types = {"ender_modem", "modem"},            label = "Ender modem",     required = true },
        { types = {"BigReactors-Reactor",
                   "bigger_reactors:reactor_access_port",
                   "bigreactors:reactor_access_port"},   label = "Reactor Port",    required = true },
    },
    display = {
        { types = {"ender_modem", "modem"},            label = "Ender modem",     required = true },
        { types = {"monitor"},                           label = "Monitor",         required = true },
    },
    pocket = {
        { types = {"ender_modem", "modem"},            label = "Ender modem",     required = true },
    },
}

local STYLE = {
    root_bg      = colors.lightGray,
    root_fg      = colors.black,
    title_bg     = colors.gray,
    title_fg     = colors.white,
    section_bg   = colors.lime,
    section_fg   = colors.black,
    label_fg     = colors.gray,
    hint_fg      = colors.gray,
    input_bg     = colors.white,
    input_fg     = colors.black,
    value_bg     = colors.white,
    value_fg     = colors.black,
    highlight_bg = colors.blue,
    highlight_fg = colors.white,
    back_bg      = colors.lightBlue,
    next_bg      = colors.blue,
    install_bg   = colors.green,
    exit_bg      = colors.red,
    button_fg    = colors.black,
    ok_fg        = colors.lime,
    warn_fg      = colors.orange,
    err_fg       = colors.red,
}

local ROOT = term.current()

-- UI helpers -----------------------------------------------------------------

local function cls()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function cloneTable(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

local function replaceTable(target, source)
    for key in pairs(target) do
        target[key] = nil
    end
    for key, value in pairs(source or {}) do
        target[key] = value
    end
end

local function truncate(text, width)
    text = tostring(text or "")
    if width <= 0 then return "" end
    if #text <= width then return text end
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
end

local function wrapText(text, width)
    local lines = {}
    for raw in tostring(text or ""):gmatch("[^\n]+") do
        local line = ""
        for word in raw:gmatch("%S+") do
            local part = truncate(word, width)
            if line == "" then
                line = part
            elseif (#line + 1 + #part) <= width then
                line = line .. " " .. part
            else
                lines[#lines + 1] = line
                line = part
            end
        end
        lines[#lines + 1] = line ~= "" and line or ""
    end
    if #lines == 0 then lines[1] = "" end
    return lines
end

local function wrapToMaxLines(text, width, max_lines)
    local lines = wrapText(text, width)
    if #lines <= max_lines then
        return lines
    end

    local result = {}
    for index = 1, max_lines do
        result[index] = lines[index] or ""
    end

    for index = max_lines + 1, #lines do
        if (#result[max_lines] + 3 + #lines[index]) <= width then
            result[max_lines] = result[max_lines] .. " | " .. lines[index]
        else
            break
        end
    end

    return result
end

local function clearWindow(win, bg, fg)
    win.setBackgroundColor(bg)
    win.setTextColor(fg)
    win.clear()
    win.setCursorPos(1, 1)
end

local function fillLine(target, y, bg, fg)
    local w = select(1, target.getSize())
    target.setCursorPos(1, y)
    target.setBackgroundColor(bg)
    target.setTextColor(fg or STYLE.root_fg)
    target.write(string.rep(" ", w))
end

local function writeAt(target, x, y, text, fg, bg)
    local w = select(1, target.getSize())
    if y < 1 or x > w then return end
    text = tostring(text or "")
    if x < 1 then
        text = text:sub(2 - x)
        x = 1
    end
    local clipped = truncate(text, w - x + 1)
    target.setCursorPos(x, y)
    if bg then target.setBackgroundColor(bg) end
    if fg then target.setTextColor(fg) end
    target.write(clipped)
end

local function centerText(target, y, text, fg, bg)
    local w = select(1, target.getSize())
    local x = math.max(1, math.floor((w - #text) / 2) + 1)
    writeAt(target, x, y, text, fg, bg)
end

local function writeParagraph(win, row, text, fg)
    local width = select(1, win.getSize())
    for _, line in ipairs(wrapText(text, width)) do
        writeAt(win, 1, row, line, fg or STYLE.root_fg, STYLE.root_bg)
        row = row + 1
    end
    return row
end

local function drawChrome(section)
    local w, h = ROOT.getSize()
    ROOT.setBackgroundColor(STYLE.root_bg)
    ROOT.setTextColor(STYLE.root_fg)
    ROOT.clear()
    fillLine(ROOT, 1, STYLE.title_bg, STYLE.title_fg)
    centerText(ROOT, 1, "ENMON Installer [" .. tostring(INSTALL_BRANCH) .. "]", STYLE.title_fg, STYLE.title_bg)
    writeAt(ROOT, math.max(2, w - #("v" .. VERSION)), 1, "v" .. VERSION, STYLE.title_fg, STYLE.title_bg)
    fillLine(ROOT, 2, STYLE.section_bg, STYLE.section_fg)
    writeAt(ROOT, 2, 2, section, STYLE.section_fg, STYLE.section_bg)
    fillLine(ROOT, h - 1, STYLE.root_bg, STYLE.hint_fg)
    fillLine(ROOT, h, STYLE.root_bg, STYLE.root_fg)

    local content = window.create(ROOT, 2, 4, math.max(1, w - 2), math.max(1, h - 5), true)
    clearWindow(content, STYLE.root_bg, STYLE.root_fg)
    return content, w, h
end

local function drawHint(text)
    local w, h = ROOT.getSize()
    local lines = wrapToMaxLines(text or "", math.max(1, w - 2), 2)
    fillLine(ROOT, h - 1, STYLE.root_bg, STYLE.hint_fg)
    writeAt(ROOT, 2, h - 1, lines[1] or "", STYLE.hint_fg, STYLE.root_bg)
    fillLine(ROOT, h, STYLE.root_bg, STYLE.hint_fg)
    writeAt(ROOT, 2, h, lines[2] or "", STYLE.hint_fg, STYLE.root_bg)
end

local function drawButton(x, y, text, bg)
    local body = " " .. text .. " "
    writeAt(ROOT, x, y, body, STYLE.button_fg, bg)
    return { x = x, y = y, w = #body }
end

local function drawNav(canBack, rightLabel, rightBg)
    local w, h = ROOT.getSize()
    local leftText = canBack and (string.char(27) .. " Back") or "Exit"
    local leftBg = canBack and STYLE.back_bg or STYLE.exit_bg
    local left = drawButton(2, h, leftText, leftBg)

    local right = nil
    if rightLabel then
        local label = rightLabel .. " " .. string.char(26)
        local rightX = math.max(left.x + left.w + 2, w - (#label + 2))
        right = drawButton(rightX, h, label, rightBg or STYLE.next_bg)
    end
    return left, right
end

local function waitAnyKey()
    while true do
        local event = os.pullEvent()
        if event == "key" or event == "char" or event == "mouse_click" then
            return
        end
    end
end

local function waitBackOnly()
    drawHint("Backspace/left: back   Q: exit")
    local left = drawButton(2, select(2, ROOT.getSize()), string.char(27) .. " Back", STYLE.back_bg)

    local function inRegion(region, x, y)
        return region and y == region.y and x >= region.x and x < (region.x + region.w)
    end

    while true do
        local event, a, b, c = os.pullEvent()
        if event == "key" then
            if a == keys.q then
                return "cancel"
            elseif a == keys.backspace or a == keys.left then
                return "back"
            end
        elseif event == "char" then
            local ch = string.lower(a)
            if ch == "q" then
                return "cancel"
            elseif ch == "b" then
                return "back"
            end
        elseif event == "mouse_click" then
            if inRegion(left, b, c) then
                return "back"
            end
        end
    end
end

local function chooseFromList(section, intro, items, selected, canBack)
    selected = selected or 1
    while true do
        local win = drawChrome(section)
        local row = 1
        row = writeParagraph(win, row, intro, STYLE.root_fg)
        row = row + 1

        for i, item in ipairs(items) do
            local isSelected = i == selected
            local prefix = isSelected and "> " or "  "
            local fg = isSelected and STYLE.highlight_fg or STYLE.root_fg
            local bg = isSelected and STYLE.highlight_bg or STYLE.root_bg
            writeAt(win, 1, row, truncate(prefix .. item, select(1, win.getSize())), fg, bg)
            row = row + 1
        end

        local hint = canBack
            and "Up/down: select   Enter/right: confirm   Backspace/left: back   Q: exit"
            or "Up/down: select   Enter/right: confirm   Q: exit"
        drawHint(hint)
        drawNav(canBack, "Select", STYLE.next_bg)

        local event, a, b, c = os.pullEvent()
        if event == "key" then
            if a == keys.up then
                selected = math.max(1, selected - 1)
            elseif a == keys.down then
                selected = math.min(#items, selected + 1)
            elseif canBack and (a == keys.backspace or a == keys.left) then
                return nil, "back"
            elseif a == keys.enter or a == keys.right then
                return selected, "forward"
            elseif a == keys.q then
                return nil, "cancel"
            end
        elseif event == "char" then
            local ch = string.lower(a)
            if ch == "q" then
                return nil, "cancel"
            elseif canBack and ch == "b" then
                return nil, "back"
            end
            local idx = tonumber(ch)
            if idx and items[idx] then
                selected = idx
            end
        elseif event == "mouse_click" then
            local w, h = ROOT.getSize()
            if c == h then
                local leftText = canBack and (" " .. string.char(27) .. " Back ") or " Exit "
                local left = { x = 2, y = h, w = #leftText }
                local rightText = " Select " .. string.char(26) .. " "
                local right = { x = math.max(left.x + left.w + 2, w - #rightText + 1), y = h, w = #rightText }
                if c == left.y and b >= left.x and b < left.x + left.w then
                    return nil, canBack and "back" or "cancel"
                elseif c == right.y and b >= right.x and b < right.x + right.w then
                    return selected, "forward"
                end
            else
                local listRow = c - 4
                if listRow >= 3 and items[listRow - 2] then
                    selected = listRow - 2
                end
            end
        end
    end
end

local function chooseToggle(section, intro, current, canBack)
    local checked = current == true

    local function toggleText()
        return checked and "[x] Enabled" or "[ ] Disabled"
    end

    while true do
        local win = drawChrome(section)
        local row = 1
        row = writeParagraph(win, row, intro, STYLE.root_fg)
        row = row + 2

        local width = select(1, win.getSize())
        writeAt(win, 1, row, string.rep(" ", width), checked and STYLE.highlight_fg or STYLE.value_fg, checked and STYLE.highlight_bg or STYLE.value_bg)
        writeAt(win, 3, row, toggleText(), checked and STYLE.highlight_fg or STYLE.value_fg, checked and STYLE.highlight_bg or STYLE.value_bg)
        row = row + 2
        row = writeParagraph(win, row, "Press space to toggle. Press Enter to continue.", STYLE.hint_fg)

        drawHint(canBack and "Space: toggle   Enter/right: next   Backspace/left: back   Q: exit" or "Space: toggle   Enter/right: next   Q: exit")
        local left, right = drawNav(canBack, "Next", STYLE.next_bg)

        local function inRegion(region, x, y)
            return region and y == region.y and x >= region.x and x < (region.x + region.w)
        end

        while true do
            local event, a, b, c = os.pullEvent()
            if event == "key" then
                if a == keys.space then
                    checked = not checked
                    break
                elseif a == keys.enter or a == keys.right then
                    return checked, "forward"
                elseif canBack and (a == keys.backspace or a == keys.left) then
                    return nil, "back"
                elseif a == keys.q then
                    return nil, "cancel"
                end
            elseif event == "char" then
                local ch = string.lower(a)
                if ch == " " or ch == "x" or ch == "t" then
                    checked = not checked
                    break
                elseif ch == "q" then
                    return nil, "cancel"
                elseif canBack and ch == "b" then
                    return nil, "back"
                end
            elseif event == "mouse_click" then
                if inRegion(left, b, c) then
                    return nil, canBack and "back" or "cancel"
                elseif inRegion(right, b, c) then
                    return checked, "forward"
                elseif c == 6 then
                    checked = not checked
                    break
                end
            end
        end
    end
end

local function waitNav(canBack, rightLabel, rightBg)
    local hint = canBack
        and "Enter/right: next   Backspace/left: back   Q: exit"
        or "Enter/right: next   Q: exit"
    drawHint(hint)
    local left, right = drawNav(canBack, rightLabel, rightBg)

    local function inRegion(region, x, y)
        return region and y == region.y and x >= region.x and x < (region.x + region.w)
    end

    while true do
        local event, a, b, c = os.pullEvent()
        if event == "key" then
            if a == keys.q then
                return "cancel"
            elseif canBack and (a == keys.backspace or a == keys.left) then
                return "back"
            elseif a == keys.enter or a == keys.right then
                return "forward"
            end
        elseif event == "char" then
            local ch = string.lower(a)
            if ch == "q" then
                return "cancel"
            elseif canBack and ch == "b" then
                return "back"
            elseif ch == "n" or ch == "y" then
                return "forward"
            end
        elseif event == "mouse_click" then
            local x, y = b, c
            if inRegion(left, x, y) then
                return canBack and "back" or "cancel"
            elseif inRegion(right, x, y) then
                return "forward"
            end
        end
    end
end

local function alert(section, text, fg)
    local win = drawChrome(section)
    local row = 1
    row = writeParagraph(win, row, text, fg or STYLE.err_fg)
    row = row + 1
    writeAt(win, 1, row, "Press any key to continue.", STYLE.hint_fg, STYLE.root_bg)
    drawHint("Press any key to continue")
    waitAnyKey()
end

local function inputField(win, row, label, default, hint)
    local width = select(1, win.getSize())
    local suffix = hint or ((default ~= nil and tostring(default) ~= "") and ("[" .. tostring(default) .. "]") or nil)
    writeAt(win, 1, row, label, STYLE.root_fg, STYLE.root_bg)
    if suffix then
        writeAt(win, math.max(1, width - #suffix + 1), row, suffix, STYLE.hint_fg, STYLE.root_bg)
    end

    local box = window.create(win, 1, row + 1, width, 1, true)
    clearWindow(box, STYLE.input_bg, STYLE.input_fg)
    local previous = term.redirect(box)
    box.setCursorPos(1, 1)
    local value = read()
    term.redirect(previous)

    if value == nil or value == "" then
        return default
    end
    return value
end

local function roleIndex(role)
    for i, candidate in ipairs(ROLE_ORDER) do
        if candidate == role then return i end
    end
    return nil
end

local sanitizeRoleConfig

local function normalizeSeedConfig(source)
    local cfg = cloneTable(source)
    if roleIndex(cfg.role) == nil then
        cfg.role = nil
    end
    if cfg.channel ~= nil then cfg.channel = tonumber(cfg.channel) or 42 end
    if cfg.modem_side ~= nil then cfg.modem_side = trim(cfg.modem_side) end
    if cfg.controller_id ~= nil then cfg.controller_id = tonumber(cfg.controller_id) end
    if cfg.threshold_low ~= nil then
        cfg.threshold_low = tonumber(cfg.threshold_low)
        if cfg.threshold_low and cfg.threshold_low > 1 then cfg.threshold_low = cfg.threshold_low / 100 end
    end
    if cfg.threshold_high ~= nil then
        cfg.threshold_high = tonumber(cfg.threshold_high)
        if cfg.threshold_high and cfg.threshold_high > 1 then cfg.threshold_high = cfg.threshold_high / 100 end
    end
    if cfg.update_check_interval ~= nil then cfg.update_check_interval = tonumber(cfg.update_check_interval) end
    if cfg.auto_ctrl ~= nil then cfg.auto_ctrl = cfg.auto_ctrl == true end
    sanitizeRoleConfig(cfg)
    return cfg
end

local function loadExistingConfig()
    if not fs.exists("enmon.cfg") then
        return nil, nil
    end

    local file = fs.open("enmon.cfg", "r")
    if not file then
        return nil, "enmon.cfg exists but could not be opened"
    end

    local raw = file.readAll()
    file.close()

    local ok, parsed = pcall(textutils.unserialize, raw)
    if not ok or type(parsed) ~= "table" then
        return nil, "enmon.cfg could not be parsed and will not be reused"
    end

    return normalizeSeedConfig(parsed), nil
end

local function listPeripheralsOfType(ptype)
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == ptype then
            found[#found + 1] = name
        end
    end
    return found
end

local function describeModem(name)
    local peripheralRef = wrapPeripheral(name)
    if not peripheralRef then
        return tostring(name) .. " (missing)"
    end

    local wireless = isWirelessModem(peripheralRef)
    if wireless == true then
        return tostring(name) .. " (ender modem)"
    elseif wireless == false then
        return tostring(name) .. " (wired)"
    end

    return tostring(name) .. " (modem)"
end

local function resolveAutoModemSide(cfg)
    if type(cfg.modem_side) == "string" and cfg.modem_side ~= "" then
        local peripheralRef = wrapPeripheral(cfg.modem_side)
        if peripheralRef and isWirelessModem(peripheralRef) == true then
            return cfg.modem_side, "saved"
        end
    end

    local wireless = listWirelessModems()
    if #wireless == 1 then
        return wireless[1], "detected"
    end

    return nil, (#wireless > 1) and "multiple" or "missing"
end

local function findMatchingNames(types)
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        local ptype = peripheral.getType(name)
        for _, wanted in ipairs(types) do
            if ptype == wanted then
                found[#found + 1] = name
                break
            end
        end
    end
    return found
end

sanitizeRoleConfig = function(cfg)
    if cfg.role ~= "controller" then
        cfg.speaker_side = nil
        cfg.auto_ctrl = nil
        cfg.threshold_low = nil
        cfg.threshold_high = nil
        cfg.update_check_interval = nil
    else
        cfg.controller_id = nil
    end
    if cfg.role ~= "controller" and cfg.role ~= "display" then
        cfg.monitor_side = nil
    end
end

-- Wizard pages ---------------------------------------------------------------

local function pageWelcome(cfg, state)
    local win = drawChrome("Welcome")
    local row = 1
    row = writeParagraph(win, row, "Install or refresh ENMON on this computer. The wizard now supports reusing an existing configuration as a starting point, then reviewing each section before files are downloaded.", STYLE.root_fg)
    row = row + 1
    row = writeParagraph(win, row, "Flow: welcome, role, hardware check, network identity, role-specific settings, final review, then download and write files.", STYLE.hint_fg)
    row = row + 1

    if state.existing_cfg then
        row = writeParagraph(win, row, "Detected existing config:", STYLE.label_fg)
        row = row + 1
        row = writeParagraph(win, row, "Role: " .. tostring(state.existing_cfg.role or "--") .. "   Node: " .. tostring(state.existing_cfg.node_id or "--"), STYLE.root_fg)
        row = row + 1
        row = writeParagraph(win, row, "Channel: " .. tostring(state.existing_cfg.channel or "--") .. "   Schema: v" .. tostring(state.existing_cfg.config_version or "legacy"), STYLE.root_fg)
        row = row + 1
        row = writeParagraph(win, row, "Next screen lets you reuse that config or start from clean defaults.", STYLE.ok_fg)
    elseif state.existing_err then
        row = writeParagraph(win, row, state.existing_err, STYLE.warn_fg)
    else
        row = writeParagraph(win, row, "No existing config found. A new config will be created during install.", STYLE.ok_fg)
    end

    return waitNav(false, "Begin", STYLE.next_bg)
end

local function pageExistingConfig(cfg, state)
    local current = state.use_existing == false and 2 or 1
    local summary = "Reuse the detected configuration as a base, or start clean. Reusing keeps the current role and values loaded into the following pages so you can review and adjust them before install."
    local choice, action = chooseFromList(
        "Existing Configuration",
        summary,
        {
            "Reuse detected config and review it page by page",
            "Start fresh with clean defaults",
        },
        current,
        true
    )
    if action ~= "forward" then return action end

    if choice == 1 then
        replaceTable(cfg, state.existing_cfg)
        state.use_existing = true
    else
        replaceTable(cfg, {})
        state.use_existing = false
    end
    return "forward"
end

local function pageRole(cfg)
    local labels = {}
    for _, role in ipairs(ROLE_ORDER) do
        labels[#labels + 1] = ROLE_LABELS[role]
    end
    local idx, action = chooseFromList(
        "Role Selection",
        "Choose the role for this computer. Use up/down arrows to move the selection and press Enter to confirm.",
        labels,
        roleIndex(cfg.role) or 1,
        false
    )
    if action ~= "forward" then return action end
    cfg.role = ROLE_ORDER[idx]
    sanitizeRoleConfig(cfg)
    return "forward"
end

local function pagePeripherals(cfg)
    local reqs = ROLE_REQUIREMENTS[cfg.role] or {}
    local win = drawChrome("Peripheral Check")
    local row = 1
    local width = select(1, win.getSize())
    local any_missing = false

    row = writeParagraph(win, row, "Detected peripherals for role: " .. (ROLE_LABELS[cfg.role] or cfg.role), STYLE.root_fg)
    row = row + 1

    for _, req in ipairs(reqs) do
        local found = findMatchingNames(req.types)
        local ok = #found > 0
        if not ok and req.required then any_missing = true end

        local marker = ok and "[+]" or (req.required and "[!]" or "[-]")
        local color = ok and STYLE.ok_fg or (req.required and STYLE.err_fg or STYLE.warn_fg)
        local detail = ok and table.concat(found, ", ") or (req.required and "missing" or "optional")

        writeAt(win, 1, row, marker, color, STYLE.root_bg)
        writeAt(win, 6, row, truncate(req.label, 14), STYLE.root_fg, STYLE.root_bg)
        writeAt(win, 22, row, truncate(detail, math.max(1, width - 22)), STYLE.hint_fg, STYLE.root_bg)
        row = row + 1
    end

    row = row + 1
    if any_missing then
        row = writeParagraph(win, row, "Required hardware is missing. You can continue, but this node will not start correctly until the missing peripherals are attached.", STYLE.err_fg)
    else
        row = writeParagraph(win, row, "All required peripherals are present.", STYLE.ok_fg)
    end

    return waitNav(true, any_missing and "Continue" or "Next", STYLE.next_bg)
end

local function pageIdentity(cfg)
    while true do
        local win = drawChrome("Network Identity")
        local row = 1
        local defaultNode = cfg.node_id or (cfg.role .. "_" .. tostring(os.getComputerID()))
        local defaultChannel = cfg.channel or 42

        row = writeParagraph(win, row, "Set this node's name and channel. New non-controller nodes will appear as unlinked on that channel until a controller adopts them.", STYLE.root_fg)
        row = row + 1

        drawHint("Leave a box blank to keep its default value.")
        drawNav(true, "Next", STYLE.next_bg)

        local node_id = trim(inputField(win, row, "Node ID", defaultNode))
        row = row + 3
        local channel = trim(inputField(win, row, "Network channel", defaultChannel, "[1-65535]"))

        local channelNumber = tonumber(channel)
        if node_id == "" then
            alert("Network Identity", "Node ID cannot be empty.")
        elseif not channelNumber or channelNumber < 1 or channelNumber > 65535 then
            alert("Network Identity", "Channel must be a number between 1 and 65535.")
        else
            cfg.node_id = node_id
            cfg.channel = channelNumber
            return "forward"
        end
    end
end

local function pageModem(cfg)
    while true do
        local win = drawChrome("Modem Selection")
        local row = 1
        local modems = listModems()
        local wireless = listWirelessModems()
        local defaultModem = cfg.modem_side or wireless[1] or modems[1] or ""

        row = writeParagraph(win, row, "Choose the ender modem ENMON should use for network traffic. This screen only appears when ENMON cannot confidently auto-select the only wireless-class modem.", STYLE.root_fg)
        row = row + 1
        if #modems > 0 then
            row = writeParagraph(win, row, "Detected modems:", STYLE.label_fg)
            row = row + 1
            for _, name in ipairs(modems) do
                row = writeParagraph(win, row, "- " .. describeModem(name), STYLE.hint_fg)
            end
            row = row + 1
        else
            row = writeParagraph(win, row, "No modems detected. You can still enter a side/name manually.", STYLE.warn_fg)
            row = row + 1
        end

        if #wireless > 1 then
            row = writeParagraph(win, row, "Multiple wireless-class modems were detected. Pick the ender modem explicitly.", STYLE.warn_fg)
            row = row + 1
        elseif #wireless == 0 then
            row = writeParagraph(win, row, "No wireless-class modem was detected automatically. Enter the ender modem side/name manually.", STYLE.warn_fg)
            row = row + 1
        end

        drawHint("Choose the ender modem side, not a wired modem.")
        drawNav(true, "Next", STYLE.next_bg)

        local modem_side = trim(inputField(win, row, "Ender modem side/name", defaultModem))
        if modem_side == "" then
            alert("Modem Selection", "Ender modem side/name cannot be empty on multi-modem systems.")
        else
            cfg.modem_side = modem_side
            return "forward"
        end
    end
end

local function pageHardware(cfg)
    while true do
        local win = drawChrome("Hardware Setup")
        local row = 1
        local monitors = listPeripheralsOfType("monitor")
        local speakers = listPeripheralsOfType("speaker")
        local monitorDefault = cfg.monitor_side or monitors[1] or "top"
        local speakerDefault = cfg.speaker_side or speakers[1] or ""

        row = writeParagraph(win, row, "Choose which attached peripherals ENMON should use on this node.", STYLE.root_fg)
        row = row + 1
        if #monitors > 0 then
            row = writeParagraph(win, row, "Detected monitors: " .. table.concat(monitors, ", "), STYLE.hint_fg)
        else
            row = writeParagraph(win, row, "No monitor detected. You can still enter a side/name manually.", STYLE.warn_fg)
        end
        if cfg.role == "controller" then
            if #speakers > 0 then
                row = writeParagraph(win, row, "Detected speakers: " .. table.concat(speakers, ", "), STYLE.hint_fg)
            else
                row = writeParagraph(win, row, "No speaker detected. Leave blank if you do not want alert sounds.", STYLE.hint_fg)
            end
        end
        row = row + 1

        drawHint("Leave the speaker box blank to disable speaker alerts.")
        drawNav(true, "Next", STYLE.next_bg)

        local monitor = trim(inputField(win, row, "Monitor side/name", monitorDefault))
        row = row + 3

        local speaker = nil
        if cfg.role == "controller" then
            speaker = trim(inputField(win, row, "Speaker side/name", speakerDefault, "[blank = none]"))
        end

        if monitor == "" then
            alert("Hardware Setup", "Monitor side/name cannot be empty for this role.")
        else
            cfg.monitor_side = monitor
            if cfg.role == "controller" then
                cfg.speaker_side = speaker ~= "" and speaker or nil
            end
            return "forward"
        end
    end
end

local function parseYesNo(value)
    local normalized = string.lower(trim(value))
    if normalized == "y" or normalized == "yes" or normalized == "true" or normalized == "1" then
        return true
    elseif normalized == "n" or normalized == "no" or normalized == "false" or normalized == "0" then
        return false
    end
    return nil
end

local function pageAutoControl(cfg)
    while true do
        local enabledDefault = (cfg.auto_ctrl == nil) and true or cfg.auto_ctrl
        local lowDefault = math.floor(((cfg.threshold_low or 0.25) * 100) + 0.5)
        local highDefault = math.floor(((cfg.threshold_high or 0.90) * 100) + 0.5)

        local enabled, action = chooseToggle(
            "Auto Control",
            "Controller nodes can automatically start and stop reactors based on matrix fill percentage.",
            enabledDefault,
            true
        )

        if action == "cancel" or action == "back" then
            return action
        else
            cfg.auto_ctrl = enabled
            if enabled then
                local win = drawChrome("Auto Control Thresholds")
                local row = 1
                row = writeParagraph(win, row, "Set the controller thresholds. Reactors start below the low threshold and stop above the high threshold.", STYLE.root_fg)
                row = row + 1
                drawHint("Thresholds are percentages. Example: 25 means 25%.")
                drawButton(2, select(2, ROOT.getSize()), string.char(27) .. " Back", STYLE.back_bg)
                row = row + 3
                local lowRaw = trim(inputField(win, row, "Start reactors below (%)", lowDefault, "[1-99]"))
                row = row + 3
                local highRaw = trim(inputField(win, row, "Stop reactors above (%)", highDefault, "[1-99]"))
                local low = tonumber(lowRaw)
                local high = tonumber(highRaw)

                if not low or not high or low < 1 or high > 99 or low >= high then
                    alert("Auto Control", "Enter valid percentages where low is below high. Example: 25 and 90.")
                else
                    cfg.threshold_low = low / 100
                    cfg.threshold_high = high / 100
                    return "forward"
                end
            else
                cfg.threshold_low = 0.25
                cfg.threshold_high = 0.90
                return "forward"
            end
        end
    end
end

local function pageUpdateChecks(cfg)
    while true do
        local defaultInterval = tonumber(cfg.update_check_interval) or 90

        local win = drawChrome("Update Checks")
        local row = 1
        row = writeParagraph(win, row, "Choose how often the controller checks the manifest for updates automatically.", STYLE.root_fg)
        row = row + 1
        row = writeParagraph(win, row, "This only affects the controller's periodic background check. Manual update checks still work anytime.", STYLE.hint_fg)
        row = row + 1

        drawHint("Enter seconds. Minimum 15. Example: 90")
        drawNav(true, "Next", STYLE.next_bg)

        local raw = trim(inputField(win, row, "Auto update check interval (seconds)", defaultInterval, "[>=15]"))
        local value = tonumber(raw)

        if value and value >= 15 then
            cfg.update_check_interval = math.floor(value + 0.5)
            return "forward"
        end

        alert("Update Checks", "Enter a valid interval of at least 15 seconds.")
    end
end

local function summaryRows(cfg)
    local rows = {
        { "Role", ROLE_LABELS[cfg.role] or cfg.role },
        { "Node ID", cfg.node_id },
        { "Channel", tostring(cfg.channel) },
        { "Modem", tostring(cfg.modem_side or "auto") },
    }
    if cfg.role ~= "controller" then
        rows[#rows + 1] = { "Linking", "Adopt into a controller after install" }
    end
    if cfg.monitor_side then
        rows[#rows + 1] = { "Monitor", cfg.monitor_side }
    end
    if cfg.speaker_side ~= nil then
        rows[#rows + 1] = { "Speaker", cfg.speaker_side ~= "" and cfg.speaker_side or "none" }
    end
    if cfg.role == "controller" then
        rows[#rows + 1] = { "Auto control", cfg.auto_ctrl and "Yes" or "No" }
        rows[#rows + 1] = { "Low threshold", tostring(math.floor((cfg.threshold_low or 0.25) * 100 + 0.5)) .. "%" }
        rows[#rows + 1] = { "High threshold", tostring(math.floor((cfg.threshold_high or 0.90) * 100 + 0.5)) .. "%" }
        rows[#rows + 1] = { "Update checks", tostring(cfg.update_check_interval or 90) .. "s" }
    end
    return rows
end

local function pageConfirm(cfg)
    local win = drawChrome("Review Configuration")
    local row = 1
    local width = select(1, win.getSize())

    row = writeParagraph(win, row, "Review the configuration below before files are downloaded and written to disk.", STYLE.root_fg)
    row = row + 1

    for _, item in ipairs(summaryRows(cfg)) do
        writeAt(win, 1, row, truncate(item[1], 16), STYLE.label_fg, STYLE.root_bg)
        writeAt(win, 18, row, string.rep(" ", math.max(1, width - 18)), STYLE.value_fg, STYLE.value_bg)
        writeAt(win, 19, row, truncate(item[2], math.max(1, width - 19)), STYLE.value_fg, STYLE.value_bg)
        row = row + 1
    end

    return waitNav(true, "Install", STYLE.install_bg)
end

local function buildPages(cfg, state)
    local pages = {
        function(cfg)
            return pageWelcome(cfg, state)
        end,
    }
    if state.existing_cfg then
        pages[#pages + 1] = function(cfg)
            return pageExistingConfig(cfg, state)
        end
    end
    pages[#pages + 1] = pageRole
    if cfg.role then
        local autoModemSide = resolveAutoModemSide(cfg)
        pages[#pages + 1] = pagePeripherals
        pages[#pages + 1] = pageIdentity
        if autoModemSide then
            pages[#pages + 1] = function(cfg)
                if type(cfg.modem_side) ~= "string" or cfg.modem_side == "" then
                    cfg.modem_side = autoModemSide
                end
                return "forward"
            end
        else
            pages[#pages + 1] = pageModem
        end
        if cfg.role == "controller" or cfg.role == "display" then
            pages[#pages + 1] = pageHardware
        end
        if cfg.role == "controller" then
            pages[#pages + 1] = pageAutoControl
            pages[#pages + 1] = pageUpdateChecks
        end
        pages[#pages + 1] = pageConfirm
    end
    return pages
end

local function runWizard(existingCfg, existingErr)
    local cfg = {}
    local state = {
        existing_cfg = existingCfg,
        existing_err = existingErr,
        use_existing = existingCfg ~= nil,
    }
    local idx = 1

    while true do
        local pages = buildPages(cfg, state)
        if idx > #pages then
            return cfg
        end

        local action = pages[idx](cfg)
        if action == "cancel" then
            return nil
        elseif action == "back" then
            idx = math.max(1, idx - 1)
        else
            idx = idx + 1
        end
    end
end

-- Download helpers -----------------------------------------------------------

local function ensureDir(path)
    if path ~= "" and not fs.isDir(path) then fs.makeDir(path) end
end

local function cacheBust(url, token)
    local sep = url:find("?", 1, true) and "&" or "?"
    return url .. sep .. "_enmon=" .. tostring(token)
end

local function download(url, dest, token)
    local ok, err = pcall(function()
        local response, herr = http.get(cacheBust(url, token or VERSION))
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
    local response, herr = http.get(cacheBust(MANIFEST, tostring(os.epoch and os.epoch("utc") or os.clock())))
    if not response then
        return nil, "HTTP failed: " .. tostring(herr) .. "\nURL: " .. MANIFEST
    end
    local code = response.getResponseCode and response.getResponseCode() or 200
    local raw = response.readAll()
    response.close()
    if code ~= 200 then
        return nil, "HTTP " .. code .. " for manifest"
    end
    local ok, data = pcall(textutils.unserializeJSON, raw)
    if not ok or type(data) ~= "table" then
        return nil, "Manifest parse error"
    end
    data.base_url = BASE_URL
    return data, nil
end

local function writeSourceSelection(branch)
    local file = fs.open(SOURCE_PATH, "w")
    if not file then
        return false, "failed to open " .. tostring(SOURCE_PATH)
    end

    if type(textutils.serializeJSON) == "function" then
        file.write(textutils.serializeJSON({ branch = branch }))
    else
        file.write('{"branch":"' .. tostring(branch):gsub('"', '\\"') .. '"}')
    end
    file.close()
    return true
end

local function makeInstallLogger()
    local win = drawChrome("Installing")
    local _, h = win.getSize()
    local lines = {}
    local scroll_offset = 0

    local function maxOffset()
        return math.max(0, #lines - h)
    end

    local function clampOffset()
        if scroll_offset < 0 then scroll_offset = 0 end
        local limit = maxOffset()
        if scroll_offset > limit then scroll_offset = limit end
    end

    local function redraw()
        clampOffset()
        clearWindow(win, STYLE.root_bg, STYLE.root_fg)
        local start = math.max(1, (#lines - h + 1) - scroll_offset)
        local finish = math.min(#lines, start + h - 1)
        local row = 1
        for i = start, finish do
            local entry = lines[i]
            writeAt(win, 1, row, entry.text, entry.fg or STYLE.root_fg, STYLE.root_bg)
            row = row + 1
        end

        local hint = "Up/down, PgUp/PgDn, mouse wheel: scroll"
        if scroll_offset == 0 then
            hint = hint .. "   Live"
        else
            hint = hint .. string.format("   %d lines above latest", scroll_offset)
        end
        drawHint(hint)
    end

    local function scroll(delta)
        if delta == 0 then return end
        scroll_offset = scroll_offset + delta
        clampOffset()
        redraw()
    end

    local function followLatest()
        if scroll_offset ~= 0 then
            scroll_offset = 0
            redraw()
        end
    end

    local function handleEvent(event, a, b, c)
        if event == "mouse_scroll" then
            local _, win_h = win.getSize()
            if c >= 4 and c < (4 + win_h) then
                scroll(a)
                return true
            end
        elseif event == "key" then
            if a == keys.up then
                scroll(1)
                return true
            elseif a == keys.down then
                scroll(-1)
                return true
            elseif a == keys.pageUp then
                scroll(math.max(1, math.floor(h / 2)))
                return true
            elseif a == keys.pageDown then
                scroll(-math.max(1, math.floor(h / 2)))
                return true
            elseif a == keys.home then
                scroll_offset = maxOffset()
                redraw()
                return true
            elseif a == keys["end"] then
                followLatest()
                return true
            end
        end
        return false
    end

    local function pumpInput()
        local timer = os.startTimer(0.05)
        while true do
            local event, a, b, c = os.pullEvent()
            if event == "timer" and a == timer then
                break
            end
            handleEvent(event, a, b, c)
        end
    end

    local function log(text, fg)
        lines[#lines + 1] = { text = tostring(text), fg = fg }
        if scroll_offset == 0 then
            redraw()
        else
            clampOffset()
            redraw()
        end
        pumpInput()
    end

    redraw()
    return log
end

local function showInstallComplete(role)
    local win = drawChrome("Install Complete")
    local row = 1
    row = writeParagraph(win, row, "ENMON was installed successfully for the " .. tostring(role) .. " role.", STYLE.ok_fg)
    row = row + 1
    row = writeParagraph(win, row, "Selected branch: " .. tostring(INSTALL_BRANCH), STYLE.root_fg)
    row = row + 1
    row = writeParagraph(win, row, "startup.lua has been written by default, so ENMON will launch automatically after a reboot.", STYLE.root_fg)
    row = row + 1
    row = writeParagraph(win, row, "Reboot now to start ENMON, or Exit if you want to reboot later.", STYLE.hint_fg)
    local action = waitNav(false, "Reboot", STYLE.install_bg)
    return action == "forward"
end

-- Main -----------------------------------------------------------------------

cls()

if not http then
    alert("HTTP Disabled", "HTTP is disabled in ComputerCraft. Enable it on the server before running the installer.")
    cls()
    return
end

local existingCfg, existingErr = loadExistingConfig()
local cfg = runWizard(existingCfg, existingErr)
if not cfg then
    cls()
    return
end

local log = makeInstallLogger()
log("Fetching manifest...", STYLE.hint_fg)

local manifest, manifestErr = fetchManifest()
if not manifest then
    log("ERROR: " .. tostring(manifestErr), STYLE.err_fg)
    log("Press any key to exit.", STYLE.hint_fg)
    waitAnyKey()
    cls()
    return
end

log("Manifest fetched.", STYLE.ok_fg)
log("Downloading files for role: " .. cfg.role, STYLE.root_fg)

local files = {}
for _, path in ipairs(manifest.files.common or {}) do files[#files + 1] = path end
for _, path in ipairs(manifest.files[cfg.role] or {}) do files[#files + 1] = path end

local failed = {}
local manifestToken = composeReleaseLabel(manifest.version or VERSION, manifest.manifest_revision or 0)
for _, path in ipairs(files) do
    local ok, err = download(manifest.base_url .. path, path, manifestToken)
    if ok then
        log("[OK]  " .. path, STYLE.ok_fg)
    else
        log("[ERR] " .. path .. " - " .. tostring(err), STYLE.err_fg)
        failed[#failed + 1] = { path = path, err = err }
    end
end

local basaltOk, basaltErr = download(BASALT_URL, "lib/basalt.lua", manifestToken)
if basaltOk then
    log("[OK]  lib/basalt.lua", STYLE.ok_fg)
else
    log("[ERR] lib/basalt.lua - " .. tostring(basaltErr), STYLE.err_fg)
    failed[#failed + 1] = { path = "lib/basalt.lua", err = basaltErr }
end

if #failed > 0 then
    log("Install failed. Check HTTP and download URLs, then re-run installer.", STYLE.err_fg)
    log("Press any key to exit.", STYLE.hint_fg)
    waitAnyKey()
    cls()
    return
end

local okConfig, config = pcall(require, "lib/config")
if okConfig and config then
    config.replace(cfg)
    config.save()
    cfg = config.export()
    log("[OK]  enmon.cfg written (schema v" .. tostring(cfg.config_version or "?") .. ")", STYLE.ok_fg)
else
    local cfgFile = fs.open("enmon.cfg", "w")
    cfgFile.write(textutils.serialize(cfg))
    cfgFile.close()
    log("[OK]  enmon.cfg written", STYLE.ok_fg)
    log("[WARN] Shared config module unavailable; config migration was deferred.", STYLE.warn_fg)
end

local startup = fs.open("startup.lua", "w")
startup.write('shell.run("enmon.lua")\n')
startup.close()
local sourceOk, sourceErr = writeSourceSelection(INSTALL_BRANCH)
if sourceOk then
    log("[OK]  enmon-source.json written", STYLE.ok_fg)
else
    log("[WARN] enmon-source.json - " .. tostring(sourceErr), STYLE.warn_fg)
end
log("[OK]  startup.lua written", STYLE.ok_fg)
log("Installation complete.", STYLE.ok_fg)
log("startup.lua is ready; reboot to launch ENMON.", STYLE.hint_fg)

os.sleep(0.8)

local rebootNow = showInstallComplete(cfg.role)
cls()
if rebootNow then
    os.reboot()
end







