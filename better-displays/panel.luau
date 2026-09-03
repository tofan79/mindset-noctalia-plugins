--!nonstrict

local scriptDir = noctalia.pluginDir() .. "/bin"
local refreshSeconds = 4

local monitors = {}
local selected = ""
local terminalSizes = {}
local isOpen = false
local vrrConfig = {}

local scalePresets = { "1", "1.25", "1.6", "2", "3", "4" }
local transformPresets = { "0", "1", "2", "3" }
local transformLabels = { ["0"] = "0°", ["1"] = "90°", ["2"] = "180°", ["3"] = "270°" }
local vrrPresets = { "0", "1", "2", "3" }
local vrrLabels = { ["0"] = "Off", ["1"] = "On", ["2"] = "Fullscreen", ["3"] = "Fullscreen+video" }
local terminalCandidates = { "alacritty", "kitty", "ghostty", "foot", "konsole", "gnome-terminal", "xfce4-terminal", "terminator", "tilix", "wezterm", "rio", "contour", "hyper", "xterm", "rxvt" }
local backendTerminals = { alacritty = true, kitty = true, ghostty = true, foot = true }
local terminals = {}

local function shellQuote(s)
  if s == nil then return "''" end
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function detectTerminals()
  local list = table.concat(terminalCandidates, " ")
  local cmd = "for t in " .. list .. "; do command -v \"$t\" >/dev/null 2>&1 && echo \"$t\"; done || true"
  noctalia.runAsync(cmd, function(result)
    if result.exitCode == 0 then
      local found = {}
      for line in (result.stdout or ""):gmatch("[^\n]+") do
        local name = line:match("^(%S+)$")
        if name then table.insert(found, name) end
      end
      terminals = found
      if #terminals == 0 then
        terminals = { "kitty", "alacritty", "ghostty", "foot" }
      end
      if isOpen then renderPanel() end
    else
      terminals = { "kitty", "alacritty", "ghostty", "foot" }
      if isOpen then renderPanel() end
    end
  end)
end

local function getSelectedMonitor()
  if #monitors == 0 then return nil end
  for _, m in ipairs(monitors) do
    if m.name == selected then return m end
  end
  for _, m in ipairs(monitors) do
    if m.focused then return m end
  end
  return monitors[1]
end

local function currentModeString(m)
  if m == nil or m.modes == nil or #m.modes == 0 then return "" end
  local best = ""
  local bestDiff = 1e9
  for _, s in ipairs(m.modes) do
    local at = string.find(s, "@")
    if at then
      local dims = string.sub(s, 1, at - 1)
      local rateStr = string.sub(s, at + 1):gsub("Hz", "")
      local rate = tonumber(rateStr)
      if rate and dims == (m.width .. "x" .. m.height) then
        local diff = math.abs(rate - m.refreshRate)
        if diff < bestDiff then
          bestDiff = diff
          best = s
        end
      end
    end
  end
  return best
end

local function selectedModeIndex(modesList, m)
  local cur = currentModeString(m)
  for i, s in ipairs(modesList) do
    if s == cur then return i - 1 end
  end
  return 0
end

local function currentVrrIndex(m)
  local cfg = m and vrrConfig[m.name]
  local val = cfg or (m and m.vrr)
  for i, p in ipairs(vrrPresets) do
    if p == val then return i - 1 end
  end
  return 0
end

local function getModes(m)
  if m == nil or m.modes == nil then return {} end
  local seen = {}
  local out = {}
  for _, s in ipairs(m.modes) do
    if not seen[s] then
      seen[s] = true
      table.insert(out, s)
    end
  end
  return out
end

