--!nonstrict
-- YT-DLP panel for downloading media.

local isOpen = false
local url = ""
local videoInfo = nil
local isExtracting = false
local isDownloading = false
local downloadProgress = ""
local lastError = nil
local selectedMode = 1
local selectedQuality = 1
local downloadDir = "/home/Downloads"

local modeOptions = { "Best Quality", "Video Only", "Audio Only" }
local qualityOptions = { "Best", "2160p", "1440p", "1080p", "720p", "480p", "360p", "240p" }

local stateFile = (noctalia.pluginDataDir() or "") .. "/state.json"

local function saveState()
  local ok, err = noctalia.writeFile(stateFile, noctalia.json.encode({
    downloadDir = downloadDir,
    selectedMode = selectedMode,
    selectedQuality = selectedQuality,
  }, true))
  if not ok then noctalia.log("ytdlp: saveState failed: " .. tostring(err)) end
end

local function loadState()
  local raw = noctalia.readFile(stateFile)
  if raw then
    local ok, data = pcall(noctalia.json.decode, raw)
    if ok and data then
      if data.downloadDir then downloadDir = data.downloadDir end
      if data.selectedMode then selectedMode = data.selectedMode end
      if data.selectedQuality then selectedQuality = data.selectedQuality end
    end
  end
end

loadState()

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function doExtract()
  if not url or url == "" then
    lastError = "Please enter a URL"
    render()
    return
  end

  isExtracting = true
  lastError = nil
  render()

  local cmd = "yt-dlp -J --no-download --no-warnings " .. shellQuote(url)
  noctalia.runAsync(cmd, function(r)
    isExtracting = false
    if r.exitCode == 0 and r.stdout then
      local ok, data = pcall(noctalia.json.decode, r.stdout)
      if ok and data then
        videoInfo = data
      else
        lastError = "Failed to parse video info"
      end
    else
      lastError = "Failed to extract: " .. (r.stderr or "Unknown error")
    end
    render()
  end)
end

local function doDownload()
  if not url or url == "" then
    lastError = "Please enter a URL"
    render()
    return
  end

  isDownloading = true
  downloadProgress = "0%"
  lastError = nil
  render()

  local outputTemplate = downloadDir .. "/%(title)s.%(ext)s"

  local cmd = "yt-dlp "
  if selectedMode == 2 then
    cmd = cmd .. "-f 'bestvideo[height<=?" .. qualityOptions[selectedQuality] .. "]+bestaudio/best[height<=?" .. qualityOptions[selectedQuality] .. "]' "
  elseif selectedMode == 3 then
    cmd = cmd .. "-x --audio-format mp3 "
  else
    cmd = cmd .. "-f best "
  end
  cmd = cmd .. "-o " .. shellQuote(outputTemplate) .. " " .. shellQuote(url)

  noctalia.runAsync(cmd, function(r)
    isDownloading = false
    if r.exitCode == 0 then
      downloadProgress = "Done!"
    else
      lastError = "Download failed"
      downloadProgress = ""
    end
    render()
  end)
end

local function formatDuration(seconds)
  if not seconds then return "N/A" end
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = math.floor(seconds % 60)
  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s)
  else
    return string.format("%d:%02d", m, s)
  end
end

local function formatSize(bytes)
  if not bytes then return "N/A" end
  local units = {"B", "KB", "MB", "GB"}
  local i = 1
  local b = tonumber(bytes) or 0
  while b >= 1024 and i < #units do
    b = b / 1024
    i = i + 1
  end
  return string.format("%.1f %s", b, units[i])
end

function onUrlChange(val)
  url = val or ""
end

function onDirChange(val)
  if val and val ~= "" then
    downloadDir = val
    saveState()
  end
end

function onModeChange(idx)
  selectedMode = tonumber(idx) + 1
  saveState()
  render()
end

function onQualityChange(idx)
  selectedQuality = tonumber(idx) + 1
  saveState()
  render()
end

local render

render = function()
  local modeIndex = selectedMode - 1
  local qualityIndex = selectedQuality - 1
  local canExtract = not isExtracting and not isDownloading and url and url ~= ""

  local infoSection = {}
  if videoInfo then
    local title = videoInfo.title or "Unknown"
    local duration = formatDuration(videoInfo.duration)
    local size = formatSize(videoInfo.filesize or videoInfo.filesize_approx)

    table.insert(infoSection, ui.label({
      text = "Title: " .. tostring(title):sub(1, 40) .. (#title > 40 and "..." or ""),
      fontSize = 11,
      color = "on_surface",
      wrap = true,
    }))
    table.insert(infoSection, ui.label({
      text = "Duration: " .. duration .. " | Size: ~" .. size,
      fontSize = 10,
      color = "on_surface_variant",
    }))
  elseif lastError then
    table.insert(infoSection, ui.label({
      text = "Error: " .. lastError,
      fontSize = 11,
      color = "error",
    }))
  elseif isExtracting then
    table.insert(infoSection, ui.label({
      text = "Extracting video info...",
      fontSize = 11,
      color = "on_surface_variant",
    }))
  elseif isDownloading then
    table.insert(infoSection, ui.label({
      text = "Downloading: " .. downloadProgress,
      fontSize = 11,
      color = "primary",
    }))
  else
    table.insert(infoSection, ui.label({
      text = "Enter a URL and click Extract or Download",
      fontSize = 11,
      color = "on_surface_variant",
    }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 8 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "YT-DLP", fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.separator({}),
    ui.label({ text = "URL", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.input({
      key = "url-input",
      placeholder = "Paste URL here",
      value = url,
      onChange = "onUrlChange",
    }),
    ui.row({ gap = 8 }, {
      ui.button({
        key = "extract-btn",
        text = "Extract",
        glyph = "search",
        variant = "primary",
        disabled = not canExtract,
        onClick = function()
          doExtract()
        end,
      }),
      ui.button({
        key = "download-btn",
        text = "Download",
        glyph = "download",
        variant = "primary",
        disabled = not canExtract,
        onClick = function()
          doDownload()
        end,
      }),
    }),
    ui.separator({}),
    ui.label({ text = "Options", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Mode:", fontSize = 11, width = 50 }),
      ui.select({
        key = "mode-select",
        options = modeOptions,
        selectedIndex = modeIndex,
        controlSize = "sm",
        onChange = "onModeChange",
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Quality:", fontSize = 11, width = 50 }),
      ui.select({
        key = "quality-select",
        options = qualityOptions,
        selectedIndex = qualityIndex,
        controlSize = "sm",
        disabled = selectedMode == 3,
        onChange = "onQualityChange",
      }),
    }),
    ui.separator({}),
    ui.scroll({ flexGrow = 1 }, ui.column({ gap = 4 }, infoSection)),
  }))
end

function onOpen(_context)
  isOpen = true
  loadState()
  render()
end

function onClose()
  isOpen = false
end

function onCloseClicked()
  panel.close()
end

function onKey(chord, pressed)
  if not pressed then return end
  if chord == "Escape" then
    panel.close()
  elseif chord == "Enter" then
    if url and url ~= "" and not isDownloading then
      doDownload()
    end
  end
end
