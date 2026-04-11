-- ui/config_editor.lua
-- Post-install / standalone config review and editor.
-- Runs on the computer terminal (not the monitor) using Basalt 2.
--
-- Usage:
--   local editor = require("ui/config_editor")
--   local action = editor.run(cfg_table)
--   -- action = "launch" | "exit"
--
-- cfg_table is the raw table of config values (as written to enmon.cfg).
-- If the user edits and saves, cfg_table is mutated in-place and the caller
-- should re-write enmon.cfg.

local basalt = require("lib/basalt")

local editor = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local COLORS = {
    bg         = colors.black,
    header_bg  = colors.gray,
    header_fg  = colors.yellow,
    tab_active = colors.cyan,
    tab_bg     = colors.gray,
    tab_fg     = colors.lightGray,
    label      = colors.lightGray,
    value      = colors.white,
    key_fg     = colors.cyan,
    ok         = colors.lime,
    warn       = colors.orange,
    err        = colors.red,
    btn_launch = colors.lime,
    btn_exit   = colors.red,
    btn_save   = colors.cyan,
    btn_fg     = colors.black,
    input_bg   = colors.gray,
    input_fg   = colors.white,
    sep        = colors.gray,
    panel_bg   = colors.black,
}

local ROLE_LABELS = {
    controller = "Controller",
    matrix     = "Matrix Node",
    reactor    = "Reactor Node",
    display    = "Display Node",
    pocket     = "Pocket",
}

local function boolStr(v)
    if v == true  then return "Yes" end
    if v == false then return "No"  end
    return tostring(v)
end

local function pctStr(v)
    if type(v) == "number" then return math.floor(v * 100) .. "%" end
    return tostring(v)
end

-- ── run(cfg) ──────────────────────────────────────────────────────────────────

