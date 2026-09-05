--!nonstrict
-- Better Workspaces panel — shows all workspaces with selected display mode.

local isOpen = false
local currentWorkspace = 1
local workspaceCount = 9
local displayMode = "default"
local specialWorkspaces = {}
local _switching = false

local pillSize = "sm"
local pillVariant = "default"
local gap = 4

local stateFile = (noctalia.pluginDataDir() or "") .. "/state.json"

local function saveState()
  local ok, err = noctalia.writeFile(stateFile, noctalia.json.encode({
    displayMode = displayMode,
    workspaceCount = workspaceCount,
    specialWorkspaces = specialWorkspaces,
    pillSize = pillSize,
    pillVariant = pillVariant,
    gap = gap,
  }, true))
  if not ok then noctalia.log("better-workspaces: saveState failed: " .. tostring(err)) end
end

local function loadState()
  local raw = noctalia.readFile(stateFile)
  if raw then
    local ok, data = pcall(noctalia.json.decode, raw)
    if ok and data then
      if data.displayMode then displayMode = data.displayMode end
      if data.workspaceCount then workspaceCount = data.workspaceCount end
      if data.specialWorkspaces then specialWorkspaces = data.specialWorkspaces end
      if data.pillSize then pillSize = data.pillSize end
      if data.pillVariant then pillVariant = data.pillVariant end
      if data.gap then gap = data.gap end
    end
  end
end

local function normalizeName(fullName)
  if not fullName then return nil end
  return fullName:gsub("^name:", "")
end

local function resolveHyprConfigDir()
  -- Fallback to common path if env not available
  local home = "/home/mindset"
  local xdg = home .. "/.config"
  local candidates = {
    xdg .. "/hypr/config",
    xdg .. "/hyprland/config",
  }
  for _, dir in ipairs(candidates) do
    local f = io.open(dir .. "/workspaces.lua", "r")
    if f then f:close(); return dir end
  end
  return xdg .. "/hypr/config"
end

local function discoverSpecialWorkspaces()
  -- Scan workspaces.lua and main Hyprland config for workspace_rule definitions.
  local configDir = resolveHyprConfigDir()
  local mainConfigs = {
    configDir .. "/hyprland.lua",
    configDir .. "/hypr.lua",
    configDir .. "/init.lua",
  }
  local found = {}
  local seen = {}
  local function scanFile(fpath)
    local raw = noctalia.readFile(fpath)
    if not raw then return end
    for fullName in raw:gmatch('workspace%s*=%s*"([^"]+)"') do
      local name = normalizeName(fullName)
      if name and name ~= "" and not name:match("^%d+$") and not seen[name] then
        seen[name] = true
        table.insert(found, name)
      end
    end
  end
  for _, f in ipairs(mainConfigs) do scanFile(f) end
  scanFile(configDir .. "/workspaces.lua")
  return found
end

loadState()

-- Clean empty entries from specialWorkspaces
local cleaned = {}
for _, ws in ipairs(specialWorkspaces) do
  if ws and ws.name and ws.name ~= "" then
    ws.name = normalizeName(ws.name) or ws.name
    table.insert(cleaned, ws)
  end
end
specialWorkspaces = cleaned

-- Replace specialWorkspaces with discovered list from workspaces.lua.
-- workspaces.lua is the authoritative source for named workspaces.
local discovered = discoverSpecialWorkspaces()
local newList = {}
for _, name in ipairs(discovered) do
  table.insert(newList, { name = name })
end
specialWorkspaces = newList
saveState()

-- Forward-declared: loadWorkspaces (defined below) calls render() from an async
-- callback. Without this the upvalue would be nil and the call would crash.
local render

-- Number to text converters
local converters = {}

converters["default"] = function(n) return tostring(n) end

converters["roman"] = function(n)
  if n < 1 or n > 3999 then return tostring(n) end
  local vals = {1000,900,500,400,100,90,50,40,10,9,5,4,1}
  local syms = {"M","CM","D","CD","C","XC","L","XL","X","IX","V","IV","I"}
  local out, i = "", 1
  while n > 0 do
    while n >= vals[i] do
      out = out .. syms[i]
      n = n - vals[i]
    end
    i = i + 1
  end
  return out
end

converters["kanji"] = function(n)
  if n < 1 or n > 9 then return tostring(n) end
  local k = {"一","二","三","四","五","六","七","八","九"}
  return k[n] or tostring(n)
end

converters["arabic"] = function(n)
  if n < 1 or n > 9 then return tostring(n) end
  local a = {"١","٢","٣","٤","٥","٦","٧","٨","٩"}
  return a[n] or tostring(n)
end

converters["korean"] = function(n)
  if n < 1 or n > 9 then return tostring(n) end
  local k = {"ㄱ","ㄴ","ㄷ","ㄹ","ㅁ","ㅂ","ㅅ","ㅇ","ㅈ"}
  return k[n] or tostring(n)
end

converters["thai"] = function(n)
  if n < 1 or n > 9 then return tostring(n) end
  local t = {"๑","๒","๓","๔","๕","๖","๗","๘","๙"}
  return t[n] or tostring(n)
end

converters["greek"] = function(n)
  if n < 1 or n > 24 then return tostring(n) end
  local g = {"α","β","γ","δ","ε","ζ","η","θ","ι","κ","λ","μ","ν","ξ","ο","π","ρ","σ","τ","υ","φ","χ","ψ","ω"}
  return g[n] or tostring(n)
end

converters["hindi"] = function(n)
  if n < 1 or n > 9 then return tostring(n) end
  local h = {"१","२","३","४","५","६","७","८","९"}
  return h[n] or tostring(n)
end

