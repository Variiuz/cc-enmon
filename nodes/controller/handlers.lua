local controller_link = require("lib/controller_link")
local net = require("lib/network")
local pocket_link = require("lib/pocket_link")

local handlers = {}

function handlers.new(opts)
    local state = assert(opts.state, "state is required")
    local now = assert(opts.now, "now is required")
    local logLine = assert(opts.logLine, "logLine is required")
    local rememberNode = assert(opts.rememberNode, "rememberNode is required")
    local reportNodeChange = assert(opts.reportNodeChange, "reportNodeChange is required")
    local refreshPanel = assert(opts.refreshPanel, "refreshPanel is required")
    local updates = assert(opts.updates, "updates is required")
    local telemetry = assert(opts.telemetry, "telemetry is required")
    local sendToNode = assert(opts.sendToNode, "sendToNode is required")

    local api = {}

    function api.onNodeDiscovery(msg, cfg)
        local payload = msg.payload or {}
        local entry, change = rememberNode(msg.node_id, payload.role, msg.sender_id, payload)
        if entry then
            entry.unlinked = true
            entry.adopted = false
            entry.update_status = "unlinked"
            entry.message = "Claim code " .. tostring(payload.claim_code or "------") .. " - select and adopt to link"
            entry.controller_mismatch = false
        end
        reportNodeChange(entry, change)
        refreshPanel(cfg)
    end

    function api.onMatrixData(msg, cfg)
        if not controller_link.validateNodeMessage(msg, logLine) then
            return
        end
        local entry, change = rememberNode(msg.node_id, "matrix", msg.sender_id, msg.payload)
        reportNodeChange(entry, change)
        updates.reconcileNode(entry, cfg, "matrix-data")
        if updates.blockMismatchedOperationalNode(entry, "matrix data") then
            refreshPanel(cfg)
            return
        end
        state.matrix = msg.payload
        state.matrix_updated = now()
        telemetry.updateAlerts(cfg)
        telemetry.autoControl(cfg)
    end

    function api.onReactorData(msg, cfg)
        if not controller_link.validateNodeMessage(msg, logLine) then
            return
        end
        local node_id = msg.node_id
        local entry, change = rememberNode(node_id, "reactor", msg.sender_id, msg.payload)
        reportNodeChange(entry, change)
        updates.reconcileNode(entry, cfg, "reactor-data")
        if updates.blockMismatchedOperationalNode(entry, "reactor data") then
            refreshPanel(cfg)
            return
        end
        if not state.reactors[node_id] then
            state.reactors[node_id] = {}
            logLine("[ctrl] New reactor node registered: " .. node_id, colors.lime)
        end
        local reactor = state.reactors[node_id]
        for key, value in pairs(msg.payload or {}) do
            reactor[key] = value
        end
        reactor.active = msg.payload.active == true
        reactor.produced_last_t = tonumber(msg.payload.produced_last_t) or 0
        reactor.updated = now()
        reactor.node_id = node_id
        reactor.sender_id = msg.sender_id
        if reactor.pending_active ~= nil and reactor.active == reactor.pending_active then
            reactor.pending_active = nil
        end
        if reactor.pending_control_rod_level ~= nil and reactor.control_rod_level ~= nil then
            local diff = math.abs((tonumber(reactor.control_rod_level) or 0) - reactor.pending_control_rod_level)
            if diff <= 1 then
                reactor.pending_control_rod_level = nil
            end
        end
        telemetry.updateAlerts(cfg)
        refreshPanel(cfg)
    end

    function api.onPocketRequest(msg, cfg)
        if not controller_link.validateNodeMessage(msg, logLine) then
            return
        end
        local entry, change = rememberNode(msg.node_id, "pocket", msg.sender_id, msg.payload)
        reportNodeChange(entry, change)
        updates.reconcileNode(entry, cfg, "pocket-request")
        if updates.blockMismatchedOperationalNode(entry, "pocket request") then
            refreshPanel(cfg)
            return
        end
        local payload = pocket_link.buildTargetedPayload(telemetry.buildDisplayPayload(), msg.sender_id)
        sendToNode(msg.node_id, msg.sender_id, net.MSG.POCKET_DATA, payload)
    end

    function api.onNodeHello(msg, cfg)
        local payload = msg.payload or {}
        local entry, change = rememberNode(msg.node_id, payload.role, msg.sender_id, payload)
        if entry then
            entry.unlinked = false
            entry.adopted = true
            entry.message = nil
            if entry.update_status == "unlinked" or entry.update_status == "adopting" then
                entry.update_status = "online-current"
            end
        end
        reportNodeChange(entry, change)
        updates.reconcileNode(entry, cfg, payload.status or "hello")
        updates.blockMismatchedOperationalNode(entry, "node hello")
        refreshPanel(cfg)
    end

    function api.onUpdateAck(msg, cfg)
        if not controller_link.validateNodeMessage(msg, logLine) then
            return
        end
        if not net.isTargetedToSelf(msg) then return end
        updates.handleUpdateAck(msg, cfg)
    end

    function api.onUpdateStatus(msg, cfg)
        if not net.isTargetedToSelf(msg) then return end
        if not controller_link.validateNodeMessage(msg, logLine) then
            return
        end
        updates.handleUpdateStatus(msg, cfg)
    end

    function api.dispatchMessage(msg, cfg)
        if msg.type == net.MSG.NODE_DISCOVERY then
            api.onNodeDiscovery(msg, cfg)
        elseif msg.type == net.MSG.NODE_HELLO then
            api.onNodeHello(msg, cfg)
        elseif msg.type == net.MSG.MATRIX_DATA then
            api.onMatrixData(msg, cfg)
        elseif msg.type == net.MSG.REACTOR_DATA then
            api.onReactorData(msg, cfg)
        elseif msg.type == net.MSG.POCKET_REQUEST then
            api.onPocketRequest(msg, cfg)
        elseif msg.type == net.MSG.UPDATE_ACK then
            api.onUpdateAck(msg, cfg)
        elseif msg.type == net.MSG.UPDATE_STATUS then
            api.onUpdateStatus(msg, cfg)
        end
    end

    return api
end

return handlers