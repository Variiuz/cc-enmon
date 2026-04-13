local util = require("lib/util")

local graph = {}

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function numericValue(value)
    if type(value) == "number" then return value end
    return tonumber(value) or 0
end

function graph.sampleSeries(samples, width, mapper)
    local count = #samples
    if width <= 0 or count == 0 then return {} end

    local result = {}
    local step = count / width
    for index = 1, width do
        local sampleIndex = math.max(1, math.min(count, math.floor(((index - 1) * step) + 1)))
        local sample = samples[sampleIndex]
        local value = mapper and mapper(sample, sampleIndex) or sample
        result[index] = numericValue(value)
    end
    return result
end

local function computeBounds(values, lower_bound, upper_bound)
    if #values == 0 then
        return tonumber(lower_bound) or 0, tonumber(upper_bound) or 1
    end

    local min_value = values[1]
    local max_value = values[1]
    for _, value in ipairs(values) do
        if value < min_value then min_value = value end
        if value > max_value then max_value = value end
    end

    if lower_bound ~= nil then
        min_value = tonumber(lower_bound) or min_value
    end
    if upper_bound ~= nil then
        max_value = tonumber(upper_bound) or max_value
    end

    if max_value <= min_value then
        if max_value <= 0 then
            max_value = 1
            min_value = 0
        else
            min_value = 0
        end
    end

    return min_value, max_value
end

function graph.renderBarRows(samples, width, height, spec)
    spec = spec or {}
    width = math.max(1, math.floor(tonumber(width) or 1))
    height = math.max(1, math.floor(tonumber(height) or 1))

    local series = graph.sampleSeries(samples or {}, width, spec.map)
    local latest = #series > 0 and series[#series] or 0

    local rows = {}
    if #series == 0 then
        for row = 1, height do
            rows[row] = string.rep(" ", width)
        end
        return rows, spec.empty_text or "--"
    end

    local min_value, max_value = computeBounds(series, spec.min, spec.max)
    local column_heights = {}
    for index = 1, #series do
        if max_value == min_value then
            column_heights[index] = latest > 0 and height or 0
        else
            local normalized = clamp((series[index] - min_value) / (max_value - min_value), 0, 1)
            local column_height = math.floor((normalized * height) + 0.5)
            if normalized > 0 and column_height == 0 then
                column_height = 1
            end
            column_heights[index] = column_height
        end
    end

    for row = 1, height do
        local threshold = height - row + 1
        local chars = {}
        for index = 1, width do
            chars[index] = (column_heights[index] or 0) >= threshold and "|" or " "
        end
        rows[row] = table.concat(chars)
    end

    local latest_text = spec.format and spec.format(latest) or tostring(math.floor(latest + 0.5))
    return rows, latest_text
end

function graph.renderHistoryLine(samples, width, mapFn, formatFn, emptyText)
    local rows, latest = graph.renderBarRows(samples, width, 1, {
        map = mapFn,
        format = formatFn,
        empty_text = emptyText,
    })
    return rows[1] or string.rep(" ", math.max(1, width)), latest
end

function graph.renderMatrixFillBars(samples, width, height)
    return graph.renderBarRows(samples, width, height, {
        map = function(sample)
            return (tonumber(sample.matrix_fill) or 0) * 100
        end,
        format = function(value)
            return util.formatPercent((tonumber(value) or 0) / 100)
        end,
        min = 0,
        max = 100,
        empty_text = "--",
    })
end

function graph.renderMatrixFillLine(samples, width)
    return graph.renderHistoryLine(samples, width, function(sample)
        return (tonumber(sample.matrix_fill) or 0) * 100
    end, function(value)
        return util.formatPercent((tonumber(value) or 0) / 100)
    end, "--")
end

function graph.renderReactorOutputBars(samples, width, height, unit)
    return graph.renderBarRows(samples, width, height, {
        map = function(sample)
            return tonumber(sample.reactor_total_output) or 0
        end,
        format = function(value)
            return util.formatRate(value, unit)
        end,
        min = 0,
        empty_text = "--",
    })
end

function graph.renderReactorOutputLine(samples, width, unit)
    return graph.renderHistoryLine(samples, width, function(sample)
        return tonumber(sample.reactor_total_output) or 0
    end, function(value)
        return util.formatRate(value, unit)
    end, "--")
end

function graph.renderPeakTempBars(samples, width, height)
    return graph.renderBarRows(samples, width, height, {
        map = function(sample)
            return tonumber(sample.reactor_peak_temp) or 0
        end,
        format = util.formatTemperature,
        min = 0,
        empty_text = "--",
    })
end

function graph.renderPeakTempLine(samples, width)
    return graph.renderHistoryLine(samples, width, function(sample)
        return tonumber(sample.reactor_peak_temp) or 0
    end, util.formatTemperature, "--")
end

function graph.reactorLevelText(value)
    if type(value) ~= "number" then return "Rod --" end
    return string.format("Rod %d%%", math.floor(value + 0.5))
end

function graph.reactorTempText(value)
    if type(value) ~= "number" then return "Temp --" end
    return "Temp " .. util.formatTemperature(value)
end

function graph.reactorStatusText(reactor)
    if not reactor then return "OFFLINE" end
    local status = reactor.active and "ONLINE" or "OFFLINE"
    if reactor.connected == false then
        status = status .. " DISC"
    end
    return status
end

function graph.reactorOverviewLines(node_id, reactor, energy_unit)
    local line_one = tostring(node_id) .. "  " .. graph.reactorStatusText(reactor)
    local parts = {
        "Out " .. util.formatRate((reactor and reactor.produced_last_t) or 0, energy_unit),
    }

    if reactor and reactor.control_rod_level ~= nil then
        parts[#parts + 1] = "Rod " .. tostring(math.floor((tonumber(reactor.control_rod_level) or 0) + 0.5)) .. "%"
    end
    if reactor and reactor.fuel_temp ~= nil then
        parts[#parts + 1] = "FT " .. util.formatTemperature(reactor.fuel_temp)
    end
    if reactor and reactor.casing_temp ~= nil then
        parts[#parts + 1] = "CT " .. util.formatTemperature(reactor.casing_temp)
    end

    return line_one, table.concat(parts, "  ")
end

return graph