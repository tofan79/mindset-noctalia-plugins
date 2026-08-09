--!nonstrict
-- Layout switcher for the active Hyprland workspace, replacing the rofi picker.
-- Panel styled after KineticWE's layout picker. Applying mirrors
-- ~/.config/hypr/scripts/switch-layouts.sh: a workspace rule scoped to the
-- current workspace id, so each workspace keeps its own layout.
--
-- The active layout is tracked per workspace in the plugin data dir: Hyprland
-- 0.56 reports a wrong `tiledLayout` for lua layouts (deck reports as fair),
-- so the mark follows what the panel last applied instead of hyprctl.
-- Keyboard: type to filter, Up/Down to move, Enter to apply (capture_keys).

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
local filtered = {}
local selectedIndex = 0
local searchText = ""
local searchRevision = 0

local function layoutCachePath()
  local directory = noctalia.pluginDataDir()
  if directory == nil then
    return nil
  end
  return directory .. "/layouts.json"
end

local function readLayoutMap()
  local path = layoutCachePath()
  if path == nil then
    return {}
  end
  local raw = noctalia.readFile(path)
  if raw == nil or raw == "" then
    return {}
  end
  local data = noctalia.json.decode(raw)
  if data == nil or type(data) ~= "table" then
    return {}
  end
  return data
end

local function saveLayout(id, value)
  local path = layoutCachePath()
  if path == nil then
    return
  end
  local map = readLayoutMap()
  map[tostring(id)] = value
  local ok, err = noctalia.writeFile(path, noctalia.json.encode(map))
  if not ok then
    noctalia.log("could not save active layout: " .. tostring(err))
  end
end

local function activeLayoutIndex()
  if currentLayout == "" then
    return nil
  end
  for index, layout in ipairs(layouts) do
    if currentLayout == layout.value or ("lua:" .. currentLayout) == layout.value then
      return index
    end
  end
  return nil
end

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
      currentLayout = layout.value
      saveLayout(id, layout.value)
      noctalia.notify(noctalia.tr("title"), noctalia.tr("notification.switched", { name = layout.name }))
    else
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.apply_failed"))
    end
    panel.close()
  end)
end

local function applyFilter()
  filtered = {}
  local needle = string.lower(searchText or "")
  for _, layout in ipairs(layouts) do
    if needle == "" or string.find(string.lower(layout.name), needle, 1, true) ~= nil then
      table.insert(filtered, layout)
    end
  end
  if selectedIndex >= #filtered then
    selectedIndex = math.max(0, #filtered - 1)
  end
  if selectedIndex < 0 then
    selectedIndex = 0
  end
end

local function renderRow(layout, index)
  local isSelected = (index - 1) == selectedIndex
  local isActive = activeLayoutIndex() == index
  local children = {}
  if isSelected then
    table.insert(children, ui.box({ width = 3, height = 20, radius = 2, fill = "secondary" }))
  end
  table.insert(children, ui.button({
    key = "layout-" .. layout.value .. (isSelected and "-sel" or ""),
    text = layout.name,
    glyph = layout.glyph,
    variant = isActive and "primary" or "default",
    contentAlign = "start",
    flexGrow = 1,
    onClick = function()
      selectLayout(layout)
    end,
  }))
  return ui.row({
    key = "row-" .. layout.value,
    align = "center",
    gap = 8,
    paddingH = 4,
    paddingV = 1,
  }, children)
end

local function render()
  local rows = {}
  for index, layout in ipairs(filtered) do
    table.insert(rows, renderRow(layout, index))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 6, padding = 10 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.separator({}),
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "search", size = 14, color = "on_surface_variant" }),
      ui.input({
        key = "search-" .. searchRevision,
        placeholder = noctalia.tr("panel.search"),
        value = searchText,
        flexGrow = 1,
        focus = true,
        onChange = "onSearch",
      }),
    }),
    ui.scroll({ flexGrow = 1, gap = 4 }, rows),
  }))
end

function onOpen(_context)
  isOpen = true
  searchText = ""
  searchRevision += 1
  noctalia.runAsync("hyprctl activeworkspace -j", function(result)
    if result.exitCode == 0 then
      local data = noctalia.json.decode(result.stdout)
      if data ~= nil then
        workspaceId = data.id
        local cached = readLayoutMap()[tostring(data.id)]
        currentLayout = cached or (data.tiledLayout or "")
      end
    end
    local idx = activeLayoutIndex()
    selectedIndex = (idx ~= nil) and (idx - 1) or 0
    applyFilter()
    if isOpen then render() end
  end)
end

function onClose()
  isOpen = false
end

function onCloseClicked()
  panel.close()
end

function onSearch(value)
  searchText = value or ""
  selectedIndex = 0
  applyFilter()
  if isOpen then render() end
end

function onKey(chord, pressed)
  if not pressed or #filtered == 0 then
    return
  end
  if chord == "Up" then
    selectedIndex = selectedIndex - 1
    if selectedIndex < 0 then
      selectedIndex = #filtered - 1
    end
    render()
  elseif chord == "Down" then
    selectedIndex = selectedIndex + 1
    if selectedIndex >= #filtered then
      selectedIndex = 0
    end
    render()
  elseif chord == "Return" then
    if selectedIndex >= 0 and selectedIndex < #filtered then
      selectLayout(filtered[selectedIndex + 1])
    end
  end
end
