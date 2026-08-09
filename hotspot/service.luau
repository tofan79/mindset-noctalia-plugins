--!nonstrict

local STATUS_KEY = "hotspot_status"
local COMMAND_KEY = "hotspot_command"

local busy = false
local revision = 0
local pkexecAvailable = noctalia.commandExists("pkexec")
local available = noctalia.commandExists("nmcli") and pkexecAvailable
local refreshing = false
local refreshAgain = false

local status = {
  active = false,
  busy = false,
  available = available,
  error = "",
  revision = 0,
  ssid = "",
  interface = "",
  connection = "",
  gateway = "",
  clients = {},
  clientCount = 0,
}

local helperPath = noctalia.pluginDir() .. "/hotspot-root.sh"

local refresh
local setActive

local function publish(errorMessage)
  revision += 1
  status.busy = busy
  status.available = available
  status.revision = revision
  status.error = errorMessage or status.error or ""
  status.clientCount = #(status.clients or {})
  noctalia.state.set(STATUS_KEY, status)
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function rootCommand(...)
  local parts = { "pkexec", shellQuote(helperPath) }
  for _, arg in ipairs({ ... }) do
    table.insert(parts, shellQuote(tostring(arg)))
  end
  return table.concat(parts, " ")
end

local function showNotification(title, body, icon, urgency)
  local payload = noctalia.json.encode({
    app_name = noctalia.tr("title"),
    summary = title,
    body = body or "",
    icon = icon,
    urgency = urgency,
  })
  if payload == nil then
    if urgency == "critical" then
      noctalia.notifyError(title, body)
    else
      noctalia.notify(title, body)
    end
    return
  end

  noctalia.runAsync("noctalia msg notification-show " .. shellQuote(payload))
end

local function runCommand(command, callback, timeoutMs)
  local started = noctalia.runAsync(command, callback, timeoutMs or 15000)
  if not started and type(callback) == "function" then
    callback({
      exitCode = -1,
      stdout = "",
      stderr = noctalia.tr("error.command_start"),
      timedOut = false,
    })
  end
  return started
end

local function validateSettings()
  local ssid = noctalia.string.trim(noctalia.getConfig("ssid") or "")
  if ssid == "" then
    return false, noctalia.tr("error.missing_ssid")
  end

  local password = tostring(noctalia.getConfig("password") or "")
  if #password < 8 then
    return false, noctalia.tr("error.password_too_short")
  end

  return true, ssid, password
end

local function parseNmcliTriple(stdout, filterType)
  local entries = {}
  for line in tostring(stdout or ""):gmatch("[^\n]+") do
    local name, entryType, extra = line:match("^([^:]+):([^:]+):([^:]*)$")
    if entryType == filterType and name ~= nil and name ~= "" then
      table.insert(entries, { name = name, device = extra or "" })
    end
  end
  return entries
end

local function pickWifiInterface(callback)
  local configured = noctalia.string.trim(noctalia.getConfig("interface") or "")
  if configured ~= "" then
    callback(configured)
    return
  end

  -- Prefer a Wi-Fi device that is already connected: a concurrent AP must share
  -- the phy and channel of the interface that is actually connected.
  runCommand("nmcli -t -f DEVICE,TYPE,STATE device status", function(result)
    local connected = nil
    for line in tostring(result.stdout or ""):gmatch("[^\n]+") do
      local device, devType, state = line:match("^([^:]+):([^:]+):([^:]*)$")
      if devType == "wifi" and device ~= "" then
        if connected == nil then connected = device end
        if state == "connected" then
          connected = device
          break
        end
      end
    end
    callback(connected)
  end)
end

local function parseIpNeigh(stdout)
  local byMac = {}
  for line in tostring(stdout or ""):gmatch("[^\n]+") do
    local ip, mac = line:match("^([%d%.]+)%s+lladdr%s+([%x:]+)")
    if ip ~= nil and mac ~= nil then
      byMac[mac:lower()] = ip
    end
  end
  return byMac
end

local function fetchClients(iface, callback)
  if iface == nil or iface == "" then
    callback({})
    return
  end

  -- Client list comes from the neighbour table, readable without root.
  -- (Per-station signal would need iw station dump as root, so it is skipped.)
  runCommand("ip neigh show dev " .. shellQuote(iface), function(result)
    if result.exitCode ~= 0 then
      callback({})
      return
    end

    local merged = {}
    local byMac = parseIpNeigh(result.stdout)
    for mac, ip in pairs(byMac) do
      table.insert(merged, { mac = mac, ip = ip, signal = nil })
    end

    table.sort(merged, function(left, right)
      if left.ip ~= right.ip then
        if left.ip == "" then return false end
        if right.ip == "" then return true end
        return left.ip < right.ip
      end
      return left.mac < right.mac
    end)

    callback(merged)
  end)
end

local function inspectConnection(entry, callback)
  local command = "nmcli -g 802-11-wireless.mode,802-11-wireless.ssid,IP4.ADDRESS connection show "
    .. shellQuote(entry.name)
  runCommand(command, function(result)
    if result.exitCode ~= 0 then
      callback(nil)
      return
    end

    local mode, ssid, gateway
    local index = 0
    for line in tostring(result.stdout or ""):gmatch("[^\n]+") do
      index += 1
      local value = noctalia.string.trim(line)
      if index == 1 then mode = value
      elseif index == 2 then ssid = value
      elseif index == 3 then gateway = value end
    end

    if mode ~= "ap" then
      callback(nil)
      return
    end

    callback({
      active = true,
      connection = entry.name,
      interface = entry.device,
      ssid = ssid or "",
      gateway = gateway or "",
    })
  end)
end

