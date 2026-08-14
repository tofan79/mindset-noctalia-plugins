--!nonstrict
-- Minimal Noctalia host used by the standalone Luau tests. Luajit-compatible
-- (no `+=`), so the same file runs under `luau` and `luajit`.
--
-- A single shared instance lives on `_G.__gm_host_mock` so the test and the
-- service under test (which loads the same file) read and write the same
-- files, state, and config.

if _G.__gm_host_mock ~= nil then
    return _G.__gm_host_mock
end

local files = {}
local stateValues = {}
local stateWatchers = {}
local fileExistsOverrides = {}
local configValues = {}
local availableCommands = {}
local asyncRequests = {}
local errorNotifications = 0
local updateInterval = nil
local readCounts = {}
local writeCounts = {}
local encodedValues = {}
local encodedIndex = 0
local wantsSecondTicks = false

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[copy(key)] = copy(item) end
  return result
end

local function normalize(path)
  local absolute = path:sub(1, 1) == "/"
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 then table.remove(parts) end
    elseif part ~= "." and part ~= "" then
      table.insert(parts, part)
    end
  end
  return (absolute and "/" or "") .. table.concat(parts, "/")
end

local function directory(path)
  local prefix = path:gsub("/+$", "") .. "/"
  local names = {}
  for file in pairs(files) do
    if file:sub(1, #prefix) == prefix then
      local rest = file:sub(#prefix + 1)
      local name = rest:match("^([^/]+)")
      if name ~= nil then names[name] = true end
    end
  end
  return names
end

local function translation(key, values)
  local value = key
  if values ~= nil then
    for name, replacement in pairs(values) do
      value = value:gsub("{" .. name .. "}", tostring(replacement))
    end
  end
  return value
end

local noctalia = {
  tr = translation,
  trp = translation,
  getenv = function(name) return name == "HOME" and "/home/test" or nil end,
  expandPath = function(path) return normalize(path:gsub("^~", "/home/test")) end,
  fileExists = function(path)
    path = normalize(path)
    if fileExistsOverrides[path] ~= nil then return fileExistsOverrides[path] end
    if files[path] ~= nil then return true end
    return next(directory(path)) ~= nil
  end,
  readFile = function(path)
    path = normalize(path)
    readCounts[path] = (readCounts[path] or 0) + 1
    local content = files[path]
    if content ~= nil then return content, nil end
    return nil, "missing"
  end,
  writeFile = function(path, content)
    path = normalize(path)
    files[path] = content
    writeCounts[path] = (writeCounts[path] or 0) + 1
    return true
  end,
  renameFile = function(from, to)
    from = normalize(from)
    to = normalize(to)
    if files[from] == nil then return false, "missing" end
    files[to] = files[from]
    files[from] = nil
    return true
  end,
  removeFile = function(path)
    files[normalize(path)] = nil
    return true
  end,
  mkdirAll = function() return true end,
  pluginDir = function() return "/plugin" end,
  pluginDataDir = function() return "/data" end,
  commandExists = function(name) return availableCommands[name] == true end,
  getConfig = function(key) return configValues[key] end,
  notify = function() end,
  notifyError = function() errorNotifications = errorNotifications + 1 end,
  log = function() end,
  setUpdateInterval = function(value) updateInterval = value end,
  runAsync = function(command, callback, timeoutMs)
    table.insert(asyncRequests, { command = command, callback = callback, timeoutMs = timeoutMs, completed = false })
    return true
  end,
  systemStats = function() return {} end,
  string = { trim = function(value) return (value:gsub("^%s+", ""):gsub("%s+$", "")) end },
  json = {
    decode = function(raw)
      local value = encodedValues[raw]
      if value == nil then return nil, "invalid mock JSON" end
      return copy(value), nil
    end,
    encode = function(value)
      encodedIndex = encodedIndex + 1
      local token = "__mock_json_" .. tostring(encodedIndex)
      encodedValues[token] = copy(value)
      return token, nil
    end,
  },
  state = {
    get = function(key) return copy(stateValues[key]) end,
    set = function(key, value)
      stateValues[key] = copy(value)
      for _, watcher in ipairs(stateWatchers[key] or {}) do watcher(copy(value)) end
    end,
    watch = function(key, callback)
      stateWatchers[key] = stateWatchers[key] or {}
      table.insert(stateWatchers[key], callback)
    end,
  },
}

local host = {
  noctalia = noctalia,
  setFiles = function(value)
    files = {}
    fileExistsOverrides = {}
    for path, content in pairs(value) do files[normalize(path)] = content end
  end,
  setFileExists = function(path, value)
    fileExistsOverrides[normalize(path)] = value
  end,
  setFile = function(path, content)
    files[normalize(path)] = content
  end,
  setConfig = function(values) configValues = values or {} end,
  setAvailableCommands = function(values) availableCommands = values or {} end,
  resetRuntime = function()
    stateValues = {}
    configValues = {}
    availableCommands = {}
    asyncRequests = {}
    errorNotifications = 0
    updateInterval = nil
    readCounts = {}
    writeCounts = {}
    wantsSecondTicks = false
  end,
  asyncLaunchCount = function() return #asyncRequests end,
  completeAsync = function(index, result)
    local request = asyncRequests[index]
    if request == nil or request.completed then return false end
    request.completed = true
    if request.callback ~= nil then request.callback(result) end
    return true
  end,
  readCount = function(path) return readCounts[normalize(path)] or 0 end,
  writeCount = function(path) return writeCounts[normalize(path)] or 0 end,
  fileContent = function(path) return files[normalize(path)] end,
  stateValue = function(key) return copy(stateValues[key]) end,
  errorNotificationCount = function() return errorNotifications end,
  updateInterval = function() return updateInterval end,
  wantsSecondTicks = function() return wantsSecondTicks end,
}

_G.__gm_host_mock = host
return host
