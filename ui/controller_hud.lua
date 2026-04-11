-- ui/controller_hud.lua
-- Basalt 2 HUD for the Controller node.
-- Renders on an attached monitor. Responsive: adapts layout to monitor size.
-- Exposes init(mon_side, cfg, ctrl_node), update(data), run().

local util = require("lib/util")

local hud = {}

-- Basalt is downloaded at install time into lib/basalt.lua
local basalt = require("lib/basalt")

-- ── Layout breakpoints ───────────────────────────────────────────────────────────
-- wide  (w >= 51): two-panel side-by-side (matrix left, reactors right)
-- narrow (w < 51): single-column stacked

local _cfg       = nil
local _ctrl      = nil   -- reference to controller node (for callbacks)
local _frame     = nil   -- Basalt monitor frame
local _data      = {}    -- latest display payload
local _elements  = {}    -- keyed UI element references

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
    panel_bg  = colors.black,
    btn_on    = colors.green,
    btn_off   = colors.red,
    btn_fg    = colors.white,
}

-- ── Helpers ──────────────────────────────────────────────────────────────────────
local function barColor(fill)
    if fill >= 0.75 then return colors.green
    elseif fill >= 0.40 then return colors.yellow
    else return colors.red end
end

local function reactorStatusColor(active)
    return active and colors.green or colors.red
end

