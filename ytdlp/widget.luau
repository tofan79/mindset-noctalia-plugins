--!nonstrict
-- YT-DLP bar widget.

local isExtracting = false
local isDownloading = false
local downloadProgress = ""

local PANEL_ID = "mindset/ytdlp:panel"

local function render()
  local glyph = isExtracting and "loader" or (isDownloading and "download" or "brand-youtube-kids")
  barWidget.setGlyph(glyph)
  local tooltip = "YT-DLP"
  if isExtracting then
    tooltip = "Extracting..."
  elseif isDownloading then
    tooltip = "Downloading " .. downloadProgress
  end
  barWidget.setTooltip(tooltip)
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  noctalia.togglePanel(PANEL_ID)
end

function onScroll(axis, steps, startsGesture)
end

function update()
  render()
end

noctalia.setUpdateInterval(5000)

render()
