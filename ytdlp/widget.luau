--!nonstrict
-- YT-DLP bar widget.

local isExtracting = false
local isDownloading = false
local downloadProgress = ""
local currentUrl = ""
local lastError = nil

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function getStatus()
  if isExtracting then
    return "Extracting..."
  elseif isDownloading then
    return "Downloading " .. downloadProgress
  else
    return "YT-DLP"
  end
end

local function render()
  local glyph = isExtracting and "loader" or (isDownloading and "download" or "download")
  barWidget.render(ui.button({
    key = "ytdlp-btn",
    text = getStatus(),
    glyph = glyph,
    variant = "ghost",
    selected = false,
    onClick = function()
      noctalia.togglePanel("mindset/ytdlp:panel")
    end,
  }))
end

local function refresh()
  render()
end

function onRightClick()
  noctalia.togglePanel("mindset/ytdlp:panel")
end

function onScroll(axis, steps, startsGesture)
end

function update()
  refresh()
end

noctalia.setUpdateInterval(5000)

refresh()
