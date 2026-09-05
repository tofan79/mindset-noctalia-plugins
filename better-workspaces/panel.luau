--!nonstrict
-- Better Workspaces panel — shows all workspaces with selected display mode.

local isOpen = false
local currentWorkspace = 1
local workspaceCount = 9
local displayMode = "default"
local revealOccupied = true
local dimEmpty = true
local workspaces = {}
local selectedIndex = 0
local _switching = false

-- Persist panel setting changes to a JSON file so the widget can override
-- Noctalia config without needing a settings-UI round-trip.
local stateFile = (noctalia.pluginDataDir() or "") .. "/state.json"

local function saveState()
  local ok, err = noctalia.writeFile(stateFile, noctalia.json.encode({
    displayMode = displayMode,
    workspaceCount = workspaceCount,
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
    end
  end
end

loadState()

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

local function loadWorkspaces()
  noctalia.runAsync("hyprctl workspaces -j", function(result)
    if result.exitCode == 0 then
      local data = noctalia.json.decode(result.stdout)
      if type(data) == "table" then
        workspaces = {}
        for _, ws in ipairs(data) do
          local apps = ""
          workspaces[ws.id] = {
            id = ws.id,
            occupied = ws.windows > 0,
            focused = (ws.id == currentWorkspace),
          }
        end
      end
    end
    -- only render if we got valid data (avoid rendering empty/stale state)
    if result.exitCode == 0 then render() end
  end)
end

local function getWorkspaceIds()
  local ids = {}
  for n = 1, workspaceCount do
    ids[n] = n
  end
  if revealOccupied then
    for id in pairs(workspaces) do
      if id > workspaceCount and id <= 20 then
        local exists = false
        for _, v in ipairs(ids) do
          if v == id then exists = true break end
        end
        if not exists then table.insert(ids, id) end
      end
    end
    table.sort(ids)
  end
  return ids
end

local function renderRow(id, index)
  local isSelected = (index - 1) == selectedIndex
  local ws = workspaces[id] or {}
  local isOccupied = ws.occupied or false
  local isFocused = ws.focused or (id == currentWorkspace)
  local opacity = (isOccupied or isFocused or not dimEmpty) and 1 or 0.5

  local displayText = convert(id)
  if displayMode == "appIcon" and isOccupied then
    displayText = "🪟"
  elseif displayMode == "appName" and isOccupied then
    displayText = id .. " 📱"
  end

  local children = {}
  if isSelected then
    table.insert(children, ui.box({ width = 3, height = 24, radius = 2, fill = "secondary" }))
  end

  table.insert(children, ui.button({
    key = "ws-" .. id .. (isSelected and "-sel" or ""),
    text = displayText,
    glyph = isFocused and "layout-grid" or nil,
    variant = isFocused and "primary" or "default",
    contentAlign = "start",
    flexGrow = 1,
    opacity = opacity,
    onClick = function()
      switchWorkspace(id)
    end,
  }))

  return ui.row({
    key = "row-" .. id,
    align = "center",
    gap = 8,
    paddingH = 4,
    paddingV = 1,
  }, children)
end

render = function()
  local rows = {}
  local ids = getWorkspaceIds()
  for index, id in ipairs(ids) do
    table.insert(rows, renderRow(id, index))
  end

  -- Display mode options
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

  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 12 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      ui.button({ glyph = "settings", variant = "ghost", onClick = "onOpenSettings" }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.separator({}),
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
    ui.label({ text = noctalia.tr("panel.workspaces"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.scroll({ flexGrow = 1, gap = 4 }, rows),
  }))
end

function onOpen(_context)
  isOpen = true
  selectedIndex = 0

  -- Load settings
  workspaceCount = noctalia.getConfig("workspaceCount") or 9
  displayMode = noctalia.getConfig("displayMode") or "default"
  revealOccupied = noctalia.getConfig("revealOccupied") ~= false
  dimEmpty = noctalia.getConfig("dimEmpty") ~= false

  -- Get current workspace
  noctalia.runAsync("hyprctl activeworkspace -j", function(result)
    if result.exitCode == 0 then
      local data = noctalia.json.decode(result.stdout)
      if data and data.id then
        currentWorkspace = data.id
      end
    end
    loadWorkspaces()
  end)
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

  local ids = getWorkspaceIds()
  if #ids == 0 then return end

  if chord == "Up" then
    selectedIndex = selectedIndex - 1
    if selectedIndex < 0 then selectedIndex = #ids - 1 end
    render()
  elseif chord == "Down" then
    selectedIndex = selectedIndex + 1
    if selectedIndex >= #ids then selectedIndex = 0 end
    render()
  elseif chord == "Return" then
    if selectedIndex >= 0 and selectedIndex < #ids then
      switchWorkspace(ids[selectedIndex + 1])
    end
  elseif chord == "Escape" then
    panel.close()
  end
end