local function findActiveHotspot(callback)
  runCommand("nmcli -t -f NAME,TYPE,DEVICE connection show --active", function(result)
    if result.exitCode ~= 0 then
      local detail = noctalia.string.trim(result.stderr or "")
      callback(nil, detail ~= "" and detail or noctalia.tr("error.status_failed"))
      return
    end

    local entries = parseNmcliTriple(result.stdout, "802-11-wireless")
    if #entries == 0 then
      callback(nil)
      return
    end

    local index = 1
    local function nextEntry()
      local entry = entries[index]
      if entry == nil then
        callback(nil)
        return
      end

      inspectConnection(entry, function(info)
        if info ~= nil then
          callback(info)
          return
        end
        index += 1
        nextEntry()
      end)
    end

    nextEntry()
  end)
end

local function completeRefresh(callback, active)
  refreshing = false
  if callback then callback(active) end
  if refreshAgain then
    refreshAgain = false
    refresh()
  end
end

refresh = function(callback)
  if not available then
    status.active = false
    status.clients = {}
    publish(noctalia.tr("error.missing_dependencies"))
    if callback then callback(false) end
    return
  end

  if refreshing then
    refreshAgain = true
    if callback then callback(status.active) end
    return
  end

  refreshing = true

  findActiveHotspot(function(info, err)
    if err ~= nil then
      status.active = false
      status.clients = {}
      publish(err)
      completeRefresh(callback, false)
      return
    end

    if info == nil then
      status.active = false
      status.ssid = ""
      status.interface = ""
      status.connection = ""
      status.gateway = ""
      status.clients = {}
      publish()
      completeRefresh(callback, false)
      return
    end

    status.active = true
    status.ssid = info.ssid
    status.interface = info.interface
    status.connection = info.connection
    status.gateway = info.gateway

    fetchClients(info.interface, function(clients)
      status.clients = clients
      publish()
      completeRefresh(callback, true)
    end)
  end)
end

local function finishToggle(expectedActive, result)
  if result.exitCode ~= 0 then
    busy = false
    local detail = noctalia.string.trim(result.stderr or "")
    if detail == "" then detail = noctalia.string.trim(result.stdout or "") end
    if detail == "" then detail = noctalia.tr("error.command_failed") end
    publish(detail)
    showNotification(noctalia.tr("title"), detail, "alert-circle", "critical")
    refresh()
    return
  end

  refresh(function(currentActive)
    busy = false
    publish()

    if currentActive ~= expectedActive then
      showNotification(noctalia.tr("title"), noctalia.tr("error.state_mismatch"), "alert-circle", "critical")
    elseif currentActive then
      showNotification(
        noctalia.tr("notification.enabled.title"),
        noctalia.tr("notification.enabled.body", { ssid = status.ssid or noctalia.getConfig("ssid") or "" }),
        "wifi",
        "normal"
      )
    else
      showNotification(
        noctalia.tr("notification.disabled.title"),
        noctalia.tr("notification.disabled.body"),
        "wifi-off",
        "normal"
      )
    end
  end)
end

local function startHotspot()
  local ok, ssidOrError, password = validateSettings()
  if not ok then
    busy = false
    publish(ssidOrError)
    showNotification(noctalia.tr("title"), ssidOrError, "alert-circle", "critical")
    return
  end

  if not pkexecAvailable then
    busy = false
    local message = noctalia.tr("error.no_pkexec")
    publish(message)
    showNotification(noctalia.tr("title"), message, "alert-circle", "critical")
    return
  end

  pickWifiInterface(function(iface)
    if iface == nil or iface == "" then
      busy = false
      local message = noctalia.tr("error.no_wifi_device")
      publish(message)
      showNotification(noctalia.tr("title"), message, "alert-circle", "critical")
      return
    end

    runCommand(rootCommand("on", ssidOrError, password, iface), function(result)
      finishToggle(true, result)
    end, 30000)
  end)
end

local function stopHotspot()
  if not pkexecAvailable then
    busy = false
    local message = noctalia.tr("error.no_pkexec")
    publish(message)
    showNotification(noctalia.tr("title"), message, "alert-circle", "critical")
    return
  end

  if status.connection ~= nil and status.connection ~= "" then
    runCommand(rootCommand("off"), function(result)
      finishToggle(false, result)
    end)
    return
  end

  findActiveHotspot(function(info)
    if info == nil then
      busy = false
      status.active = false
      status.clients = {}
      publish()
      showNotification(
        noctalia.tr("notification.disabled.title"),
        noctalia.tr("notification.disabled.body"),
        "wifi-off",
        "normal"
      )
      return
    end

    runCommand(rootCommand("off"), function(result)
      finishToggle(false, result)
    end)
  end)
end

setActive = function(nextActive)
  if busy or not available then return end

  if nextActive then
    local ok, message = validateSettings()
    if not ok then
      publish(message)
      showNotification(noctalia.tr("title"), message, "alert-circle", "critical")
      return
    end
  end

  busy = true
  publish()

  if nextActive then
    startHotspot()
  else
    stopHotspot()
  end
end

local function handleCommand(action)
  if action == "toggle" then
    setActive(not status.active)
  elseif action == "enable" then
    setActive(true)
  elseif action == "disable" then
    setActive(false)
  elseif action == "refresh" or action == "status" then
    refresh()
  end
end

noctalia.state.watch(COMMAND_KEY, function(command)
  if type(command) ~= "table" or type(command.action) ~= "string" then return end
  handleCommand(command.action)
end)

publish(available and "" or noctalia.tr("error.missing_dependencies"))
refresh()

function update()
  local seconds = tonumber(noctalia.getConfig("refresh_interval")) or 5
  noctalia.setUpdateInterval(math.max(2, seconds) * 1000)
  if not busy then
    refresh()
  end
end

function onConfigChanged()
  update()
end

function onIpc(event, _payload)
  handleCommand(event)
end
