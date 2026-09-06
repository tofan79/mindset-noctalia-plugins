--!nonstrict
--
-- YT-DLP service: owns every yt-dlp subprocess and all plugin state. The panel and the
-- widget are thin readers of `noctalia.state`; every mutation arrives here as a
-- `command` state write (same split as gamer-mode).
--
-- Downloads stream live progress through `noctalia.runStream`. A small `sh` wrapper
-- writes its own pid to the data dir so the panel can pause/cancel by signalling it,
-- and echoes a sentinel line after the process exits, because runStream has no
-- on-close callback to report an exit code back.

local noctalia = noctalia
if noctalia == nil then
  -- Standalone (tests): run against the host mock instead of the real shell.
  local host = dofile("tests/host_mock.luau")
  noctalia = host.noctalia
end

local M = {}

local DATA_DIR = noctalia.pluginDataDir() or ""
local SETTINGS_PATH = DATA_DIR .. "/settings.json"
local PID_PATH = DATA_DIR .. "/active.pid"
local THUMBS_DIR = DATA_DIR .. "/thumbnails"
local ERROR_LOG_PATH = DATA_DIR .. "/last_error.log"

local HISTORY_LIMIT = 50
local MAX_LOG = 65536
local EXIT_SENTINEL = "__YTDLP_EXIT__"
local STAT_PREFIX = "progress:"

local _settings = {}
local _panelOpen = false
local _sessionWebClient = false
local _extractGeneration = 0
local _pauseRequested = false
local _cancelPending = false
local _forceNoSubs = false
local _extractRetried = false
local _lastHandledNonce = 0
local _lastRawInput = ""
local _lastExtractedUrl = ""
local _clipboardVersion = 0

-- ── state shapes (`noctalia.state` keys: settings / media_info / active_job / queue /
--    extracting / error_message / clipboard) ──────────────────────────────────────

local state = {
  extracting = false,
  mediaInfo = nil,
  errorMessage = "",
  active = {
    status = "idle",
    title = "",
    progress = { percent = 0, percentText = "", size = "", speed = "", eta = "" },
    error = "",
    outputPath = "",
    outputDir = "",
    log = "",
    job = nil,
  },
  queue = {},
  clipboard = { text = "", forced = false },
}

local function publishSettings() noctalia.state.set("settings", _settings) end
local function publishMediaInfo() noctalia.state.set("media_info", state.mediaInfo) end
local function publishActive() noctalia.state.set("active_job", state.active) end
local function publishQueue() noctalia.state.set("queue", state.queue) end
local function publishExtracting() noctalia.state.set("extracting", state.extracting) end
local function publishError() noctalia.state.set("error_message", state.errorMessage) end
local function publishClipboard() noctalia.state.set("clipboard", state.clipboard) end

local function publishAll()
  publishSettings()
  publishMediaInfo()
  publishActive()
  publishQueue()
  publishExtracting()
  publishError()
  publishClipboard()
end

-- ── settings (persisted JSON, edited from the panel — declared settings cannot be
--    written from a plugin, so downloads/panel state that otoru kept settings for
--    live here instead) ───────────────────────────────────────────────────────────

function M.defaultSettings()
  local home = noctalia.getenv("HOME") or ""
  return {
    downloadDir = home .. "/Downloads/Videos/yt-dlp",
    downloadMode = "video",
    quality = "best",
    videoFormat = "auto",
    audioQuality = "best",
    audioFormat = "best",
    audioLanguage = "",
    autoClipboard = true,
    autoExtractClipboard = true,
    clearInputAfterDownload = true,
    advancedVisible = false,
    outputTemplate = "%(title)s.%(ext)s",
    cookies = "",
    cookiesFromBrowser = "",
    cookiesProfile = "",
    proxy = "",
    rateLimit = "",
    concurrentFragments = "",
    customFormatSelector = "",
    customArgs = "",
    downloadThumbnail = false,
    embedThumbnail = false,
    embedMetadata = true,
    embedSubs = false,
    includeAutoSubs = false,
    preferDrc = false,
    sponsorBlock = false,
    sponsorBlockCategories = { "sponsor", "selfpromo", "interaction" },
    useArchive = false,
    saveHistory = true,
    history = {},
    subLanguage = "off",
    postDownloadAction = "nothing",
  }
end

function M.loadSettings()
  _settings = M.defaultSettings()
  if SETTINGS_PATH ~= "" then
    local raw = noctalia.readFile(SETTINGS_PATH)
    if raw then
      local ok, parsed = pcall(noctalia.json.decode, raw)
      if ok and type(parsed) == "table" then
        for key, fallback in pairs(M.defaultSettings()) do
          if parsed[key] ~= nil then
            _settings[key] = parsed[key]
          end
        end
      end
    end
  end
  return _settings
end

function M.saveSettings()
  if SETTINGS_PATH == "" then return end
  local ok, encoded = pcall(noctalia.json.encode, _settings)
  if ok then noctalia.writeFile(SETTINGS_PATH, encoded) end
end

function M.setSetting(key, value)
  if key == nil or M.defaultSettings()[key] == nil then return end
  _settings[key] = value
  M.saveSettings()
  publishSettings()
end

function M.resetSettings()
  _settings = M.defaultSettings()
  M.saveSettings()
  publishSettings()
end

-- ── pure helpers (port of OtoruModel.js; kept on `M` for the standalone tests) ────

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function expandHome(path)
  local value = tostring(path or "")
  if value:sub(1, 1) == "~" then
    return (noctalia.getenv("HOME") or "") .. value:sub(2)
  end
  return value
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- api ≤ 23 runAsync/runStream only accept a shell string, so argv arrays are
-- joined back into one safely-quoted command line.
local function shellJoin(argv)
  local out = {}
  for i, arg in ipairs(argv) do
    out[i] = shellQuote(arg)
  end
  return table.concat(out, " ")
