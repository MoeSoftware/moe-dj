--[[
    Moe DJ — client. Mirrors booth state from the server and runs the proximity
    loop that drives per-booth volume (via the NUI audio bridge), plus finder blips
    and the DJ access map. Jukebox screen -> dui.lua; manager UI -> app.js.
]]

-- id -> public booth table (geometry + current playback state)
Booths = {}

local loadedState = {}   -- id -> { url, status } currently loaded in NUI
local mayDJ = {}         -- id -> bool, server-pushed DJ access map
local toastShown = {}    -- id -> true while a listener is inside an audible booth

local function dbg(...)
    if Config.Debug then print('[moe-dj]', ...) end
end

local function notifyLocal(msg)
    SetNotificationTextEntry('STRING')
    AddTextComponentSubstringPlayerName(('[Moe DJ] %s'):format(msg))
    DrawNotification(false, false)
end

--------------------------------------------------------------------------------
-- Wall-clock sync (estimate server time in local GetGameTimer space)
--------------------------------------------------------------------------------

local timeOffset = 0
local pendingTime = {}

local function serverNow()
    return GetGameTimer() + timeOffset
end

local function requestTimeSync()
    local reqId = math.random(1, 2000000000)
    pendingTime[reqId] = GetGameTimer()
    TriggerServerEvent('moedj:timeSync', reqId)
end

-- fire several samples back-to-back (used at startup to lock on quickly)
local function syncBurst(n)
    CreateThread(function()
        for _ = 1, (n or 5) do
            requestTimeSync()
            Wait(120)
        end
    end)
end

RegisterNetEvent('moedj:timeSyncResult', function(reqId, serverMs)
    local sent = pendingTime[reqId]
    if not sent then return end
    pendingTime[reqId] = nil
    local rtt = GetGameTimer() - sent
    if rtt > 800 then return end -- drop a hitched sample; a cleaner one follows next cycle
    timeOffset = (serverMs + rtt / 2) - GetGameTimer()
end)

--------------------------------------------------------------------------------
-- NUI audio bridge
--------------------------------------------------------------------------------

local function Audio(sub, data)
    data = data or {}
    data.action = 'audio'
    data.sub = sub
    SendNUIMessage(data)
end

local function boothElapsed(b)
    if b.status == 'playing' and b.startEpochMs then
        return (serverNow() - b.startEpochMs) / 1000.0
    elseif b.status == 'paused' then
        return (b.pauseOffsetMs or 0) / 1000.0
    end
    return 0.0
end

-- exposed for client/dui.lua so the jukebox screen shows synced progress
function MoeDJElapsedMs(id)
    local b = Booths[id]
    return b and math.floor(boothElapsed(b) * 1000) or 0
end

-- widest speaker range, cached on the booth so the proximity loop's coarse
-- pre-check doesn't re-scan every speaker each cycle
local function boothMaxRange(b)
    local maxR = b.range or Config.DefaultRange
    for _, s in ipairs(b.speakers or {}) do
        local r = s.range or b.range or Config.DefaultRange
        if r > maxR then maxR = r end
    end
    return maxR
end

--------------------------------------------------------------------------------
-- Booth state sync
--------------------------------------------------------------------------------

RegisterNetEvent('moedj:syncBooths', function(list)
    Booths = {}
    for _, b in ipairs(list) do
        b.maxRange = boothMaxRange(b)
        Booths[b.id] = b
    end
    RefreshBlips()
end)

RegisterNetEvent('moedj:boothState', function(b)
    b.maxRange = boothMaxRange(b)
    Booths[b.id] = b
    RefreshBlips()
end)

RegisterNetEvent('moedj:boothRemoved', function(id)
    Booths[id] = nil
    if loadedState[id] then
        Audio('unload', { booth = id })
        loadedState[id] = nil
    end
    RefreshBlips()
end)

RegisterNetEvent('moedj:access', function(map)
    mayDJ = map or {}
end)

-- exposed for client/dui.lua (jukebox focus access check)
function MoeDJMayDJ(id) return mayDJ[id] == true end

RegisterNetEvent('moedj:notify', function(msg, kind)
    notifyLocal(msg)
    dbg(kind, msg)
end)

--------------------------------------------------------------------------------
-- Audio reporting (from html/audio.js, which runs in the always-loaded NUI page)
--------------------------------------------------------------------------------

RegisterNUICallback('reportMeta', function(data, cb)
    TriggerServerEvent('moedj:dj:reportMeta', data.boothId, data.url, data.title, data.duration)
    cb('ok')
end)

RegisterNUICallback('reportError', function(data, cb)
    TriggerServerEvent('moedj:dj:reportError', data.boothId, data.url)
    cb('ok')
end)

--------------------------------------------------------------------------------
-- Proximity / audio reconciliation loop
--------------------------------------------------------------------------------

local function byVolumeDesc(a, b) return a.vol > b.vol end

