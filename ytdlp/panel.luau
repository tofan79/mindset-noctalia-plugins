--!nonstrict
-- YT-DLP panel

local url = ""
local selectedMode = 1
local isExtracting = false
local isDownloading = false

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function onUrlChange(val)
  url = val or ""
end

function onModeChange(idx)
  selectedMode = tonumber(idx) + 1
  render()
end

function onExtract()
  noctalia.notify("YT-DLP Extract", "URL: " .. url)
end

function onDownload()
  noctalia.notify("YT-DLP Download", "URL: " .. url)
end

function onCloseClicked()
  panel.close()
end

local render

render = function()
  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "YT-DLP", fontSize = 16, fontWeight = "bold", color = "primary" }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.separator({}),
    ui.label({ text = "URL", fontSize = 12 }),
    ui.input({ key = "url", placeholder = "Paste URL", value = url, onChange = "onUrlChange" }),
    ui.row({ gap = 8 }, {
      ui.button({ text = "Extract", variant = "primary", disabled = url == "", onClick = "onExtract" }),
      ui.button({ text = "Download", variant = "primary", disabled = url == "", onClick = "onDownload" }),
    }),
    ui.separator({}),
    ui.label({ text = "Mode", fontSize = 12 }),
    ui.select({ key = "mode", options = { "Best", "Video", "Audio" }, selectedIndex = selectedMode - 1, onChange = "onModeChange" }),
    ui.separator({}),
    ui.label({ text = "URL: " .. url, fontSize = 11, color = "on_surface_variant", wrap = true }),
  }))
end

function onOpen()
  render()
end

function onClose()
end
