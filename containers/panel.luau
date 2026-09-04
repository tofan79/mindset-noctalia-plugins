--!nonstrict
--
-- Containers panel: live status of docker/podman containers, images, volumes and
-- networks with start/stop/restart and removal controls. It owns no state -- it renders
-- what the service publishes and sends commands back through `noctalia.state`.
--
-- Interactive props (onClick/onChange) must be the *names* of global functions -- the
-- ui bridge resolves handlers by name and cannot call a Lua closure.

local M = {}

local state = noctalia.state.get("containers") or { available = false }

local function tr(key, subst)
    return noctalia.tr(key, subst)
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

local function percent(frac)
    local v = tonumber(frac) or 0
    return string.format("%.0f%%", math.max(0, math.min(100, v * 100)))
end

-- ── summary / engine ──

local function statsSummary()
    if not state.available then
        return nil
    end
    return state.stats or { total = 0, running = 0, stopped = 0, unhealthy = 0, engine = "" }
end

local function engineLabel()
    if not state.available then
        return tr("panel.loading")
    end
    local engine = (state.stats and state.stats.engine) or state.engine or ""
    if engine == "both" then
        return tr("panel.engine_both")
    elseif engine == "podman" then
        return tr("panel.engine_podman")
    elseif engine == "docker" then
        return tr("panel.engine_docker")
    end
    return tr("panel.engine_none")
end

-- ── container rows ──

local function stateLabel(container)
    if container.health and container.health ~= "" then
        return container.health
    end
    return container.state ~= "" and container.state or tr("panel.state_unknown")
end

local function stateColor(container)
    if container.problem then
        return "error"
    end
    if container.running then
        return "success"
    end
    return "on_surface_variant"
end

local function runAction(command)
    noctalia.runAsync(command, function(result)
        -- force the panel to re-read after the engine settles; the service poll updates it
        state = noctalia.state.get("containers") or { available = false }
        render()
    end)
end

local function engineBin(engine)
    return (engine == "podman") and "podman" or "docker"
end

M.containerRows = function(containers)
    containers = containers or {}
    local rows = {}
    for _, c in ipairs(containers) do
        local bin = engineBin(c.engine)
        local id = c.containerId
        rows[#rows + 1] = ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = c.running and "circle-check" or "circle", size = 12, color = stateColor(c) }),
            ui.column({ gap = 1, flexGrow = 1 }, {
                ui.row({ gap = 6 }, {
                    ui.label({ text = c.name, fontWeight = "bold", flexGrow = 1 }),
                    ui.label({ text = stateLabel(c), fontSize = 10, color = stateColor(c) }),
                }),
                ui.label({ text = c.image, fontSize = 10, color = "on_surface_variant" }),
            }),
            ui.button({ glyph = "player-play", variant = "ghost", tooltip = tr("panel.start"),
                enabled = not c.running, onClick = function()
                    runAction({ bin, "start", id })
                end }),
            ui.button({ glyph = "player-stop", variant = "ghost", tooltip = tr("panel.stop"),
                enabled = c.running, onClick = function()
                    runAction({ bin, "stop", id })
                end }),
            ui.button({ glyph = "rotate-clockwise", variant = "ghost", tooltip = tr("panel.restart"),
                onClick = function()
                    runAction({ bin, "restart", id })
                end }),
        })
    end
    return rows
end

-- ── image / volume / network rows ──

local function resourceRow(item)
    local size = (item.kind == "image") and (item.sizeText or formatBytes(item.size)) or item.driver
    local bin = engineBin(item.engine)
    local removeArgs = { "rmi" }
    if item.kind == "volume" then
        removeArgs = { "volume", "rm" }
    elseif item.kind == "network" then
        removeArgs = { "network", "rm" }
    end
    return ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = item.kind == "image" and "photo" or item.kind == "volume" and "database"
            or "network", size = 12, color = "on_surface_variant" }),
        ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({ text = item.name, fontWeight = "bold" }),
            ui.label({ text = size, fontSize = 10, color = "on_surface_variant" }),
        }),
        ui.button({ glyph = "trash", variant = "ghost", tooltip = tr("panel.remove"),
            enabled = item.removable, onClick = function()
                local cmd = { bin }
                for _, arg in ipairs(removeArgs) do
                    cmd[#cmd + 1] = arg
                end
                cmd[#cmd + 1] = item.resourceId
                runAction(cmd)
            end }),
    })
end