converters["emoji"] = function(n)
  if n < 1 or n > 9 then return tostring(n) end
  local e = {"①","②","③","④","⑤","⑥","⑦","⑧","⑨"}
  return e[n] or tostring(n)
end

converters["russian"] = function(n)
  if n < 1 or n > 33 then return tostring(n) end
  local r = {"а","б","в","г","д","е","ж","з","и","й","к","л","м","н","о","п","р","с","т","у","ф","х","ц","ч","ш","щ","ъ","ы","ь","э","ю","я"}
  return r[n] or tostring(n)
end

converters["appIcon"] = function(n) return converters["default"](n) end
converters["appName"] = function(n) return converters["default"](n) end

local function convert(n)
  local conv = converters[displayMode] or converters["default"]
  return conv(n)
end

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function switchWorkspace(id)
  if _switching then return end  -- ignore rapid/repeated clicks
  _switching = true
  local expr = 'hl.dsp.focus({ workspace = "' .. tostring(id) .. '" })'
  noctalia.runAsync("hyprctl eval " .. shellQuote(expr), function(result)
    _switching = false
    if result.exitCode == 0 then
      panel.close()
    else
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.switch_failed"))
    end
  end)
end

render = function()
  local modeOptions = {
    "default", "roman", "kanji", "arabic", "korean",
    "thai", "greek", "hindi", "emoji", "russian",
    "appIcon", "appName"
  }
  local modeLabels = {
    "Default (1,2,3...)", "Roman (I,II,III...)", "Kanji (一,二,三...)",
    "Arabic (١,٢,٣...)", "Korean (ㄱ,ㄴ,ㄷ...)", "Thai (๑,๒,๓...)",
    "Greek (α,β,γ...)", "Hindi (१,२,३...)", "Emoji (①,②,③...)",
    "Russian (а,б,в...)", "App Icon", "App Name"
  }
  local modeIndex = 0
  for i, m in ipairs(modeOptions) do
    if m == displayMode then modeIndex = i - 1 break end
  end

  local sizeOptions = { "sm", "md", "lg" }
  local sizeLabels = { "Small", "Medium", "Large" }
  local sizeIndex = 0
  for i, s in ipairs(sizeOptions) do
    if s == pillSize then sizeIndex = i - 1 break end
  end

  local variantOptions = { "default", "primary", "secondary" }
  local variantLabels = { "Default", "Primary", "Secondary" }
  local variantIndex = 0
  for i, v in ipairs(variantOptions) do
    if v == pillVariant then variantIndex = i - 1 break end
  end

  local previewPills = {}
  for n = 1, math.min(workspaceCount, 6) do
    table.insert(previewPills, ui.button({
      key = "preview-" .. n,
      text = convert(n),
      fontSize = 11,
      controlSize = pillSize,
      variant = pillVariant,
    }))
  end

  local function scrollBody()
    return {
      ui.label({ text = noctalia.tr("panel.display_mode"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
      ui.select({
        key = "mode-select",
        options = modeLabels,
        selectedIndex = modeIndex,
        controlSize = "sm",
        onChange = function(idx)
          displayMode = modeOptions[tonumber(idx) + 1]
          saveState()
          render()
        end,
      }),
      ui.separator({}),
      ui.label({ text = noctalia.tr("panel.workspace_count"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = tostring(workspaceCount), fontSize = 13, fontWeight = "bold", width = 24 }),
        ui.slider({
          min = 1, max = 9, step = 1, value = workspaceCount,
          controlSize = "sm",
          onChange = function(val)
            workspaceCount = tonumber(val) or 9
            saveState()
            render()
          end,
        }),
      }),
      ui.separator({}),
      ui.label({ text = "Pill Size", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
      ui.select({
        key = "size-select",
        options = sizeLabels,
        selectedIndex = sizeIndex,
        controlSize = "sm",
        onChange = function(idx)
          pillSize = sizeOptions[tonumber(idx) + 1]
          saveState()
          render()
        end,
      }),
      ui.separator({}),
      ui.label({ text = "Pill Color", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
      ui.select({
        key = "variant-select",
        options = variantLabels,
        selectedIndex = variantIndex,
        controlSize = "sm",
        onChange = function(idx)
          pillVariant = variantOptions[tonumber(idx) + 1]
          saveState()
          render()
        end,
      }),
      ui.separator({}),
      ui.label({ text = "Gap: " .. gap, fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
      ui.slider({
        min = 2, max = 16, step = 1, value = gap,
        controlSize = "sm",
        onChange = function(val)
          gap = tonumber(val) or 4
          saveState()
          render()
        end,
      }),
    }
  end

  panel.render(ui.column({ flexGrow = 1, gap = 0 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      ui.button({ glyph = "settings", variant = "ghost", onClick = "onOpenSettings" }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.separator({}),
    ui.label({ text = "Preview", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.box({ fill = "secondary", radius = 6 }, ui.row({ gap = gap, align = "center", justify = "center" }, previewPills)),
    ui.separator({}),
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "Special Workspaces", fontSize = 11, fontWeight = "bold", color = "on_surface_variant", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = "Re-scan workspaces.lua", onClick = function()
        local discovered = discoverSpecialWorkspaces()
        local newList = {}
        for _, name in ipairs(discovered) do
          table.insert(newList, { name = name })
        end
        specialWorkspaces = newList
        saveState()
        render()
      end }),
    }),
    ui.separator({}),
    ui.scroll({ flexGrow = 1, gap = 6 }, scrollBody()),
  }))
end

function onOpen(_context)
  isOpen = true
  render()
end

function onClose()
  isOpen = false
end

function onCloseClicked()
  panel.close()
end

function onOpenSettings()
  noctalia.openSettings()
end

function onKey(chord, pressed)
  if not pressed then return end
  if chord == "Escape" then
    panel.close()
  end
end
