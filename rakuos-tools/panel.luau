--!nonstrict
--
-- RakuOS Tools panel: status summary + action buttons.
-- Actions use sudo-rs with the image-baked NOPASSWD drop-in
-- (system_files/etc/sudoers.d/rakuos-plugin-updates) — no pkexec dialogs.
-- Long-running upgrades stream live output into the log area.
--
-- Communication with the service: the panel sets noctalia.state["rakuos_cmd"]
-- to ask for a check; the service owns the check pipeline and broadcasts
-- noctalia.state["rakuos_updates"]. The panel owns the "rakuos_busy" flag so
-- the service never runs a check while an upgrade action is in flight.
--
-- plugin_api 19: runAsync/runStream only accept shell strings.

local KEY = "rakuos_updates"
local CMD_KEY = "rakuos_cmd"
local BUSY_KEY = "rakuos_busy"

local M = {}

local open = false
local state = {}
local ui = {
    showAdvanced = false,
    pendingConfirm = nil, -- "rollback" | "reset" | nil
    target = "",
    zram = "",
    karg = "",
    currentKargs = "",
    busy = false,
    logs = {},
}

local function tr(key)
    return noctalia.tr(key) or key
end

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

-- ── shell quoting (runStream takes a string; runAsync takes argv) ────────────

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

-- ── busy / logs ───────────────────────────────────────────────────────────────

local function setBusy(b)
    ui.busy = b
    noctalia.state.set(BUSY_KEY, b)
    if open then render() end
end

local function appendLog(text, kind)
    text = tostring(text or "")
    if text == "" then return end
    table.insert(ui.logs, { text = text, kind = kind or "info" })
    while #ui.logs > 50 do
        table.remove(ui.logs, 1)
    end
    if open then render() end
end

function clearLogs()
    ui.logs = {}
    if open then render() end
end

-- ── rendering helpers ─────────────────────────────────────────────────────────

