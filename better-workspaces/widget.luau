--!nonstrict
-- Better Workspaces bar widget.
-- Shows all workspaces as pills. Click widget to cycle next workspace.

local currentWorkspace = 1
local workspaces = {}
local displayMode = "default"
local workspaceCount = 9

converters = {}
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

-- Get all workspace ids to show
local function getIds()
  local ids = {}
  for n = 1, workspaceCount do ids[n] = n end
  -- Add occupied workspaces beyond count
  for id in pairs(workspaces) do
    if id > workspaceCount and id <= 20 then
      local exists = false
      for _, v in ipairs(ids) do if v == id then exists = true break end end
      if not exists then table.insert(ids, id) end
    end
  end
  table.sort(ids)
  return ids
end

-- Build pills tree
local function buildPills()
  local children = {}
  local ids = getIds()
  for _, id in ipairs(ids) do
    local ws = workspaces[id] or {}
    local occ = ws.occupied or false
    local focused = (id == currentWorkspace)
    local fill = focused and "primary" or "surface"
    local txt = focused and "on_primary" or "on_surface"
    local op = (occ or focused) and 1.0 or 0.4
    table.insert(children, ui.box({
      key = "pill-" .. id,
      width = 24,
      height = 20,
      radius = 4,
      fill = fill,
      opacity = op,
    }, {
      ui.label({
        text = conv(id),
        fontSize = 10,
        fontWeight = focused and "bold" or "normal",
        color = txt,
        textAlign = "center",
      }),
    }))
  end
  return children
end

local function render()
  barWidget.render(ui.row({ gap = 4, align = "center" }, buildPills()))
end

-- Click = cycle to next workspace
function onClick()
  local ids = getIds()
  local nextIdx = 1
  for i, id in ipairs(ids) do
    if id == currentWorkspace then
      nextIdx = (i % #ids) + 1
      break
    end
  end
  local nextWs = ids[nextIdx]
  noctalia.runAsync("hyprctl dispatch workspace " .. tostring(nextWs), function() end)
end

local function refresh()
  displayMode = noctalia.getConfig("displayMode") or "default"
  workspaceCount = noctalia.getConfig("workspaceCount") or 9

  noctalia.runAsync("hyprctl activeworkspace -j", function(r)
    if r.exitCode == 0 and r.stdout then
      local d = noctalia.json.decode(r.stdout)
      if d and d.id then currentWorkspace = d.id end
    end
    noctalia.runAsync("hyprctl workspaces -j", function(r2)
      if r2.exitCode == 0 and r2.stdout then
        local d = noctalia.json.decode(r2.stdout)
        if type(d) == "table" then
          workspaces = {}
          for _, ws in ipairs(d) do
            workspaces[ws.id] = { occupied = (ws.windows or 0) > 0 }
          end
        end
      end
      render()
    end)
  end)
end

refresh()
