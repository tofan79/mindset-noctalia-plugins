--!nonstrict

local scriptDir = noctalia.pluginDir() .. "/bin"
local refreshSeconds = 4

local monitors = {}
local selected = ""
local terminalSizes = {}
local isOpen = false

local scalePresets = { "1", "1.25", "1.6", "2", "3", "4" }
local transformPresets = { "0", "1", "2", "3" }
local transformLabels = { ["0"] = "0°", ["1"] = "90°", ["2"] = "180°", ["3"] = "270°" }
local terminals = { "alacritty", "kitty", "ghostty", "foot" }

local function shellQuote(s)
  if s == nil then return "''" end
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
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

  noctalia.runAsync("bash " .. shellQuote(scriptDir .. "/omarchy-display-terminal list --json"), function(result)
    if result.exitCode == 0 then
      local data = noctalia.json.decode(result.stdout)
      if type(data) == "table" then
        terminalSizes = data
      end
    end
    if isOpen then renderPanel() end
  end)
end

local function setMonitor(flag, val)
  local m = getSelectedMonitor()
  if m == nil then return end
  local cmd = "bash " .. shellQuote(scriptDir .. "/omarchy-display-monitor set " .. shellQuote(m.name) .. " " .. shellQuote(flag) .. " " .. shellQuote(val))
  noctalia.runAsync(cmd, function()
    refresh()
  end)
end

local function setTerminal(term, size)
  local cmd = "bash " .. shellQuote(scriptDir .. "/omarchy-display-terminal set " .. shellQuote(term) .. " " .. shellQuote(size))
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

local function posFor(sel, other, dir)
  local sw, sh = sel.width, sel.height
  local ox, oy, ow, oh = other.x, other.y, other.width, other.height
  if dir == "left" then return (ox - sw) .. "x" .. oy end
  if dir == "right" then return (ox + ow) .. "x" .. oy end
  if dir == "above" then return ox .. "x" .. (oy - sh) end
  if dir == "below" then return ox .. "x" .. (oy + oh) end
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
    { dir = "left", glyph = "chevron-left" },
    { dir = "right", glyph = "chevron-right" },
    { dir = "above", glyph = "chevron-up" },
    { dir = "below", glyph = "chevron-down" },
  }
  for _, o in ipairs(monitors) do
    if o.name ~= sel.name then
      for _, d in ipairs(dirs) do
        table.insert(out, { label = d.glyph .. " " .. o.name, other = o.name, dir = d.dir })
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
    text = "Auto",
    controlSize = "sm",
    onClick = function()
      setMonitor("--pos", "auto")
    end,
  }))
  for _, pb in ipairs(positionButtons()) do
    table.insert(posButtons, ui.button({
      key = "pos-" .. pb.other .. "-" .. pb.dir,
      text = pb.label,
      controlSize = "sm",
      onClick = function()
        local m = getSelectedMonitor()
        local other = monitorByName(pb.other)
        if m and other then
          setMonitor("--pos", posFor(m, other, pb.dir))
        end
      end,
    }))
  end

  local terminalRows = {}
  for _, term in ipairs(terminals) do
    local size = terminalSizes[term] or "—"
    table.insert(terminalRows, ui.row({
      key = "term-" .. term,
      align = "center",
      gap = 8,
    }, {
      ui.label({ text = term, fontSize = 13, width = 90 }),
      ui.button({
        key = "term-" .. term .. "-minus",
        text = "−",
        controlSize = "sm",
        onClick = function()
          stepTerminal(term, -1)
        end,
      }),
      ui.label({ text = tostring(size), fontSize = 13, width = 40, textAlign = "center" }),
      ui.button({
        key = "term-" .. term .. "-plus",
        text = "+",
        controlSize = "sm",
        onClick = function()
          stepTerminal(term, 1)
        end,
      }),
    }))
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
      selectedIndex = 1,
      controlSize = "sm",
      onChange = function(value)
        setMonitor("--mode", value)
      end,
    }),
    ui.label({ text = noctalia.tr("panel.scale"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.row({ gap = 6 }, scaleButtons),
    ui.label({ text = noctalia.tr("panel.position"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.row({ gap = 6, wrap = true }, posButtons),
    ui.label({ text = noctalia.tr("panel.orientation"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.row({ gap = 6 }, transformButtons),
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
