--!nonstrict
--
-- Today Reminders bar widget.

local PANEL_ID = "mindset/today-reminders:main"

local M = {}
local state = { reminders = {}, count = 0 }

local function render()
    local count = state.count or 0
    barWidget.setGlyph(noctalia.getConfig("glyph") or "bell-ringing")
    if noctalia.getConfig("show_count") ~= false and count > 0 then
        barWidget.setTooltip(count .. " reminder" .. (count > 1 and "s" or "") .. " today")
        barWidget.setText(tostring(count))
    else
        barWidget.setTooltip("No reminders today")
        barWidget.setText("")
    end
end

function M.onClick()
    noctalia.togglePanel(PANEL_ID)
end

function M.onRightClick()
    noctalia.togglePanel(PANEL_ID)
end

noctalia.state.watch("reminders", function(value)
    state = type(value) == "table" and value or { reminders = {}, count = 0 }
    render()
end)

function onClick() M.onClick() end
function onRightClick() M.onRightClick() end
function onConfigChanged() render() end

render()
return M
