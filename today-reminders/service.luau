--!nonstrict
--
-- Today Reminders service: set reminder in X minutes from now.
-- Stores fireAt as absolute timestamp, checks in tick().

local DATA_FILE = noctalia.appdir() .. "/reminders.json"

local M = {}
local reminders = {}

-- ── Persistence ──────────────────────────────────────────────────────────────

local function load()
    local f = io.open(DATA_FILE, "r")
    if not f then return {} end
    local data = f:read("*a")
    f:close()
    if data == "" then return {} end
    local ok, parsed = pcall(noctalia.json.decode, data)
    if not ok or type(parsed) ~= "table" then return {} end
    return parsed
end

local function save()
    local ok, data = pcall(noctalia.json.encode, reminders)
    if not ok then return end
    local f = io.open(DATA_FILE, "w")
    if not f then return end
    f:write(data)
    f:close()
end

-- ── Broadcast ───────────────────────────────────────────────────────────────

local function broadcast()
    local pending = 0
    for _, r in ipairs(reminders) do
        if not r.done then pending = pending + 1 end
    end
    noctalia.state.set("reminders", { reminders = reminders, count = pending })
end

-- ── Add reminder ─────────────────────────────────────────────────────────────

function M.add(minutes, text)
    local fireAt = os.time() + (tonumber(minutes) or 1) * 60
    table.insert(reminders, {
        id = os.time(),
        text = text or "",
        fireAt = fireAt,
        done = false,
    })
    save()
    broadcast()
end

function M.dismiss(id)
    local num = tonumber(id)
    for i, r in ipairs(reminders) do
        if r.id == num then table.remove(reminders, i); break end
    end
    save()
    broadcast()
end

function M.clearDone()
    local changed = false
    for i = #reminders, 1, -1 do
        if reminders[i].done then table.remove(reminders, i); changed = true end
    end
    if changed then save(); broadcast() end
end

-- ── IPC handler ─────────────────────────────────────────────────────────────

function M.handleCommand(cmd)
    if not cmd or type(cmd) ~= "table" then return end
    local action = cmd.action
    if action == "add" then
        M.add(cmd.minutes, cmd.text)
    elseif action == "dismiss" then
        M.dismiss(cmd.id)
    elseif action == "clearDone" then
        M.clearDone()
    end
end

-- ── Timer (every 10s) ───────────────────────────────────────────────────────

local function tick()
    local now = os.time()
    for _, r in ipairs(reminders) do
        if not r.done and r.fireAt <= now then
            r.done = true
            local body = r.text or ""
            noctalia.runAsync({ "sh", "-c", "notify-send -u normal 'Reminder' " .. string.format("%q", body) }, function() end)
        end
    end
    save()
    broadcast()
end

-- ── Entry points ─────────────────────────────────────────────────────────────

function init()
    reminders = load()
    broadcast()
    noctalia.setUpdateInterval(10000)  -- every 10s
end

function update()
    tick()
end

function onConfigChanged() end
function onIpc(event) end

noctalia.state.watch("reminders_cmd", M.handleCommand)
M.init()
return M
