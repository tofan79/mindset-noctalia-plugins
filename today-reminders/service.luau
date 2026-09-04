--!nonstrict
--
-- Today Reminders service — simplest possible: minutes from now.
-- No HH:MM parsing. Input is minutes from current time.
--

local STORAGE_KEY = "mindset/today-reminders:reminders"

-- Module
local M = {}

-- Persist reminders to noctalia.json
local function loadReminders()
    local data = noctalia.json.decode(noctalia.readFile(noctalia.json))
    if not data then return {} end
    if type(data.reminders) ~= "table" then return {} end
    return data.reminders
end

local function saveReminders(reminders)
    local data = noctalia.json.decode(noctalia.readFile(noctalia.json)) or {}
    data.reminders = reminders
    noctalia.writeFile(noctalia.json, noctalia.json.encode(data))
end

-- Load on init
M.reminders = loadReminders()

-- Called by plugin host every tick
function update()
    local now = os.time()
    local changed = false

    for i = #M.reminders, 1, -1 do
        local r = M.reminders[i]
        if r.fireAt <= now then
            -- Fire notification
            local text = r.text or "Reminder!"
            os.execute('notify-send "⏰ ' .. text .. '" --expire-time=10000')
            table.remove(M.reminders, i)
            changed = true
        end
    end

    if changed then
        saveReminders(M.reminders)
    end

    -- Publish count for widget
    noctalia.state.set("reminders_count", #M.reminders)
end

-- IPC: add reminder
function addReminder(minutes, text)
    local fireAt = os.time() + (tonumber(minutes) or 0) * 60
    table.insert(M.reminders, { fireAt = fireAt, text = text or "" })
    saveReminders(M.reminders)
end

-- IPC: dismiss
function dismissReminder(id)
    table.remove(M.reminders, id)
    saveReminders(M.reminders)
end

-- IPC: clear all
function dismissAll()
    M.reminders = {}
    saveReminders(M.reminders)
end

-- IPC: list
function getReminders()
    return M.reminders
end

-- Init: set initial state
noctalia.state.set("reminders_count", #M.reminders)

M.init = function()
    -- nothing extra needed
end

return M
