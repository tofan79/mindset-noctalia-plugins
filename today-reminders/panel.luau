--!nonstrict
--
-- Today Reminders panel — minutes-from-now input.
-- Pattern matches working plugins: gamer-mode + containers (global onOpen/render).
--

local M = {}

local state = { reminders = {}, count = 0 }
local addMinutesVal = "5"
local addTextVal = ""

local function tr(key)
    return noctalia.tr(key) or key
end

-- ── UI helpers ────────────────────────────────────────────────────────────────

local function reminderRow(r)
    local minsLeft = math.max(0, math.floor((r.fireAt - os.time()) / 60))
    local label = minsLeft > 0 and ("in " .. minsLeft .. " min") or "now"
    local text = r.text and r.text ~= "" and r.text or "(no text)"
    return ui.row({ gap = 6, align = "center", key = "row-" .. r.id }, {
        ui.label({ text = label, fontSize = 12 }),
        ui.label({ text = text, flexGrow = 1, color = "on_surface_variant" }),
        ui.button({
            glyph = "x", variant = "ghost", controlSize = "sm",
            tooltip = tr("panel.remove"),
            onClick = function()
                noctalia.state.set("reminders_cmd", { action = "dismiss", id = r.id })
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

-- ── Render (must be global) ───────────────────────────────────────────────────

local function buildTree()
    state = noctalia.state.get("reminders") or { reminders = {}, count = 0 }

    local listChildren = {}
    local reminders = state.reminders or {}
    for _, r in pairs(reminders) do
        listChildren[#listChildren + 1] = reminderRow(r)
    end
    if #listChildren == 0 then
        listChildren[#listChildren + 1] = emptyState()
    end

    return ui.scroll({ fill = true, stickToBottom = true }, {
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
                        onChange = function(v) addMinutesVal = v end,
                    }),
                    ui.input({
                        key = "add-text",
                        placeholder = tr("panel.text_placeholder"),
                        value = addTextVal,
                        flexGrow = 1,
                        onChange = function(v) addTextVal = v end,
                    }),
                    ui.button({
                        glyph = "plus", variant = "primary",
                        tooltip = tr("panel.add"),
                        onClick = function()
                            if addMinutesVal ~= "" and tonumber(addMinutesVal) then
                                noctalia.state.set("reminders_cmd", {
                                    action = "add",
                                    minutes = addMinutesVal,
                                    text = addTextVal,
                                })
                                addMinutesVal = "5"
                                addTextVal = ""
                                render()
                            end
                        end,
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
    })
end

function render()
    noctalia.log("today-reminders: panel render, count=" .. (state and state.count or "?"))
    panel.render(buildTree())
end

-- ── shell entry points (must be globals) ──────────────────────────────────────

function onOpen()
    noctalia.log("today-reminders: panel onOpen")
    noctalia.state.watch("reminders", function(val)
        if val then state = val else state = { reminders = {}, count = 0 } end
        render()
    end)
    render()
end

return M
