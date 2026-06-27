--[[
    Moe DJ — jukebox prop + DUI screen. Each booth has one jukebox prop (a model
    chosen from Config.Dui.models). This file spawns that prop as a local object,
    renders html/screen.html to a DUI texture, and draws it as a flat quad sized to
    the model's `surface`. The prop is also the DJ interaction point. Display-only —
    audio still comes from the proximity speakers.
]]

local D = Config.Dui
local models = (D and D.models) or {}
local TXD, TEX = 'moedj_screen_txd', 'moedj_screen_tex'

local dui = nil
local ready = false
local props = {} -- boothId -> { ent, x, y, z, h, model, interior }
local Target = nil   -- 'ox' | 'qb' target resource (if Config.UseTarget and present)
local enterFocus     -- forward-declared; defined in the focus section below

-- the screen surface for a given prop model (falls back to the first model)
local function modelSurface(name)
    for _, m in ipairs(models) do
        if m.model == name then return m.surface end
    end
    return models[1] and models[1].surface
end

local function boothSurface(boothId)
    local b = Booths[boothId]
    return b and b.prop and modelSurface(b.prop.model)
end

-- per-model E/target interaction radius (defaults to Config.InteractDistance); lets
-- a bulky prop reach further than a small one since distance is measured to the origin
local function modelInteract(name)
    for _, m in ipairs(models) do
        if m.model == name then return m.interactDistance or Config.InteractDistance end
    end
    return Config.InteractDistance
end

local function addPropTarget(boothId, ent)
    if not Target or not ent or not DoesEntityExist(ent) then return end
    local label = Config.TargetLabel or 'Use jukebox'
    local icon = Config.TargetIcon or 'fa-solid fa-music'
    local p = props[boothId]
    local dist = (p and modelInteract(p.model)) or Config.InteractDistance or 2.0
    if Target == 'ox' then
        exports.ox_target:addLocalEntity(ent, { {
            name = 'moedj_use', label = label, icon = icon, distance = dist,
            canInteract = function() return MoeDJMayDJ and MoeDJMayDJ(boothId) end,
            onSelect = function() enterFocus(boothId) end,
        } })
    else
        exports['qb-target']:AddTargetEntity(ent, {
            options = { {
                label = label, icon = icon,
                canInteract = function() return MoeDJMayDJ and MoeDJMayDJ(boothId) end,
                action = function() enterFocus(boothId) end,
            } },
            distance = dist,
        })
    end
end

local function removePropTarget(ent)
    if not Target or not ent then return end
    if Target == 'ox' then
        exports.ox_target:removeLocalEntity(ent)
    else
        exports['qb-target']:RemoveTargetEntity(ent)
    end
end

local function dbg(...)
    if Config.Debug then print('[moe-dj:dui]', ...) end
end

