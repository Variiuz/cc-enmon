local util = require("lib/util")

local controller_view = {}

function controller_view.buildDisplayPayload(state, isStale, buildUpdateSnapshot, buildHistoryPayload, timestamp, energy_unit)
    return {
        matrix = state.matrix,
        matrix_stale = (state.matrix == nil or isStale(state.matrix_updated)),
        reactors = state.reactors,
        alerts = state.alerts,
        updates = buildUpdateSnapshot(),
        history = buildHistoryPayload(90),
        energy_unit = util.normalizeEnergyUnit(energy_unit, "FE"),
        timestamp = timestamp,
    }
end

function controller_view.buildRuntimeSummaryRows(cfg, branch_label, state, isStale, currentAlertText, buildRuntimeUpdatesLine)
    local reactor_count = 0
    for _ in pairs(state.reactors) do reactor_count = reactor_count + 1 end

    local matrix_status = "Waiting"
    local matrix_fg = colors.black
    local matrix_bg = colors.white
    if state.matrix and not isStale(state.matrix_updated) then
        matrix_status = util.formatPercent(util.fillFraction(state.matrix.energy, state.matrix.max_energy))
        matrix_fg = colors.white
        matrix_bg = colors.blue
    elseif state.matrix and isStale(state.matrix_updated) then
        matrix_status = "Stale"
        matrix_fg = colors.red
        matrix_bg = colors.white
    end

    local alert_text, alert_fg, alert_bg = currentAlertText()
    local updates_line = buildRuntimeUpdatesLine(cfg)

    return {
        { "Computer ID", tostring(os.getComputerID()), colors.white, colors.blue },
        { "Node", tostring(cfg.get("node_id")) },
        { "Branch", tostring(branch_label) },
        { "Modem", tostring(cfg.get("modem_side") or "auto") },
        { "Updates", updates_line },
        { "Channel", tostring(cfg.get("channel")) },
        { "Matrix", matrix_status, matrix_fg, matrix_bg },
        { "Reactors", tostring(reactor_count) },
        { "Alert", alert_text, alert_fg, alert_bg },
    }
end

return controller_view