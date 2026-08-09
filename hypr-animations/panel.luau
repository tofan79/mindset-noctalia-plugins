--!nonstrict
-- Animation preset picker, replacing the rofi animation picker.
-- Lists ~/.config/hypr/animations/*.lua and applies the chosen file with
-- `hyprctl eval` after stripping `--` comments, exactly like
-- ~/.config/hypr/scripts/switch-animations.sh.

local DIR = noctalia.getConfig("presets_dir") or "~/.config/hypr/animations"
local GLYPH = "palette"
local NAME_PATTERN = 'name%s+"([^"]*)"'

local presets = {}
local isOpen = false
local status = ""

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

local function selectPreset(preset)
  noctalia.runAsync("hyprctl eval " .. shellQuote(preset.code), function(result)
    if result.exitCode == 0 then
      noctalia.notify(noctalia.tr("title"), noctalia.tr("notification.switched", { name = preset.name }))
    else
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.apply_failed"))
    end
    panel.close()
  end)
end

local function render()
  local listChildren = {}

  if status ~= "" then
    table.insert(listChildren, ui.label({ text = status, color = "error", maxLines = 2 }))
  elseif #presets == 0 then
    table.insert(listChildren, ui.label({ text = noctalia.tr("error.no_presets"), maxLines = 2 }))
  else
    for _, preset in ipairs(presets) do
      table.insert(listChildren, ui.button({
        key = "preset-" .. preset.file,
        text = preset.name,
        glyph = GLYPH,
        variant = "default",
        contentAlign = "start",
        onClick = function()
          selectPreset(preset)
        end,
      }))
    end
  end

  panel.render(ui.column({ flexGrow = 1, gap = 6, padding = 10 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.separator({}),
    ui.label({
      text = noctalia.tr("panel.presets", { count = tostring(#presets), dir = DIR }),
      fontSize = 11,
      color = "on_surface_variant",
    }),
    ui.scroll({ flexGrow = 1, gap = 6 }, listChildren),
  }))
end

function onOpen(_context)
  isOpen = true
  presets = {}
  status = ""
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
  render()
end

function onClose()
  isOpen = false
end

function onCloseClicked()
  panel.close()
end
