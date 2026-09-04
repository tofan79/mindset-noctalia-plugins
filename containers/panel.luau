--!nonstrict
--
-- Containers panel: a faithful Luau port of the dockmarchy tidy panel.
--
--   1. Hero header (engine title + live meta, click to refresh)
--   2. Hardware gauges (CPU / RAM / Disk) rendered with progress bars
--   3. Kind tab row: Containers | Images | Volumes | Networks
--   4. Filter row (containers only): All | Running | Stopped
--   5. Search field
--   6. Bulk command bar (select-all + start/stop/restart/remove) acting on
--      whatever rows are checked
--   7. The active kind's list, grouped by compose project
--
-- The panel owns no data -- it renders whatever the service publishes under the
-- "containers" state key. Interactive props (onClick/onChange) are closures that
-- mutate the module-level uiState and call render(); the ui bridge keeps the
-- panel module alive between renders.

local M = {}

local KIND_IDS = { "containers", "images", "volumes", "networks" }
local FILTER_IDS = { "all", "running", "stopped" }

local uiState = {
    kind = "containers",
    kindIndex = 0,
    filter = "all",
    filterIndex = 0,
    query = "",
    selectedKeys = {},
    revision = 0,
}

local state = noctalia.state.get("containers") or { available = false }

-- Forward-declared so the selection/action helpers (defined higher up) can capture it
-- as an upvalue; it is assigned just before the shell entry points at the bottom.
local render
local trpKind
local actionButton

local function tr(key, subst)
    return noctalia.tr(key, subst)
end

local function trim(s)
    return (tostring(s or "")):match("^%s*(.-)%s*$")
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

local function percentOf(fraction)
    local v = tonumber(fraction) or 0
    return math.max(0, math.min(1, v))
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

function M.resourceKey(item)
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

-- ── derived data (mirrors dockmarchy Panel.qml catalog/filter/group) ──

local function catalog()
    if uiState.kind == "images" then
        return state.images or {}
    elseif uiState.kind == "volumes" then
        return state.volumes or {}
    elseif uiState.kind == "networks" then
        return state.networks or {}
    end
    return state.containers or {}
end

