--!nonstrict
-- Layout picker for the Hyprland session, replacing the rofi picker.
-- The chosen layout is applied with hl.config(general.layout) and written back
-- to misc.lua. A runtime-only workspace rule was lost on `hyprctl reload`,
-- which made the panel look like it forgot the selection and fell back to the
-- default `scrolling` layout.
--
-- Keyboard: type to filter, Up/Down to move, Enter to apply (capture_keys).

local DEFAULT_DIR = "~/.config/hypr/layouts"
local DEFAULT_CONFIG = "~/.config/hypr/config/misc.lua"

-- Glyphs for lua layouts we recognize; unknown ones fall back to layout-grid.
local GLYPH_BY_NAME = {
  deck = "layers-difference",
  fair = "layout-board-split",
}

-- The four built-in Hyprland layouts are always available. Additional layouts
-- come from hl.layout.register("name") calls in files under the layouts folder.
local BUILTIN_LAYOUTS = {
  { name = "Dwindle",    value = "dwindle",   glyph = "layout-2" },
  { name = "Master",     value = "master",    glyph = "layout-sidebar" },
  { name = "Monocle",    value = "monocle",   glyph = "square" },
  { name = "Scrolling",  value = "scrolling", glyph = "arrows-horizontal" },
}

local layouts = {}
local isOpen = false
local currentLayout = ""
local filtered = {}
local selectedIndex = 0
local searchText = ""
local searchRevision = 0

local function capitalizeName(name)
  local s = noctalia.string.trim(tostring(name or "")):gsub("[_%s]+", " ")
  return s:gsub("(%a)([%w_-]*)", function(a, rest)
    return string.upper(a) .. string.lower(rest)
  end)
end

-- "lua:deck" and "deck" should mark the same row in the picker.
local function bareName(value)
  local v = tostring(value or "")
  if v:sub(1, 4) == "lua:" then
    return v:sub(5)
  end
  return v
end

local function safeValue(value)
  return tostring(value or ""):match("^[%w_:]+$") ~= nil
end

-- Scan <layouts_dir>/*.lua, find each hl.layout.register("<name>", ...) call,
-- and expose it as the "lua:<name>" layout. Built-ins stay on top.
local function loadLayouts()
  layouts = {}
  for _, layout in ipairs(BUILTIN_LAYOUTS) do
    table.insert(layouts, layout)
  end
  local dir = noctalia.getConfig("layouts_dir") or DEFAULT_DIR
  local entries = noctalia.listDir(dir)
  if entries == nil then
    return
  end
  for _, file in ipairs(entries) do
    if string.sub(file, -4) == ".lua" then
      local text = noctalia.readFile(dir .. "/" .. file)
      local name = string.match(text or "", 'hl.layout.register%s*%(%s*"([%w_]+)')
      if name ~= nil and name ~= "" then
        local value = "lua:" .. name
        local dup = false
        for _, layout in ipairs(layouts) do
          if layout.value == value then
            dup = true
            break
          end
        end
        if not dup then
          table.insert(layouts, {
            name = (name == "deck" and "Deck Stack")
              or (name == "fair" and "Fair Grid")
              or capitalizeName(name),
            value = value,
            glyph = GLYPH_BY_NAME[name] or "layout-grid",
          })
        end
      end
    end
  end
end

local function configPath()
  return noctalia.getConfig("config_file") or DEFAULT_CONFIG
end

-- Persist the choice in misc.lua, the same way Better Displays persists
-- monitor settings into monitors.lua. Without this, a reload restores the
-- static `general.layout` value and the user sees the layout snap back.
local function persistLayout(value)
  if not safeValue(value) then
    noctalia.log("cannot persist layout: invalid value " .. tostring(value))
    return
  end
  local path = configPath()
  local text = noctalia.readFile(path)
  if text == nil then
    noctalia.log("cannot persist layout: missing " .. path)
    return
  end
  local updated, count = text:gsub(
    '(hl%.config%s*%(%s*%{%s*general%s*=%s*%{[^}]-)layout%s*=%s*"[^"]*"',
    '%1layout = "' .. value .. '"',
    1
  )
  if count == 0 then
    updated = text .. '\nhl.config({ general = { layout = "' .. value .. '" } })\n'
  end
  if updated == text then
    return
  end
  local ok, err = noctalia.writeFile(path, updated)
  if not ok then
    noctalia.log("could not persist active layout: " .. tostring(err))
  end
end

local function activeLayoutIndex()
  if currentLayout == "" then
    return nil
  end
  local bare = bareName(currentLayout)
  for index, layout in ipairs(layouts) do
    if currentLayout == layout.value or bare == bareName(layout.value) then
      return index
    end
  end
  return nil
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function selectLayout(layout)
  if not safeValue(layout.value) then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.apply_failed"))
    return
  end
  local lua = string.format("hl.config({ general = { layout = %q } })", layout.value)
  noctalia.runAsync("hyprctl eval " .. shellQuote(lua), function(result)
    if result.exitCode == 0 then
      currentLayout = layout.value
      persistLayout(layout.value)
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

-- Defined after render(): Luau locals are only visible to closures declared
-- after them, so calling render() from an earlier local caused a nil call.
local function finishOpen()
  local idx = activeLayoutIndex()
  selectedIndex = (idx ~= nil) and (idx - 1) or 0
  applyFilter()
  if isOpen then
    render()
  end
end

function onOpen(_context)
  isOpen = true
  searchText = ""
  searchRevision += 1
  loadLayouts()
  -- Draw immediately; the async hyprctl result only refines the highlight.
  -- Waiting for the callback left an empty black panel if hyprctl was slow.
  applyFilter()
  render()
  noctalia.runAsync("hyprctl getoption general:layout -j", function(result)
    if result.exitCode == 0 then
      local data = noctalia.json.decode(result.stdout)
      if type(data) == "table" and type(data.str) == "string" then
        currentLayout = data.str
      end
    end
    finishOpen()
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
