--!nonstrict
-- Layout switcher for the active Hyprland workspace, replacing the rofi picker.
-- Panel styled after KineticWE's layout picker. Applying mirrors
-- ~/.config/hypr/scripts/switch-layouts.sh: a workspace rule scoped to the
-- current workspace id, so each workspace keeps its own layout.

local layouts = {
  { name = "Deck Stack", value = "lua:deck",  glyph = "layers-difference" },
  { name = "Dwindle",    value = "dwindle",   glyph = "layout-2" },
  { name = "Fair Grid",  value = "lua:fair",  glyph = "layout-board-split" },
  { name = "Master",     value = "master",    glyph = "layout-sidebar" },
  { name = "Monocle",    value = "monocle",   glyph = "square" },
  { name = "Scrolling",  value = "scrolling", glyph = "arrows-horizontal" },
}

local isOpen = false
local currentLayout = ""
local workspaceId = nil

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function selectLayout(layout)
  local id = tostring(workspaceId or "")
  if id == "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.no_workspace"))
    return
  end

  local lua = string.format(
    "hl.workspace_rule({ workspace = tostring(%s), layout = %q })",
    id, layout.value
  )
  noctalia.runAsync("hyprctl eval " .. shellQuote(lua), function(result)
    if result.exitCode == 0 then
      noctalia.notify(noctalia.tr("title"), noctalia.tr("notification.switched", { name = layout.name }))
    else
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.apply_failed"))
    end
    panel.close()
  end)
end

local function render()
  local children = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.separator({}),
  }

  for _, layout in ipairs(layouts) do
    local selected = currentLayout ~= ""
      and (currentLayout == layout.value or ("lua:" .. currentLayout) == layout.value)
    table.insert(children, ui.button({
      key = "layout-" .. layout.value,
      text = layout.name,
      glyph = layout.glyph,
      variant = selected and "primary" or "default",
      contentAlign = "start",
      onClick = function()
        selectLayout(layout)
      end,
    }))
  end

  panel.render(ui.column({ gap = 6, padding = 10 }, children))
end

function onOpen(_context)
  isOpen = true
  noctalia.runAsync("hyprctl activeworkspace -j", function(result)
    if result.exitCode == 0 then
      local data = noctalia.json.decode(result.stdout)
      if data ~= nil then
        currentLayout = data.tiledLayout or ""
        workspaceId = data.id
      end
    end
    if isOpen then render() end
  end)
end

function onClose()
  isOpen = false
end

function onCloseClicked()
  panel.close()
end
