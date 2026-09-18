--!nonstrict
--
-- RakuOS Tools bar widget: badge with the number of available updates, a
-- spinner while checking, and a tooltip with image/package summary.
-- Click / right-click open the RakuOS Tools panel.

local PANEL_ID = "mindset/rakuos-tools:main"
local KEY = "rakuos_updates"

local M = {}
local state = {}

local function tr(key)
    return noctalia.tr(key) or key
end

local function countAvailable()
    local n = 0
    if state.image and state.image.available then
        n = n + 1
    end
    if state.packages and type(state.packages.count) == "number" then
        n = n + state.packages.count
    end
    return n
end

local function render()
    local checking = state.checking == true
    local count = countAvailable()
    local glyph = noctalia.getConfig("glyph") or "system-software-update"
    if checking then glyph = "loader" end
    barWidget.setGlyph(glyph)

    if not checking and noctalia.getConfig("show_badge") ~= false and count > 0 then
        barWidget.setText(tostring(count))
        barWidget.setGlyphColor("primary")
    else
        barWidget.setText("")
    end

    local imageRow
    if checking then
        imageRow = tr("widget.checking")
    elseif state.image and state.image.pending_reboot then
        imageRow = tr("widget.reboot_pending")
    elseif state.image and state.image.available then
        imageRow = tr("widget.update_available")
    else
        imageRow = tr("widget.uptodate")
    end

    local pkgRow
    local pcount = state.packages and state.packages.count or 0
    if checking then
        pkgRow = tr("widget.checking")
    elseif pcount > 0 then
        pkgRow = tostring(pcount) .. " " ..
            (pcount == 1 and tr("widget.updates_single") or tr("widget.updates_plural"))
    else
        pkgRow = tr("widget.uptodate")
    end

    barWidget.setTooltip({
        { tr("widget.tt_image"), imageRow },
        { tr("widget.tt_packages"), pkgRow },
    })
end

function M.onClick()
    noctalia.togglePanel(PANEL_ID)
end

function M.onRightClick()
    noctalia.togglePanel(PANEL_ID)
end

noctalia.state.watch(KEY, function(value)
    state = type(value) == "table" and value or {}
    render()
end)

function onClick() M.onClick() end
function onRightClick() M.onRightClick() end
function onConfigChanged() render() end

render()
return M