local function filterBy(list, filter)
    list = list or {}
    if filter == "running" then
        local out = {}
        for _, item in ipairs(list) do
            if item.running then
                out[#out + 1] = item
            end
        end
        return out
    elseif filter == "stopped" then
        local out = {}
        for _, item in ipairs(list) do
            if not item.running then
                out[#out + 1] = item
            end
        end
        return out
    end
    return list
end

local function searchHaystack(item)
    if not item then
        return ""
    end
    return table.concat({
        item.name or "",
        item.service or "",
        item.project or "",
        item.image or "",
        item.repository or "",
        item.tag or "",
        item.driver or "",
        item.status or "",
        item.state or "",
        item.containerId or "",
        item.resourceId or "",
    }, " "):lower()
end

local function searchBy(list, query)
    list = list or {}
    local needle = trim(query):lower()
    if needle == "" then
        return list
    end
    local out = {}
    for _, item in ipairs(list) do
        if searchHaystack(item):find(needle, 1, true) then
            out[#out + 1] = item
        end
    end
    return out
end

local function visibleItems()
    local filtered = filterBy(catalog(), uiState.kind == "containers" and uiState.filter or "all")
    return searchBy(filtered, uiState.query)
end

local function groupByProject(list)
    local order = {}
    local map = {}
    for _, item in ipairs(list) do
        local key = item.project or ""
        if not map[key] then
            map[key] = { name = key, running = 0, total = 0, problem = 0, containers = {} }
            order[#order + 1] = key
        end
        local group = map[key]
        group.containers[#group.containers + 1] = item
        group.total = group.total + 1
        if item.running then
            group.running = group.running + 1
        end
        if item.problem then
            group.problem = group.problem + 1
        end
    end
    local out = {}
    for _, key in ipairs(order) do
        out[#out + 1] = map[key]
    end
    return out
end

-- ── selection helpers ──

local function selectedMap()
    local map = {}
    for _, key in ipairs(uiState.selectedKeys) do
        map[key] = true
    end
    return map
end

local function isSelected(item)
    local key = M.resourceKey(item)
    return key ~= "" and selectedMap()[key] == true
end

local function selectedItems(list)
    local map = selectedMap()
    local out = {}
    for _, item in ipairs(list) do
        local key = M.resourceKey(item)
        if key ~= "" and map[key] then
            out[#out + 1] = item
        end
    end
    return out
end

local function selectedIn(items)
    local map = selectedMap()
    local n = 0
    for _, item in ipairs(items) do
        local key = M.resourceKey(item)
        if key ~= "" and map[key] then
            n = n + 1
        end
    end
    return n
end

local function allVisibleSelected()
    local list = visibleItems()
    return #list > 0 and selectedIn(list) == #list
end

local function toggleSelected(item)
    local key = M.resourceKey(item)
    if key == "" then
        return
    end
    local map = selectedMap()
    map[key] = not map[key]
    local next = {}
    for k in pairs(map) do
        if map[k] then
            next[#next + 1] = k
        end
    end
    uiState.selectedKeys = next
    uiState.revision = uiState.revision + 1
    render()
end

local function toggleSelectAllVisible()
    local list = visibleItems()
    local map = selectedMap()
    local allOn = #list > 0 and selectedIn(list) == #list
    for _, item in ipairs(list) do
        local key = M.resourceKey(item)
        if key ~= "" then
            map[key] = allOn and false or true
        end
    end
    local next = {}
    for k in pairs(map) do
        if map[k] then
            next[#next + 1] = k
        end
    end
    uiState.selectedKeys = next
    uiState.revision = uiState.revision + 1
    render()
end

local function toggleGroup(group)
    if not group or not group.containers then
        return
    end
    local map = selectedMap()
    local checked = selectedIn(group.containers) < #group.containers
    for _, item in ipairs(group.containers) do
        local key = M.resourceKey(item)
        if key ~= "" then
            map[key] = checked
        end
    end
    local next = {}
    for k in pairs(map) do
        if map[k] then
            next[#next + 1] = k
        end
    end
    uiState.selectedKeys = next
    uiState.revision = uiState.revision + 1
    render()
end

-- ── actions (bulk, faithful to dockmarchy runSelected/runBulkAction) ──

local function engineBinOf(item)
    return (item.engine == "podman") and "podman" or "docker"
end

local function commandFor(action, item)
    local bin = engineBinOf(item)
    if uiState.kind == "containers" then
        return { bin, action, item.containerId or item.shortId }
    end
    -- resources: remove only (images/volumes/networks)
    local verb = "rmi"
    if item.kind == "volume" then
        verb = "volume rm"
    elseif item.kind == "network" then
        verb = "network rm"
    end
    local parts = { bin }
    for part in tostring(verb):gmatch("%S+") do
        parts[#parts + 1] = part
    end
    parts[#parts + 1] = item.resourceId or item.shortId or item.name
    return parts
end

local function runBulkAction(action)
    local targets = selectedItems(catalog())
    if #targets == 0 then
        return
    end
    local left = #targets
    for _, item in ipairs(targets) do
        noctalia.runAsync(commandFor(action, item), function()
            left = left - 1
            if left <= 0 then
                uiState.selectedKeys = {}
                uiState.revision = uiState.revision + 1
                render()
            end
        end)
    end
end

local function refreshNow()
    uiState.revision = uiState.revision + 1
    render()
end

-- ── engine / status helpers ──

local function engineTitle()
    if not state.available then
        return tr("panel.title")
    end
    local engine = (state.stats and state.stats.engine) or state.engine or ""
    if engine == "both" then
        return tr("panel.engine_both")
    elseif engine == "podman" then
        return tr("panel.engine_podman")
    elseif engine == "docker" then
        return tr("panel.engine_docker")
    end
    return tr("panel.title")
end

local function heroMeta()
    if not state.available then
        return tr("panel.loading")
    end
    if uiState.kind == "images" then
        local n = #(state.images or {})
        return n == 0 and tr("panel.empty_images") or trpKind("images", n)
    elseif uiState.kind == "volumes" then
        local n = #(state.volumes or {})
        return n == 0 and tr("panel.empty_volumes") or trpKind("volumes", n)
    elseif uiState.kind == "networks" then
        local n = #(state.networks or {})
        return n == 0 and tr("panel.empty_networks") or trpKind("networks", n)
    end
    local stats = state.stats or { running = 0, total = 0 }
    if stats.total == 0 then
        return tr("panel.empty")
    end
    local text = tr("panel.summary", {
        running = tostring(stats.running or 0),
        total = tostring(stats.total or 0),
        unhealthy = tostring(stats.unhealthy or 0),
    })
    return text
end

trpKind = function(kind, count)
    local key = "panel." .. kind .. "_count"
    return noctalia.trp(key, count)
end

local function statusColor(item)
    if item and item.problem then
        return "error"
    elseif item and item.running then
        return "success"
    end
    return "on_surface_variant"
end

local function metaLine(item)
    if not item then
        return ""
    end
    local kind = item.kind or "container"
    if kind == "image" then
        local size = (item.sizeText ~= "" and item.sizeText) or formatBytes(item.size)
        local parts = { size }
        if item.used and item.used > 0 then
            parts[#parts + 1] = tostring(item.used) .. "x"
        end
        if item.dangling then
            parts[#parts + 1] = tr("panel.dangling")
        end
        if item.created and item.created ~= "" then
            parts[#parts + 1] = item.created
        end
        if item.shortId and item.shortId ~= "" then
            parts[#parts + 1] = item.shortId
        end
        return table.concat(parts, "  ·  ")
    end
    if kind == "volume" then
        local parts = {}
        if item.driver and item.driver ~= "" then
            parts[#parts + 1] = item.driver
        end
        if item.anonymous then
            parts[#parts + 1] = tr("panel.anonymous")
        end
        if item.scope and item.scope ~= "" then
            parts[#parts + 1] = item.scope
        end
        return table.concat(parts, "  ·  ")
    end
    if kind == "network" then
        local parts = {}
        if item.driver and item.driver ~= "" then
            parts[#parts + 1] = item.driver
        end
        if item.builtin then
            parts[#parts + 1] = tr("panel.builtin")
        end
        if item.internal then
            parts[#parts + 1] = tr("panel.internal")
        end
        if item.scope and item.scope ~= "" then
            parts[#parts + 1] = item.scope
        end
        return table.concat(parts, "  ·  ")
    end
    -- containers
    local parts = {}
    if item.running and item.cpu ~= nil then
        local cpu = tonumber(item.cpu) or 0
        if cpu > 0 then
            parts[#parts + 1] = string.format("%.1f", cpu) .. "% CPU"
        end
    end
    if item.running and item.memPerc ~= nil then
        local memText = (item.memText and item.memText ~= "") and (item.memText .. " ") or ""
        local memPerc = tonumber(item.memPerc) or 0
        parts[#parts + 1] = memText .. string.format("%.1f", memPerc) .. "%"
    end
    if item.status and item.status ~= "" then
        parts[#parts + 1] = item.status
    elseif item.state and item.state ~= "" then
        parts[#parts + 1] = item.state
    end
    if item.image and item.image ~= "" then
        parts[#parts + 1] = item.image
    end
    if item.ports and item.ports ~= "" then
        parts[#parts + 1] = item.ports
    end
    -- drop empty tokens caused by a 0% cpu stamp
    local kept = {}
    for _, p in ipairs(parts) do
        if p ~= "" then
            kept[#kept + 1] = p
        end
    end
    return table.concat(kept, "  ·  ")
end

local function rowTitle(item)
    if not item then
        return ""
    end
    return (item.service ~= "" and item.service) or item.name or ""
end

-- ── hardware gauges ──

local function gauge(label, glyph, fraction, percentText, usedText, totalText, hot)
    local percentColor = hot and "error" or "primary"
    local fill = hot and "error" or "primary"
    return ui.column({ gap = 6, flexGrow = 1 }, {
        ui.row({ align = "center", gap = 6 }, {
            ui.glyph({ name = glyph, size = 13, color = hot and "error" or "on_surface_variant" }),
            ui.label({ text = label, color = "on_surface_variant", fontSize = 11, flexGrow = 1, fontWeight = "bold" }),
            ui.label({ text = percentText, color = percentColor, fontSize = 11, fontWeight = "bold" }),
        }),
        ui.progress({ height = 5, progress = percentOf(fraction), fill = fill, track = "surface_variant", radius = 3 }),
        ui.label({ text = usedText .. " / " .. totalText, color = "on_surface_variant", fontSize = 10 }),
    })
end

local function percentText(v)
    local n = tonumber(v) or 0
    if n > 0 and n < 0.1 then
        return "<0.1%"
    end
    if math.abs(n - math.floor(n + 0.5)) < 0.05 then
        return tostring(math.floor(n + 0.5)) .. "%"
    end
    return string.format("%.1f", n) .. "%"
end

local function hardwareSection()
    local hw = state.hardware
    if not hw then
        return {}
    end
    local function frac(v)
        return (tonumber(v) or 0) / 100
    end
    local cpuPerc = tonumber(hw.cpuPerc) or 0
    local memPerc = tonumber(hw.memPerc) or 0
    local diskPerc = tonumber(hw.diskPerc) or 0
    return {
        ui.column({ gap = 8, padding = 8 }, {
            ui.label({ text = tr("panel.hardware"):upper(), color = "on_surface", fontSize = 11, fontWeight = "bold" }),
            ui.row({ gap = 10, align = "center" }, {
                gauge("CPU", "cpu", frac(cpuPerc), percentText(cpuPerc),
                    formatCores(hw.cpuUsed), formatCores(hw.cpuTotal), cpuPerc >= 80),
                gauge("RAM", "chart-donut", frac(memPerc), percentText(memPerc),
                    formatBytes(hw.memUsed), formatBytes(hw.memTotal), memPerc >= 90),
                gauge("HD", "database", frac(diskPerc), percentText(diskPerc),
                    formatBytes(hw.diskUsed), formatBytes(hw.diskTotal), diskPerc >= 90),
            }),
        }),
    }
end

-- ── tab / filter button rows ──

local function kindRow()
    local children = {}
    for index, id in ipairs(KIND_IDS) do
        children[#children + 1] = ui.button({
            text = tr("panel.kind_" .. id),
            variant = (uiState.kind == id) and "primary" or "ghost",
            controlSize = "sm",
            flexGrow = 1,
            onClick = function()
                uiState.kind = id
                uiState.kindIndex = index - 1
                uiState.query = ""
                uiState.selectedKeys = {}
                uiState.revision = uiState.revision + 1
                render()
            end,
        })
    end
    return ui.row({ gap = 6 }, children)
end

local function filterRow()
    if uiState.kind ~= "containers" then
        return nil
    end
    local children = {}
    for index, id in ipairs(FILTER_IDS) do
        children[#children + 1] = ui.button({
            text = tr("panel.filter_" .. id),
            variant = (uiState.filter == id) and "primary" or "ghost",
            controlSize = "sm",
            flexGrow = 1,
            onClick = function()
                uiState.filter = id
                uiState.filterIndex = index - 1
                uiState.revision = uiState.revision + 1
                render()
            end,
        })
    end
    return ui.row({ gap = 6 }, children)
end

local function searchRow()
    return ui.row({ align = "center", gap = 6 }, {
        ui.glyph({ name = "search", size = 14, color = "on_surface_variant" }),
        ui.input({
            key = "container-search-" .. uiState.revision,
            placeholder = tr("panel.search"),
            value = uiState.query,
            flexGrow = 1,
            onChange = function(value)
                uiState.query = value or ""
                uiState.revision = uiState.revision + 1
                render()
            end,
        }),
    })
end

-- ── command bar ──

local function selectionGlyph(allOn, partial)
    if allOn then
        return "circle-check-filled"
    elseif partial then
        return "circle-minus"
    end
    return "circle"
end

local function commandBar()
    local list = visibleItems()
    if #list == 0 then
        return nil
    end
    local allOn = allVisibleSelected()
    local partial = selectedIn(list) > 0 and not allOn
    local selectedCount = selectedIn(catalog())
    local children = {}

    children[#children + 1] = ui.button({
        glyph = selectionGlyph(allOn, partial),
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("panel.select_all"),
        onClick = toggleSelectAllVisible,
    })

    local label = selectedCount > 0
        and (selectedCount .. " " .. tr("panel.selected"))
        or tr("panel.select_all")
    children[#children + 1] = ui.label({ text = label, color = "on_surface_variant", fontSize = 11, flexGrow = 1 })

    if uiState.kind == "containers" then
        children[#children + 1] = actionButton("player-play", "panel.start", "start", selectedCount > 0)
        children[#children + 1] = actionButton("player-stop", "panel.stop", "stop", selectedCount > 0)
        children[#children + 1] = actionButton("rotate-clockwise", "panel.restart", "restart", selectedCount > 0)
    else
        children[#children + 1] = actionButton("trash", "panel.remove", "remove", selectedCount > 0)
    end

    return ui.row({ align = "center", gap = 6 }, children)
end

actionButton = function(glyphName, tooltipKey, action, enabled)
    return ui.button({
        glyph = glyphName,
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr(tooltipKey),
        enabled = enabled,
        onClick = function()
            runBulkAction(action)
        end,
    })
end

-- ── list rendering ──

local function selectionBox(item)
    local checked = isSelected(item)
    return ui.button({
        glyph = checked and "circle-check" or "circle",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
            toggleSelected(item)
        end,
    })
end

local function statusDot(item)
    return ui.glyph({ name = "circle-filled", size = 7, color = statusColor(item) })
end

local function containerRowChild(item)
    local children = {
        selectionBox(item),
        statusDot(item),
        ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({
                text = rowTitle(item),
                color = item.problem and "error" or "on_surface",
                fontSize = 13,
                fontWeight = "bold",
            }),
            ui.label({ text = metaLine(item), color = "on_surface_variant", fontSize = 10 }),
        }),
    }
    return ui.row({
        key = M.resourceKey(item),
        align = "center",
        gap = 8,
        padding = 6,
        onClick = function()
            toggleSelected(item)
        end,
    }, children)
end

local function groupSection(group)
    local allOn = selectedIn(group.containers) == #group.containers
    local partial = selectedIn(group.containers) > 0 and not allOn
    local children = {
        ui.row({ align = "center", gap = 6, padding = 4 }, {
            ui.button({
                glyph = selectionGlyph(allOn, partial),
                variant = "ghost",
                controlSize = "sm",
                onClick = function()
                    toggleGroup(group)
                end,
            }),
            ui.label({
                text = (group.name == "" and tr("panel.project_default") or group.name):upper()
                    .. "  " .. tostring(group.running) .. "/" .. tostring(group.total),
                color = group.problem > 0 and "error" or "primary",
                fontSize = 11,
                fontWeight = "bold",
                flexGrow = 1,
            }),
        }),
    }
    for _, item in ipairs(group.containers) do
        children[#children + 1] = containerRowChild(item)
    end
    return ui.column({ gap = 2 }, children)
end

local function emptyText()
    local needle = trim(uiState.query)
    local kind = uiState.kind
    if needle ~= "" then
        return tr("panel.no_match")
    elseif kind == "images" then
        return tr("panel.empty_images")
    elseif kind == "volumes" then
        return tr("panel.empty_volumes")
    elseif kind == "networks" then
        return tr("panel.empty_networks")
    end
    return tr("panel.empty")
end

local function listSection()
    local list = visibleItems()
    if #list == 0 then
        return { ui.label({ text = emptyText(), color = "on_surface_variant", fontSize = 12, flexGrow = 1 }) }
    end
    local children = {}
    for _, group in ipairs(groupByProject(list)) do
        children[#children + 1] = groupSection(group)
    end
    return children
end

-- ── chrome (hero / header) ──

local function heroBadge()
    local stats = (state and state.stats) or { running = 0, total = 0 }
    local running = stats.running or 0
    local total = stats.total or 0
    local color = "on_surface"
    if running > 0 and running == total and (stats.unhealthy or 0) == 0 then
        color = "success"
    elseif (stats.unhealthy or 0) > 0 then
        color = "error"
    end
    return ui.button({
        text = tostring(running) .. "/" .. tostring(total),
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("panel.refresh"),
        onClick = refreshNow,
    })
end

local function hero()
    local hasEngine = state.available and state.stats and (state.stats.running or 0) > 0
    local iconColor = state.available and state.stats and state.stats.unhealthy and state.stats.unhealthy > 0 and "error" or (hasEngine and "primary" or "on_surface_variant")
    return ui.row({ align = "center", gap = 10 }, {
        ui.glyph({ name = "container", size = 24, color = iconColor }),
        ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({ text = engineTitle(), fontSize = 17, fontWeight = "bold", color = "on_surface" }),
            ui.label({ text = heroMeta(), fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
        }),
        heroBadge(),
    })
end

-- ── render ──

local function body()
    local children = {}
    if state.available then
        local hw = hardwareSection()
        for _, node in ipairs(hw) do
            children[#children + 1] = node
        end
    end
    children[#children + 1] = kindRow()
    local filters = filterRow()
    if filters then
        children[#children + 1] = filters
    end
    children[#children + 1] = searchRow()
    local cmdBar = commandBar()
    if cmdBar then
        children[#children + 1] = cmdBar
    end
    local list = listSection()
    for _, node in ipairs(list) do
        children[#children + 1] = node
    end
    return children
end

local function footer()
    local text = state.available and state.stats and (state.stats.engine ~= "" and state.stats.engine or "?") or tr("panel.loading")
    local enginePref = tostring(noctalia.getConfig("engine") or "auto")
    local footerText = (enginePref == "auto") and tr("panel.subtitle") or engineTitle()
    return ui.row({ align = "center", gap = 6 }, {
        ui.label({ text = footerText, color = "on_surface_variant", fontSize = 10, flexGrow = 1 }),
        ui.label({ text = text, color = "on_surface_variant", fontSize = 10 }),
        ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = tr("panel.refresh"), onClick = refreshNow }),
        ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = tr("panel.settings"), onClick = "onOpenSettings" }),
    })
end

render = function()
    panel.render(ui.column({ padding = 18, gap = 12, flexGrow = 1 }, {
        hero(),
        ui.separator({}),
        ui.scroll({ flexGrow = 1, gap = 12 }, body()),
        ui.separator({}),
        footer(),
    }))
end

-- ── shell entry points (must be globals) ──

function onOpen()
    state = noctalia.state.get("containers") or { available = false }
    uiState.query = ""
    uiState.selectedKeys = {}
    uiState.revision = uiState.revision + 1
    render()
end

function onCloseClicked()
    panel.close()
end

function onOpenSettings()
    noctalia.openSettings()
end

noctalia.state.watch("containers", function(value)
    state = type(value) == "table" and value or { available = false }
    render()
end)

return M