end

local function isWebUrl(value)
  return tostring(value or ""):match("^https?://") ~= nil
end

-- Trailing prose debris off a pasted URL: punctuation, quotes, closing brackets.
-- No digits — a query string must survive intact.
local JUNK_TAIL = "[.,;:!?%)%]}\"'%s]*$"

local function stripUrlJunk(value)
  return tostring(value or ""):gsub(JUNK_TAIL, "")
end

-- Normalize whatever the user pastes into a usable URL, or "" if it can't be one:
local function stripYtListParams(url)
  if not url:match("^https?://[^/]*youtube%.com/watch") then return url end
  local base, query = url:match("^(.-%?)(.*)$")
  if not base then return url end
  local kept = {}
  for param in query:gmatch("([^&]+)") do
    local key = param:match("^([^=]+)")
    if key and key ~= "list" and key ~= "index" and key ~= "start_radio" and key ~= "pp" then
      kept[#kept + 1] = param
    end
  end
  return base .. table.concat(kept, "&")
end

-- trim, take the first http(s) URL (even inside prose), strip trailing junk and
-- auto-prefix https:// for bare hosts (youtube.com/...).
function M.cleanUrlText(text)
  local t = trim(text)
  if t == "" then return "" end
  if t:match("^ytsearch") then return stripUrlJunk(t) end
  local startPos, endPos = t:find("https?://%S+")
  if startPos then
    return stripYtListParams(stripUrlJunk(t:sub(startPos, endPos)))
  end
  if not t:find("%s") and t:match("%.") then
    return stripYtListParams("https://" .. stripUrlJunk(t))
  end
  return ""
end

function M.looksLikeUrl(text) return M.cleanUrlText(text) ~= "" end

-- Non-empty text that isn't a URL and isn't an explicit ytsearch: prefix — the
-- candidate for "search YouTube for this".
function M.isSearchQuery(text)
  local t = trim(text)
  return t ~= "" and M.cleanUrlText(t) == "" and not t:match("^ytsearch")
end

local function cookiesFromBrowserArg(settings)
  local browser = trim(settings.cookiesFromBrowser):lower()
  if browser == "" then return nil end
  local profile = trim(settings.cookiesProfile)
  if profile ~= "" then return browser .. ":" .. profile end
  return browser
end

local VIDEO_QUALITIES = { 2160, 1440, 1080, 720, 480, 360, 240 }

function M.availableVideoQualities(maxHeight)
  local out = {}
  for _, quality in ipairs(VIDEO_QUALITIES) do
    if maxHeight >= quality then
      out[#out + 1] = tostring(quality)
    end
  end
  return out
end

-- Flat playlist extraction carries no formats, so the real max height is unknown —
-- offer every rung and let yt-dlp cap each entry on its own.
function M.allVideoQualities()
  local out = {}
  for _, quality in ipairs(VIDEO_QUALITIES) do
    out[#out + 1] = tostring(quality)
  end
  return out
end

local function parseVideoInfo(info)
  local formats = type(info.formats) == "table" and info.formats or {}
  local heights = {}
  local maxHeight = 0
  local hasAudio = false
  local audioLanguages = {}
  for _, audioLang in ipairs(audioLanguages) do end

  for _, f in ipairs(formats) do
    if type(f) == "table" then
      local h = tonumber(f.height)
      if h and h > 0 then
        heights[#heights + 1] = h
        if h > maxHeight then maxHeight = h end
      end
      local acodec = tostring(f.acodec or "")
      if acodec ~= "" and acodec:lower() ~= "none" then
        hasAudio = true
        local language = tostring(f.language or "")
        if language ~= "" then
          local lang = language:lower():match("^([^%-_]+)")
          if lang then
            local seen = false
            for _, existing in ipairs(audioLanguages) do
              if existing == lang then seen = true break end
            end
            if not seen then audioLanguages[#audioLanguages + 1] = lang end
          end
        end
      end
    end
  end

  local hasSubs = false
  local hasAutoSubs = false
  local subLanguages = {}
  if type(info.subtitles) == "table" and next(info.subtitles) then hasSubs = true end
  if type(info.automatic_captions) == "table" and next(info.automatic_captions) then hasAutoSubs = true end
  for _, subtitles in ipairs({ info.subtitles, info.automatic_captions }) do
    if type(subtitles) == "table" then
      for code in pairs(subtitles) do
        local normalized = code:lower()
        local seen = false
        for _, existing in ipairs(subLanguages) do
          if existing == normalized then seen = true break end
        end
        if not seen then subLanguages[#subLanguages + 1] = normalized end
      end
    end
  end
  table.sort(subLanguages)

  -- Non-webp thumbnail preferred (the panel's image renderer has no webp decoder);
  -- rewrite YouTube's vi_webp/*.webp to their jpg equivalents when webp is all we get.
  local thumbs = type(info.thumbnails) == "table" and info.thumbnails or {}
  local thumbnail = ""
  for _, th in ipairs(thumbs) do
    if type(th) == "table" then
      local url = tostring(th.url or "")
      if url ~= "" and not url:match("%.webp") then
        thumbnail = url
        break
      end
    end
  end
  if thumbnail == "" then thumbnail = tostring(info.thumbnail or "") end
  local webpCandidate = ""
  if thumbnail == "" then
    for _, th in ipairs(thumbs) do
      if type(th) == "table" then
        local url = tostring(th.url or "")
        if url ~= "" then
          thumbnail = url
          webpCandidate = url
          break
        end
      end
    end
  end
  if thumbnail:match("%.webp") or webpCandidate:match("%.webp") then
    thumbnail = thumbnail:gsub("/vi_webp/", "/vi/"):gsub("%.webp$", ".jpg")
  end

  return {
    title = tostring(info.title or "Unknown title"),
    thumbnail = thumbnail,
    thumbnailPath = nil,
    duration = tonumber(info.duration) or 0,
    uploader = tostring(info.uploader or info.channel or info.artist or ""),
    formats = formats,
    hasAudio = hasAudio,
    maxHeight = maxHeight,
    extractor = tostring(info.extractor or ""),
    audioLanguages = audioLanguages,
    hasSubs = hasSubs,
    hasAutoSubs = hasAutoSubs,
    subLanguages = subLanguages,
    webpage_url = tostring(info.webpage_url or ""),
    isPlaylist = false,
    count = nil,
  }
end

-- Decode-free split so the standalone tests can feed plain tables.
function M.parseInfoDecoded(info)
  if type(info) ~= "table" then return nil end

  if info._type == "playlist" or type(info.entries) == "table" then
    local entries = info.entries or {}
    -- A single fully-extracted result (ytsearch1) is unwrapped to its video card.
    if #entries == 1 and type(entries[1]) == "table"
        and type(entries[1].formats) == "table" and #entries[1].formats > 0 then
      return parseVideoInfo(entries[1])
    end
    return {
      isPlaylist = true,
      title = tostring(info.title or "Playlist"),
      thumbnail = "",
      thumbnailPath = nil,
      duration = 0,
      uploader = tostring(info.uploader or info.channel or ""),
      formats = {},
      hasAudio = true,
      maxHeight = 0,
      extractor = tostring(info.extractor or ""),
      audioLanguages = {},
      hasSubs = false,
      hasAutoSubs = false,
      subLanguages = {},
      count = tonumber(info.playlist_count) or #entries,
      webpage_url = tostring(info.webpage_url or ""),
    }
  end

  return parseVideoInfo(info)
end

function M.parseInfo(raw)
  local ok, info = pcall(noctalia.json.decode, tostring(raw or "{}"))
  if not ok then return nil end
  return M.parseInfoDecoded(info)
end

function M.progressTemplate()
  return "progress:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress._downloaded_bytes_str)s|%(progress._total_bytes_str)s|%(progress._total_bytes_estimate_str)s|%(playlist_index)s|%(n_entries)s"
end

local function stripAnsi(value)
  return tostring(value or ""):gsub("\27%[[0-9;]*m", "")
end

function M.parseProgressLine(line)
  local s = stripAnsi(line)
  if s:sub(1, #STAT_PREFIX) ~= STAT_PREFIX then return nil end
  -- Decode-free split that keeps empty fields, so fields stay aligned with the
  -- upstream progress-template slots even when a value is missing.
  local function splitFields(text, separator)
    local out = {}
    local pos = 1
    while pos <= #text do
      local startPos, endPos = text:find(separator, pos, true)
      if not startPos then
        out[#out + 1] = text:sub(pos)
        break
      end
      out[#out + 1] = text:sub(pos, startPos - 1)
      pos = endPos + 1
    end
    if #text == 0 then out[#out + 1] = "" end
    return out
  end

  local parts = splitFields(s:sub(#STAT_PREFIX + 1), "|")
  local function field(i)
    local v = trim(parts[i])
    if v == "" or v == "NA" or v:find("Unknown", 1, true) then return "" end
    return v
  end

  local percentText = field(1)
  local percent = 0
  local parsed = tonumber((percentText:gsub("%%", "")))
  if parsed then percent = math.max(0, math.min(100, parsed)) end

  local downloaded = field(4)
  local total = field(5)
  if total == "" then total = field(6) end
  local idx = field(7)
  local count = field(8)
  local itemPrefix = ""
  if idx ~= "" and count ~= "" then itemPrefix = "[" .. idx .. "/" .. count .. "] " end

  local sizeText = itemPrefix
  if downloaded ~= "" and total ~= "" then
    sizeText = sizeText .. downloaded .. " / " .. total
  elseif downloaded ~= "" then
    sizeText = sizeText .. downloaded
  end

  return {
    percent = percent,
    percentText = percentText,
    speed = field(2),
    eta = field(3),
    downloaded = downloaded,
    total = total,
    sizeText = sizeText,
  }
end

local function containsAny(needles, haystack)
  for _, needle in ipairs(needles) do
    if haystack:find(needle, 1, true) then return true end
  end
  return false
end

function M.friendlyError(stderr, exitCode)
  local s = tostring(stderr or "")
  local low = s:lower()
  local first = s:match("([^\n]*)") or ""

  if exitCode == 127 or containsAny({ "command not found", "yt-dlp: not found" }, low) then
    return "yt-dlp is not installed or not on PATH."
  end
  if low:find("ffmpeg", 1, true) then
    return "ffmpeg is required for this download. Please install ffmpeg."
  end
  if s:find("Unsupported URL", 1, true) then
    return "Unsupported website or URL."
  end
  if containsAny({ "sign in", "login", "authentication", "auth required", "authenticate" }, low) then
    return "Authentication required."
  end
  if containsAny({ "private", "removed", "unavailable", "not available", "blocked", "copyright", "age restricted" }, low) then
    return "Media unavailable."
  end
  if containsAny({ "requested format", "format not available" }, low) then
    return "Selected format unavailable."
  end
  if containsAny({ "403", "forbidden", "access denied" }, low) then
    return "Access denied (HTTP 403). Try updating yt-dlp, using cookies, or retry as web client."
  end
  if containsAny({ "not available in your country", "geo", "this content is not available" }, low) then
    return "Geo-blocked in your region."
  end
  if containsAny({ "certificate verify failed", "ssl" }, low) then
    return "SSL/TLS certificate error."
  end
  if containsAny({ "http error", "timed out", "temporary failure", "network", "could not send", "connection" }, low) then
    return "Network error."
  end
  return "Download failed: " .. (s ~= "" and first or "")
end

function M.capLog(text)
  local value = tostring(text or "")
  if #value > MAX_LOG then return value:sub(#value - MAX_LOG + 1) end
  return value
end

local function saveLastError(text)
  if ERROR_LOG_PATH == "" or type(noctalia.writeFile) ~= "function" then return end
  pcall(noctalia.writeFile, ERROR_LOG_PATH, tostring(text or ""))
end

function M.guessOutputPath(settings, job)
  local dir = expandHome(settings.downloadDir)
  local title = tostring(job.title or ""):gsub("[/\\?%%*:|%\"<>]", "_")
  if title == "" then title = "download" end
  local ext = ".%(ext)s"
  if job.mode == "audio" then
    local audioFormat = tostring(job.audioFormat or settings.audioFormat or "best")
    if audioFormat ~= "best" then ext = "." .. audioFormat end
  end
  return dir .. "/" .. title .. ext
end

local function splitCustomArgs(argString)
  local tokens = {}
  for token in trim(argString):gmatch("%S+") do
    tokens[#tokens + 1] = token
  end
  return tokens
end

-- ── yt-dlp command builders (argv form — no shell interpolation of user input) ────

function M.infoCommand(url, useWebClient, settings)
  local args = {
    "yt-dlp", "--no-warnings", "--dump-single-json", "--skip-download",
  }
  -- Search queries need real (non-flat) extraction to return the resolved video
  -- instead of a playlist stub; single-video URLs need full info (formats,
  -- subtitles, audio languages). Only true playlists stay flat to keep the
  -- extraction JSON small.
  local targetUrl = tostring(url)
  local isPlaylist = targetUrl:match("playlist%.") ~= nil or targetUrl:match("list=") ~= nil
  if not targetUrl:match("^ytsearch") and isPlaylist then
    args[#args + 1] = "--flat-playlist"
  end
  if useWebClient then
    args[#args + 1] = "--extractor-args"
    args[#args + 1] = "youtube:player_client=web"
  end
  local proxy = trim(settings.proxy)
  if proxy ~= "" then
    args[#args + 1] = "--proxy"
    args[#args + 1] = proxy
  end
  local browserCookies = cookiesFromBrowserArg(settings)
  if browserCookies then
    args[#args + 1] = "--cookies-from-browser"
    args[#args + 1] = browserCookies
  else
    local cookies = trim(settings.cookies)
    if cookies ~= "" then
      args[#args + 1] = "--cookies"
      args[#args + 1] = expandHome(cookies)
    end
  end
  args[#args + 1] = tostring(url)
  -- Cap the producer-side output at 16MB so even a huge auto-mix playlist JSON fits
  -- (a radio mix can exceed 1MiB on its own). "$@" passes each arg as a separate
  -- parameter and pipefail keeps yt-dlp's exit status through head.
  local wrapped = { "bash", "-c", "set -o pipefail; exec \"$@\" | head -c 16777216", "ytdlp-info" }
  for _, arg in ipairs(args) do
    wrapped[#wrapped + 1] = arg
  end
  return wrapped
end

function M.buildDownloadArgs(job, settings, useWebClient)
  local args = {
    "yt-dlp", "--newline", "--no-warnings", "--no-colors", "--progress",
    "--progress-delta", "0.3",
    "--progress-template", M.progressTemplate(),
    "--print", "after_move:filepath",
  }
  if useWebClient then
    args[#args + 1] = "--extractor-args"
    args[#args + 1] = "youtube:player_client=web"
  end

  local outDir = expandHome(settings.downloadDir)
  args[#args + 1] = "-P"
  args[#args + 1] = outDir

  local outputTemplate = trim(settings.outputTemplate)
  if outputTemplate ~= "" then
    args[#args + 1] = "-o"
    args[#args + 1] = outputTemplate
  end
  local proxy = trim(settings.proxy)
  if proxy ~= "" then
    args[#args + 1] = "--proxy"
    args[#args + 1] = proxy
  end
  local browserCookies = cookiesFromBrowserArg(settings)
  if browserCookies then
    args[#args + 1] = "--cookies-from-browser"
    args[#args + 1] = browserCookies
  else
    local cookies = trim(settings.cookies)
    if cookies ~= "" then
      args[#args + 1] = "--cookies"
      args[#args + 1] = expandHome(cookies)
    end
  end
  local rateLimit = trim(settings.rateLimit)
  if rateLimit ~= "" then
    args[#args + 1] = "--limit-rate"
    args[#args + 1] = rateLimit
  end
  local concurrentFragments = trim(settings.concurrentFragments)
  if concurrentFragments ~= "" then
    args[#args + 1] = "--concurrent-fragments"
    args[#args + 1] = concurrentFragments
  end
  local customArgs = trim(settings.customArgs)
  if customArgs ~= "" then
    for _, token in ipairs(splitCustomArgs(customArgs)) do
      args[#args + 1] = token
    end
  end
  if settings.sponsorBlock == true then
    local categories = type(settings.sponsorBlockCategories) == "table" and settings.sponsorBlockCategories or {}
    local joined = table.concat(categories, ",")
    if joined ~= "" then
      args[#args + 1] = "--sponsorblock-remove"
      args[#args + 1] = joined
    end
  end
  if settings.useArchive == true then
    args[#args + 1] = "--download-archive"
    args[#args + 1] = outDir .. "/.ytdlp-archive.txt"
  end
  if settings.downloadThumbnail == true then
    args[#args + 1] = "--write-thumbnail"
    args[#args + 1] = "--convert-thumbnails"
    args[#args + 1] = "jpg"
  end
  if settings.embedThumbnail == true then
    args[#args + 1] = "--embed-thumbnail"
  end
  if settings.embedMetadata ~= false then
    args[#args + 1] = "--embed-metadata"
  end
  local subLanguage = trim(settings.subLanguage)
  if subLanguage ~= "" and subLanguage ~= "off" and not _forceNoSubs then
    local embedSubs = settings.embedSubs == true and (job.mode or "video") ~= "audio"
    args[#args + 1] = "--sub-langs"
    args[#args + 1] = subLanguage
    args[#args + 1] = "--write-subs"
    if embedSubs then
      args[#args + 1] = "--embed-subs"
    end
    -- A specific language may only exist as YouTube auto captions (manual subs
    -- are often missing), and jobs coming from the panel have no info dict, so
    -- pull auto captions whenever the user picked one language + embedding.
    local explicitAuto = settings.includeAutoSubs == true
      or (subLanguage ~= "all" and settings.embedSubs == true)
      or (embedSubs
        and type(job.info) == "table"
        and job.info.hasSubs == false
        and job.info.hasAutoSubs == true)
    if explicitAuto then
      args[#args + 1] = "--write-auto-subs"
    end
  end

  local preferDrc = settings.preferDrc == true
  local mode = job.mode or "best"
  if mode == "audio" then
    args[#args + 1] = "-x"
    local audioFormat = tostring(job.audioFormat or settings.audioFormat or "best")
    if audioFormat ~= "" and audioFormat ~= "best" then
      args[#args + 1] = "--audio-format"
      args[#args + 1] = audioFormat
    end
    local audioQuality = tostring(job.audioQuality or settings.audioQuality or "best")
    if audioQuality ~= "" and audioQuality ~= "best" and not audioQuality:match("%D$") then
      args[#args + 1] = "--audio-quality"
      args[#args + 1] = audioQuality .. "K"
    end
    local language = tostring(job.audioLanguage or "")
    if preferDrc or language ~= "" then
      local base = "bestaudio"
      if language ~= "" then base = base .. "[language=" .. language .. "]" end
      local selector = base
      if preferDrc then selector = base .. "[format_id$='-drc']/" .. base end
      args[#args + 1] = "-f"
      args[#args + 1] = selector .. "/bestaudio"
    end
  elseif mode == "custom" then
    local selector = trim(settings.customFormatSelector)
    if selector ~= "" then
      args[#args + 1] = "-f"
      args[#args + 1] = selector
    end
  elseif mode == "video" then
    local quality = tostring(job.quality or "best")
    local language = tostring(job.audioLanguage or "")
    local audioPart = "bestaudio"
    if language ~= "" then audioPart = "bestaudio[language=" .. language .. "]" end
    if quality ~= "best" then
      local base = "bestvideo[height<=" .. quality .. "]+" .. audioPart
      local selector = base
      if preferDrc then selector = selector .. "[format_id$='-drc']/" .. base end
      selector = selector .. "/best[height<=" .. quality .. "]"
      args[#args + 1] = "-f"
      args[#args + 1] = selector
    elseif preferDrc or language ~= "" then
      local selector = "bestvideo*+" .. audioPart
      if preferDrc then selector = "bestvideo*+bestaudio[format_id$='-drc']/" .. selector end
      args[#args + 1] = "-f"
      args[#args + 1] = selector .. "/bestvideo*+bestaudio/best"
    end
  end

  if mode ~= "audio" then
    local videoFormat = trim(settings.videoFormat or "")
    if videoFormat ~= "" and videoFormat ~= "auto" then
      args[#args + 1] = "--merge-output-format"
      args[#args + 1] = videoFormat
    end
  end

  args[#args + 1] = tostring(job.url)
  return args
end

-- ── thumbnail cache ──────────────────────────────────────────────────────────────

local function simpleHash(value)
  local h = 5381
  for i = 1, #value do
    h = (h * 33 + value:byte(i)) % 4294967296
  end
  return string.format("%d", h)
end

function M.fetchThumbnail(info)
  if not isWebUrl(info.thumbnail) then return end
  noctalia.mkdirAll(THUMBS_DIR)
  local ext = info.thumbnail:match("%.([%w]+)[%?]") or info.thumbnail:match("%.([%w]+)$") or "jpg"
  local path = THUMBS_DIR .. "/" .. simpleHash(tostring(info.webpage_url or info.thumbnail)) .. "." .. ext
  if noctalia.fileExists(path) then
    info.thumbnailPath = path
    publishMediaInfo()
    return
  end
  noctalia.download(info.thumbnail, path, function(ok)
    if ok and state.mediaInfo and state.mediaInfo.webpage_url == info.webpage_url then
      info.thumbnailPath = path
      publishMediaInfo()
    end
  end)
end

-- ── extraction ───────────────────────────────────────────────────────────────────

function M.extractTarget(raw)
  local cleaned = M.cleanUrlText(raw)
  if cleaned ~= "" then return cleaned end
  if M.isSearchQuery(raw) then return "ytsearch1:" .. trim(raw) end
  return ""
end

function M.startExtraction(raw)
  local target = M.extractTarget(raw)
  if target == "" then
    state.errorMessage = "Enter a URL or search query."
    publishError()
    return
  end
  _lastRawInput = tostring(raw or "")
  _lastExtractedUrl = target
  _extractRetried = false
  state.mediaInfo = nil
  publishMediaInfo()
  state.errorMessage = ""
  publishError()
  state.extracting = true
  publishExtracting()

  _extractGeneration = _extractGeneration + 1
  local generation = _extractGeneration
  local args = M.infoCommand(target, _sessionWebClient, _settings)
  noctalia.runAsync(shellJoin(args), function(result)
    if generation ~= _extractGeneration then return end
    state.extracting = false
    publishExtracting()
    if result.exitCode == 0 then
      M.handleInfo(tostring(result.stdout or ""))
    else
      local errorText = M.friendlyError(tostring(result.stderr or ""), result.exitCode)
      local rawLow = (tostring(result.stderr or "") .. "\n" .. tostring(result.stdout or "")):lower()
      saveLastError("EXTRACT exit=" .. tostring(result.exitCode) .. "\n" .. tostring(result.stderr or ""))
      -- YouTube rate-limits requests (429) even the info dump. Retry
      -- the same extraction once before surfacing the error.
      if not _extractRetried and containsAny({ "429", "too many requests", "rate limited", "timedtext", "unable to download", "bot" }, rawLow) then
        _extractRetried = true
        state.extracting = true
        publishExtracting()
        _extractGeneration = _extractGeneration + 1
        local retryGen = _extractGeneration
        local retryArgs = M.infoCommand(target, _sessionWebClient, _settings)
        noctalia.runAsync(shellJoin(retryArgs), function(r2)
          if retryGen ~= _extractGeneration then return end
          state.extracting = false
          publishExtracting()
          if r2.exitCode == 0 then
            M.handleInfo(tostring(r2.stdout or ""))
          else
            local retryError = M.friendlyError(tostring(r2.stderr or ""), r2.exitCode)
            saveLastError("EXTRACT(retry) exit=" .. tostring(r2.exitCode) .. "\n" .. tostring(r2.stderr or ""))
            state.errorMessage = retryError
            publishError()
            if state.active.status ~= "downloading" and state.active.status ~= "preparing"
                and containsAny({ "403", "forbidden", "access denied", "sign in", "authentication",
                  "auth required", "authenticate", "unable to download", "blocked", "geo", "bot" },
                  retryError:lower()) then
              state.active.status = "error"
              state.active.error = retryError
              publishActive()
            end
          end
        end)
        return
      end
      state.errorMessage = errorText
      publishError()
      if state.active.status ~= "downloading" and state.active.status ~= "preparing"
          and containsAny({ "403", "forbidden", "access denied", "sign in", "authentication",
            "auth required", "authenticate", "unable to download", "blocked", "geo", "bot" },
            errorText:lower()) then
        state.active.status = "error"
        state.active.error = errorText
        publishActive()
      end
    end
  end)
end

function M.handleInfo(raw)
  local info = M.parseInfo(raw)
  if not info then
    state.errorMessage = "Could not parse media information."
    publishError()
    return
  end
  info.isPlaylist = info.isPlaylist == true
  info.extractedUrl = _lastExtractedUrl
  info.availableQualities = info.isPlaylist
    and M.allVideoQualities()
    or M.availableVideoQualities(info.maxHeight)
  state.mediaInfo = info
  publishMediaInfo()
  if info.thumbnail ~= "" and info.webpage_url ~= "" then
    M.fetchThumbnail(info)
  end
end

-- ── download engine ──────────────────────────────────────────────────────────────

local function clearActivePid()
  if PID_PATH ~= "" then noctalia.removeFile(PID_PATH) end
end

local function retrievePid()
  if PID_PATH == "" then return nil end
  local raw = noctalia.readFile(PID_PATH)
  if not raw then return nil end
  local pid = trim(raw)
  if pid == "" then return nil end
  return pid
end

local function buildRunCommand(args)
  local script = 'echo $$ > "$0"; trap "kill $CHILD 2>/dev/null" INT TERM; env PYTHONUNBUFFERED=1 "$@" 2>&1 & CHILD=$!; wait $CHILD; echo '
    .. EXIT_SENTINEL .. '$?'
  local pieces = { "sh", "-c", script, PID_PATH }
  for _, arg in ipairs(args) do
    pieces[#pieces + 1] = arg
  end
  local command = ""
  for i, piece in ipairs(pieces) do
    if i > 1 then command = command .. " " end
    command = command .. shellQuote(piece)
  end
  return command
end

local function setActive(patch)
  for key, value in pairs(patch) do
    state.active[key] = value
  end
  publishActive()
end

function M.killActive()
  local pid = retrievePid()
  if pid then
    noctalia.runAsync(shellJoin({ "kill", "-TERM", pid }), function() end)
  end
  clearActivePid()
end

function M.startDownload(job)
  if type(job) ~= "table" then return false end
  local url = trim(job.url)
  if url == "" then
    state.errorMessage = "Enter a URL first."
    publishError()
    return false
  end
  if state.active.status == "downloading" or state.active.status == "preparing" or state.active.status == "paused" then
    M.enqueue(job)
    return true
  end

  _pauseRequested = false
  _cancelPending = false
  _forceNoSubs = false
  state.active = {
    status = "preparing",
    job = job,
    title = tostring(job.title or "Downloading"),
    progress = { percent = 0, percentText = "", size = "", speed = "", eta = "" },
    error = "",
    outputPath = "",
    outputDir = expandHome(_settings.downloadDir),
    log = "",
  }
  publishActive()

  local dir = trim(_settings.downloadDir)
  if dir == "" then dir = noctalia.getenv("HOME") or "/tmp" end
  noctalia.runAsync(shellJoin({ "mkdir", "-p", expandHome(dir) }), function(result)
    if result.exitCode ~= 0 then
      setActive({
        status = "error",
        error = "Could not create download directory.",
      })
      if not _panelOpen then
        noctalia.notifyError("YT-DLP", "Could not create download directory.")
      end
      return
    end
    M.beginDownload()
  end)
end

function M.beginDownload()
  local active = state.active
  if not active.job then return end
  local args = M.buildDownloadArgs(active.job, _settings, _sessionWebClient)
  local command = buildRunCommand(args)
  setActive({ status = "downloading" })
  noctalia.runStream(command, function(line)
    M.onDownloadLine(tostring(line or ""))
  end)
end

function M.onDownloadLine(line)
  local trimmed = trim(line)
  if trimmed == "" then return end

  -- yt-dlp --print after_move:filepath → the real output path.
  if trimmed:sub(1, 1) == "/" then
    setActive({ outputPath = trimmed })
    return
  end

  local sentinelAt = trimmed:find(EXIT_SENTINEL, 1, true)
  if sentinelAt then
    local code = tonumber(trimmed:sub(sentinelAt + #EXIT_SENTINEL))
    M.handleDownloadFinished(code)
    return
  end

  local parsed = M.parseProgressLine(trimmed)
  if parsed then
    setActive({ progress = parsed })
  else
    setActive({ log = M.capLog(state.active.log .. trimmed .. "\n") })
  end
end

function M.handleDownloadFinished(exitCode)
  local active = state.active
  if not active.job then return end
  local code = tonumber(exitCode) or 0
  local job = active.job

  if _pauseRequested then
    _pauseRequested = false
    _cancelPending = false
    setActive({ status = "paused", error = "" })
    return
  end

  if code ~= 0 then
    if _cancelPending then
      _cancelPending = false
      setActive({ status = "cancelled", error = "" })
    else
      local errorText = M.friendlyError(active.log or "", code)
      saveLastError("DOWNLOAD exit=" .. tostring(code) .. "\n" .. tostring(active.log or ""))
      -- Subtitle/caption fetches hit YouTube rate limits (429/timedtext) and
      -- silently kill the whole download. Retry once without subtitle flags so
      -- the media still lands. Match the RAW log: friendlyError rewrites 429
      -- into 'Network error.', losing the trigger words.
      local rawLow = (active.log or ""):lower()
      local subsActive = trim(_settings.subLanguage or "") ~= ""
        and trim(_settings.subLanguage or "") ~= "off"
      if subsActive and not _forceNoSubs
          and containsAny({ "subtitle", "caption", "timedtext", "429", "too many requests", "error embedding" }, rawLow) then
        _forceNoSubs = true
        setActive({ status = "preparing", error = "", log = "Subtitle fetch failed; retrying without subtitles.\n" })
        publishActive()
        M.beginDownload()
        return
      end
      setActive({ status = "error", error = errorText })
      if not _panelOpen then noctalia.notifyError("YT-DLP", errorText) end
    end
    state.active.job = nil
    publishActive()
    M.processQueue()
    return
  end

  local outputPath = active.outputPath
  if outputPath == "" then outputPath = M.guessOutputPath(_settings, job) end
  setActive({
    status = "completed",
    outputPath = outputPath,
    outputDir = expandHome(_settings.downloadDir),
    progress = { percent = 100, percentText = "100%", size = "", speed = "", eta = "" },
  })
  M.rememberUrl(job.url)

  local action = _settings.postDownloadAction or "nothing"
  if action == "copy" and outputPath ~= "" then
    noctalia.copyToClipboard(outputPath, "text/plain")
  elseif action == "open" then
    noctalia.runAsync(shellJoin({ "xdg-open", state.active.outputDir }), function() end)
  elseif action == "openFile" and outputPath ~= "" then
    noctalia.runAsync(shellJoin({ "xdg-open", outputPath }), function() end)
  end

  if not _panelOpen then
    noctalia.notify("YT-DLP", "Download complete — " .. tostring(job.title or job.url or ""))
  end

  state.active.job = nil
  publishActive()
  M.processQueue()
end

function M.pauseActive()
  if state.active.status ~= "downloading" then return end
  _pauseRequested = true
  M.killActive()
end

function M.cancelActive()
  if state.active.status ~= "downloading" then return end
  _cancelPending = true
  M.killActive()
end

function M.resumeActive()
  if state.active.status ~= "paused" then return end
  local job = state.active.job
  state.active = {
    status = "idle",
    title = "",
    progress = { percent = 0, percentText = "", size = "", speed = "", eta = "" },
    error = "",
    outputPath = "",
    outputDir = "",
    log = "",
    job = nil,
  }
  publishActive()
  M.startDownload(job)
end

function M.clearActive()
  if state.active.status == "downloading" or state.active.status == "preparing" or state.active.status == "paused" then
    return
  end
  state.active = {
    status = "idle",
    title = "",
    progress = { percent = 0, percentText = "", size = "", speed = "", eta = "" },
    error = "",
    outputPath = "",
    outputDir = "",
    log = "",
    job = nil,
  }
  publishActive()
end

function M.retryWebClient(job, url)
  _sessionWebClient = true
  state.errorMessage = ""
  publishError()
  if state.mediaInfo and state.mediaInfo.webpage_url ~= "" then
    local target = job
    if type(target) ~= "table" then
      target = {
        url = state.mediaInfo.webpage_url,
        title = state.mediaInfo.title or "",
        mode = "video",
        quality = "best",
        videoFormat = _settings.videoFormat or "auto",
        audioQuality = _settings.audioQuality or "best",
        audioFormat = _settings.audioFormat or "best",
        audioLanguage = "",
      }
    end
    M.startDownload(target)
  elseif url then
    M.startExtraction(url)
  end
end

-- ── queue ────────────────────────────────────────────────────────────────────────

function M.enqueue(job)
  if type(job) ~= "table" then return end
  state.queue[#state.queue + 1] = {
    url = tostring(job.url or ""),
    title = tostring(job.title or ""),
    mode = job.mode or "video",
    quality = tostring(job.quality or "best"),
    audioFormat = tostring(job.audioFormat or _settings.audioFormat or "best"),
    audioQuality = tostring(job.audioQuality or _settings.audioQuality or "best"),
    audioLanguage = tostring(job.audioLanguage or ""),
  }
  publishQueue()
end

function M.removeQueued(index)
  local position = tonumber(index)
  if position and position >= 1 and position <= #state.queue then
    table.remove(state.queue, position)
    publishQueue()
  end
end

function M.processQueue()
  if state.active.status == "downloading"
      or state.active.status == "preparing"
      or state.active.status == "paused" then
    return
  end
  if #state.queue == 0 then return end
  local job = table.remove(state.queue, 1)
  publishQueue()
  M.startDownload(job)
end

-- ── history ──────────────────────────────────────────────────────────────────────

function M.rememberUrl(url)
  local value = trim(url)
  if value == "" then return end
  for _, existing in ipairs(_settings.history or {}) do
    if existing == value then return end
  end
  local history = _settings.history or {}
  history[#history + 1] = value
  if #history > HISTORY_LIMIT then
    local trimmed = {}
    for i = #history - HISTORY_LIMIT + 1, #history do
      trimmed[#trimmed + 1] = history[i]
    end
    history = trimmed
  end
  _settings.history = history
  if _settings.saveHistory ~= false then
    M.saveSettings()
  end
  publishSettings()
end

-- ── clipboard ────────────────────────────────────────────────────────────────────

function M.readClipboard(forced)
  noctalia.runAsync(shellJoin({ "wl-paste", "--no-newline" }), function(result)
    local text = result.exitCode == 0 and tostring(result.stdout or "") or ""
    _clipboardVersion = _clipboardVersion + 1
    state.clipboard = { text = text, forced = forced == true, version = _clipboardVersion }
    publishClipboard()
  end)
end

-- Test hook: the standalone suite needs a clean flow slate between scenarios — the host
-- mock clears its IPC copy but not this module's live tables, which are the ones the
-- engine actually reads.
function M.resetFlow()
  _pauseRequested = false
  _cancelPending = false
  state.mediaInfo = nil
  state.extracting = false
  state.active = {
    status = "idle",
    title = "",
    progress = { percent = 0, percentText = "", size = "", speed = "", eta = "" },
    error = "",
    outputPath = "",
    outputDir = "",
    log = "",
    job = nil,
  }
  state.queue = {}
end

-- ── commands from panel / widget / IPC ──────────────────────────────────────────

function M.handleCommand(command)
  if type(command) ~= "table" then return end
  local nonce = tonumber(command.nonce)
  if nonce then
    if nonce <= _lastHandledNonce then return end
    _lastHandledNonce = nonce
  end
  local action = command.action
  if action == "extract" then
    M.startExtraction(command.url)
  elseif action == "download" then
    M.startDownload(command.job)
  elseif action == "enqueue" then
    M.enqueue(command.job)
  elseif action == "run_queue" then
    M.processQueue()
  elseif action == "cancel" then
    M.cancelActive()
  elseif action == "pause" then
    M.pauseActive()
  elseif action == "resume" then
    M.resumeActive()
  elseif action == "retry" then
    M.retryWebClient(command.job, command.url)
  elseif action == "clear" then
    M.clearActive()
  elseif action == "remove_queued" then
    M.removeQueued(command.index)
  elseif action == "set_setting" then
    M.setSetting(command.key, command.value)
  elseif action == "reset_settings" then
    M.resetSettings()
  elseif action == "read_clipboard" then
    M.readClipboard(command.forced == true)
  elseif action == "panel_open" then
    _panelOpen = command.open == true
  elseif action == "open_folder" then
    local dir = expandHome(_settings.downloadDir)
    noctalia.runAsync(shellJoin({ "xdg-open", dir }), function() end)
  elseif action == "copy_url" then
    local text = tostring(command.text or "")
    if text ~= "" then
      noctalia.runAsync("printf '%s' " .. shellQuote(text) .. " | wl-copy --trim-newline", function() end)
    end
  end
end

-- ── service lifecycle ───────────────────────────────────────────────────────────

function M.init()
  M.loadSettings()
  state.queue = {}
  state.clipboard = { text = "", forced = false }
  state.active = {
    status = "idle",
    title = "",
    progress = { percent = 0, percentText = "", size = "", speed = "", eta = "" },
    error = "",
    outputPath = "",
    outputDir = "",
    log = "",
    job = nil,
  }
  publishAll()
  noctalia.setUpdateInterval(4000)
end

function update()
end

function onConfigChanged()
end

function onIpc(event, payload)
  local command = { action = event }
  if type(payload) == "string" then
    local ok, decoded = pcall(noctalia.json.decode, payload)
    if ok and type(decoded) == "table" then
      command = decoded
      command.action = command.action or event
    end
  end
  M.handleCommand(command)
end

noctalia.state.watch("command", M.handleCommand)

M.init()
return M