--!nonstrict
--
-- RakuOS Tools service ("checker"): periodically probes bootc (image) and rum
-- (overlay packages), publishes the result to noctalia.state["rakuos_updates"]
-- and notifies once whenever the set of available updates changes.
--
-- The panel owns the "rakuos_busy" flag; while it is set the service skips
-- checks so a bootc/rum run never overlaps an upgrade action.
--
-- plugin_api 19: runAsync only accepts a single shell string, so commands are
-- assembled with shellQuote/shellJoin (same workaround as containers/ytdlp).

local KEY = "rakuos_updates"
local CMD_KEY = "rakuos_cmd"
local BUSY_KEY = "rakuos_busy"

local SIG_FILE = (noctalia.pluginDataDir() or "") .. "/notify_signature.txt"

local M = {}
local checking = false
local lastSignature = ""

local function tr(key)
    return noctalia.tr(key) or key
end

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

-- ── shell quoting ─────────────────────────────────────────────────────────────

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function shellJoin(argv)
    local out = {}
    for i, arg in ipairs(argv) do
        out[i] = shellQuote(arg)
    end
    return table.concat(out, " ")
end

-- ── persisted "last notified" signature ───────────────────────────────────────

local function loadSignature()
    if SIG_FILE == "" then return end
    local raw = noctalia.readFile(SIG_FILE)
    if raw then lastSignature = trim(raw) end
end

local function saveSignature()
    if SIG_FILE == "" then return end
    noctalia.writeFile(SIG_FILE, lastSignature)
end

-- ── parsers ───────────────────────────────────────────────────────────────────

local function parseBootcStatus(result)
    local image = { available = false, pending_reboot = false }
    if not (result and result.exitCode == 0) then
        image.error = tr("service.bootc_status_failed")
        return image
    end
    local ok, data = pcall(noctalia.json.decode, result.stdout)
    if not ok or type(data) ~= "table" then
        image.error = tr("service.bootc_bad_json")
        return image
    end
    local status = data.status
    if type(status) == "table" then
        local booted = status.booted
        local staged = status.staged
        if type(booted) == "table" and type(booted.image) == "table" then
            image.booted = {
                version = booted.image.version or nil,
                digest = booted.image.imageDigest or nil,
            }
        end
        if type(staged) == "table" and type(staged.image) == "table" then
            image.staged = {
                version = staged.image.version or nil,
                digest = staged.image.imageDigest or nil,
            }
        end
        if image.booted and image.staged and image.staged.digest
            and image.booted.digest and image.staged.digest ~= image.booted.digest then
            image.pending_reboot = true
            image.available = true
        end
    end
    return image
end

local function parseRum(result)
    local out = { count = 0, ups = {} }
    if not (result and result.exitCode == 0) then
        out.error = tr("service.rum_check_failed")
        return out
    end
    local ok, data = pcall(noctalia.json.decode, result.stdout)
    if not ok or type(data) ~= "table" or type(data.updates) ~= "table" then
        out.error = tr("service.rum_bad_json")
        return out
    end
    local ups = {}
    for _, item in ipairs(data.updates) do
        if type(item) == "table" then
            ups[#ups + 1] = {
                name = item.name or item.package or item.nevra or item.id or tostring(item),
                version = item.version or "",
                repo = item.repo or item.repository or item.repo_id or "",
            }
        end
    end
    out.ups = ups
    out.count = #ups
    return out
end

-- ── notifications ─────────────────────────────────────────────────────────────

