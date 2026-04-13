-- ui/pocket_hud.lua
-- Basalt 2 compact read-only HUD for Pocket Computers.
-- Renders on the pocket computer's built-in terminal (39x13 chars).

local util   = require("lib/util")
local graph  = require("lib/graph")
local basalt = require("lib/basalt")

local hud = {}

local COLORS = {
    bg        = colors.black,
    header_bg = colors.gray,
    header_fg = colors.yellow,
    label     = colors.lightGray,
    value     = colors.cyan,
    alert_fg  = colors.red,
    ok_fg     = colors.green,
    bar_full  = colors.green,
    bar_empty = colors.gray,
}

local _frame    = nil
local _elements = {}
local _tab = "overview"
local _data = {}
local _selected_reactor_id = nil

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

local function setTab(name)
    _tab = name or "overview"
    local e = _elements
    if not e.tabs then return end

    for tab_name, spec in pairs(e.tabs) do
        local active = tab_name == _tab
        spec.button:setBackground(active and colors.blue or colors.lightGray)
        spec.button:setForeground(active and colors.white or colors.black)
        spec.frame:setVisible(active)
    end
end

local function ensureSelectedReactor(data)
    local reactors = data and data.reactors or nil
    if type(reactors) ~= "table" then
        _selected_reactor_id = nil
        return nil
    end

    if _selected_reactor_id and reactors[_selected_reactor_id] then
        return _selected_reactor_id
    end

    local ids = {}
    for nid in pairs(reactors) do
        ids[#ids + 1] = nid
    end
    table.sort(ids)
    _selected_reactor_id = ids[1]
    return _selected_reactor_id
end

local function cycleReactor(delta)
    local reactors = _data and _data.reactors or nil
    if type(reactors) ~= "table" then return end
    local ids = {}
    for nid in pairs(reactors) do
        ids[#ids + 1] = nid
    end
    table.sort(ids)
    if #ids == 0 then
        _selected_reactor_id = nil
        return
    end

    local current = 1
    for index, nid in ipairs(ids) do
        if nid == _selected_reactor_id then
            current = index
            break
        end
    end

    current = current + delta
    if current < 1 then current = #ids end
    if current > #ids then current = 1 end
    _selected_reactor_id = ids[current]
end

local function updateOverview(data)
    local e = _elements
    local energy_unit = data.energy_unit or "FE"
    local m = data.matrix
    if m and not data.matrix_stale then
        local fill = util.fillFraction(m.energy, m.max_energy)
        local fill_rows, fill_latest = graph.renderMatrixFillBars(data.history or {}, e.hist_graph_w or 8, 2)
        e.ov_mat_pct:setText(truncate(util.formatEnergy(m.energy, energy_unit) .. "  " .. util.formatPercent(fill), e._w or 20))
        e.ov_mat_fill:setText("Fill " .. fill_latest)
        e.ov_mat_flow:setText(truncate("In +" .. util.formatRate(m.last_input or 0, energy_unit) .. "  Out -" .. util.formatRate(m.last_output or 0, energy_unit), e._w or 20))
        setGraphRows(e.ov_mat_graph_rows, fill_rows, e.hist_graph_w or 8, barColor(fill))
    else
        e.ov_mat_pct:setText("DISCONNECTED")
        e.ov_mat_fill:setText("Fill --")
        e.ov_mat_flow:setText("")
        local fill_rows = select(1, graph.renderMatrixFillBars(data.history or {}, e.hist_graph_w or 8, 2))
        setGraphRows(e.ov_mat_graph_rows, fill_rows, e.hist_graph_w or 8, COLORS.label)
    end

    local total_output = 0
    local reactor_count = 0
    local hottest = nil
    for _, reactor in pairs(data.reactors or {}) do
        reactor_count = reactor_count + 1
        total_output = total_output + (tonumber(reactor.produced_last_t) or 0)
        local fuel_temp = tonumber(reactor.fuel_temp)
        if fuel_temp and (not hottest or fuel_temp > hottest) then
            hottest = fuel_temp
        end
    end
    e.ov_rx_summary:setText(truncate("Reactors: " .. tostring(reactor_count) .. "  Out: " .. util.formatRate(total_output, energy_unit), e._w or 20))
    e.ov_rx_temp:setText(hottest and ("Peak: " .. util.formatTemperature(hottest)) or "Peak: --")
end

local function updateHistory(data)
    local e = _elements
    local samples = data.history or {}
    local energy_unit = data.energy_unit or "FE"
    local fill_rows, fill_latest = graph.renderMatrixFillBars(samples, e.hist_graph_w or 8, 2)
    local out_rows, out_latest = graph.renderReactorOutputBars(samples, e.hist_graph_w or 8, 2, energy_unit)
    local temp_rows, temp_latest = graph.renderPeakTempBars(samples, e.hist_graph_w or 8, 2)

    e.hist_fill_line:setText(truncate("Fill " .. fill_latest, e._w or 20))
    setGraphRows(e.hist_fill_rows, fill_rows, e.hist_graph_w or 8, colors.green)
    e.hist_out_line:setText(truncate("Out  " .. out_latest, e._w or 20))
    setGraphRows(e.hist_out_rows, out_rows, e.hist_graph_w or 8, colors.orange)
    e.hist_temp_line:setText(truncate("Temp " .. temp_latest, e._w or 20))
    setGraphRows(e.hist_temp_rows, temp_rows, e.hist_graph_w or 8, colors.red)
end

local function updateReactors(data)
    local e = _elements
    local energy_unit = data.energy_unit or "FE"
    local selected = ensureSelectedReactor(data)
    if not selected or not data.reactors or not data.reactors[selected] then
        e.rx_title:setText(" Reactor")
        e.rx_status:setText("No reactor data")
        e.rx_rate:setText("")
        e.rx_rod:setText("")
        e.rx_fuel:setText("")
        e.rx_temp:setText("")
        e.rx_casing:setText("")
        return
    end

    local reactor = data.reactors[selected]
    e.rx_title:setText(truncate(" Reactor " .. tostring(selected), e._w or 20))
    local line_one, line_two = graph.reactorOverviewLines(selected, reactor, energy_unit)
    e.rx_status:setText(truncate(line_one, e._w or 20))
    e.rx_rate:setText(truncate(line_two, e._w or 20))
    e.rx_rod:setText(truncate(
        "Fuel " .. (reactor.fuel_fill ~= nil and util.formatPercent(reactor.fuel_fill) or "--") ..
        "  Waste " .. tostring(math.floor((tonumber(reactor.waste_amount) or 0) + 0.5)),
        e._w or 20
    ))
    e.rx_fuel:setText(truncate(
        "Fuel " .. tostring(math.floor((tonumber(reactor.fuel_amount) or 0) + 0.5)) ..
        "/" .. tostring(math.floor((tonumber(reactor.fuel_amount_max) or 0) + 0.5)),
        e._w or 20
    ))
    e.rx_temp:setText(truncate("FT " .. (reactor.fuel_temp and util.formatTemperature(reactor.fuel_temp) or "--"), e._w or 20))
    e.rx_casing:setText(truncate("CT " .. (reactor.casing_temp and util.formatTemperature(reactor.casing_temp) or "--"), e._w or 20))
end

function hud.init()
    _frame = basalt.getMainFrame()
    _frame:setBackground(COLORS.bg)

    local w, h = term.getSize()
    local e = {}

    -- Header
    e.header = _frame:addLabel()
        :setPosition(1, 1):setSize(w, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText(" ENMON")
    e.clock = _frame:addLabel()
        :setPosition(w - 8, 1):setSize(9, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText("--:--:--")

    -- Alert
    e.alert = _frame:addLabel()
        :setPosition(1, 2):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.ok_fg)
        :setText("  Connecting...")

    e.tabs = {}
    local tab_w = math.max(9, math.floor(w / 3))
    local function addTab(name, label, x)
        local button = _frame:addButton()
            :setPosition(x, 3):setSize(tab_w, 1)
            :setText(label)
            :setBackground(colors.lightGray):setForeground(colors.black)
            :onClick(function()
                setTab(name)
                hud.update(_data or {})
            end)
        local frame = _frame:addFrame():setPosition(1, 4):setSize(w, math.max(1, h - 3)):setBackground(COLORS.bg)
        e.tabs[name] = { button = button, frame = frame }
        return frame
    end

    local overview = addTab("overview", " Overview ", 1)
    local historyFrame = addTab("history", " History ", tab_w + 1)
    local reactorsFrame = addTab("reactors", " Reactors ", (tab_w * 2) + 1)

    overview:addLabel():setPosition(1, 1):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(colors.yellow):setText(" Matrix")
    e.ov_mat_pct = overview:addLabel()
        :setPosition(2, 2):setSize(w - 1, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.value):setText("--")
    e.ov_mat_flow = overview:addLabel()
        :setPosition(2, 3):setSize(w - 1, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label):setText("+-- / ---")
    e.ov_mat_fill = overview:addLabel()
        :setPosition(1, 4):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label):setText("Fill --")
    e.ov_mat_graph_rows = {}
    for index = 1, 2 do
        e.ov_mat_graph_rows[index] = overview:addLabel()
            :setPosition(1, 4 + index):setSize(w, 1)
            :setBackground(COLORS.bg):setForeground(COLORS.value):setText(string.rep(" ", w))
    end
    e.ov_rx_summary = overview:addLabel()
        :setPosition(1, 8):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(colors.yellow):setText("Reactors: --")
    e.ov_rx_temp = overview:addLabel()
        :setPosition(2, 9):setSize(w - 1, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label):setText("Peak: --")

    historyFrame:addLabel():setPosition(1, 1):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(colors.yellow):setText(" History")
    e.hist_fill_line = historyFrame:addLabel()
        :setPosition(1, 2):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.value):setText("Fill --")
    e.hist_fill_rows = {}
    for index = 1, 2 do
        e.hist_fill_rows[index] = historyFrame:addLabel()
            :setPosition(1, 2 + index):setSize(w, 1)
            :setBackground(COLORS.bg):setForeground(colors.green):setText(string.rep(" ", w))
    end
    e.hist_out_line = historyFrame:addLabel()
        :setPosition(1, 5):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label):setText("Out --")
    e.hist_out_rows = {}
    for index = 1, 2 do
        e.hist_out_rows[index] = historyFrame:addLabel()
            :setPosition(1, 5 + index):setSize(w, 1)
            :setBackground(COLORS.bg):setForeground(colors.orange):setText(string.rep(" ", w))
    end
    e.hist_temp_line = historyFrame:addLabel()
        :setPosition(1, 8):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label):setText("Temp --")
    e.hist_temp_rows = {}
    for index = 1, 2 do
        e.hist_temp_rows[index] = historyFrame:addLabel()
            :setPosition(1, 8 + index):setSize(w, 1)
            :setBackground(COLORS.bg):setForeground(colors.red):setText(string.rep(" ", w))
    end

    reactorsFrame:addButton()
        :setPosition(1, 1):setSize(6, 1)
        :setText(" Prev ")
        :setBackground(colors.lightGray):setForeground(colors.black)
        :onClick(function()
            cycleReactor(-1)
            hud.update(_data or {})
        end)
    reactorsFrame:addButton()
        :setPosition(w - 5, 1):setSize(6, 1)
        :setText(" Next ")
        :setBackground(colors.lightGray):setForeground(colors.black)
        :onClick(function()
            cycleReactor(1)
            hud.update(_data or {})
        end)
    e.rx_title = reactorsFrame:addLabel()
        :setPosition(8, 1):setSize(math.max(1, w - 14), 1)
        :setBackground(COLORS.bg):setForeground(colors.yellow):setText(" Reactor")
    e.rx_status = reactorsFrame:addLabel()
        :setPosition(1, 3):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.value):setText("No reactor data")
    e.rx_rate = reactorsFrame:addLabel()
        :setPosition(1, 4):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label):setText("")
    e.rx_rod = reactorsFrame:addLabel()
        :setPosition(1, 5):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label):setText("")
    e.rx_fuel = reactorsFrame:addLabel()
        :setPosition(1, 6):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label):setText("")
    e.rx_temp = reactorsFrame:addLabel()
        :setPosition(1, 7):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label):setText("")
    e.rx_casing = reactorsFrame:addLabel()
        :setPosition(1, 8):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label):setText("")

    e.hist_graph_w = math.max(6, w - 14)

    _elements = e
    _elements._w = w
    _elements._h = h
    setTab("overview")
end

function hud.update(data)
    if not _frame then return end
    _data = data or {}
    local e = _elements

    e.clock:setText(data.timestamp or "--:--:--")

    -- Alerts
    if data.alerts and #data.alerts > 0 then
        e.alert:setText("!" .. data.alerts[1])
        e.alert:setForeground(COLORS.alert_fg)
    else
        e.alert:setText("  All nominal")
        e.alert:setForeground(COLORS.ok_fg)
    end
    updateOverview(data)
    updateHistory(data)
    updateReactors(data)
end

function hud.run()
    basalt.run()
end

return hud
