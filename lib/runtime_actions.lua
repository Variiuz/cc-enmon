local actions = {}

function actions.openConfigEditor(cfg, logger)
    local okEditor, editor = pcall(require, "ui/config_editor")
    if not okEditor then
        if logger then
            logger("[runtime] Config editor unavailable: " .. tostring(editor), colors.red)
        end
        return false
    end

    local okRun, action = pcall(editor.run, cfg.export())
    if not okRun then
        if logger then
            logger("[runtime] Config editor failed: " .. tostring(action), colors.red)
        end
        return false
    end

    shell.run("enmon.lua")
    return action == "launch"
end

return actions