-- ui/controller_hud.lua
-- Basalt 2 HUD for the Controller node.
-- Provides both the runtime overview and a dedicated update/operator pane.

local util = require("lib/util")
local graph = require("lib/graph")
local basalt = require("lib/basalt")

local hud = {}

local _cfg = nil
local _ctrl = nil
local _frame = nil
local _data = {}
local _monitor_w = 0
local _monitor_h = 0
local _view = "overview"
local _selected_node_id = nil
local _update_page = 1

local _overview = { reactor_entries = {} }
local _updates = { row_buttons = {}, row_node_ids = {}, action_state = {} }
local _chrome = {}
local renderUpdates

local HEADER_H = 2
local UPDATES_HEADER_ROWS = 4
local UPDATES_FOOTER_ROWS = 1
local UPDATES_LIST_START = 5

local COLORS = {
    bg = colors.black,
    panel_bg = colors.black,
    panel_alt = colors.gray,
    header_bg = colors.gray,
    header_fg = colors.yellow,
    tab_bg = colors.lightGray,
    tab_fg = colors.black,
    tab_active_bg = colors.blue,
    tab_active_fg = colors.white,
    label = colors.white,
    value = colors.cyan,
    muted = colors.lightGray,
    ok_fg = colors.green,
    warn_fg = colors.orange,
    alert_fg = colors.red,
    bar_full = colors.green,
    bar_empty = colors.gray,
    btn_on = colors.green,
    btn_off = colors.red,
    btn_fg = colors.white,
    action_bg = colors.blue,
    neutral_bg = colors.gray,
    list_bg = colors.black,
    list_selected_bg = colors.blue,
    list_selected_fg = colors.white,
}

local function truncate(text, width)
    text = tostring(text or "")
    if width <= 0 then return "" end
    if #text <= width then return text end
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
end

local function setGraphRows(labels, rows, width, fg)
    local blank = string.rep(" ", math.max(1, width or 1))
    for index, label in ipairs(labels or {}) do
        label:setText(rows and rows[index] or blank)
        if fg then
            label:setForeground(fg)
        end
    end
end

local function barColor(fill)
    if fill >= 0.75 then return colors.green end
    if fill >= 0.40 then return colors.yellow end
    return colors.red
end

local function reactorStatusColor(active)
    return active and colors.green or colors.red
end

local function statusColor(status)
    if status == "online-current" or status == "success" or status == "offered" then
        return COLORS.ok_fg, COLORS.list_bg
    end
    if status == "queued" or status == "checking" or status == "ack" or status == "in_progress" or status == "starting" or status == "abort-requested" then
        return COLORS.value, COLORS.list_bg
    end
    if status == "unlinked" or status == "pending-offline" or status == "wrong-controller" or status == "version-mismatch" or status == "no-check-response" or status == "cannot-abort" or status == "aborted" or status == "adopting" then
        return COLORS.warn_fg, COLORS.list_bg
    end
    if status == "identity-conflict" or status == "failed" or status == "timeout" or status == "rejected-no-offer" then
        return COLORS.alert_fg, COLORS.list_bg
    end
    return COLORS.label, COLORS.list_bg
end

local function applyActionButton(button, enabled, active_bg, active_fg, active_text)
    if not button then return end
    if enabled then
        button:setBackground(active_bg):setForeground(active_fg)
        button:setText(active_text)
    else
        button:setBackground(COLORS.neutral_bg):setForeground(COLORS.muted)
        button:setText(active_text)
    end
end

local function setView(view)
    if view ~= "overview" and view ~= "updates" then
        view = "overview"
    end
    _view = view
    _overview.frame:setVisible(view == "overview")
    _updates.frame:setVisible(view == "updates")
    if _chrome.header then
        local title = view == "overview" and "  ENMON  Controller / Overview" or "  ENMON  Controller / Updates"
        local clock_w = 9
        _chrome.header:setText(truncate(title, math.max(1, _monitor_w - clock_w - 1)))
    end
end