local function render()

    -- status strings
    local imgStatus, imgColor = tr("panel.unknown"), nil
    if state.image then
        if state.image.pending_reboot then
            imgStatus, imgColor = tr("panel.reboot_pending"), "primary"
        elseif state.image.available then
            imgStatus, imgColor = tr("panel.update_available"), "primary"
        else
            imgStatus = tr("panel.uptodate")
        end
    end

    local pkgStatusText, pkgColor = tr("panel.uptodate"), nil
    if state.checking then
        pkgStatusText = tr("panel.checking")
    else
        local pcount = state.packages and state.packages.count or 0
        if pcount > 0 then
            pkgStatusText, pkgColor = tostring(pcount) .. " " ..
                (pcount == 1 and tr("panel.pkg_single") or tr("panel.pkg_plural")), "primary"
        end
    end

    -- header
    local children = {}
    local titleColumn = ui.column({ gap = 2 }, {
        ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
        ui.label({ text = lastCheckLabel(), fontSize = 11, color = "on_surface" }),
    })
    children[#children + 1] = ui.row({ gap = 8, align = "center", justify = "space_between" }, {
        titleColumn,
        ui.button({ glyph = "refresh", variant = "ghost", onClick = "panelCheck" }),
    })
    children[#children + 1] = ui.separator()

    -- status block
    local statusRows = {}
    statusRows[#statusRows + 1] = ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = tr("panel.image_label"), fontSize = 12, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = imgStatus, fontSize = 12, color = imgColor }),
    })
    statusRows[#statusRows + 1] = bootedRow()
    statusRows[#statusRows + 1] = stagedRow()
    statusRows[#statusRows + 1] = ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = tr("panel.packages_label"), fontSize = 12, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = pkgStatusText, fontSize = 12, color = pkgColor }),
    })
    if state.error then
        statusRows[#statusRows + 1] = ui.label({
            text = tr("panel.error_prefix") .. " " .. state.error,
            fontSize = 11,
            color = "error",
        })
    end
    if ui.busy then
        statusRows[#statusRows + 1] = ui.label({ text = tr("panel.busy"), fontSize = 11, color = "primary" })
    end
    children[#children + 1] = ui.column({ gap = 4 }, statusRows)

    -- actions
    children[#children + 1] = ui.label({ text = tr("panel.actions"), fontSize = 12, fontWeight = "bold", color = "on_surface" })
    children[#children + 1] = ui.row({ gap = 8 }, {
        ui.button({ glyph = "search", text = tr("panel.check_now"), variant = "secondary", onClick = "panelCheck" }),
        ui.button({ glyph = "package", text = tr("panel.update_packages"), variant = "primary", onClick = "startUpgradePkgs" }),
    })
    children[#children + 1] = ui.row({ gap = 8 }, {
        ui.button({ glyph = "refresh", text = tr("panel.update_image"), variant = "primary", onClick = "startImage" }),
        ui.button({ glyph = "brand-flatpak", text = tr("panel.flatpak"), variant = "secondary", onClick = "startFlatpak" }),
    })
    children[#children + 1] = ui.row({ gap = 8 }, {
        ui.button({
            glyph = "history",
            text = ui.pendingConfirm == "rollback" and (tr("panel.confirm") .. "?") or tr("panel.rollback"),
            variant = "destructive",
            onClick = "startRollback",
        }),
        ui.button({
            glyph = "eraser",
            text = ui.pendingConfirm == "reset" and (tr("panel.confirm") .. "?") or tr("panel.reset_overlay"),
            variant = "destructive",
            onClick = "startResetOverlay",
        }),
    })

    -- advanced
    children[#children + 1] = ui.button({
        glyph = "settings",
        text = tr("panel.advanced"),
        variant = "ghost",
        onClick = "toggleAdvanced",
    })
    if ui.showAdvanced then
        children[#children + 1] = zramRow()
        children[#children + 1] = switchRow()
        children[#children + 1] = kargsRow()
    end

    -- logs
    children[#children + 1] = ui.row({ gap = 8, align = "center", justify = "space_between" }, {
        ui.label({ text = tr("panel.logs"), fontSize = 12, fontWeight = "bold", color = "on_surface" }),
        ui.button({ glyph = "eraser", variant = "ghost", onClick = "clearLogs" }),
    })
    local logRows = {}
    if #ui.logs == 0 then
        logRows[#logRows + 1] = ui.label({ text = tr("panel.no_logs"), fontSize = 11, color = "on_surface" })
    else
        local startIdx = math.max(1, #ui.logs - 8)
        for i = startIdx, #ui.logs do
            local entry = ui.logs[i]
            local color = entry.kind == "err" and "error" or (entry.kind == "ok" and "primary" or "on_surface")
            logRows[#logRows + 1] = ui.label({
                text = entry.text,
                fontSize = 11,
                color = color,
                wrap = true,
            })
        end
    end
    children[#children + 1] = ui.column({ gap = 2 }, logRows)

    panel.render(ui.scroll({ flexGrow = 1, gap = 8, padding = 12 }, children))
end

function lastCheckLabel()
    if not state.last_check_at then
        return tr("panel.last_check") .. ": " .. tr("panel.never")
    end
    local ok, fmt = pcall(os.date, "%H:%M", state.last_check_at)
    return tr("panel.last_check") .. ": " .. (ok and fmt or tostring(state.last_check_at))
end

local function versionRow(which, labelKey)
    local img = state.image
    if not img or not img[which] then return nil end
    local v = img[which].version or img[which].digest
    if not v then return nil end
    return ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = tr(labelKey) .. ":", fontSize = 11, color = "on_surface" }),
        ui.label({ text = v, fontSize = 11 }),
    })
end

local function bootedRow()
    return versionRow("booted", "panel.installed")
end

local function stagedRow()
    return versionRow("staged", "panel.staged")
end

