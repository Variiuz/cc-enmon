local util = require("lib/util")

local controller_view = {}

local function aggregateMatrices(state, isStale)
    local total_energy = 0
    local total_max = 0
    local total_in = 0
    local total_out = 0
    local count = 0
    local latest = 0
    local sources = state.matrices or {}

    for node_id, entry in pairs(sources) do
        if entry and entry.payload and not isStale(entry.updated or 0) then
            local payload = entry.payload
            total_energy = total_energy + (tonumber(payload.energy) or 0)
            total_max = total_max + (tonumber(payload.max_energy) or 0)
            total_in = total_in + (tonumber(payload.last_input) or 0)
            total_out = total_out + (tonumber(payload.last_output) or 0)
            count = count + 1
            if (entry.updated or 0) > latest then
                latest = entry.updated or 0
            end
        end
    end

    if count == 0 then
        return state.matrix, state.matrix_updated or 0, 0
    end

    return {
        energy = total_energy,
        max_energy = total_max,
        last_input = total_in,
        last_output = total_out,
        matrix_count = count,
    }, latest, count
end

local function aggregateMeters(state, isStale)
    local total_rate = 0
    local total_in = 0
    local total_out = 0
    local count = 0
    local latest = 0
    local sources = state.meters or {}

    for node_id, entry in pairs(sources) do
        if entry and not isStale(entry.updated or 0) then
            local rate = tonumber(entry.rate) or 0
            total_rate = total_rate + rate
            total_in = total_in + (tonumber(entry.last_input) or (rate > 0 and rate or 0))
            total_out = total_out + (tonumber(entry.last_output) or (rate < 0 and (-rate) or 0))
            count = count + 1
            if (entry.updated or 0) > latest then
                latest = entry.updated or 0
            end
        end
    end

    if count == 0 then
        return nil, 0, 0
    end

    return {
        rate = total_rate,
        last_input = total_in,
        last_output = total_out,
        meter_count = count,
    }, latest, count
end

function controller_view.buildDisplayPayload(state, isStale, buildUpdateSnapshot, buildHistoryPayload, timestamp, energy_unit)
    local matrix, matrix_updated, matrix_count = aggregateMatrices(state, isStale)
    local meter_io, meter_updated, meter_count = aggregateMeters(state, isStale)
    local eta_text, eta_empty, eta_full = nil, nil, nil
    if matrix then
        eta_text, eta_empty, eta_full = util.formatEnergyEta(
            matrix.energy,
            matrix.max_energy,
            matrix.last_input,
            matrix.last_output
        )
    end

    return {
        matrix = matrix,
        matrix_stale = (matrix == nil or isStale(matrix_updated)),
        matrix_count = matrix_count,
        matrix_eta = eta_text,
        matrix_eta_empty_s = eta_empty,
        matrix_eta_full_s = eta_full,
        meters = state.meters,
        meter_io = meter_io,
        meter_stale = (meter_io == nil or isStale(meter_updated)),
        meter_count = meter_count,
        reactors = state.reactors,
        generators = state.generators,
        alerts = state.alerts,
        updates = buildUpdateSnapshot(),
        history = buildHistoryPayload(90),
        energy_unit = util.normalizeEnergyUnit(energy_unit, "FE"),
        timestamp = timestamp,
    }
end

function controller_view.getAggregatedMatrix(state, isStale)
    return aggregateMatrices(state, isStale)
end

function controller_view.getAggregatedMeters(state, isStale)
    return aggregateMeters(state, isStale)
end

function controller_view.buildRuntimeSummaryRows(cfg, branch_label, state, isStale, currentAlertText, buildRuntimeUpdatesLine)
    local reactor_count = 0
    for _ in pairs(state.reactors) do reactor_count = reactor_count + 1 end
    local generator_count = 0
    for _ in pairs(state.generators or {}) do generator_count = generator_count + 1 end
    local meter_count = 0
    for _ in pairs(state.meters or {}) do meter_count = meter_count + 1 end

    local matrix, matrix_updated, matrix_count = aggregateMatrices(state, isStale)
    local matrix_status = "Waiting"
    local matrix_fg = colors.black
    local matrix_bg = colors.white
    if matrix and not isStale(matrix_updated) then
        local fill = util.fillFraction(matrix.energy, matrix.max_energy)
        local eta = select(1, util.formatEnergyEta(matrix.energy, matrix.max_energy, matrix.last_input, matrix.last_output))
        matrix_status = util.formatPercent(fill)
        if matrix_count > 1 then
            matrix_status = matrix_status .. " (" .. tostring(matrix_count) .. ")"
        end
        if eta and eta ~= "ETA --" then
            matrix_status = matrix_status .. " " .. eta
        end
        matrix_fg = colors.white
        matrix_bg = colors.blue
    elseif matrix and isStale(matrix_updated) then
        matrix_status = "Stale"
        matrix_fg = colors.red
        matrix_bg = colors.white
    end

    local meter_io = select(1, aggregateMeters(state, isStale))
    local meter_status = meter_count == 0 and "none" or "--"
    if meter_io then
        meter_status = util.formatRate(meter_io.rate or 0)
        if meter_io.meter_count and meter_io.meter_count > 1 then
            meter_status = meter_status .. " (" .. tostring(meter_io.meter_count) .. ")"
        end
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
        { "Meters", meter_status },
        { "Reactors", tostring(reactor_count) },
        { "Generators", tostring(generator_count) },
        { "Alert", alert_text, alert_fg, alert_bg },
    }
end

return controller_view