local function refresh()
  noctalia.runAsync("hyprctl monitors -j", function(result)
    if result.exitCode == 0 then
      local data = noctalia.json.decode(result.stdout)
      if type(data) == "table" then
        local out = {}
        for _, d in ipairs(data) do
          local modeStrings = {}
          if type(d.modes) == "table" then
            for _, rm in ipairs(d.modes) do
              if rm and rm.width then
                table.insert(modeStrings, rm.width .. "x" .. rm.height .. "@" .. rm.refreshRate)
              end
            end
          end
          if #modeStrings == 0 and type(d.availableModes) == "table" then
            for _, am in ipairs(d.availableModes) do
              table.insert(modeStrings, am)
            end
          end
          table.insert(out, {
            name = d.name,
            width = d.width,
            height = d.height,
            x = d.x,
            y = d.y,
            scale = d.scale,
            transform = d.transform,
            vrr = d.vrr == true and "1" or "0",
            focused = d.focused == true,
            modes = modeStrings,
            refreshRate = d.refreshRate or 0,
          })
        end
        monitors = out
        if selected == "" then
          for _, m in ipairs(out) do
            if m.focused then
              selected = m.name
              break
            end
          end
          if selected == "" and #out > 0 then
            selected = out[1].name
          end
        end
      end
    end
    if isOpen then renderPanel() end
  end)

  noctalia.runAsync(shellQuote(scriptDir .. "/omarchy-display-monitor") .. " vrr", function(result)
    if result.exitCode == 0 then
      local v = {}
      for line in (result.stdout or ""):gmatch("[^\n]+") do
        local name, val = line:match("^([^=]+)=([0-9]+)$")
        if name and val then v[name] = val end
      end
      vrrConfig = v
    end
  end)

  noctalia.runAsync(shellQuote(scriptDir .. "/omarchy-display-terminal") .. " list --json", function(result)
    if result.exitCode == 0 then
      local data = noctalia.json.decode(result.stdout)
      if type(data) == "table" then
        terminalSizes = data
      end
    end
    if isOpen then renderPanel() end
  end)

  detectTerminals()
end

local function setMonitor(flag, val)
  local m = getSelectedMonitor()
  if m == nil then
    noctalia.notifyError("Better Displays", "No monitor detected")
    return
  end
  local script = scriptDir .. "/omarchy-display-monitor"
  local cmd = shellQuote(script) .. " set " .. shellQuote(m.name) .. " " .. shellQuote(flag) .. " " .. shellQuote(val)
  noctalia.runAsync(cmd, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError("Better Displays", tostring(result.stderr or "Failed to apply setting"))
    end
    refresh()
  end)
end

local function setTerminal(term, size)
  local script = scriptDir .. "/omarchy-display-terminal"
  local cmd = shellQuote(script) .. " set " .. shellQuote(term) .. " " .. shellQuote(size)
  noctalia.runAsync(cmd, function()
    refresh()
  end)
end

local function stepTerminal(term, delta)
  local cur = tonumber(terminalSizes[term] or 0)
  if not cur or cur <= 0 then return end
  local next = cur + delta
  if next < 6 then next = 6 end
  if next > 40 then next = 40 end
  setTerminal(term, tostring(next))
end

local function posFor(sel, anchor, dir)
  local sw, sh = sel.width, sel.height
  local ax, ay, aw, ah = anchor.x, anchor.y, anchor.width, anchor.height
  if dir == "left" then return (ax - sw) .. "x" .. ay end
  if dir == "right" then return (ax + aw) .. "x" .. ay end
  if dir == "above" then return ax .. "x" .. (ay - sh) end
  if dir == "below" then return ax .. "x" .. (ay + ah) end
  return "auto"
end

local function monitorByName(name)
  for _, m in ipairs(monitors) do
    if m.name == name then return m end
  end
  return nil
end

local function positionButtons()
  local sel = getSelectedMonitor()
  if sel == nil then return {} end
  local out = {}
  local dirs = {
    { dir = "left", glyph = "arrow-left", label = "Left" },
    { dir = "right", glyph = "arrow-right", label = "Right" },
    { dir = "above", glyph = "arrow-up", label = "Above" },
    { dir = "below", glyph = "arrow-down", label = "Below" },
  }
  for _, o in ipairs(monitors) do
    if o.name ~= sel.name then
      for _, d in ipairs(dirs) do
        table.insert(out, { label = d.label .. " of " .. o.name, anchor = o.name, dir = d.dir, glyph = d.glyph })
      end
    end
  end
  return out
end

