local runtime = {}

function runtime.new(opts)
    local controller = assert(opts.controller, "controller is required")
    local state = assert(opts.state, "state is required")
    local logLine = assert(opts.logLine, "logLine is required")
    local setRuntimeUi = assert(opts.setRuntimeUi, "setRuntimeUi is required")
    local refreshPanel = assert(opts.refreshPanel, "refreshPanel is required")
    local refreshSelfEntry = assert(opts.refreshSelfEntry, "refreshSelfEntry is required")
    local telemetry = assert(opts.telemetry, "telemetry is required")
    local updates = assert(opts.updates, "updates is required")
    local handlers = assert(opts.handlers, "handlers is required")
    local sendToEntry = assert(opts.sendToEntry, "sendToEntry is required")
    local isStale = assert(opts.isStale, "isStale is required")
    local getAutoCheckInterval = assert(opts.getAutoCheckInterval, "getAutoCheckInterval is required")
    local display_interval = assert(opts.display_interval, "display_interval is required")
    local modem_type = assert(opts.modem_type, "modem_type is required")
    local pmgr = assert(opts.pmgr, "pmgr is required")
    local controller_link = assert(opts.controller_link, "controller_link is required")
    local history = assert(opts.history, "history is required")
    local history_policy = assert(opts.history_policy, "history_policy is required")
    local runtime_panel = assert(opts.runtime_panel, "runtime_panel is required")
    local runtime_actions = assert(opts.runtime_actions, "runtime_actions is required")
    local hud = assert(opts.hud, "hud is required")
    local net = assert(opts.net, "net is required")

    local api = {}

    function api.run(cfg)
        local persistence_mode = history_policy.applyToBuffer(cfg, state.history, history.detectDisk)
        local runtime_ui = runtime_panel.new("Controller")
        setRuntimeUi(runtime_ui)
        runtime_ui.setHint("C Config | F4 View | F5 Check | F6 Offer | F7 Start | F8 Abort | F9 Self")
        logLine("[ctrl] Starting controller: " .. cfg.get("node_id"), colors.lime)
        logLine("[ctrl] History persistence mode: " .. tostring(persistence_mode), colors.lightBlue)

        local modem = pmgr.findPreferred(cfg.get("modem_side"), modem_type, "modem")
        if not modem then error("No ender modem found.") end
        controller_link.openControllerNetwork(cfg, modem)
        if state.history.persist then
            history.restore(state.history)
        end

        local speaker = nil
        local speaker_side = cfg.get("speaker_side")
        if speaker_side then
            speaker = pmgr.wrap(speaker_side)
            if speaker then logLine("[ctrl] Speaker attached: " .. speaker_side, colors.lime) end
        end
        refreshPanel(cfg)

        local monitor_side = cfg.get("monitor_side")
        hud.init(monitor_side, cfg, controller)
        local self_entry = refreshSelfEntry(cfg, "online")
        if self_entry then
            self_entry.local_version = state.updates.controller_version
        end

        local display_timer = os.startTimer(display_interval)
        local alert_timer = os.startTimer(5)
        local rollout_timer = os.startTimer(1)
        local auto_check_timer = os.startTimer(2)
        local runtime_action = nil

        local function net_loop()
            while true do
                local msg = net.receive(display_interval + 1, {
                    net.MSG.NODE_DISCOVERY,
                    net.MSG.NODE_HELLO,
                    net.MSG.MATRIX_DATA,
                    net.MSG.REACTOR_DATA,
                    net.MSG.METER_DATA,
                    net.MSG.GENERATOR_DATA,
                    net.MSG.POCKET_REQUEST,
                    net.MSG.POCKET_CMD,
                    net.MSG.UPDATE_ACK,
                    net.MSG.UPDATE_STATUS,
                })
                if msg then
                    handlers.dispatchMessage(msg, cfg)
                    refreshPanel(cfg)
                    hud.update(telemetry.buildDisplayPayload())
                end
            end
        end

        local function timer_loop()
            while true do
                local _, id = os.pullEvent("timer")
                if id == display_timer then
                    refreshSelfEntry(cfg, "online")
                    local payload = telemetry.buildDisplayPayload()
                    for _, entry in pairs(state.updates.nodes) do
                        if entry.role == "display" and entry.sender_id and not isStale(entry.last_seen or 0) and not entry.controller_mismatch then
                            sendToEntry(entry, net.MSG.DISPLAY_UPDATE, payload)
                        end
                    end
                    telemetry.updateAlerts(cfg)
                    refreshPanel(cfg)
                    hud.update(telemetry.buildDisplayPayload())
                    display_timer = os.startTimer(display_interval)
                elseif id == alert_timer then
                    telemetry.playAlerts(speaker)
                    telemetry.rotateAlert()
                    refreshPanel(cfg)
                    alert_timer = os.startTimer(5)
                elseif id == rollout_timer then
                    updates.tickRollout(cfg)
                    rollout_timer = os.startTimer(1)
                elseif id == auto_check_timer then
                    if not state.updates.offer and not state.updates.rollout and not state.updates.check_deadline then
                        updates.performUpdateCheck(cfg, false)
                    end
                    auto_check_timer = os.startTimer(getAutoCheckInterval(cfg))
                end
            end
        end

        local function key_loop()
            while true do
                local _, key = os.pullEvent("key")
                if runtime_ui and runtime_ui.handleKey(key) then
                elseif key == keys.c then
                    runtime_action = "config"
                    return
                elseif key == keys.f4 then
                    hud.toggleView()
                elseif key == keys.f5 then
                    updates.performUpdateCheck(cfg, false)
                elseif key == keys.f6 then
                    updates.createUpdateOffer(cfg, nil)
                elseif key == keys.f7 then
                    updates.startUpdateOffer(cfg)
                elseif key == keys.f8 then
                    updates.abortUpdateFlow(cfg)
                elseif key == keys.f9 then
                    updates.updateSelf(cfg)
                end
            end
        end

        local function mouse_loop()
            while true do
                local _, direction = os.pullEvent("mouse_scroll")
                if runtime_ui then
                    runtime_ui.handleMouseScroll(direction)
                end
            end
        end

        local function hud_loop()
            hud.run()
        end

        parallel.waitForAny(net_loop, timer_loop, hud_loop, key_loop, mouse_loop)

        if runtime_action == "config" then
            runtime_actions.openConfigEditor(cfg, logLine)
        end
    end

    return api
end

return runtime