-- ── Build HUD ────────────────────────────────────────────────────────────────────
local function buildWideLayout(frame, w, h)
    local e = {}

    -- Header bar (full width, row 1)
    e.header_bg = frame:addLabel()
        :setPosition(1, 1):setSize(w, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText("  ENMON  Energy Network Monitor")

    e.clock = frame:addLabel()
        :setPosition(w - 8, 1):setSize(9, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText("--:--:--")

    -- Alert bar (row 2)
    e.alert_bar = frame:addLabel()
        :setPosition(1, 2):setSize(w, 1)
        :setBackground(colors.black):setForeground(COLORS.alert_fg)
        :setText("")

    -- ── Matrix panel (left half) ─────────────────────────────────────────────
    local lw = math.floor(w / 2) - 1
    local py = 4  -- panel start row

    e.mat_title = frame:addLabel()
        :setPosition(2, py):setSize(lw, 1)
        :setBackground(COLORS.bg):setForeground(colors.yellow)
        :setText("[ Induction Matrix ]")

    e.mat_stored_lbl = frame:addLabel()
        :setPosition(2, py+1):setSize(lw, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label)
        :setText("Stored:")
    e.mat_stored_val = frame:addLabel()
        :setPosition(11, py+1):setSize(lw-9, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.value)
        :setText("--")

    e.mat_max_lbl = frame:addLabel()
        :setPosition(2, py+2):setSize(lw, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label)
        :setText("Max:   ")
    e.mat_max_val = frame:addLabel()
        :setPosition(11, py+2):setSize(lw-9, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.value)
        :setText("--")

    e.mat_in_lbl = frame:addLabel()
        :setPosition(2, py+3):setSize(lw, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label)
        :setText("Input: ")
    e.mat_in_val = frame:addLabel()
        :setPosition(11, py+3):setSize(lw-9, 1)
        :setBackground(COLORS.bg):setForeground(colors.lime)
        :setText("--")

    e.mat_out_lbl = frame:addLabel()
        :setPosition(2, py+4):setSize(lw, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label)
        :setText("Output:")
    e.mat_out_val = frame:addLabel()
        :setPosition(11, py+4):setSize(lw-9, 1)
        :setBackground(COLORS.bg):setForeground(colors.orange)
        :setText("--")

    -- Energy bar
    e.mat_bar = frame:addProgressBar()
        :setPosition(2, py+6):setSize(lw, 1)
        :setDirection("horizontal")
        :setProgress(0)
        :setBackground(COLORS.bar_empty):setForeground(COLORS.bar_full)

    e.mat_pct = frame:addLabel()
        :setPosition(2, py+7):setSize(lw, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.value)
        :setText("0.0%")

    -- ── Reactor panel (right half) ────────────────────────────────────────────
    local rx = math.floor(w / 2) + 2

    e.rx_title = frame:addLabel()
        :setPosition(rx, py):setSize(w - rx, 1)
        :setBackground(COLORS.bg):setForeground(colors.yellow)
        :setText("[ Reactors ]")

    -- Reactor entries are built dynamically in update()
    e.rx_entries = {}  -- populated dynamically

    -- ── Bottom strip: threshold controls ─────────────────────────────────────
    local bottom = h - 2
    e.thresh_lbl = frame:addLabel()
        :setPosition(2, bottom):setSize(w - 2, 1)
        :setBackground(COLORS.bg):setForeground(colors.lightGray)
        :setText("AutoCtrl: OFF   Low:--% High:--%")

    return e
end

local function buildNarrowLayout(frame, w, h)
    local e = {}

    e.header_bg = frame:addLabel()
        :setPosition(1, 1):setSize(w, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText(" ENMON")

    e.clock = frame:addLabel()
        :setPosition(w - 8, 1):setSize(9, 1)
        :setBackground(COLORS.header_bg):setForeground(COLORS.header_fg)
        :setText("--:--:--")

    e.alert_bar = frame:addLabel()
        :setPosition(1, 2):setSize(w, 1)
        :setBackground(colors.black):setForeground(COLORS.alert_fg)
        :setText("")

    local py = 4
    e.mat_title = frame:addLabel()
        :setPosition(1, py):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(colors.yellow)
        :setText("[Matrix]")

    e.mat_stored_val = frame:addLabel()
        :setPosition(1, py+1):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.value)
        :setText("--")

    e.mat_bar = frame:addProgressBar()
        :setPosition(1, py+2):setSize(w, 1)
        :setDirection("horizontal")
        :setProgress(0)
        :setBackground(COLORS.bar_empty):setForeground(COLORS.bar_full)

    e.mat_pct = frame:addLabel()
        :setPosition(1, py+3):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.value)
        :setText("0.0%")

    e.rx_title = frame:addLabel()
        :setPosition(1, py+5):setSize(w, 1)
        :setBackground(COLORS.bg):setForeground(colors.yellow)
        :setText("[Reactors]")

    e.rx_entries = {}
    e.thresh_lbl = nil  -- omitted in narrow

    return e
end

-- Rebuild (or update) reactor entry rows for a given reactor node_id.
-- We create a small sub-block per reactor on demand.
local function ensureReactorEntry(frame, e, nid, row, w, wide)
    if e.rx_entries[nid] then return end

    local x = wide and (math.floor(w / 2) + 2) or 1
    local ew = wide and (w - x) or w

    local entry = {}
    entry.label = frame:addLabel()
        :setPosition(x, row):setSize(ew, 1)
        :setBackground(COLORS.bg):setForeground(COLORS.label)
        :setText(nid .. ": --")

    entry.btn = frame:addButton()
        :setPosition(x, row + 1):setSize(6, 1)
        :setText(" ON  "):setBackground(COLORS.btn_off):setForeground(COLORS.btn_fg)
        :onClick(function()
            if _ctrl then
                local r = _data.reactors and _data.reactors[nid]
                local want = not (r and r.active)
                _ctrl.setReactorActive(nid, want)
            end
        end)

    e.rx_entries[nid] = entry
    e.rx_entries[nid].row = row
end

-- ── Public API ───────────────────────────────────────────────────────────────────

function hud.init(mon_side, cfg, ctrl_node)
    _cfg  = cfg
    _ctrl = ctrl_node

    local monitor = peripheral.wrap(mon_side)
    if not monitor then
        error("[hud] Monitor not found on side: " .. tostring(mon_side))
    end

    monitor.setTextScale(0.5)

    _frame = basalt.createFrame():setTerm(monitor)
    _frame:setBackground(COLORS.bg)

    local w, h = monitor.getSize()
    if w >= 51 then
        _elements = buildWideLayout(_frame, w, h)
        _elements._wide = true
    else
        _elements = buildNarrowLayout(_frame, w, h)
        _elements._wide = false
    end

    _elements._w = w
    _elements._h = h
end

function hud.update(data)
    if not _frame then return end
    _data = data
    local e = _elements
    local w = e._w
    local wide = e._wide

    -- Clock
    e.clock:setText(data.timestamp or "--:--:--")

    -- Alert bar
    if #data.alerts > 0 then
        e.alert_bar:setText("! " .. table.concat(data.alerts, "  |  "))
        e.alert_bar:setForeground(COLORS.alert_fg)
    else
        e.alert_bar:setText("  All systems nominal")
        e.alert_bar:setForeground(COLORS.ok_fg)
    end

    -- Matrix values
    local m = data.matrix
    if m and not data.matrix_stale then
        local fill = util.fillFraction(m.energy, m.max_energy)

        if e.mat_stored_val then
            e.mat_stored_val:setText(util.formatEnergy(m.energy))
        end
        if e.mat_max_val then
            e.mat_max_val:setText(util.formatEnergy(m.max_energy))
        end
        if e.mat_in_val then
            e.mat_in_val:setText("+" .. util.formatRate(m.last_input))
        end
        if e.mat_out_val then
            e.mat_out_val:setText("-" .. util.formatRate(m.last_output))
        end

        e.mat_bar:setProgress(fill * 100)
        e.mat_bar:setForeground(barColor(fill))
        e.mat_pct:setText(util.formatPercent(fill))
    else
        if e.mat_stored_val then e.mat_stored_val:setText("DISCONNECTED") end
        e.mat_bar:setProgress(0)
        e.mat_pct:setText("--")
    end

    -- Reactor entries
    local r_row = wide and 4 or 11
    if data.reactors then
        for nid, r in pairs(data.reactors) do
            ensureReactorEntry(_frame, e, nid, r_row, w, wide)
            r_row = r_row + 3

            local entry = e.rx_entries[nid]
            if entry then
                local stale = (now and (os.clock() - (r.updated or 0)) > 10) or false
                if stale then
                    entry.label:setText(nid .. ": OFFLINE")
                    entry.label:setForeground(COLORS.alert_fg)
                else
                    local status = r.active and "ONLINE" or "OFFLINE"
                    local rate   = util.formatRate(r.produced_last_t or 0)
                    entry.label:setText(nid .. ": " .. status .. "  " .. rate)
                    entry.label:setForeground(reactorStatusColor(r.active))
                end
                -- Button label reflects current state
                if r.active then
                    entry.btn:setText(" OFF "):setBackground(COLORS.btn_on)
                else
                    entry.btn:setText(" ON  "):setBackground(COLORS.btn_off)
                end
            end
        end
    end

    -- Threshold strip
    if e.thresh_lbl then
        local auto = _cfg.get("auto_ctrl") and "ON " or "OFF"
        local lo   = util.formatPercent(_cfg.get("threshold_low"))
        local hi   = util.formatPercent(_cfg.get("threshold_high"))
        e.thresh_lbl:setText("AutoCtrl:" .. auto .. "  Low:" .. lo .. " High:" .. hi)
    end
end

function hud.run()
    basalt.run()
end

return hud