function editor.run(cfg)
    local w, h = term.getSize()
    local action = "exit"  -- default if window is closed

    local frame = basalt.getMainFrame()
    frame:setBackground(COLORS.bg)

    -- ── Header bar ────────────────────────────────────────────────────────────
    frame:addLabel()
        :setPosition(1, 1):setSize(w, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText("  ENMON  Node Configuration")

    -- Role label top-right
    local role_label = ROLE_LABELS[cfg.role] or tostring(cfg.role)
    local rl_x = w - #role_label
    frame:addLabel()
        :setPosition(rl_x, 1):setSize(#role_label, 1)
        :setBackground(COLORS.header_bg):setForeground(colors.white)
        :setText(role_label)

    -- ── Tab buttons (row 2) ───────────────────────────────────────────────────
    local TAB_DETAILS = 1
    local TAB_EDIT    = 2
    local current_tab = TAB_DETAILS

    local tab_details_btn = frame:addButton()
        :setPosition(1, 2):setSize(12, 1)
        :setBackground(COLORS.tab_active):setForeground(COLORS.bg)
        :setText(" Details   ")

    local tab_edit_btn = frame:addButton()
        :setPosition(13, 2):setSize(10, 1)
        :setBackground(COLORS.tab_bg):setForeground(COLORS.tab_fg)
        :setText(" Edit     ")

    -- Separator
    frame:addLabel()
        :setPosition(1, 3):setSize(w, 1)
        :setBackground(COLORS.sep):setForeground(COLORS.sep)
        :setText(string.rep(" ", w))

    -- ── Bottom bar ────────────────────────────────────────────────────────────
    local BTN_ROW = h
    frame:addLabel()
        :setPosition(1, BTN_ROW - 1):setSize(w, 1)
        :setBackground(COLORS.sep):setForeground(COLORS.sep)
        :setText(string.rep(" ", w))

    local launch_btn = frame:addButton()
        :setPosition(1, BTN_ROW):setSize(math.floor(w / 2) - 1, 1)
        :setBackground(COLORS.btn_launch):setForeground(COLORS.btn_fg)
        :setText("  Launch ENMON  ")

    local exit_btn = frame:addButton()
        :setPosition(math.floor(w / 2) + 1, BTN_ROW):setSize(w - math.floor(w / 2), 1)
        :setBackground(COLORS.btn_exit):setForeground(COLORS.btn_fg)
        :setText("  Exit  ")

    -- ── Content area bounds ───────────────────────────────────────────────────
    local CONTENT_Y = 4
    local CONTENT_H = h - 4  -- rows 4 .. h-2

    -- ────────────────────────────────────────────────────────────────────────
    -- DETAILS PANEL
    -- ────────────────────────────────────────────────────────────────────────
    local details_panel = frame:addFrame()
        :setPosition(1, CONTENT_Y):setSize(w, CONTENT_H)
        :setBackground(COLORS.panel_bg)

    local function addDetailRow(panel, row, key, value, vcolor)
        panel:addLabel()
            :setPosition(2, row):setSize(16, 1)
            :setBackground(COLORS.panel_bg):setForeground(COLORS.label)
            :setText(key)
        panel:addLabel()
            :setPosition(18, row):setSize(w - 18, 1)
            :setBackground(COLORS.panel_bg):setForeground(vcolor or COLORS.value)
            :setText(tostring(value or "--"))
    end

    -- Computer ID row — highlighted prominently
    local comp_id_str = tostring(os.getComputerID())
    details_panel:addLabel()
        :setPosition(1, 1):setSize(w, 1)
        :setBackground(colors.blue):setForeground(colors.white)
        :setText("  Computer ID: " .. comp_id_str
                 .. "  <-- needed by other nodes")

    local row = 3
    addDetailRow(details_panel, row, "Role:",          ROLE_LABELS[cfg.role] or cfg.role)
    row = row + 1
    addDetailRow(details_panel, row, "Node ID:",       cfg.node_id)
    row = row + 1
    addDetailRow(details_panel, row, "Channel:",       tostring(cfg.channel or 42))
    row = row + 1
    addDetailRow(details_panel, row, "Shared secret:", cfg.shared_secret)

    if cfg.role ~= "controller" then
        row = row + 1
        addDetailRow(details_panel, row, "Controller ID:", tostring(cfg.controller_id or "--"), COLORS.warn)
    end

    if cfg.role == "controller" or cfg.role == "display" then
        row = row + 1
        addDetailRow(details_panel, row, "Monitor:",    cfg.monitor_side or "--")
    end
    if cfg.role == "controller" then
        row = row + 1
        addDetailRow(details_panel, row, "Speaker:",    cfg.speaker_side or "none")
        row = row + 1
        addDetailRow(details_panel, row, "Auto-ctrl:",  boolStr(cfg.auto_ctrl))
        if cfg.auto_ctrl then
            row = row + 1
            addDetailRow(details_panel, row, "Thresh low:", pctStr(cfg.threshold_low))
            row = row + 1
            addDetailRow(details_panel, row, "Thresh high:", pctStr(cfg.threshold_high))
        end
    end

    -- ────────────────────────────────────────────────────────────────────────
    -- EDIT PANEL
    -- ────────────────────────────────────────────────────────────────────────
    local edit_panel = frame:addFrame()
        :setPosition(1, CONTENT_Y):setSize(w, CONTENT_H)
        :setBackground(COLORS.panel_bg)
        :setVisible(false)

    -- Working copy — edits happen here, only applied on Save
    local edits = {}
    for k, v in pairs(cfg) do edits[k] = v end

    local status_lbl = edit_panel:addLabel()
        :setPosition(1, CONTENT_H):setSize(w, 1)
        :setBackground(COLORS.panel_bg):setForeground(COLORS.label)
        :setText("")

    local function setStatus(msg, color)
        status_lbl:setText("  " .. msg):setForeground(color or COLORS.label)
    end

    -- Helper: add a labelled input field. Returns the input element.
    local inputs = {}
    local irow = 1

    local function addInput(panel, label, cfg_key, convert_fn)
        panel:addLabel()
            :setPosition(2, irow):setSize(w - 2, 1)
            :setBackground(COLORS.panel_bg):setForeground(COLORS.label)
            :setText(label)
        irow = irow + 1

        local inp = panel:addInput()
            :setPosition(2, irow):setSize(w - 3, 1)
            :setBackground(COLORS.input_bg):setForeground(COLORS.input_fg)
            :setDefaultText(tostring(edits[cfg_key] or ""))

        irow = irow + 2  -- gap

        inp:onChange(function(_, _, value)
            if convert_fn then
                local converted = convert_fn(value)
                if converted ~= nil then
                    edits[cfg_key] = converted
                    setStatus("  " .. cfg_key .. " = " .. tostring(converted), COLORS.ok)
                else
                    setStatus("  Invalid value for " .. cfg_key, COLORS.err)
                end
            else
                edits[cfg_key] = value
            end
        end)

        inputs[cfg_key] = inp
        return inp
    end

    local function toNum(s) return tonumber(s) end
    local function toBool(s)
        s = tostring(s):lower()
        if s == "true" or s == "yes" or s == "1" then return true  end
        if s == "false" or s == "no"  or s == "0" then return false end
        return nil
    end
    local function toPct(s)
        local n = tonumber(s)
        if not n then return nil end
        -- Accept 0-1 directly or 1-100 as percentage
        if n > 1 then n = n / 100 end
        if n < 0 or n > 1 then return nil end
        return n
    end

    addInput(edit_panel, "Node ID:", "node_id")
    addInput(edit_panel, "Channel (1-65535):", "channel", toNum)
    addInput(edit_panel, "Shared secret:", "shared_secret")

    if cfg.role ~= "controller" then
        addInput(edit_panel, "Controller computer ID:", "controller_id", toNum)
    end
    if cfg.role == "controller" or cfg.role == "display" then
        addInput(edit_panel, "Monitor side/name:", "monitor_side")
    end
    if cfg.role == "controller" then
        addInput(edit_panel, "Speaker side (blank=none):", "speaker_side")
        addInput(edit_panel, "Auto-ctrl (true/false):", "auto_ctrl", toBool)
        addInput(edit_panel, "Thresh low (% or 0-1):", "threshold_low",  toPct)
        addInput(edit_panel, "Thresh high (% or 0-1):", "threshold_high", toPct)
    end

    -- Save button inside edit panel
    local save_x = w - 10
    edit_panel:addButton()
        :setPosition(save_x, CONTENT_H):setSize(w - save_x + 1, 1)
        :setBackground(COLORS.btn_save):setForeground(COLORS.btn_fg)
        :setText(" Save ")
        :onClick(function()
            -- Apply edits back to the live cfg table
            for k, v in pairs(edits) do cfg[k] = v end
            -- Re-write enmon.cfg
            local f = fs.open("enmon.cfg", "w")
            f.write(textutils.serialize(cfg))
            f.close()
            setStatus("Config saved!", COLORS.ok)
        end)

    -- ── Tab switching ─────────────────────────────────────────────────────────
    local function showTab(tab)
        current_tab = tab
        if tab == TAB_DETAILS then
            details_panel:setVisible(true)
            edit_panel:setVisible(false)
            tab_details_btn:setBackground(COLORS.tab_active):setForeground(COLORS.bg)
            tab_edit_btn:setBackground(COLORS.tab_bg):setForeground(COLORS.tab_fg)
        else
            details_panel:setVisible(false)
            edit_panel:setVisible(true)
            tab_details_btn:setBackground(COLORS.tab_bg):setForeground(COLORS.tab_fg)
            tab_edit_btn:setBackground(COLORS.tab_active):setForeground(COLORS.bg)
        end
    end

    tab_details_btn:onClick(function() showTab(TAB_DETAILS) end)
    tab_edit_btn:onClick(function() showTab(TAB_EDIT) end)

    -- ── Bottom button callbacks ───────────────────────────────────────────────
    launch_btn:onClick(function()
        action = "launch"
        basalt.stop()
    end)
    exit_btn:onClick(function()
        action = "exit"
        basalt.stop()
    end)

    -- ── Start Basalt event loop ───────────────────────────────────────────────
    basalt.autoUpdate()

    return action
end

return editor