function renderPanel()
  local sel = getSelectedMonitor()
  local modes = getModes(sel)

  local monitorButtons = {}
  for _, m in ipairs(monitors) do
    table.insert(monitorButtons, ui.button({
      key = "mon-" .. m.name,
      text = m.name,
      controlSize = "sm",
      variant = (selected == m.name) and "primary" or "default",
      onClick = function()
        selected = m.name
        renderPanel()
      end,
    }))
  end

  local scaleButtons = {}
  for _, s in ipairs(scalePresets) do
    local isActive = sel and math.abs((sel.scale or 1) - tonumber(s)) < 0.001
    table.insert(scaleButtons, ui.button({
      key = "scale-" .. s,
      text = s .. "x",
      controlSize = "sm",
      variant = isActive and "primary" or "default",
      onClick = function()
        setMonitor("--scale", s)
      end,
    }))
  end

  local transformButtons = {}
  for _, t in ipairs(transformPresets) do
    local isActive = sel and tostring(sel.transform or "0") == t
    table.insert(transformButtons, ui.button({
      key = "orient-" .. t,
      text = transformLabels[t],
      controlSize = "sm",
      variant = isActive and "primary" or "default",
      onClick = function()
        setMonitor("--transform", t)
      end,
    }))
  end

  local posButtons = {}
  table.insert(posButtons, ui.button({
    key = "pos-auto",
    glyph = "layout-2",
    controlSize = "sm",
    variant = "outline",
    tooltip = "Auto",
    onClick = function()
      setMonitor("--pos", "auto")
    end,
  }))
  for _, pb in ipairs(positionButtons()) do
    table.insert(posButtons, ui.button({
      key = "pos-" .. pb.anchor .. "-" .. pb.dir,
      glyph = pb.glyph,
      controlSize = "sm",
      variant = "outline",
      tooltip = pb.label,
      onClick = function()
        local sel = getSelectedMonitor()
        local anchor = monitorByName(pb.anchor)
        if sel and anchor and sel.name ~= anchor.name then
          setMonitor("--pos", posFor(sel, anchor, pb.dir))
        end
      end,
    }))
  end

  local terminalRows = {}
  for _, term in ipairs(terminals) do
    local size = terminalSizes[term] or "—"
    if backendTerminals[term] then
      table.insert(terminalRows, ui.row({
        key = "term-" .. term,
        align = "center",
        justify = "space_between",
        gap = 8,
      }, {
        ui.label({ text = term, fontSize = 13, flexGrow = 1 }),
        ui.button({
          key = "term-" .. term .. "-minus",
          glyph = "minus",
          controlSize = "sm",
          onClick = function()
            stepTerminal(term, -1)
          end,
        }),
        ui.label({ text = tostring(size), fontSize = 13, width = 40, textAlign = "center" }),
        ui.button({
          key = "term-" .. term .. "-plus",
          glyph = "plus",
          controlSize = "sm",
          onClick = function()
            stepTerminal(term, 1)
          end,
        }),
      }))
    else
      table.insert(terminalRows, ui.row({
        key = "term-" .. term,
        align = "center",
        gap = 8,
      }, {
        ui.label({ text = term, fontSize = 13, flexGrow = 1 }),
        ui.label({ text = tostring(size), fontSize = 13, width = 40, textAlign = "center" }),
      }))
    end
  end

  local children = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.glyph({ name = "device-desktop", size = 20 }),
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "x", variant = "ghost", onClick = function() panel.close() end }),
    }),
    ui.separator({}),
    ui.label({ text = noctalia.tr("panel.monitor"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.row({ gap = 6 }, monitorButtons),
    ui.separator({}),
    ui.label({ text = noctalia.tr("panel.resolution"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.select({
      key = "resolution",
      options = modes,
      selectedIndex = selectedModeIndex(modes, sel),
      controlSize = "sm",
      onChange = function(index)
        local chosen = modes[tonumber(index) + 1]
        if chosen then setMonitor("--mode", chosen) end
      end,
    }),
    ui.label({ text = noctalia.tr("panel.scale"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.row({ gap = 6 }, scaleButtons),
    ui.label({ text = noctalia.tr("panel.position"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.row({ gap = 6 }, posButtons),
    ui.label({ text = noctalia.tr("panel.orientation"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.row({ gap = 6 }, transformButtons),
    ui.label({ text = noctalia.tr("panel.vrr"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.select({
      key = "vrr",
      options = vrrLabels,
      selectedIndex = currentVrrIndex(sel),
      controlSize = "sm",
      onChange = function(index)
        local chosen = vrrPresets[tonumber(index) + 1]
        if chosen then setMonitor("--vrr", chosen) end
      end,
    }),
    ui.separator({}),
    ui.label({ text = noctalia.tr("panel.terminal_font"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.column({ gap = 6 }, terminalRows),
  }

  panel.render(ui.column({ gap = 10, padding = 12, flexGrow = 1 }, children))
end

function onOpen(_context)
  isOpen = true
  selected = ""
  refresh()
end

function onClose()
  isOpen = false
end
