-- ui/config_editor.lua
-- Post-install / standalone config review and editor.
-- Runs on the computer terminal using Basalt 2.

local basalt = require("lib/basalt")
local version = require("lib/version")

local editor = {}

local COLORS = {
    root_bg       = colors.lightGray,
    root_fg       = colors.black,
    header_bg     = colors.gray,
    header_fg     = colors.white,
    section_bg    = colors.lime,
    section_fg    = colors.black,
    tab_bg        = colors.gray,
    tab_fg        = colors.white,
    tab_active_bg = colors.white,
    tab_active_fg = colors.black,
    panel_bg      = colors.lightGray,
    label_fg      = colors.gray,
    hint_fg       = colors.gray,
    value_bg      = colors.white,
    value_fg      = colors.black,
    input_bg      = colors.white,
    input_fg      = colors.black,
    highlight_bg  = colors.blue,
    highlight_fg  = colors.white,
    save_bg       = colors.lightBlue,
    launch_bg     = colors.blue,
    exit_bg       = colors.red,
    button_fg     = colors.black,
    ok_fg         = colors.lime,
    warn_fg       = colors.orange,
    err_fg        = colors.red,
}

local ROLE_LABELS = {
    controller = "Controller",
    matrix     = "Matrix Node",
    reactor    = "Reactor Node",
    display    = "Display Node",
    pocket     = "Pocket",
}

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function truncate(text, width)
    text = tostring(text or "")
    if width <= 0 then return "" end
    if #text <= width then return text end
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
end

local function boolStr(v)
    if v == true then return "Yes" end
    if v == false then return "No" end
    return "--"
end

local function pctStr(v)
    if type(v) == "number" then
        return tostring(math.floor(v * 100 + 0.5)) .. "%"
    end
    return "--"
end

local function normalizeText(raw, optional)
    raw = trim(raw)
    if raw == "" then
        if optional then return true, nil end
        return false, nil, "Field cannot be blank"
    end
    return true, raw
end

local function normalizeNumber(raw, optional, min, max)
    raw = trim(raw)
    if raw == "" then
        if optional then return true, nil end
        return false, nil, "Field cannot be blank"
    end
    local value = tonumber(raw)
    if not value then
        return false, nil, "Field must be numeric"
    end
    if min and value < min then
        return false, nil, "Value is below minimum"
    end
    if max and value > max then
        return false, nil, "Value is above maximum"
    end
    return true, value
end

local function normalizeBool(raw)
    raw = string.lower(trim(raw))
    if raw == "true" or raw == "yes" or raw == "y" or raw == "1" then
        return true, true
    elseif raw == "false" or raw == "no" or raw == "n" or raw == "0" then
        return true, false
    end
    return false, nil, "Use true/false or yes/no"
end

local function normalizePercent(raw)
    raw = trim(raw)
    if raw == "" then
        return false, nil, "Field cannot be blank"
    end
    local value = tonumber(raw)
    if not value then
        return false, nil, "Field must be numeric"
    end
    if value > 1 then value = value / 100 end
    if value < 0 or value > 1 then
        return false, nil, "Use 0-1 or 1-100"
    end
    return true, value
end

local function safeSet(element, key, value)
    if element == nil then return end
    if type(element.set) == "function" then
        element:set(key, value)
    end
end

local function runBasaltLoop()
    if type(basalt.run) == "function" then
        basalt.run()
        return
    end
    if type(basalt.autoUpdate) == "function" then
        basalt.autoUpdate()
        return
    end
    error("Unsupported Basalt version: missing run loop entry point", 0)
end

