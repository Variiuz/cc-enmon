local runtime_panel = require("ui/runtime_panel")
local version = require("lib/version")

local node_runtime = {}

function node_runtime.create(title, cfg, options)
    options = options or {}

    local runtime_ui = runtime_panel.new(title, options.runtime_panel_options)
    local branch = version.getBranchLabel()

    local function logLine(message, fg)
        if runtime_ui then
            runtime_ui.log(message, fg)
        else
            print(message)
        end
    end

    local function updatePanel(status, detail, color)
        local rows = {
            { "Node", tostring(cfg.get("node_id")) },
            { "Version", tostring(version.getVersion()) },
            { "Branch", tostring(branch) },
            { "Channel", tostring(cfg.get("channel")) },
            { "Modem", tostring(cfg.get("modem_side") or "auto") },
        }

        local extra_rows = options.extra_rows and options.extra_rows(cfg) or {}
        for _, row in ipairs(extra_rows) do
            rows[#rows + 1] = row
        end

        rows[#rows + 1] = { "Status", status or "Idle", color or colors.black, colors.white }
        rows[#rows + 1] = { "Detail", detail or "--" }
        runtime_ui.setSummary(rows)
    end

    return {
        ui = runtime_ui,
        log = logLine,
        updatePanel = updatePanel,
        setHint = function(text)
            runtime_ui.setHint(text or "")
        end,
        handleKey = function(key)
            return runtime_ui.handleKey(key)
        end,
    }
end

return node_runtime