-- One invisible World Partition streaming source, moved around to load map regions without moving the player.
local U = require("util")

local M = {}

local SPAWN_ALWAYS = 1
local SCALE_OVERRIDE_ROOT = 0
local MOBILITY_MOVABLE = 2

local source = nil

local function transformAt(loc)
    return {
        Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
end

local function create(loc)
    local pc = U.playerController()
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local actorClass = StaticFindObject("/Script/Engine.TargetPoint")
    local compClass = StaticFindObject("/Script/Engine.WorldPartitionStreamingSourceComponent")
    if not U.valid(gs) or not U.valid(actorClass) or not U.valid(compClass) then
        return nil, "missing engine classes"
    end
    local xf = transformAt(loc)
    local actor = gs:BeginDeferredActorSpawnFromClass(pc, actorClass, xf, SPAWN_ALWAYS, nil, SCALE_OVERRIDE_ROOT)
    if not U.valid(actor) then return nil, "spawn failed" end
    gs:FinishSpawningActor(actor, xf, SCALE_OVERRIDE_ROOT)
    pcall(function() actor.RootComponent:SetMobility(MOBILITY_MOVABLE) end)
    local comp = actor:AddComponentByClass(compClass, false, transformAt({ X = 0, Y = 0, Z = 0 }), false)
    if not U.valid(comp) then
        pcall(function() actor:K2_DestroyActor() end)
        return nil, "component failed"
    end
    pcall(function() comp:EnableStreamingSource() end)
    return { actor = actor, comp = comp }
end

local function isAt(actor, loc)
    return U.dist(U.location(actor), loc) < 100
end

function M.moveTo(loc)
    if source and U.valid(source.actor) then
        pcall(function() source.actor:K2_TeleportTo(loc, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }) end)
        if isAt(source.actor, loc) then return true end
        U.log("streaming source did not move, recreating it")
        M.clear()
    end
    local s, err = create(loc)
    if not s then return false, err end
    source = s
    if not isAt(s.actor, loc) then
        U.log("streaming source spawned at %s instead of target", tostring(U.location(s.actor) and "another place" or "unknown"))
    end
    local enabled = false
    pcall(function() enabled = s.comp:IsStreamingSourceEnabled() end)
    U.log("streaming source ready, enabled=%s", tostring(enabled))
    return true
end

function M.active()
    return source ~= nil
end

-- True once the engine has nothing left to load or unload, for this source and the whole world.
function M.idle()
    if source then
        local ok, done = pcall(function() return source.comp:IsStreamingCompleted() end)
        if ok and not done then return false end
    end
    local wps = U.worldSubsystem("WorldPartitionSubsystem")
    if wps then
        local ok, done = pcall(function() return wps:IsAllStreamingCompleted() end)
        if ok then return done == true end
    end
    return true
end

function M.clear()
    if not source then return end
    pcall(function() source.comp:DisableStreamingSource() end)
    pcall(function() source.actor:K2_DestroyActor() end)
    source = nil
end

return M
