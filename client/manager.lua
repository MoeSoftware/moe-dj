--[[
    Moe DJ — owner/admin manager (/djmanager). In-world "walk and confirm" placement
    for the jukebox prop + speakers; relays create/update/delete to the server (which
    re-checks ACE). `Placing` (shared global) silences the jukebox prompt in dui.lua
    while positioning.
]]

Placing = false
local adminOpened = false -- set once the server has ACE-verified this player

--------------------------------------------------------------------------------
-- Open the manager (server validates ACE before replying)
--------------------------------------------------------------------------------

RegisterCommand('djmanager', function()
    TriggerServerEvent('moedj:admin:open')
end, false)

RegisterNetEvent('moedj:admin:opened', function(payload)
    adminOpened = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'openManager', data = payload })
end)

RegisterNetEvent('moedj:admin:refresh', function(boothList)
    SendNUIMessage({ action = 'managerBooths', booths = boothList })
end)

--------------------------------------------------------------------------------
-- In-world placement: walk to a spot, confirm, capture coords (+heading).
--------------------------------------------------------------------------------

local function showHelp(text)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayHelp(0, false, false, -1) -- no beep
end

local function rotToDir(rot)
    local zr, xr = math.rad(rot.z), math.rad(rot.x)
    local num = math.abs(math.cos(xr))
    return vector3(-math.sin(zr) * num, math.cos(zr) * num, math.sin(xr))
end

-- where the player is aiming, on the ground (or nil if aiming at the sky)
local function aimGroundPoint(ped)
    local cam = GetGameplayCamCoord()
    local dir = rotToDir(GetGameplayCamRot(2))
    local far = cam + dir * 25.0
    local h = StartExpensiveSynchronousShapeTestLosProbe(cam.x, cam.y, cam.z, far.x, far.y, far.z, 1 + 16, ped, 4)
    local _, hit, endCoords = GetShapeTestResult(h)
    if hit and hit ~= 0 then return endCoords end
    return nil
end

-- nearest other booth's jukebox within minSpacing of `coords`, or nil
local function tooCloseToOtherProp(coords, excludeId)
    local min = (Config.Dui and Config.Dui.minSpacing) or 8.0
    for id, b in pairs(Booths) do
        if id ~= excludeId and b.prop then
            if #(coords - vector3(b.prop.x, b.prop.y, b.prop.z)) < min then return b.prop end
        end
    end
    return nil
end

-- Ghost preview placement for the jukebox: a translucent jukebox follows your aim
-- so you see exactly where it'll go before confirming. Scroll to rotate.
local function placeGhostProp(excludeId, modelName)
    modelName = modelName or (Config.Dui.models[1] and Config.Dui.models[1].model)
    local model = GetHashKey(modelName)
    RequestModel(model)
    local t = 0
    while not HasModelLoaded(model) and t < 200 do Wait(10); t = t + 1 end
    if not HasModelLoaded(model) then return nil end

    local ped = PlayerPedId()
    local pc = GetEntityCoords(ped)
    local ghost = CreateObject(model, pc.x, pc.y, pc.z, false, false, false)
    SetEntityAlpha(ghost, 170, false)
    SetEntityCollision(ghost, false, false) -- so the aim ray passes through it
    FreezeEntityPosition(ghost, true)
    SetModelAsNoLongerNeeded(model)

    local heading = GetEntityHeading(ped)
    local confirmed, result = false, nil

    while true do
        Wait(0)
        local p = aimGroundPoint(ped)
        if p then
            SetEntityCoords(ghost, p.x, p.y, p.z + 1.0, false, false, false, false)
            PlaceObjectOnGroundProperly(ghost)
            SetEntityHeading(ghost, heading)
        end

        -- scroll wheel to rotate (14/15 = wheel on foot); block weapon switching
        DisableControlAction(0, 14, true)
        DisableControlAction(0, 15, true)
        if IsDisabledControlPressed(0, 15) then heading = (heading + 8.0) % 360.0 end -- scroll up
        if IsDisabledControlPressed(0, 14) then heading = (heading - 8.0) % 360.0 end -- scroll down

        -- spacing feedback: ring nearby jukeboxes red if we're too close to them
        local gc = GetEntityCoords(ghost)
        local min = (Config.Dui and Config.Dui.minSpacing) or 8.0
        local blocker = tooCloseToOtherProp(gc, excludeId)
        local pc2 = GetEntityCoords(ped)
        for bid, b in pairs(Booths) do
            if bid ~= excludeId and b.prop then
                local pp = vector3(b.prop.x, b.prop.y, b.prop.z)
                if #(pc2 - pp) < 45.0 then
                    local close = #(gc - pp) < min
                    DrawMarker(1, pp.x, pp.y, pp.z - 0.95, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                        min * 2.0, min * 2.0, 0.5,
                        close and 230 or 80, close and 60 or 90, close and 60 or 120, close and 90 or 40,
                        false, false, 2, false, nil, nil, false)
                end
            end
        end

        if blocker then
            showHelp('~r~Too close to another jukebox~s~ — move further away.  ~INPUT_VEH_DUCK~ cancel')
        else
            showHelp('Aim to position the jukebox.  Scroll to rotate.  ~INPUT_CONTEXT~ place  ~INPUT_VEH_DUCK~ cancel')
        end

        if IsControlJustReleased(0, 38) and not blocker then -- E (blocked when too close)
            local c = GetEntityCoords(ghost)
            confirmed = true
            result = { x = c.x + 0.0, y = c.y + 0.0, z = c.z + 0.0, heading = heading + 0.0 }
            break
        elseif IsControlJustReleased(0, 73) then -- X
            break
        end
    end

    if DoesEntityExist(ghost) then DeleteEntity(ghost) end
    return confirmed and result or nil
