--!nonstrict
-- Better Workspaces panel — shows all workspaces with selected display mode.

local isOpen = false
local currentWorkspace = 1
local workspaceCount = 9
local displayMode = "default"
local _switching = false

local pillWidth = 40
local pillHeight = 20
local pillVariant = "default"
local gap = 4

local stateFile = (noctalia.pluginDataDir() or "") .. "/state.json"

local function saveState()
  local ok, err = noctalia.writeFile(stateFile, noctalia.json.encode({
    displayMode = displayMode,
    workspaceCount = workspaceCount,
    pillWidth = pillWidth,
    pillHeight = pillHeight,
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
      if data.pillWidth then pillWidth = data.pillWidth end
      if data.pillHeight then pillHeight = data.pillHeight end
      if data.pillVariant then pillVariant = data.pillVariant end
      if data.gap then gap = data.gap end
    end
  end
end

loadState()

local render

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
      width = pillWidth,
      height = pillHeight,
      variant = pillVariant,
    }))
  end

  local function sliderRow(label, value, min, max, onChange)
    return ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = label, fontSize = 11, width = 70 }),
      ui.label({ text = tostring(value), fontSize = 11, fontWeight = "bold", width = 28 }),
      ui.slider({
        min = min, max = max, step = 1, value = value,
        controlSize = "sm",
        onChange = function(val)
          onChange(tonumber(val))
        end,
      }),
    })
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
      sliderRow("Count", workspaceCount, 1, 9, function(val)
        workspaceCount = val
        saveState()
        render()
      end),
      ui.separator({}),
      ui.label({ text = "Pill Size", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
      sliderRow("Width", pillWidth, 0, 100, function(val)
        pillWidth = val
        saveState()
        render()
      end),
      sliderRow("Height", pillHeight, 0, 50, function(val)
        pillHeight = val
        saveState()
        render()
      end),
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
      ui.label({ text = "Gap", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
      sliderRow("Gap", gap, 1, 15, function(val)
        gap = val
        saveState()
        render()
      end),
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
