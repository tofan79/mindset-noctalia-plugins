--!nonstrict
-- Standalone Luau tests for the YT-DLP service (ports OtoruModel.js + Panel.qml logic).
-- Run: luajit tests/service_test.luau
--
-- The service under test loads ./tests/host_mock.luau itself; sharing the singleton
-- host means the tests can drive its process, stream, and download queues.

local host = dofile("./tests/host_mock.luau")
local noctalia = host.noctalia
local service = dofile("./service.luau")

local tests = {}
local function test(name, fn) table.insert(tests, { name = name, fn = fn }) end

local function assertEqual(got, want, msg)
  if got ~= want then
    error((msg or "assertEqual") .. ": got " .. tostring(got) .. ", want " .. tostring(want), 2)
  end
end

local function assertTrue(value, msg)
  if not value then
    error((msg or "assertTrue") .. ": expected truthy, got " .. tostring(value), 2)
  end
end

local function assertContains(list, value)
  if type(list) == "string" then
    assertTrue(list:find(value, 1, true) ~= nil, "expected '" .. value .. "' in: " .. list)
    return
  end
  for _, entry in ipairs(list) do
    if entry == value then return end
  end
  error("assertContains: " .. tostring(value) .. " missing from args", 2)
end

-- Commands travel through the service's nonce dedupe, so every command in this run
-- must carry a strictly increasing nonce (they are not reset between tests).
local testNonce = 0
local function cmd(action, extra)
  testNonce = testNonce + 1
  local command = { nonce = testNonce, action = action }
  for key, value in pairs(extra or {}) do command[key] = value end
  noctalia.state.set("command", command)
end

-- ── cleanUrlText / extractTarget ──

test("cleanUrlText trims whitespace and trailing junk", function()
  assertEqual(service.cleanUrlText("  https://youtu.be/aBc?si=x123   "), "https://youtu.be/aBc")
  assertEqual(service.cleanUrlText("https://example.com/video.mp4."), "https://example.com/video.mp4")
  assertEqual(service.cleanUrlText("https://example.com/video.mp4),"), "https://example.com/video.mp4")
end)

test("cleanUrlText extracts first URL from prose", function()
  assertEqual(
    service.cleanUrlText("check this out https://www.youtube.com/watch?v=abc123"),
    "https://www.youtube.com/watch?v=abc123")
end)

test("cleanUrlText auto-prefixes bare hosts", function()
  assertEqual(service.cleanUrlText("youtube.com/watch?v=abc"), "https://youtube.com/watch?v=abc")
end)

test("cleanUrlText rejects plain text", function()
  assertEqual(service.cleanUrlText("hello world this is text"), "")
end)

test("cleanUrlText strips session-only params but keeps RD mix playlists", function()
  assertEqual(
    service.cleanUrlText("https://www.youtube.com/watch?v=HIJfaBq7T1k&list=RDHIJfaBq7T1k&start_radio=1&pp=oAcB"),
    "https://www.youtube.com/watch?v=HIJfaBq7T1k&list=RDHIJfaBq7T1k&start_radio=1")
  assertEqual(
    service.cleanUrlText("https://www.youtube.com/watch?v=abc123&list=RDxyz&index=3"),
    "https://www.youtube.com/watch?v=abc123&list=RDxyz")
  assertEqual(
    service.cleanUrlText("https://www.youtube.com/watch?v=abc&si=abc123"),
    "https://www.youtube.com/watch?v=abc")
end)

test("cleanUrlText keeps playlist-only and non-youtube URLs intact", function()
  assertEqual(
    service.cleanUrlText("https://www.youtube.com/playlist?list=PLABC123"),
    "https://www.youtube.com/playlist?list=PLABC123")
  assertEqual(
    service.cleanUrlText("https://example.com/watch?v=abc&list=keepme"),
    "https://example.com/watch?v=abc&list=keepme")
end)

test("cleanUrlText keeps a real list on watch URLs for playlist selection", function()
  assertEqual(
    service.cleanUrlText("https://www.youtube.com/watch?v=abc&list=PLILLJnHxU89&pp=0gcJCf8COCosWNin"),
    "https://www.youtube.com/watch?v=abc&list=PLILLJnHxU89")
end)

