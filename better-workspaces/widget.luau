--!nonstrict
-- Better Workspaces bar widget — styled like the built-in workspaces widget
-- Shows pill indicators per workspace, with active highlighted.

local PANEL_ID = "mindset/better-workspaces:panel"

local currentWorkspace = 1
local workspaces = {} -- {id = {occupied, focused}}
local displayMode = "default"
local workspaceCount = 9
local revealOccupied = true
local dimEmpty = true

-- Number converters
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
  if n < 1 or n > 24 then return toostring(n) end
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
  local lua = string.format("hl.workspace_rule({ workspace = tostring(%s) })", tostring(id))
  noctalia.runAsync("hyprctl eval " .. shellQuote(lua), function(result)
    -- silently switch
  end)
end

local function refreshWorkspaces()
  noctalia.runAsync("hyprctl activeworkspace -j", function(result)
    if result.exitCode == 0 then
      local data = noctalia.json.decode(result.stdout)
      if data and data.id then
        currentWorkspace = data.id
      end
    end

    -- Get all workspaces
    noctalia.runAsync("hyprctl workspaces -j", function(result2)
      if result2.exitCode == 0 then
        local data = noctalia.json.decode(result2.stdout or "[]")
        if type(data) == "table" then
          workspaces = {}
          for _, ws in ipairs(data) do
            workspaces[ws.id] = {
              occupied = (ws.windows or 0) > 0,
              focused = ws.id == currentWorkspace,
            }
          end
        end
      end
      render()
    end)
  end)
end

local function render()
  -- Build workspace pills like the built-in workspaces widget
  local pills = {}

  -- Get all workspace ids to show
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

  -- Build pill for each workspace
  for _, id in ipairs(ids) do
    local ws = workspaces[id] or {}
    local isOccupied = ws.occupied or false
    local isFocused = ws.focused or (id == currentWorkspace)
    local opacity = (isOccupied or isFocused or not dimEmpty) and 1 or 0.4

    local label = convert(id)

    -- Pill style: small rounded box with number
    table.insert(pills, ui.box({
      key = "pill-" .. id,
      width = 20,
      height = 20,
      radius = 4,
      fill = isFocused and "primary" or "surface_variant",
      opacity = opacity,
    }, {
      ui.label({
        text = label,
        fontSize = 9,
        fontWeight = isFocused and "bold" or "normal",
        color = isFocused and "on_primary" or "on_surface_variant",
        textAlign = "center",
      }),
    }))
  end

  -- Render as a row of pills (like built-in workspaces)
  barWidget.render(ui.row({
    key = "workspaces-row",
    gap = 3,
    align = "center",
  }, pills))
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

-- Refresh state
local function refresh()
  workspaceCount = noctalia.getConfig("workspaceCount") or 9
  displayMode = noctalia.getConfig("displayMode") or "default"
  revealOccupied = noctalia.getConfig("revealOccupied") ~= false
  dimEmpty = noctalia.getConfig("dimEmpty") ~= false
  refreshWorkspaces()
end

refresh()