local function ensureSelection(snapshot)
    local nodes = snapshot and snapshot.nodes or {}
    if _selected_node_id == nil then return end
    for _, node in ipairs(nodes) do
        if node.node_id == _selected_node_id then return end
    end
    _selected_node_id = nil
end

local function listRowsPerPage()
    return math.max(2, (_monitor_h - HEADER_H) - UPDATES_HEADER_ROWS - UPDATES_FOOTER_ROWS - 2)
end

local function getSelectedNodeSnapshot(snapshot)
    if not snapshot then return nil end
    if _selected_node_id == nil then return nil end
    for _, node in ipairs(snapshot.nodes or {}) do
        if node.node_id == _selected_node_id then return node end
    end
    return nil
end

local function setSelection(node_id)
    _selected_node_id = node_id
    renderUpdates(_data or {})
end

local function pageSelection(delta)
    local snapshot = _data.updates or { nodes = {} }
    local rows = {{ node_id = nil }}
    for _, node in ipairs(snapshot.nodes or {}) do
        rows[#rows + 1] = node
    end

    local current_index = 1
    if _selected_node_id ~= nil then
        for index, node in ipairs(rows) do
            if node.node_id == _selected_node_id then
                current_index = index
                break
            end
        end
    end

    current_index = math.max(1, math.min(#rows, current_index + delta))
    _selected_node_id = rows[current_index].node_id

    local per_page = listRowsPerPage()
    _update_page = math.max(1, math.ceil(current_index / per_page))
    renderUpdates(_data or {})
end

local function ensureReactorEntry(nid, row)
    local max_row = (_monitor_h or 0) - 1
    if row + 2 > max_row then
        return nil
    end

    local entry = _overview.reactor_entries[nid]
    if entry then
        entry.label:setPosition(_overview.rx_x, row)
        entry.detail:setPosition(_overview.rx_x, row + 1)
        entry.btn:setPosition(_overview.rx_x, row + 2)
        entry.rod_down:setPosition(_overview.rx_x + 7, row + 2)
        entry.rod_up:setPosition(_overview.rx_x + 12, row + 2)
        return entry
    end

    entry = {}
    entry.label = _overview.frame:addLabel()
        :setPosition(_overview.rx_x, row):setSize(_overview.rx_w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label)
        :setText(nid .. ": --")

    entry.detail = _overview.frame:addLabel()
        :setPosition(_overview.rx_x, row + 1):setSize(_overview.rx_w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.muted)
        :setText("")

    entry.btn = _overview.frame:addButton()
        :setPosition(_overview.rx_x, row + 2):setSize(6, 1)
        :setText(" ON  "):setBackground(COLORS.btn_off):setForeground(COLORS.btn_fg)
        :onClick(function()
            if _ctrl then
                local reactor = _data.reactors and _data.reactors[nid]
                local want = not (reactor and reactor.active)
                _ctrl.setReactorActive(nid, want)
            end
        end)

    entry.rod_down = _overview.frame:addButton()
        :setPosition(_overview.rx_x + 7, row + 2):setSize(4, 1)
        :setText("R- "):setBackground(COLORS.neutral_bg):setForeground(COLORS.btn_fg)
        :onClick(function()
            if _ctrl then
                _ctrl.adjustReactorControlRod(nid, -5)
            end
        end)

    entry.rod_up = _overview.frame:addButton()
        :setPosition(_overview.rx_x + 12, row + 2):setSize(4, 1)
        :setText("R+ "):setBackground(COLORS.action_bg):setForeground(COLORS.btn_fg)
        :onClick(function()
            if _ctrl then
                _ctrl.adjustReactorControlRod(nid, 5)
            end
        end)

    _overview.reactor_entries[nid] = entry
    return entry
end

local function ensureGeneratorEntry(nid, row)
    local max_row = (_monitor_h or 0) - 1
    if row + 2 > max_row then
        return nil
    end

    _overview.generator_entries = _overview.generator_entries or {}
    local entry = _overview.generator_entries[nid]
    if entry then
        entry.label:setPosition(_overview.rx_x, row)
        entry.detail:setPosition(_overview.rx_x, row + 1)
        entry.btn:setPosition(_overview.rx_x, row + 2)
        return entry
    end

    entry = {}
    entry.label = _overview.frame:addLabel()
        :setPosition(_overview.rx_x, row):setSize(_overview.rx_w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label)
        :setText(nid .. ": --")

    entry.detail = _overview.frame:addLabel()
        :setPosition(_overview.rx_x, row + 1):setSize(_overview.rx_w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.muted)
        :setText("")

    entry.btn = _overview.frame:addButton()
        :setPosition(_overview.rx_x, row + 2):setSize(6, 1)
        :setText(" ON  "):setBackground(COLORS.btn_off):setForeground(COLORS.btn_fg)
        :onClick(function()
            if _ctrl then
                local generator = _data.generators and _data.generators[nid]
                local want = not (generator and generator.active)
                _ctrl.setGeneratorActive(nid, want)
            end
        end)

    _overview.generator_entries[nid] = entry
    return entry
end

local function buildOverview(frame, w, h)
    local e = { reactor_entries = {}, generator_entries = {} }
    local frame_h = h - 2
    e.frame = frame:addFrame():setPosition(1, 3):setSize(w, frame_h):setBackground(COLORS.bg)
    local localFrame = e.frame
    local wide = w >= 51
    e.wide = wide

    if wide then
        local lw = math.floor(w / 2) - 1
        local rx = math.floor(w / 2) + 2
        local py = 2

        e.mat_title = localFrame:addLabel()
            :setPosition(2, py):setSize(lw, 1):setBackground(COLORS.bg)
            :setForeground(colors.yellow):setText("[ Induction Matrix ]")

        localFrame:addLabel():setPosition(2, py + 1):setSize(8, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.label):setText("Stored:")
        e.mat_stored_val = localFrame:addLabel()
            :setPosition(11, py + 1):setSize(lw - 9, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.value):setText("--")

        localFrame:addLabel():setPosition(2, py + 2):setSize(8, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.label):setText("Max:")
        e.mat_max_val = localFrame:addLabel()
            :setPosition(11, py + 2):setSize(lw - 9, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.value):setText("--")

        localFrame:addLabel():setPosition(2, py + 3):setSize(8, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.label):setText("Input:")
        e.mat_in_val = localFrame:addLabel()
            :setPosition(11, py + 3):setSize(lw - 9, 1):setBackground(COLORS.bg)
            :setForeground(colors.lime):setText("--")

        localFrame:addLabel():setPosition(2, py + 4):setSize(8, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.label):setText("Output:")
        e.mat_out_val = localFrame:addLabel()
            :setPosition(11, py + 4):setSize(lw - 9, 1):setBackground(COLORS.bg)
            :setForeground(colors.orange):setText("--")

        e.mat_fill_summary = localFrame:addLabel()
            :setPosition(2, py + 7):setSize(lw, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.value):setText("Fill --")

        e.hist_fill_rows = {}
        for index = 1, 3 do
            e.hist_fill_rows[index] = localFrame:addLabel()
                :setPosition(2, py + 7 + index):setSize(lw, 1):setBackground(COLORS.bg)
                :setForeground(COLORS.value):setText(string.rep(" ", lw))
        end

        e.mat_output_summary = localFrame:addLabel()
            :setPosition(2, py + 11):setSize(lw, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.muted):setText("In --  Out --")

        e.meter_io_lbl = localFrame:addLabel()
            :setPosition(2, py + 12):setSize(lw, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.value):setText("IO --")

        e.hist_graph_w = math.max(8, lw - 2)
        e.hist_graph_h = 3

        e.rx_title = localFrame:addLabel()
            :setPosition(rx, py):setSize(w - rx, 1):setBackground(COLORS.bg)
            :setForeground(colors.yellow):setText("[ Reactors / Gens ]")

        e.rx_x = rx
        e.rx_w = w - rx

        e.thresh_lbl = localFrame:addLabel()
            :setPosition(2, frame_h):setSize(w - 2, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.muted):setText("AutoCtrl: OFF  Low: --  High: --")
    else
        local py = 2
        e.mat_title = localFrame:addLabel()
            :setPosition(1, py):setSize(w, 1):setBackground(COLORS.bg)
            :setForeground(colors.yellow):setText("[Matrix]")

        e.mat_stored_val = localFrame:addLabel()
            :setPosition(1, py + 1):setSize(w, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.value):setText("--")

        e.mat_fill_summary = localFrame:addLabel()
            :setPosition(1, py + 2):setSize(w, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.value):setText("Fill --")

        e.hist_fill_rows = {}
        for index = 1, 2 do
            e.hist_fill_rows[index] = localFrame:addLabel()
                :setPosition(1, py + 2 + index):setSize(w, 1):setBackground(COLORS.bg)
                :setForeground(COLORS.value):setText(string.rep(" ", w))
        end

        e.mat_output_summary = localFrame:addLabel()
            :setPosition(1, py + 5):setSize(w, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.muted):setText("In --  Out --")

        e.meter_io_lbl = localFrame:addLabel()
            :setPosition(1, py + 6):setSize(w, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.value):setText("IO --")

        e.hist_graph_w = math.max(6, w)
        e.hist_graph_h = 2

        e.rx_title = localFrame:addLabel()
            :setPosition(1, py + 8):setSize(w, 1):setBackground(COLORS.bg)
            :setForeground(colors.yellow):setText("[Reactors/Gens]")

        e.rx_x = 1
        e.rx_w = w
        e.thresh_lbl = nil
    end

    return e
end

local function buildUpdates(frame, w, h)
    local e = { row_buttons = {}, row_node_ids = {}, action_state = {} }
    e.frame = frame:addFrame():setPosition(1, HEADER_H + 1):setSize(w, h - HEADER_H):setBackground(COLORS.bg)
    local localFrame = e.frame
    local content_h = h - HEADER_H
    local per_page = listRowsPerPage()
    local selected_w = math.max(1, w - 13)

    e.summary = localFrame:addLabel()
        :setPosition(1, 1):setSize(w, 1):setBackground(COLORS.bg)
        :setForeground(colors.yellow):setText("Controller --  Latest --  Phase idle")

    e.counts = localFrame:addLabel()
        :setPosition(1, 2):setSize(w, 1):setBackground(COLORS.bg)
        :setForeground(COLORS.muted):setText("Q:0 Pend:0 Conflict:0 Wrong:0 Offered:0")

    e.selected = localFrame:addLabel()
        :setPosition(1, 3):setSize(selected_w, 1):setBackground(COLORS.bg)
        :setForeground(COLORS.value):setText("Selected: ALL eligible nodes")

    e.prev_btn = localFrame:addButton()
        :setPosition(math.max(1, selected_w + 1), 3):setSize(6, 1)
        :setBackground(COLORS.neutral_bg):setForeground(COLORS.btn_fg)
        :setText(" Prev ")
        :onClick(function() pageSelection(-1) end)

    e.next_btn = localFrame:addButton()
        :setPosition(math.max(1, w - 5), 3):setSize(5, 1)
        :setBackground(COLORS.neutral_bg):setForeground(COLORS.btn_fg)
        :setText("Next ")
        :onClick(function() pageSelection(1) end)

    e.detail = localFrame:addLabel()
        :setPosition(1, 4):setSize(w, 1):setBackground(COLORS.bg)
        :setForeground(COLORS.label):setText("Check for updates, offer to selected nodes, then start or abort.")

    local list_y = UPDATES_LIST_START
    for index = 1, per_page do
        e.row_buttons[index] = localFrame:addButton()
            :setPosition(1, list_y + index - 1):setSize(w, 1)
            :setBackground(COLORS.list_bg):setForeground(COLORS.label)
            :setText("")
            :onClick(function(self)
                local node_id = e.row_node_ids and e.row_node_ids[index] or nil
                setSelection(node_id)
            end)
    end

    local action_y = content_h - 1
    local button_w = math.max(6, math.floor(w / 5))
    local x = 1

    e.check_btn = localFrame:addButton()
        :setPosition(x, action_y):setSize(button_w, 1)
        :setBackground(COLORS.action_bg):setForeground(COLORS.btn_fg)
        :setText(" Check ")
        :onClick(function()
            if _ctrl then _ctrl.requestUpdateCheck() end
        end)
    x = x + button_w

    e.offer_btn = localFrame:addButton()
        :setPosition(x, action_y):setSize(button_w, 1)
        :setBackground(COLORS.action_bg):setForeground(COLORS.btn_fg)
        :setText(" Offer ")
        :onClick(function()
            if _ctrl and e.action_state.offer then _ctrl.offerUpdates(_selected_node_id) end
        end)
    x = x + button_w

    e.start_btn = localFrame:addButton()
        :setPosition(x, action_y):setSize(button_w, 1)
        :setBackground(colors.green):setForeground(COLORS.btn_fg)
        :setText(" Start ")
        :onClick(function()
            if _ctrl and e.action_state.start then _ctrl.startOfferedUpdates() end
        end)
    x = x + button_w

    e.abort_btn = localFrame:addButton()
        :setPosition(x, action_y):setSize(button_w, 1)
        :setBackground(colors.red):setForeground(COLORS.btn_fg)
        :setText(" Abort ")
        :onClick(function()
            if _ctrl and e.action_state.abort then _ctrl.abortUpdates() end
        end)
    x = x + button_w

    e.adopt_btn = localFrame:addButton()
        :setPosition(x, action_y):setSize(math.max(1, w - x + 1), 1)
        :setBackground(COLORS.neutral_bg):setForeground(COLORS.btn_fg)
        :setText(" Adopt ")
        :onClick(function()
            if _ctrl and e.action_state.adopt then _ctrl.adoptReplacement(_selected_node_id) end
        end)

    return e
end

local function renderOverview(data)
    local e = _overview
    if not e.frame then return end
    local energy_unit = data.energy_unit or "FE"

    local matrix = data.matrix
    local samples = data.history or {}
    if matrix and not data.matrix_stale then
        local fill = util.fillFraction(matrix.energy, matrix.max_energy)
        e.mat_stored_val:setText(util.formatEnergy(matrix.energy, energy_unit))
        if e.mat_max_val then e.mat_max_val:setText(util.formatEnergy(matrix.max_energy, energy_unit)) end
        if e.mat_in_val then e.mat_in_val:setText("+" .. util.formatRate(matrix.last_input, energy_unit)) end
        if e.mat_out_val then e.mat_out_val:setText("-" .. util.formatRate(matrix.last_output, energy_unit)) end
        e.mat_fill_summary:setText("Fill " .. util.formatPercent(fill) .. "  " .. tostring(data.matrix_eta or "ETA --") .. "  Recent " .. select(2, graph.renderMatrixFillBars(samples, e.hist_graph_w or 10, e.hist_graph_h or 2)))
        local matrix_count = tonumber(data.matrix_count) or 0
        local count_prefix = matrix_count > 1 and (tostring(matrix_count) .. "x ") or ""
        e.mat_output_summary:setText(truncate(count_prefix .. "In +" .. util.formatRate(matrix.last_input, energy_unit) .. "  Out -" .. util.formatRate(matrix.last_output, energy_unit), e.wide and (e.hist_graph_w or e.rx_w) or e.rx_w))
        local fill_rows = select(1, graph.renderMatrixFillBars(samples, e.hist_graph_w or 10, e.hist_graph_h or 2))
        setGraphRows(e.hist_fill_rows, fill_rows, e.hist_graph_w or e.rx_w, barColor(fill))
    else
        e.mat_stored_val:setText("DISCONNECTED")
        if e.mat_max_val then e.mat_max_val:setText("--") end
        if e.mat_in_val then e.mat_in_val:setText("--") end
        if e.mat_out_val then e.mat_out_val:setText("--") end
        e.mat_fill_summary:setText("Fill --")
        e.mat_output_summary:setText("In --  Out --")
        local fill_rows = select(1, graph.renderMatrixFillBars(samples, e.hist_graph_w or 10, e.hist_graph_h or 2))
        setGraphRows(e.hist_fill_rows, fill_rows, e.hist_graph_w or e.rx_w, COLORS.muted)
    end

    if e.meter_io_lbl then
        local meter_io = data.meter_io
        if meter_io and not data.meter_stale then
            local count = tonumber(data.meter_count) or tonumber(meter_io.meter_count) or 0
            local prefix = count > 1 and (tostring(count) .. "x IO ") or "IO "
            e.meter_io_lbl:setText(truncate(
                prefix .. util.formatRate(meter_io.rate or 0, energy_unit) ..
                "  +" .. util.formatRate(meter_io.last_input or 0, energy_unit) ..
                " / -" .. util.formatRate(meter_io.last_output or 0, energy_unit),
                e.wide and (e.hist_graph_w or e.rx_w) or e.rx_w
            ))
            e.meter_io_lbl:setForeground(COLORS.value)
        else
            e.meter_io_lbl:setText("IO --")
            e.meter_io_lbl:setForeground(COLORS.muted)
        end
    end

    local row = e.wide and 2 or 10
    for nid, reactor in pairs(data.reactors or {}) do
        local entry = ensureReactorEntry(nid, row)
        if entry then
            local stale = (os.clock() - (reactor.updated or 0)) > 10
            if stale then
                entry.label:setText(truncate(tostring(nid) .. "  OFFLINE", e.rx_w))
                entry.detail:setText("Awaiting telemetry")
                entry.label:setForeground(COLORS.alert_fg)
                entry.detail:setForeground(COLORS.muted)
            else
                local line_one, line_two = graph.reactorOverviewLines(nid, reactor, energy_unit)
                entry.label:setText(truncate(line_one, e.rx_w))
                entry.detail:setText(truncate(line_two, e.rx_w))
                entry.label:setForeground(reactorStatusColor(reactor.active))
                entry.detail:setForeground(COLORS.muted)
            end
            if reactor.active then
                entry.btn:setText(" OFF "):setBackground(COLORS.btn_on)
            else
                entry.btn:setText(" ON  "):setBackground(COLORS.btn_off)
            end
            if reactor.control_rod_level ~= nil then
                entry.rod_down:setBackground(COLORS.neutral_bg):setForeground(COLORS.btn_fg)
                entry.rod_up:setBackground(COLORS.action_bg):setForeground(COLORS.btn_fg)
            else
                entry.rod_down:setBackground(COLORS.neutral_bg):setForeground(COLORS.muted)
                entry.rod_up:setBackground(COLORS.neutral_bg):setForeground(COLORS.muted)
            end
            row = row + 3
        end
    end

    for nid, generator in pairs(data.generators or {}) do
        local entry = ensureGeneratorEntry(nid, row)
        if entry then
            local stale = (os.clock() - (generator.updated or 0)) > 10
            if stale then
                entry.label:setText(truncate("G " .. tostring(nid) .. "  OFFLINE", e.rx_w))
                entry.detail:setText("Awaiting telemetry")
                entry.label:setForeground(COLORS.alert_fg)
                entry.detail:setForeground(COLORS.muted)
            else
                local status = generator.active and "ON" or "OFF"
                entry.label:setText(truncate("G " .. tostring(nid) .. "  " .. status, e.rx_w))
                entry.detail:setText(truncate(util.formatRate(generator.produced_last_t or 0, energy_unit), e.rx_w))
                entry.label:setForeground(reactorStatusColor(generator.active))
                entry.detail:setForeground(COLORS.muted)
            end
            if generator.controllable == false then
                entry.btn:setText("  -- "):setBackground(COLORS.neutral_bg):setForeground(COLORS.muted)
            elseif generator.active then
                entry.btn:setText(" OFF "):setBackground(COLORS.btn_on)
            else
                entry.btn:setText(" ON  "):setBackground(COLORS.btn_off)
            end
            row = row + 3
        end
    end

    if e.thresh_lbl then
        local auto = _cfg.get("auto_ctrl") and "ON" or "OFF"
        e.thresh_lbl:setText("AutoCtrl: " .. auto .. "  Low: " .. util.formatPercent(_cfg.get("threshold_low")) .. "  High: " .. util.formatPercent(_cfg.get("threshold_high")))
    end
end

renderUpdates = function(data)
    local e = _updates
    if not e.frame then return end

    local snapshot = data.updates or { controller_version = "--", latest_version = "--", phase = "idle", counts = {}, nodes = {} }
    ensureSelection(snapshot)

    e.summary:setText(truncate(
        "Controller " .. tostring(snapshot.controller_version or "--") ..
        "  Latest " .. tostring(snapshot.latest_version or "--") ..
        "  Phase " .. tostring(snapshot.phase or "idle"),
        _monitor_w
    ))

    local counts = snapshot.counts or {}
    e.counts:setText(truncate(
        "Q:" .. tostring(counts.queued or 0) ..
        "  Unlk:" .. tostring(counts.unlinked or 0) ..
        "  Pend:" .. tostring(counts.pending_offline or 0) ..
        "  Conflict:" .. tostring(counts.identity_conflict or 0) ..
        "  Wrong:" .. tostring(counts.wrong_controller or 0) ..
        "  Offered:" .. tostring(counts.offered or 0),
        _monitor_w
    ))

    local selected = getSelectedNodeSnapshot(snapshot)
    if selected then
        e.selected:setText(truncate(
            "Selected: " .. tostring(selected.node_id) .. "  " .. tostring(selected.role) .. "  " .. tostring(selected.version_display or selected.local_version) .. "  " .. tostring(selected.status),
            math.max(1, _monitor_w - 14)
        ))
        e.detail:setText(truncate(selected.note or "Offer/start/abort update actions for the selected node.", _monitor_w))
    else
        e.selected:setText(truncate("Selected: ALL eligible nodes", math.max(1, _monitor_w - 14)))
        if snapshot.offer then
            e.detail:setText(truncate("Offer ready for " .. tostring(snapshot.offer.target_count) .. " live node(s), " .. tostring(snapshot.offer.pending_count) .. " pending offline", _monitor_w))
        elseif snapshot.rollout then
            e.detail:setText(truncate("Rollout current: " .. tostring(snapshot.rollout.current or "--") .. "  queued: " .. tostring(snapshot.rollout.queued or 0), _monitor_w))
        else
            e.detail:setText(truncate("Check, offer, start, abort, or adopt a selected unlinked node.", _monitor_w))
        end
    end

    local selected_is_controller = selected and selected.role == "controller"
    local offer_enabled = not selected_is_controller
    local start_enabled = (snapshot.offer ~= nil) and not selected_is_controller
    local abort_enabled = snapshot.offer ~= nil or snapshot.rollout ~= nil
    local adopt_enabled = selected ~= nil and (selected.status == "unlinked" or selected.status == "identity-conflict")

    e.action_state.offer = offer_enabled
    e.action_state.start = start_enabled
    e.action_state.abort = abort_enabled
    e.action_state.adopt = adopt_enabled

    applyActionButton(e.check_btn, true, COLORS.action_bg, COLORS.btn_fg, " Check ")
    applyActionButton(e.offer_btn, offer_enabled, COLORS.action_bg, COLORS.btn_fg, selected_is_controller and " Local " or " Offer ")
    applyActionButton(e.start_btn, start_enabled, colors.green, COLORS.btn_fg, selected_is_controller and " CLI  " or " Start ")
    applyActionButton(e.abort_btn, abort_enabled, colors.red, COLORS.btn_fg, " Abort ")
    applyActionButton(e.adopt_btn, adopt_enabled, COLORS.neutral_bg, COLORS.btn_fg, selected and selected.status == "identity-conflict" and "Replace" or " Adopt ")

    local rows = {{ node_id = nil, role = "scope", local_version = snapshot.latest_version or "--", version_display = snapshot.latest_version or "--", status = "all-eligible", note = "Operate on all eligible nodes" }}
    for _, node in ipairs(snapshot.nodes or {}) do
        rows[#rows + 1] = node
    end

    local per_page = listRowsPerPage()
    local max_page = math.max(1, math.ceil(#rows / per_page))
    _update_page = math.max(1, math.min(_update_page, max_page))
    local start_index = ((_update_page - 1) * per_page) + 1

    for index, button in ipairs(e.row_buttons) do
        local row = rows[start_index + index - 1]
        if row then
            local selected_row = row.node_id == _selected_node_id or (row.node_id == nil and _selected_node_id == nil)
            local fg, bg = statusColor(row.status)
            if selected_row then
                fg = COLORS.list_selected_fg
                bg = COLORS.list_selected_bg
            end

            local label
            if row.node_id == nil then
                label = truncate("ALL  scope  " .. tostring(row.version_display or row.local_version or "--") .. "  offer/start eligible nodes", _monitor_w)
            else
                label = truncate(tostring(row.node_id) .. "  " .. tostring(row.role) .. "  " .. tostring(row.version_display or row.local_version) .. "  " .. tostring(row.status), _monitor_w)
            end

            button:setVisible(true)
            button:setText(label)
            button:setBackground(bg):setForeground(fg)
            e.row_node_ids[index] = row.node_id
        else
            e.row_node_ids[index] = nil
            button:setVisible(false)
        end
    end
end

function hud.init(mon_side, cfg, ctrl_node)
    _cfg = cfg
    _ctrl = ctrl_node

    local monitor = nil
    while true do
        monitor = peripheral.wrap(mon_side)
        if monitor then break end
        print("[hud] Waiting for monitor on side: " .. tostring(mon_side))
        os.sleep(1)
    end

    monitor.setTextScale(0.5)
    _monitor_w, _monitor_h = monitor.getSize()

    _frame = basalt.createFrame():setTerm(monitor)
    _frame:setBackground(COLORS.bg)

    _chrome.header = _frame:addLabel()
        :setPosition(1, 1):setSize(_monitor_w, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText("  ENMON  Controller / Overview")

    _chrome.clock = _frame:addLabel()
        :setPosition(_monitor_w - 8, 1):setSize(9, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText("--:--:--")

    _chrome.alert_bar = _frame:addLabel()
        :setPosition(1, 2):setSize(_monitor_w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.ok_fg)
        :setText("  All systems nominal")

    _overview = buildOverview(_frame, _monitor_w, _monitor_h)
    _updates = buildUpdates(_frame, _monitor_w, _monitor_h)
    setView("overview")
end

function hud.setView(view)
    setView(view)
    renderUpdates(_data or {})
    renderOverview(_data or {})
end

function hud.toggleView()
    if _view == "overview" then
        hud.setView("updates")
    else
        hud.setView("overview")
    end
end

function hud.update(data)
    if not _frame then return end
    _data = data or {}

    _chrome.clock:setText(data.timestamp or "--:--:--")
    if data.alerts and #data.alerts > 0 then
        _chrome.alert_bar:setText(truncate("! " .. table.concat(data.alerts, " | "), _monitor_w))
        if (math.floor(os.clock() / 1.5) % 2) == 0 then
            _chrome.alert_bar:setBackground(COLORS.bg):setForeground(COLORS.alert_fg)
        else
            _chrome.alert_bar:setBackground(COLORS.alert_fg):setForeground(colors.white)
        end
    else
        _chrome.alert_bar:setText("  All systems nominal")
        _chrome.alert_bar:setBackground(COLORS.bg):setForeground(COLORS.ok_fg)
    end

    renderOverview(data)
    renderUpdates(data)
end

function hud.run()
    basalt.run()
end

return hud
