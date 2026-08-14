--!nonstrict
-- Standalone Luau tests for the wallpaper-automation pause feature.
-- Run: luajit tests/service_test.luau  (or luau tests/service_test.luau)

local host = dofile("./tests/host_mock.luau")

-- service.luau is loaded with the host mock injected (it detects a missing
-- global `noctalia` and requires ./tests/host_mock itself).
local service = dofile("./service.luau")

local tests = {}
local function test(name, fn)
  table.insert(tests, { name = name, fn = fn })
end

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

local function sampleSettings(enabled)
  return ("[wallpaper]\nfill_mode = \"span\"\n\n[wallpaper.automation]\nenabled = %s\ninterval_seconds = 600\n\n[weather]\nrefresh_minutes = 5\n"):format(enabled)
end

-- ── pure text edit ──

test("disable: flips enabled to false inside [wallpaper.automation]", function()
  local out = service.applyAutomationEnabled(sampleSettings(true), false)
  assertTrue(out ~= nil, "returns text")
  assertTrue(out:find("enabled = false", 1, true) ~= nil, "enabled = false present")
  assertTrue(out:find("interval_seconds = 600", 1, true) ~= nil, "other key untouched")
  assertTrue(out:find("refresh_minutes = 5", 1, true) ~= nil, "other section untouched")
end)

test("enable: flips enabled to true", function()
  local out = service.applyAutomationEnabled(sampleSettings(false), true)
  assertTrue(out ~= nil, "returns text")
  assertTrue(out:find("enabled = true", 1, true) ~= nil, "enabled = true present")
end)

test("does not touch a different section that also has enabled", function()
  local text = "[window_effects]\nenabled = true\n\n[wallpaper.automation]\nenabled = true\ninterval_seconds = 600\n"
  local out = service.applyAutomationEnabled(text, false)
  assertTrue(out ~= nil, "returns text")
  assertTrue(out:find("enabled = false", 1, true) ~= nil, "automation disabled")
  assertTrue(out:find("%[window_effects%]"), "window_effects section intact")
end)

test("missing section returns nil", function()
  local out = service.applyAutomationEnabled("[weather]\nrefresh_minutes = 5\n", false)
  assertEqual(out, nil)
end)

-- ── file IO ──

test("readWallpaperAutomation reads enabled", function()
  host.resetRuntime()
  host.setFiles({ ["/home/test/.local/state/noctalia/settings.toml"] = sampleSettings(true) })
  assertEqual(service.readWallpaperAutomation(), true)
end)

test("readWallpaperAutomation reads disabled", function()
  host.resetRuntime()
  host.setFiles({ ["/home/test/.local/state/noctalia/settings.toml"] = sampleSettings(false) })
  assertEqual(service.readWallpaperAutomation(), false)
end)

test("readWallpaperAutomation returns nil when file missing", function()
  host.resetRuntime()
  host.setFiles({})
  assertEqual(service.readWallpaperAutomation(), nil)
end)

test("setWallpaperAutomation writes the file", function()
  host.resetRuntime()
  host.setFiles({ ["/home/test/.local/state/noctalia/settings.toml"] = sampleSettings(true) })
  local ok = service.setWallpaperAutomation(false)
  assertTrue(ok, "write succeeds")
  local written = host.fileContent("/home/test/.local/state/noctalia/settings.toml")
  assertTrue(written ~= nil, "file written")
  assertTrue(written:find("enabled = false", 1, true) ~= nil, "disabled written")
end)

test("setWallpaperAutomation reports failure when file unreadable", function()
  host.resetRuntime()
  host.setFiles({})
  local ok = service.setWallpaperAutomation(false)
  assertEqual(ok, false)
end)

-- ── snapshot round-trip ──

test("snapshot round-trips wallpaper_automation_before", function()
  host.resetRuntime()
  host.setFiles({ ["/home/test/.local/state/noctalia/settings.toml"] = sampleSettings(true) })
  local snap = service.buildSnapshot("light", nil, {}, true)
  local ok = service.writeSnapshot(snap)
  assertTrue(ok, "snapshot written")
  local read = service.readSnapshot()
  assertTrue(read ~= nil, "snapshot read")
  assertEqual(read.wallpaper_automation_before, true)
end)

test("snapshot with no wallpaper_automation_before round-trips as nil", function()
  host.resetRuntime()
  host.setFiles({})
  local snap = service.buildSnapshot("light", nil, {}, nil)
  local ok = service.writeSnapshot(snap)
  assertTrue(ok, "snapshot written")
  local read = service.readSnapshot()
  assertTrue(read ~= nil, "snapshot read")
  assertEqual(read.wallpaper_automation_before, nil)
end)

test("enable path pauses wallpaper automation and records the original", function()
  host.resetRuntime()
  host.setFiles({ ["/home/test/.local/state/noctalia/settings.toml"] = sampleSettings(true) })
  local ok = service.setWallpaperAutomation(false)
  assertTrue(ok, "pauses wallpaper automation")
  local settings = host.fileContent("/home/test/.local/state/noctalia/settings.toml")
  assertTrue(settings ~= nil and settings:find("enabled = false", 1, true) ~= nil, "file now disabled")
  assertEqual(service.readWallpaperAutomation(), false)
end)

-- ── runner ──

local failures = 0
for _, t in ipairs(tests) do
  host.resetRuntime()
  local ok, err = pcall(t.fn)
  if ok then
    print("ok    " .. t.name)
  else
    failures = failures + 1
    print("FAIL  " .. t.name)
    print("      " .. tostring(err))
  end
end

print(string.format("%d tests, %d failures", #tests, failures))
os.exit(failures == 0 and 0 or 1)