local function payloadFor(b)
    if not b then return { idle = true } end
    return {
        id = b.id, name = b.name, status = b.status, track = b.currentTrack,
        -- current position in ms on this client's synced clock; the screen ticks
        -- forward locally from here. (startEpochMs is a server-monotonic timer with
        -- no meaning inside the DUI's own wall-clock, so we resolve it here.)
        posMs = (MoeDJElapsedMs and MoeDJElapsedMs(b.id)) or 0,
        baseVolume = b.baseVolume,
    }
end

local function nearestProp(maxDist)
    local pc = GetEntityCoords(PlayerPedId())
    local bestId, bestD
    for id, p in pairs(props) do
        if Booths[id] and p.ent and DoesEntityExist(p.ent) then
            local d = #(pc - vector3(p.x, p.y, p.z))
            if d <= maxDist and (not bestD or d < bestD) then bestD = d; bestId = id end
        end
    end
    return bestId
end

-- like nearestProp, but each prop uses its own model interaction radius
local function nearestInteractable()
    local pc = GetEntityCoords(PlayerPedId())
    local bestId, bestD
    for id, p in pairs(props) do
        if Booths[id] and p.ent and DoesEntityExist(p.ent) then
            local d = #(pc - vector3(p.x, p.y, p.z))
            if d <= modelInteract(p.model) and (not bestD or d < bestD) then bestD = d; bestId = id end
        end
    end
    return bestId
end

--------------------------------------------------------------------------------
-- Prop spawning
--------------------------------------------------------------------------------

local function spawnProp(id, pr)
    local modelName = pr.model or (models[1] and models[1].model)
    local hash = GetHashKey(modelName)
    if not IsModelValid(hash) then
        print(('^1[moe-dj] jukebox model is not valid: %s^0'):format(tostring(modelName)))
        return
    end
    RequestModel(hash)
    local t = 0
    while not HasModelLoaded(hash) and t < 300 do Wait(10); t = t + 1 end
    if not HasModelLoaded(hash) then
        print(('^1[moe-dj] jukebox model failed to load: %s^0'):format(tostring(modelName)))
        return
    end
    -- spawn a touch high, then drop onto the ground so the model's origin offset
    -- doesn't bury it (some prop origins are not at their base)
    local ent = CreateObjectNoOffset(hash, pr.x + 0.0, pr.y + 0.0, pr.z + 1.0, false, false, false)
    SetEntityHeading(ent, (pr.heading or 0.0) + 0.0)
    PlaceObjectOnGroundProperly(ent)
    FreezeEntityPosition(ent, true)
    SetEntityCollision(ent, true, true)
    SetEntityVisible(ent, true, false)
    SetEntityAsMissionEntity(ent, true, true)
    SetModelAsNoLongerNeeded(hash)

    local c = GetEntityCoords(ent)
    -- if the prop sits inside an MLO, note the interior so we can bind it to the
    -- room (otherwise the interior culls it: collision works but it's invisible)
    local interior = GetInteriorAtCoords(c.x, c.y, c.z)
    if interior ~= 0 then LoadInterior(interior) end
    props[id] = {
        ent = ent, x = pr.x, y = pr.y, z = pr.z, h = pr.heading or 0.0,
        model = modelName, interior = (interior ~= 0) and interior or nil,
    }
    addPropTarget(id, ent)
    dbg(('spawned booth %s prop (%s)'):format(id, modelName))
end

local function despawn(id)
    local p = props[id]
    if p and p.ent and DoesEntityExist(p.ent) then
        removePropTarget(p.ent)
        DeleteEntity(p.ent)
    end
    props[id] = nil
end

-- detect a target resource; if it appears after some props already spawned, add to them
CreateThread(function()
    if not Config.UseTarget then return end
    for _ = 1, 20 do
        if GetResourceState('ox_target') == 'started' then Target = 'ox'; break end
        if GetResourceState('qb-target') == 'started' then Target = 'qb'; break end
        Wait(500)
    end
    if Target then
        for id, p in pairs(props) do
            if p.ent and DoesEntityExist(p.ent) then addPropTarget(id, p.ent) end
        end
        dbg('using target:', Target)
    end
end)

-- Bind interior props to a room so the MLO doesn't cull them (collision works but
-- the model is invisible otherwise). While you're inside any interior and near a
-- prop, keep forcing it into your room (which is the prop's room when you're close).
CreateThread(function()
    while true do
        local sleep = 1000
        local ped = PlayerPedId()
        local pInt = GetInteriorFromEntity(ped)
        if pInt ~= 0 then
            local pc = GetEntityCoords(ped)
            local roomKey = GetRoomKeyFromEntity(ped)
            for _, p in pairs(props) do
                if p.ent and DoesEntityExist(p.ent) and #(pc - vector3(p.x, p.y, p.z)) < 15.0 then
                    ForceRoomForEntity(p.ent, pInt, roomKey)
                    sleep = 300 -- re-assert often while we're near it
                end
            end
        end
        Wait(sleep)
    end
end)

local function syncProps()
    local pc = GetEntityCoords(PlayerPedId())

    for id, p in pairs(props) do
        local b = Booths[id]
        if not b or not b.prop then
            despawn(id)
        elseif b.prop.x ~= p.x or b.prop.y ~= p.y or b.prop.z ~= p.z
            or (b.prop.heading or 0.0) ~= p.h or b.prop.model ~= p.model then
            despawn(id) -- moved or model changed -> respawn below
        end
    end

    for id, b in pairs(Booths) do
        if b.prop and not props[id] then
            if #(pc - vector3(b.prop.x, b.prop.y, b.prop.z)) <= D.propDistance then spawnProp(id, b.prop) end
        elseif b.prop and props[id] then
            if #(pc - vector3(b.prop.x, b.prop.y, b.prop.z)) > D.propDistance + 15.0 then despawn(id) end -- hysteresis
        end
    end
end

--------------------------------------------------------------------------------
-- Screen quad (sized to the prop model's surface)
--------------------------------------------------------------------------------

-- rotate a corner offset around the surface center by the surface's tilt angles
local function rotOffset(dx, dy, dz, rx, ry, rz)
    if rx ~= 0.0 then local c, s = math.cos(rx), math.sin(rx); dy, dz = dy * c - dz * s, dy * s + dz * c end
    if ry ~= 0.0 then local c, s = math.cos(ry), math.sin(ry); dx, dz = dx * c + dz * s, -dx * s + dz * c end
    if rz ~= 0.0 then local c, s = math.cos(rz), math.sin(rz); dx, dy = dx * c - dy * s, dx * s + dy * c end
    return dx, dy, dz
end

local function drawScreen(ent, s)
    local hw, hh = s.w / 2.0, s.h / 2.0
    local rx, ry, rz = math.rad(s.rx or 0.0), math.rad(s.ry or 0.0), math.rad(s.rz or 0.0)
    local function corner(dx, dz)
        local ox, oy, oz = rotOffset(dx, 0.0, dz, rx, ry, rz)
        return GetOffsetFromEntityInWorldCoords(ent, s.x + ox, s.y + oy, s.z + oz)
    end
    local tl, tr = corner(-hw, hh), corner(hw, hh)
    local bl, br = corner(-hw, -hh), corner(hw, -hh)

    DrawSpritePoly(tl.x, tl.y, tl.z, tr.x, tr.y, tr.z, bl.x, bl.y, bl.z,
        255, 255, 255, 255, TXD, TEX, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0, 0.0, 1.0, 1.0)
    DrawSpritePoly(tr.x, tr.y, tr.z, br.x, br.y, br.z, bl.x, bl.y, bl.z,
        255, 255, 255, 255, TXD, TEX, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0, 1.0, 1.0)
    -- reversed winding so it is visible from either side
    DrawSpritePoly(tl.x, tl.y, tl.z, bl.x, bl.y, bl.z, tr.x, tr.y, tr.z,
        255, 255, 255, 255, TXD, TEX, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 1.0, 0.0, 1.0)
    DrawSpritePoly(tr.x, tr.y, tr.z, bl.x, bl.y, bl.z, br.x, br.y, br.z,
        255, 255, 255, 255, TXD, TEX, 1.0, 0.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

CreateThread(function()
    if not D then return end
    dui = CreateDui(('nui://%s/html/screen.html'):format(GetCurrentResourceName()), D.width, D.height)
    local txd = CreateRuntimeTxd(TXD)
    CreateRuntimeTextureFromDuiHandle(txd, TEX, GetDuiHandle(dui))
    local g = 0
    while not IsDuiAvailable(dui) and g < 200 do Wait(50); g = g + 1 end
    ready = true
    dbg('DUI ready')
end)

CreateThread(function()
    if not D then return end
    while true do
        Wait(D.updateInterval)
        syncProps()
        if dui then
            local id = nearestProp(D.drawDistance)
            SendDuiMessage(dui, json.encode({ action = 'screen', booth = payloadFor(id and Booths[id] or nil) }))
        end
    end
end)

-- Draw the quad every frame while near a prop, but only re-scan for the nearest
-- prop a few times a second (the scan walks every prop + a coord lookup).
CreateThread(function()
    if not D then return end
    local drawId, nextScan = nil, 0
    while true do
        local now = GetGameTimer()
        if ready and now >= nextScan then
            drawId = nearestProp(D.drawDistance)
            nextScan = now + 250
        end
        local p = drawId and props[drawId]
        local s = drawId and boothSurface(drawId)
        if p and s and DoesEntityExist(p.ent) then
            drawScreen(p.ent, s)
            Wait(0)
        else
            drawId = nil
            Wait(150)
        end
    end
end)

--------------------------------------------------------------------------------
-- Interactive focus: walk up to the jukebox, press E, drive the panel on-screen.
-- A fixed camera looks at the screen; the mouse moves an on-screen cursor that
-- the DUI page uses to hover/click its own buttons. Links use GTA's keyboard.
--------------------------------------------------------------------------------

local focused = false
local focusBooth, focusEnt = nil, nil
local cam = nil
local cur = { u = 0.5, v = 0.5 }
local overlayOpen = false -- a NUI overlay (paste box / queue manager) is up
local aligning = false    -- /djscreen is open (suppresses the keybind prompt)

local function sendDui(tbl) if dui then SendDuiMessage(dui, json.encode(tbl)) end end

enterFocus = function(id)
    local p = props[id]
    local s = boothSurface(id)
    if not p or not s or not DoesEntityExist(p.ent) then return end
    focused = true
    focusBooth = id
    focusEnt = p.ent
    cur.u, cur.v = 0.5, 0.5

    local ent = focusEnt
    local center = GetOffsetFromEntityInWorldCoords(ent, s.x, s.y, s.z)
    -- The readable face is the screen's local -forward; tilt that normal by the
    -- surface rotation so the camera sits square to the (possibly tilted) screen.
    local rx, ry, rz = math.rad(s.rx or 0.0), math.rad(s.ry or 0.0), math.rad(s.rz or 0.0)
    local nx, ny, nz = rotOffset(0.0, -1.0, 0.0, rx, ry, rz)
    local normal = GetOffsetFromEntityInWorldCoords(ent, s.x + nx, s.y + ny, s.z + nz) - center
    local nlen = #normal
    if nlen > 0.0 then normal = normal / nlen end
    local dist = (s.w * 0.5) / math.tan(math.rad(D.camFov) * 0.5) * 1.15
    if dist < 0.2 then dist = D.camDistance end
    local camPos = center + normal * dist
    cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', camPos.x, camPos.y, camPos.z, 0.0, 0.0, 0.0, D.camFov, true, 0)
    PointCamAtCoord(cam, center.x, center.y, center.z)
    SetCamActive(cam, true)
    RenderScriptCams(true, true, 350, true, false)

    sendDui({ action = 'mode', mode = 'panel', boothId = id })
    TriggerServerEvent('moedj:dj:requestQueue', id)
end

function ExitJukeboxFocus()
    if not focused then return end
    focused = false
    sendDui({ action = 'mode', mode = 'display' })
    RenderScriptCams(false, true, 350, true, false)
    if cam then DestroyCam(cam, false); cam = nil end
    focusBooth, focusEnt = nil, nil
end

-- While focused, hide your own ped and any other players clustered at the screen
-- so nobody blocks the panel. Purely local (SetEntityLocallyInvisible) — everyone
-- still sees each other normally, and it self-restores the frame you exit focus.
CreateThread(function()
    while true do
        if focused then
            local me = PlayerPedId()
            SetEntityLocallyInvisible(me)
            if focusEnt and DoesEntityExist(focusEnt) then
                local sc = GetEntityCoords(focusEnt)
                for _, pl in ipairs(GetActivePlayers()) do
                    local ped = GetPlayerPed(pl)
                    if ped ~= me and DoesEntityExist(ped)
                        and #(GetEntityCoords(ped) - sc) < 4.0 then
                        SetEntityLocallyInvisible(ped)
                    end
                end
            end
            Wait(0)
        else
            Wait(300)
        end
    end
end)

-- keybind prompt + enter (only used when no target resource is active)
CreateThread(function()
    if not D then return end
    while true do
        local sleep = 500
        if not Target and not focused and not Placing and not aligning then
            local id = nearestInteractable()
            if id and MoeDJMayDJ and MoeDJMayDJ(id) then
                sleep = 0
                BeginTextCommandDisplayHelp('STRING')
                AddTextComponentSubstringPlayerName('Press ~INPUT_CONTEXT~ to use the jukebox')
                EndTextCommandDisplayHelp(0, false, false, -1) -- no beep
                if IsControlJustReleased(0, Config.InteractKey) then enterFocus(id) end
            end
        end
        Wait(sleep)
    end
end)

CreateThread(function()
    if not D then return end
    while true do
        if focused and not overlayOpen then
            Wait(0)
            DisableAllControlActions(0)
            -- look input is already scaled by the player's in-game mouse sensitivity;
            -- normalize to a 60fps reference so the cursor feels the same at any frame rate
            local dt = GetFrameTime() * 60.0
            local dx = GetDisabledControlNormal(0, 1) * D.cursorSpeed * dt -- look LR
            local dy = GetDisabledControlNormal(0, 2) * D.cursorSpeed * dt -- look UD
            cur.u = math.max(0.0, math.min(1.0, cur.u + dx))
            cur.v = math.max(0.0, math.min(1.0, cur.v + dy))
            sendDui({ action = 'cursor', u = cur.u, v = cur.v })
            if IsDisabledControlJustPressed(0, D.clickKey) then sendDui({ action = 'click' }) end
            if IsDisabledControlJustPressed(0, D.exitKey) then ExitJukeboxFocus() end
            if not (focusEnt and DoesEntityExist(focusEnt)) then ExitJukeboxFocus() end
        else
            Wait(200)
        end
    end
end)

-- panel actions from the DUI page (fetch -> here -> server)
RegisterNUICallback('duiAction', function(data, cb)
    cb('ok')
    local id = focusBooth
    if not id then return end
    local t = data.type
    if t == 'play' or t == 'pause' or t == 'skip' or t == 'stop' then
        TriggerServerEvent('moedj:dj:control', id, t)
    elseif t == 'volUp' or t == 'volDown' then
        local b = Booths[id]
        local v = (b and b.baseVolume or 0.8) + (t == 'volUp' and 0.1 or -0.1)
        TriggerServerEvent('moedj:dj:setVolume', id, math.max(0.0, math.min(1.0, v)))
    elseif t == 'queueRemove' then
        TriggerServerEvent('moedj:dj:queueRemove', id, data.index)
    elseif t == 'exit' then
        ExitJukeboxFocus()
    end
end)

local function openOverlay(msg)
    overlayOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage(msg)
end

-- click "add link" on the screen -> NUI paste overlay (real text box, Ctrl+V works)
RegisterNUICallback('duiAddLink', function(_, cb)
    cb('ok')
    if focusBooth then openOverlay({ action = 'pasteLinks' }) end
end)

RegisterNUICallback('duiQueue', function(_, cb)
    cb('ok')
    if not focusBooth then return end
    openOverlay({ action = 'openQueue' })
    TriggerServerEvent('moedj:dj:requestQueue', focusBooth)
end)

RegisterNUICallback('jukeboxAddLinks', function(data, cb)
    cb('ok')
    if focusBooth and type(data.urls) == 'table' and #data.urls > 0 then
        TriggerServerEvent('moedj:dj:queueAddMany', focusBooth, data.urls)
    end
end)

RegisterNUICallback('jukeboxQueueAction', function(data, cb)
    cb('ok')
    if not focusBooth then return end
    if data.type == 'remove' then
        TriggerServerEvent('moedj:dj:queueRemove', focusBooth, data.index)
    elseif data.type == 'reorder' then
        TriggerServerEvent('moedj:dj:queueReorder', focusBooth, data.from, data.to)
    elseif data.type == 'order' then
        TriggerServerEvent('moedj:dj:queueOrder', focusBooth, data.order)
    end
end)

RegisterNUICallback('jukeboxOverlayClose', function(_, cb)
    cb('ok')
    overlayOpen = false
    SetNuiFocus(false, false)
end)

RegisterNetEvent('moedj:dj:queue', function(boothId, queue)
    if focusBooth ~= boothId then return end
    if focused then sendDui({ action = 'queue', queue = queue }) end
    if overlayOpen then SendNUIMessage({ action = 'queueData', queue = queue }) end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    if focused then RenderScriptCams(false, false, 0, true, false); if cam then DestroyCam(cam, false) end end
    for id in pairs(props) do despawn(id) end
    if dui then DestroyDui(dui) end
end)

--------------------------------------------------------------------------------
-- /djscreen — live-align the screen quad on the prop you're nearest, then print
-- the surface values to paste into that model's entry in Config.Dui.models. The
-- change is live, so you watch the quad move. Use it when fitting a new model.
--------------------------------------------------------------------------------

RegisterNetEvent('moedj:run:djscreen', function()
    local id = nearestProp(D.drawDistance + 8.0) or nearestProp(60.0)
    local modelName = (id and props[id] and props[id].model) or (models[1] and models[1].model)
    local s = (id and boothSurface(id)) or (models[1] and models[1].surface)
    if not s then print('[moe-dj] /djscreen: no jukebox model configured to align.'); return end
    s.rx, s.ry, s.rz = s.rx or 0.0, s.ry or 0.0, s.rz or 0.0

    local function line()
        return ('%s surface = { x = %.3f, y = %.3f, z = %.3f, w = %.3f, h = %.3f, rx = %.1f, ry = %.1f, rz = %.1f }')
            :format(modelName, s.x, s.y, s.z, s.w, s.h, s.rx, s.ry, s.rz)
    end
    local function push()
        SendNUIMessage({ action = 'djscreenVals', s = { x = s.x, y = s.y, z = s.z, w = s.w, h = s.h, rx = s.rx, ry = s.ry, rz = s.rz } })
    end

    SendNUIMessage({ action = 'djscreenShow', model = tostring(modelName) })
    push()
    aligning = true
    local keys = { 174, 175, 172, 173, 10, 11, 39, 40, 44, 38, 20, 73, 21 }
    CreateThread(function()
        while true do
            Wait(0)
            for _, c in ipairs(keys) do DisableControlAction(0, c, true) end -- suppress their game actions
            local changed = false
            local shift = IsDisabledControlPressed(0, 21) -- LeftShift
            local function bump(k, d) s[k] = s[k] + d; changed = true end
            if IsDisabledControlPressed(0, 174) then bump('x', -0.005) end -- arrow left
            if IsDisabledControlPressed(0, 175) then bump('x',  0.005) end -- arrow right
            if IsDisabledControlPressed(0, 172) then bump('z',  0.005) end -- arrow up
            if IsDisabledControlPressed(0, 173) then bump('z', -0.005) end -- arrow down
            if IsDisabledControlPressed(0, 10)  then bump('y',  0.005) end -- PageUp
            if IsDisabledControlPressed(0, 11)  then bump('y', -0.005) end -- PageDown
            if IsDisabledControlPressed(0, 39) then -- [
                if shift then s.h = math.max(0.05, s.h - 0.005) else s.w = math.max(0.05, s.w - 0.005) end; changed = true
            end
            if IsDisabledControlPressed(0, 40) then -- ]
                if shift then s.h = s.h + 0.005 else s.w = s.w + 0.005 end; changed = true
            end
            if IsDisabledControlPressed(0, 44) then bump('rx', -0.5) end -- Q tilt up
            if IsDisabledControlPressed(0, 38) then bump('rx',  0.5) end -- E tilt down
            if IsDisabledControlPressed(0, 20) then bump('rz', -0.5) end -- Z turn left
            if IsDisabledControlPressed(0, 73) then bump('rz',  0.5) end -- X turn right
            if changed then push() end
            if IsControlJustPressed(0, 191) then print('[moe-dj] ' .. line()) end -- Enter
            if IsControlJustPressed(0, 194) then break end -- Backspace
        end
        aligning = false
        SendNUIMessage({ action = 'djscreenHide' })
        print('[moe-dj] ' .. line())
    end)
end)

-- diagnostics: prints what the DUI/prop system currently sees
RegisterNetEvent('moedj:run:djdui', function()
    local ped = PlayerPedId()
    local pc = GetEntityCoords(ped)
    print('^3==== moe-dj DUI diagnostics ====^0')
    print(('models configured=%d  dui ready=%s  propDistance=%s'):format(#models, tostring(ready), tostring(D and D.propDistance)))
    print(('player interior=%s  room=%s'):format(GetInteriorFromEntity(ped), GetRoomKeyFromEntity(ped)))
    local n, withProp = 0, 0
    for id, b in pairs(Booths) do
        n = n + 1
        if b.prop then
            withProp = withProp + 1
            local d = #(pc - vector3(b.prop.x, b.prop.y, b.prop.z))
            local sp = props[id] and props[id].ent and DoesEntityExist(props[id].ent)
            print(('  booth %s "%s"  model=%s  prop=(%.1f %.1f %.1f)  dist=%.1f  spawned=%s'):format(
                id, b.name or '?', tostring(b.prop.model), b.prop.x, b.prop.y, b.prop.z, d, tostring(sp)))
        else
            print(('  booth %s "%s"  prop=NONE'):format(id, b.name or '?'))
        end
    end
    print(('booths=%d  with prop=%d'):format(n, withProp))
    print('^3================================^0')
end)