test("extractTarget wraps search text in ytsearch", function()
  assertEqual(service.extractTarget("lofi beats"), "ytsearch1:lofi beats")
end)

test("extractTarget keeps urls and explicit ytsearch", function()
  assertEqual(service.extractTarget("https://youtu.be/x"), "https://youtu.be/x")
  assertEqual(service.extractTarget("ytsearch10:lofi"), "ytsearch10:lofi")
end)

-- ── parseInfoDecoded ──

test("parseInfoDecoded unwraps a single-entry search result", function()
  local info = service.parseInfoDecoded({
    _type = "playlist",
    entries = { {
      title = "Resolved",
      webpage_url = "https://youtu.be/x",
      formats = { { height = 720, acodec = "mp4a.40.2", language = "en-US" } },
      thumbnails = { { url = "https://img.example/vi/x/y.jpg" } },
    } },
  })
  assertEqual(info.isPlaylist, false)
  assertEqual(info.title, "Resolved")
  assertEqual(info.maxHeight, 720)
  assertEqual(info.hasAudio, true)
end)

test("parseInfoDecoded builds a playlist card from entries", function()
  local entries = {}
  for i = 1, 10 do entries[i] = { title = "clip " .. i } end
  local info = service.parseInfoDecoded({ _type = "playlist", title = "Mix", entries = entries })
  assertEqual(info.isPlaylist, true)
  assertEqual(info.count, 10)
end)

