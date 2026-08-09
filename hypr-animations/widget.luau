--!nonstrict

local PANEL_ID = "mindset/hypr-animations:panel"

barWidget.setGlyph("palette")
barWidget.setTooltip(noctalia.tr("tooltip"))

function onClick()
  noctalia.togglePanel(PANEL_ID)
end
