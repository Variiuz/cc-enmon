local controller_view = require("lib/controller_view")
local history = require("lib/history")
local net = require("lib/network")
local util = require("lib/util")

local telemetry = {}

function telemetry.new(opts)
    local state = assert(opts.state, "state is required")
    local isStale = assert(opts.isStale, "isStale is required")
    local buildUpdateSnapshot = assert(opts.buildUpdateSnapshot, "buildUpdateSnapshot is required")
    local sendToNode = assert(opts.sendToNode, "sendToNode is required")
    local logLine = assert(opts.logLine, "logLine is required")
    local getEnergyUnit = assert(opts.getEnergyUnit, "getEnergyUnit is required")
    local now = assert(opts.now, "now is required")
    local sample_interval = tonumber(opts.sample_interval) or 1

    local function currentReactorTotals()
        local total = 0
        local per_reactor = {}
        local hottest = nil
        for node_id, reactor in pairs(state.reactors) do
            if not isStale(reactor.updated or 0) then
                local produced = tonumber(reactor.produced_last_t) or 0
                total = total + produced
                local fuel_temp = tonumber(reactor.fuel_temp)
                if fuel_temp and (not hottest or fuel_temp > hottest) then
                    hottest = fuel_temp
                end
                per_reactor[#per_reactor + 1] = {
                    node_id = node_id,
                    output = produced,
                    active = reactor.active == true,
                    control_rod_level = tonumber(reactor.control_rod_level),
                    fuel_temp = fuel_temp,
                }
            end
        end
        table.sort(per_reactor, function(left, right)
            return tostring(left.node_id) < tostring(right.node_id)
        end)
        return total, per_reactor, hottest
    end

    local function captureHistorySample(force)
        if not force and (now() - state.last_history_sample) < sample_interval then
            return
        end

        local total_output, per_reactor, hottest_temp = currentReactorTotals()
        local matrix_fill = 0
        local matrix_energy = 0
        local matrix_max = 0
        local matrix_input = 0
        local matrix_output = 0
        if state.matrix and not isStale(state.matrix_updated) then
            matrix_energy = tonumber(state.matrix.energy) or 0
            matrix_max = tonumber(state.matrix.max_energy) or 0
            matrix_input = tonumber(state.matrix.last_input) or 0
            matrix_output = tonumber(state.matrix.last_output) or 0
            matrix_fill = util.fillFraction(matrix_energy, matrix_max)
        end

        history.recordSample(state.history, {
            captured_at = now(),
            timestamp = util.timestamp(),
            matrix_fill = matrix_fill,
            matrix_energy = matrix_energy,
            matrix_max = matrix_max,
            matrix_input = matrix_input,
            matrix_output = matrix_output,
            reactor_total_output = total_output,
            reactor_peak_temp = hottest_temp,
            reactors = per_reactor,
        })
        history.maybeFlush(state.history)
        state.last_history_sample = now()
    end

    local function buildHistoryPayload(limit)
        return history.getRecentSamples(state.history, limit or 90)
    end

    local api = {}

    function api.updateAlerts(cfg)
        local new_alerts = {}

        if state.matrix == nil or isStale(state.matrix_updated) then
            new_alerts[#new_alerts + 1] = "MATRIX: No data"
        else
            local fill = util.fillFraction(state.matrix.energy, state.matrix.max_energy)
            if fill <= cfg.get("threshold_low") then
                new_alerts[#new_alerts + 1] = "ENERGY LOW: " .. util.formatPercent(fill)
            elseif fill >= cfg.get("threshold_high") then
                new_alerts[#new_alerts + 1] = "ENERGY HIGH: " .. util.formatPercent(fill)
            end
        end

        for node_id, reactor in pairs(state.reactors) do
            if isStale(reactor.updated) then
                new_alerts[#new_alerts + 1] = "REACTOR " .. node_id .. ": No data"
            end
        end

        state.alerts = new_alerts
        if #state.alerts == 0 then
            state.alert_index = 1
        else
            state.alert_index = math.max(1, math.min(state.alert_index or 1, #state.alerts))
        end
    end

    function api.currentAlertText()
        if #state.alerts == 0 then
            return "All nominal", colors.black, colors.white
        end

        local index = state.alert_index or 1
        if index < 1 or index > #state.alerts then
            index = 1
            state.alert_index = 1
        end
        return state.alerts[index], colors.red, colors.white
    end

    function api.rotateAlert()
        if #state.alerts <= 1 then return end
        state.alert_index = (state.alert_index % #state.alerts) + 1
    end

    function api.playAlerts(speaker)
        if not speaker then return end
        if #state.alerts > 0 then
            pcall(speaker.playNote, speaker, "harp", 1, 6)
        end
    end

    function api.autoControl(cfg)
        if not cfg.get("auto_ctrl") then return end
        if state.matrix == nil or isStale(state.matrix_updated) then return end

        local fill = util.fillFraction(state.matrix.energy, state.matrix.max_energy)
        local low_threshold = cfg.get("threshold_low")
        local high_threshold = cfg.get("threshold_high")

        local want_active = nil
        if fill <= low_threshold then
            want_active = true
        elseif fill >= high_threshold then
            want_active = false
        end

        if want_active == nil then return end

        for node_id, reactor in pairs(state.reactors) do
            if not isStale(reactor.updated) and reactor.active ~= want_active then
                sendToNode(node_id, reactor.sender_id, net.MSG.CMD_REACTOR_SET, { active = want_active })
                reactor.pending_active = want_active
                logLine("[ctrl] auto-ctrl: reactor " .. node_id ..
                    " -> " .. tostring(want_active) ..
                    " (fill " .. util.formatPercent(fill) .. ")", colors.lightBlue)
            end
        end
    end

    function api.buildDisplayPayload()
        captureHistorySample(false)
        return controller_view.buildDisplayPayload(
            state,
            isStale,
            buildUpdateSnapshot,
            buildHistoryPayload,
            util.timestamp(),
            getEnergyUnit()
        )
    end

    return api
end

return telemetry