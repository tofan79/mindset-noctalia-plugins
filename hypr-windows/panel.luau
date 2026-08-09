--!nonstrict
-- Window/gaps preset picker, replacing the rofi window picker.
-- Lists ~/.config/hypr/windows/*.lua and applies the chosen file with
-- `hyprctl eval` after stripping `--` comments, exactly like
-- ~/.config/hypr/scripts/switch-windows.sh.
--
-- Keyboard: type to filter, Up/Down to move, Enter to apply (capture_keys).
-- The last applied preset is remembered and shown in primary (blue).

local PLUGIN_ID = "mindset/hypr-windows"
local DIR = noctalia.getConfig("presets_dir") or "~/.config/hypr/windows"
local GLYPH = "square-dashed"
local NAME_PATTERN = 'name:%s*"([^"]*)"'

local presets = {}
local filtered = {}
local selectedIndex = 0
local searchText = ""
local searchRevision = 0
local activeFile = ""
local status = ""
local isOpen = false
local WINDOW_SIZE = 8

local function visibleRange(total)
  if total <= WINDOW_SIZE then
    return 1, total
  end
  local half = math.floor(WINDOW_SIZE / 2)
  local start = math.max(1, selectedIndex + 1 - half)
  if start + WINDOW_SIZE > total + 1 then
    start = math.max(1, total - WINDOW_SIZE + 1)
  end
  return start, math.min(total, start + WINDOW_SIZE - 1)
end

local function cachePath()
  local directory = noctalia.pluginDataDir()
  if directory == nil then
    return nil
  end
  return directory .. "/current.txt"
end

local function loadActive()
  local path = cachePath()
  if path == nil then
    activeFile = ""
    return
  end
  local raw = noctalia.readFile(path)
  activeFile = raw ~= nil and noctalia.string.trim(raw) or ""
end

local function saveActive(file)
  local path = cachePath()
  if path == nil then
    return
  end
  local ok, err = noctalia.writeFile(path, file)
  if not ok then
    noctalia.log("could not save active preset: " .. tostring(err))
  end
end

local function extractName(text, fallback)
  local name = string.match(text or "", NAME_PATTERN)
  if name == nil or name == "" then
    name = fallback
  end
  return name
end

local function stripCode(text)
  local parts = {}
  for line in tostring(text or ""):gmatch("[^\n]+") do
    local cut = line:find("--", 1, true)
    local body = line
    if cut then
      body = string.sub(line, 1, cut - 1)
    end
    body = noctalia.string.trim(body)
    table.insert(parts, body)
  end
  return table.concat(parts, "")
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function applyFilter()
  filtered = {}
  local needle = string.lower(searchText or "")
  for _, preset in ipairs(presets) do
    if needle == "" or string.find(string.lower(preset.name), needle, 1, true) ~= nil then
      table.insert(filtered, preset)
    end
  end
  if selectedIndex >= #filtered then
    selectedIndex = math.max(0, #filtered - 1)
  end
  if selectedIndex < 0 then
    selectedIndex = 0
  end
end

local function selectPreset(preset)
  noctalia.runAsync("hyprctl eval " .. shellQuote(preset.code), function(result)
    if result.exitCode == 0 then
      activeFile = preset.file
      saveActive(preset.file)
      noctalia.notify(noctalia.tr("title"), noctalia.tr("notification.switched", { name = preset.name }))
    else
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.apply_failed"))
    end
    panel.close()
  end)
end

local function renderRow(preset, index)
  local isSelected = (index - 1) == selectedIndex
  local isActive = preset.file == activeFile
  local children = {}
  if isSelected then
    table.insert(children, ui.box({ width = 3, height = 20, radius = 2, fill = "secondary" }))
  end
  table.insert(children, ui.button({
    key = "preset-" .. preset.file .. (isSelected and "-sel" or ""),
    text = preset.name,
    glyph = GLYPH,
    variant = isActive and "primary" or "default",
    contentAlign = "start",
    flexGrow = 1,
    onClick = function()
      selectPreset(preset)
    end,
  }))
  return ui.row({
    key = "row-" .. preset.file,
    align = "center",
    gap = 8,
    paddingH = 4,
    paddingV = 1,
  }, children)
end

local function render()
  local rows = {}
  if status ~= "" then
    table.insert(rows, ui.label({ text = status, color = "error", maxLines = 2 }))
  elseif #filtered == 0 then
    table.insert(rows, ui.label({ text = noctalia.tr("error.no_presets"), maxLines = 2 }))
  else
    local first, last = visibleRange(#filtered)
    for index = first, last do
      table.insert(rows, renderRow(filtered[index], index))
    end
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
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({
        text = noctalia.tr("panel.presets", { count = tostring(#filtered), dir = DIR }),
        fontSize = 11,
        color = "on_surface_variant",
      }),
      ui.label({ text = noctalia.tr("panel.hint"), fontSize = 10, color = "on_surface_variant" }),
    }),
    ui.scroll({ key = "rows-" .. searchRevision .. "-" .. selectedIndex, flexGrow = 1, gap = 4 }, rows),
  }))
end

function onOpen(_context)
  isOpen = true
  presets = {}
  status = ""
  searchText = ""
  searchRevision += 1
  loadActive()
  local entries, err = noctalia.listDir(DIR)
  if entries == nil then
    status = noctalia.tr("error.read_dir", { dir = DIR }) .. (err ~= nil and " · " .. err or "")
    render()
    return
  end
  table.sort(entries)
  for _, name in ipairs(entries) do
    if string.sub(name, -4) == ".lua" then
      local text = noctalia.readFile(DIR .. "/" .. name)
      local fallback = string.sub(name, 1, #name - 4)
      table.insert(presets, {
        name = extractName(text, fallback),
        file = name,
        code = stripCode(text),
      })
    end
  end
  selectedIndex = 0
  applyFilter()
  render()
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
      selectPreset(filtered[selectedIndex + 1])
    end
  end
end
