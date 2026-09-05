--!nonstrict
-- YT-DLP panel - simple version

local url = ""
local selectedMode = 1
local isExtracting = false
local isDownloading = false
local videoInfo = nil
local lastError = nil
local downloadDir = "/home/Downloads"

local modeOptions = { "Best Quality", "Video Only", "Audio Only" }

local stateFile = (noctalia.pluginDataDir() or "") .. "/state.json"

local function saveState()
  local ok, err = noctalia.writeFile(stateFile, noctalia.json.encode({
    downloadDir = downloadDir,
    selectedMode = selectedMode,
  }, true))
end

local function loadState()
  local raw = noctalia.readFile(stateFile)
  if raw then
    local ok, data = pcall(noctalia.json.decode, raw)
    if ok and data then
      if data.downloadDir then downloadDir = data.downloadDir end
      if data.selectedMode then selectedMode = data.selectedMode end
    end
  end
end

loadState()

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function doExtract()
  if url == "" then return end
  isExtracting = true
  render()
  local cmd = "yt-dlp -J --no-download --no-warnings " .. shellQuote(url)
  noctalia.runAsync(cmd, function(r)
    isExtracting = false
    if r.exitCode == 0 and r.stdout then
      local ok, data = pcall(noctalia.json.decode, r.stdout)
      if ok and data then videoInfo = data else lastError = "Parse error" end
    else
      lastError = "Extract failed"
    end
    render()
  end)
end

local function doDownload()
  if url == "" then return end
  isDownloading = true
  render()
  local outputTemplate = downloadDir .. "/%(title)s.%(ext)s"
  local cmd = "yt-dlp -f best -o " .. shellQuote(outputTemplate) .. " " .. shellQuote(url)
  noctalia.runAsync(cmd, function(r)
    isDownloading = false
    if r.exitCode == 0 then
      noctalia.notify("YT-DLP", "Download complete!")
    else
      lastError = "Download failed"
    end
    render()
  end)
end

function onUrlChange(val)
  url = val or ""
end

function onModeChange(idx)
  selectedMode = tonumber(idx) + 1
  saveState()
  render()
end

function onExtract()
  doExtract()
end

function onDownload()
  doDownload()
end

function onCloseClicked()
  panel.close()
end

local render

render = function()
  local info = ""
  if videoInfo then
    info = "Ready: " .. tostring(videoInfo.title or "Unknown")
  elseif lastError then
    info = "Error: " .. lastError
  elseif isExtracting then
    info = "Extracting..."
  elseif isDownloading then
    info = "Downloading..."
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "YT-DLP", fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.separator({}),
    ui.label({ text = "URL", fontSize = 12, fontWeight = "bold" }),
    ui.input({ key = "url", placeholder = "Paste URL", value = url, onChange = "onUrlChange" }),
    ui.row({ gap = 8 }, {
      ui.button({ text = "Extract", variant = "primary", disabled = url == "" or isExtracting or isDownloading, onClick = "onExtract" }),
      ui.button({ text = "Download", variant = "primary", disabled = url == "" or isExtracting or isDownloading, onClick = "onDownload" }),
    }),
    ui.separator({}),
    ui.label({ text = "Mode", fontSize = 12, fontWeight = "bold" }),
    ui.select({ key = "mode", options = modeOptions, selectedIndex = selectedMode - 1, onChange = "onModeChange" }),
    ui.separator({}),
    ui.label({ text = info, fontSize = 11, color = "on_surface_variant", wrap = true }),
  }))
end

function onOpen()
  render()
end

function onClose()
end