M.resourceRows = function(kind, items)
    items = items or {}
    local rows = {}
    for _, item in ipairs(items) do
        if item.kind == kind then
            rows[#rows + 1] = resourceRow(item)
        end
    end
    return rows
end

-- ── hardware summary section ──

local function hardwareRow(label, glyph, text)
    return ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = glyph, size = 14, color = "on_surface_variant" }),
        ui.label({ text = label, color = "on_surface_variant", width = 48 }),
        ui.spacer({ flexGrow = 1 }),
        ui.label({ text = text, color = "on_surface_variant", fontSize = 11 }),
    })
end

local function summarySection(children)
    local hw = state.hardware
    if not state.available or not hw then
        return
    end
    children[#children + 1] = ui.separator({})
    children[#children + 1] = ui.label({
        text = tr("panel.resources"),
        color = "on_surface_variant", fontSize = 12, fontWeight = "bold",
    })
    if hw.cpuText then
        children[#children + 1] = hardwareRow("CPU", "cpu", hw.cpuText)
    end
    if hw.memText then
        children[#children + 1] = hardwareRow("RAM", "chart-donut", hw.memText)
    end
    if hw.diskText then
        children[#children + 1] = hardwareRow("Disk", "database", hw.diskText)
    end
    if (hw.pids or 0) > 0 then
        children[#children + 1] = hardwareRow("PIDs", "activity", tostring(hw.pids))
    end
end

-- ── main sections ──

local function sectionTitle(key, count)
    local text = tr(key)
    if type(count) == "number" then
        text = text .. "  (" .. tostring(count) .. ")"
    end
    return ui.label({ text = text, color = "on_surface_variant", fontSize = 12, fontWeight = "bold" })
end

local function containerSection(children)
    local containers = (type(state) == "table" and state.containers) or {}
    children[#children + 1] = sectionTitle("panel.containers", #containers)
    if #containers == 0 then
        children[#children + 1] = ui.label({ text = tr("panel.no_containers"), fontSize = 11 })
        return
    end
    for _, row in ipairs(M.containerRows(containers)) do
        children[#children + 1] = row
    end
end

local function resourceSection(children, key, kind)
    local items = (type(state) == "table" and state[kind]) or {}
    children[#children + 1] = ui.separator({})
    children[#children + 1] = sectionTitle(key, #items)
    if #items == 0 then
        children[#children + 1] = ui.label({ text = tr("panel.none"), fontSize = 11 })
        return
    end
    for _, row in ipairs(M.resourceRows(kind, items)) do
        children[#children + 1] = row
    end
end

local function body()
    local stats = statsSummary()
    local children = {}

    children[#children + 1] = ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = "container", size = 22, color = "primary" }),
        ui.column({ gap = 0, flexGrow = 1 }, {
            ui.label({ text = tr("panel.title"), fontSize = 17, fontWeight = "bold" }),
            ui.label({ text = engineLabel(), fontSize = 11, color = "on_surface_variant" }),
        }),
    })

    if not state.available then
        children[#children + 1] = ui.label({ text = tr("panel.loading"), color = "on_surface_variant", fontSize = 11 })
        return children
    end

    summarySection(children)
    containerSection(children)
    resourceSection(children, "panel.images", "images")
    resourceSection(children, "panel.volumes", "volumes")
    resourceSection(children, "panel.networks", "networks")

    return children
end

local function footer()
    local stats = statsSummary()
    local text = "—"
    if stats then
        text = tr("panel.summary", {
            running = tostring(stats.running),
            total = tostring(stats.total),
            unhealthy = tostring(stats.unhealthy or 0),
        })
    end
    return ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = text, color = "on_surface_variant", fontSize = 11, flexGrow = 1 }),
        ui.button({ text = tr("panel.settings"), glyph = "settings", variant = "ghost", onClick = "onOpenSettings" }),
    })
end

local function render()
    panel.render(ui.column({ padding = 20, gap = 14, flexGrow = 1 }, {
        ui.scroll({ flexGrow = 1, gap = 12 }, body()),
        footer(),
    }))
end

-- ── shell entry points (must be globals) ──

function onOpen()
    state = noctalia.state.get("containers") or { available = false }
    render()
end

function onOpenSettings()
    noctalia.openSettings()
end

function onCloseClicked()
    panel.close()
end

noctalia.state.watch("containers", function(value)
    state = type(value) == "table" and value or { available = false }
    render()
end)

return M