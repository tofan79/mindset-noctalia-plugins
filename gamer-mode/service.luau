--!nonstrict
--
-- Gamer Mode service: publishes system metrics and owns the snapshot-based game-mode
-- engine. The panel and widget are thin readers of `noctalia.state`; every mutation
-- arrives here as a `command` state write.
--
-- Luau's sandbox gives plugins no `io`, no `os.execute`/`os.remove` and no `load`, so
-- all filesystem access goes through noctalia.readFile/writeFile/removeFile/mkdirAll
-- and the snapshot is stored as JSON via noctalia.json.

local noctalia = noctalia
if noctalia == nil then
  -- Standalone (tests): run against the host mock instead of the real shell.
  local host = dofile("tests/host_mock.luau")
  noctalia = host.noctalia
end

local M = {}

local BYTES_PER_MIB = 1048576

local function clampFraction(percent)
    local value = tonumber(percent)
    if not value then
        return 0
    end
    return math.max(0, math.min(1, value / 100))
end

-- normalize converts a noctalia.systemStats() sample into the published `metrics`
-- shape: percentages as 0-1 fractions, memory in MiB.
--
-- Optional readings stay nil rather than becoming zero, so the UI can say "unsupported"
-- instead of drawing an empty bar that looks like a real 0% reading.
function M.normalize(raw)
    if type(raw) ~= "table" then
        return nil
    end

    local cpu = type(raw.cpu) == "table" and raw.cpu or {}
    local ram = type(raw.ram) == "table" and raw.ram or {}
    local gpu = type(raw.gpu) == "table" and raw.gpu or {}

    local metrics = {
        cpuPerc = clampFraction(cpu.usagePercent),
        cpuTemp = tonumber(cpu.tempC),
        memPerc = clampFraction(ram.usagePercent),
        memUsedMb = tonumber(ram.usedMb) or 0,
        memTotalMb = tonumber(ram.totalMb) or 0,
        gpuAvailable = false,
    }

    local gpuPercent = tonumber(gpu.usagePercent)
    if gpuPercent then
        metrics.gpuPerc = clampFraction(gpuPercent)
        metrics.gpuAvailable = true
    end
    local gpuTemp = tonumber(gpu.tempC)
    if gpuTemp then
        metrics.gpuTemp = gpuTemp
        metrics.gpuAvailable = true
    end

    -- VRAM needs both halves: a used figure without a total cannot be drawn as a ratio.
    local vramUsed = tonumber(gpu.vramUsedBytes)
    local vramTotal = tonumber(gpu.vramTotalBytes)
    if vramUsed and vramTotal and vramTotal > 0 then
        metrics.vramUsedMb = vramUsed / BYTES_PER_MIB
        metrics.vramTotalMb = vramTotal / BYTES_PER_MIB
        metrics.vramPerc = math.max(0, math.min(1, vramUsed / vramTotal))
        metrics.gpuAvailable = true
    end

    -- Swap reports used and total but no percentage of its own, and a machine with swap
    -- turned off reports a total of zero, which is a ratio with no meaning.
    local swap = type(raw.swap) == "table" and raw.swap or {}
    local swapUsed = tonumber(swap.usedMb)
    local swapTotal = tonumber(swap.totalMb)
    if swapUsed and swapTotal and swapTotal > 0 then
        metrics.swapUsedMb = swapUsed
        metrics.swapTotalMb = swapTotal
        metrics.swapPerc = math.max(0, math.min(1, swapUsed / swapTotal))
    end

    -- Load average arrives as a three-element array. It is not a percentage of anything
    -- without a core count, so it is carried through as numbers and shown as numbers.
    if type(raw.loadAvg) == "table" then
        local one, five, fifteen = tonumber(raw.loadAvg[1]), tonumber(raw.loadAvg[2]), tonumber(raw.loadAvg[3])
        if one and five and fifteen then
            metrics.load1, metrics.load5, metrics.load15 = one, five, fifteen
        end
    end

    -- Totals across every interface. The per-interface breakdown is left alone: on a
    -- machine running containers it is mostly bridges and veth pairs.
    local net = type(raw.net) == "table" and raw.net or {}
    local rx = tonumber(net.rxBytesPerSec)
    local tx = tonumber(net.txBytesPerSec)
    if rx and tx then
        metrics.netRxPerSec = math.max(0, rx)
        metrics.netTxPerSec = math.max(0, tx)
    end

    return metrics
end

-- ── suspend targets ──

local VALID_KINDS = {
    process = true,
    ["user-service"] = true,
    ["system-service"] = true,
    ["user-timer"] = true,
    ["system-timer"] = true,
    container = true,
}

-- Timer kinds share systemctl with the service kinds but must name a *.timer unit, and
-- cannot be frozen -- a timer has no process to signal.
local TIMER_KINDS = { ["user-timer"] = true, ["system-timer"] = true }

local VALID_ACTIONS = { stop = true, freeze = true }

-- Targets that must never be stopped or frozen. Acting on any of these ends the session,
-- kills audio or network, or kills the game gamer mode exists to serve. Deliberately not
-- overridable: the cost of a wrong entry is a dead session, and an override flag is
-- exactly the field a user copies from a forum post without reading.
local DENIED = {}
for _, name in ipairs({
    -- session and display
    "niri", "hyprland", "sway", "river", "wayfire", "labwc", "gnome-shell",
    "kwin_wayland", "plasmashell", "xorg", "xwayland", "greetd", "sddm", "gdm",
    -- the shell hosting this plugin
    "noctalia", "quickshell",
    -- audio
    "pipewire", "pipewire-pulse", "wireplumber", "pulseaudio",
    -- core IPC and session management
    "systemd", "systemd-logind", "dbus-broker", "dbus-daemon", "elogind",
    -- network
    "networkmanager", "wpa_supplicant", "iwd", "systemd-networkd",
    -- the game stack itself
    "steam", "steamwebhelper", "gamescope", "wine", "wineserver", "proton",
    "lutris", "heroic", "bottles", "gamemoded",
    -- GPU driver daemons. Stopping one of these mid-session costs the thing gamer mode
    -- exists to protect: nvidia-persistenced holds the driver state that keeps a card
    -- from reinitialising, and nvidia-powerd manages the dynamic power budget that lets
    -- it reach its boost clocks.
    "nvidia-persistenced", "nvidia-powerd", "nvidia-suspend", "nvidia-resume",
    "nvidia-hibernate", "amdgpu", "amd-pstate", "switcheroo-control",
}) do
    DENIED[name] = true
end

local UNIT_SUFFIXES = { ".service", ".timer", ".socket" }

