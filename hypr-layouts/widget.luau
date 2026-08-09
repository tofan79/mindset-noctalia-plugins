--!nonstrict

local PANEL_ID = "mindset/hypr-layouts:panel"

local display = {
  deck      = "Deck",
  fair      = "Fair",
  dwindle   = "Dwindle",
  master    = "Master",
  monocle   = "Monocle",
  scrolling = "Scrolling",
}

local glyphs = {
  deck      = "layers-difference",
  fair      = "layout-board-split",
  dwindle   = "layout-2",
  master    = "layout-sidebar",
  monocle   = "square",
  scrolling = "arrows-horizontal",
}

local current = ""

local function render()
  barWidget.setGlyph(glyphs[current] or "layout-grid")
  barWidget.setText(display[current] or "")
  barWidget.setTooltip(noctalia.tr("tooltip.description", {
    name = display[current] or current or noctalia.tr("tooltip.unknown"),
  }))
end

noctalia.state.watch("hypr_layouts_state", function(value)
  if type(value) == "table" then
    current = value.layout or ""
    render()
  end
end)

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

render()
