--!nonstrict
-- YT-DLP bar widget: glyph + one-line tooltip driven entirely by service state.

local PANEL_ID = "mindset/ytdlp:panel"

local glyph = "brand-youtube-kids"
local extractText = ""

local function render()
    barWidget.setGlyph(glyph)
    barWidget.setTooltip(extractText)
end

local function refetch()
    local active = noctalia.state.get("active_job") or {}
    local extracting = noctalia.state.get("extracting") == true
    local status = tostring(active and active.status or "idle")

    if extracting then
        glyph = "loader-2"
        extractText = noctalia.tr("widget.extracting")
    elseif status == "downloading" or status == "preparing" then
        glyph = "download"
        local progress = (type(active.progress) == "table" and active.progress) or {}
        local percentText = tostring(progress.percentText or "")
        extractText = noctalia.tr("widget.downloading", { p = percentText })
    elseif status == "paused" then
        glyph = "player-pause"
        extractText = noctalia.tr("widget.paused")
    elseif status == "completed" then
        glyph = "check"
        extractText = noctalia.tr("widget.saved")
    elseif status == "error" then
        glyph = "alert-triangle"
        extractText = noctalia.tr("widget.failed", { e = tostring(active.error or "") })
    elseif status == "cancelled" then
        glyph = "player-stop"
        extractText = noctalia.tr("widget.cancelled")
    else
        glyph = "brand-youtube-kids"
        extractText = noctalia.tr("widget.idle")
    end
    render()
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
    noctalia.togglePanel(PANEL_ID)
end

function onScroll(axis, steps, startsGesture)
end

function update()
    refetch()
end

noctalia.setUpdateInterval(2000)

noctalia.state.watch("active_job", refetch)
noctalia.state.watch("extracting", refetch)

refetch()