local function signatureOf(st)
    local parts = {}
    if st.image and st.image.available and not st.image.error then
        parts[#parts + 1] = "image"
    end
    if st.packages and st.packages.count and st.packages.count > 0 then
        parts[#parts + 1] = "packages:" .. st.packages.count
    end
    return table.concat(parts, ",")
end

local function notifyIfChanged(st)
    if noctalia.getConfig("notify_on_updates") == false then return end
    local sig = signatureOf(st)
    if sig == "" then
        lastSignature = ""
        saveSignature()
        return
    end
    if sig == lastSignature then
        return
    end
    local lines = {}
    if st.image and st.image.available and not st.image.error then
        lines[#lines + 1] = st.image.pending_reboot and tr("notify.reboot") or tr("notify.image")
    end
    if st.packages and st.packages.count and st.packages.count > 0 then
        lines[#lines + 1] = st.packages.count .. " " ..
            (st.packages.count == 1 and tr("panel.pkg_single") or tr("panel.pkg_plural"))
    end
    if #lines > 0 then
        noctalia.runAsync(shellJoin({
            "notify-send", "-u", "normal", tr("notify.title"), table.concat(lines, "\n"),
        }), function() end)
    end
    lastSignature = sig
    saveSignature()
end

-- ── check pipeline ────────────────────────────────────────────────────────────

local function finishImage(st, image)
    if noctalia.getConfig("check_packages") ~= false then
        noctalia.runAsync("sudo rum check-upgrade --json", function(r)
            st.packages = parseRum(r)
            M.finish(st)
        end)
    else
        st.packages = { count = 0, ups = {} }
        M.finish(st)
    end
end

function M.finish(st)
    st.checking = false
    st.last_check_at = os.time()
    if not st.error then
        st.error = (st.image and st.image.error) or (st.packages and st.packages.error) or nil
    end
    noctalia.state.set(KEY, st)
    checking = false
    notifyIfChanged(st)
end

function M.check()
    if checking then return end
    if noctalia.state.get(BUSY_KEY) then return end
    checking = true
    local st = {
        checking = true,
        image = {},
        packages = { count = 0, ups = {} },
        last_check_at = nil,
        error = nil,
    }
    noctalia.state.set(KEY, st)
    noctalia.runAsync("sudo bootc status --json", function(r1)
        local image = parseBootcStatus(r1)
        st.image = image
        if image.pending_reboot then
            finishImage(st, image)
            return
        end
        noctalia.runAsync("sudo bootc upgrade --check", function(r2)
            local text = ((r2 and r2.stdout) or "") .. "\n" .. ((r2 and r2.stderr) or "")
            image.available = text:find("Update available", 1, true) ~= nil
            finishImage(st, image)
        end)
    end)
end

-- ── host hooks ────────────────────────────────────────────────────────────────

-- `check_interval` select: 6h / 12h / 1d / 1w / manual.
-- Day and week schedules always land on 10:00 local (drift-free).
local function next10am(days)
    local now = os.time()
    local t = os.date("*t", now)
    local nextEpoch = os.time({
        year = t.year,
        month = t.month,
        day = t.day,
        hour = 10,
        min = 0,
        sec = 0,
    })
    while nextEpoch <= now do
        nextEpoch = nextEpoch + days * 86400
    end
    return (nextEpoch - now) * 1000
end

local function applyInterval()
    local choice = tostring(noctalia.getConfig("check_interval") or "1d")
    if choice == "manual" then
        noctalia.setUpdateInterval(365 * 86400000)
    elseif choice == "6h" then
        noctalia.setUpdateInterval(6 * 3600000)
    elseif choice == "12h" then
        noctalia.setUpdateInterval(12 * 3600000)
    elseif choice == "1w" then
        noctalia.setUpdateInterval(next10am(7))
    else
        noctalia.setUpdateInterval(next10am(1))
    end
end

function update()
    M.check()
    applyInterval()
end

function onIpc(event, _payload)
    if event == "check" or event == "refresh" then
        pcall(M.check)
    end
end

function onConfigChanged()
    applyInterval()
    pcall(M.check)
end

noctalia.state.watch(CMD_KEY, function(cmd)
    if type(cmd) == "table" and (cmd.action == "check" or cmd.action == "refresh") then
        pcall(M.check)
    end
end)

loadSignature()
applyInterval()
M.check()

return M