local function zramRow()
    return ui.column({ gap = 4 }, {
        ui.label({ text = tr("panel.zram"), fontSize = 12, fontWeight = "bold", color = "on_surface" }),
        ui.row({ gap = 8 }, {
            ui.input({ key = "rakuos-zram", placeholder = tr("panel.zram_placeholder"), value = ui.zram, onChange = "onZramChanged" }),
            ui.button({ text = tr("panel.zram_save"), variant = "secondary", onClick = "applyZram" }),
        }),
    })
end

local function switchRow()
    return ui.column({ gap = 4 }, {
        ui.label({ text = tr("panel.switch_image"), fontSize = 12, fontWeight = "bold", color = "on_surface" }),
        ui.row({ gap = 8 }, {
            ui.input({ key = "rakuos-target", placeholder = tr("panel.switch_placeholder"), value = ui.target, onChange = "onTargetChanged" }),
            ui.button({ text = tr("panel.switch_btn"), variant = "secondary", onClick = "switchImage" }),
        }),
    })
end

local function kargsRow()
    return ui.column({ gap = 4 }, {
        ui.label({ text = tr("panel.kargs"), fontSize = 12, fontWeight = "bold", color = "on_surface" }),
        ui.label({
            text = tr("panel.kargs_current") .. ": " .. (ui.currentKargs ~= "" and ui.currentKargs or tr("panel.unknown")),
            fontSize = 11,
            color = "on_surface",
            wrap = true,
        }),
        ui.row({ gap = 8 }, {
            ui.input({ key = "rakuos-karg", placeholder = tr("panel.kargs_placeholder"), value = ui.karg, onChange = "onKargChanged" }),
            ui.button({ text = tr("panel.kargs_apply"), variant = "secondary", onClick = "applyKarg" }),
        }),
    })
end

-- ── input state ───────────────────────────────────────────────────────────────

function onTargetChanged(v) ui.target = v or "" end
function onZramChanged(v) ui.zram = v or "" end
function onKargChanged(v) ui.karg = v or "" end

function toggleAdvanced()
    ui.showAdvanced = not ui.showAdvanced
    if open then render() end
end

-- ── actions ───────────────────────────────────────────────────────────────────

function panelCheck()
    noctalia.state.set(CMD_KEY, { action = "check", at = os.time() })
    appendLog(tr("panel.check_started"))
end

local function streamAction(name, argv, doneMsg)
    if ui.busy then return end
    setBusy(true)
    appendLog(tr("panel.starting") .. " " .. table.concat(argv, " "))
    local cmd = shellJoin(argv) .. "; echo __RAKUOS_" .. name .. "_$?"
    noctalia.runStream(cmd, function(line)
        if not line or line == "" then return end
        local code = line:match("^__RAKUOS_" .. name .. "_(%d+)$")
        if code then
            setBusy(false)
            local ok = code == "0"
            appendLog(ok and doneMsg or (tr("panel.failed") .. " (exit " .. code .. ")"), ok and "ok" or "err")
            if ok then panelCheck() end
        else
            appendLog(line)
        end
    end)
end

local function runAsyncAction(argv, doneMsg, refresh)
    if ui.busy then return end
    if type(argv) == "table" then argv = shellJoin(argv) end
    setBusy(true)
    appendLog(tr("panel.starting") .. " " .. argv)
    noctalia.runAsync(argv, function(r)
        if r and r.stdout and trim(r.stdout) ~= "" then appendLog(trim(r.stdout)) end
        if r and r.stderr and trim(r.stderr) ~= "" then appendLog(trim(r.stderr), "err") end
        local ok = r and r.exitCode == 0
        setBusy(false)
        appendLog(ok and doneMsg or (tr("panel.failed") .. " (exit " .. tostring(r and r.exitCode or "?") .. ")"), ok and "ok" or "err")
        if refresh and ok then panelCheck() end
    end)
end

