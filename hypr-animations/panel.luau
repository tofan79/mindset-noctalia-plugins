--!nonstrict
-- Animation preset picker, replacing the rofi animation picker.
-- Lists ~/.config/hypr/config/animations_presets/*.lua, applies the chosen file
-- with `hyprctl eval`, and updates ANIMATION_PRESET in animations.lua so the
-- choice survives a Hyprland config reload or reboot.
--
-- Keyboard: type to filter, Up/Down to move, Enter to apply (capture_keys).

local PLUGIN_ID = "mindset/hypr-animations"
local DEFAULT_DIR = "~/.config/hypr/config/animations_presets"
local DEFAULT_CONFIG = "~/.config/hypr/config/animations.lua"
local DIR = DEFAULT_DIR
local GLYPH = "palette"
-- Hyde-derived presets call hyde.config.anim.duration_scale. Hyprland's Lua
-- context has no `hyde`, so provide a neutral scale of 1 before the preset.
local HYDE_SHIM = 'hyde = hyde or { config = { anim = { duration_scale = 1 } } }\n'

local presets = {}
local filtered = {}
local selectedIndex = 0
local searchText = ""
local searchRevision = 0
local activeFile = ""
local status = ""
local isOpen = false

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

local function presetStem(file)
  return tostring(file or ""):match("^([%w_%-]+)%.lua$")
end

local function configPath()
  return noctalia.getConfig("config_file") or DEFAULT_CONFIG
end

-- Persist the picked preset in animations.lua, the same way Better Displays
-- persists monitor settings into monitors.lua. A runtime eval alone is lost on
-- `hyprctl reload`, which made the panel appear to forget the selection.
local function persistActive(file)
  local stem = presetStem(file)
  if stem == nil then
    noctalia.log("cannot persist animation preset: invalid file name " .. tostring(file))
    return
  end
  local path = configPath()
  local text = noctalia.readFile(path)
  if text == nil then
    noctalia.log("cannot persist animation preset: missing " .. path)
    return
  end
  local updated, count = text:gsub('ANIMATION_PRESET%s*=%s*"[^"]*"', 'ANIMATION_PRESET = "' .. stem .. '"', 1)
  if count == 0 then
    updated, count = updated:gsub('(require%s*%(%s*"config%.animations_presets%.)([^"]*)(")%s*%)', function(prefix, _old, quote)
      return prefix .. stem .. quote .. ")"
    end, 1)
  end
  if count == 0 then
    noctalia.log("cannot persist animation preset: no ANIMATION_PRESET line in " .. path)
    return
  end
  if updated == text then
    return
  end
  local ok, err = noctalia.writeFile(path, updated)
  if not ok then
    noctalia.log("could not persist active preset: " .. tostring(err))
  end
end

local function prettyName(file)
  local s = tostring(file or ""):gsub("%.lua$", ""):gsub("[_%-]+", " ")
  return s:gsub("(%a)([%w]*)", function(a, rest)
    return string.upper(a) .. string.lower(rest)
  end)
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
  return table.concat(parts, "\n")
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
  -- Read only the chosen file here. Reading every preset in onOpen exceeded
  -- Noctalia's CPU callback budget and left the panel black. Do not shell out
  -- to `cat`: a quoted `~/...` path is not expanded by the shell, so the read
  -- failed and Hyprland never received the preset.
  local text = noctalia.readFile(DIR .. "/" .. preset.file)
  if text == nil then
    noctalia.log("cannot apply animation preset: missing " .. DIR .. "/" .. preset.file)
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.apply_failed"))
    panel.close()
    return
  end
  local code = HYDE_SHIM .. stripCode(text)
  noctalia.runAsync("hyprctl eval " .. shellQuote(code), function(result)
    if result.exitCode == 0 then
      activeFile = preset.file
      saveActive(preset.file)
      persistActive(preset.file)
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
    for index, preset in ipairs(filtered) do
      table.insert(rows, renderRow(preset, index))
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
    ui.scroll({ flexGrow = 1, gap = 4 }, rows),
  }))
end

function onOpen(_context)
  isOpen = true
  presets = {}
  status = ""
  searchText = ""
  searchRevision += 1
  DIR = noctalia.getConfig("presets_dir") or DEFAULT_DIR
  loadActive()
  local entries, err = noctalia.listDir(DIR)
  if entries == nil then
    status = noctalia.tr("error.read_dir", { dir = DIR }) .. (err ~= nil and " · " .. err or "")
    render()
    return
  end
  table.sort(entries)
  -- Only build the list here. Reading and stripping all 32 preset files in
  -- onOpen exceeded Noctalia's CPU callback budget and produced a black panel.
  -- The chosen file is read asynchronously in selectPreset instead.
  for _, name in ipairs(entries) do
    if string.sub(name, -4) == ".lua" then
      table.insert(presets, {
        name = prettyName(name),
        file = name,
      })
    end
  end
  selectedIndex = 0
  if activeFile ~= "" then
    for i, p in ipairs(presets) do
      if p.file == activeFile then
        selectedIndex = i - 1
        break
      end
    end
  end
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
