-- ui/pocket_hud.lua
-- Basalt 2 compact read-only HUD for Pocket Computers.
-- Renders on the pocket computer's built-in terminal (39x13 chars).

local util   = require("lib/util")
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

local function barColor(fill)
    if fill >= 0.75 then return colors.green
    elseif fill >= 0.40 then return colors.yellow
    else return colors.red end
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

    -- Matrix section
    _frame:addLabel():setPosition(1, 4):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(colors.yellow):setText(" Matrix")

    e.mat_pct = _frame:addLabel()
        :setPosition(2, 5):setSize(w-1, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.value):setText("--")

    e.mat_bar = _frame:addProgressBar()
        :setPosition(1, 6):setSize(w, 1):setDirection("horizontal")
        :setProgress(0):setBackground(COLORS.bar_empty):setForeground(COLORS.bar_full)

    e.mat_flow = _frame:addLabel()
        :setPosition(2, 7):setSize(w-1, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label):setText("+-- / ---")

    -- Reactor section
    _frame:addLabel():setPosition(1, 9):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(colors.yellow):setText(" Reactors")

    e.rx_lines = {}  -- built on first update

    _elements = e
    _elements._w = w
    _elements._h = h
end

local function ensureReactorLine(nid)
    if _elements.rx_lines[nid] then return end
    local count = 0
    for _ in pairs(_elements.rx_lines) do count = count + 1 end
    local row = 10 + count
    local w = _elements._w
    local lbl = _frame:addLabel()
        :setPosition(2, row):setSize(w-1, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label)
        :setText(nid .. ": --")
    _elements.rx_lines[nid] = lbl
end

function hud.update(data)
    if not _frame then return end
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

    -- Matrix
    local m = data.matrix
    if m and not data.matrix_stale then
        local fill = util.fillFraction(m.energy, m.max_energy)
        e.mat_pct:setText(util.formatEnergy(m.energy) .. "  " .. util.formatPercent(fill))
        e.mat_bar:setProgress(fill * 100):setForeground(barColor(fill))
        local net_flow = m.last_input - m.last_output
        local sign = net_flow >= 0 and "+" or ""
        e.mat_flow:setText("Net: " .. sign .. util.formatRate(net_flow))
    else
        e.mat_pct:setText("DISCONNECTED")
        e.mat_bar:setProgress(0)
        e.mat_flow:setText("")
    end

    -- Reactors
    if data.reactors then
        for nid, r in pairs(data.reactors) do
            ensureReactorLine(nid)
            local lbl = _elements.rx_lines[nid]
            local status = r.active and "ON " or "OFF"
            local rate   = util.formatRate(r.produced_last_t or 0)
            lbl:setText(nid .. ":" .. status .. " " .. rate)
            lbl:setForeground(r.active and COLORS.ok_fg or COLORS.label)
        end
    end
end

function hud.run()
    basalt.run()
end

return hud
