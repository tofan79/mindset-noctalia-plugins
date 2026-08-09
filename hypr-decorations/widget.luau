--!nonstrict

local PANEL_ID = "mindset/hypr-decorations:panel"

barWidget.setGlyph("wand")
barWidget.setTooltip(noctalia.tr("tooltip"))

function onClick()
  noctalia.togglePanel(PANEL_ID)
end
