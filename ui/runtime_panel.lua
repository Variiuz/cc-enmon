-- ui/runtime_panel.lua
-- Lightweight themed terminal panel for ENMON runtime nodes.
-- Uses plain term/window APIs so it can run alongside monitor HUDs.

local panel = {}

local STYLE = {
    root_bg      = colors.lightGray,
    root_fg      = colors.black,
    title_bg     = colors.gray,
    title_fg     = colors.white,
    section_bg   = colors.lime,
    section_fg   = colors.black,
    label_fg     = colors.gray,
    value_bg     = colors.white,
    value_fg     = colors.black,
    hint_fg      = colors.gray,
    ok_fg        = colors.lime,
    warn_fg      = colors.orange,
    err_fg       = colors.red,
    highlight_bg = colors.blue,
    highlight_fg = colors.white,
}

local function truncate(text, width)
    text = tostring(text or "")
    if width <= 0 then return "" end
    if #text <= width then return text end
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
end

function panel.new(section, options)
    local root = term.current()
    options = options or {}
    local state = {
        title = "ENMON Runtime",
        section = section or "Status",
        hint = "",
        summary = {},
        logs = {},
        max_logs = 64,
        scroll_offset = 0,
        interactive_scroll = options.interactive_scroll == true,
    }

    local self = {}

    local function computeLogHeight(h)
        return math.max(1, h - 10 - #state.summary)
    end

    local function maxOffset(log_height)
        return math.max(0, #state.logs - log_height)
    end

    local function clampOffset(log_height)
        if state.scroll_offset < 0 then state.scroll_offset = 0 end
        local limit = maxOffset(log_height)
        if state.scroll_offset > limit then state.scroll_offset = limit end
    end

    local function buildHint(log_height)
        local hint = tostring(state.hint or "")
        if not state.interactive_scroll then
            return hint
        end

        local scroll_hint = "Up/down PgUp/PgDn Home/End"
        if state.scroll_offset == 0 then
            scroll_hint = scroll_hint .. " Live"
        else
            scroll_hint = scroll_hint .. string.format(" %d lines above latest", state.scroll_offset)
        end

        local width = select(1, root.getSize())
        if hint == "" then
            return truncate(scroll_hint, math.max(1, width - 2))
        end

        local prefix = truncate(hint, math.max(1, width - #scroll_hint - 5))
        return prefix .. " | " .. scroll_hint
    end

    local function writeAt(target, x, y, text, fg, bg)
        local w = select(1, target.getSize())
        if y < 1 or x > w then return end
        text = tostring(text or "")
        if x < 1 then
            text = text:sub(2 - x)
            x = 1
        end
        target.setCursorPos(x, y)
        if bg then target.setBackgroundColor(bg) end
        if fg then target.setTextColor(fg) end
        target.write(truncate(text, w - x + 1))
    end

    local function fillLine(y, bg, fg)
        local w = select(1, root.getSize())
        root.setCursorPos(1, y)
        root.setBackgroundColor(bg)
        root.setTextColor(fg or STYLE.root_fg)
        root.write(string.rep(" ", w))
    end

    local function draw()
        local w, h = root.getSize()
        root.setBackgroundColor(STYLE.root_bg)
        root.setTextColor(STYLE.root_fg)
        root.clear()

        fillLine(1, STYLE.title_bg, STYLE.title_fg)
        writeAt(root, 2, 1, state.title, STYLE.title_fg, STYLE.title_bg)

        fillLine(2, STYLE.section_bg, STYLE.section_fg)
        writeAt(root, 2, 2, state.section, STYLE.section_fg, STYLE.section_bg)

        local content = window.create(root, 2, 4, math.max(1, w - 2), math.max(1, h - 5), true)
        content.setBackgroundColor(STYLE.root_bg)
        content.setTextColor(STYLE.root_fg)
        content.clear()

        local row = 1
        for _, item in ipairs(state.summary) do
            local label = tostring(item[1] or "")
            local value = tostring(item[2] or "--")
            local fg = item[3] or STYLE.value_fg
            local bg = item[4] or STYLE.value_bg
            writeAt(content, 1, row, truncate(label, 14), STYLE.label_fg, STYLE.root_bg)
            writeAt(content, 16, row, string.rep(" ", math.max(1, w - 18)), fg, bg)
            writeAt(content, 17, row, value, fg, bg)
            row = row + 1
        end

        row = row + 1
        writeAt(content, 1, row, "Activity", STYLE.root_fg, STYLE.root_bg)
        row = row + 1

        local log_height = computeLogHeight(h)
        clampOffset(log_height)
        local start = math.max(1, (#state.logs - log_height + 1) - state.scroll_offset)
        local finish = math.min(#state.logs, start + log_height - 1)
        for i = start, finish do
            local entry = state.logs[i]
            writeAt(content, 1, row, entry.text, entry.fg or STYLE.root_fg, STYLE.root_bg)
            row = row + 1
        end

        fillLine(h - 1, STYLE.root_bg, STYLE.hint_fg)
        writeAt(root, 2, h - 1, buildHint(log_height), STYLE.hint_fg, STYLE.root_bg)
        fillLine(h, STYLE.root_bg, STYLE.root_fg)
    end

    local function scroll(delta)
        local _, h = root.getSize()
        local log_height = computeLogHeight(h)
        state.scroll_offset = state.scroll_offset + delta
        clampOffset(log_height)
        draw()
    end

    local function followLatest()
        if state.scroll_offset ~= 0 then
            state.scroll_offset = 0
            draw()
        end
    end

    local function pumpInput()
        if not state.interactive_scroll then return end

        local _, h = root.getSize()
        local log_height = computeLogHeight(h)
        local step = math.max(1, math.floor(log_height / 2))
        local timer = os.startTimer(0)

        while true do
            local event, a = os.pullEvent()
            if event == "timer" and a == timer then
                break
            elseif event == "key" then
                if a == keys.up then
                    scroll(1)
                elseif a == keys.down then
                    scroll(-1)
                elseif a == keys.pageUp then
                    scroll(step)
                elseif a == keys.pageDown then
                    scroll(-step)
                elseif a == keys.home then
                    state.scroll_offset = maxOffset(log_height)
                    draw()
                elseif a == keys["end"] then
                    followLatest()
                end
            elseif event == "mouse_scroll" then
                scroll(a)
            end
        end
    end

    function self.setSection(text)
        state.section = tostring(text or "Status")
        draw()
    end

    function self.setHint(text)
        state.hint = tostring(text or "")
        draw()
    end

    function self.setSummary(items)
        state.summary = items or {}
        draw()
    end

    function self.log(text, fg)
        state.logs[#state.logs + 1] = { text = tostring(text or ""), fg = fg }
        if #state.logs > state.max_logs then
            table.remove(state.logs, 1)
        end
        draw()
        pumpInput()
    end

    function self.clearLogs()
        state.logs = {}
        state.scroll_offset = 0
        draw()
    end

    draw()
    return self
end

return panel
