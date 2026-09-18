--!nonstrict
--
-- RakuOS Tools control-center shortcut tile: label and active state reflect
-- pending updates; click opens the RakuOS Tools panel.

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

local function labelFor()
    if state.checking then
        return tr("shortcut.checking")
    end
    if state.image and state.image.pending_reboot then
        return tr("shortcut.reboot")
    end
    local count = countAvailable()
    if count > 0 then
        return tostring(count) .. " " .. (count == 1 and tr("shortcut.update") or tr("shortcut.updates"))
    end
    return tr("shortcut.uptodate")
end

local function render()
    shortcut.setLabel(labelFor())
    shortcut.setIcon(state.checking and "loader" or (noctalia.getConfig("glyph") or "system-software-update"))
    shortcut.setActive(
        state.checking == true
        or countAvailable() > 0
        or (state.image and state.image.pending_reboot == true)
    )
    shortcut.setEnabled(true)
end

noctalia.state.watch(KEY, function(value)
    state = type(value) == "table" and value or {}
    render()
end)

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

function onConfigChanged()
    render()
end

render()
return M