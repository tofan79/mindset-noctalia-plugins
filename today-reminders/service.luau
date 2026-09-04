--!nonstrict
--
-- Today Reminders service: loads reminders, fires notifications when due,
-- and auto-deletes them at end of day.
--
-- IPC: panel sets commands via noctalia.state.set("reminders_cmd", {...})
-- Service watches reminders_cmd and processes actions.
-- Timer via global update() + noctalia.setUpdateInterval().

local DATA_FILE = noctalia.appdir() .. "/reminders.json"

local M = {}

local reminders = {}
local REFRESH_MS = 30000  -- poll every 30s

-- ── Persistence ──────────────────────────────────────────────────────────────

local function load()
    local f = io.open(DATA_FILE, "r")
    if not f then return {} end
    local data = f:read("*a")
    f:close()
    if data == "" then return {} end
    local ok, parsed = pcall(noctalia.json.decode, data)
    if not ok or type(parsed) ~= "table" then return {} end
    local today = os.date("%Y-%m-%d")
    local filtered = {}
    for _, r in ipairs(parsed) do
        if r.date == today then table.insert(filtered, r) end
    end
    return filtered
end

local function save(list)
    local ok, data = pcall(noctalia.json.encode, list)
    if not ok then return end
    local f = io.open(DATA_FILE, "w")
    if not f then return end
    f:write(data)
    f:close()
end

-- ── State broadcast ───────────────────────────────────────────────────────────

local function broadcast()
    local pending = 0
    for _, r in ipairs(reminders) do
        if not r.done then pending = pending + 1 end
    end
    noctalia.state.set("reminders", {
        reminders = reminders,
        count = pending,
    })
end

-- ── Actions ───────────────────────────────────────────────────────────────────

function M.add(time_str, text)
    local today = os.date("%Y-%m-%d")
    table.insert(reminders, {
        id = os.time(),
        date = today,
        time = time_str or "00:00",
        text = text or "",
        done = false,
    })
    table.sort(reminders, function(a, b) return a.time < b.time end)
    save(reminders)
    broadcast()
end

function M.dismiss(id)
    local num = tonumber(id)
    for i, r in ipairs(reminders) do
        if r.id == num then
            table.remove(reminders, i)
            save(reminders)
            broadcast()
            return
        end
    end
end

function M.clearDone()
    local changed = false
    for i = #reminders, 1, -1 do
        if reminders[i].done then
            table.remove(reminders, i)
            changed = true
        end
    end
    if changed then
        save(reminders)
        broadcast()
    end
end

-- ── IPC handler: watches state changes from the panel ─────────────────────────

function M.handleCommand(cmd)
    if not cmd or type(cmd) ~= "table" then return end
    local action = cmd.action
    if action == "add" then
        M.add(cmd.time, cmd.text)
    elseif action == "dismiss" then
        M.dismiss(cmd.id)
    elseif action == "clearDone" then
        M.clearDone()
    end
end

-- ── Timer ─────────────────────────────────────────────────────────────────────

local function tick()
    local now = os.date("%H:%M")
    for _, r in ipairs(reminders) do
        if not r.done and r.time == now then
            r.done = true
            local body = r.text or ""
            noctalia.runAsync({ "sh", "-c", "notify-send -u normal 'Reminder' " .. string.format("%q", body) }, function() end)
        end
    end
    save(reminders)
    broadcast()
end

-- ── Noctalia entry points ─────────────────────────────────────────────────────

function init()
    reminders = load()
    broadcast()
    noctalia.setUpdateInterval(REFRESH_MS)
end

function update()
    tick()
end

function onConfigChanged()
    -- no runtime config changes
end

function onIpc(event)
    -- handles CLI: noctalia msg plugin mindset/today-reminders:service all <event>
end

-- Watch for panel commands
noctalia.state.watch("reminders_cmd", M.handleCommand)

M.init()

return M
