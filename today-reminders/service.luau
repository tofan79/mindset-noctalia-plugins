--!nonstrict
--
-- Today Reminders service: loads reminders, fires notifications when due,
-- and auto-deletes them at end of day.

local DATA_FILE = noctalia.appdir() .. "/reminders.json"

local M = {}

local reminders = {}
local tick_timer = nil

-- ── Persistence ──────────────────────────────────────────────────────────────

local function load()
    local f = io.open(DATA_FILE, "r")
    if not f then return {} end
    local data = f:read("*a")
    f:close()
    local ok, parsed = pcall(noctalia.jsonDecode, data)
    if not ok or type(parsed) ~= "table" then return {} end
    -- prune reminders past today's date
    local today = os.date("%Y-%m-%d")
    local filtered = {}
    for _, r in ipairs(parsed) do
        if r.date == today then table.insert(filtered, r) end
    end
    return filtered
end

local function save(list)
    local ok, data = pcall(noctalia.jsonEncode, list)
    if not ok then return end
    local f = io.open(DATA_FILE, "w")
    if not f then return end
    f:write(data)
    f:close()
end

-- ── Reminder ops ─────────────────────────────────────────────────────────────

function M.add(time_str, text)
    local today = os.date("%Y-%m-%d")
    table.insert(reminders, {
        id = os.time(),
        date = today,
        time = time_str,
        text = text,
        done = false,
    })
    table.sort(reminders, function(a, b) return a.time < b.time end)
    save(reminders)
    broadcast()
end

function M.remove(id)
    for i, r in ipairs(reminders) do
        if r.id == id then
            table.remove(reminders, i)
            save(reminders)
            broadcast()
            return
        end
    end
end

function M.dismiss(id)
    for i, r in ipairs(reminders) do
        if r.id == id then
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

-- ── State broadcast ───────────────────────────────────────────────────────────

local function broadcast()
    noctalia.state.set("reminders", {
        reminders = reminders,
        count = #reminders,
    })
end

-- ── Timer check ─────────────────────────────────────────────────────────────

local function secondsUntil(time_str)
    -- time_str is "HH:MM" in 24h
    local h = tonumber(time_str:sub(1, 2)) or 0
    local m = tonumber(time_str:sub(4, 5)) or 0
    local now = os.date("*t")
    local target = {
        year = now.year, month = now.month, day = now.day,
        hour = h, min = m, sec = 0,
    }
    local t = os.time(target)
    local diff = t - os.time(now)
    -- if past today, check tomorrow
    if diff <= 0 then diff = diff + 86400 end
    return diff
end

local function fire(r)
    if r.done then return end
    local sound = noctalia.getConfig("sound") ~= false
    local body = r.text or ""
    if sound then
        os.execute("notify-send -u normal \"Reminder\" " .. noctalia.shellQuote(body) .. " 2>/dev/null")
        os.execute("canberra-gtk-play -i notification 2>/dev/null")
    else
        os.execute("notify-send -u normal \"Reminder\" " .. noctalia.shellQuote(body) .. " 2>/dev/null")
    end
    r.done = true
    save(reminders)
    broadcast()
end

local function tick()
    local now = os.date("%H:%M")
    for _, r in ipairs(reminders) do
        if not r.done and r.time == now then
            fire(r)
        end
    end
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

noctalia.onInit(function()
    reminders = load()
    broadcast()
    -- check every 30s
    noctalia.interval(30, tick)
end)

noctalia.onExit(function()
    save(reminders)
end)

-- IPC handlers
noctalia.handle("add", function(args)
    M.add(args[1], args[2] or "")
end)

noctalia.handle("remove", function(args)
    M.remove(tonumber(args[1]))
end)

noctalia.handle("dismiss", function(args)
    M.dismiss(tonumber(args[1]))
end)

noctalia.handle("clearDone", function()
    M.clearDone()
end)

return M
