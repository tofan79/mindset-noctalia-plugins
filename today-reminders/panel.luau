--!nonstrict
--
-- Today Reminders panel: add, view, dismiss reminders for today.

local M = {}

local state = { reminders = {}, count = 0 }
local addTime = "09:00"
local addText = ""
local render

-- ── i18n helpers ─────────────────────────────────────────────────────────────

local function tr(key, subst)
    return noctalia.tr(key, subst)
end

-- ── time helpers ─────────────────────────────────────────────────────────────

local function formatTime(time_str)
    local h = tonumber(time_str:sub(1, 2)) or 0
    local m = tonumber(time_str:sub(4, 5)) or 0
    local ampm = h >= 12 and "PM" or "AM"
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    return string.format("%d:%02d %s", h12, m, ampm)
end

local function sortByTime(list)
    local sorted = {}
    for _, r in ipairs(list or {}) do
        sorted[#sorted + 1] = r
    end
    table.sort(sorted, function(a, b) return a.time < b.time end)
    return sorted
end

-- ── add reminder ──────────────────────────────────────────────────────────────

local function addReminder()
    local text = addText or ""
    if text == "" then return end
    noctalia.msg("plugin mindset/today-reminders:service all add " .. noctalia.shellQuote(addTime) .. " " .. noctalia.shellQuote(text))
    addText = ""
    addTime = "09:00"
    render()
end

-- ── render helpers ────────────────────────────────────────────────────────────

local function reminderRow(r)
    local timeLabel = formatTime(r.time)
    local doneColor = r.done and "on_surface_variant" or "on_surface"
    local doneTextDeco = r.done and "line_through" or "none"
    return ui.row({
        key = "r" .. tostring(r.id),
        align = "center",
        gap = 8,
        padding = 6,
    }, {
        ui.glyph({ name = r.done and "check-circle" or "clock", size = 16, color = r.done and "success" or "primary" }),
        ui.column({ gap = 2, flexGrow = 1 }, {
            ui.label({
                text = r.text or "",
                color = doneColor,
                fontSize = 13,
                fontWeight = "medium",
                textDecoration = doneTextDeco,
            }),
            ui.label({
                text = timeLabel,
                color = "on_surface_variant",
                fontSize = 11,
            }),
        }),
        ui.button({
            glyph = "x",
            variant = "ghost",
            controlSize = "sm",
            tooltip = tr("panel.remove"),
            onClick = function()
                noctalia.msg("plugin mindset/today-reminders:service all dismiss " .. tostring(r.id))
            end,
        }),
    })
end

local function emptyState()
    return ui.column({ align = "center", gap = 8, padding = 24 }, {
        ui.glyph({ name = "bell-off", size = 32, color = "on_surface_variant" }),
        ui.label({ text = tr("panel.empty"), color = "on_surface_variant", fontSize = 12 }),
    })
end

local function addSection()
    return ui.column({ gap = 8 }, {
        ui.label({ text = tr("panel.add_header"):upper(), color = "on_surface", fontSize = 11, fontWeight = "bold" }),
        ui.row({ gap = 6 }, {
            ui.input({
                key = "reminder-time",
                type = "time",
                value = addTime,
                flexGrow = 0,
                onChange = function(v) addTime = v end,
            }),
            ui.input({
                key = "reminder-text",
                placeholder = tr("panel.placeholder"),
                value = addText,
                flexGrow = 1,
                onChange = function(v) addText = v end,
                onSubmit = addReminder,
            }),
            ui.button({
                glyph = "plus",
                text = tr("panel.add"),
                variant = "primary",
                onClick = addReminder,
            }),
        }),
    })
end

local function listSection()
    local sorted = sortByTime(state.reminders)
    local pending = {}
    local done = {}
    for _, r in ipairs(sorted) do
        if r.done then
            done[#done + 1] = r
        else
            pending[#pending + 1] = r
        end
    end
    local children = {}
    if #pending > 0 then
        children[#children + 1] = ui.label({ text = tr("panel.pending"):upper(), color = "on_surface", fontSize = 11, fontWeight = "bold" })
        for _, r in ipairs(pending) do
            children[#children + 1] = reminderRow(r)
        end
    end
    if #done > 0 then
        if #pending > 0 then
            children[#children + 1] = ui.separator({})
        end
        children[#children + 1] = ui.label({ text = tr("panel.done"):upper(), color = "on_surface_variant", fontSize = 11, fontWeight = "bold" })
        for _, r in ipairs(done) do
            children[#children + 1] = reminderRow(r)
        end
    end
    return children
end

local function footer()
    return ui.row({ align = "center", gap = 6 }, {
        ui.label({ text = tostring(state.count) .. " " .. tr("panel.footer"), color = "on_surface_variant", fontSize = 10, flexGrow = 1 }),
        ui.button({
            glyph = "trash",
            text = tr("panel.clear_done"),
            variant = "ghost",
            controlSize = "sm",
            tooltip = tr("panel.clear_done"),
            onClick = function()
                noctalia.msg("plugin mindset/today-reminders:service all clearDone")
            end,
        }),
    })
end

render = function()
    panel.render(ui.column({ padding = 18, gap = 14, flexGrow = 1 }, {
        -- Hero
        ui.row({ align = "center", gap = 10 }, {
            ui.glyph({ name = "bell", size = 24, color = "primary" }),
            ui.column({ gap = 1, flexGrow = 1 }, {
                ui.label({ text = tr("panel.title"), fontSize = 17, fontWeight = "bold", color = "on_surface" }),
                ui.label({ text = os.date("%A, %B %d"), fontSize = 11, color = "on_surface_variant" }),
            }),
        }),
        ui.separator({}),
        -- Add form
        addSection(),
        ui.separator({}),
        -- List
        ui.scroll({ flexGrow = 1, gap = 2 }, (function()
            if (state.count or 0) == 0 then
                return { emptyState() }
            end
            return listSection()
        end)()),
        ui.separator({}),
        footer(),
    }))
end

-- ── shell entry points ────────────────────────────────────────────────────────

function onOpen()
    state = noctalia.state.get("reminders") or { reminders = {}, count = 0 }
    addText = ""
    addTime = "09:00"
    render()
end

function onCloseClicked()
    panel.close()
end

noctalia.state.watch("reminders", function(value)
    state = type(value) == "table" and value or { reminders = {}, count = 0 }
    render()
end)

return M