function editor.run(cfg)
    local w, h = term.getSize()
    local action = "exit"
    local dirty = false
    local currentVersion = version.getVersion()

    local edits = {
        role = cfg.role,
        node_id = cfg.node_id,
        channel = cfg.channel or 42,
        shared_secret = cfg.shared_secret or "enmon_default",
        controller_id = cfg.controller_id,
        monitor_side = cfg.monitor_side,
        speaker_side = cfg.speaker_side,
        auto_ctrl = cfg.auto_ctrl,
        threshold_low = cfg.threshold_low,
        threshold_high = cfg.threshold_high,
    }
    if edits.auto_ctrl == nil then edits.auto_ctrl = true end
    if edits.threshold_low == nil then edits.threshold_low = 0.25 end
    if edits.threshold_high == nil then edits.threshold_high = 0.90 end

    local field_errors = {}
    local panels = {}
    local tabs = {}
    local summary_refs = {}

    local frame = basalt.getMainFrame()
    frame:setBackground(COLORS.root_bg)

    frame:addLabel()
        :setPosition(1, 1):setSize(w, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText(" ENMON Configurator")

    frame:addLabel()
        :setPosition(math.max(1, w - #("v" .. currentVersion)), 1):setSize(#("v" .. currentVersion), 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText("v" .. currentVersion)

    local section = frame:addLabel()
        :setPosition(1, 2):setSize(w, 1)
        :setBackground(COLORS.section_bg):setForeground(COLORS.section_fg)
        :setText(" Summary")

    local status = frame:addLabel()
        :setPosition(1, h - 1):setSize(w, 1)
        :setBackground(COLORS.root_bg):setForeground(COLORS.hint_fg)
        :setText(" Ready")

    local third = math.floor(w / 3)
    local save_w = third
    local launch_w = third
    local exit_w = w - save_w - launch_w

    local save_btn = frame:addButton()
        :setPosition(1, h):setSize(save_w, 1)
        :setBackground(COLORS.save_bg):setForeground(COLORS.button_fg)
        :setText(" Save ")

    local launch_btn = frame:addButton()
        :setPosition(save_w + 1, h):setSize(launch_w, 1)
        :setBackground(COLORS.launch_bg):setForeground(COLORS.button_fg)
        :setText(" Launch ")

    local exit_btn = frame:addButton()
        :setPosition(save_w + launch_w + 1, h):setSize(exit_w, 1)
        :setBackground(COLORS.exit_bg):setForeground(COLORS.button_fg)
        :setText(" Exit ")

    local content_y = 4
    local content_h = h - 5
    local panel_w = math.max(1, w - 2)

    local function setStatus(message, color)
        status:setForeground(color or COLORS.hint_fg)
        status:setText(" " .. truncate(message or "", w - 1))
    end

    local function addTab(key, label, sectionText, x)
        local width = #label + 2
        local button = frame:addButton()
            :setPosition(x, 3):setSize(width, 1)
            :setBackground(COLORS.tab_bg):setForeground(COLORS.tab_fg)
            :setText(" " .. label .. " ")
        tabs[key] = {
            button = button,
            section = sectionText,
        }
        return x + width
    end

    local function newPanel()
        return frame:addFrame()
            :setPosition(2, content_y):setSize(panel_w, content_h)
            :setBackground(COLORS.panel_bg)
            :setVisible(false)
    end

    local function addNote(panel, row, text, color)
        panel:addLabel()
            :setPosition(1, row):setSize(panel_w, 1)
            :setBackground(COLORS.panel_bg):setForeground(color or COLORS.hint_fg)
            :setText(truncate(text, panel_w))
        return row + 1
    end

    local function addSummaryRow(panel, row, label, key, formatter, fg, bg)
        panel:addLabel()
            :setPosition(1, row):setSize(13, 1)
            :setBackground(COLORS.panel_bg):setForeground(COLORS.label_fg)
            :setText(label)
        local value = panel:addLabel()
            :setPosition(14, row):setSize(panel_w - 13, 1)
            :setBackground(bg or COLORS.value_bg):setForeground(fg or COLORS.value_fg)
            :setText("")
        summary_refs[key] = { label = value, formatter = formatter }
        return row + 1
    end

    local function refreshSummary()
        local values = {
            role = ROLE_LABELS[cfg.role] or tostring(cfg.role),
            node_id = cfg.node_id or "--",
            channel = tostring(cfg.channel or "--"),
            shared_secret = cfg.shared_secret or "--",
            controller_id = cfg.controller_id and tostring(cfg.controller_id) or "--",
            monitor_side = cfg.monitor_side or "--",
            speaker_side = cfg.speaker_side or "none",
            auto_ctrl = boolStr(cfg.auto_ctrl),
            threshold_low = pctStr(cfg.threshold_low),
            threshold_high = pctStr(cfg.threshold_high),
        }
        for key, ref in pairs(summary_refs) do
            local text = values[key] or "--"
            if ref.formatter then text = ref.formatter(text) end
            ref.label:setText(" " .. truncate(text, panel_w - 14))
        end
    end

    local function registerInput(panel, row, label, key, initial, normalizer)
        panel:addLabel()
            :setPosition(1, row):setSize(panel_w, 1)
            :setBackground(COLORS.panel_bg):setForeground(COLORS.label_fg)
            :setText(label)
        local input = panel:addInput()
            :setPosition(1, row + 1):setSize(panel_w, 1)
            :setBackground(COLORS.input_bg):setForeground(COLORS.input_fg)
        safeSet(input, "text", initial == nil and "" or tostring(initial))
        input:onChange(function(_, _, raw)
            dirty = true
            local ok, value, err = normalizer(raw)
            if ok then
                edits[key] = value
                field_errors[key] = nil
                setStatus(label .. " updated", COLORS.hint_fg)
            else
                field_errors[key] = label .. ": " .. tostring(err)
                setStatus(field_errors[key], COLORS.err_fg)
            end
        end)
        return row + 3
    end

    local current_x = 1
    current_x = addTab("summary", "Summary", "Summary", current_x)
    current_x = addTab("network", "Network", "Network", current_x)
    if cfg.role == "controller" or cfg.role == "display" then
        current_x = addTab("hardware", "Hardware", "Hardware", current_x)
    end
    if cfg.role == "controller" then
        current_x = addTab("control", "Control", "Control", current_x)
    end

    panels.summary = newPanel()
    do
        local row = 1
        panels.summary:addLabel()
            :setPosition(1, row):setSize(panel_w, 1)
            :setBackground(COLORS.highlight_bg):setForeground(COLORS.highlight_fg)
            :setText(" Computer ID: " .. tostring(os.getComputerID()) .. "  <-- needed by other nodes")
        row = row + 2
        row = addSummaryRow(panels.summary, row, "Role", "role")
        row = addSummaryRow(panels.summary, row, "Node ID", "node_id")
        row = addSummaryRow(panels.summary, row, "Channel", "channel")
        row = addSummaryRow(panels.summary, row, "Secret", "shared_secret")
        if cfg.role ~= "controller" then
            row = addSummaryRow(panels.summary, row, "Controller", "controller_id", nil, COLORS.warn_fg)
        end
        if cfg.role == "controller" or cfg.role == "display" then
            row = addSummaryRow(panels.summary, row, "Monitor", "monitor_side")
        end
        if cfg.role == "controller" then
            row = addSummaryRow(panels.summary, row, "Speaker", "speaker_side")
            row = addSummaryRow(panels.summary, row, "Auto ctrl", "auto_ctrl")
            row = addSummaryRow(panels.summary, row, "Low", "threshold_low")
            row = addSummaryRow(panels.summary, row, "High", "threshold_high")
        end
    end

    panels.network = newPanel()
    do
        local row = 1
        row = addNote(panels.network, row, "Edit identity and network settings for this node.")
        row = row + 1
        row = registerInput(panels.network, row, "Node ID", "node_id", edits.node_id, function(raw)
            return normalizeText(raw, false)
        end)
        row = registerInput(panels.network, row, "Channel (1-65535)", "channel", edits.channel, function(raw)
            return normalizeNumber(raw, false, 1, 65535)
        end)
        row = registerInput(panels.network, row, "Shared secret", "shared_secret", edits.shared_secret, function(raw)
            return normalizeText(raw, false)
        end)
        if cfg.role ~= "controller" then
            row = registerInput(panels.network, row, "Controller computer ID", "controller_id", edits.controller_id, function(raw)
                return normalizeNumber(raw, false, 0)
            end)
        end
    end

    if cfg.role == "controller" or cfg.role == "display" then
        panels.hardware = newPanel()
        do
            local row = 1
            row = addNote(panels.hardware, row, "Assign hardware sides or peripheral names.")
            row = row + 1
            row = registerInput(panels.hardware, row, "Monitor side/name", "monitor_side", edits.monitor_side, function(raw)
                return normalizeText(raw, false)
            end)
            if cfg.role == "controller" then
                row = registerInput(panels.hardware, row, "Speaker side/name", "speaker_side", edits.speaker_side, function(raw)
                    return normalizeText(raw, true)
                end)
                addNote(panels.hardware, row, "Leave speaker blank to disable alert sounds.")
            end
        end
    end

    if cfg.role == "controller" then
        panels.control = newPanel()
        do
            local row = 1
            row = addNote(panels.control, row, "Tune automatic reactor control behavior.")
            row = row + 1
            panels.control:addLabel()
                :setPosition(1, row):setSize(panel_w, 1)
                :setBackground(COLORS.panel_bg):setForeground(COLORS.label_fg)
                :setText("Auto control")
            local checkbox = panels.control:addCheckBox()
                :setPosition(1, row + 1):setSize(panel_w, 1)
                :setForeground(COLORS.value_fg):setBackground(COLORS.panel_bg)
            safeSet(checkbox, "text", "[ ] Disabled")
            safeSet(checkbox, "checkedText", "[x] Enabled")
            safeSet(checkbox, "checked", edits.auto_ctrl == true)
            checkbox:onClick(function(self)
                dirty = true
                edits.auto_ctrl = self:get("checked") == true
                field_errors.auto_ctrl = nil
                setStatus("Auto control updated", COLORS.hint_fg)
            end)
            row = row + 4
            row = registerInput(panels.control, row, "Start reactors below (% or 0-1)", "threshold_low", math.floor((edits.threshold_low or 0.25) * 100 + 0.5), normalizePercent)
            row = registerInput(panels.control, row, "Stop reactors above (% or 0-1)", "threshold_high", math.floor((edits.threshold_high or 0.90) * 100 + 0.5), normalizePercent)
        end
    end

    local function showPanel(key)
        for panelKey, panel in pairs(panels) do
            panel:setVisible(panelKey == key)
        end
        for tabKey, spec in pairs(tabs) do
            if tabKey == key then
                spec.button:setBackground(COLORS.tab_active_bg):setForeground(COLORS.tab_active_fg)
            else
                spec.button:setBackground(COLORS.tab_bg):setForeground(COLORS.tab_fg)
            end
        end
        section:setText(" " .. tabs[key].section)
    end

    for key, spec in pairs(tabs) do
        spec.button:onClick(function() showPanel(key) end)
    end

    local function validateEdits()
        for _, err in pairs(field_errors) do
            if err then
                return false, err
            end
        end
        if trim(edits.node_id) == "" then
            return false, "Node ID is required"
        end
        if type(edits.channel) ~= "number" or edits.channel < 1 or edits.channel > 65535 then
            return false, "Channel must be 1-65535"
        end
        if trim(edits.shared_secret) == "" then
            return false, "Shared secret is required"
        end
        if cfg.role ~= "controller" and type(edits.controller_id) ~= "number" then
            return false, "Controller computer ID must be numeric"
        end
        if (cfg.role == "controller" or cfg.role == "display") and trim(edits.monitor_side) == "" then
            return false, "Monitor side/name is required"
        end
        if cfg.role == "controller" then
            if type(edits.auto_ctrl) ~= "boolean" then
                return false, "Auto control must be true or false"
            end
            if edits.auto_ctrl then
                if type(edits.threshold_low) ~= "number" or type(edits.threshold_high) ~= "number" then
                    return false, "Thresholds must be numeric"
                end
                if edits.threshold_low >= edits.threshold_high then
                    return false, "Low threshold must be below high threshold"
                end
            end
        end
        return true
    end

    local function saveConfig()
        local ok, err = validateEdits()
        if not ok then
            setStatus(err, COLORS.err_fg)
            return
        end

        cfg.node_id = edits.node_id
        cfg.channel = edits.channel
        cfg.shared_secret = edits.shared_secret
        cfg.controller_id = edits.controller_id
        cfg.monitor_side = edits.monitor_side
        cfg.speaker_side = edits.speaker_side
        cfg.auto_ctrl = edits.auto_ctrl
        cfg.threshold_low = edits.threshold_low
        cfg.threshold_high = edits.threshold_high

        local file = fs.open("enmon.cfg", "w")
        file.write(textutils.serialize(cfg))
        file.close()

        dirty = false
        refreshSummary()
        setStatus("Configuration saved.", COLORS.ok_fg)
    end

    save_btn:onClick(saveConfig)
    launch_btn:onClick(function()
        local ok, err = validateEdits()
        if not ok then
            setStatus(err, COLORS.err_fg)
            return
        end
        if dirty then
            saveConfig()
            if dirty then return end
        end
        if dirty then
            setStatus("Unsaved changes. Save before launching.", COLORS.warn_fg)
            return
        end
        action = "launch"
        basalt.stop()
    end)
    exit_btn:onClick(function()
        action = "exit"
        basalt.stop()
    end)

    refreshSummary()
    showPanel("summary")
    runBasaltLoop()

    return action
end

return editor
