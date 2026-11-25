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
  -- Hyprland reports custom layouts as "lua:deck"; the display tables are
  -- keyed by the bare registered name.
  local key = current:gsub("^lua:", "")
  barWidget.setGlyph(glyphs[key] or "layout-grid")
  local name = display[key] or (key ~= "" and key or nil) or noctalia.tr("tooltip.unknown")
  barWidget.setText(display[key] or "")
  barWidget.setTooltip(noctalia.tr("tooltip.description", { name = name }))
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
