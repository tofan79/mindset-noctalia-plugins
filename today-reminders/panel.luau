--!nonstrict
--
-- Today Reminders panel — minutes-from-now input only.
-- Label-above-field form (no history/list). Uses closures for onClick (api ≥ 9).
--

local M = {}

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
    addMinutesVal = ""
    addTextVal = ""
    panel.close()
end

function onAddMinutesChanged(v)
    addMinutesVal = v or ""
end

function onAddTextChanged(v)
    addTextVal = v or ""
end

-- ── Form field helper: label above the input ──────────────────────────────────

local function field(label, input)
    return ui.column({ gap = 4 }, {
        ui.label({
            text = label, color = "on_surface",
            fontSize = 11, fontWeight = "bold",
        }),
        input,
    })
end

-- ── Render ────────────────────────────────────────────────────────────────────

function render()
    panel.render(ui.column({ flexGrow = 1, gap = 12, padding = 12 }, {
        field(tr("panel.time_label"), ui.input({
            key = "add-minutes",
            placeholder = tr("panel.minutes_placeholder"),
            value = addMinutesVal,
            onChange = "onAddMinutesChanged",
        })),
        field(tr("panel.message_label"), ui.input({
            key = "add-text",
            placeholder = tr("panel.text_placeholder"),
            value = addTextVal,
            onChange = "onAddTextChanged",
        })),
        ui.button({
            glyph = "plus",
            text = tr("panel.add"),
            variant = "primary",
            align = "center",
            onClick = "addReminder",
        }),
    }))
end

-- ── shell entry points ────────────────────────────────────────────────────────

function onOpen()
    render()
end

return M