-- baseName lowercases and strips a unit suffix so "Steam", "steam" and "steam.service"
-- all collapse onto the same denylist key.
local function baseName(match)
    local name = tostring(match):lower()
    for _, suffix in ipairs(UNIT_SUFFIXES) do
        if #name > #suffix and name:sub(-#suffix) == suffix then
            return name:sub(1, #name - #suffix)
        end
    end
    return name
end

function M.isDenied(match)
    if type(match) ~= "string" or match == "" then
        return false
    end
    return DENIED[baseName(match)] == true
end

-- Defaults aim to be plausible on an arbitrary Linux desktop rather than tuned to one
-- machine. Breadth is close to free: a target that is not running probes as `down`, so it
-- is never acted on and never restored -- an entry for absent software costs one pgrep.
-- The risk is never "too many entries", it is "an entry that is present but should not be
-- touched", which is what the denylist above exists for.
--
-- `light` is background-only: nothing the user could be interacting with, and nothing that
-- produces sound, voice or video they would want during a game. `heavy` adds the big
-- foreground consumers as freezes plus the self-hosted service stacks as stops.
local LIGHT = { "light", "heavy" }
local HEAVY = { "heavy" }

local function processes(names, profiles, out)
    for _, name in ipairs(names) do
        -- Always freeze: a bare process has no argv to relaunch from, so stopping one is
        -- unrecoverable.
        out[#out + 1] = { match = name, kind = "process", action = "freeze", profiles = profiles }
    end
    return out
end

local function units(names, kind, profiles, out)
    for _, name in ipairs(names) do
        out[#out + 1] = { match = name, kind = kind, action = "stop", profiles = profiles }
    end
    return out
end

local function buildDefaults()
    local out = {}

    -- ── light: wallpaper and desktop-effect daemons ──
    -- Animated and video wallpapers cost real GPU time. Freezing stops the rendering,
    -- which is the entire win, and SIGCONT restores it perfectly -- where killing the
    -- daemon would need a full relaunch-and-rewallpaper dance.
    -- swww was archived and renamed to awww in Oct 2025; both names ship.
    processes({
        "awww-daemon", "swww-daemon", "hyprpaper", "swaybg", "wpaperd", "mpvpaper",
        "glpaper", "wbg", "oguri", "linux-wallpaperengine", "gslapper",
    }, LIGHT, out)

    -- ── light: torrent and usenet ──
    -- Sustained disk I/O plus network saturation; usenet unpack and par2 repair also burn
    -- a lot of CPU.
    processes({
        "qbittorrent", "qbittorrent-nox", "transmission-daemon", "transmission-gtk",
        "deluged", "deluge-gtk", "rtorrent", "aria2c", "ktorrent",
        "sabnzbd", "sabnzbdplus", "nzbget",
    }, LIGHT, out)
    units({
        "transmission.service", "qbittorrent-nox.service", "deluged.service",
        "aria2.service", "sabnzbd.service", "nzbget.service",
    }, "system-service", LIGHT, out)

    -- ── light: cloud sync ──
    processes({
        "syncthing", "dropbox", "nextcloud", "insync", "megasync", "onedrive",
        "maestral", "rclone", "seafile-applet", "owncloud",
    }, LIGHT, out)
    units({ "syncthing.service", "onedrive.service" }, "user-service", LIGHT, out)

    -- ── light: backup ──
    processes({ "borg", "restic", "duplicati", "rsnapshot", "kopia" }, LIGHT, out)
    units({
        "borgmatic.timer", "restic-backup.timer", "snapper-timeline.timer",
        "snapper-cleanup.timer", "duplicati.timer",
    }, "system-timer", LIGHT, out)

    -- ── light: file indexers ──
    processes({
        "baloo_file", "baloo_file_extractor", "tracker-miner-fs-3", "tracker-extract-3",
        "recollindex", "updatedb", "plocate",
    }, LIGHT, out)
    units({ "plocate-updatedb.timer", "updatedb.timer", "mlocate.timer" }, "system-timer", LIGHT, out)

    -- ── light: scheduled maintenance ──
    -- Stopping a service does nothing if its timer re-fires it mid-game. fstrim in
    -- particular stalls I/O hard.
    units({
        "fstrim.timer", "smartd.timer", "paccache.timer", "pamac-cleancache.timer",
        "reflector.timer", "archlinux-keyring-wkd-sync.timer", "pacman-filesdb-refresh.timer",
        "systemd-tmpfiles-clean.timer", "man-db.timer", "dnf-makecache.timer",
        "snapd.refresh.timer", "flatpak-system-update.timer", "e2scrub_all.timer",
    }, "system-timer", LIGHT, out)

    -- ── light: distro maintenance timers (Fedora/Debian-adjacent) ──
    -- raid-check is the nasty one: an mdraid check on a laptop spins the disks for
    -- minutes at full I/O. dnf5-automatic, logrotate and unbound-anchor are light but
    -- pointless to run mid-game.
    units({
        "dnf5-automatic.timer", "raid-check.timer", "logrotate.timer",
        "unbound-anchor.timer",
    }, "system-timer", LIGHT, out)

    -- ── light: desktop indexers ──
    -- User-scoped search indexers keep burning CPU and I/O on metadata scans.
    units({ "localsearch-3.service" }, "user-service", LIGHT, out)

    -- ── light: update daemons ──
    units({
        "packagekit.service", "pamac-daemon.service", "snapd.service",
        "unattended-upgrades.service",
    }, "system-service", LIGHT, out)

    -- ── light: AI / LLM runtimes ──
    -- These hold VRAM, which only a real stop releases -- freezing keeps every page
    -- resident. Service-kind only, because process + stop is unrecoverable.
    units({
        "ollama.service", "localai.service", "comfyui.service", "open-webui.service",
    }, "system-service", LIGHT, out)

    -- ── light: antivirus and telemetry ──
    units({
        "clamav-daemon.service", "clamd.service", "clamav-freshclam.service",
    }, "system-service", LIGHT, out)
    units({ "clamav-freshclam.timer", "rkhunter.timer" }, "system-timer", LIGHT, out)
    units({
        "whoopsie.service", "apport.service", "abrtd.service", "teamviewerd.service",
        "anydesk.service",
    }, "system-service", LIGHT, out)

    -- ── light: phone and emulator tooling ──
    processes({ "adb", "scrcpy" }, LIGHT, out)

    -- ── heavy: browsers ──
    -- Usually the single largest consumer of both RAM and CPU. Frozen, not killed: nobody
    -- wants their tabs gone when they quit a game.
    processes({
        "brave", "chrome", "google-chrome", "chromium", "firefox", "librewolf",
        "vivaldi-bin", "opera", "microsoft-edge", "thorium", "zen-browser", "waterfox",
        "qutebrowser", "helium",
    }, HEAVY, out)

    -- ── heavy: editors, language servers, builds ──
    -- `java`, `dotnet` and `node` are deliberately absent: they are game runtimes as well
    -- as build tools. Minecraft and every PrismLauncher instance run as `java`, Unity and
    -- .NET titles as `dotnet` -- freezing them would freeze the game.
    processes({
        "code", "codium", "code-oss", "cursor", "zed", "idea", "pycharm", "webstorm",
        "clion", "goland", "rider", "rustrover", "android-studio", "sublime_text",
    }, HEAVY, out)
    processes({
        "rust-analyzer", "gopls", "clangd", "pylsp", "pyright",
        "typescript-language-server", "jdtls", "lua-language-server", "omnisharp", "ccls",
    }, HEAVY, out)
    processes({
        "cargo", "rustc", "gradle", "tsc", "webpack", "vite", "esbuild", "ninja", "make",
        "cc1plus", "ccache", "sccache", "distccd",
    }, HEAVY, out)
    processes({ "claude", "opencode", "codex", "aider" }, HEAVY, out)

    -- ── heavy: CI runners ──
    units({
        "gitlab-runner.service", "buildkite-agent.service", "jenkins.service",
    }, "system-service", HEAVY, out)

    -- ── heavy: container engines ──
    -- Docker only: stopping the daemon stops every container. Containers running game
    -- servers would need an explicit target, and a freeze would leave the daemon stuck
    -- with paused workloads.
    units({ "docker.service" }, "system-service", HEAVY, out)

    -- ── heavy: self-hosted media stack ──
    units({
        "sonarr.service", "radarr.service", "lidarr.service", "readarr.service",
        "prowlarr.service", "bazarr.service", "jackett.service", "jellyseerr.service",
        "overseerr.service", "ombi.service", "tautulli.service",
    }, "system-service", HEAVY, out)
    units({
        "jellyfin.service", "plexmediaserver.service", "emby-server.service",
        "audiobookshelf.service", "navidrome.service", "komga.service", "kavita.service",
        "photoprism.service", "calibre-server.service",
    }, "system-service", HEAVY, out)

    -- ── heavy: JVM databases ──
    -- Multi-gigabyte heaps. Other databases (postgres, mysql, redis) are omitted because
    -- other services depend on them.
    units({ "elasticsearch.service", "opensearch.service" }, "system-service", HEAVY, out)

    return out
end

M.DEFAULT_TARGETS = buildDefaults()

-- Every match string is interpolated into a shell command, so control characters are
-- refused outright rather than escaped.
local function validateShellValue(value)
    if type(value) ~= "string" or value == "" or value:find("[\n\r%z]") then
        return nil
    end
    return value
end

M.validateShellValue = validateShellValue

-- validEntry returns ok plus a human reason, so parseTargets can tell the user which of
-- their entries was dropped and why rather than only how many.
local function validEntry(entry)
    if type(entry) ~= "table" then
        return false, "not an object"
    end
    if not VALID_KINDS[entry.kind] then
        return false, "unknown kind " .. tostring(entry.kind)
    end
    if not validateShellValue(entry.match) then
        return false, "match is empty or contains a control character"
    end
    if M.isDenied(entry.match) then
        return false, "'" .. entry.match .. "' is protected and can never be suspended"
    end
    -- `systemctl is-active fstrim` resolves to fstrim.service, so a timer target that does
    -- not name its unit would silently act on the wrong one.
    if TIMER_KINDS[entry.kind] and entry.match:lower():sub(-6) ~= ".timer" then
        return false, "timer target '" .. entry.match .. "' must name a .timer unit"
    end
    if entry.action ~= nil and not VALID_ACTIONS[entry.action] then
        return false, "unknown action " .. tostring(entry.action)
    end
    if entry.action == "freeze" and TIMER_KINDS[entry.kind] then
        return false, "a timer cannot be frozen, only stopped"
    end
    if type(entry.profiles) ~= "table" or #entry.profiles == 0 then
        return false, "profiles must be a non-empty array"
    end
    for _, profile in ipairs(entry.profiles) do
        if type(profile) ~= "string" or profile == "" then
            return false, "profile names must be non-empty strings"
        end
    end
    return true
end

local function copyTargets(list)
    local out = {}
    for index, entry in ipairs(list) do
        local profiles = {}
        for profileIndex, profile in ipairs(entry.profiles) do
            profiles[profileIndex] = profile
        end
        out[index] = {
            match = entry.match,
            kind = entry.kind,
            action = entry.action,
            profiles = profiles,
        }
    end
    return out
end

-- parseTargets decodes the `targets` setting, dropping individual invalid entries.
-- An unset, unparseable or wholly invalid setting falls back to DEFAULT_TARGETS so a
-- typo can never leave gamer mode with an empty kill list and no explanation.
function M.parseTargets(raw)
    if type(raw) == "string" and raw ~= "" then
        local decoded, decodeError = noctalia.json.decode(raw)
        if type(decoded) ~= "table" then
            noctalia.log("gamermode: ignoring invalid targets setting: " .. tostring(decodeError or "not a JSON array"))
        else
            local out = {}
            for _, entry in ipairs(decoded) do
                local ok, reason = validEntry(entry)
                if ok then
                    out[#out + 1] = {
                        match = entry.match,
                        kind = entry.kind,
                        action = entry.action,
                        profiles = entry.profiles,
                    }
                else
                    noctalia.log("gamermode: dropped target: " .. tostring(reason))
                end
            end
            if #out > 0 then
                -- Allowed, but the user should know it is a one-way trip.
                for _, entry in ipairs(out) do
                    if entry.kind == "process" and M.actionOf(entry) == "stop" then
                        noctalia.log(
                            "gamermode: '" .. entry.match .. "' is a process with action=stop, which is "
                                .. "unrecoverable -- a bare process has no argv to relaunch from. "
                                .. "Use action=freeze, or target the unit that supervises it."
                        )
                    end
                end
                return copyTargets(out)
            end
            noctalia.log("gamermode: targets setting had no usable entries, using defaults")
        end
    end
    return copyTargets(M.DEFAULT_TARGETS)
end

-- summarizeTargets reports how a `targets` setting fared before it is applied, so the
-- panel can show the user which of their entries were dropped and why -- a typo that
-- silently vanishes into the default list is precisely the config error worth surfacing.
-- Pure and free of shell calls, so it can be unit-tested.
function M.summarizeTargets(raw)
    local result = { total = 0, dropped = {} }
    if type(raw) == "string" and raw ~= "" then
        local decoded, decodeError = noctalia.json.decode(raw)
        if type(decoded) == "table" then
            result.total = #decoded
            result.parseError = nil
            for _, entry in ipairs(decoded) do
                local ok, reason = validEntry(entry)
                if not ok then
                    local match = type(entry) == "table" and tostring(entry.match) or "?"
                    result.dropped[#result.dropped + 1] = { match = match, reason = tostring(reason) }
                end
            end
        else
            result.parseError = tostring(decodeError or "not a JSON array")
        end
    end
    return result
end

function M.targetsForProfile(targets, profile)
    local out = {}
    for _, target in ipairs(targets) do
        for _, tagged in ipairs(target.profiles) do
            if tagged == profile then
                out[#out + 1] = target
                break
            end
        end
    end
    return out
end

-- ── shell commands per target kind ──

-- shellQuote returns nil for anything that cannot be represented safely, and every
-- command builder propagates that nil rather than emitting a half-quoted command.
local function shellQuote(value)
    if not validateShellValue(value) then
        return nil
    end
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

M.shellQuote = shellQuote

-- safeMatch is the single choke point for shell interpolation: it refuses protected
-- targets and anything that cannot be quoted. Builders return nil rather than emitting a
-- command, so a denied entry surviving in an old session file still cannot act.
local function safeMatch(target)
    if M.isDenied(target.match) then
        noctalia.log("gamermode: refusing to act on protected target " .. tostring(target.match))
        return nil
    end
    return shellQuote(target.match)
end

-- Probes read state only, so none of them needs elevation -- `systemctl is-active`
-- works unprivileged even for system units.
function M.probeCmd(target)
    local match = safeMatch(target)
    if not match then
        return nil
    end
    if target.kind == "process" then
        return "pgrep -x " .. match
    elseif target.kind == "user-service" or target.kind == "user-timer" then
        return "systemctl --user is-active " .. match
    elseif target.kind == "system-service" or target.kind == "system-timer" then
        return "systemctl is-active " .. match
    elseif target.kind == "container" then
        return "docker inspect -f '{{.State.Running}}' " .. match
    end
    return nil
end

-- Changing a system unit needs authorisation, and systemctl already knows how to ask for
-- it: the call goes over D-Bus, systemd asks polkit, and polkit asks the desktop's
-- authentication agent to prompt. `org.freedesktop.systemd1.manage-units` resolves to
-- auth_admin_keep for an active local session, so an administrator is prompted once and
-- the answer is cached for the rest of the batch.
--
-- This is why none of the builders below shell out to sudo. `sudo -n` cannot prompt at
-- all, so on any machine without a NOPASSWD rule -- which is most of them -- every system
-- target failed and gamer mode quietly did a fraction of its job.
--
-- Callers must route these through the privileged lane: see needsPrivilege.
function M.needsPrivilege(kind)
    return kind == "system-service" or kind == "system-timer"
end

function M.stopCmd(target)
    local match = safeMatch(target)
    if not match then
        return nil
    end
    if target.kind == "process" then
        return "pkill -x " .. match
    elseif target.kind == "user-service" or target.kind == "user-timer" then
        return "systemctl --user stop " .. match
    elseif target.kind == "system-service" or target.kind == "system-timer" then
        return "systemctl stop " .. match
    elseif target.kind == "container" then
        return "docker stop " .. match
    end
    return nil
end

-- Processes have no generic start: a bare process name carries no argv, environment or
-- working directory, so gamer mode cannot honestly relaunch one. Users who need a
-- process brought back should target the unit that supervises it instead.
function M.startCmd(target)
    local match = safeMatch(target)
    if not match then
        return nil
    end
    if target.kind == "user-service" or target.kind == "user-timer" then
        return "systemctl --user start " .. match
    elseif target.kind == "system-service" or target.kind == "system-timer" then
        return "systemctl start " .. match
    elseif target.kind == "container" then
        return "docker start " .. match
    end
    return nil
end

-- actionOf normalises the optional `action` field. Absent means "stop", which keeps every
-- pre-existing config and session file meaning exactly what it did before.
function M.actionOf(target)
    return target.action == "freeze" and "freeze" or "stop"
end

-- Authorising system units once, rather than once per unit.
--
-- Two approaches were measured on a live machine and both cost one password prompt per
-- unit -- seven units, seven dialogs:
--
--   * one `systemctl` process per unit. polkit's auth_admin_keep retains an authorisation
--     against the subject that gave it, and the subject systemd reports is the calling
--     process, so seven processes are seven subjects with nothing to reuse.
--   * one `systemctl` process naming all seven units. systemctl issues its StopUnit calls
--     in parallel, so all seven polkit checks are outstanding before any of them has an
--     answer, and again none can reuse a retained authorisation.
--
-- pkexec authorises the exec itself, once, and systemd performs no polkit check at all for
-- a caller running as root. That makes one dialog a property of the design rather than a
-- hoped-for cache hit. org.freedesktop.policykit.exec is auth_admin with no keep, so each
-- pkexec prompts -- which is why a verb's units all go in one invocation. The built-in
-- targets only ever stop system units, never freeze them, so an enable and a disable are
-- one prompt each; a config that mixes both verbs pays one per verb.
--
-- Batching costs per-unit exit codes. It is affordable because nothing depends on them:
-- the snapshot records what a target was doing before, not whether its stop returned zero,
-- and restore probes live state rather than trusting a recorded outcome. systemctl still
-- names each unit it could not act on, and that stderr is logged whole.
local BATCH_ARGS = {
    stop = "stop",
    start = "start",
    freeze = "kill --kill-whom=all -s SIGSTOP",
    thaw = "kill --kill-whom=all -s SIGCONT",
}

-- pkexec resolves a bare program name against a sanitised PATH, so the absolute path is
-- the dependable form. init() replaces these from the live system.
M.systemctlPath = "/usr/bin/systemctl"
M.canElevate = true

local function batchPrefix(verb)
    local args = BATCH_ARGS[verb]
    if not args then
        return nil
    end
    if not M.canElevate then
        -- No pkexec: fall back to asking systemd directly. It still works, at the cost of
        -- the prompt-per-unit behaviour described above.
        return "systemctl " .. args
    end
    return "pkexec " .. M.systemctlPath .. " " .. args
end

-- Timers have no process to signal, so they can only be stopped and started.
local function batchable(verb, kind)
    if not M.needsPrivilege(kind) then
        return false
    end
    if verb == "freeze" or verb == "thaw" then
        return kind == "system-service"
    end
    return true
end

-- Returns the batched command and the targets it covers, so the caller can report against
-- exactly what went in. Targets refused by safeMatch are left out of both.
function M.batchCmd(verb, targets)
    local prefix = batchPrefix(verb)
    if not prefix then
        return nil, {}
    end
    local quoted, covered = {}, {}
    for _, target in ipairs(targets) do
        if batchable(verb, target.kind) then
            local match = safeMatch(target)
            if match then
                quoted[#quoted + 1] = match
                covered[#covered + 1] = target
            end
        end
    end
    if #quoted == 0 then
        return nil, {}
    end
    return prefix .. " " .. table.concat(quoted, " "), covered
end

-- freeze suspends a target in place: SIGSTOP for processes and units, docker pause for
-- containers. Unlike stop it is perfectly reversible and loses no state, which makes it
-- the right action for anything the user might return to -- a browser, an editor, an
-- animated wallpaper daemon.
--
-- renice was measured and rejected as the reversible option: with RLIMIT_NICE=0 an
-- unprivileged process can lower priority but never raise it back, so it would
-- permanently degrade anything it touched.
function M.freezeCmd(target)
    local match = safeMatch(target)
    if not match then
        return nil
    end
    if target.kind == "process" then
        return "pkill -STOP -x " .. match
    elseif target.kind == "user-service" then
        -- --kill-whom=all is explicit because `systemctl kill --help` does not state its
        -- default, and freezing a unit must reach every process in its cgroup.
        return "systemctl --user kill --kill-whom=all -s SIGSTOP " .. match
    elseif target.kind == "system-service" then
        return "systemctl kill --kill-whom=all -s SIGSTOP " .. match
    elseif target.kind == "container" then
        -- docker pause is the cgroup freezer: an exact match for freeze semantics.
        return "docker pause " .. match
    end
    -- Timer kinds fall through: there is no process to signal.
    return nil
end

function M.thawCmd(target)
    local match = safeMatch(target)
    if not match then
        return nil
    end
    if target.kind == "process" then
        return "pkill -CONT -x " .. match
    elseif target.kind == "user-service" then
        return "systemctl --user kill --kill-whom=all -s SIGCONT " .. match
    elseif target.kind == "system-service" then
        return "systemctl kill --kill-whom=all -s SIGCONT " .. match
    elseif target.kind == "container" then
        return "docker unpause " .. match
    end
    return nil
end

-- wasState maps probe stdout to the state recorded in the snapshot. Only "running" and
-- "active" count as up; everything else -- including transitional states and any output
-- that could not be read -- is "down", so nothing gets restarted on a guess.
function M.wasState(kind, output)
    local text = (tostring(output or "")):gsub("%s+", "")
    if kind == "process" then
        return text ~= "" and "running" or "down"
    elseif kind == "container" then
        return text == "true" and "running" or "down"
    end
    return text == "active" and "active" or "down"
end

-- ── session snapshot ──

local SNAPSHOT_VERSION = 1
local UP_STATES = { running = true, active = true }

local function snapshotPath()
    local directory = noctalia.pluginDataDir()
    if not directory then
        return nil
    end
    return directory .. "/session.json"
end

-- The kernel boot id changes on every boot, which makes it an exact staleness marker for a
-- session file. More reliable than inferring staleness from live state: a frozen process
-- still appears in pgrep, so "is everything running again?" false-positives on every freeze
-- target.
function M.currentBootId()
    local contents = noctalia.readFile("/proc/sys/kernel/random/boot_id")
    if not contents then
        return nil
    end
    local id = contents:gsub("%s+", "")
    return id ~= "" and id or nil
end

function M.buildSnapshot(profile, powerProfileBefore, probedTargets, wallpaperAutomationBefore, decorBefore)
    return {
        version = SNAPSHOT_VERSION,
        profile = profile,
        power_profile_before = powerProfileBefore,
        wallpaper_automation_before = wallpaperAutomationBefore,
        boot_id = M.currentBootId(),
        targets = probedTargets,
        decor_before = decorBefore,
    }
end

-- restorePlan answers "which stopped targets may be started again?". A target qualifies
-- only if it was up when gamer mode began and is still down now: that keeps a manual
-- restart from being stomped and keeps something that was already off from being started.
-- `stateOf` returns the live state string, or nil when it could not be determined -- in
-- which case the target is left alone.
--
-- Freeze targets are deliberately excluded; they go through thawPlan, which needs no
-- probe at all.
function M.restorePlan(snap, stateOf)
    local plan = {}
    for _, target in ipairs((snap and snap.targets) or {}) do
        if UP_STATES[target.was] and M.actionOf(target) == "stop" and stateOf(target.match) == "down" then
            plan[#plan + 1] = target
        end
    end
    return plan
end

-- thawPlan returns every frozen target, with no live check. A frozen process still shows
-- up in pgrep, so there is no probe that could distinguish "still frozen" from "running",
-- and SIGCONT to a process that is not stopped is a verified no-op. Thawing
-- unconditionally is therefore both simpler and strictly safer: it cannot misread a
-- state, cannot stomp a manual restart, and cannot leave something frozen because a probe
-- failed to start.
function M.thawPlan(snap)
    local plan = {}
    for _, target in ipairs((snap and snap.targets) or {}) do
        if UP_STATES[target.was] and M.actionOf(target) == "freeze" then
            plan[#plan + 1] = target
        end
    end
    return plan
end

local function validSnapshotTarget(entry)
    return type(entry) == "table"
        and validateShellValue(entry.match) ~= nil
        and VALID_KINDS[entry.kind] ~= nil
        and type(entry.was) == "string"
        and (entry.action == nil or VALID_ACTIONS[entry.action] == true)
end

function M.writeSnapshot(snap)
    local path = snapshotPath()
    if not path then
        noctalia.log("gamermode: no plugin data dir, cannot persist the session")
        return false
    end

    local encoded, encodeError = noctalia.json.encode(snap)
    if not encoded then
        noctalia.log("gamermode: could not encode the session: " .. tostring(encodeError))
        return false
    end

    noctalia.mkdirAll(noctalia.pluginDataDir())
    -- Write-then-rename: a shell crash mid-write must not leave a half-written session
    -- that would be read back as "no session" while targets are still suspended.
    local temporary = path .. ".tmp"
    if not noctalia.writeFile(temporary, encoded) then
        noctalia.log("gamermode: could not write the session file")
        return false
    end
    if not noctalia.renameFile(temporary, path) then
        noctalia.removeFile(temporary)
        noctalia.log("gamermode: could not replace the session file")
        return false
    end
    return true
end

-- readSnapshot returns nil for anything it cannot trust. Callers treat nil as "gamer
-- mode is off", which is the safe reading: it never invents targets to restart.
function M.readSnapshot()
    local path = snapshotPath()
    if not path then
        return nil
    end
    local contents = noctalia.readFile(path)
    if not contents then
        return nil
    end

    local decoded, decodeError = noctalia.json.decode(contents)
    if type(decoded) ~= "table" then
        noctalia.log("gamermode: ignoring unreadable session file: " .. tostring(decodeError or "not an object"))
        return nil
    end
    if decoded.version ~= SNAPSHOT_VERSION then
        noctalia.log("gamermode: ignoring session file with version " .. tostring(decoded.version))
        return nil
    end
    if type(decoded.targets) ~= "table" then
        noctalia.log("gamermode: ignoring session file without a target list")
        return nil
    end

    -- Keep the entries that are still usable rather than discarding the whole session:
    -- dropping it would report gamer mode as off while targets stay suspended.
    local targets = {}
    local dropped = 0
    for _, entry in ipairs(decoded.targets) do
        if validSnapshotTarget(entry) then
            targets[#targets + 1] = {
                match = entry.match,
                kind = entry.kind,
                action = entry.action,
                was = entry.was,
            }
        else
            dropped = dropped + 1
        end
    end
    if dropped > 0 then
        noctalia.log("gamermode: dropped " .. dropped .. " unusable entries from the session file")
    end

    return {
        version = decoded.version,
        profile = type(decoded.profile) == "string" and decoded.profile or "light",
        power_profile_before = type(decoded.power_profile_before) == "string" and decoded.power_profile_before or nil,
        wallpaper_automation_before = type(decoded.wallpaper_automation_before) == "boolean" and decoded.wallpaper_automation_before or nil,
        boot_id = type(decoded.boot_id) == "string" and decoded.boot_id or nil,
        targets = targets,
        decor_before = type(decoded.decor_before) == "table" and decoded.decor_before or nil,
    }
end

function M.deleteSnapshot()
    local path = snapshotPath()
    if path then
        noctalia.removeFile(path)
    end
end

-- ── runtime ──

local COMMAND_TIMEOUT_MS = 10000
-- A privileged command can sit at a polkit password dialog. Ten seconds is not enough time
-- to read a prompt and type a password, and a timeout there kills the command mid-dialog.
local PRIVILEGED_TIMEOUT_MS = 120000
local DEFAULT_POLL_SECONDS = 3

local busy = false
local lastHandledNonce = 0
local powerState = { available = false, profiles = {} }

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The shell caps how many child processes may be in flight at once (8 in the build this
-- was written against) and runAsync refuses rather than queueing once that cap is hit.
-- Fanning the whole target list out in one pass therefore loses every command past the
-- eighth, and a probe that never ran reads as "down" -- so enable would record an idle
-- machine and suspend nothing. Commands go through a queue instead, a few at a time.
--
-- The cap is shared with the rest of the shell, so a refusal does not always mean our own
-- slots are full. Staying well under it leaves room for other plugins and makes a refusal
-- rare enough to treat as transient.
local MAX_IN_FLIGHT = 4

-- Privileged commands run one at a time. Polkit caches an administrator's answer, but only
-- once it has one: firing four at a shell with no cached authorisation races four password
-- dialogs onto the screen. Serialised, the first prompts and the rest ride the cache.
local lanes = {
    default = { queued = {}, inFlight = 0, limit = MAX_IN_FLIGHT, timeoutMs = COMMAND_TIMEOUT_MS },
    privileged = { queued = {}, inFlight = 0, limit = 1, timeoutMs = PRIVILEGED_TIMEOUT_MS },
}
local pumping = false
-- Across both lanes, because the shell's cap is global: whether a refusal is worth waiting
-- out depends on anything of ours still running, not just this lane.
local totalInFlight = 0
local pump

-- Returns whether it disposed of anything, which is what tells the caller a second round
-- is worth attempting rather than spinning.
local function pumpLane(lane)
    local progressed = false
    while lane.inFlight < lane.limit and #lane.queued > 0 do
        local job = table.remove(lane.queued, 1)
        lane.inFlight = lane.inFlight + 1
        totalInFlight = totalInFlight + 1
        local started = noctalia.runAsync(job.command, function(result)
            lane.inFlight = lane.inFlight - 1
            totalInFlight = totalInFlight - 1
            job.callback(result)
            pump()
        end, lane.timeoutMs)
        if not started then
            lane.inFlight = lane.inFlight - 1
            totalInFlight = totalInFlight - 1
            if totalInFlight > 0 then
                -- Something is still running and will pump again when it finishes, so the
                -- job keeps its place rather than being reported as a failure.
                table.insert(lane.queued, 1, job)
                return progressed
            end
            -- Nothing is running to trigger a later pump. update() retries the queues on
            -- the poll tick, but this job has waited long enough to answer now.
            noctalia.log("gamermode: could not start command: " .. job.command)
            job.callback(nil)
        end
        progressed = true
    end
    return progressed
end

-- A command that completes synchronously calls back into pump from inside pumpLane.
-- Letting that recurse would nest one stack frame per queued command and overflow on a
-- full target list, so the outer call keeps ownership of both queues.
pump = function()
    if pumping then
        return
    end
    pumping = true
    -- Rounds, not one pass: a callback firing inside pumpLane can queue work for the lane
    -- that was already visited this pass -- probes finishing is exactly what queues the
    -- suspends -- and its own pump() call was swallowed by the guard above. Without the
    -- loop that work sits in the queue with nothing left to start it.
    local progressed = true
    while progressed do
        -- Privileged first: it is the lane that may block on a password dialog, so it
        -- should be waiting on the human rather than on our own bookkeeping.
        progressed = pumpLane(lanes.privileged)
        progressed = pumpLane(lanes.default) or progressed
    end
    pumping = false
end

-- run always invokes `callback` exactly once. A command that could not be built or
-- could not be started yields nil, which every caller reads as "state unknown" -- so a
-- busy shell degrades into doing nothing rather than into a wrong decision.
local function run(command, callback, privileged)
    if not command then
        callback(nil)
        return
    end
    local lane = privileged and lanes.privileged or lanes.default
    lane.queued[#lane.queued + 1] = { command = command, callback = callback }
    pump()
end

local function succeeded(result)
    return result ~= nil and result.exitCode == 0
end

local function describeFailure(result)
    if result == nil then
        return "command did not start"
    end
    local stderr = trim(result.stderr)
    if stderr ~= "" then
        return stderr
    end
    if result.timedOut then
        return "timed out"
    end
    return "exit code " .. tostring(result.exitCode)
end

local VALID_PROFILES = { light = true, heavy = true }

local function configuredProfile()
    local profile = noctalia.getConfig("profile")
    return profile == "heavy" and "heavy" or "light"
end

-- resolveProfile lets a command name the profile to apply for one session. The panel needs
-- this because a plugin reads its own settings and cannot write them, so choosing a profile
-- in the panel has to travel with the enable rather than change the setting.
local function resolveProfile(override)
    if override == nil then
        return configuredProfile()
    end
    if VALID_PROFILES[override] then
        return override
    end
    noctalia.log("gamermode: ignoring unknown profile " .. tostring(override))
    return configuredProfile()
end

local function autoPerformance()
    return noctalia.getConfig("auto_performance") ~= false
end

-- ── power profiles ──

-- parsePowerProfiles reads `powerprofilesctl list`, whose entries are lines like
-- "* balanced:" (the leading star marks the active one) followed by indented details.
function M.parsePowerProfiles(text)
    local profiles = {}
    local active = nil
    for line in tostring(text or ""):gmatch("[^\n]+") do
        local star, name = line:match("^%s*(%*?)%s*([%w][%w%-_]*):%s*$")
        if name then
            profiles[#profiles + 1] = name
            if star == "*" then
                active = name
            end
        end
    end
    return profiles, active
end

local function publishPower()
    noctalia.state.set("power", powerState)
end

local function powerSupports(profile)
    for _, candidate in ipairs(powerState.profiles) do
        if candidate == profile then
            return true
        end
    end
    return false
end

-- refreshPower republishes the power group and hands the active profile to `done`.
-- Without powerprofilesctl the group is marked unavailable and `done` receives nil, so
-- gamer mode still runs -- it just does not switch profiles.
function M.refreshPower(done)
    done = done or function() end
    if not noctalia.commandExists("powerprofilesctl") then
        powerState = { available = false, profiles = {} }
        publishPower()
        done(nil)
        return
    end
    run("powerprofilesctl list", function(result)
        local profiles, active = M.parsePowerProfiles(succeeded(result) and result.stdout or "")
        powerState = { available = true, profiles = profiles, active = active }
        publishPower()
        done(active)
    end)
end

function M.setPowerProfile(profile)
    if not powerState.available then
        noctalia.log("gamermode: powerprofilesctl is unavailable")
        return
    end
    if type(profile) ~= "string" or not powerSupports(profile) then
        noctalia.log("gamermode: refusing unsupported power profile " .. tostring(profile))
        return
    end
    run("powerprofilesctl set " .. shellQuote(profile), function(result)
        if not succeeded(result) then
            noctalia.log("gamermode: could not set the power profile: " .. describeFailure(result))
        end
        M.refreshPower()
    end)
end

-- ── published state ──

function M.publishMetrics()
    local metrics = M.normalize(noctalia.systemStats())
    if metrics then
        metrics.available = true
    else
        -- No system monitor: say so rather than publishing zeroes that read as real
        -- idle readings.
        metrics = { available = false, gpuAvailable = false }
    end
    noctalia.state.set("metrics", metrics)
end

M.pollMetrics = M.publishMetrics

-- publishGameMode derives the whole UI-visible state from the session file, so a shell
-- restart mid-session still shows gamer mode as on with the right suspend list.
function M.publishGameMode()
    local snap = M.readSnapshot()
    local suspended = {}
    if snap then
        for _, target in ipairs(snap.targets) do
            if UP_STATES[target.was] then
                suspended[#suspended + 1] = {
                    match = target.match,
                    kind = target.kind,
                    action = M.actionOf(target),
                }
            end
        end
    end
    noctalia.state.set("game_mode", {
        enabled = snap ~= nil,
        busy = busy,
        profile = snap and snap.profile or configuredProfile(),
        suspended = suspended,
        power_profile_before = snap and snap.power_profile_before or nil,
    })
    M.publishTargetsStatus()
end

-- publishTargetsStatus surfaces how the `targets` setting parses, so the panel can flag
-- entries that were dropped (and why) instead of the user finding out that gamer mode
-- quietly fell back to the defaults.
function M.publishTargetsStatus()
    noctalia.state.set("targets_status", M.summarizeTargets(noctalia.getConfig("targets")))
end

-- ── wallpaper automation pause ──
--
-- Noctalia can cycle the wallpaper while gamer mode is on. There is no command to pause
-- that, so the toggle edits `[wallpaper.automation].enabled` in the Noctalia settings file
-- directly. The value that was in place when gamer mode turned on is recorded in the
-- session snapshot so disable restores it exactly, whatever it was.

function M.settingsTomlPath()
    return noctalia.expandPath("~") .. "/.local/state/noctalia/settings.toml"
end

-- applyAutomationEnabled rewrites `enabled` inside the `[wallpaper.automation]` section of
-- a settings.toml text. Only that section is touched; a same-named key in any other
-- section is left alone. Returns the new text, or nil when the section is not present.
function M.applyAutomationEnabled(text, enabled)
    if type(text) ~= "string" then
        return nil
    end
    local wanted = enabled and "true" or "false"
    local lines = {}
    local inSection = false
    local changed = false
    local index = 1
    for line in text:gmatch("([^\n]*)\n?") do
        local section = line:match("^%s*%[([^%]]*)%]%s*$")
        if section ~= nil then
            inSection = trim(section) == "wallpaper.automation"
        end
        if inSection then
            local indent, key, value = line:match("^(%s*)([%w_]+)%s*=%s*(%w+)%s*$")
            if indent ~= nil and key == "enabled" and (value == "true" or value == "false") then
                if value ~= wanted then
                    line = indent .. key .. " = " .. wanted
                    changed = true
                end
                -- `enabled` is unique in the section; stop editing further lines.
                inSection = false
            end
        end
        lines[index] = line
        index = index + 1
    end
    if not changed then
        return nil
    end
    return table.concat(lines, "\n")
end

-- readWallpaperAutomation returns the live `[wallpaper.automation].enabled` value, or nil
-- when the file or the section is missing (treated as "not automated", so enable records
-- nothing to restore).
function M.readWallpaperAutomation()
    local contents = noctalia.readFile(M.settingsTomlPath())
    if not contents then
        return nil
    end
    local inSection = false
    for line in contents:gmatch("([^\n]*)\n?") do
        local section = line:match("^%s*%[([^%]]*)%]%s*$")
        if section ~= nil then
            inSection = trim(section) == "wallpaper.automation"
        elseif inSection then
            local value = line:match("^%s*enabled%s*=%s*(%w+)%s*$")
            if value ~= nil and (value == "true" or value == "false") then
                return value == "true"
            end
        end
    end
    return nil
end

-- setWallpaperAutomation rewrites the file. Returns false when the file cannot be read or
-- the section is absent (we never invent a `[wallpaper.automation]` section).
function M.setWallpaperAutomation(enabled)
    local contents = noctalia.readFile(M.settingsTomlPath())
    if not contents then
        return false
    end
    local updated = M.applyAutomationEnabled(contents, enabled)
    if not updated then
        return false
    end
    return noctalia.writeFile(M.settingsTomlPath(), updated) == true
end

-- ── enable ──

-- probeAll fans out one probe per target and reports once every answer is in. Results
-- keep the configured target order so snapshots are stable across runs.
local function probeAll(targets, done)
    local slots = {}
    local pending = #targets
    if pending == 0 then
        done({})
        return
    end

    local function settle()
        if pending > 0 then
            return
        end
        local probed = {}
        for index = 1, #targets do
            if slots[index] then
                probed[#probed + 1] = slots[index]
            end
        end
        done(probed)
    end

    for index, target in ipairs(targets) do
        local command = M.probeCmd(target)
        if not command then
            noctalia.log("gamermode: skipping unusable target " .. tostring(target.match))
            pending = pending - 1
            settle()
        else
            run(command, function(result)
                slots[index] = {
                    match = target.match,
                    kind = target.kind,
                    action = M.actionOf(target),
                    was = M.wasState(target.kind, result and result.stdout),
                }
                pending = pending - 1
                settle()
            end)
        end
    end
end

-- suspendAll suspends every target that was up, using each target's own action. A failure
-- is logged and the flow continues: a missing NOPASSWD rule for one system unit must not
-- abandon the rest.
local function suspendAll(probed, done)
    local jobs = {}

    -- System units go out in one invocation per verb, so the user answers one prompt
    -- rather than one per unit. Everything else stays per-target: pkill and docker need
    -- no authorisation, so batching them would only blur which one failed.
    local grouped = { freeze = {}, stop = {} }
    local loose = {}
    for _, entry in ipairs(probed) do
        if UP_STATES[entry.was] then
            local action = M.actionOf(entry)
            if batchable(action, entry.kind) then
                table.insert(grouped[action], entry)
            else
                table.insert(loose, { entry = entry, action = action })
            end
        end
    end

    for verb, entries in pairs(grouped) do
        local command, covered = M.batchCmd(verb, entries)
        if command then
            jobs[#jobs + 1] = { command = command, action = verb, entries = covered, privileged = true }
        end
    end
    for _, item in ipairs(loose) do
        local command = item.action == "freeze" and M.freezeCmd(item.entry) or M.stopCmd(item.entry)
        if command then
            jobs[#jobs + 1] = { command = command, action = item.action, entries = { item.entry } }
        else
            noctalia.log("gamermode: no " .. item.action .. " command for " .. tostring(item.entry.match))
        end
    end

    local pending = #jobs
    if pending == 0 then
        done(0)
        return
    end
    local suspended = 0
    for _, job in ipairs(jobs) do
        run(job.command, function(result)
            if succeeded(result) then
                suspended = suspended + #job.entries
            else
                local names = {}
                for _, entry in ipairs(job.entries) do
                    names[#names + 1] = entry.match
                end
                noctalia.log(
                    "gamermode: could not " .. job.action .. " " .. table.concat(names, ", ")
                        .. ": " .. describeFailure(result)
                )
            end
            pending = pending - 1
            if pending == 0 then
                done(suspended)
            end
        end, job.privileged)
    end
end

-- ── boost ──
--
-- The "one button" half of gamer mode: alongside suspending background hogs and the
-- power profile switch, enabling gamer mode can also strip Hyprland's decorations and
-- animations for maximum FPS, and disable restores them. These mirror the old
-- toggle-boost-mode.sh, now folded into the plugin so Super+Shift+B drives everything.
--
-- The restore half is not hardcoded to "default" values. The first time gamer mode is
-- enabled the current value of every option the boost touches is read and stored in the
-- session snapshot, so disable hands the desktop back exactly the user's own style --
-- whatever it is -- instead of resetting it to stock Hyprland.
local function luaNumber(value)
    local number = tonumber(value)
    return number
end

-- gapValue normalises the "top right bottom left" CSS string from `hyprctl getoption` into
-- an object Hyprland's eval accepts. Equal values collapse to a plain number for
-- readability; uneven values round-trip as an explicit table.
local function gapValue(css)
    local numbers = {}
    for part in tostring(css or ""):gmatch("%S+") do
        local n = tonumber(part)
        if n then
            numbers[#numbers + 1] = n
        end
    end
    if #numbers == 0 then
        return nil
    end
    if #numbers == 1 or (numbers[1] == numbers[2] and numbers[2] == numbers[3] and numbers[3] == numbers[4]) then
        return numbers[1]
    end
    return { top = numbers[1], right = numbers[2], bottom = numbers[3], left = numbers[4] }
end

-- The option names the boost reads before it strips the desktop, keyed to the value it
-- rewrites so the snapshot can restore the exact style. gaps_in/out are stored as CSS and
-- collapsed by gapValue on restore.
local DECOR_SNAPSHOT = {
    { option = "animations:enabled",         to = "animations_enabled" },
    { option = "decoration:rounding",        to = "rounding" },
    { option = "general:border_size",        to = "border_size" },
    { option = "general:gaps_in",            to = "gaps_in",      css = true },
    { option = "general:gaps_out",           to = "gaps_out",     css = true },
    { option = "decoration:active_opacity",  to = "active_opacity" },
    { option = "decoration:inactive_opacity", to = "inactive_opacity" },
    { option = "decoration:fullscreen_opacity", to = "fullscreen_opacity" },
    { option = "decoration:blur:enabled",    to = "blur_enabled" },
    { option = "decoration:blur:size",       to = "blur_size" },
    { option = "decoration:blur:passes",     to = "blur_passes" },
    { option = "decoration:shadow:enabled",  to = "shadow_enabled" },
    { option = "decoration:shadow:range",    to = "shadow_range" },
}

-- getoptionCmd builds the `hyprctl getoption` command. Hyprland expects the option as a
-- single colon-joined token (`animations:enabled`), not space-separated segments. The
-- option comes from the fixed DECOR_SNAPSHOT list, never the user, so it is safe to
-- embed verbatim.
local function getoptionCmd(option)
    return "hyprctl getoption " .. option
end

-- parseOptionLine reads the value out of one `hyprctl getoption` line -- `int: 12`,
-- `float: 0.7`, `bool: true` or `css gap data: 5 5 5 5` -- returning the raw value plus
-- its type. `getoption` prints a second `set: true` line that must not leak into the
-- value, so only the first line is considered. Kept separate and pure so it can be
-- unit-tested with a host mock.
function M.parseOptionLine(line)
    if type(line) ~= "string" or line == "" then
        return nil
    end
    local first = tostring(line):match("([^\n]+)")
    if not first then
        return nil
    end
    local stringLine = first
    local kind, raw = stringLine:match("^%s*([%w _]+):%s*(.*[^%s])%s*$")
    if not kind then
        return nil
    end
    kind = kind:gsub("^%s+", ""):gsub("%s+$", "")
    return { kind = kind, value = raw }
end

-- snapshotDecor reads every option the boost touches and returns an object of their
-- current values. Only options that could be read are included, so a value Hyprland
-- cannot report falls back to the stock restore value rather than being dropped.
function M.snapshotDecor(done)
    done = done or function() end
    -- The whole batch is best-effort: it runs close to the start of enable and finishes
    -- before anything is suspended, so a single read failure degrades to the stock restore
    -- rather than to a stripped desktop.
    local decor = {}
    local pending = #DECOR_SNAPSHOT
    local settled = false
    local function finish()
        if settled then
            return
        end
        settled = true
        done(decor)
    end
    local function settle()
        if pending > 0 then
            return
        end
        finish()
    end
    for _, spec in ipairs(DECOR_SNAPSHOT) do
        run(getoptionCmd(spec.option), function(result)
            local parsed = M.parseOptionLine(trim(result and result.stdout or ""))
            if parsed then
                local raw = parsed.value
                if spec.css then
                    decor[spec.to] = raw
                elseif parsed.kind == "int" or parsed.kind == "float" then
                    decor[spec.to] = luaNumber(raw)
                elseif parsed.kind == "bool" then
                    decor[spec.to] = raw == "true"
                elseif type(raw) == "string" and raw ~= "" then
                    decor[spec.to] = raw
                end
            end
            pending = pending - 1
            settle()
        end)
    end
end

-- buildBoostOn rebuilds the user's own style from the snapshot. Fields that were read are
-- restored as captured; anything missing (a value Hyprland could not report) uses a stock
-- fallback identical to the historical BOOST_DECOR_ON.
local function luaLiteral(value, fallback)
    if value == nil then
        return tostring(fallback)
    end
    if type(value) == "boolean" then
        return value and "true" or "false"
    end
    return tostring(value)
end

-- gapLiteral turns gaps_in/out (a CSS "top right bottom left" string) into the Lua the
-- eval accepts: a plain number when even, an explicit per-edge table when uneven.
local function gapLiteral(value, fallback)
    local gaps = gapValue(value)
    if gaps == nil then
        return tostring(fallback)
    end
    if type(gaps) == "number" then
        return tostring(gaps)
    end
    return string.format(
        "{ top = %s, right = %s, bottom = %s, left = %s }",
        tostring(gaps.top), tostring(gaps.right), tostring(gaps.bottom), tostring(gaps.left)
    )
end

local function buildBoostOn(decor)
    decor = decor or {}
    local animations = luaLiteral(decor.animations_enabled, true)
    local rounding = luaLiteral(decor.rounding, 12)
    local activeOpacity = luaLiteral(decor.active_opacity, 0.9)
    local inactiveOpacity = luaLiteral(decor.inactive_opacity, 0.7)
    local fullscreenOpacity = luaLiteral(decor.fullscreen_opacity, 0.9)
    local blurEnabled = luaLiteral(decor.blur_enabled, true)
    local blurSize = luaLiteral(decor.blur_size, 3)
    local blurPasses = luaLiteral(decor.blur_passes, 2)
    local shadowEnabled = luaLiteral(decor.shadow_enabled, true)
    local shadowRange = luaLiteral(decor.shadow_range, 30)
    local gapsIn = gapLiteral(decor.gaps_in, 5)
    local gapsOut = gapLiteral(decor.gaps_out, 10)
    local borderSize = luaLiteral(decor.border_size, 2)
    return "hyprctl eval \"hl.config({" ..
        "animations = { enabled = " .. animations ..
        " }, decoration = { rounding = " .. rounding ..
        ", active_opacity = " .. activeOpacity ..
        ", inactive_opacity = " .. inactiveOpacity ..
        ", fullscreen_opacity = " .. fullscreenOpacity ..
        ", blur = { enabled = " .. blurEnabled ..
        ", size = " .. blurSize ..
        ", passes = " .. blurPasses ..
        " }, shadow = { enabled = " .. shadowEnabled ..
        ", range = " .. shadowRange ..
        " } }, general = { gaps_in = " .. gapsIn ..
        ", gaps_out = " .. gapsOut ..
        ", border_size = " .. borderSize ..
        " } })\""
end

-- buildBoostOff strips the desktop to the maximum-FPS form. This half is intentionally
-- fixed: while gamer mode runs the compositing is gone, and there is nothing to restore
-- mid-session because the user opted into stripping it.
local function buildBoostOff()
    return "hyprctl eval \"hl.config({ animations = { enabled = false }, decoration = { rounding = 0, active_opacity = 1.0, inactive_opacity = 0.9, fullscreen_opacity = 1.0, blur = { enabled = false }, shadow = { enabled = false } }, general = { gaps_in = 0, gaps_out = 0, border_size = 1 } })\""
end

local function applyBoost(gaming, decorBefore)
    if noctalia.getConfig("boost_decorations") ~= false then
        local command = gaming and buildBoostOff() or buildBoostOn(decorBefore)
        run(command, function(result)
            if not succeeded(result) then
                noctalia.log("gamermode: could not apply Hyprland boost: " .. describeFailure(result))
            end
        end)
    end
end

function M.enable(profileOverride)
    if busy then
        return
    end
    -- Idempotent: an existing session means gamer mode is already on, and probing again
    -- would overwrite the recorded "was" states with the suspended ones.
    if M.readSnapshot() then
        M.publishGameMode()
        return
    end

    busy = true
    M.publishGameMode()

    local profile = resolveProfile(profileOverride)
    local targets = M.targetsForProfile(M.parseTargets(noctalia.getConfig("targets")), profile)

    -- Capture the profile to hand back before switching away from it, and the decoration
    -- values the boost will strip, so disable can restore the user's own style. Both run
    -- before any process is touched, and neither blocks the other.
    local function startSuspend(powerBefore, decor)
        probeAll(targets, function(probed)
            -- The session file is the only record of what was running before gamer mode
            -- touched it, so it is written before anything is suspended. A process frozen
            -- with SIGSTOP or a unit stopped with nothing on disk to name it cannot be
            -- restored: disable reads the session, finds none, and returns. A failed
            -- write therefore aborts the enable with the machine still untouched.
            --
            -- Ordering it this way can leave the snapshot naming a target whose suspend
            -- command then failed, which is the harmless direction. Thawing is
            -- unconditional and SIGCONT to a running process is a no-op, and a stop
            -- target is only restarted after a live probe says it is still down.
            --
            -- The wallpaper automation value is read here, before the file is edited, so
            -- the snapshot records what disable must hand back. Pausing it is best-effort:
            -- a failure to read or write the settings file must not abort the enable.
            local wallpaperBefore = M.readWallpaperAutomation()
            if not M.writeSnapshot(M.buildSnapshot(profile, powerBefore, probed, wallpaperBefore, decor)) then
                busy = false
                M.publishGameMode()
                noctalia.notifyError(
                    noctalia.tr("notify.session_failed_title"),
                    noctalia.tr("notify.session_failed")
                )
                return
            end
            if wallpaperBefore ~= nil then
                if not M.setWallpaperAutomation(false) then
                    noctalia.log("gamermode: could not pause wallpaper automation")
                end
            end
            -- Boost is applied as soon as the session is committed, not after the async
            -- suspend finishes, so the Hyprland strip lands the moment the toggle fires
            -- rather than waiting on any polkit or systemctl round-trips. The snapshot
            -- already holds the pre-boost values, which is all disable needs.
            applyBoost(true)
            suspendAll(probed, function(stopped)
                busy = false
                M.publishGameMode()
                if autoPerformance() and powerState.available and powerSupports("performance") then
                    M.setPowerProfile("performance")
                end
                if stopped > 0 then
                    noctalia.notify(noctalia.tr("notify.enabled_title"), noctalia.trp("notify.suspended_count", stopped))
                else
                    noctalia.notify(noctalia.tr("notify.enabled_title"), noctalia.tr("notify.nothing_suspended"))
                end
            end)
        end)
    end

    local ready = 0
    local powerBefore = nil
    local decorBefore = nil
    local function maybeGo()
        ready = ready + 1
        if ready >= 2 then
            startSuspend(powerBefore, decorBefore)
        end
    end
    M.snapshotDecor(function(decor)
        decorBefore = decor
        maybeGo()
    end)
    if autoPerformance() then
        M.refreshPower(function(before)
            powerBefore = before
            maybeGo()
        end)
    else
        maybeGo()
    end
end

-- ── disable ──

-- Watchdog arm, filled in by disable and checked by update() on every poll tick.
-- A restore must never wedge the shell: enable recorded the power profile to hand back,
-- and disable has to hand it back even if a privileged restore hangs on a polkit dialog
-- that nobody answers. The watchdog forces finish() once a deadline has passed, logging
-- anything that was still pending, then swallows the dropped callbacks with the settled
-- guard.
local DISABLE_RESOLVE_MS = 15000
local disableWatchdog = { armed = false, deadline = 0, pendingRef = nil, finish = nil }

function M.disable()
    if busy then
        return
    end
    local snap = M.readSnapshot()
    if not snap then
        M.publishGameMode()
        return
    end

    busy = true
    M.publishGameMode()

    -- Restore Hyprland's decorations immediately, from the values captured at enable; the
    -- thaw/restart batch is async and may wait on polkit, but the desktop should look
    -- normal the moment the toggle lands.
    applyBoost(false, snap.decor_before)

    local thawTargets = M.thawPlan(snap)
    -- Filter to stop targets recorded as up; the "still down" half of the check is a live
    -- probe per target below, so a manual restart in the meantime wins.
    local candidates = M.restorePlan(snap, function()
        return "down"
    end)

    local restored = 0
    -- Held at one until every job has been queued, so a batch that completes inline cannot
    -- finish the session while later phases are still being set up.
    local pending = 1
    -- Completed by either the last restore callback or the watchdog. A pkexec callback that
    -- fires *after* the watchdog already forced completion must not run the restore half a
    -- second time, so finish() settles exactly once.
    local finished = false

    local function finish()
        if finished then
            return
        end
        finished = true
        disableWatchdog.armed = false
        disableWatchdog.finish = nil
        disableWatchdog.pendingRef = nil
        M.deleteSnapshot()
        busy = false
        M.publishGameMode()
        if autoPerformance() and snap.power_profile_before then
            -- Resolve the live profile list first: powerState.available can be stale (e.g.
            -- power-profiles-daemon restarted), which would make setPowerProfile bail to a
            -- no-op and leave power stuck on performance after a disable.
            noctalia.log("gamermode DEBUG disable: restoring profile=" .. tostring(snap.power_profile_before))
            M.refreshPower(function(active)
                noctalia.log("gamermode DEBUG disable: powerState available=" .. tostring(powerState.available) .. " active=" .. tostring(active))
                M.setPowerProfile(snap.power_profile_before)
            end)
        else
            noctalia.log("gamermode DEBUG disable: SKIP restore autoPerf=" .. tostring(autoPerformance()) .. " pwrBefore=" .. tostring(snap.power_profile_before))
        end
        if snap.wallpaper_automation_before ~= nil then
            if not M.setWallpaperAutomation(snap.wallpaper_automation_before) then
                noctalia.log("gamermode: could not restore wallpaper automation")
            end
        end
        if restored > 0 then
            noctalia.notify(noctalia.tr("notify.disabled_title"), noctalia.trp("notify.restored_count", restored))
        else
            noctalia.notify(noctalia.tr("notify.disabled_title"), noctalia.tr("notify.nothing_restored"))
        end
    end

    local function step()
        pending = pending - 1
        if pending == 0 then
            finish()
        end
    end

    -- launch counts one job whatever it covers, so a batch and a single command are the
    -- same thing to the caller.
    local function launch(command, privileged, covered, verb)
        pending = pending + 1
        run(command, function(result)
            if succeeded(result) then
                restored = restored + #covered
            else
                local names = {}
                for _, target in ipairs(covered) do
                    names[#names + 1] = target.match
                end
                noctalia.log(
                    "gamermode: could not " .. verb .. " " .. table.concat(names, ", ")
                        .. ": " .. describeFailure(result)
                )
            end
            step()
        end, privileged)
    end

    -- Freeze targets: thaw unconditionally, no probe. A frozen process still appears in
    -- pgrep so no probe could tell "still frozen" from "running", and SIGCONT to a running
    -- process is a verified no-op.
    local thawCommand, thawCovered = M.batchCmd("thaw", thawTargets)
    if thawCommand then
        launch(thawCommand, true, thawCovered, "thaw")
    end
    for _, target in ipairs(thawTargets) do
        if not batchable("thaw", target.kind) then
            local command = M.thawCmd(target)
            if command then
                launch(command, false, { target }, "thaw")
            else
                noctalia.log("gamermode: no thaw command for " .. tostring(target.match))
            end
        end
    end

    -- Stop targets: probe every candidate, then start only those still down. The probes
    -- are unprivileged and run first so the single privileged start covers exactly the
    -- units that need it, rather than prompting for units already back up.
    local stillDown = {}

    local function startStillDown()
        local startCommand, startCovered = M.batchCmd("start", stillDown)
        if startCommand then
            launch(startCommand, true, startCovered, "restart")
        end
        for _, target in ipairs(stillDown) do
            if not batchable("start", target.kind) then
                local command = M.startCmd(target)
                if command then
                    launch(command, false, { target }, "restart")
                end
            end
        end
        step()
    end

    local probesLeft = #candidates
    if probesLeft == 0 then
        startStillDown()
    else
        local function probeDone()
            probesLeft = probesLeft - 1
            if probesLeft == 0 then
                startStillDown()
            end
        end
        for _, target in ipairs(candidates) do
            if not M.startCmd(target) then
                -- Processes cannot be relaunched generically; say so once, per target.
                noctalia.log(
                    "gamermode: cannot restart " .. tostring(target.match) .. " (" .. tostring(target.kind) .. ")"
                )
                probeDone()
            else
                run(M.probeCmd(target), function(probeResult)
                    if M.wasState(target.kind, probeResult and probeResult.stdout) == "down" then
                        stillDown[#stillDown + 1] = target
                    end
                    -- Anything already back up, by hand or by its own supervisor, is left
                    -- out of the start batch.
                    probeDone()
                end)
            end
        end
    end
    -- Arm the watchdog once every restore job is queued. From here, if anything fails to
    -- call back (a pkexec sitting on an unanswered polkit dialog being the target case),
    -- update() forces finish() after the deadline so the power profile is handed back and
    -- the session file is cleared rather than leaving gamer mode permanently wedged.
    disableWatchdog.armed = true
    disableWatchdog.deadline = noctalia.nowMs() + DISABLE_RESOLVE_MS
    disableWatchdog.pendingRef = function()
        return pending
    end
    disableWatchdog.finish = finish
end

-- toggle passes the override through to enable. Turning gamer mode off needs no profile:
-- the session records which one was applied.
function M.toggle(profileOverride)
    if M.readSnapshot() then
        M.disable()
    else
        M.enable(profileOverride)
    end
end

-- ── maintenance ──
--
-- One-shot cleanups, run on demand from the panel rather than as part of gamer mode.
-- Nothing here is undone by disabling gamer mode: a deleted cache is gone and a dropped
-- page cache refills on its own, so none of it belongs in the session snapshot.

-- Shader caches, in the locations the drivers and Steam actually use. Deleting one costs
-- a slower first launch while it recompiles and nothing else, which is the trade people
-- want after a driver update leaves stale shaders behind.
-- Covering both vendors, because which of these exists is the clearest sign of which
-- driver stack a machine runs.
local SHADER_CACHES = {
    -- Mesa: AMD radeonsi and RADV, Intel, and the software rasterisers. The _db suffix is
    -- the newer single-file format; a machine mid-upgrade has both.
    "~/.cache/mesa_shader_cache",
    "~/.cache/mesa_shader_cache_db",
    "~/.cache/radv_builtin_shaders",
    -- AMDVLK and the AMD Pro stack keep their own, separate from Mesa's.
    "~/.cache/AMD",
    -- NVIDIA moved GLCache from ~/.nv to ~/.cache/nvidia. Drivers old enough to use the
    -- first are still in service, so both are listed.
    "~/.cache/nvidia/GLCache",
    "~/.nv/GLCache",
    -- Steam's own, for the native package and the Flatpak. A library on a second drive
    -- keeps its shadercache beside it and is not covered: finding those means parsing
    -- libraryfolders.vdf, which is more machinery than this is worth.
    "~/.local/share/Steam/steamapps/shadercache",
    "~/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/shadercache",
}

-- Every path is expanded from the fixed list above and then checked to be under the home
-- directory. The list is not user-supplied today, and this makes sure a future setting
-- cannot turn `rm -rf` on something outside it.
function M.shaderCachePaths()
    local home = noctalia.expandPath("~")
    if not home or home == "" or home == "/" then
        return {}
    end
    local prefix = home:sub(-1) == "/" and home or (home .. "/")
    local found = {}
    for _, entry in ipairs(SHADER_CACHES) do
        local path = noctalia.expandPath(entry)
        if type(path) == "string" and path:sub(1, #prefix) == prefix and noctalia.fileExists(path) then
            found[#found + 1] = path
        end
    end
    return found
end

function M.shaderSizeCmd(paths)
    if not paths or #paths == 0 then
        return nil
    end
    local quoted = {}
    for _, path in ipairs(paths) do
        quoted[#quoted + 1] = shellQuote(path)
    end
    -- -c adds a grand total as the last line; -s keeps each argument to one line.
    return "du -sbc " .. table.concat(quoted, " ") .. " | tail -1 | cut -f1"
end

function M.shaderClearCmd(paths)
    if not paths or #paths == 0 then
        return nil
    end
    local quoted = {}
    for _, path in ipairs(paths) do
        quoted[#quoted + 1] = shellQuote(path)
    end
    -- `--` stops a path that begins with a dash being read as an option.
    return "rm -rf -- " .. table.concat(quoted, " ")
end

-- sysctl writes /proc/sys/vm/drop_caches without needing a root shell, so the elevated
-- half stays a single fixed argv with nothing interpolated into it.
function M.dropCachesCmd()
    return "pkexec /usr/bin/sysctl -w vm.drop_caches=3"
end

-- swapoff has to complete before swapon starts, which needs the two joined. The string is
-- a fixed literal: nothing the user controls reaches it.
function M.reclaimSwapCmd()
    return "pkexec /bin/sh -c 'swapoff -a && swapon -a'"
end

-- Reclaiming swap reads every swapped page back into RAM. If it does not fit, swapoff
-- fails partway or the machine starts killing things, so the check runs first.
function M.canReclaimSwap(raw)
    local swap = type(raw) == "table" and type(raw.swap) == "table" and raw.swap or nil
    local ram = type(raw) == "table" and type(raw.ram) == "table" and raw.ram or nil
    local swapUsed = swap and tonumber(swap.usedMb)
    if not swapUsed then
        return false, "swap_unknown"
    end
    if swapUsed <= 0 then
        return false, "swap_empty"
    end
    local total = ram and tonumber(ram.totalMb)
    local used = ram and tonumber(ram.usedMb)
    if not total or not used then
        return false, "swap_unknown"
    end
    -- A tenth of RAM in headroom, so this does not succeed straight into an out-of-memory
    -- kill of the game it was meant to help.
    if swapUsed > (total - used) - (total * 0.1) then
        return false, "swap_no_room"
    end
    return true
end

local cleanupJob = nil
local shaderSize = nil

local function publishCleanup(message, ok)
    noctalia.state.set("cleanup", {
        running = cleanupJob,
        message = message,
        ok = ok,
        shaderSize = shaderSize,
    })
end

local function finishCleanup(messageKey, ok, subst)
    cleanupJob = nil
    publishCleanup(subst and noctalia.tr(messageKey, subst) or noctalia.tr(messageKey), ok)
end

-- Measuring is its own job because the panel arms the delete before performing it, and a
-- confirmation that names a size is worth the round trip. Nothing is removed here.
local function measureShaderCaches()
    local paths = M.shaderCachePaths()
    if #paths == 0 then
        shaderSize = nil
        finishCleanup("cleanup.shaders_none", true)
        return
    end
    run(M.shaderSizeCmd(paths), function(result)
        shaderSize = M.humanBytes(tonumber(trim(result and result.stdout)) or 0)
        finishCleanup("cleanup.shaders_confirm", nil, { size = shaderSize })
    end)
end

local function clearShaderCaches()
    local paths = M.shaderCachePaths()
    if #paths == 0 then
        shaderSize = nil
        finishCleanup("cleanup.shaders_none", true)
        return
    end
    local removed = shaderSize
    run(M.shaderClearCmd(paths), function(result)
        if succeeded(result) then
            shaderSize = nil
            finishCleanup("cleanup.shaders_done", true, { size = removed or "?" })
        else
            noctalia.log("gamermode: could not clear shader caches: " .. describeFailure(result))
            finishCleanup("cleanup.failed", false)
        end
    end)
end

local function dropPageCache()
    -- sync first so dirty pages are written out; dropping them unwritten would lose data.
    run("sync", function()
        run(M.dropCachesCmd(), function(result)
            if succeeded(result) then
                finishCleanup("cleanup.pagecache_done", true)
            else
                noctalia.log("gamermode: could not drop the page cache: " .. describeFailure(result))
                finishCleanup("cleanup.failed", false)
            end
        end, true)
    end)
end

local function reclaimSwap()
    local ok, reason = M.canReclaimSwap(noctalia.systemStats())
    if not ok then
        finishCleanup("cleanup." .. reason, false)
        return
    end
    run(M.reclaimSwapCmd(), function(result)
        if succeeded(result) then
            finishCleanup("cleanup.swap_done", true)
        else
            noctalia.log("gamermode: could not reclaim swap: " .. describeFailure(result))
            finishCleanup("cleanup.failed", false)
        end
    end, true)
end

local CLEANUP_JOBS = {
    ["shaders-measure"] = measureShaderCaches,
    shaders = clearShaderCaches,
    pagecache = dropPageCache,
    swap = reclaimSwap,
}

function M.humanBytes(bytes)
    local value = tonumber(bytes) or 0
    if value >= 1024 * 1024 * 1024 then
        return string.format("%.1f GiB", value / (1024 * 1024 * 1024))
    elseif value >= 1024 * 1024 then
        return string.format("%.0f MiB", value / (1024 * 1024))
    end
    return string.format("%.0f KiB", value / 1024)
end

function M.runCleanup(job)
    if cleanupJob then
        return
    end
    local runner = CLEANUP_JOBS[job]
    if not runner then
        noctalia.log("gamermode: ignoring an unknown cleanup job " .. tostring(job))
        return
    end
    cleanupJob = job
    publishCleanup(noctalia.tr("cleanup.running"), nil)
    runner()
end

-- ── diagnostics ──

-- What this machine reports, written to the shell log.
--
-- GPU readings come from the shell, which uses NVML for NVIDIA and sysfs for everything
-- else, and the two do not expose the same fields. Rather than guess at what an AMD or
-- Intel box provides, this prints the raw sample so anyone can say what their hardware
-- actually reports. It is also the first thing to run when a target refuses to act.
function M.diagnose()
    local raw = noctalia.systemStats()
    noctalia.log("gamermode diagnose: stats = " .. tostring(noctalia.json.encode(raw)))
    noctalia.log("gamermode diagnose: metrics = " .. tostring(noctalia.json.encode(M.normalize(raw))))

    local tools = {}
    for _, name in ipairs({ "pgrep", "pkill", "systemctl", "pkexec", "docker", "powerprofilesctl", "du" }) do
        tools[#tools + 1] = name .. "=" .. tostring(noctalia.commandExists(name) == true)
    end
    noctalia.log("gamermode diagnose: tools " .. table.concat(tools, " "))
    noctalia.log(
        "gamermode diagnose: elevation pkexec=" .. tostring(M.canElevate) .. " systemctl=" .. tostring(M.systemctlPath)
    )

    local caches = M.shaderCachePaths()
    noctalia.log("gamermode diagnose: shader caches = " .. (#caches > 0 and table.concat(caches, " ") or "none"))

    local snap = M.readSnapshot()
    noctalia.log(
        "gamermode diagnose: session = "
            .. (snap and (snap.profile .. ", " .. #snap.targets .. " targets") or "none")
    )
end

-- ── commands ──

-- Commands arrive as `command` state writes from the panel and widget. The nonce makes
-- a replayed or duplicated write a no-op instead of a second toggle.
function M.handleCommand(command)
    if type(command) ~= "table" then
        noctalia.log("gamermode: ignoring a malformed command")
        return
    end
    local nonce = tonumber(command.nonce)
    if nonce then
        if nonce <= lastHandledNonce then
            return
        end
        lastHandledNonce = nonce
    end

    local action = command.action
    if action == "toggle" then
        M.toggle(command.profile)
    elseif action == "enable" then
        M.enable(command.profile)
    elseif action == "disable" then
        M.disable()
    elseif action == "set-power-profile" then
        M.setPowerProfile(command.profile)
    elseif action == "cleanup" then
        M.runCleanup(command.job)
    elseif action == "diagnose" then
        M.diagnose()
    else
        noctalia.log("gamermode: unknown command action " .. tostring(action))
    end
end

-- reconcileSession decides what a session file found at startup means. A session from a
-- previous boot is stale: nothing it froze still exists, and units it stopped may have come
-- back on their own. It still gets a full restore pass before being cleared, because a
-- stopped unit that is not `enabled` really is still down, and putting it back is what the
-- user was told would happen.
--
-- Within the same boot a session is always kept, even if everything looks running -- that
-- is precisely the case where something may still be frozen and needs thawing.
function M.reconcileSession()
    local snap = M.readSnapshot()
    if not snap then
        M.publishGameMode()
        return
    end

    local current = M.currentBootId()
    -- A snapshot with no boot id was written by an older version; treat it as current
    -- rather than abandoning targets that may still be suspended. Likewise when the boot
    -- id cannot be read at all.
    if not snap.boot_id or not current or snap.boot_id == current then
        M.publishGameMode()
        return
    end

    noctalia.log("gamermode: session predates the current boot, restoring and clearing it")
    M.disable()
end

function M.init()
    local directory = noctalia.pluginDataDir()
    if directory then
        noctalia.mkdirAll(directory)
    end

    -- Resolve elevation before anything can need it. Without pkexec the plugin still works
    -- through systemd's own polkit check, so this downgrades rather than disables.
    M.canElevate = noctalia.commandExists("pkexec") == true
    if not M.canElevate then
        noctalia.log(
            "gamermode: pkexec not found, so system units will ask for a password once per "
                .. "unit instead of once per batch"
        )
    else
        run("command -v systemctl", function(result)
            local path = result and trim(result.stdout) or ""
            if path ~= "" and path:sub(1, 1) == "/" then
                M.systemctlPath = path
            end
        end)
    end

    -- Publish immediately so a panel opened before the first poll is not empty.
    M.publishGameMode()
    M.publishMetrics()
    -- Reconciliation can restore the previous power profile, so it waits until the power
    -- state is known.
    M.refreshPower(function()
        M.reconcileSession()
    end)

    local seconds = tonumber(noctalia.getConfig("poll_interval")) or DEFAULT_POLL_SECONDS
    noctalia.setUpdateInterval(math.max(1, seconds) * 1000)
end

-- ── shell entry points (must be globals) ──

function update()
    M.publishMetrics()
    -- A queue can only stall if every start was refused while nothing of ours was running,
    -- which needs the rest of the shell to hold the whole process cap. The poll tick is the
    -- one thing guaranteed to keep firing, so it is what gets the queue moving again.
    pump()
    -- Resolve a stuck disable: if a restore job never called back (a pkexec wedged on an
    -- unanswered polkit dialog is the case that hangs), force finish() past the deadline so
    -- the power profile is handed back and the session file cleared.
    if disableWatchdog.armed and noctalia.nowMs() > disableWatchdog.deadline then
        local pending = disableWatchdog.pendingRef and disableWatchdog.pendingRef() or 0
        local finalize = disableWatchdog.finish
        disableWatchdog.armed = false
        disableWatchdog.finish = nil
        disableWatchdog.pendingRef = nil
        if finalize then
            finalize()
        else
            noctalia.log("gamermode: disable watchdog fired with no finalize hook")
        end
        if pending > 0 then
            noctalia.log("gamermode: disabled with " .. tostring(pending) .. " restore job(s) unresolved; session cleared anyway")
        end
    end
end

function onConfigChanged()
    local seconds = tonumber(noctalia.getConfig("poll_interval")) or DEFAULT_POLL_SECONDS
    noctalia.setUpdateInterval(math.max(1, seconds) * 1000)
    -- The configured profile shows in the panel even while gamer mode is off.
    M.publishGameMode()
end

function onIpc(event)
    if event == "toggle" then
        M.toggle()
    elseif event == "enable" then
        M.enable()
    elseif event == "disable" then
        M.disable()
    elseif event == "diagnose" then
        M.diagnose()
    end
end

noctalia.state.watch("command", M.handleCommand)
M.init()

return M