CreateThread(function()
    Wait(500)
    syncBurst(6)
    Wait(400)  -- let the first offset samples land before any audio is seeked
    TriggerServerEvent('moedj:requestBooths')

    while true do
        local sleep = Config.IdleInterval
        local pc = GetEntityCoords(PlayerPedId())

        -- For each booth, the effective volume is the LOUDEST speaker as heard from
        -- here: each speaker has its own range + volume multiplier.
        local candidates = {}
        for id, b in pairs(Booths) do
            local cp = b.controlPoint
            local maxR = b.maxRange or b.range or Config.DefaultRange
            local coarse = #(pc - vector3(cp.x, cp.y, cp.z))
            if coarse <= (Config.CoarsePrecheckRange + maxR) then
                sleep = Config.ProximityInterval
                local best = 0.0
                for _, s in ipairs(b.speakers or {}) do
                    local r = s.range or b.range or Config.DefaultRange
                    local d = #(pc - vector3(s.x, s.y, s.z))
                    if d <= r then
                        local frac = 1.0 - (d / r)
                        if frac < 0 then frac = 0 end
                        if b.falloff == 'quadratic' then frac = frac * frac end
                        local v = frac * (s.volume or 1.0)
                        if v > best then best = v end
                    end
                end
                candidates[#candidates + 1] = { id = id, b = b, vol = best }
            end
        end

        -- loudest active booths win the limited audio slots
        table.sort(candidates, byVolumeDesc)
        local shouldLoad = {}
        local active = 0
        for _, c in ipairs(candidates) do
            local b = c.b
            local isActive = (b.status == 'playing' or b.status == 'paused') and b.currentTrack ~= nil
            if isActive and c.vol > 0 and active < Config.MaxConcurrentBooths then
                active = active + 1
                shouldLoad[c.id] = c.vol * (b.baseVolume or 0.8)
            end
        end

        for id in pairs(loadedState) do
            if not shouldLoad[id] then
                Audio('unload', { booth = id })
                loadedState[id] = nil
            end
        end

        for id, vol in pairs(shouldLoad) do
            local b = Booths[id]
            local ls = loadedState[id]
            if not ls or ls.url ~= b.currentTrack.url then
                Audio('load', {
                    booth = id,
                    sourceType = b.currentTrack.sourceType,
                    url = b.currentTrack.url,
                    seek = boothElapsed(b),
                    volume = vol,
                    paused = (b.status == 'paused'),
                })
                loadedState[id] = { url = b.currentTrack.url, status = b.status }
            else
                Audio('volume', { booth = id, volume = vol })
                if ls.status ~= b.status then
                    if b.status == 'paused' then
                        Audio('pause', { booth = id })
                    else
                        Audio('resume', { booth = id, seek = boothElapsed(b) })
                    end
                    ls.status = b.status
                end
            end
        end

        if Config.ListenerToast then
            for id in pairs(shouldLoad) do
                if not toastShown[id] then
                    toastShown[id] = true
                    local b = Booths[id]
                    if b.status == 'playing' then
                        local what = b.currentTrack and b.currentTrack.title
                        notifyLocal(('♪ Now playing at %s%s'):format(b.name, what and (': ' .. what) or ''))
                    end
                end
            end
            for id in pairs(toastShown) do
                if not shouldLoad[id] then toastShown[id] = nil end
            end
        end

        Wait(sleep)
    end
end)

-- Clock-offset refresh + drift correction.
--   Near an audible booth: re-measure the offset and nudge each booth every cycle
--     (a stale offset feeds a wrong target into the drift check and playback wanders).
--   Otherwise: just a cheap "keep-warm" ping every ~5s so the offset is already
--     fresh when the player walks into range — no per-cycle traffic for the bulk of
--     players who aren't standing at a booth.
CreateThread(function()
    local idleEvery = math.max(1, math.floor(5000 / Config.ResyncInterval))
    local tick = 0
    while true do
        Wait(Config.ResyncInterval)
        tick = tick + 1
        if next(loadedState) ~= nil then
            requestTimeSync()
            for id, ls in pairs(loadedState) do
                local b = Booths[id]
                if b and b.status == 'playing' then
                    Audio('sync', { booth = id, target = boothElapsed(b), threshold = Config.DriftThreshold })
                end
            end
        elseif tick % idleEvery == 0 then
            requestTimeSync()
        end
    end
end)

CreateThread(function()
    while true do
        Wait(Config.AccessRefreshInterval)
        TriggerServerEvent('moedj:requestAccess')
    end
end)

--------------------------------------------------------------------------------
-- Booth finder blips (recolor + "(LIVE)" while playing, if enabled)
--------------------------------------------------------------------------------

local blips = {}

function RefreshBlips()
    for id, blip in pairs(blips) do
        if not Booths[id] or Booths[id].blip == false then
            RemoveBlip(blip)
            blips[id] = nil
        end
    end
    for id, b in pairs(Booths) do
        if b.blip ~= false then
            if not blips[id] then
                local cp = b.controlPoint
                local blip = AddBlipForCoord(cp.x, cp.y, cp.z)
                SetBlipSprite(blip, 136)
                SetBlipScale(blip, 0.8)
                SetBlipAsShortRange(blip, true)
                blips[id] = blip
            end
            local blip = blips[id]
            local live = Config.LiveBlip and b.status == 'playing'
            SetBlipColour(blip, live and 5 or 27) -- 5 = yellow (live), 27 = teal
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(live and ('(LIVE) ' .. b.name) or b.name)
            EndTextCommandSetBlipName(blip)
        end
    end
end

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    SetNuiFocus(false, false)
    for _, blip in pairs(blips) do RemoveBlip(blip) end
end)
