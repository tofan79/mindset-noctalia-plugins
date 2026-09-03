--!nonstrict

local PANEL_ID = "mindset/better-displays:panel"
local monitorCount = 0

local function render()
  if monitorCount > 1 then
    barWidget.setGlyph("screen-share")
  else
    barWidget.setGlyph("device-desktop")
  end
  barWidget.setTooltip(noctalia.tr("tooltip"))
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

noctalia.runAsync("hyprctl monitors -j", function(result)
  if result.exitCode == 0 then
    local data = noctalia.json.decode(result.stdout)
    if type(data) == "table" then
      monitorCount = #data
    end
  end
  render()
end)

render()
