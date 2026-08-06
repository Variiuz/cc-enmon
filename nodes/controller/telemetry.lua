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
        for node_id, generator in pairs(state.generators or {}) do
            if not isStale(generator.updated or 0) then
                local produced = tonumber(generator.produced_last_t) or 0
                total = total + produced
                per_reactor[#per_reactor + 1] = {
                    node_id = node_id,
                    output = produced,
                    active = generator.active == true,
                    kind = "generator",
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
        local matrix, matrix_updated = controller_view.getAggregatedMatrix(state, isStale)
        if matrix and not isStale(matrix_updated) then
            matrix_energy = tonumber(matrix.energy) or 0
            matrix_max = tonumber(matrix.max_energy) or 0
            matrix_input = tonumber(matrix.last_input) or 0
            matrix_output = tonumber(matrix.last_output) or 0
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

    local function alertFingerprint(alerts)
        return table.concat(alerts or {}, "|")
    end

    local function applyRedstoneAlert(cfg)
        local side = cfg.get("alert_redstone_side")
        if not side or side == "" then return end
        local active = #(state.alerts or {}) > 0
        pcall(redstone.setOutput, side, active)
    end

    local function postWebhook(cfg, alerts)
        local url = cfg.get("alert_webhook_url")
        if not url or url == "" then return end
        if not http or type(http.post) ~= "function" then return end

        local fingerprint = alertFingerprint(alerts)
        local now_clock = now()
        if fingerprint == "" then
            state.last_webhook_fingerprint = ""
            return
        end
        if state.last_webhook_fingerprint == fingerprint and (now_clock - (state.last_webhook_at or 0)) < 300 then
            return
        end

        local content = "**ENMON** alert\n" .. table.concat(alerts, "\n")
        if #content > 1800 then
            content = content:sub(1, 1797) .. "..."
        end
        local body
        if textutils.serializeJSON then
            body = textutils.serializeJSON({ content = content })
        else
            body = '{"content":"' .. content:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"}'
        end

        local ok, err = pcall(function()
            local response, herr = http.post(url, body, { ["Content-Type"] = "application/json" })
            if response then
                pcall(response.close)
            elseif herr then
                logLine("[ctrl] webhook failed: " .. tostring(herr), colors.orange)
            end
        end)
        if not ok then
            logLine("[ctrl] webhook error: " .. tostring(err), colors.orange)
        else
            state.last_webhook_fingerprint = fingerprint
            state.last_webhook_at = now_clock
        end
    end

    local api = {}

    function api.updateAlerts(cfg)
        local new_alerts = {}
        local matrix, matrix_updated = controller_view.getAggregatedMatrix(state, isStale)

        if matrix == nil or isStale(matrix_updated) then
            new_alerts[#new_alerts + 1] = "MATRIX: No data"
        else
            local fill = util.fillFraction(matrix.energy, matrix.max_energy)
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

        for node_id, generator in pairs(state.generators or {}) do
            if isStale(generator.updated) then
                new_alerts[#new_alerts + 1] = "GENERATOR " .. node_id .. ": No data"
            end
        end

        for node_id, meter in pairs(state.meters or {}) do
            if isStale(meter.updated) then
                new_alerts[#new_alerts + 1] = "METER " .. node_id .. ": No data"
            end
        end

        state.alerts = new_alerts
        if #state.alerts == 0 then
            state.alert_index = 1
        else
            state.alert_index = math.max(1, math.min(state.alert_index or 1, #state.alerts))
        end

        applyRedstoneAlert(cfg)
        postWebhook(cfg, state.alerts)
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
        local matrix, matrix_updated = controller_view.getAggregatedMatrix(state, isStale)
        if matrix == nil or isStale(matrix_updated) then return end

        local fill = util.fillFraction(matrix.energy, matrix.max_energy)
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
            if not isStale(reactor.updated)
                and reactor.active ~= want_active
                and reactor.pending_active ~= want_active then
                sendToNode(node_id, reactor.sender_id, net.MSG.CMD_REACTOR_SET, { active = want_active })
                reactor.pending_active = want_active
                logLine("[ctrl] auto-ctrl: reactor " .. node_id ..
                    " -> " .. tostring(want_active) ..
                    " (fill " .. util.formatPercent(fill) .. ")", colors.lightBlue)
            end
        end

        for node_id, generator in pairs(state.generators or {}) do
            if not isStale(generator.updated)
                and generator.controllable ~= false
                and generator.active ~= want_active
                and generator.pending_active ~= want_active then
                sendToNode(node_id, generator.sender_id, net.MSG.CMD_GENERATOR_SET, { active = want_active })
                generator.pending_active = want_active
                logLine("[ctrl] auto-ctrl: generator " .. node_id ..
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
