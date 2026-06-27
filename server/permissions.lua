local Core = { name = nil, obj = nil }

local function dbg(...)
    if Config.Debug then print('[moe-dj:perm]', ...) end
end

local function started(res)
    return GetResourceState(res) == 'started'
end

CreateThread(function()
    local want = Config.Core
    if want == 'none' then
        dbg('core disabled by config')
        return
    end

    if (want == 'auto' or want == 'qbx_core') and started('qbx_core') then
        Core.name = 'qbx_core'
    elseif (want == 'auto' or want == 'qb-core') and started('qb-core') then
        Core.name = 'qb-core'
        Core.obj = exports['qb-core']:GetCoreObject()
    elseif (want == 'auto' or want == 'es_extended') and started('es_extended') then
        Core.name = 'es_extended'
        Core.obj = exports['es_extended']:getSharedObject()
    end
    dbg(Core.name and ('core detected: ' .. Core.name) or 'no framework core')
end)

function HasCore()
    return Core.name ~= nil
end

function CoreName()
    return Core.name
end

-- Returns the player's job name and numeric grade level, or nil if unavailable
function GetPlayerJob(src)
    if Core.name == 'qbx_core' then
        local p = exports.qbx_core:GetPlayer(src)
        if not p then return nil end
        local job = p.PlayerData and p.PlayerData.job
        if not job then return nil end
        return job.name, (job.grade and job.grade.level) or 0
    elseif Core.name == 'qb-core' then
        local p = Core.obj.Functions.GetPlayer(src)
        if not p then return nil end
        local job = p.PlayerData and p.PlayerData.job
        if not job then return nil end
        return job.name, (job.grade and job.grade.level) or 0
    elseif Core.name == 'es_extended' then
        local xPlayer = Core.obj.GetPlayerFromId(src)
        if not xPlayer or not xPlayer.job then return nil end
        return xPlayer.job.name, xPlayer.job.grade or 0
    end
    return nil
end

function CanAdmin(src)
    return IsPlayerAceAllowed(src, Config.AdminAce)
end

function CanDJ(src, booth)
    if CanAdmin(src) then return true end
    if not booth.job or booth.job == '' then return true end
    if not HasCore() then return true end

    local jobName, grade = GetPlayerJob(src)

    if not jobName or jobName ~= booth.job then return false end
    if not booth.grades or #booth.grades == 0 then return true end

    for _, g in ipairs(booth.grades) do
        if g == grade then return true end
    end
    return false
end
