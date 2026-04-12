local util = require("lib/util")

local graph = {}

local LEVELS = {"_", ".", ":", "-", "=", "+", "*", "#"}

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

function graph.sparkline(values, width)
    width = math.max(1, math.floor(tonumber(width) or #values))
    if #values == 0 then return string.rep("_", width) end

    local minValue = values[1]
    local maxValue = values[1]
    for _, value in ipairs(values) do
        if value < minValue then minValue = value end
        if value > maxValue then maxValue = value end
    end

    if maxValue == minValue then
        local fill = LEVELS[math.max(1, math.floor(#LEVELS / 2))]
        return string.rep(fill, math.max(width, #values))
    end

    local chars = {}
    for index = 1, math.min(width, #values) do
        local normalized = (values[index] - minValue) / (maxValue - minValue)
        local level = clamp(math.floor(normalized * (#LEVELS - 1)) + 1, 1, #LEVELS)
        chars[index] = LEVELS[level]
    end
    return table.concat(chars)
end

function graph.renderHistory(samples, width, spec)
    spec = spec or {}
    local series = graph.sampleSeries(samples, width, spec.map)
    local line = graph.sparkline(series, width)
    local latest = #series > 0 and series[#series] or 0
    local latestText = spec.format and spec.format(latest) or tostring(math.floor(latest + 0.5))
    return line, latestText
end

function graph.renderHistoryLine(samples, width, mapFn, formatFn, emptyText)
    if not samples or #samples == 0 then
        return string.rep("_", math.max(1, width)), emptyText or "--"
    end

    return graph.renderHistory(samples, width, {
        map = mapFn,
        format = formatFn,
    })
end

function graph.renderMatrixFillLine(samples, width)
    return graph.renderHistoryLine(samples, width, function(sample)
        return (tonumber(sample.matrix_fill) or 0) * 100
    end, function(value)
        return util.formatPercent((tonumber(value) or 0) / 100)
    end, "--")
end

function graph.renderReactorOutputLine(samples, width, unit)
    return graph.renderHistoryLine(samples, width, function(sample)
        return tonumber(sample.reactor_total_output) or 0
    end, function(value)
        return util.formatRate(value, unit)
    end, "--")
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

return graph