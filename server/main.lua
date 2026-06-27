local RES = GetCurrentResourceName()
local DATA_FILE = 'data/booths.json'   -- JSON-fallback booth definitions
local DATA_BAK  = 'data/booths.bak.json'
local QUEUE_FILE = 'data/queues.json'

local booths = {}
local cooldown = {}

local function dbg(...)
    if Config.Debug then print('[moe-dj]', ...) end
end

local function nowMs()
    return GetGameTimer()
end

--------------------------------------------------------------------------------
-- Persistence
--   Booth definitions -> oxmysql (table moe_dj_booths) when available, else JSON.
--   Queues            -> data/queues.json
--------------------------------------------------------------------------------

local usingSql = false

local function boothDef(b)
    return {
        id = b.id, name = b.name, controlPoint = b.controlPoint, prop = b.prop,
        speakers = b.speakers, range = b.range, falloff = b.falloff,
        job = b.job, grades = b.grades, blip = b.blip, baseVolume = b.baseVolume,
    }
end

local function saveBoothsFile()
    local arr = {}
    for _, b in pairs(booths) do arr[#arr + 1] = boothDef(b) end
    SaveResourceFile(RES, DATA_FILE, json.encode(arr), -1)
end

local boothTimer = {}
local function saveBooth(id)
    if boothTimer[id] then return end
    boothTimer[id] = true
    SetTimeout(700, function()
        boothTimer[id] = nil
        local b = booths[id]
        if not b then return end
        if usingSql then
            exports.oxmysql:execute(
                'INSERT INTO moe_dj_booths (id, data) VALUES (?, ?) ON DUPLICATE KEY UPDATE data = VALUES(data)',
                { id, json.encode(boothDef(b)) })
        else
            saveBoothsFile()
        end
    end)
end

local function deleteBoothRow(id)
    boothTimer[id] = nil
    if usingSql then
        exports.oxmysql:execute('DELETE FROM moe_dj_booths WHERE id = ?', { id })
    else
        saveBoothsFile()
    end
end

local queueTimer = false
local function saveQueues()
    if queueTimer then return end
    queueTimer = true
    SetTimeout(1000, function()
        queueTimer = false
        local map = {}
        for id, b in pairs(booths) do
            local q = {}
            -- prepend the now-playing track so a restart re-queues it (restarts from 0)
            if b.currentTrack then
                q[#q + 1] = {
                    sourceType = b.currentTrack.sourceType, url = b.currentTrack.url,
                    title = b.currentTrack.title, duration = b.currentTrack.duration,
                }
            end
            for _, item in ipairs(b.queue or {}) do q[#q + 1] = item end
            map[id] = q
        end
        SaveResourceFile(RES, QUEUE_FILE, json.encode(map), -1)
    end)
end

local function materialize(defs, queues)
    for _, d in ipairs(defs) do
        d.queue = queues[d.id] or {}
        d.status = 'idle'
        d.currentTrack = nil
        d.startEpochMs = nil
        d.pauseOffsetMs = 0
        d.baseVolume = d.baseVolume or 0.8
        booths[d.id] = d
    end
    dbg(('loaded %d booth(s) [%s]'):format(#defs, usingSql and 'sql' or 'json'))
end

local function loadQueues()
    local raw = LoadResourceFile(RES, QUEUE_FILE)
    if raw and raw ~= '' then
        local ok, m = pcall(json.decode, raw)
        if ok and type(m) == 'table' then return m end
    end
    return {}
end

local function defsFromJson(queues)
    local defs = {}
    local raw = LoadResourceFile(RES, DATA_FILE)
    if not raw or raw == '' then raw = LoadResourceFile(RES, DATA_BAK) end
    if raw and raw ~= '' then
        local ok, arr = pcall(json.decode, raw)
        if ok and type(arr) == 'table' then
            for _, b in ipairs(arr) do
                if b.id then
                    defs[#defs + 1] = boothDef(b)
                    if b.queue and not queues[b.id] then queues[b.id] = b.queue end
                end
            end
        end
    end
    return defs
end

local function load()
    -- if oxmysql is installed but still starting, give it a moment
    if GetResourceState('oxmysql') ~= 'missing' then
        local tries = 0
        while GetResourceState('oxmysql') ~= 'started' and tries < 50 do Wait(100); tries = tries + 1 end
    end
    usingSql = GetResourceState('oxmysql') == 'started'
    local queues = loadQueues()

    if not usingSql then
        materialize(defsFromJson(queues), queues)
        return
    end

    exports.oxmysql:execute('CREATE TABLE IF NOT EXISTS moe_dj_booths (id VARCHAR(50) PRIMARY KEY, data LONGTEXT NOT NULL)', {})
    exports.oxmysql:query('SELECT id, data FROM moe_dj_booths', {}, function(rows)
        local defs = {}
        for _, row in ipairs(rows or {}) do
            local ok, d = pcall(json.decode, row.data)
            if ok and type(d) == 'table' and d.id then defs[#defs + 1] = d end
        end
        materialize(defs, queues)
    end)
end

local function publicBooth(b)
    return {
        id = b.id,
        name = b.name,
        controlPoint = b.controlPoint,
        prop = b.prop,
        speakers = b.speakers,
        range = b.range or Config.DefaultRange,
        falloff = b.falloff or Config.DefaultFalloff,
        blip = b.blip ~= false,
        baseVolume = b.baseVolume or 0.8,
        status = b.status or 'idle',
        currentTrack = b.currentTrack,
        startEpochMs = b.startEpochMs,
        pauseOffsetMs = b.pauseOffsetMs or 0,
    }
end

local function allPublicBooths()
    local out = {}
    for _, b in pairs(booths) do out[#out + 1] = publicBooth(b) end
    return out
end

local function adminBooth(b)
    local pb = publicBooth(b)
    pb.job = b.job or ''
    pb.grades = b.grades or {}
    return pb
end

local function allAdminBooths()
    local out = {}
    for _, b in pairs(booths) do out[#out + 1] = adminBooth(b) end
    return out
end

local function broadcastBooth(b)
    TriggerClientEvent('moedj:boothState', -1, publicBooth(b))
end

local function broadcastRemoval(id)
    TriggerClientEvent('moedj:boothRemoved', -1, id)
end

local function sendAccess(src)
    local map = {}
    for id, b in pairs(booths) do map[id] = CanDJ(src, b) end
    TriggerClientEvent('moedj:access', src, map)
end

local function broadcastAccess()
    for _, src in ipairs(GetPlayers()) do sendAccess(tonumber(src)) end
end

--------------------------------------------------------------------------------
-- URL validation / source typing
--------------------------------------------------------------------------------

local function hostOf(url)
    return (url:match('^%w+://([^/]+)') or ''):lower()
end

local function youtubeVideoId(url)
    return url:match('[?&]v=([%w_%-]+)')
        or url:match('youtu%.be/([%w_%-]+)')
        or url:match('/embed/([%w_%-]+)')
        or url:match('/shorts/([%w_%-]+)')
end

-- Returns 'youtube' for an allowed single-video YouTube link, or nil.
local function classifyUrl(url)
    if type(url) ~= 'string' or not url:match('^https?://') then return nil end
    local host = hostOf(url)
    for _, h in ipairs(Config.AllowedHosts) do
        if host == h then
            -- only accept YT links that resolve to a single video; bare
            -- playlist/channel URLs are expanded client-side before they get here
            if host:find('youtu') then return youtubeVideoId(url) and 'youtube' or nil end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function notify(src, msg, kind)
    TriggerClientEvent('moedj:notify', src, msg, kind or 'info')
end

local function onCooldown(src)
    local t = GetGameTimer()
    if cooldown[src] and t < cooldown[src] then return true end
    cooldown[src] = t + Config.ActionCooldown
    return false
end

local function genId()
    return ('b%d%04d'):format(os.time(), math.random(0, 9999))
end

local function playNext(b)
    b.errorAt = nil
    b.queue = b.queue or {}
    local track = table.remove(b.queue, 1)
    if not track then
        b.status = 'idle'
        b.currentTrack = nil
        b.startEpochMs = nil
        return
    end
    b.currentTrack = {
        sourceType = track.sourceType,
        url = track.url,
        title = track.title,
        duration = track.duration, -- may be nil until a client reports it
    }
    b.status = 'playing'
    b.startEpochMs = nowMs()
    b.pauseOffsetMs = 0
end

local function advance(b)
    playNext(b)
    broadcastBooth(b)
    -- the queue changed (next track popped) -> refresh "up next" / queue manager for everyone
    TriggerClientEvent('moedj:dj:queue', -1, b.id, b.queue or {})
    saveQueues()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function printBanner()
    local b = Config.Brand
    local version = GetResourceMetadata(RES, 'version', 0) or '?'
    local count = 0
    for _ in pairs(booths) do count = count + 1 end
    print('^5')
    print('  ███╗   ███╗ ██████╗ ███████╗    ██████╗      ██╗')
    print('  ████╗ ████║██╔═══██╗██╔════╝    ██╔══██╗     ██║')
    print('  ██╔████╔██║██║   ██║█████╗      ██║  ██║     ██║')
    print('  ██║╚██╔╝██║██║   ██║██╔══╝      ██║  ██║██   ██║')
    print('  ██║ ╚═╝ ██║╚██████╔╝███████╗    ██████╔╝╚█████╔╝')
    print('  ╚═╝     ╚═╝ ╚═════╝ ╚══════╝    ╚═════╝  ╚════╝ ^0')
    print(('^7  %s ^0v%s ^7by %s^0'):format(b.name, version, b.author))
    print(('^7  %d booth(s) loaded · core: %s^0'):format(count, CoreName() or 'standalone'))
    if b.discord and not b.discord:find('REPLACE_ME') then print(('^7  Discord: %s^0'):format(b.discord)) end
    if b.store and not b.store:find('REPLACE_ME') then print(('^7  Store:   %s^0'):format(b.store)) end
    print('')
end

AddEventHandler('onResourceStart', function(name)
    if name ~= RES then return end
    math.randomseed(os.time())
    CreateThread(load) -- load() may briefly wait for oxmysql to finish starting
    -- defer so the core-detection thread in permissions.lua resolves first
    CreateThread(function()
        Wait(1500)
        printBanner()
    end)
end)

AddEventHandler('playerDropped', function()
    cooldown[source] = nil
end)

RegisterNetEvent('moedj:requestBooths', function()
    TriggerClientEvent('moedj:syncBooths', source, allPublicBooths())
    sendAccess(source)
end)

-- Lightweight wall-clock sync: client computes its offset from this.
RegisterNetEvent('moedj:timeSync', function(reqId)
    TriggerClientEvent('moedj:timeSyncResult', source, reqId, nowMs())
end)

-- Client periodically refreshes its DJ access map (catches job/grade changes).
RegisterNetEvent('moedj:requestAccess', function()
    sendAccess(source)
end)

--------------------------------------------------------------------------------
-- Title resolution (YouTube oEmbed — server-side, no API key / CORS)
--------------------------------------------------------------------------------

local qDirty, qTimer = {}, {}

local function broadcastQueueSoon(id)
    qDirty[id] = true
    if qTimer[id] then return end
    qTimer[id] = true
    SetTimeout(700, function()
        qTimer[id] = nil
        if qDirty[id] then
            qDirty[id] = nil
            local b = booths[id]
            if b then
                TriggerClientEvent('moedj:dj:queue', -1, id, b.queue or {})
                saveQueues()
            end
        end
    end)
end

local function urlencode(s)
    return (s:gsub('[^%w%-_%.~]', function(c) return ('%%%02X'):format(string.byte(c)) end))
end

local function resolveTitle(b, item)
    if not item or item.sourceType ~= 'youtube' or item.title then return end
    PerformHttpRequest('https://www.youtube.com/oembed?format=json&url=' .. urlencode(item.url), function(status, body)
        if status ~= 200 or not body or body == '' then return end
        local ok, data = pcall(json.decode, body)
        if not ok or type(data) ~= 'table' or type(data.title) ~= 'string' then return end
        item.title = data.title
        if b.currentTrack and b.currentTrack.url == item.url and not b.currentTrack.title then
            b.currentTrack.title = data.title
            broadcastBooth(b)
        end
        broadcastQueueSoon(b.id)
    end, 'GET')
end

-- resolve titles for the current track + every queued item that lacks one (staggered)
local function resolveBoothTitles(b)
    resolveTitle(b, b.currentTrack)
    local delay = 0
    for _, item in ipairs(b.queue or {}) do
        if item.sourceType == 'youtube' and not item.title then
            local it = item
            SetTimeout(delay, function() resolveTitle(b, it) end)
            delay = delay + 120
        end
    end
end

--------------------------------------------------------------------------------
-- DJ actions
--------------------------------------------------------------------------------

local function guardDJ(src, boothId)
    local b = booths[boothId]
    if not b then return nil end
    if not CanDJ(src, b) then
        notify(src, 'You are not allowed to DJ this booth.', 'error')
        return nil
    end
    return b
end

RegisterNetEvent('moedj:dj:requestQueue', function(boothId)
    local src = source
    local b = guardDJ(src, boothId)
    if not b then return end
    TriggerClientEvent('moedj:dj:queue', src, boothId, b.queue or {})
end)

RegisterNetEvent('moedj:dj:queueAddMany', function(boothId, urls)
    local src = source
    local b = guardDJ(src, boothId)
    if not b or type(urls) ~= 'table' then return end

    b.queue = b.queue or {}
    local added, rejected = 0, 0
    for _, url in ipairs(urls) do
        if #b.queue >= Config.MaxQueueLength then break end
        local st = classifyUrl(url)
        if st then
            b.queue[#b.queue + 1] = { sourceType = st, url = url, title = nil, duration = nil }
            added = added + 1
        else
            rejected = rejected + 1
        end
    end

    if added > 0 then
        broadcastBooth(b)
        TriggerClientEvent('moedj:dj:queue', src, boothId, b.queue)
        saveQueues()
        resolveBoothTitles(b)
    end
    if rejected > 0 then notify(src, ('%d link(s) were not a supported source.'):format(rejected), 'error') end
end)

RegisterNetEvent('moedj:dj:queueRemove', function(boothId, index)
    local src = source
    local b = guardDJ(src, boothId)
    if not b or not b.queue or not b.queue[index] then return end
    table.remove(b.queue, index)
    saveQueues()
    TriggerClientEvent('moedj:dj:queue', src, boothId, b.queue or {})
end)

RegisterNetEvent('moedj:dj:queueReorder', function(boothId, from, to)
    local src = source
    local b = guardDJ(src, boothId)
    if not b or not b.queue then return end
    local item = b.queue[from]
    if not item then return end
    table.remove(b.queue, from)
    table.insert(b.queue, math.max(1, math.min(to, #b.queue + 1)), item)
    TriggerClientEvent('moedj:dj:queue', src, boothId, b.queue)
    saveQueues()
end)

RegisterNetEvent('moedj:dj:queueOrder', function(boothId, order)
    local src = source
    local b = guardDJ(src, boothId)
    if not b or not b.queue or type(order) ~= 'table' then return end
    local n = #b.queue
    if #order ~= n then return end
    local seen, newQ = {}, {}
    for _, idx in ipairs(order) do
        idx = tonumber(idx)
        if not idx or idx < 1 or idx > n or seen[idx] then return end -- not a valid permutation
        seen[idx] = true
        newQ[#newQ + 1] = b.queue[idx]
    end
    b.queue = newQ
    TriggerClientEvent('moedj:dj:queue', src, boothId, b.queue)
    saveQueues()
end)

RegisterNetEvent('moedj:dj:control', function(boothId, action)
    local src = source
    if onCooldown(src) then return end
    local b = guardDJ(src, boothId)
    if not b then return end

    if action == 'play' then
        if b.status == 'paused' and b.currentTrack then
            b.startEpochMs = nowMs() - (b.pauseOffsetMs or 0)
            b.status = 'playing'
        elseif b.status ~= 'playing' then
            playNext(b)
        end
    elseif action == 'pause' then
        if b.status == 'playing' then
            b.pauseOffsetMs = nowMs() - (b.startEpochMs or nowMs())
            b.status = 'paused'
        end
    elseif action == 'skip' then
        advance(b)
        return
    elseif action == 'stop' then
        b.status = 'idle'
        b.currentTrack = nil
        b.startEpochMs = nil
        b.pauseOffsetMs = 0
    end

    broadcastBooth(b)
    TriggerClientEvent('moedj:dj:queue', -1, b.id, b.queue or {})
    saveQueues()
end)

RegisterNetEvent('moedj:dj:setVolume', function(boothId, vol)
    local src = source
    local b = guardDJ(src, boothId)
    if not b then return end
    b.baseVolume = math.max(0.0, math.min(1.0, tonumber(vol) or 0.8))
    broadcastBooth(b)
    saveBooth(boothId)
end)

RegisterNetEvent('moedj:dj:reportMeta', function(boothId, url, title, duration)
    local b = booths[boothId]
    if not b or not b.currentTrack or b.currentTrack.url ~= url then return end

    b.errorAt = nil
    local changed = false

    if type(title) == 'string' and title ~= '' and not b.currentTrack.title then
        b.currentTrack.title = title
        changed = true
    end

    duration = tonumber(duration)
    if duration and duration > 0 and not b.currentTrack.duration then
        b.currentTrack.duration = duration
        changed = true
    end

    if changed then broadcastBooth(b) end
end)

RegisterNetEvent('moedj:dj:reportError', function(boothId, url)
    local b = booths[boothId]
    if not b or not b.currentTrack or b.currentTrack.url ~= url then return end
    if b.currentTrack.duration then return end -- already known good somewhere
    if not b.errorAt then b.errorAt = nowMs() end
end)

--------------------------------------------------------------------------------
-- Admin / manager
--------------------------------------------------------------------------------

-- the {label, model} list the manager dropdown offers (surfaces stay client-side)
local function propModelList()
    local out = {}
    for _, m in ipairs((Config.Dui and Config.Dui.models) or {}) do
        out[#out + 1] = { label = m.label or m.model, model = m.model }
    end
    return out
end

RegisterNetEvent('moedj:admin:open', function()
    local src = source
    if not CanAdmin(src) then
        notify(src, 'You do not have permission to manage booths.', 'error')
        return
    end
    TriggerClientEvent('moedj:admin:opened', src, {
        booths = allAdminBooths(),
        hasCore = HasCore(),
        coreName = CoreName(),
        defaultJob = Config.DefaultJob,
        defaultGrades = Config.DefaultGrades,
        defaultRange = Config.DefaultRange,
        maxSpeakers = Config.MaxSpeakers,
        propModels = propModelList(),
        brand = Config.Brand,
    })
end)

local function sanitizeLock(data)
    if not HasCore() then return '', {} end
    local job = type(data.job) == 'string' and data.job or ''
    local grades = {}
    if job ~= '' and type(data.grades) == 'table' then
        for _, g in ipairs(data.grades) do
            local n = tonumber(g)
            if n then grades[#grades + 1] = math.floor(n) end
        end
    end
    return job, grades
end

-- accept only a configured model name; fall back to the first configured model
local function validPropModel(name)
    local list = (Config.Dui and Config.Dui.models) or {}
    for _, m in ipairs(list) do if m.model == name then return name end end
    return list[1] and list[1].model
end

local function sanitizeProp(p)
    if type(p) ~= 'table' or not p.x or not p.y or not p.z then return nil end
    return {
        x = p.x + 0.0, y = p.y + 0.0, z = p.z + 0.0,
        heading = (tonumber(p.heading) or 0.0) + 0.0,
        model = validPropModel(p.model),
    }
end

-- Validate speakers; each carries its own range (m) and volume multiplier (0..1).
local function sanitizeSpeakers(arr)
    local out = {}
    if type(arr) ~= 'table' then return out end
    for _, s in ipairs(arr) do
        if #out < Config.MaxSpeakers and type(s) == 'table' and s.x and s.y and s.z then
            out[#out + 1] = {
                x = s.x + 0.0, y = s.y + 0.0, z = s.z + 0.0,
                range = math.max(1.0, math.min(200.0, tonumber(s.range) or Config.DefaultRange)),
                volume = math.max(0.0, math.min(1.0, tonumber(s.volume) or 1.0)),
            }
        end
    end
    return out
end

local function deriveAnchor(prop)
    if not prop then return nil end
    return { x = prop.x, y = prop.y, z = prop.z, heading = prop.heading or 0.0 }
end

local function propTooClose(prop, excludeId)
    if not prop then return false end
    local min = (Config.Dui and Config.Dui.minSpacing) or 8.0
    local min2 = min * min
    for id, b in pairs(booths) do
        if id ~= excludeId and b.prop then
            local dx, dy, dz = b.prop.x - prop.x, b.prop.y - prop.y, b.prop.z - prop.z
            if (dx * dx + dy * dy + dz * dz) < min2 then return true end
        end
    end
    return false
end

local function spacingError(src)
    local min = math.floor((Config.Dui and Config.Dui.minSpacing) or 8)
    notify(src, ('Too close to another jukebox — keep them at least %dm apart.'):format(min), 'error')
end

local function propMoved(a, b)
    if not a and not b then return false end
    if not a or not b then return true end
    return a.x ~= b.x or a.y ~= b.y or a.z ~= b.z
end

RegisterNetEvent('moedj:admin:create', function(data)
    local src = source
    if not CanAdmin(src) then return end
    if type(data) ~= 'table' then return end

    local speakers = sanitizeSpeakers(data.speakers)
    local prop = sanitizeProp(data.prop)
    if not prop then notify(src, 'Place a jukebox prop first.', 'error'); return end
    if #speakers == 0 then notify(src, 'Add at least one speaker.', 'error'); return end
    if propTooClose(prop, nil) then spacingError(src); return end
    local anchor = deriveAnchor(prop)

    local job, grades = sanitizeLock(data)
    local id = genId()
    booths[id] = {
        id = id,
        name = (type(data.name) == 'string' and data.name ~= '') and data.name or ('Booth ' .. id),
        controlPoint = anchor,
        prop = prop,
        speakers = speakers,
        range = tonumber(data.range) or Config.DefaultRange,
        falloff = data.falloff or Config.DefaultFalloff,
        job = job,
        grades = grades,
        blip = data.blip ~= false,
        baseVolume = 0.8,
        status = 'idle',
        queue = {},
        currentTrack = nil,
        pauseOffsetMs = 0,
    }
    broadcastBooth(booths[id])
    saveBooth(id)
    broadcastAccess() -- new booth must appear in everyone's access map
    notify(src, ('Booth "%s" created.'):format(booths[id].name), 'success')
    TriggerClientEvent('moedj:admin:refresh', src, allAdminBooths())
end)

RegisterNetEvent('moedj:admin:update', function(id, data)
    local src = source
    if not CanAdmin(src) then return end
    local b = booths[id]
    if not b or type(data) ~= 'table' then return end

    local newProp = b.prop
    if data.prop ~= nil then newProp = sanitizeProp(data.prop ~= false and data.prop or nil) end
    if not newProp then notify(src, 'A booth needs a jukebox prop.', 'error'); return end
    if propMoved(newProp, b.prop) and propTooClose(newProp, id) then spacingError(src); return end

    if type(data.name) == 'string' and data.name ~= '' then b.name = data.name end
    b.prop = newProp
    if type(data.speakers) == 'table' then
        b.speakers = sanitizeSpeakers(data.speakers)
    end
    b.controlPoint = deriveAnchor(b.prop)
    if data.range ~= nil then b.range = tonumber(data.range) or b.range end
    if data.falloff ~= nil then b.falloff = data.falloff end
    if data.blip ~= nil then b.blip = data.blip ~= false end
    if data.job ~= nil or data.grades ~= nil then
        b.job, b.grades = sanitizeLock(data)
    end

    broadcastBooth(b)
    saveBooth(id)
    broadcastAccess() -- job/grade lock may have changed
    notify(src, ('Booth "%s" updated.'):format(b.name), 'success')
    TriggerClientEvent('moedj:admin:refresh', src, allAdminBooths())
end)

RegisterNetEvent('moedj:admin:delete', function(id)
    local src = source
    if not CanAdmin(src) then return end
    if not booths[id] then return end
    booths[id] = nil
    broadcastRemoval(id)
    deleteBoothRow(id)
    saveQueues()
    broadcastAccess()
    notify(src, 'Booth deleted.', 'success')
    TriggerClientEvent('moedj:admin:refresh', src, allAdminBooths())
end)

RegisterNetEvent('moedj:admin:forceStop', function(id)
    local src = source
    if not CanAdmin(src) then return end
    local b = booths[id]
    if not b then return end
    b.status = 'idle'
    b.currentTrack = nil
    b.startEpochMs = nil
    b.pauseOffsetMs = 0
    b.errorAt = nil
    broadcastBooth(b)
    saveQueues() -- the now-playing track was cleared
    notify(src, ('Stopped playback on "%s".'):format(b.name), 'success')
    TriggerClientEvent('moedj:admin:refresh', src, allAdminBooths())
end)

--------------------------------------------------------------------------------
-- Admin-only client tools: validate ACE here (server), then run on the client.
-- (IsPlayerAceAllowed is server-only, so the gate can't live client-side.)
--------------------------------------------------------------------------------

RegisterCommand('djscreen', function(source)
    if source ~= 0 and CanAdmin(source) then TriggerClientEvent('moedj:run:djscreen', source) end
end, false)

RegisterCommand('djdui', function(source)
    if source ~= 0 and CanAdmin(source) then TriggerClientEvent('moedj:run:djdui', source) end
end, false)

--------------------------------------------------------------------------------
-- Auto-advance loop: when a playing track passes its known duration, advance.
--------------------------------------------------------------------------------

CreateThread(function()
    while true do
        Wait(1000)
        for _, b in pairs(booths) do
            if b.status == 'playing' and b.currentTrack then
                if b.currentTrack.duration and b.startEpochMs then
                    local elapsed = (nowMs() - b.startEpochMs) / 1000
                    if elapsed >= (b.currentTrack.duration + 1) then
                        advance(b)
                    end
                -- dead embed: nobody loaded it and the grace window elapsed
                elseif b.errorAt and (nowMs() - b.errorAt) >= Config.EmbedErrorGrace then
                    advance(b)
                end
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- Exports for other resources (signs, blips, add-ons)
--------------------------------------------------------------------------------

exports('GetBooths', function()
    return allPublicBooths()
end)

exports('GetBoothState', function(id)
    local b = booths[id]
    return b and publicBooth(b) or nil
end)
