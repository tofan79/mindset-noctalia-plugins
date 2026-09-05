--!nonstrict
--
-- Containers bar widget: a glyph plus a live tooltip. It owns no state -- it renders
-- whatever the service publishes and opens the panel on click.

local PANEL_ID = "mindset/containers:main"

local M = {}

local state = noctalia.state.get("containers") or { available = false }

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

function M.formatTooltip(s)
    s = s or {}
    if not s.available then
        return noctalia.tr("widget.loading")
    end
    local stats = s.stats or { total = 0, running = 0, stopped = 0, unhealthy = 0, engine = "" }
    local engine = stats.engine == "podman" and "podman"
        or ((stats.engine == "docker" or stats.engine == "both") and "docker")
        or s.engine or "?"
    local parts = {
        engine,
        noctalia.trp("widget.running", stats.running),
        noctalia.trp("widget.total", stats.total),
    }
    if stats.unhealthy and stats.unhealthy > 0 then
        parts[#parts + 1] = noctalia.trp("widget.unhealthy", stats.unhealthy)
    end
    if s.hardware and s.hardware.cpuText then
        parts[#parts + 1] = "CPU " .. s.hardware.cpuText
    end
    if s.hardware and s.hardware.memText then
        parts[#parts + 1] = "RAM " .. s.hardware.memText
    end
    if s.hardware and s.hardware.diskText then
        parts[#parts + 1] = "dsk " .. s.hardware.diskText
    end
    return table.concat(parts, " | ")
end

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph") or "brand-docker")
    local tooltip = M.formatTooltip(state)
    if noctalia.getConfig("show_running_count") ~= false and state and state.stats then
        tooltip = tostring(state.stats.running .. " | " .. tooltip)
    end
    barWidget.setTooltip(tooltip)
    local problem = (state and state.stats and state.stats.unhealthy and state.stats.unhealthy > 0)
    barWidget.setGlyphColor(problem and "error" or "on_surface")
end

function M.onClick()
    noctalia.togglePanel(PANEL_ID)
end

function M.onRightClick()
    noctalia.togglePanel(PANEL_ID)
end

noctalia.state.watch("containers", function(value)
    state = type(value) == "table" and value or { available = false }
    render()
end)

-- ── shell entry points (must be globals) ──

function onClick()
    M.onClick()
end

function onRightClick()
    M.onRightClick()
end

function onConfigChanged()
    render()
end

render()

return M