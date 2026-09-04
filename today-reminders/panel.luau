--!nonstrict
--
-- Today Reminders panel — minutes-from-now input.
-- Uses global callbacks per skill doc: closures are not resolved by the ui bridge.
-- Actually closures work fine for api ≥ 9.
--

local M = {}

local state = { reminders = {}, count = 0 }
local addMinutesVal = "5"
local addTextVal = ""

local function tr(key)
    return noctalia.tr(key) or key
end

-- ── Named global callbacks (must be global, referenced by string from ui props) ─

function addReminder()
    local mins = addMinutesVal
    local text = addTextVal
    if mins == "" or not tonumber(mins) then return end
    noctalia.state.set("reminders_cmd", {
        action = "add",
        minutes = mins,
        text = text,
    })
    addMinutesVal = "5"
    addTextVal = ""
    render()
end

function dismissReminder(_)
    if not pendingDismissId then return end
    noctalia.state.set("reminders_cmd", { action = "dismiss", id = pendingDismissId })
    pendingDismissId = nil
    render()
end

function onAddMinutesChanged(v)
    addMinutesVal = v or ""
end

function onAddTextChanged(v)
    addTextVal = v or ""
end

-- ── UI helpers ────────────────────────────────────────────────────────────────

local function reminderRow(r)
    local minsLeft = math.max(0, math.floor((r.fireAt - os.time()) / 60))
    local label = minsLeft > 0 and ("in " .. minsLeft .. " min") or "now"
    local text = r.text and r.text ~= "" and r.text or "(no text)"
    local rid = tostring(r.id)
    local dismissFn = function()
        pendingDismissId = r.id
        dismissReminder(nil)
    end
    return ui.row({ gap = 6, align = "center", key = "row-" .. rid }, {
        ui.label({ text = label, fontSize = 12 }),
        ui.label({ text = text, flexGrow = 1, color = "on_surface_variant" }),
        ui.button({
            glyph = "x", variant = "ghost", controlSize = "sm",
            tooltip = tr("panel.remove"),
            onClick = dismissFn,
        }),
    })
end

local function emptyState()
    return ui.column({ align = "center", gap = 8, padding = 24 }, {
        ui.glyph({ name = "bell-off", size = 32, color = "on_surface_variant" }),
        ui.label({ text = tr("panel.empty"), color = "on_surface_variant" }),
    })
end

-- ── Render ────────────────────────────────────────────────────────────────────

function render()
    state = noctalia.state.get("reminders") or { reminders = {}, count = 0 }

    local listChildren = {}
    local reminders = state.reminders or {}
    for _, r in pairs(reminders) do
        listChildren[#listChildren + 1] = reminderRow(r)
    end
    if #listChildren == 0 then
        listChildren[#listChildren + 1] = emptyState()
    end

    panel.render(ui.scroll({ fill = true, stickToBottom = true }, {
        ui.column({ gap = 8, padding = 12 }, {
            ui.column({ gap = 6 }, {
                ui.label({
                    text = tr("panel.add_header"), color = "on_surface",
                    fontSize = 11, fontWeight = "bold",
                }),
                ui.row({ gap = 6 }, {
                    ui.input({
                        key = "add-minutes",
                        placeholder = tr("panel.minutes_placeholder"),
                        value = addMinutesVal,
                        flexGrow = 0,
                        onChange = "onAddMinutesChanged",
                    }),
                    ui.input({
                        key = "add-text",
                        placeholder = tr("panel.text_placeholder"),
                        value = addTextVal,
                        flexGrow = 1,
                        onChange = "onAddTextChanged",
                    }),
                    ui.button({
                        glyph = "plus", variant = "primary",
                        tooltip = tr("panel.add"),
                        onClick = "addReminder",
                    }),
                }),
            }),
            ui.separator(),
            ui.label({
                text = tr("panel.list_header"), color = "on_surface",
                fontSize = 11, fontWeight = "bold",
            }),
            ui.column({ gap = 4 }, listChildren),
        }),
    }))
end

-- ── shell entry points ────────────────────────────────────────────────────────

function onOpen()
    noctalia.state.watch("reminders", function(val)
        if val then state = val else state = { reminders = {}, count = 0 } end
        render()
    end)
    render()
end

return M
