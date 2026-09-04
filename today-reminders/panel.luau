--!nonstrict
--
-- Today Reminders panel: set reminder in X minutes from now.

local M = {}
local state = { reminders = {}, count = 0 }
local addMinutes = "5"
local addText = ""
local render

local function tr(key) return noctalia.tr(key) end

-- ── Time formatting ─────────────────────────────────────────────────────────

local function formatRemaining(fireAt)
    local diff = (tonumber(fireAt) or 0) - os.time()
    if diff <= 0 then return "now" end
    local mins = math.floor(diff / 60)
    local secs = diff % 60
    if mins >= 60 then
        local hrs = math.floor(mins / 60)
        mins = mins % 60
        return string.format("%dh %dm", hrs, mins)
    end
    return string.format("%dm %ds", mins, secs)
end

-- ── Send command ────────────────────────────────────────────────────────────

local function send(cmd) noctalia.state.set("reminders_cmd", cmd) end

-- ── Add ────────────────────────────────────────────────────────────────────

local function addReminder()
    local text = addText or ""
    if text == "" then return end
    send({ action = "add", minutes = addMinutes, text = text })
    addText = ""
    addMinutes = "5"
    render()
end

-- ── Render helpers ─────────────────────────────────────────────────────────

local function reminderRow(r)
    local remaining = formatRemaining(r.fireAt)
    return ui.row({
        key = "r" .. tostring(r.id),
        align = "center",
        gap = 8,
        padding = 6,
    }, {
        ui.glyph({ name = r.done and "check-circle" or "clock", size = 16, color = r.done and "success" or "primary" }),
        ui.column({ gap = 2, flexGrow = 1 }, {
            ui.label({ text = r.text or "", color = r.done and "on_surface_variant" or "on_surface", fontSize = 13, fontWeight = "medium" }),
            ui.label({ text = r.done and "fired" or remaining, color = "on_surface_variant", fontSize = 11 }),
        }),
        ui.button({
            glyph = "x", variant = "ghost", controlSize = "sm",
            onClick = function() send({ action = "dismiss", id = r.id }) end,
        }),
    })
end

local function emptyState()
    return ui.column({ align = "center", gap = 8, padding = 24 }, {
        ui.glyph({ name = "bell-off", size = 32, color = "on_surface_variant" }),
        ui.label({ text = tr("panel.empty"), color = "on_surface_variant", fontSize = 12 }),
    })
end

local function listSection()
    local pending, done = {}, {}
    for _, r in ipairs(state.reminders) do
        if r.done then done[#done + 1] = r else pending[#pending + 1] = r end
    end
    local children = {}
    if #pending > 0 then
        children[#children + 1] = ui.label({ text = tr("panel.pending"):upper(), color = "on_surface", fontSize = 11, fontWeight = "bold" })
        for _, r in ipairs(pending) do children[#children + 1] = reminderRow(r) end
    end
    if #done > 0 then
        if #pending > 0 then children[#children + 1] = ui.separator({}) end
        children[#children + 1] = ui.label({ text = tr("panel.done"):upper(), color = "on_surface_variant", fontSize = 11, fontWeight = "bold" })
        for _, r in ipairs(done) do children[#children + 1] = reminderRow(r) end
    end
    return children
end

local function footer()
    return ui.row({ align = "center", gap = 6 }, {
        ui.label({ text = tostring(state.count) .. " " .. tr("panel.footer"), color = "on_surface_variant", fontSize = 10, flexGrow = 1 }),
        ui.button({
            glyph = "trash", text = tr("panel.clear_done"), variant = "ghost", controlSize = "sm",
            onClick = function() send({ action = "clearDone" }) end,
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
        ui.column({ gap = 8 }, {
            ui.label({ text = tr("panel.add_header"):upper(), color = "on_surface", fontSize = 11, fontWeight = "bold" }),
            ui.row({ gap = 6 }, {
                ui.input({
                    key = "reminder-minutes",
                    placeholder = tr("panel.minutes_placeholder"),
                    value = addMinutes,
                    flexGrow = 0,
                    onChange = function(v) addMinutes = v or "5" end,
                }),
                ui.input({
                    key = "reminder-text",
                    placeholder = tr("panel.placeholder"),
                    value = addText,
                    flexGrow = 1,
                    onChange = function(v) addText = v or "" end,
                    onSubmit = addReminder,
                }),
                ui.button({
                    glyph = "plus", text = tr("panel.add"), variant = "primary",
                    onClick = addReminder,
                }),
            }),
        }),
        ui.separator({}),
        -- List
        ui.scroll({ flexGrow = 1, gap = 2 }, (#(state.reminders or {}) == 0) and { emptyState() } or listSection()),
        ui.separator({}),
        footer(),
    }))
end

function onOpen()
    state = noctalia.state.get("reminders") or { reminders = {}, count = 0 }
    addText = ""; addMinutes = "5"
    render()
end

function onCloseClicked() panel.close() end

noctalia.state.watch("reminders", function(value)
    state = type(value) == "table" and value or { reminders = {}, count = 0 }
    render()
end)

return M
