--!nonstrict
--
-- Today Reminders service: add/dismiss reminders, fire notifications when due.

local DATA_FILE = (noctalia.pluginDataDir() or "") .. "/reminders.json"

local M = { reminders = {}, nextId = 1 }

-- ── Persistence ──────────────────────────────────────────────────────────────

local function load()
    if DATA_FILE == "" then return {} end
    local raw, err = noctalia.readFile(DATA_FILE)
    if not raw then return {} end
    local ok, val = pcall(noctalia.json.decode, raw)
    if not ok or type(val) ~= "table" then return {} end
    return val
end

local function save()
    if DATA_FILE == "" then return end
    local ok, encoded = pcall(noctalia.json.encode, M.reminders)
    if not ok then return end
    noctalia.writeFile(DATA_FILE, encoded)
end

-- ── State ────────────────────────────────────────────────────────────────────

local function countReminders()
    local n = 0
    for _ in pairs(M.reminders) do n = n + 1 end
    return n
end

local function broadcast()
    local n = 0
    for _ in pairs(M.reminders) do n = n + 1 end
    noctalia.state.set("reminders", {
        reminders = M.reminders,
        count = n,
    })
end

-- ── Actions ──────────────────────────────────────────────────────────────────

function M.add(minutes, text)
    local fireAt = os.time() + (tonumber(minutes) or 1) * 60
    local id = M.nextId
    M.nextId = M.nextId + 1
    M.reminders[id] = { id = id, fireAt = fireAt, text = text or "", done = false }
    save()
    broadcast()
end

function M.dismiss(id)
    local nid = tonumber(id)
    if nid and M.reminders[nid] then
        M.reminders[nid] = nil
        save()
        broadcast()
    end
end

function M.clearDone()
    for id, r in pairs(M.reminders) do
        if r.done then M.reminders[id] = nil end
    end
    save()
    broadcast()
end

-- ── IPC: called from panel ───────────────────────────────────────────────────

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

-- ── Timer ─────────────────────────────────────────────────────────────────────

local function tick()
    local now = os.time()
    for id, r in pairs(M.reminders) do
        if not r.done and r.fireAt <= now then
            r.done = true
            local body = r.text or "Reminder!"
            noctalia.runAsync(
                { "notify-send", "-u", "normal", "Reminder", body },
                function() end
            )
            -- auto-clear setelah 3 detik biar user lihat status "done" dulu
            local laterId = id
            local laterBody = body
            noctalia.runAsync(
                { "sleep", "3" },
                function()
                    M.dismiss(laterId)
                end
            )
        end
    end
end

-- ── Entry points ──────────────────────────────────────────────────────────────

function M.init()
    M.reminders = load()
    broadcast()
    noctalia.setUpdateInterval(10000)
end

function update()
    tick()
end

function onConfigChanged() end
function onIpc(event, payload)
    noctalia.log("onIpc: event=" .. tostring(event) .. " payload=" .. tostring(payload))
    if type(payload) == "string" then
        local ok, decoded = pcall(noctalia.json.decode, payload)
        if ok and type(decoded) == "table" then payload = decoded end
    end
    if event == "add" then
        M.add(payload.minutes, payload.text)
    elseif event == "dismiss" then
        M.dismiss(payload.id)
    elseif event == "clearDone" then
        M.clearDone()
    end
end

-- Watch for panel commands
noctalia.state.watch("reminders_cmd", M.handleCommand)

M.init()
return M
