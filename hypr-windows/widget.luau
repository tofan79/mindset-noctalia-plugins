--!nonstrict

local PANEL_ID = "mindset/hypr-windows:panel"

barWidget.setGlyph("square-dashed")
barWidget.setTooltip(noctalia.tr("tooltip"))

function onClick()
  noctalia.togglePanel(PANEL_ID)
end
