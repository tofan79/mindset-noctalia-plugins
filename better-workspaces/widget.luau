--!nonstrict
-- Better Workspaces bar widget.
-- Workspace pills behave like a normal indicator: click to switch, right-click
-- for the panel, scroll to cycle. Workspace rules sync to hypr workspaces.lua.

local activeWorkspace = 1
local workspaces = {}
local displayMode = "default"
local workspaceCount = 9
local _switching = false
local _refreshing = false

-- Read persisted panel choices (displayMode, workspaceCount) from state.json.
-- Panel writes here so changes survive without needing the settings UI.
local stateFile = (noctalia.pluginDataDir() or "") .. "/state.json"
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

local function getIds()
  local ids = {}
  for n = 1, workspaceCount do ids[n] = n end
  table.sort(ids)
  return ids
end

local function switchTo(id)
  if _switching then return end
  _switching = true
  local expr = 'hl.dsp.focus({ workspace = "' .. tostring(id) .. '" })'
  noctalia.runAsync("hyprctl dispatch " .. shellQuote(expr), function(r)
    _switching = false
    if r.exitCode ~= 0 then
      noctalia.log("better-workspaces: dispatch to " .. id .. " failed (exit " .. tostring(r.exitCode) .. ")")
    end
    -- no render() here — 100ms poll update() catches the change fast enough
  end)
end

-- Workspace pills behave like a normal workspace indicator: left-click a pill
-- switches to that workspace. `ui.button` is the only reliably interactive
-- element in bar widgets (no keyboard there, so column/label hit-testing is not
-- usable); the active pill is rendered `selected` so its fill tracks the active
-- workspace. Right-click (onRightClick) opens the panel.
local function buildPills()
  local children = {}
  local ids = getIds()
  for _, id in ipairs(ids) do
    local pid = id
    local focused = (id == activeWorkspace)
    table.insert(children, ui.button({
      key = "pill-" .. id,
      text = conv(id),
      fontSize = 11,
      controlSize = "sm",
      variant = focused and "primary" or "default",
      selected = focused,
      onClick = function()
        switchTo(pid)
      end,
    }))
  end
  return children
end

local function render()
  barWidget.render(ui.row({ gap = 4, align = "center" }, buildPills()))
end

-- Right-click = open panel (settings + per-workspace selection)
function onRightClick()
  noctalia.togglePanel("mindset/better-workspaces:panel")
end

-- Scroll = cycle workspaces (host calls onScroll(axis, steps, startsGesture);
-- `steps` is negative for up/left. Act once per gesture so a flick doesn't jump several.)
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
  -- re-read state.json every poll so panel changes are picked up within ~100ms
  loadState()
  -- displayMode and workspaceCount come from state.json (set by panel), not Noctalia config

  noctalia.runAsync("hyprctl activeworkspace -j", function(r)
    if r.exitCode == 0 and r.stdout then
      local d = noctalia.json.decode(r.stdout)
      if d and d.id then activeWorkspace = d.id end
    end
    noctalia.runAsync("hyprctl workspaces -j", function(r2)
      _refreshing = false
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

-- Keep ~/.config/hypr/config/workspaces.lua in sync with the configured workspace
-- count, same way better-displays owns its monitor lines. Runs on every widget
-- reload (startup and config change); the script no-ops when already in sync.
local scriptDir = noctalia.pluginDir() .. "/bin"
local function persistWorkspaceRules()
  noctalia.runAsync(shellQuote(scriptDir .. "/better-workspace-persist") .. " " .. tostring(workspaceCount), function() end)
end

-- Poll active workspace so the pill fill tracks workspace switches made from
-- outside the widget too (keybinds, other indicators).
function update()
  refresh()
end

noctalia.setUpdateInterval(100)  -- 100ms: very responsive, still reasonable load

refresh()
persistWorkspaceRules()
