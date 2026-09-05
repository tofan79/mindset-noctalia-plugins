--!nonstrict
--
-- Containers service: probes docker/podman and publishes merged container, image,
-- volume, network and live-stat data to `noctalia.state`, plus a thin action engine
-- for start/stop/restart/remove. The panel and widget are thin readers of that state.
--
-- Luau's sandbox has no io/os.execute, so every external command goes through
-- noctalia.runAsync. Docker and Podman both speak JSON; the parsers here normalise
-- both into one shape.

local noctalia = noctalia
if noctalia == nil then
    local host = dofile("tests/host_mock.luau")
    noctalia = host.noctalia
end

local M = {}

-- Forward-declared because parseRows/parseList (defined above) close over it, while the
-- implementation is declared further down. Luau resolves upvalues at definition scope, so
-- without this the early parsers would see a nil global and fail every list fetch.
local sortContainers

-- ── string helpers ──

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

local function startsWith(s, p)
    return (s:sub(1, #p) == p)
end

local function trimSlash(name)
    local v = tostring(name or "")
    if v:sub(1, 1) == "/" then
        return v:sub(2)
    end
    return v
end

local function firstName(value)
    if type(value) == "table" then
        for _, v in ipairs(value) do
            local n = trimSlash(v)
            if n ~= "" then
                return n
            end
        end
        return ""
    end
    return trimSlash(value)
end

-- Docker's `ps --format '{{json .}}'` flattens labels into a comma-separated `k=v`
-- string. Compose's depends_on values contain commas, so a split on comma is wrong;
-- walk `key=` tokens instead.
local function parseLabelString(text)
    local map = {}
    local raw = tostring(text or "")
    if raw == "" then
        return map
    end
    local pattern = "(^|,)([A-Za-z0-9][A-Za-z0-9._/%-]*)="
    local pos = 1
    local parts = {}
    while true do
        local startPos, _ = raw:find("[A-Za-z0-9%.%_%/%-]*=", pos)
        if not startPos then
            break
        end
        local keyEnd = startPos + raw:sub(startPos):find("=%s*") - 2
        local key = raw:sub(startPos, keyEnd)
        local valueStart = keyEnd + 2
        -- find the next token start
        local nextToken = raw:find(",", valueStart)
        local valueEnd = nextToken or (#raw + 1)
        map[key] = raw:sub(valueStart, valueEnd - 1)
        if not nextToken then
            break
        end
        pos = nextToken + 1
    end
    return map
end

local function parseLabels(labels)
    if not labels then
        return {}
    end
    if type(labels) == "table" then
        return labels
    end
    return parseLabelString(labels)
end

local function projectOf(labels)
    return tostring(labels["com.docker.compose.project"] or labels["io.podman.compose.project"] or "")
end

local function serviceOf(labels)
    return tostring(labels["com.docker.compose.service"] or labels["io.podman.compose.service"] or "")
end

-- ── ports ──

local function formatPorts(ports)
    if ports == nil or ports == "" then
        return ""
    end
    if type(ports) == "string" then
        return ports
    end
    if type(ports) ~= "table" then
        return tostring(ports)
    end
    local parts = {}
    for _, p in ipairs(ports) do
        if p == nil then
            -- skip
        elseif type(p) == "string" then
            if p ~= "" then
                parts[#parts + 1] = p
            end
        else
            local host = p.host_port or p.HostPort or p.hostPort or ""
            local dest = p.container_port or p.ContainerPort or p.containerPort or ""
            local proto = p.protocol or p.Protocol or "tcp"
            if host ~= "" and dest ~= "" then
                parts[#parts + 1] = host .. ":" .. dest .. "/" .. proto
            elseif dest ~= "" then
                parts[#parts + 1] = dest .. "/" .. proto
            elseif host ~= "" then
                parts[#parts + 1] = tostring(host)
            end
        end
    end
    return table.concat(parts, ", ")
end

-- ── state / health normalisers ──

local function normalizeState(raw)
    local value = trim(tostring(raw or "")):lower()
    if value == "up" or startsWith(value, "up ") then
        return "running"
    end
    if startsWith(value, "exited") then
        return "exited"
    end
    if startsWith(value, "created") then
        return "created"
    end
    if startsWith(value, "paused") then
        return "paused"
    end
    if startsWith(value, "restarting") then
        return "restarting"
    end
    if startsWith(value, "dead") then
        return "dead"
    end
    if startsWith(value, "removing") then
        return "removing"
    end
    return value
end

local function normalizeHealth(raw)
    local value = trim(tostring(raw or "")):lower()
    if value == "" or value == "none" or value == "n/a" then
        return ""
    end
    return value
end

local function isRunning(state)
    return state == "running" or state == "restarting"
end

local function isProblem(state, health)
    if state == "restarting" or state == "dead" or state == "paused" then
        return true
    end
    return state == "running" and health == "unhealthy"
end

local function normalizeContainer(raw, engine)
    if type(raw) ~= "table" then
        return nil
    end
    local id = tostring(raw.ID or raw.Id or raw.id or "")
    if id == "" then
        return nil
    end
    local labels = parseLabels(raw.Labels or raw.labels or {})
    local state = normalizeState(raw.State ~= nil and raw.State or "")
    if state == "" then
        state = normalizeState(raw.Status or "")
    end
    local health = normalizeHealth(raw.HealthStatus or raw.Health or raw.health or "")
    local name = firstName(raw.Names or raw.Name or raw.names or raw.name or "")
    if name == "" then
        name = id:sub(1, 12)
    end
    return {
        id = id,
        containerId = id,
        shortId = id:sub(1, 12),
        name = name,
        image = tostring(raw.Image or raw.image or ""),
        state = state,
        status = tostring(raw.Status or raw.status or ""),
        health = health,
        running = isRunning(state),
        problem = isProblem(state, health),
        ports = formatPorts(raw.Ports ~= nil and raw.Ports or raw.ports),
        project = projectOf(labels),
        service = serviceOf(labels),
        engine = (engine == "podman") and "podman" or "docker",
        kind = "container",
        removable = false,
    }
end

function M.normalizeContainer(raw, engine)
    return normalizeContainer(raw, engine)
end

-- ── images ──

local function isNoneRef(value)
    local s = trim(tostring(value or "")):lower()
    return s == "" or s == "<none>"
end

local function splitRepoTag(value)
    local s = firstName(value)
    if isNoneRef(s) then
        return { repository = "", tag = "" }
    end
    local slash = s:find(".$") and (s:match(".*/([^/]+$)")) and (s:find("/[^/]*$")) or 0
    local lastSlash = 0
    for i = #s, 1, -1 do
        if s:sub(i, i) == "/" then
            lastSlash = i
            break
        end
    end
    local lastColon = 0
    for i = #s, 1, -1 do
        if s:sub(i, i) == ":" then
            lastColon = i
            break
        end
    end
    if lastColon > lastSlash then
        return { repository = s:sub(1, lastColon - 1), tag = s:sub(lastColon + 1) }
    end
    return { repository = s, tag = "" }
end

local function imageRef(repository, tag)
    if repository == "" then
        return ""
    end
    return (tag ~= "") and (repository .. ":" .. tag) or repository
end

-- ── byte-size parsing (mirror parseSize/formatBytes) ──

local function parseOneSize(text)
    local s = trim(tostring(text or "")):gsub(",", "")
    if s == "" or s == "--" or s == "0" then
        return 0
    end
    local n, unit = s:match("^([%d%.]+)%s*([A-Za-z]+)")
    if not n then
        return 0
    end
    local num = tonumber(n)
    if not num then
        return 0
    end
    local u = (unit or "B"):upper()
    local mul = 1
    if u == "KB" or u == "K" then
        mul = 1000
    elseif u == "KIB" or u == "KI" then
        mul = 1024
    elseif u == "MB" or u == "M" then
        mul = 1000 * 1000
    elseif u == "MIB" or u == "MI" then
        mul = 1024 * 1024
    elseif u == "GB" or u == "G" then
        mul = 1000 * 1000 * 1000
    elseif u == "GIB" or u == "GI" then
        mul = 1024 * 1024 * 1024
    elseif u == "TB" or u == "T" then
        mul = 1000 * 1000 * 1000 * 1000
    elseif u == "TIB" or u == "TI" then
        mul = 1024 * 1024 * 1024 * 1024
    end
    return num * mul
end

local function formatBytes(n)
    local value = tonumber(n) or 0
    if not (value > 0) then
        return "0B"
    end
    local units = { "B", "KiB", "MiB", "GiB", "TiB" }
    local i = 1
    while value >= 1024 and i < #units do
        value = value / 1024
        i = i + 1
    end
    local digits = (i == 1 or value >= 10) and 0 or 1
    return string.format("%." .. digits .. "f", value) .. units[i]
end

local function parseSize(raw)
    if type(raw) == "number" then
        return raw
    end
    return parseOneSize(raw)
end

local function normalizeImage(raw, engine)
    if type(raw) ~= "table" then
        return nil
    end
    local id = tostring(raw.ID or raw.Id or raw.id or ""):gsub("^sha256:", "")
    if id == "" then
        return nil
    end
    local repo = tostring(raw.Repository or raw.repository or "")
    local tag = tostring(raw.Tag or raw.tag or "")
    if repo == "" and tag == "" then
        local split = splitRepoTag(raw.Names or raw.names or raw.NamesHistory or "")
        repo, tag = split.repository, split.tag
    end
    if isNoneRef(repo) then
        repo = ""
    end
    if isNoneRef(tag) then
        tag = ""
    end
    local dangling = (repo == "") or raw.Dangling == true or raw.dangling == true
    local used = tonumber(raw.Containers ~= nil and raw.Containers or (raw.containers ~= nil and raw.containers or "0"))
    if not used then
        used = 0
    end
    if used < 0 then
        used = 0
    end
    local sizeRaw = raw.Size ~= nil and raw.Size or raw.size
    local size = parseSize(sizeRaw)
    local name = imageRef(repo, tag) ~= "" and imageRef(repo, tag) or id:sub(1, 12)
    return {
        kind = "image",
        id = id,
        resourceId = id,
        shortId = id:sub(1, 12),
        name = name,
        repository = repo,
        tag = tag,
        project = repo,
        engine = (engine == "podman") and "podman" or "docker",
        size = size,
        sizeText = (type(sizeRaw) == "string" and trim(sizeRaw) ~= "") and trim(sizeRaw) or formatBytes(size),
        created = tostring(raw.CreatedSince or raw.CreatedAt or raw.created or ""),
        used = used,
        dangling = dangling,
        running = used > 0,
        problem = false,
        removable = true,
        inUse = used > 0,
    }
end

-- ── volumes ──

local function isAnonymousVolume(name, labels)
    if labels and (labels["com.docker.volume.anonymous"] ~= nil or labels["com.docker.volume.anonymous"] == "") then
        return true
    end
    return name:match("^[a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]") and #name == 64
end

local function normalizeVolume(raw, engine)
    if type(raw) ~= "table" then
        return nil
    end
    local name = firstName(raw.Name or raw.Names or raw.name or "")
    if name == "" then
        return nil
    end
    local labels = parseLabels(raw.Labels or raw.labels or {})
    local project = projectOf(labels)
    local anonymous = isAnonymousVolume(name, labels)
    local driver = tostring(raw.Driver or raw.driver or "")
    return {
        kind = "volume",
        id = name,
        resourceId = name,
        shortId = name:sub(1, 12),
        name = name,
        project = project,
        engine = (engine == "podman") and "podman" or "docker",
        driver = driver,
        scope = tostring(raw.Scope or raw.scope or ""),
        mountpoint = tostring(raw.Mountpoint or raw.MountPoint or raw.mountpoint or ""),
        anonymous = anonymous,
        running = not anonymous,
        problem = false,
        removable = true,
    }
end

-- ── networks ──

local BUILTIN_NETWORKS = { bridge = true, host = true, ["none"] = true, podman = true, pasta = true }

local function isBuiltinNetwork(name)
    return BUILTIN_NETWORKS[trim(tostring(name or "")):lower()] == true
end

local function normalizeNetwork(raw, engine)
    if type(raw) ~= "table" then
        return nil
    end
    local id = tostring(raw.ID or raw.Id or raw.id or "")
    local name = firstName(raw.Name or raw.Names or raw.name or "")
    if id == "" and name == "" then
        return nil
    end
    if name == "" then
        name = id:sub(1, 12)
    end
    if id == "" then
        id = name
    end
    local labels = parseLabels(raw.Labels or raw.labels or {})
    local builtin = isBuiltinNetwork(name)
    local internal = tostring(raw.Internal or raw.internal or "") == "true" or raw.Internal == true
    return {
        kind = "network",
        id = id,
        resourceId = id,
        shortId = id:sub(1, 12),
        name = name,
        project = projectOf(labels),
        engine = (engine == "podman") and "podman" or "docker",
        driver = tostring(raw.Driver or raw.driver or ""),
        scope = tostring(raw.Scope or raw.scope or ""),
        internal = internal,
        builtin = builtin,
        running = not builtin,
        problem = false,
        removable = not builtin,
    }
end

-- ── JSON row parsing ──

local function parseJsonRows(text)
    local s = trim(tostring(text or ""))
    if s == "" then
        return {}
    end
    -- Resources use '{{json .}}' (NDJSON: one object per line); stats/system-df use
    -- '--format json' (a single array document). Peek the first char to pick the cheap,
    -- correct decoder instead of trying to parse the whole blob both ways every poll.
    if s:sub(1, 1) == "[" then
        local ok, parsed = pcall(function()
            return noctalia.json.decode(s)
        end)
        if ok and type(parsed) == "table" then
            return parsed
        end
        return {}
    end
    -- NDJSON: one object per line
    local rows = {}
    for line in s:gmatch("[^\r\n]+") do
        local l = trim(line)
        if l ~= "" then
            local ok2, row = pcall(function()
                return noctalia.json.decode(l)
            end)
            if ok2 and type(row) == "table" then
                rows[#rows + 1] = row
            else
                return {}
            end
        end
    end
    return rows
end

local function parseRows(value, engine)
    local containers = {}
    if type(value) == "table" then
        for _, row in ipairs(value) do
            local c = normalizeContainer(row, engine)
            if c then
                containers[#containers + 1] = c
            end
        end
        return { ok = true, containers = sortContainers(containers) }
    end
    return { ok = false, error = "unexpected json" }
end

local function parseList(raw, engine)
    local text = trim(tostring(raw or ""))
    if text == "" then
        return { ok = true, containers = {} }
    end
    local ok, parsed = pcall(function()
        return noctalia.json.decode(text)
    end)
    if ok then
        return parseRows(parsed, engine)
    end
    -- NDJSON
    local rows = parseJsonRows(text)
    local containers = {}
    for _, row in ipairs(rows) do
        local c = normalizeContainer(row, engine)
        if c then
            containers[#containers + 1] = c
        end
    end
    return { ok = true, containers = sortContainers(containers) }
end

function M.parseList(raw, engine)
    return parseList(raw, engine)
end

-- ── sorting / merge / summary ──

sortContainers = function(list)
    local out = {}
    for _, v in ipairs(list) do
        out[#out + 1] = v
    end
    table.sort(out, function(a, b)
        if a.problem ~= b.problem then
            return a.problem
        end
        if a.running ~= b.running then
            return a.running
        end
        local pa = a.project ~= "" and a.project or "~"
        local pb = b.project ~= "" and b.project or "~"
        if pa ~= pb then
            return pa < pb
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        return false
    end)
    return out
end

function M.sortContainers(list)
    return sortContainers(list)
end

local function mergeLists(...)
    local containers = {}
    for i = 1, select("#", ...) do
        local list = select(i, ...)
        if list then
            for _, item in ipairs(list) do
                containers[#containers + 1] = item
            end
        end
    end
    return sortContainers(containers)
end

function M.mergeLists(...)
    return mergeLists(...)
end

local function summary(containers)
    local list = containers or {}
    local total, running, stopped, unhealthy = 0, 0, 0, 0
    local engines = {}
    for _, item in ipairs(list) do
        engines[item.engine] = true
        if item.running then
            running = running + 1
        else
            stopped = stopped + 1
        end
        if item.problem then
            unhealthy = unhealthy + 1
        end
    end
    local totalEngines = 0
    for _ in pairs(engines) do
        totalEngines = totalEngines + 1
    end
    local eng = ""
    if totalEngines == 1 then
        for k in pairs(engines) do
            eng = k
        end
    elseif totalEngines > 1 then
        eng = "both"
    end
    return {
        total = #list,
        running = running,
        stopped = stopped,
        unhealthy = unhealthy,
        engine = eng,
    }
end

function M.summary(containers)
    return summary(containers)
end

-- ── resource bundle (images/volumes/networks from one script) ──

M.SEP_IMAGES = "__CONTAINERS_IMAGES__"
M.SEP_VOLUMES = "__CONTAINERS_VOLUMES__"
M.SEP_NETWORKS = "__CONTAINERS_NETWORKS__"

function M.imagesCommand(engine)
    local bin = (engine == "podman") and "podman" or "docker"
    if engine == "podman" then
        return bin .. " images --format json"
    end
    return bin .. " images --format '{{json .}}'"
end

function M.volumesCommand(engine)
    local bin = (engine == "podman") and "podman" or "docker"
    if engine == "podman" then
        return bin .. " volume ls --format json"
    end
    return bin .. " volume ls --format '{{json .}}'"
end

function M.networksCommand(engine)
    local bin = (engine == "podman") and "podman" or "docker"
    if engine == "podman" then
        return bin .. " network ls --format json"
    end
    return bin .. " network ls --format '{{json .}}'"
end

local function mapResources(rows, engine, normalizeOne)
    local out = {}
    for _, row in ipairs(rows or {}) do
        local item = normalizeOne(row, engine)
        if item then
            out[#out + 1] = item
        end
    end
    return sortContainers(out)
end

local function parseImages(raw, engine)
    return mapResources(parseJsonRows(raw), engine, normalizeImage)
end

local function parseVolumes(raw, engine)
    return mapResources(parseJsonRows(raw), engine, normalizeVolume)
end

local function parseNetworks(raw, engine)
    return mapResources(parseJsonRows(raw), engine, normalizeNetwork)
end

M.parseImages = parseImages
M.parseVolumes = parseVolumes
M.parseNetworks = parseNetworks

-- ── stats ──

local function parsePercent(value)
    local s = trim(tostring(value or "")):gsub("%%", ""):gsub(",", ".")
    local n = tonumber(s)
    return n or 0
end

local function parsePids(value)
    local n = tonumber(trim(tostring(value or "0")))
    return (n and n > 0) and n or 0
end

local function parsePair(text)
    local s = tostring(text or "")
    local idx = s:find("/")
    if not idx then
        return { used = 0, limit = 0 }
    end
    return { used = parseSize(s:sub(1, idx - 1)), limit = parseSize(s:sub(idx + 1)) }
end

local function normalizeStat(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local name = firstName(raw.Name or raw.Names or raw.name or raw.Container or "")
    local id = tostring(raw.ID or raw.Id or raw.id or raw.Container or "")
    if name == "" and id == "" then
        return nil
    end
    local mem = parsePair(raw.MemUsage or raw.Mem or raw.mem_usage or "")
    local net = parsePair(raw.NetIO or raw.net_io or "")
    local block = parsePair(raw.BlockIO or raw.block_io or "")
    local cpu = parsePercent(raw.CPUPerc ~= nil and raw.CPUPerc or (raw.CPU ~= nil and raw.CPU or (raw.cpu_percent ~= nil and raw.cpu_percent or raw.cpu)))
    local memPerc = parsePercent(raw.MemPerc ~= nil and raw.MemPerc or (raw.MemPercentage ~= nil and raw.MemPercentage or 0))
    if memPerc == 0 and mem.limit > 0 then
        memPerc = (mem.used / mem.limit) * 100
    end
    return {
        id = id,
        name = name,
        cpu = cpu,
        memPerc = memPerc,
        memUsed = mem.used,
        memLimit = mem.limit,
        netIn = net.used,
        netOut = net.limit,
        blockIn = block.used,
        blockOut = block.limit,
        pids = parsePids(raw.PIDs ~= nil and raw.PIDs or raw.pids),
    }
end

local function parseStats(raw)
    local text = trim(tostring(raw or ""))
    if text == "" then
        return { ok = true, rows = {} }
    end
    local rows = {}
    for _, row in ipairs(parseJsonRows(text)) do
        local s = normalizeStat(row)
        if s then
            rows[#rows + 1] = s
        end
    end
    return { ok = true, rows = rows }
end

M.parseStats = parseStats

function M.statsCommand(engine)
    local bin = (engine == "podman") and "podman" or "docker"
    if engine == "podman" then
        return bin .. " stats --no-stream --format json"
    end
    return bin .. " stats --no-stream --format '{{json .}}'"
end

-- ── system df ──

function M.dfCommand(engine)
    local bin = (engine == "podman") and "podman" or "docker"
    if engine == "podman" then
        return bin .. " system df --format json"
    end
    return bin .. " system df --format '{{json .}}'"
end

local function parseSystemDf(raw)
    local rows = parseJsonRows(raw)
    local used = 0
    local parts = {}
    for _, row in ipairs(rows) do
        local kind = tostring(row.Type or row.type or "")
        local size = parseSize(row.Size or row.size or "")
        if kind ~= "" then
            parts[kind] = size
        end
        used = used + size
    end
    return { ok = true, used = used, parts = parts }
end

M.parseSystemDf = parseSystemDf

-- ── attach stats to containers ──

function M.attachStats(containers, rows)
    local list = containers or {}
    local stats = rows or {}
    local byName, byId = {}, {}
    for _, row in ipairs(stats) do
        if row.name then
            byName[row.name] = row
        end
        if row.id then
            byId[row.id] = row
            byId[row.id:sub(1, 12)] = row
        end
    end
    local out = {}
    for _, item in ipairs(list) do
        local hit = byId[item.id] or byId[item.shortId] or byName[item.name]
        if not hit then
            out[#out + 1] = item
        else
            local next = {}
            for k, v in pairs(item) do
                next[k] = v
            end
            next.cpu = hit.cpu
            next.memPerc = hit.memPerc
            next.memUsed = hit.memUsed
            next.memLimit = hit.memLimit
            next.memText = formatBytes(hit.memUsed)
            next.netIn = hit.netIn
            next.netOut = hit.netOut
            next.netText = formatBytes(hit.netIn) .. " \u{2193}  " .. formatBytes(hit.netOut) .. " \u{2191}"
            next.pids = hit.pids
            out[#out + 1] = next
        end
    end
    return out
end

-- ── hardware / host ──

local function hardware(rows)
    local list = rows or {}
    local cpu, memUsed, memLimit, pids, netIn, netOut = 0, 0, 0, 0, 0, 0
    for _, row in ipairs(list) do
        cpu = cpu + (tonumber(row.cpu) or 0)
        memUsed = memUsed + (tonumber(row.memUsed) or 0)
        memLimit = memLimit + (tonumber(row.memLimit) or 0)
        pids = pids + (tonumber(row.pids) or 0)
        netIn = netIn + (tonumber(row.netIn) or 0)
        netOut = netOut + (tonumber(row.netOut) or 0)
    end
    local memPerc = (memLimit > 0) and ((memUsed / memLimit) * 100) or 0
    return {
        cpu = cpu,
        memUsed = memUsed,
        memLimit = memLimit,
        memPerc = memPerc,
        pids = pids,
        netIn = netIn,
        netOut = netOut,
    }
end

local function formatPercent(n)
    local value = tonumber(n) or 0
    if value > 0 and value < 0.1 then
        return "<0.1%"
    end
    if math.abs(value - math.floor(value + 0.5)) < 0.05 then
        return tostring(math.floor(value + 0.5)) .. "%"
    end
    return string.format("%.1f%%", value)
end

local function formatCores(n)
    local value = tonumber(n) or 0
    if not (value > 0) then
        return "0"
    end
    if value > 0 and value < 0.1 then
        return "<0.1"
    end
    if value >= 10 or math.abs(value - math.floor(value + 0.5)) < 0.05 then
        return tostring(math.floor(value + 0.5))
    end
    return string.format("%.1f", value)
end

local function formatUsedTotal(used, total, kind)
    local perc = (total > 0) and ((tonumber(used) / tonumber(total)) * 100) or 0
    local left = (kind == "cpu") and formatCores(used) or formatBytes(used)
    local right = (kind == "cpu") and formatCores(total) or formatBytes(total)
    return left .. "/" .. right .. " (" .. formatPercent(perc) .. ")"
end

-- Docker CPU% is 100% = one core. RAM/HD are compared to the host.
function M.composeHardware(statRows, host, diskUsed)
    local live = hardware(statRows)
    local cpuTotal = (host and host.cpuTotal and host.cpuTotal > 0) and host.cpuTotal or 0
    local memTotal = (host and host.memTotal and host.memTotal > 0) and host.memTotal or 0
    local diskTotal = (host and host.diskTotal and host.diskTotal > 0) and host.diskTotal or 0
    local cpuUsed = live.cpu / 100
    local disk = tonumber(diskUsed) or 0
    return {
        cpu = live.cpu,
        cpuUsed = cpuUsed,
        cpuTotal = cpuTotal,
        cpuPerc = (cpuTotal > 0) and ((cpuUsed / cpuTotal) * 100) or 0,
        cpuText = formatPercent(cpuPerc),
        memUsed = live.memUsed,
        memLimit = live.memLimit,
        memTotal = memTotal,
        memPerc = (memTotal > 0) and ((live.memUsed / memTotal) * 100) or 0,
        memText = formatUsedTotal(live.memUsed, memTotal, "bytes"),
        diskUsed = disk,
        diskTotal = diskTotal,
        diskPerc = (diskTotal > 0) and ((disk / diskTotal) * 100) or 0,
        diskText = formatUsedTotal(disk, diskTotal, "bytes"),
        pids = live.pids,
        netIn = live.netIn,
        netOut = live.netOut,
    }
end

function M.parseHost(text)
    local s = trim(tostring(text or ""))
    if s == "" then
        return { cpuTotal = 0, memTotal = 0, diskTotal = 0 }
    end
    local ok, obj = pcall(function()
        return noctalia.json.decode(s)
    end)
    if not ok or type(obj) ~= "table" then
        return { cpuTotal = 0, memTotal = 0, diskTotal = 0 }
    end
    return {
        cpuTotal = math.max(0, tonumber(obj.cpuTotal) or 0),
        memTotal = math.max(0, tonumber(obj.memTotal) or 0),
        diskTotal = math.max(0, tonumber(obj.diskTotal) or 0),
    }
end

M.formatBytes = formatBytes

-- ── actions ──

local function containerKey(item)
    local engine = tostring(item.engine or "docker")
    local cid = tostring(item.containerId or item.shortId or item.id or "")
    if cid == "" then
        return ""
    end
    return engine .. ":" .. cid
end

local function resourceKey(item)
    if not item then
        return ""
    end
    local kind = tostring(item.kind or "container")
    if kind == "container" then
        local cid = tostring(item.containerId or item.shortId or "")
        if cid == "" then
            return ""
        end
        return tostring(item.engine or "docker") .. ":" .. cid
    end
    local rid = tostring(item.resourceId or item.shortId or item.name or "")
    if rid == "" then
        return ""
    end
    return kind .. ":" .. tostring(item.engine or "docker") .. ":" .. rid
end

function M.resourceKey(item)
    return resourceKey(item)
end

function M.bulkJobs(list, verb)
    local action = tostring(verb or "")
    if action == "remove" or action == "rm" then
        return removeJobs(list)
    end
    if action ~= "start" and action ~= "stop" and action ~= "restart" then
        return {}
    end
    local dockerIds, podmanIds = {}, {}
    local seen = {}
    for _, item in ipairs(list or {}) do
        if not item or (item.kind and item.kind ~= "container") then
            -- skip
        elseif not (item.containerId or item.id) then
            -- skip
        elseif (action == "start" and item.running) or (action == "stop" and not item.running) then
            -- skip
        else
            local key = containerKey(item)
            if not seen[key] then
                seen[key] = true
                if item.engine == "podman" then
                    podmanIds[#podmanIds + 1] = item.containerId or item.id
                else
                    dockerIds[#dockerIds + 1] = item.containerId or item.id
                end
            end
        end
    end
    local jobs = {}
    if #dockerIds > 0 then
        jobs[#jobs + 1] = { engine = "docker", verb = action, ids = dockerIds }
    end
    if #podmanIds > 0 then
        jobs[#jobs + 1] = { engine = "podman", verb = action, ids = podmanIds }
    end
    return jobs
end

local function removeCommand(engine, kind, ids)
    local bin = (engine == "podman") and "podman" or "docker"
    if kind == "image" then
        return { bin, "rmi" }
    elseif kind == "volume" then
        return { bin, "volume", "rm" }
    elseif kind == "network" then
        return { bin, "network", "rm" }
    end
    return {}
end

local function removeJobs(list)
    local buckets = {}
    local seen = {}
    for _, item in ipairs(list or {}) do
        if not item or item.removable == false then
            -- skip
        else
            local kind = tostring(item.kind or "")
            if kind ~= "image" and kind ~= "volume" and kind ~= "network" then
                -- skip
            else
                local engine = (item.engine == "podman") and "podman" or "docker"
                local id = tostring(item.resourceId or item.name or "")
                if id ~= "" then
                    local key = resourceKey(item)
                    if not seen[key] then
                        seen[key] = true
                        local bucket = engine .. ":" .. kind
                        if not buckets[bucket] then
                            buckets[bucket] = { engine = engine, kind = kind, ids = {} }
                        end
                        buckets[bucket].ids[#buckets[bucket].ids + 1] = id
                    end
                end
            end
        end
    end
    local order = { "docker:image", "docker:volume", "docker:network", "podman:image", "podman:volume", "podman:network" }
    local jobs = {}
    for _, groupName in ipairs(order) do
        local group = buckets[groupName]
        if group and #group.ids > 0 then
            jobs[#jobs + 1] = {
                engine = group.engine,
                verb = "remove",
                ids = group.ids,
                command = removeCommand(group.engine, group.kind, group.ids),
            }
        end
    end
    return jobs
end

M.removeJobs = removeJobs

function M.actionCommand(job)
    local bin = (job.engine == "podman") and "podman" or "docker"
    if job.command then
        return job.command
    end
    local cmd = { bin, job.verb }
    for _, id in ipairs(job.ids) do
        cmd[#cmd + 1] = id
    end
    return cmd
end

local function nextAction(container)
    if not container then
        return ""
    end
    return container.running and "stop" or "start"
end

M.nextAction = nextAction

local function barLabel(stats)
    if not stats then
        return "\u{2014}"
    end
    return tostring(stats.running)
end

local function barEngine(stats, dockerOk, podmanOk)
    if stats and stats.engine == "podman" then
        return "podman"
    end
    if stats and stats.engine == "docker" then
        return "docker"
    end
    if stats and stats.engine == "both" then
        return "docker"
    end
    if dockerOk then
        return "docker"
    end
    if podmanOk then
        return "podman"
    end
    return ""
end

M.barLabel = barLabel
M.barEngine = barEngine
M.probeWhich = function(whichDone)
    -- With the preference preserved as an optimistic intent, there is nothing to probe
    -- synchronously: the fetch exit codes decide reality. `command -v` is PATH-dependent
    -- and the sandboxed service PATH can miss /usr/bin, so we keep it out of the loop.
    M.wantDocker = M.enginePref ~= "podman"
    M.wantPodman = M.enginePref ~= "docker"
    M.dockerInstalled = M.wantDocker
    M.podmanInstalled = M.wantPodman
    whichDone()
end

-- ── service runtime engine ──

local DEFAULT_INTERVAL_SEC = 5

local state = {
    available = false,
    engine = "",
    containers = {},
    images = {},
    volumes = {},
    networks = {},
    stats = { total = 0, running = 0, stopped = 0, unhealthy = 0, engine = "" },
    hardware = {},
}
local dockerOk = false
local podmanOk = false
local refreshing = false
local host = { cpuTotal = 0, memTotal = 0, diskTotal = 0 }
local statRows = {}
local diskUsed = 0

local statCache = { rows = {}, freshAt = 0 }

local function refreshStatsLazy()
    -- `docker/podman stats` is only meaningful for running containers and is expensive;
    -- refresh it at most every few ticks, and stop entirely when nothing is running.
    if #state.containers == 0 then
        statCache.rows = {}
        statCache.freshAt = 0
        return {}
    end
    if statCache.rows and noctalia.nowMs() < statCache.freshAt then
        return statCache.rows
    end
    return statCache.rows
end

local function publishState()
    -- attach live stats to the running containers so row-level CPU/RAM shows in the panel
    local attached = M.attachStats(state.containers, refreshStatsLazy())
    state.containers = attached
    local stats = M.summary(state.containers)
    local hw = M.composeHardware(statRows, host, diskUsed)
    noctalia.state.set("containers", {
        available = true,
        engine = M.barEngine(stats, dockerOk, podmanOk),
        containers = state.containers,
        images = state.images,
        volumes = state.volumes,
        networks = state.networks,
        stats = stats,
        hardware = hw,
    })
end

function M.fetchEngineList(engine, done)
    local command
    if engine == "podman" then
        command = { "podman", "ps", "-a", "--format", "json" }
    else
        command = { "docker", "ps", "-a", "--format", "{{json .}}" }
    end
    noctalia.runAsync(command, function(result)
        local ok = result and result.exitCode == 0
        local parsed = ok and parseList(result.stdout, engine) or { ok = false }
        done(ok, ok and parsed.containers or {})
    end)
end

local function selectedEngine()
    -- docker and podman are the same engine on many hosts (docker is a podman shim),
    -- so we never fetch both: pick the preferred binary and fall back to the other.
    return (M.enginePref == "docker") and "docker" or "podman"
end

local function refreshLists(done)
    done = done or function() end
    local engine = selectedEngine()
    M.fetchEngineList(engine, function(ok, containers)
        dockerOk = (engine == "docker") and ok or false
        podmanOk = (engine == "podman") and ok or false
        state.containers = ok and containers or {}
        done()
    end)
end

local function fetchEngineResources(engine, done)
    local bin = (engine == "podman") and "podman" or "docker"
    local fmt = "{{json .}}"
    local script = table.concat({
        bin .. " images --format '" .. fmt .. "'; echo " .. M.SEP_IMAGES .. ";",
        bin .. " volume ls --format '" .. fmt .. "'; echo " .. M.SEP_VOLUMES .. ";",
        bin .. " network ls --format '" .. fmt .. "'",
    }, "")
    noctalia.runAsync({ "sh", "-c", script }, function(result)
        local out = (result and result.stdout) or ""
        local images, volumes, networks = {}, {}, {}
        if result and result.exitCode == 0 then
            local imgPart, rest = out:match("^(.-)" .. M.SEP_IMAGES .. "(.*)$")
            local volPart, netPart = (rest or ""):match("^(.-)" .. M.SEP_VOLUMES .. "(.*)$")
            images = parseImages(imgPart or "", engine)
            volumes = parseVolumes(volPart or "", engine)
            networks = parseNetworks(netPart or "", engine)
        end
        done(images, volumes, networks)
    end)
end

local resourceCache = { freshAt = 0 }

local function refreshResources(done)
    done = done or function() end
    -- Images/volumes/networks change rarely; a single host runs podman/docker, so
    -- fetching and decoding them every poll is needless CPU churn that occasionally
    -- trips the VM budget. Re-fetch at most every 10s.
    if noctalia.nowMs() < resourceCache.freshAt then
        done()
        return
    end
    local engine = selectedEngine()
    fetchEngineResources(engine, function(i, v, n)
        state.images = i
        state.volumes = v
        state.networks = n
        resourceCache.freshAt = noctalia.nowMs() + 10000
        done()
    end)
end

local HOST_SCRIPT = "cpu=$(nproc); mem=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo); df -B1 / | awk 'NR==2{print $2}' | { read disk; printf '{\"cpuTotal\":%s,\"memTotal\":%s,\"diskTotal\":%s}\\n' $cpu $((mem * 1024)) $disk; }"

local function refreshHost(done)
    noctalia.runAsync({ "sh", "-c", HOST_SCRIPT }, function(result)
        if result and result.exitCode == 0 then
            host = M.parseHost(result.stdout)
        end
        done()
    end)
end

local function dfUsed(engine, done)
    local bin = (engine == "podman") and "podman" or "docker"
    local fmt = (engine == "podman") and "json" or "{{json .}}"
    noctalia.runAsync({ bin, "system", "df", "--format", fmt }, function(result)
        local used = 0
        if result and result.exitCode == 0 then
            used = M.parseSystemDf(result.stdout).used
        end
        done(used)
    end)
end

local function refreshStats(done)
    done = done or function() end
    local engine = selectedEngine()
    local anyRunning = false
    for _, c in ipairs(state.containers) do
        if c.running then
            anyRunning = true
            break
        end
    end
    if not anyRunning then
        statRows = {}
        diskUsed = 0
        statCache.rows = {}
        done()
        return
    end
    local pending = 2
    local function maybe()
        pending = pending - 1
        if pending == 0 then
            done()
        end
    end
    local bin = (engine == "podman") and "podman" or "docker"
    local fmt = (engine == "podman") and "json" or "{{json .}}"
    noctalia.runAsync({ bin, "stats", "--no-stream", "--format", fmt }, function(result)
        if result and result.exitCode == 0 then
            local parsed = M.parseStats(result.stdout)
            statRows = parsed.rows
            statCache.rows = parsed.rows
            statCache.freshAt = noctalia.nowMs() + 6000
        end
        maybe()
    end)
    dfUsed(engine, function(used)
        diskUsed = used
        maybe()
    end)
end

local function recognizeEngine()
    local engine = selectedEngine()
    if engine == "docker" then
        state.engine = dockerOk and "docker" or ""
    else
        state.engine = podmanOk and "podman" or ""
    end
end

local pendingRefresh = false

function M.refreshNow()
    if refreshing then
        pendingRefresh = true
        return
    end
    refreshing = true
    refreshLists(function()
        recognizeEngine()
        refreshResources(function()
            refreshStats(function()
                refreshHost(function()
                    refreshing = false
                    publishState()
                    if pendingRefresh then
                        pendingRefresh = false
                        M.refreshNow()
                    end
                end)
            end)
        end)
    end)
end

function M.init()
    M.enginePref = tostring(noctalia.getConfig("engine") or "auto"):lower()
    -- Normalise "auto": treat as wanting whichever exists.
    if M.enginePref ~= "podman" and M.enginePref ~= "docker" then
        M.enginePref = "auto"
    end
    -- Seed the installed flags optimistically from the preference; each poll then
    -- discovers the real engine(s) via the actual fetch exit code (dockerOk/podmanOk).
    -- We deliberately do NOT gate on `command -v`: the service's sandboxed PATH may not
    -- resolve docker/podman even though the daemon binary is present, which would turn
    -- every poll into an empty list. The fetch itself is the honest probe.
    M.dockerInstalled = M.enginePref ~= "podman"
    M.podmanInstalled = M.enginePref ~= "docker"
    noctalia.state.set("containers", { available = false, containers = {}, images = {}, volumes = {}, networks = {} })

    -- The panel signals "something changed (start/stop/restart/remove)" by writing a
    -- refresh command; re-poll immediately instead of waiting for the next tick.
    -- The first delivery may be nil — guard it.
    noctalia.state.watch("containers_refresh", function(cmd)
        if not cmd then
            return
        end
        -- A user action changed state: bypass the resource cache (images/volumes/
        -- networks) and the stats cache so the panel shows the new reality immediately.
        resourceCache.freshAt = 0
        statCache.freshAt = 0
        M.refreshNow()
    end)

    M.probeWhich(function()
        M.refreshNow()
    end)
    local seconds = tonumber(noctalia.getConfig("refresh_interval")) or DEFAULT_INTERVAL_SEC
    noctalia.setUpdateInterval(math.max(1, seconds) * 1000)
end

function update()
    -- Re-resolve the engine preference each tick in case a config changed without a callback.
    local desired = tostring(noctalia.getConfig("engine") or "auto"):lower()
    if desired ~= "podman" and desired ~= "docker" then
        desired = "auto"
    end
    if desired ~= M.enginePref then
        M.enginePref = desired
        M.refreshNow()
    else
        M.refreshNow()
    end
end

function onConfigChanged()
    M.enginePref = tostring(noctalia.getConfig("engine") or "auto"):lower()
    if M.enginePref ~= "podman" and M.enginePref ~= "docker" then
        M.enginePref = "auto"
    end
    M.refreshNow()
end

-- Noctalia has no `init()` global: the top-level chunk runs once at load. Register
-- the refresh watcher (and seed state) here, or panel refresh commands go nowhere.
M.init()

return M