--!nonstrict
-- Better Workspaces bar widget.
-- Workspace pills behave like a normal indicator: click to switch, right-click
-- for the panel, scroll to cycle.

local activeWorkspace = 1
local activeSpecialName = nil
local workspaces = {}
local displayMode = "default"
local workspaceCount = 9
local _switching = false
local _refreshing = false
local pillWidth = 40
local pillHeight = 20
local pillVariant = "default"
local fontSize = 11
local fontWeight = "normal"
local textStyle = "normal"
local gap = 4

local stateFile = (noctalia.pluginDataDir() or "") .. "/state.json"
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
      if data.fontSize then fontSize = data.fontSize end
      if data.fontWeight then fontWeight = data.fontWeight end
      if data.textStyle then textStyle = data.textStyle end
      if data.gap then gap = data.gap end
    end
  end
end
loadState()

local converters = {}
converters["default"] = function(n) return tostring(n) end

converters["roman"] = function(n)
  if n < 1 or n > 3999 then return tostring(n) end
  local vals = {1000,900,500,400,100,90,50,40,10,9,5,4,1}
  local syms = {"M","CM","D","CD","C","XC","L","XL","X","IX","V","IV","I"}
  local out, i = "", 1
  while n > 0 do
    while n >= vals[i] do out = out..syms[i]; n = n - vals[i] end
    i = i + 1
  end
  return out
end

converters["kanji"] = function(n)
  local k = {"一","二","三","四","五","六","七","八","九"}
  return (n >= 1 and n <= 9) and k[n] or tostring(n)
end

converters["arabic"] = function(n)
  local a = {"١","٢","٣","٤","٥","٦","٧","٨","٩"}
  return (n >= 1 and n <= 9) and a[n] or tostring(n)
end

converters["korean"] = function(n)
  local k = {"ㄱ","ㄴ","ㄷ","ㄹ","ㅁ","ㅂ","ㅅ","ㅇ","ㅈ"}
  return (n >= 1 and n <= 9) and k[n] or tostring(n)
end

converters["thai"] = function(n)
  local t = {"๑","๒","๓","๔","๕","๖","๗","๘","๙"}
  return (n >= 1 and n <= 9) and t[n] or tostring(n)
end

converters["greek"] = function(n)
  local g = {"α","β","γ","δ","ε","ζ","η","θ","ι","κ","λ","μ","ν","ξ","ο","π","ρ","σ","τ","υ","φ","χ","ψ","ω"}
  return (n >= 1 and n <= 24) and g[n] or tostring(n)
end

converters["hindi"] = function(n)
  local h = {"१","२","३","४","५","६","७","८","९"}
  return (n >= 1 and n <= 9) and h[n] or tostring(n)
end

converters["emoji"] = function(n)
  local e = {"①","②","③","④","⑤","⑥","⑦","⑧","⑨"}
  return (n >= 1 and n <= 9) and e[n] or tostring(n)
end

converters["russian"] = function(n)
  local r = {"а","б","в","г","д","е","ж","з","и","й","к","л","м","н","о","п","р","с","т","у","ф","х","ц","ч","ш","щ","ъ","ы","ь","э","ю","я"}
  return (n >= 1 and n <= 33) and r[n] or tostring(n)
end

converters["appIcon"] = function(n) return converters["default"](n) end
converters["appName"] = function(n) return converters["default"](n) end

local function conv(n)
  return (converters[displayMode] or converters["default"])(n)
end

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function isSpecialWorkspaceName(name)
  return name and name ~= "" and not name:match("^%d+$")
end

local function getIds()
  local ids = {}

  for n = 1, workspaceCount do ids[n] = n end

  for wsId, wsData in pairs(workspaces) do
    if wsData.occupied then
      local isInRange = (type(wsId) == "number" and wsId >= 1 and wsId <= workspaceCount)
      local specialName = isSpecialWorkspaceName(wsData.name) and wsData.name or nil
      if not isInRange then
        local seen = false
        for _, v in ipairs(ids) do
          if v == wsId or (specialName and v == specialName) then seen = true break end
        end
        if not seen then
          table.insert(ids, specialName or wsId)
        end
      end
    end
  end

  return ids
end

local function switchTo(id)
  if _switching then return end
  _switching = true
  local expr = 'hl.dsp.focus({ workspace = "' .. tostring(id) .. '" })'
  noctalia.runAsync("hyprctl dispatch " .. shellQuote(expr), function(r)
    _switching = false
    if r.exitCode ~= 0 then
      noctalia.log("better-workspaces: dispatch to " .. tostring(id) .. " failed (exit " .. tostring(r.exitCode) .. ")")
    end
  end)
end

local function buildPills()
  local children = {}
  local ids = getIds()
  for _, id in ipairs(ids) do
    local pid = id
    local isSpecial = isSpecialWorkspaceName(tostring(id))

    local focused = false
    if isSpecial then
      focused = (id == activeSpecialName)
    else
      focused = (id == activeWorkspace)
    end

    local variant
    if focused then
      variant = "primary"
    elseif isSpecial then
      variant = "secondary"
    else
      variant = pillVariant
    end

    table.insert(children, ui.button({
      key = "pill-" .. tostring(id),
      text = isSpecial and tostring(id) or conv(id),
      fontSize = fontSize,
      fontWeight = fontWeight,
      textStyle = textStyle,
      width = pillWidth,
      height = pillHeight,
      variant = variant,
      selected = focused,
      onClick = function()
        switchTo(pid)
      end,
    }))
  end
  return children
end

local function render()
  barWidget.render(ui.row({ gap = gap, align = "center" }, buildPills()))
end

function onRightClick()
  noctalia.togglePanel("mindset/better-workspaces:panel")
end

function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" then return end
  if not startsGesture then return end
  local ids = getIds()
  local currentIdx = 1
  for i, id in ipairs(ids) do
    if id == activeWorkspace then currentIdx = i break end
  end
  local delta = (steps < 0) and -1 or 1
  local newIdx = ((currentIdx - 1 + delta + #ids) % #ids) + 1
  switchTo(ids[newIdx])
end

local function refresh()
  if _refreshing then return end
  _refreshing = true
  loadState()

  noctalia.runAsync("hyprctl activeworkspace -j", function(r)
    if r.exitCode == 0 and r.stdout then
      local d = noctalia.json.decode(r.stdout)
      if d and d.id then
        if isSpecialWorkspaceName(d.name) then
          activeSpecialName = d.name
          activeWorkspace = d.id
        else
          activeWorkspace = d.id
          activeSpecialName = nil
        end
      end
    end
    noctalia.runAsync("hyprctl workspaces -j", function(r2)
      _refreshing = false
      if r2.exitCode == 0 and r2.stdout then
        local d = noctalia.json.decode(r2.stdout)
        if type(d) == "table" then
          workspaces = {}
          for _, ws in ipairs(d) do
            workspaces[ws.id] = { occupied = (ws.windows or 0) > 0, name = ws.name }
          end
        end
      end
      render()
    end)
  end)
end

function update()
  refresh()
end

noctalia.setUpdateInterval(100)

refresh()
