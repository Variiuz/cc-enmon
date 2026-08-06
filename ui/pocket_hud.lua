-- ui/pocket_hud.lua
-- Basalt 2 compact HUD for Pocket Computers with remote control.

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
    btn_on    = colors.green,
    btn_off   = colors.red,
    btn_fg    = colors.white,
}

local _frame    = nil
local _elements = {}
local _tab = "overview"
local _data = {}
local _selected_id = nil
local _selected_kind = "reactor" -- reactor | generator
local _sendCommand = nil

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

local function listMachines(data)
    local machines = {}
    for nid, reactor in pairs((data and data.reactors) or {}) do
        machines[#machines + 1] = { id = nid, kind = "reactor", data = reactor }
    end
    for nid, generator in pairs((data and data.generators) or {}) do
        machines[#machines + 1] = { id = nid, kind = "generator", data = generator }
    end
    table.sort(machines, function(a, b)
        if a.kind == b.kind then
            return tostring(a.id) < tostring(b.id)
        end
        return a.kind < b.kind
    end)
    return machines
end

local function ensureSelectedMachine(data)
    local machines = listMachines(data)
    if #machines == 0 then
        _selected_id = nil
        _selected_kind = "reactor"
        return nil
    end

    for _, machine in ipairs(machines) do
        if machine.id == _selected_id and machine.kind == _selected_kind then
            return machine
        end
    end

    _selected_id = machines[1].id
    _selected_kind = machines[1].kind
    return machines[1]
end

local function cycleMachine(delta)
    local machines = listMachines(_data)
    if #machines == 0 then
        _selected_id = nil
        return
    end

    local current = 1
    for index, machine in ipairs(machines) do
        if machine.id == _selected_id and machine.kind == _selected_kind then
            current = index
            break
        end
    end

    current = current + delta
    if current < 1 then current = #machines end
    if current > #machines then current = 1 end
    _selected_id = machines[current].id
    _selected_kind = machines[current].kind
end

local function sendCommand(payload)
    if type(_sendCommand) == "function" then
        _sendCommand(payload)
    end
end

local function updateOverview(data)
    local e = _elements
    local energy_unit = data.energy_unit or "FE"
    local m = data.matrix
    if m and not data.matrix_stale then
        local fill = util.fillFraction(m.energy, m.max_energy)
        local fill_rows, fill_latest = graph.renderMatrixFillBars(data.history or {}, e.hist_graph_w or 8, 2)
        e.ov_mat_pct:setText(truncate(util.formatEnergy(m.energy, energy_unit) .. "  " .. util.formatPercent(fill), e._w or 20))
        e.ov_mat_fill:setText(truncate("Fill " .. fill_latest .. "  " .. tostring(data.matrix_eta or "ETA --"), e._w or 20))
        local matrix_count = tonumber(data.matrix_count) or 0
        local count_prefix = matrix_count > 1 and (tostring(matrix_count) .. "x ") or ""
        e.ov_mat_flow:setText(truncate(count_prefix .. "In +" .. util.formatRate(m.last_input or 0, energy_unit) .. "  Out -" .. util.formatRate(m.last_output or 0, energy_unit), e._w or 20))
        setGraphRows(e.ov_mat_graph_rows, fill_rows, e.hist_graph_w or 8, barColor(fill))
    else
        e.ov_mat_pct:setText("DISCONNECTED")
        e.ov_mat_fill:setText("Fill --")
        e.ov_mat_flow:setText("")
        local fill_rows = select(1, graph.renderMatrixFillBars(data.history or {}, e.hist_graph_w or 8, 2))
        setGraphRows(e.ov_mat_graph_rows, fill_rows, e.hist_graph_w or 8, COLORS.label)
    end

    if data.meter_io and not data.meter_stale then
        e.ov_meter:setText(truncate("IO " .. util.formatRate(data.meter_io.rate or 0, energy_unit), e._w or 20))
    else
        e.ov_meter:setText("IO --")
    end

    local total_output = 0
    local reactor_count = 0
    local generator_count = 0
    local hottest = nil
    for _, reactor in pairs(data.reactors or {}) do
        reactor_count = reactor_count + 1
        total_output = total_output + (tonumber(reactor.produced_last_t) or 0)
        local fuel_temp = tonumber(reactor.fuel_temp)
        if fuel_temp and (not hottest or fuel_temp > hottest) then
            hottest = fuel_temp
        end
    end
    for _, generator in pairs(data.generators or {}) do
        generator_count = generator_count + 1
        total_output = total_output + (tonumber(generator.produced_last_t) or 0)
    end
    e.ov_rx_summary:setText(truncate("Rx " .. tostring(reactor_count) .. " Gen " .. tostring(generator_count) .. " Out " .. util.formatRate(total_output, energy_unit), e._w or 20))
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

local function updateControl(data)
    local e = _elements
    local energy_unit = data.energy_unit or "FE"
    local selected = ensureSelectedMachine(data)
    if not selected then
        e.rx_title:setText(" Control")
        e.rx_status:setText("No machine data")
        e.rx_rate:setText("")
        e.rx_rod:setText("")
        e.rx_fuel:setText("")
        e.btn_on:setBackground(colors.gray)
        e.btn_off:setBackground(colors.gray)
        e.btn_rod_down:setBackground(colors.gray)
        e.btn_rod_up:setBackground(colors.gray)
        return
    end

    local machine = selected.data
    local kind_label = selected.kind == "generator" and "Gen" or "Rx"
    e.rx_title:setText(truncate(" " .. kind_label .. " " .. tostring(selected.id), e._w or 20))
    e.rx_status:setText(truncate((machine.active and "ON" or "OFF") .. "  " .. util.formatRate(machine.produced_last_t or 0, energy_unit), e._w or 20))

    if selected.kind == "reactor" then
        local line_one, line_two = graph.reactorOverviewLines(selected.id, machine, energy_unit)
        e.rx_rate:setText(truncate(line_two, e._w or 20))
        e.rx_rod:setText(truncate(
            "Rod " .. (machine.control_rod_level ~= nil and (tostring(math.floor(machine.control_rod_level + 0.5)) .. "%") or "--"),
            e._w or 20
        ))
        e.rx_fuel:setText(truncate(
            "FT " .. (machine.fuel_temp and util.formatTemperature(machine.fuel_temp) or "--"),
            e._w or 20
        ))
        e.btn_rod_down:setBackground(machine.control_rod_level ~= nil and colors.lightGray or colors.gray)
        e.btn_rod_up:setBackground(machine.control_rod_level ~= nil and colors.blue or colors.gray)
    else
        e.rx_rate:setText(truncate(machine.controllable == false and "Read-only" or "Controllable", e._w or 20))
        e.rx_rod:setText("")
        e.rx_fuel:setText("")
        e.btn_rod_down:setBackground(colors.gray)
        e.btn_rod_up:setBackground(colors.gray)
    end

    e.btn_on:setBackground(COLORS.btn_off)
    e.btn_off:setBackground(COLORS.btn_on)
end

function hud.setCommandHandler(handler)
    _sendCommand = handler
end

function hud.init()
    _frame = basalt.getMainFrame()
    _frame:setBackground(COLORS.bg)

    local w, h = term.getSize()
    local e = {}

    e.header = _frame:addLabel()
        :setPosition(1, 1):setSize(w, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText(" ENMON")
    e.clock = _frame:addLabel()
        :setPosition(w - 8, 1):setSize(9, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText("--:--:--")

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
    local controlFrame = addTab("control", " Control ", (tab_w * 2) + 1)

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
    e.ov_meter = overview:addLabel()
        :setPosition(1, 7):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.value):setText("IO --")
    e.ov_rx_summary = overview:addLabel()
        :setPosition(1, 8):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(colors.yellow):setText("Rx --")
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

    controlFrame:addButton()
        :setPosition(1, 1):setSize(6, 1)
        :setText(" Prev ")
        :setBackground(colors.lightGray):setForeground(colors.black)
        :onClick(function()
            cycleMachine(-1)
            hud.update(_data or {})
        end)
    controlFrame:addButton()
        :setPosition(w - 5, 1):setSize(6, 1)
        :setText(" Next ")
        :setBackground(colors.lightGray):setForeground(colors.black)
        :onClick(function()
            cycleMachine(1)
            hud.update(_data or {})
        end)
    e.rx_title = controlFrame:addLabel()
        :setPosition(8, 1):setSize(math.max(1, w - 14), 1)
        :setBackground(COLORS.bg):setForeground(colors.yellow):setText(" Control")
    e.rx_status = controlFrame:addLabel()
        :setPosition(1, 3):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.value):setText("No machine data")
    e.rx_rate = controlFrame:addLabel()
        :setPosition(1, 4):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label):setText("")
    e.rx_rod = controlFrame:addLabel()
        :setPosition(1, 5):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label):setText("")
    e.rx_fuel = controlFrame:addLabel()
        :setPosition(1, 6):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label):setText("")

    e.btn_on = controlFrame:addButton()
        :setPosition(1, 8):setSize(6, 1)
        :setText(" ON  ")
        :setBackground(COLORS.btn_off):setForeground(COLORS.btn_fg)
        :onClick(function()
            local selected = ensureSelectedMachine(_data)
            if not selected then return end
            if selected.kind == "reactor" then
                sendCommand({
                    action = "reactor_set",
                    target_node_id = selected.id,
                    active = true,
                })
            else
                sendCommand({
                    action = "generator_set",
                    target_node_id = selected.id,
                    active = true,
                })
            end
        end)

    e.btn_off = controlFrame:addButton()
        :setPosition(8, 8):setSize(6, 1)
        :setText(" OFF ")
        :setBackground(COLORS.btn_on):setForeground(COLORS.btn_fg)
        :onClick(function()
            local selected = ensureSelectedMachine(_data)
            if not selected then return end
            if selected.kind == "reactor" then
                sendCommand({
                    action = "reactor_set",
                    target_node_id = selected.id,
                    active = false,
                })
            else
                sendCommand({
                    action = "generator_set",
                    target_node_id = selected.id,
                    active = false,
                })
            end
        end)

    e.btn_rod_down = controlFrame:addButton()
        :setPosition(15, 8):setSize(5, 1)
        :setText(" R- ")
        :setBackground(colors.lightGray):setForeground(colors.black)
        :onClick(function()
            local selected = ensureSelectedMachine(_data)
            if not selected or selected.kind ~= "reactor" then return end
            sendCommand({
                action = "reactor_set",
                target_node_id = selected.id,
                control_rod_delta = -5,
            })
        end)

    e.btn_rod_up = controlFrame:addButton()
        :setPosition(21, 8):setSize(5, 1)
        :setText(" R+ ")
        :setBackground(colors.blue):setForeground(colors.white)
        :onClick(function()
            local selected = ensureSelectedMachine(_data)
            if not selected or selected.kind ~= "reactor" then return end
            sendCommand({
                action = "reactor_set",
                target_node_id = selected.id,
                control_rod_delta = 5,
            })
        end)

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

    if data.alerts and #data.alerts > 0 then
        e.alert:setText("!" .. data.alerts[1])
        e.alert:setForeground(COLORS.alert_fg)
    else
        e.alert:setText("  All nominal")
        e.alert:setForeground(COLORS.ok_fg)
    end
    updateOverview(data)
    updateHistory(data)
    updateControl(data)
end

function hud.run()
    basalt.run()
end

return hud