end

-- Simple marker placement (speakers): stand on the spot and confirm.
local function placeMarker(kind)
    local confirmed, point = false, nil
    while true do
        Wait(0)
        local ped = PlayerPedId()
        local c = GetEntityCoords(ped)
        DrawMarker(1, c.x, c.y, c.z - 0.95, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            0.6, 0.6, 0.4, 30, 144, 255, 120, false, false, 2, false, nil, nil, false)
        showHelp(('Placing %s — stand on the spot.  ~INPUT_CONTEXT~ confirm  ~INPUT_VEH_DUCK~ cancel'):format(kind))
        if IsControlJustReleased(0, 38) then
            confirmed = true
            point = { x = c.x + 0.0, y = c.y + 0.0, z = c.z + 0.0 }
            break
        elseif IsControlJustReleased(0, 73) then
            break
        end
    end
    return confirmed and point or nil
end

local function doPlacement(kind, excludeId, modelName)
    Placing = true
    SetNuiFocus(false, false)

    local point
    if kind == 'prop' then
        point = placeGhostProp(excludeId, modelName)
    else
        point = placeMarker(kind)
    end

    Placing = false
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'placementResult', kind = kind, point = point })
end

--------------------------------------------------------------------------------
-- NUI callbacks
--------------------------------------------------------------------------------

RegisterNUICallback('managerClose', function(_, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNUICallback('managerPlace', function(data, cb)
    cb('ok')
    CreateThread(function() doPlacement(data.kind, data.boothId, data.model) end)
end)

RegisterNUICallback('managerCreate', function(data, cb)
    TriggerServerEvent('moedj:admin:create', data)
    cb('ok')
end)

RegisterNUICallback('managerUpdate', function(data, cb)
    TriggerServerEvent('moedj:admin:update', data.id, data)
    cb('ok')
end)

RegisterNUICallback('managerDelete', function(data, cb)
    TriggerServerEvent('moedj:admin:delete', data.id)
    cb('ok')
end)

RegisterNUICallback('managerForceStop', function(data, cb)
    TriggerServerEvent('moedj:admin:forceStop', data.id)
    cb('ok')
end)

RegisterNUICallback('managerTeleport', function(data, cb)
    cb('ok')
    if not adminOpened then return end
    local b = Booths and Booths[data.id]
    if not b then return end
    local p = b.prop or b.controlPoint
    if not p then return end
    SetNuiFocus(false, false)
    local ped = PlayerPedId()
    RequestCollisionAtCoord(p.x + 0.0, p.y + 0.0, p.z + 0.0)
    SetEntityCoords(ped, p.x + 0.0, p.y + 0.0, p.z + 0.0, false, false, false, false)
    if p.heading then SetEntityHeading(ped, p.heading + 0.0) end
end)

--------------------------------------------------------------------------------
-- Live range preview: draw a ground ring at each speaker while editing a booth,
-- highlighting the one whose range is currently being changed.
--------------------------------------------------------------------------------

local previewSpeakers = {}

RegisterNUICallback('managerPreview', function(data, cb)
    previewSpeakers = data.speakers or {}
    cb('ok')
end)

RegisterNUICallback('managerPreviewClear', function(_, cb)
    previewSpeakers = {}
    cb('ok')
end)

CreateThread(function()
    while true do
        local sleep = 500
        if #previewSpeakers > 0 then
            sleep = 0
            for _, s in ipairs(previewSpeakers) do
                local r = (s.range or 30.0) + 0.0
                local cr, cg, cbl = 91, 134, 255          -- accent blue
                if s.active then cr, cg, cbl = 138, 108, 255 end -- highlight purple
                -- flat range disc on the ground
                DrawMarker(1, s.x + 0.0, s.y + 0.0, s.z - 1.0,
                    0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    r * 2.0, r * 2.0, 1.0,
                    cr, cg, cbl, s.active and 70 or 35, false, false, 2, false, nil, nil, false)
                -- speaker marker
                DrawMarker(28, s.x + 0.0, s.y + 0.0, s.z + 0.5,
                    0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    0.45, 0.45, 0.45,
                    cr, cg, cbl, 180, false, false, 2, false, nil, nil, false)
            end
        end
        Wait(sleep)
    end
end)
