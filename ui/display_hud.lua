-- ui/display_hud.lua
-- Basalt 2 read-only HUD for Display nodes.
-- Identical layout to controller_hud but no interactive controls (no buttons).

local util   = require("lib/util")
local graph  = require("lib/graph")
local basalt = require("lib/basalt")

local hud = {}

local COLORS = {
    bg        = colors.black,
    header_bg = colors.gray,
    header_fg = colors.yellow,
    label     = colors.white,
    value     = colors.cyan,
    alert_fg  = colors.red,
    ok_fg     = colors.green,
    bar_full  = colors.green,
    bar_empty = colors.gray,
}

local _frame    = nil
local _elements = {}

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
    if fill >= 0.75 then return colors.green
    elseif fill >= 0.40 then return colors.yellow
    else return colors.red end
end

local function buildWide(frame, w, h)
    local e = {}
    e.header = frame:addLabel()
        :setPosition(1, 1):setSize(w, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText("  ENMON  Display")
    e.clock = frame:addLabel()
        :setPosition(w - 8, 1):setSize(9, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText("--:--:--")
    e.alert_bar = frame:addLabel()
        :setPosition(1, 2):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.alert_fg)
        :setText("")

    local lw = math.floor(w / 2) - 1
    local py = 4

    e.mat_title = frame:addLabel()
        :setPosition(2, py):setSize(lw, 1):setBackground(COLORS.bg)
        :setForeground(colors.yellow):setText("[ Induction Matrix ]")

    e.mat_stored_val = frame:addLabel()
        :setPosition(11, py+1):setSize(lw-9, 1):setBackground(COLORS.bg)
        :setForeground(COLORS.value):setText("--")
    frame:addLabel():setPosition(2, py+1):setSize(9, 1):setBackground(COLORS.bg)
        :setForeground(COLORS.label):setText("Stored:")

    e.mat_max_val = frame:addLabel()
        :setPosition(11, py+2):setSize(lw-9, 1):setBackground(COLORS.bg)
        :setForeground(COLORS.value):setText("--")
    frame:addLabel():setPosition(2, py+2):setSize(9, 1):setBackground(COLORS.bg)
        :setForeground(COLORS.label):setText("Max:   ")

    e.mat_in_val = frame:addLabel()
        :setPosition(11, py+3):setSize(lw-9, 1):setBackground(COLORS.bg)
        :setForeground(colors.lime):setText("--")
    frame:addLabel():setPosition(2, py+3):setSize(9, 1):setBackground(COLORS.bg)
        :setForeground(COLORS.label):setText("Input: ")

    e.mat_out_val = frame:addLabel()
        :setPosition(11, py+4):setSize(lw-9, 1):setBackground(COLORS.bg)
        :setForeground(colors.orange):setText("--")
    frame:addLabel():setPosition(2, py+4):setSize(9, 1):setBackground(COLORS.bg)
        :setForeground(COLORS.label):setText("Output:")

    e.mat_fill_summary = frame:addLabel()
        :setPosition(2, py+7):setSize(lw, 1):setBackground(COLORS.bg)
        :setForeground(COLORS.value):setText("Fill --")

    e.hist_fill_rows = {}
    for index = 1, 3 do
        e.hist_fill_rows[index] = frame:addLabel()
            :setPosition(2, py + 7 + index):setSize(lw, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.value):setText(string.rep(" ", lw))
    end

    e.mat_output_summary = frame:addLabel()
        :setPosition(2, py + 11):setSize(lw, 1):setBackground(COLORS.bg)
        :setForeground(COLORS.label):setText("In --  Out --")

    e.hist_graph_w = math.max(8, lw - 2)
    e.hist_graph_h = 3

    local rx = math.floor(w / 2) + 2
    e.rx_title = frame:addLabel()
        :setPosition(rx, py):setSize(w - rx, 1):setBackground(COLORS.bg)
        :setForeground(colors.yellow):setText("[ Reactors ]")
    e.rx_entries = {}
    e._rx_start_row = py
    e._rx_x = rx
    e._rx_w = w - rx

    return e
end

local function buildNarrow(frame, w, h)
    local e = {}
    e.header = frame:addLabel()
        :setPosition(1, 1):setSize(w, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText(" ENMON")
    e.clock = frame:addLabel()
        :setPosition(w - 8, 1):setSize(9, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText("--:--:--")
    e.alert_bar = frame:addLabel()
        :setPosition(1, 2):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.alert_fg)
        :setText("")
    local py = 4
    frame:addLabel():setPosition(1, py):setSize(w, 1):setBackground(COLORS.bg)
        :setForeground(colors.yellow):setText("[Matrix]")
    e.mat_stored_val = frame:addLabel()
        :setPosition(1, py+1):setSize(w, 1):setBackground(COLORS.bg)
        :setForeground(COLORS.value):setText("--")
    e.mat_fill_summary = frame:addLabel()
        :setPosition(1, py+2):setSize(w, 1):setBackground(COLORS.bg)
        :setForeground(COLORS.value):setText("Fill --")
    e.hist_fill_rows = {}
    for index = 1, 2 do
        e.hist_fill_rows[index] = frame:addLabel()
            :setPosition(1, py + 2 + index):setSize(w, 1):setBackground(COLORS.bg)
            :setForeground(COLORS.value):setText(string.rep(" ", w))
    end
    e.mat_output_summary = frame:addLabel()
        :setPosition(1, py+5):setSize(w, 1):setBackground(COLORS.bg)
        :setForeground(COLORS.label):setText("In --  Out --")
    e.hist_graph_w = math.max(6, w)
    e.hist_graph_h = 2
    frame:addLabel():setPosition(1, py+7):setSize(w, 1):setBackground(COLORS.bg)
        :setForeground(colors.yellow):setText("[Reactors]")
    e.rx_entries = {}
    e._rx_start_row = py + 7
    e._rx_x = 1
    e._rx_w = w
    return e
end

local function ensureReactorEntry(frame, e, nid)
    if e.rx_entries[nid] then return end
    local count = 0
    for _ in pairs(e.rx_entries) do count = count + 1 end
    local row = e._rx_start_row + count * 2
    local entry = {}
    entry.label = frame:addLabel()
        :setPosition(e._rx_x, row):setSize(e._rx_w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label)
        :setText(nid .. ": --")
    entry.detail = frame:addLabel()
        :setPosition(e._rx_x, row + 1):setSize(e._rx_w, 1)
        :setBackground(COLORS.bg):setForeground(colors.lightGray)
        :setText("")
    e.rx_entries[nid] = entry
end

function hud.init(mon_side)
    local monitor = peripheral.wrap(mon_side)
    if not monitor then error("[display_hud] Monitor not found: " .. tostring(mon_side)) end
    monitor.setTextScale(0.5)
    _frame = basalt.createFrame():setTerm(monitor)
    _frame:setBackground(COLORS.bg)
    local w, h = monitor.getSize()
    if w >= 51 then
        _elements = buildWide(_frame, w, h)
        _elements._wide = true
    else
        _elements = buildNarrow(_frame, w, h)
        _elements._wide = false
    end
end

function hud.update(data)
    if not _frame then return end
    local e = _elements
    local energy_unit = data.energy_unit or "FE"

    e.clock:setText(data.timestamp or "--:--:--")

    if data.alerts and #data.alerts > 0 then
        e.alert_bar:setText("! " .. table.concat(data.alerts, "  |  "))
        e.alert_bar:setForeground(COLORS.alert_fg)
    else
        e.alert_bar:setText("  All systems nominal")
        e.alert_bar:setForeground(COLORS.ok_fg)
    end

    local m = data.matrix
    local samples = data.history or {}
    if m and not data.matrix_stale then
        local fill = util.fillFraction(m.energy, m.max_energy)
        e.mat_stored_val:setText(util.formatEnergy(m.energy, energy_unit))
        if e.mat_max_val  then e.mat_max_val:setText(util.formatEnergy(m.max_energy, energy_unit)) end
        if e.mat_in_val   then e.mat_in_val:setText("+" .. util.formatRate(m.last_input, energy_unit)) end
        if e.mat_out_val  then e.mat_out_val:setText("-" .. util.formatRate(m.last_output, energy_unit)) end
        e.mat_fill_summary:setText("Fill " .. util.formatPercent(fill) .. "  Recent " .. select(2, graph.renderMatrixFillBars(samples, e.hist_graph_w or 10, e.hist_graph_h or 2)))
        e.mat_output_summary:setText(truncate("In +" .. util.formatRate(m.last_input, energy_unit) .. "  Out -" .. util.formatRate(m.last_output, energy_unit), e._wide and (e.hist_graph_w or e._rx_w) or e._rx_w))
        local fill_rows = select(1, graph.renderMatrixFillBars(samples, e.hist_graph_w or 10, e.hist_graph_h or 2))
        setGraphRows(e.hist_fill_rows, fill_rows, e.hist_graph_w or e._rx_w, barColor(fill))
    else
        e.mat_stored_val:setText("DISCONNECTED")
        e.mat_fill_summary:setText("Fill --")
        e.mat_output_summary:setText("In --  Out --")
        local fill_rows = select(1, graph.renderMatrixFillBars(samples, e.hist_graph_w or 10, e.hist_graph_h or 2))
        setGraphRows(e.hist_fill_rows, fill_rows, e.hist_graph_w or e._rx_w, colors.lightGray)
    end

    if data.reactors then
        for nid, r in pairs(data.reactors) do
            ensureReactorEntry(_frame, e, nid)
            local entry = e.rx_entries[nid]
            if entry then
                local line_one, line_two = graph.reactorOverviewLines(nid, r, energy_unit)
                entry.label:setText(truncate(line_one, e._rx_w))
                entry.detail:setText(truncate(line_two, e._rx_w))
                entry.label:setForeground(r.active and COLORS.ok_fg or COLORS.alert_fg)
                entry.detail:setForeground(colors.lightGray)
            end
        end
    end
end

function hud.run()
    basalt.run()
end

return hud