function startUpgradePkgs()
    streamAction("RUM", { "sudo", "rum", "upgrade", "-y" }, tr("panel.done_pkgs"))
end

function startFlatpak()
    streamAction("FLATPAK", { "sudo", "flatpak", "update", "-y" }, tr("panel.done_flatpak"))
end

function startImage()
    runAsyncAction(
        shellJoin({ "sudo", "systemctl", "start", "rakuos-bootc-upgrade.service" }),
        tr("panel.done_image"),
        true
    )
end

function startRollback()
    if ui.pendingConfirm ~= "rollback" then
        ui.pendingConfirm = "rollback"
        if open then render() end
        return
    end
    ui.pendingConfirm = nil
    if ui.busy then return end
    setBusy(true)
    appendLog(tr("panel.starting") .. " sudo bootc rollback")
    noctalia.runAsync("sudo bootc rollback", function(r)
        if r and r.stderr and trim(r.stderr) ~= "" then appendLog(trim(r.stderr), "err") end
        appendLog(tr("panel.starting") .. " sudo /usr/libexec/rakuos/rakuos-reset-overlay --soft")
        noctalia.runAsync("sudo /usr/libexec/rakuos/rakuos-reset-overlay --soft", function(r2)
            if r2 and r2.stderr and trim(r2.stderr) ~= "" then appendLog(trim(r2.stderr), "err") end
            local ok = r2 and r2.exitCode == 0
            setBusy(false)
            appendLog(ok and tr("panel.done_rollback") or (tr("panel.failed") .. " (exit " .. tostring(r2 and r2.exitCode or "?") .. ")"), ok and "ok" or "err")
            if ok then panelCheck() end
        end)
    end)
end

function startResetOverlay()
    if ui.pendingConfirm ~= "reset" then
        ui.pendingConfirm = "reset"
        if open then render() end
        return
    end
    ui.pendingConfirm = nil
    runAsyncAction(
        shellJoin({ "sudo", "/usr/libexec/rakuos/rakuos-reset-overlay", "--soft" }),
        tr("panel.done_reset"),
        true
    )
end

function switchImage()
    local target = trim(ui.target)
    if target == "" or ui.busy then return end
    ui.target = ""
    runAsyncAction(shellJoin({ "sudo", "bootc", "switch", target }), tr("panel.done_switch"), false)
end

function applyZram()
    if ui.busy then return end
    local mib = tonumber(trim(ui.zram))
    if not mib or mib <= 0 then return end
    ui.zram = ""
    local cmd = "printf '%s' " .. shellQuote("zram-size = " .. tostring(mib))
        .. " | sudo tee /etc/systemd/zram-generator.conf >/dev/null"
    runAsyncAction(cmd, tr("panel.zram_written"), false)
end

function applyKarg()
    if ui.busy then return end
    local karg = trim(ui.karg)
    if karg == "" then return end
    ui.karg = ""
    local content = 'kargs = ["' .. karg .. '"]\n'
    local cmd = "printf '%s' " .. shellQuote(content)
        .. " | sudo tee /usr/lib/bootc/kargs.d/10-rakuos-plugin.toml >/dev/null"
    runAsyncAction(cmd, tr("panel.kargs_written"), false)
end

-- ── entry points ──────────────────────────────────────────────────────────────

function onOpen()
    open = true
    ui.pendingConfirm = nil
    noctalia.state.set(BUSY_KEY, ui.busy)
    noctalia.runAsync("cat /proc/cmdline", function(r)
        ui.currentKargs = trim(r and r.stdout or "")
        if open then render() end
    end)
    local st = noctalia.state.get(KEY)
    state = type(st) == "table" and st or {}
    render()
end

function onClose()
    open = false
    ui.pendingConfirm = nil
end

noctalia.state.watch(KEY, function(value)
    state = type(value) == "table" and value or {}
    if open then render() end
end)

local st = noctalia.state.get(KEY)
state = type(st) == "table" and st or {}

return M