--!nonstrict
--
-- Today Reminders panel — minutes-from-now input, no time picker.
--

local PANEL_ID = "mindset/today-reminders:main"

local M = {}

local state = noctalia.state.get("reminders") or { count = 0 }

-- Translations
local function tr(key)
    return noctalia.tr(key) or key
end

-- Reminder row
local function reminderRow(r, i)
    local minsLeft = math.max(0, math.floor((r.fireAt - os.time()) / 60))
    local label = minsLeft > 0
        and ("in " .. minsLeft .. " min")
        or "now"
    local text = r.text and r.text ~= "" and r.text or "(no text)"

    return ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = label, fontSize = 12 }),
        ui.label({ text = text, flexGrow = 1, color = "on_surface_variant" }),
        ui.button({
            glyph = "x",
            variant = "ghost",
            controlSize = "sm",
            tooltip = tr("panel.remove"),
            onClick = function()
                noctalia.state.set("reminders_cmd", { action = "dismiss", id = i })
            end,
        }),
    })
end

local function emptyState()
    return ui.column({ align = "center", gap = 8, padding = 24 }, {
        ui.glyph({ name = "bell-off", size = 32, color = "on_surface_variant" }),
        ui.label({ text = tr("panel.empty"), color = "on_surface_variant" }),
    })
end

local function addSection()
    local minutesVal = ""
    local textVal = ""

    return ui.column({ gap = 8 }, {
        ui.label({ text = tr("panel.add_header"), color = "on_surface", fontSize = 11, fontWeight = "bold" }),
        ui.row({ gap = 6 }, {
            ui.input({
                key = "reminder-minutes",
                placeholder = tr("panel.minutes_placeholder"),
                value = minutesVal,
                flexGrow = 0,
                onChange = function(v) minutesVal = v end,
            }),
            ui.input({
                key = "reminder-text",
                placeholder = tr("panel.text_placeholder"),
                value = textVal,
                flexGrow = 1,
                onChange = function(v) textVal = v end,
            }),
            ui.button({
                glyph = "plus",
                variant = "primary",
                tooltip = tr("panel.add"),
                onClick = function()
                    if minutesVal and minutesVal ~= "" then
                        noctalia.state.set("reminders_cmd", {
                            action = "add",
                            minutes = minutesVal,
                            text = textVal,
                        })
                    end
                end,
            }),
        }),
    })
end

-- Render function (called by host)
function render(props)
    return ui.column({ gap = 8 }, {
        addSection(),
        ui.separator(),
        ui.label({ text = tr("panel.list_header"), color = "on_surface", fontSize = 11, fontWeight = "bold" }),
    })
end

M.init = function()
    -- Watch for commands
    noctalia.state.watch("reminders_cmd", function(cmd)
        if not cmd then return end
        local action = cmd.action
        if action == "add" then
            addReminder(cmd.minutes, cmd.text)
        elseif action == "dismiss" then
            dismissReminder(cmd.id)
        elseif action == "clear" then
            dismissAll()
        end
        noctalia.state.set("reminders_cmd", nil)
    end)
end

M.onClose = function()
    -- nothing
end

return M