test("parseInfoDecoded keeps lightweight per-item stubs for a playlist", function()
  local entries = {}
  for i = 1, 10 do
    entries[i] = { id = "v" .. i, title = "clip " .. i, duration = i * 60, url = "https://youtu.be/v" .. i }
  end
  local info = service.parseInfoDecoded({ _type = "playlist", title = "Mix", entries = entries })
  assertEqual(#info.entries, 10)
  assertEqual(info.entries[3].index, 3)
  assertEqual(info.entries[3].id, "v3")
  assertEqual(info.entries[3].url, "https://youtu.be/v3")
  assertEqual(info.entries[4].duration, 240)
end)

test("parseInfoDecoded caps playlist item stubs", function()
  local entries = {}
  for i = 1, 500 do entries[i] = { title = "clip " .. i } end
  local info = service.parseInfoDecoded({ _type = "playlist", title = "Mix", entries = entries })
  assertEqual(#info.entries, 200)
  assertEqual(info.count, 500)
end)

test("parseInfoDecoded rewrites webp thumbnails to jpg", function()
  local info = service.parseInfoDecoded({
    title = "webp only",
    thumbnails = { { url = "https://i.ytimg.com/vi_webp/x/lo.webp" } },
  })
  assertEqual(info.thumbnail, "https://i.ytimg.com/vi/x/lo.jpg")
end)

test("parseInfoDecoded collects audio languages and sub languages", function()
  local info = service.parseInfoDecoded({
    title = "multi",
    formats = {
      { height = 1080, acodec = "mp4a.40.2", language = "en-US" },
      { height = 720, acodec = "mp4a.40.2", language = "es" },
      { height = 480, acodec = "none" },
    },
    subtitles = { en = {}, fr = {} },
    automatic_captions = { en = {} },
  })
  assertEqual(#info.audioLanguages, 2)
  assertEqual(#info.subLanguages, 2)
  assertEqual(info.hasAudio, true)
  assertEqual(info.hasSubs, true)
  assertEqual(info.hasAutoSubs, true)
end)

-- ── progress parsing ──

test("parseProgressLine extracts fields and playlist prefix", function()
  local p = service.parseProgressLine(
    "progress:12.3%| 34.5MiB/s |00:07|15.2MiB|120.4MiB||1|3")
  assertEqual(p.percent, 12.3)
  assertEqual(p.percentText, "12.3%")
  assertEqual(p.speed, "34.5MiB/s")
  assertEqual(p.eta, "00:07")
  assertEqual(p.downloaded, "15.2MiB")
  assertEqual(p.total, "120.4MiB")
  assertEqual(p.sizeText, "[1/3] 15.2MiB / 120.4MiB")
end)

test("parseProgressLine tolerates NA fields", function()
  local p = service.parseProgressLine("progress:0.0%|NA|NA|NA|NA|NA|NA|NA")
  assertEqual(p.percent, 0)
  assertEqual(p.speed, "")
  assertEqual(p.sizeText, "")
end)

test("parseProgressLine rejects ordinary log lines", function()
  assertEqual(service.parseProgressLine("[youtube] Extracting URL: x"), nil)
end)

-- ── command building ──

local function defaultSettings()
  local s = service.defaultSettings()
  s.downloadDir = "/home/test/Downloads"
  return s
end

local function flatten(args) return table.concat(args, " ") end

test("infoCommand: full info for single videos, flat only for playlists, resolves searches", function()
  local plain = service.infoCommand("https://youtu.be/x", false, defaultSettings())
  assertTrue(flatten(plain):find("--flat-playlist", 1, true) == nil)
  local search = service.infoCommand("ytsearch1:lofi", false, defaultSettings())
  assertTrue(flatten(search):find("--flat-playlist", 1, true) == nil)
  local watch = service.infoCommand("https://www.youtube.com/watch?v=abc", false, defaultSettings())
  assertTrue(flatten(watch):find("--flat-playlist", 1, true) == nil)
  local playlist = service.infoCommand("https://www.youtube.com/playlist?list=PLx", false, defaultSettings())
  assertTrue(flatten(playlist):find("--flat-playlist", 1, true) ~= nil)
end)

test("infoCommand carries proxy, browser cookies and web client", function()
  local s = defaultSettings()
  s.proxy = "http://proxy:8080"
  s.cookiesFromBrowser = "firefox"
  s.cookiesProfile = "default-release"
  local args = service.infoCommand("https://youtu.be/x", true, s)
  assertContains(args, "--proxy")
  assertContains(args, "http://proxy:8080")
  assertContains(args, "--cookies-from-browser")
  assertContains(args, "firefox:default-release")
  assertContains(args, "--extractor-args")
  assertContains(args, "youtube:player_client=web")
end)

test("download args: audio mode extracts mp3", function()
  local s = defaultSettings()
  s.audioFormat = "mp3"
  local args = service.buildDownloadArgs({ url = "https://youtu.be/x", mode = "audio" }, s, false)
  local text = flatten(args)
  assertTrue(text:find("-x --audio-format mp3", 1, true) ~= nil, "extract audio")
  assertTrue(text:find("bestaudio", 1, true) == nil, "default best audio need not pin a selector")
end)

test("download args: audio mode with language and DRC", function()
  local s = defaultSettings()
  s.preferDrc = true
  local args = service.buildDownloadArgs({
    url = "https://youtu.be/x",
    mode = "audio",
    audioLanguage = "ja",
  }, s, false)
  local text = flatten(args)
  assertTrue(text:find("bestaudio[language=ja][format_id$='-drc']", 1, true) ~= nil)
  assertTrue(text:find("bestaudio", 1, true) ~= nil)
end)

test("download args: video quality selector", function()
  local args = service.buildDownloadArgs({ url = "https://youtu.be/x", mode = "video", quality = "1080" }, defaultSettings(), false)
  local text = flatten(args)
  assertTrue(text:find("bestvideo[height<=1080]+bestaudio", 1, true) ~= nil)
  assertTrue(text:find("best[height<=1080]", 1, true) ~= nil)
end)

test("download args: custom format selector", function()
  local s = defaultSettings()
  s.customFormatSelector = "bestvideo[ext=webm]+bestaudio"
  local args = service.buildDownloadArgs({ url = "https://youtu.be/x", mode = "custom" }, s, false)
  assertTrue(flatten(args):find("bestvideo[ext=webm]+bestaudio", 1, true) ~= nil)
end)

test("download args: playlist item selection passes --playlist-items", function()
  local args = service.buildDownloadArgs({
    url = "https://www.youtube.com/playlist?list=PLx",
    playlistItems = { 2, 5, 8 },
  }, defaultSettings(), false)
  local text = flatten(args)
  assertTrue(text:find("--playlist-items 2,5,8", 1, true) ~= nil, "selected indices joined")
end)

test("download args: no --playlist-items when nothing selected", function()
  local args = service.buildDownloadArgs({ url = "https://www.youtube.com/playlist?list=PLx" }, defaultSettings(), false)
  assertTrue(flatten(args):find("--playlist-items", 1, true) == nil)
end)

test("download args: video mode honors chosen audio language track", function()
  local s = defaultSettings()
  local args = service.buildDownloadArgs({ url = "https://youtu.be/x", mode = "video", quality = "1080", audioLanguage = "ja" }, s, false)
  assertTrue(flatten(args):find("bestvideo[height<=1080]+bestaudio[language=ja]", 1, true) ~= nil)

  args = service.buildDownloadArgs({ url = "https://youtu.be/x", mode = "video", quality = "best", audioLanguage = "en" }, s, false)
  assertTrue(flatten(args):find("bestvideo*+bestaudio[language=en]", 1, true) ~= nil)
end)

test("download args: video container via merge-output-format", function()
  local s = defaultSettings()
  s.videoFormat = "mp4"
  local args = service.buildDownloadArgs({ url = "https://youtu.be/x", mode = "video", quality = "best" }, s, false)
  local text = flatten(args)
  assertTrue(text:find("--merge-output-format mp4", 1, true) ~= nil)

  s.videoFormat = "mkv"
  args = service.buildDownloadArgs({ url = "https://youtu.be/x", mode = "video", quality = "720" }, s, false)
  assertTrue(flatten(args):find("--merge-output-format mkv", 1, true) ~= nil)

  s.videoFormat = "auto"
  args = service.buildDownloadArgs({ url = "https://youtu.be/x", mode = "video", quality = "best" }, s, false)
  assertTrue(flatten(args):find("--merge-output-format", 1, true) == nil)
end)

test("download args: no container flag in audio mode", function()
  local s = defaultSettings()
  s.videoFormat = "mp4"
  local args = service.buildDownloadArgs({ url = "https://youtu.be/x", mode = "audio", audioFormat = "mp3" }, s, false)
  assertTrue(flatten(args):find("--merge-output-format", 1, true) == nil)
end)

test("download args: audio quality bitrate via --audio-quality", function()
  local s = defaultSettings()
  local args = service.buildDownloadArgs({ url = "https://youtu.be/x", mode = "audio", audioFormat = "mp3", audioQuality = "192" }, s, false)
  assertTrue(flatten(args):find("--audio-quality 192K", 1, true) ~= nil)

  args = service.buildDownloadArgs({ url = "https://youtu.be/x", mode = "audio", audioFormat = "opus", audioQuality = "best" }, s, false)
  assertTrue(flatten(args):find("--audio-quality", 1, true) == nil)
end)

test("download args: sponsorblock, thumbnails, subs, archive, rate limit", function()
  local s = defaultSettings()
  s.sponsorBlock = true
  s.downloadThumbnail = true
  s.embedThumbnail = true
  s.embedSubs = true
  s.subLanguage = "all"
  s.rateLimit = "10M"
  s.useArchive = true
  local args = service.buildDownloadArgs({ url = "https://youtu.be/x", mode = "video", quality = "best" }, s, false)
  local text = flatten(args)
  assertTrue(text:find("--sponsorblock-remove sponsor,selfpromo,interaction", 1, true) ~= nil)
  assertTrue(text:find("--write-thumbnail", 1, true) ~= nil)
  assertTrue(text:find("--convert-thumbnails jpg", 1, true) ~= nil)
  assertTrue(text:find("--embed-thumbnail", 1, true) ~= nil)
  assertTrue(text:find("--sub-langs all", 1, true) ~= nil)
  assertTrue(text:find("--embed-subs", 1, true) ~= nil)
  assertTrue(text:find("--limit-rate 10M", 1, true) ~= nil)
  assertTrue(text:find("--download-archive /home/test/Downloads/.ytdlp-archive.txt", 1, true) ~= nil)
end)

test("download args: auto subs pulled when embedding and no manual subs", function()
  local s = defaultSettings()
  s.embedSubs = true
  s.subLanguage = "all"
  local job = {
    url = "https://youtu.be/x",
    mode = "video",
    info = { hasSubs = false, hasAutoSubs = true },
  }
  local args = service.buildDownloadArgs(job, s, false)
  assertTrue(flatten(args):find("--write-auto-subs", 1, true) ~= nil)
end)

test("download args: audio mode writes subs but never embeds them", function()
  local s = defaultSettings()
  s.embedSubs = true
  s.subLanguage = "id"
  local args = service.buildDownloadArgs({ url = "https://youtu.be/x", mode = "audio", audioFormat = "mp3" }, s, false)
  local text = flatten(args)
  assertTrue(text:find("--sub-langs id", 1, true) ~= nil)
  assertTrue(text:find("--write-subs", 1, true) ~= nil)
  assertTrue(text:find("--embed-subs", 1, true) == nil)
end)

test("download args: specific language + embed pulls auto captions even without info dict", function()
  local s = defaultSettings()
  s.embedSubs = true
  s.subLanguage = "id"
  local args = service.buildDownloadArgs({ url = "https://youtu.be/x", mode = "video" }, s, false)
  local text = flatten(args)
  assertTrue(text:find("--write-auto-subs", 1, true) ~= nil)
  assertTrue(text:find("--embed-subs", 1, true) ~= nil)
end)

-- ── friendlyError ──

test("friendlyError maps 403 to a cookie/web hint", function()
  local msg = service.friendlyError("ERROR: [youtube] abc: HTTP Error 403: Forbidden", 1)
  assertTrue(msg:find("Access denied", 1, true) ~= nil)
end)

test("friendlyError maps ffmpeg to an install hint", function()
  local msg = service.friendlyError("ERROR: Postprocessing: ffmpeg and ffprobe not found", 1)
  assertTrue(msg:find("ffmpeg is required", 1, true) ~= nil)
end)

test("friendlyError falls back to the first line", function()
  assertEqual(service.friendlyError("Some odd failure\nsecond line", 1), "Download failed: Some odd failure")
end)

-- ── runtime flows (host mock drives service's subprocesses) ──

local function sampleVideo()
  return {
    title = "A Test Video",
    thumbnail = "https://img.example/vi/x/y.jpg",
    duration = 125,
    uploader = "tester",
    webpage_url = "https://youtu.be/x",
    extractor = "youtube",
    formats = {
      { height = 1080, acodec = "mp4a.40.2" },
      { height = 720, acodec = "mp4a.40.2" },
    },
    subtitles = {},
    automatic_captions = {},
  }
end

test("extract flow publishes media_info", function()
  host.resetRuntime()
  cmd("extract", { url = "ytsearch1:test" })
  assertEqual(noctalia.state.get("extracting"), true)
  host.completeAsync(1, { exitCode = 0, stdout = noctalia.json.encode(sampleVideo()) })
  assertEqual(noctalia.state.get("extracting"), false)
  local info = noctalia.state.get("media_info")
  assertTrue(info ~= nil, "media_info published")
  assertEqual(info.title, "A Test Video")
  assertEqual(info.availableQualities[1], "1080")
  assertEqual(info.availableQualities[2], "720")
  assertEqual(info.extractedUrl, "ytsearch1:test")
  assertEqual(info.isPlaylist, false)
end)

test("extract failure surfaces a friendly error", function()
  host.resetRuntime()
  cmd("extract", { url = "https://youtu.be/x" })
  host.completeAsync(1, { exitCode = 1, stderr = "ERROR: Unsupported URL: example" })
  local err = noctalia.state.get("error_message")
  assertTrue(err ~= nil and err:find("Unsupported", 1, true) ~= nil, "friendly error set")
end)

local function defaultJob(url, title)
  return { url = url, title = title, mode = "video", quality = "720", audioFormat = "best", audioLanguage = "" }
end

test("download flow downloads, reads progress, finishes and records history", function()
  host.resetRuntime()
  service.resetFlow()
  cmd("extract", { url = "https://youtu.be/x" })
  host.completeAsync(1, { exitCode = 0, stdout = noctalia.json.encode(sampleVideo()) })
  cmd("download", { job = defaultJob("https://youtu.be/x", "A Test Video") })
  assertEqual(noctalia.state.get("active_job").status, "preparing")
  host.completeAsync(2, { exitCode = 0 })
  assertEqual(noctalia.state.get("active_job").status, "downloading")
  assertEqual(host.streamCount(), 1)

  host.feedStreamLine(1, "progress:42.0%| 2.5MiB/s |00:20|100.0MiB|200.0MiB||1|1")
  assertEqual(noctalia.state.get("active_job").progress.percent, 42)

  host.feedStreamLine(1, "/home/test/Downloads/A Test Video.mp4")
  assertEqual(noctalia.state.get("active_job").outputPath, "/home/test/Downloads/A Test Video.mp4")

  host.feedStreamLine(1, "__YTDLP_EXIT__0")
  local finished = noctalia.state.get("active_job")
  assertEqual(finished.status, "completed")
  assertEqual(finished.outputPath, "/home/test/Downloads/A Test Video.mp4")

  local history = noctalia.state.get("settings").history
  assertTrue(type(history) == "table" and #history == 1, "history recorded")
  assertEqual(history[1], "https://youtu.be/x")
end)

test("download failure flags error", function()
  host.resetRuntime()
  service.resetFlow()
  cmd("download", { job = defaultJob("https://youtu.be/x", "x") })
  host.completeAsync(1, { exitCode = 0 })
  host.feedStreamLine(1, "__YTDLP_EXIT__1")
  local active = noctalia.state.get("active_job")
  assertEqual(active.status, "error")
  assertTrue(active.error:find("Download failed", 1, true) ~= nil)
  assertTrue(host.errorNotificationCount() >= 1, "error notification sent when no panel")
end)

test("sponsorblock concat failure retries once without sponsorblock flags", function()
  host.resetRuntime()
  service.resetFlow()
  service.setSetting("sponsorBlock", true)
  service.setSetting("sponsorBlockCategories", { "music_offtopic" })
  cmd("download", { job = defaultJob("https://youtu.be/x", "x") })
  host.completeAsync(1, { exitCode = 0 })
  assertTrue(host.streamCount() == 1)
  local firstHasSB = (host.streamRequest(1) or ""):find("--sponsorblock-remove", 1, true) ~= nil
  assertTrue(firstHasSB, "first attempt has sponsorblock")

  host.feedStreamLine(1, "ERROR: Postprocessing: Error opening input files: Numerical result out of range")
  host.feedStreamLine(1, "__YTDLP_EXIT__1")
  assertTrue(host.streamCount() == 2, "retried with a fresh download")
  assertEqual(noctalia.state.get("active_job").status, "downloading")
  local retryCmd = host.streamRequest(2) or ""
  assertTrue(retryCmd:find("--sponsorblock-remove", 1, true) == nil, "retry omits sponsorblock flags")

  host.completeAsync(2, { exitCode = 0 })
  host.feedStreamLine(2, "__YTDLP_EXIT__0")
  assertEqual(noctalia.state.get("active_job").status, "completed")

  service.resetSettings()
end)

test("cancel marks the job cancelled", function()
  host.resetRuntime()
  service.resetFlow()
  cmd("download", { job = defaultJob("https://youtu.be/x", "x") })
  host.completeAsync(1, { exitCode = 0 })
  cmd("cancel")
  host.feedStreamLine(1, "__YTDLP_EXIT__143")
  assertEqual(noctalia.state.get("active_job").status, "cancelled")
end)

test("pause then resume starts a fresh download", function()
  host.resetRuntime()
  service.resetFlow()
  cmd("download", { job = defaultJob("https://youtu.be/x", "x") })
  host.completeAsync(1, { exitCode = 0 })
  cmd("pause")
  host.feedStreamLine(1, "__YTDLP_EXIT__143")
  assertEqual(noctalia.state.get("active_job").status, "paused")

  cmd("resume")
  assertEqual(noctalia.state.get("active_job").status, "preparing")
  host.completeAsync(2, { exitCode = 0 })
  assertEqual(host.streamCount(), 2)
  host.feedStreamLine(2, "__YTDLP_EXIT__0")
  assertEqual(noctalia.state.get("active_job").status, "completed")
end)

test("queue drains after each item", function()
  host.resetRuntime()
  service.resetFlow()
  cmd("enqueue", { job = defaultJob("https://a.x/1", "one") })
  cmd("enqueue", { job = defaultJob("https://a.x/2", "two") })
  cmd("download", { job = defaultJob("https://a.x/3", "three") })
  host.completeAsync(1, { exitCode = 0 })
  assertEqual(host.streamCount(), 1)
  host.feedStreamLine(1, "__YTDLP_EXIT__0")
  host.completeAsync(2, { exitCode = 0 })
  host.feedStreamLine(2, "__YTDLP_EXIT__0")
  host.completeAsync(3, { exitCode = 0 })
  host.feedStreamLine(3, "__YTDLP_EXIT__0")
  assertEqual(#(noctalia.state.get("queue")), 0)
  assertEqual(host.streamCount(), 3)
end)

test("remove_queued drops a specific entry", function()
  host.resetRuntime()
  service.resetFlow()
  cmd("enqueue", { job = defaultJob("https://a.x/1", "one") })
  cmd("enqueue", { job = defaultJob("https://a.x/2", "two") })
  assertEqual(#(noctalia.state.get("queue")), 2)
  cmd("remove_queued", { index = 1 })
  local q = noctalia.state.get("queue")
  assertEqual(#q, 1)
  assertEqual(q[1].url, "https://a.x/2")
end)

test("retry web client re-extracts with a web player client", function()
  host.resetRuntime()
  service.resetFlow()
  cmd("retry", { url = "https://youtu.be/x" })
  assertEqual(noctalia.state.get("extracting"), true)
  assertContains(host.asyncCommand(1), "--extractor-args")
  assertContains(host.asyncCommand(1), "youtube:player_client=web")
end)

test("set_setting persists and publishes only known keys", function()
  host.resetRuntime()
  cmd("set_setting", { key = "rateLimit", value = "1M" })
  assertEqual(noctalia.state.get("settings").rateLimit, "1M")
  assertTrue(host.fileContent("/data/settings.json") ~= nil, "settings persisted")
  cmd("set_setting", { key = "nonsense", value = "x" })
  assertEqual(noctalia.state.get("settings").nonsense, nil)
end)

test("reset_settings restores defaults", function()
  host.resetRuntime()
  cmd("set_setting", { key = "rateLimit", value = "1M" })
  cmd("reset_settings")
  assertEqual(noctalia.state.get("settings").rateLimit, "")
  assertEqual(noctalia.state.get("settings").downloadDir, "/home/test/Downloads/Videos/yt-dlp")
end)

test("read_clipboard writes through to state", function()
  host.resetRuntime()
  cmd("read_clipboard", { forced = true })
  host.completeAsync(1, { exitCode = 0, stdout = "https://youtu.be/x" })
  local clip = noctalia.state.get("clipboard")
  assertEqual(clip.text, "https://youtu.be/x")
  assertEqual(clip.forced, true)
  assertTrue(clip.version >= 1, "version bumped for panel re-seed")
end)

test("settings round-trip through the persisted file", function()
  host.resetRuntime()
  cmd("set_setting", { key = "proxy", value = "socks5://127.0.0.1:1080" })
  service.loadSettings()
  assertEqual(noctalia.state.get("settings").proxy, "socks5://127.0.0.1:1080")
end)

local function runAll()
  local failed = 0
  for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
      io.write("ok  " .. t.name .. "\n")
    else
      failed = failed + 1
      io.write("FAIL " .. t.name .. ": " .. tostring(err) .. "\n")
    end
  end
  io.write(string.format("\n%d passed, %d failed, %d total\n", #tests - failed, failed, #tests))
  return failed == 0
end

local ok = runAll()
os.exit(ok and 0 or 1)