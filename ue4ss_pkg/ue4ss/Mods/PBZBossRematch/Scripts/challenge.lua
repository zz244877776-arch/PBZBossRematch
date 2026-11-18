local U = require("util")
local Config = require("config")
local Data = require("gamedata")
local Save = require("savesnap")
local Toast = require("toast")
local Streaming = require("streaming")
local Curtain = require("curtain")
local EndChoice = require("endchoice")
local L = require("locale")

local M = {}

local TRAVEL_TIMEOUT_S = 120
-- Extra time once streaming reports idle after arriving. The player stays frozen with gravity
-- off until the reveal, so this only has to cover collision settling under the feet.
local SETTLE_SAME_MAP_S = 1.0
local SETTLE_CROSS_MAP_S = 2.0
local LOCATE_TIMEOUT_S = 20
-- World-Partition pockets at Z≥~1e7 often need longer than a ground cell.
local SKY_LOCATE_TIMEOUT_S = 45
-- Ground Seq* family (拳痴：铁狂): ClaimSeqSpawn minions, wait for boss class to appear.
local SEQ_FAMILY_TIMEOUT_S = 35
-- Traveling has already waited for streaming; locating only needs a short re-check.
local LOCATE_SETTLE_S = 0.5
-- A freshly moved streaming source can report idle before it has started loading.
local SCAN_SETTLE_S = 2
local SCAN_STEP_TIMEOUT_S = 20
local SPAWN_TIMEOUT_S = 15
local ALT_SPAWN_AFTER_S = 6
local ARRIVAL_RADIUS = 3000
local NEAR_BOSS_RADIUS = 3000
local APPROACH_DISTANCE = 700
local NEAR_BOSS_DISTANCES = { 700, 500, 1000, 1400 }
-- Keep the same Z as the boss (正前方). A positive offset put the player 前上方
-- in sky pockets (暗魔天堡 Z≈1e7) and looked wrong on flat arenas too.
local PLAYER_HEIGHT_OFFSET = 0
local RELOAD_TIMEOUT_S = 20
local RELOAD_MIN_S = 5
local SCAN_STABLE_REGIONS = 3
local STAGE_WAIT_S = 6
local STAGE_FADE_AT_S = 4
local STAGE_FADE_S = 1.0
local PREPARE_MIN_S = 1.0
-- The sky pocket is streamed in only once the boss exists there, so it gets longer.
local PREPARE_MIN_SKY_S = 2.0
local PREPARE_TIMEOUT_S = 15
local REVEAL_FADE_S = 0.8
-- The countdown starts while the scene is still fading in; setup is finished by then.
local COUNTDOWN_AFTER_REVEAL_MS = 300
local DEPART_FADE_S = 0.35

-- idle -> departing -> traveling -> locating [-> scanning -> traveling -> locating] -> spawning
--   -> preparing -> countdown -> fighting -> ending -> reloading -> idle
local st = { phase = "idle" }

-- Defined later; start/return call these before their assignment runs at load time.
local clearStickyCombatMusic
local applyStageMusic

function M.phase() return st.phase end
function M.isActive() return st.phase ~= "idle" end

local function setPhase(p)
    U.log("phase %s -> %s", st.phase, p)
    st.phase = p
    st.phaseAt = os.time()
    st.phaseClock = os.clock()
end

local function elapsed() return os.time() - (st.phaseAt or os.time()) end
-- Sub-second version for the short loading waits; os.time() rounds them to whole seconds.
local function elapsedS() return os.clock() - (st.phaseClock or os.clock()) end

-- One line under the black screen, so the loading does not look like a hang.
local function loadingToast(stage)
    if not st.boss then return end
    Toast.show(L.T("loading", st.boss.name, stage), 20000)
end

local function saveSub() return U.gameInstanceSubsystem("PBZSaveLoadSubsystem") end

-- A transform standing `distance` away from `target`, on the side of `from`, facing `target`.
local function approachTransform(target, from, distance)
    local dx, dy = from.X - target.X, from.Y - target.Y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then dx, dy, len = 1, 0, 1 end
    local ux, uy = dx / len, dy / len
    local yaw = math.atan(-uy, -ux)
    return {
        Rotation = { X = 0.0, Y = 0.0, Z = math.sin(yaw / 2), W = math.cos(yaw / 2) },
        Translation = { X = target.X + ux * distance, Y = target.Y + uy * distance, Z = target.Z + PLAYER_HEIGHT_OFFSET },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }, math.deg(yaw)
end

-- Unreal yaw degrees: 0 = +X, looking from `from` toward `to`.
local function yawFacing(from, to)
    local dx, dy = to.X - from.X, to.Y - from.Y
    if dx * dx + dy * dy < 1 then return 0.0 end
    return math.deg(math.atan(dy, dx))
end

-- Player and boss fronts face each other (used at place / pull / fight start).
local function faceEachOther(pawn, boss)
    pawn = pawn or U.playerPawn()
    local p = U.location(pawn)
    local b = U.location(boss)
    if not U.valid(pawn) or not U.valid(boss) or not p or not b then return end
    local playerYaw = yawFacing(p, b)
    local bossYaw = yawFacing(b, p)
    local playerRot = { Pitch = 0.0, Yaw = playerYaw, Roll = 0.0 }
    local bossRot = { Pitch = 0.0, Yaw = bossYaw, Roll = 0.0 }
    pcall(function() pawn:K2_SetActorRotation(playerRot, false) end)
    pcall(function() U.playerController():SetControlRotation(playerRot) end)
    pcall(function() boss:K2_SetActorRotation(bossRot, false) end)
    U.log("faced each other playerYaw=%.1f bossYaw=%.1f", playerYaw, bossYaw)
end

local function inLevel(level)
    return string.find(U.worldName() or "", level, 1, true) ~= nil
end

-- Fast travel while already in the destination level hangs the game, above all when the
-- destination is the bell the player just opened. Move the pawn instead.
local function localTeleport(transform)
    local pawn = U.playerPawn()
    if not U.valid(pawn) then return false, "找不到角色" end
    local loc = transform.Translation
    local here = U.location(pawn)
    if here and U.dist(here, loc) < 150 then
        U.log("already at the target")
        return true
    end
    local q = transform.Rotation or {}
    local yaw = math.deg(2 * math.atan(q.Z or 0, q.W or 1))
    local rot = { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }
    local ok, moved = pcall(function() return pawn:K2_TeleportTo(loc, rot) end)
    U.log("K2_TeleportTo ok=%s moved=%s", tostring(ok), tostring(moved))
    if ok and moved then
        pcall(function() U.playerController():SetControlRotation(rot) end)
        return true
    end
    -- MOVE_None / blocked collision can make K2_TeleportTo report moved=false while the pawn
    -- is otherwise fine. Force the transform; streaming under the feet finishes in traveling.
    pcall(function() pawn:K2_SetActorLocationAndRotation(loc, rot, false, nil, true) end)
    local after = U.location(pawn)
    if after and U.dist(after, loc) < 400 then
        U.log("K2_SetActorLocationAndRotation fallback ok (was %.0f away)", here and U.dist(here, loc) or -1)
        pcall(function() U.playerController():SetControlRotation(rot) end)
        return true
    end
    pcall(function() pawn:K2_SetActorLocation(loc, false, nil, true) end)
    after = U.location(pawn)
    if after and U.dist(after, loc) < 400 then
        U.log("K2_SetActorLocation fallback ok")
        pcall(function() pawn:K2_SetActorRotation(rot, false) end)
        pcall(function() U.playerController():SetControlRotation(rot) end)
        return true
    end
    return false, "同地图传送失败"
end

local setPlayerTransitFrozen -- defined after setFrozen (local forward ref)
local dismissEarlyNextStage -- defined later; used from tickSpawning
local rematchOnDefeat -- defined later; used from tickFighting
local finishReload -- defined later; used from returnToStart fallback
local completeReturn -- defined after finishReload; also run once landing has settled
local placePlayerNearBoss -- defined later; used from sky / seq-family locate

local function travel(level, transform, bellId, opts)
    opts = opts or {}
    local allowSky = opts.allowSky == true
    local bell = Data.bellById(bellId)
    local xf = transform
    local function allowed(loc)
        return U.saneWorldLoc(loc) or (allowSky and U.isSkyArenaLoc(loc))
    end
    -- Same-map hops may pass an approach transform; cross-map always prefers a sane bell point
    -- unless this is an explicit sky-arena entry (暗魔天堡 / 龙柱试炼).
    if not inLevel(level) then
        xf = (bell and U.bellTravelTransform(bell)) or transform
        if not allowed(xf and xf.Translation) and allowed(transform and transform.Translation) then
            xf = transform
        end
    elseif not allowed(xf and xf.Translation) then
        xf = (bell and U.bellTravelTransform(bell)) or xf
    end
    if not allowed(xf and xf.Translation) then
        U.log("travel refused: destination Z is not allowed (%.0f, %.0f, %.0f)",
            xf and xf.Translation.X or 0, xf and xf.Translation.Y or 0, xf and xf.Translation.Z or 0)
        return false, "目标点坐标异常（可能摔死），已取消传送"
    end

    local same = inLevel(level)
    st.travel = { level = level, loc = xf.Translation, bell = bellId, sameMap = same }
    U.log("travel level=%s bell=%s sameMap=%s at (%.0f, %.0f, %.0f)", level, bellId, tostring(same),
        xf.Translation.X, xf.Translation.Y, xf.Translation.Z)
    if Config.LoadingCurtain ~= false then setPlayerTransitFrozen(true) end
    if same then
        -- Pre-stream the destination so the hop is less likely to be blocked by unloaded cells.
        pcall(function() Streaming.moveTo(xf.Translation) end)
        local ok, err = localTeleport(xf)
        if not ok then
            -- Do NOT rewrite travel.loc to the player's current spot and pretend we arrived:
            -- that used to clear finalHop and re-enter locating forever (black-screen loop).
            U.log("local move failed: %s", tostring(err))
            return false, err
        end
        st.arrivedAt = nil
        setPhase("traveling")
        return true
    end
    -- Cross-map travel has to land on the bell itself. A point in an unloaded cell hangs TeleportTo.
    st.travel.loc = xf.Translation
    local sub = saveSub()
    if not sub then return false, "找不到存档子系统" end
    local ok, err = pcall(function() sub:TeleportTo(FName(level), xf, FName(bellId)) end)
    if not ok then return false, "传送失败: " .. tostring(err) end
    st.arrivedAt = nil
    setPhase("traveling")
    return true
end

-- Actors are remembered by address and class only, then looked up among live objects each time:
-- a corpse or spawner the engine has already freed must never be touched through an old wrapper.
local function remember(actor)
    if not actor then return nil, nil end
    return U.address(actor), U.className(actor)
end

local function bossPawn()
    return U.live(st.bossClass, st.bossKey)
end

local function setBoss(pawn)
    st.bossKey, st.bossClass = remember(pawn)
end

local function isDead(actor)
    local ok, v = pcall(function() return actor:IsDead() end)
    return ok and v == true
end

local function restoreActorFullHealth(actor)
    if not U.valid(actor) then return end
    pcall(function()
        if actor.RestoreFullHealth then actor:RestoreFullHealth() end
    end)
    pcall(function()
        if actor.RestoreHealth then actor:RestoreHealth() end
    end)
    pcall(function()
        if actor.SetHealthPercent then actor:SetHealthPercent(1.0) end
    end)
    pcall(function()
        if actor.SetHPPercent then actor:SetHPPercent(1.0) end
    end)
end

local restorePlayerFullHealth -- defined after cheatManager

local function bossLocUsable(loc)
    if not loc or U.isSoftWorldLoc(loc) then return false end
    if st.skyArenaHop then return U.isSkyArenaLoc(loc) end
    return U.teleportAllowedLoc(loc)
end

-- After the player dies SpawnedAI often goes soft at (0,0,0) while the visible sky
-- boss keeps animating. Never freeze/return that soft shell.
local function reacquireBoss()
    if not st.boss or not st.boss.class then return nil end
    local anchor = st.spawnerLoc
    local function consider(a, src)
        if not (U.valid(a) and not isDead(a)) then return nil, nil end
        local loc = U.location(a)
        if not bossLocUsable(loc) then return nil, nil end
        local d = (anchor and U.horizDist(loc, anchor)) or 0
        return a, d, loc, src
    end

    local best, bestD, bestLoc, bestSrc = nil, math.huge, nil, nil
    local spawner = st.spawnerKey and U.live(st.spawnerClass, st.spawnerKey)
    if spawner then
        local ai = nil
        pcall(function() ai = spawner.SpawnedAI end)
        local a, d, loc, src = consider(ai, "spawner.SpawnedAI")
        if a and d < bestD then best, bestD, bestLoc, bestSrc = a, d, loc, src end
    end
    for _, a in ipairs(FindAllOf(st.boss.class) or {}) do
        local cand, d, loc, src = consider(a, "FindAllOf")
        if cand and d < bestD then best, bestD, bestLoc, bestSrc = cand, d, loc, src end
    end
    if best then
        setBoss(best)
        U.log("reacquired boss via %s distXY=%.0f at (%.0f,%.0f,%.0f)",
            bestSrc, bestD, bestLoc.X, bestLoc.Y, bestLoc.Z)
        return best
    end
    U.log("reacquireBoss: no usable %s (skyHop=%s)", st.boss.class, tostring(st.skyArenaHop))
    return nil
end

-- Living boss of the current class, ignoring soft/sky loc filters (caller may rescue it).
local function findLivingBossRaw()
    if not st.boss or not st.boss.class then return nil end
    local spawner = st.spawnerKey and U.live(st.spawnerClass, st.spawnerKey)
    if spawner then
        local ai = nil
        pcall(function() ai = spawner.SpawnedAI end)
        if U.valid(ai) and not isDead(ai) then return ai end
    end
    for _, a in ipairs(FindAllOf(st.boss.class) or {}) do
        if U.valid(a) and not isDead(a) then
            local key = U.address(a)
            if not (st.vetoedNextKeys and st.vetoedNextKeys[key]) then
                return a
            end
        end
    end
    return nil
end

-- Soft WP junk (Z≈2e6) is neither ground-sane nor a real sky pocket. Drag the living AI
-- next to the player so preparing/countdown can proceed (seen with 活人偶清道夫).
local function rescueSoftBossToPlayer(boss)
    local pawn = U.playerPawn()
    local p = U.location(pawn)
    if not (U.valid(boss) and not isDead(boss) and p and U.saneWorldLoc(p)) then return false end
    local b = U.location(boss)
    if bossLocUsable(b) then
        setBoss(boss)
        return true
    end
    local dest = { X = p.X + 250, Y = p.Y + 250, Z = p.Z }
    local rot = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
    local ok, moved = pcall(function() return boss:K2_TeleportTo(dest, rot) end)
    if not (ok and moved) then
        pcall(function() boss:K2_SetActorLocation(dest, false, nil, true) end)
        local after = U.location(boss)
        moved = after and U.dist(after, dest) < 600
    end
    U.log("rescue soft boss -> player ok=%s moved=%s to (%.0f,%.0f,%.0f) wasZ=%s",
        tostring(ok), tostring(moved), dest.X, dest.Y, dest.Z, tostring(b and b.Z))
    if not moved then return false end
    setBoss(boss)
    st.spawnerLoc = dest
    Data.rememberArenaLoc(st.rootBoss or st.boss, dest, st.spawnerId)
    return true
end

-- Despawn + ClaimSeqSpawn / Spawn a fresh arena boss. Prefer not to keep a soft corpse.
local function respawnBossForRematch()
    local spawner = st.spawnerKey and U.live(st.spawnerClass, st.spawnerKey)
    if not spawner and st.boss then
        if Data.findSpawnerForBoss then
            spawner = Data.findSpawnerForBoss(st.boss)
        end
        if not spawner then spawner = Data.findSpawner(st.boss.class) end
        if spawner then
            st.spawnerKey, st.spawnerClass = remember(spawner)
            local sid = ""
            pcall(function() sid = U.str(spawner.SpawnerID) end)
            st.spawnerId = sid
        end
    end
    if not spawner then
        U.log("respawnBossForRematch: no spawner")
        return nil
    end
    local streamLoc = st.spawnerLoc
    if not (streamLoc and U.teleportAllowedLoc(streamLoc)) then
        streamLoc = U.location(U.playerPawn())
    end
    if streamLoc and U.saneWorldLoc(streamLoc) then
        Streaming.moveTo(streamLoc)
    end
    -- Drop any previous AI so ClaimSeqSpawn cannot "succeed" by handing back a corpse.
    pcall(function()
        local old = spawner.SpawnedAI
        if U.valid(old) then pcall(function() old:K2_DestroyActor() end) end
    end)
    pcall(function() spawner:Despawn() end)
    pcall(function() spawner.ShouldSpawn = true end)
    pcall(function()
        if spawner.SpawnerSaveInfo then spawner.SpawnerSaveInfo.IsAlive = true end
    end)
    local okClaim = pcall(function() spawner:ClaimSeqSpawn(false, true, true) end)
    local pending, hasAI = false, false
    pcall(function() pending = spawner:IsSpawnPending() == true end)
    pcall(function() hasAI = U.valid(spawner.SpawnedAI) end)
    local started = okClaim and (pending or hasAI)
    if not started then
        pcall(function() spawner:SpawnFromSequence() end)
        pcall(function() hasAI = U.valid(spawner.SpawnedAI) end)
        started = hasAI
    end
    if not started then
        local okSpawn = pcall(function() spawner:Spawn() end)
        U.log("respawnBossForRematch: Spawn() ok=%s", tostring(okSpawn))
    end
    U.log("respawnBossForRematch: ClaimSeqSpawn ok=%s started=%s", tostring(okClaim), tostring(started))
    local boss = reacquireBoss()
    if not boss then
        boss = findLivingBossRaw()
        if boss and not bossLocUsable(U.location(boss)) then
            if rescueSoftBossToPlayer(boss) then return bossPawn() or boss end
            return nil
        end
        if boss then setBoss(boss) end
    end
    return boss
end

local function ensureBossForRematch()
    local boss = reacquireBoss()
    if boss then return boss end
    boss = findLivingBossRaw()
    if boss then
        if bossLocUsable(U.location(boss)) then
            setBoss(boss)
            return boss
        end
        if rescueSoftBossToPlayer(boss) then return bossPawn() or boss end
    end
    boss = respawnBossForRematch()
    if boss then return boss end
    return nil
end

local function pawnAddress()
    local pawn = U.playerPawn()
    return pawn and U.address(pawn) or nil
end

local function controllerOf(pawn)
    local ok, c = pcall(function() return pawn.Controller end)
    return ok and U.valid(c) and c or nil
end

local function sgameAIComponents(pawn, controller)
    local cls = StaticFindObject("/Script/SGameAI.SGameAIComponent")
    local list = {}
    if not U.valid(cls) then return list end
    for _, owner in ipairs({ pawn, controller }) do
        if U.valid(owner) then
            local ok, comp = pcall(function() return owner:GetComponentByClass(cls) end)
            if ok and U.valid(comp) then table.insert(list, comp) end
        end
    end
    return list
end

local function call(what, fn)
    local ok, err = pcall(fn)
    U.log("%s ok=%s %s", what, tostring(ok), ok and "" or tostring(err))
end

-- Boss and player MUST use separate freeze-slot keys. Sharing one key meant sky
-- transit freeze on the player stomped the boss slot, so countdown StopAI never stuck.
local function setActorFrozen(pawn, frozen, slotKey)
    if not U.valid(pawn) then return end
    local d = frozen and 0.0 or 1.0
    pcall(function() pawn.CustomTimeDilation = d end)
    pcall(function()
        local mesh = pawn.Mesh
        if U.valid(mesh) then
            mesh.GlobalAnimRateScale = frozen and 0.0 or 1.0
        end
    end)
    local controller = controllerOf(pawn)
    if controller then pcall(function() controller.CustomTimeDilation = d end) end
    local key = tostring(U.address(pawn)) .. "/" .. tostring(controller and U.address(controller))
    -- Same pawn+controller: still refresh dilation/anim rate above; skip StopAI spam only.
    if frozen and st[slotKey] == key then return end
    st[slotKey] = frozen and key or nil
    local verb = frozen and "freeze" or "release"
    call(verb .. " FreezeCharacter", function() pawn:FreezeCharacter(frozen) end)
    for _, comp in ipairs(sgameAIComponents(pawn, controller)) do
        if frozen then
            call(verb .. " StopAI", function() comp:StopAI() end)
        else
            call(verb .. " StartAI", function() comp:StartAI() end)
        end
    end
    if controller then
        local lib = StaticFindObject("/Script/SGameAI.Default__SGameAIFunctionLibrary")
        local brain = nil
        pcall(function() brain = controller.BrainComponent end)
        if U.valid(lib) and U.valid(brain) then
            if frozen then
                call(verb .. " PauseLogic", function() lib:PauseLogic(brain, "PBZBossRematch") end)
            else
                call(verb .. " ResumeLogic", function() lib:ResumeLogic(brain, "PBZBossRematch") end)
            end
        end
        local perception = nil
        pcall(function() perception = controller.PerceptionComponent end)
        if U.valid(lib) and U.valid(perception) then
            call(verb .. " SetSensesEnabled", function() lib:SetSensesEnabled(perception, not frozen) end)
        end
        call(verb .. " StopMovement", function() controller:StopMovement() end)
    end
end

local function setFrozen(pawn, frozen)
    setActorFrozen(pawn, frozen, "bossFreezeKey")
end

-- Force a full freeze pass (clears slot so StopAI runs again after controller reattach).
local function hardFreezeBoss(pawn)
    if not U.valid(pawn) then return end
    st.bossFreezeKey = nil
    setFrozen(pawn, true)
end

-- Soft-rescued / countdown-frozen bosses sometimes keep dilation 0 or MOVE_None after a
-- single FreezeCharacter(false). Clear slot and reassert movement + AI hard.
local function forceUnfreezeBoss(pawn)
    if not U.valid(pawn) then return end
    st.bossFreezeKey = nil
    pcall(function() pawn.CustomTimeDilation = 1.0 end)
    pcall(function()
        local mesh = pawn.Mesh
        if U.valid(mesh) then mesh.GlobalAnimRateScale = 1.0 end
    end)
    local controller = controllerOf(pawn)
    if controller then pcall(function() controller.CustomTimeDilation = 1.0 end) end
    setFrozen(pawn, false)
    -- Soft teleport rescue can leave CMC in MOVE_None; walking must come back for combat.
    pcall(function()
        local move = pawn.CharacterMovement
        if U.valid(move) then
            pcall(function() move:SetMovementMode(1) end)
        end
    end)
    -- Second pass: some controllers reattach a beat after StartAI.
    pcall(function() pawn:FreezeCharacter(false) end)
end

setPlayerTransitFrozen = function(frozen)
    local pawn = U.playerPawn()
    if frozen then
        if not U.valid(pawn) then return end
        st.playerFreezeKey = U.address(pawn)
        st.playerFreezeClass = U.className(pawn)
        setActorFrozen(pawn, true, "playerFreezeSlot")
        -- FreezeCharacter alone does not stop void fall / kill volumes.
        pcall(function()
            local move = pawn.CharacterMovement
            if U.valid(move) then
                if st.savedGravity == nil then st.savedGravity = move.GravityScale end
                move.GravityScale = 0
                pcall(function() move:StopMovementImmediately() end)
                pcall(function() move:SetMovementMode(0) end) -- MOVE_None
            end
        end)
        return
    end
    if st.playerFreezeKey then
        local p = U.live(st.playerFreezeClass, st.playerFreezeKey)
        if p then
            setActorFrozen(p, false, "playerFreezeSlot")
            pcall(function()
                local move = p.CharacterMovement
                if U.valid(move) then
                    if st.savedGravity ~= nil then move.GravityScale = st.savedGravity end
                    pcall(function() move:SetMovementMode(1) end) -- MOVE_Walking
                end
            end)
        end
        st.playerFreezeKey, st.playerFreezeClass, st.savedGravity = nil, nil, nil
        st.playerFreezeSlot = nil
    end
end

local function unfreezeBoss()
    local p = nil
    if st.frozenKey then
        p = U.live(st.frozenClass, st.frozenKey) or bossPawn()
    else
        p = bossPawn()
    end
    if p then
        forceUnfreezeBoss(p)
        U.log("boss released")
    end
    st.frozenKey, st.frozenClass = nil, nil
    st.bossFreezeKey = nil
    -- Keep forcing unfreeze for a couple seconds; soft-rescued bosses can re-stick.
    st.unfreezeUntil = os.clock() + 2.5
end

-- Despawn the rematch boss so it cannot linger / re-aggro at the return bell.
local function cleanupRematchActors()
    local function wipe(actor, tag)
        if not (U.valid(actor) and not isDead(actor)) then return end
        hardFreezeBoss(actor)
        pcall(function() actor:SetActorHiddenInGame(true) end)
        pcall(function() actor:K2_DestroyActor() end)
        U.log("cleanup: destroyed %s", tag or "actor")
    end
    wipe(bossPawn(), "rematch boss")
    if st.boss and st.boss.class then
        for _, a in ipairs(FindAllOf(st.boss.class) or {}) do
            local loc = U.location(a)
            if loc and not U.isSoftWorldLoc(loc) then
                if U.isSkyArenaLoc(loc) or (st.spawnerLoc and U.dist(loc, st.spawnerLoc) < 8000) then
                    wipe(a, st.boss.class)
                end
            end
        end
    end
    local spawner = st.spawnerKey and U.live(st.spawnerClass, st.spawnerKey)
    if spawner then
        pcall(function() spawner:Despawn() end)
        pcall(function() spawner.ShouldSpawn = false end)
        pcall(function()
            if spawner.SpawnerSaveInfo then spawner.SpawnerSaveInfo.IsAlive = false end
        end)
        U.log("cleanup: despawned rematch spawner")
    end
    st.bossKey, st.bossClass, st.frozenKey, st.frozenClass = nil, nil, nil, nil
end

local function returnToStart(reason, delayMs)
    if st.phase == "ending" or st.phase == "reloading" or st.phase == "landing" then return end
    EndChoice.hide()
    st.choiceToken = nil
    st.endReason = reason
    setPhase("ending")
    -- Quit/abort/defeat: remove living rematch AI before save restore so the return
    -- bell is not contested by a still-spawned boss (soft loads keep actors).
    if reason ~= "victory" then
        pcall(cleanupRematchActors)
    else
        unfreezeBoss()
    end
    clearStickyCombatMusic()
    -- Leave the screen open during delayMs so「斩」/ toast can play; cover only for the
    -- restore + reload hitch that follows.
    setPlayerTransitFrozen(false)
    Streaming.clear()
    U.delay(delayMs or 0, "challenge.return", function()
        if st.phase ~= "ending" then return end
        if Config.LoadingCurtain ~= false then
            Curtain.cover()
            setPlayerTransitFrozen(true)
        end
        -- Small beat so the fade is up before disk/load work stalls the frame.
        U.delay(150, "challenge.returnIO", function()
            if st.phase ~= "ending" then return end
            Save.exitVeto()
            if not Save.restoreFiles() then
                Toast.show(L.T("save_restore_fail"), 8000)
                U.log("restore failed; state kept for recovery on next launch")
                Curtain.reveal(0.5)
                setPlayerTransitFrozen(false)
                setPhase("idle")
                return
            end
            local state = Save.readState()
            local slot = (state and state.continueSlot) or Save.continueSlotName()
            st.reloadPawn = pawnAddress()
            st.reloadLoc = U.location(U.playerPawn())
            st.startBell = state and state.startBell
            setPhase("reloading")
            -- The real save is back on disk at this point, so the state file must not survive:
            -- recovery on a later launch would otherwise delete saves made after this challenge.
            Save.clearState()
            if not Save.reloadSlot(slot) then
                Toast.show(L.T("reload_fail_manual"), 8000)
                Curtain.reveal(0.5)
                setPlayerTransitFrozen(false)
                setPhase("idle")
                return
            end
            local reloadAt = st.phaseAt
            U.delay((RELOAD_TIMEOUT_S + 2) * 1000, "challenge.reloadFallback", function()
                if st.phase == "reloading" and st.phaseAt == reloadAt then
                    U.log("reload fallback timer fired")
                    finishReload()
                end
            end)
        end)
    end)
end

local function abort(msg)
    U.log("abort: %s", msg)
    Toast.show(msg, 5000)
    returnToStart("abort", 3000)
end

-- Prefer a grounded bell that is NOT the fight arena. Starting rematch from the
-- boss's own bell used to make quit land back in the encounter volume (vanilla fight).
local QUIT_BELL_MIN_SEP = 2500

local function alternateBellAwayFrom(mapId, avoidId, origin)
    local bestFar, bestFarD = nil, math.huge
    local bestAny, bestAnyD = nil, math.huge
    for _, b in ipairs(Data.bellsInMap(mapId) or {}) do
        if b.id ~= avoidId and U.saneWorldLoc(b.loc) then
            local d = (origin and U.dist(origin, b.loc)) or 0
            if d < bestAnyD then bestAny, bestAnyD = b, d end
            if d >= QUIT_BELL_MIN_SEP and d < bestFarD then bestFar, bestFarD = b, d end
        end
    end
    return bestFar or bestAny
end

function M.start(boss)
    if M.isActive() then
        Toast.show(L.T("already_challenging"), 2000)
        return
    end
    local arena = Data.arena(boss.id)
    if arena and arena.unsupported then
        Toast.show(L.T("unsupported", boss.name), 3000)
        return
    end
    U.log("=== start challenge: %s (%s, map %s)", boss.name, boss.id, boss.map)

    local mapBells = Data.bellsInMap(boss.map)
    local function firstSaneMapBell()
        for _, b in ipairs(mapBells) do
            local t = U.bellTravelTransform(b)
            if t and U.saneWorldLoc(t.Translation) then return b end
        end
        return mapBells[1]
    end
    if arena and not Data.arenaBelongsToBossMap(arena, boss.map) then
        U.log("arena cache for %s is off-map/mismatched; ignoring cached bell/xyz", boss.id)
        arena = { map = boss.map }
    end
    local arenaBell = arena and arena.bell and arena.bell ~= "" and Data.bellById(arena.bell) or nil
    if arenaBell then
        local t = U.bellTravelTransform(arenaBell)
        if not (t and U.saneWorldLoc(t.Translation)) then
            U.log("arena bell %s travel point not sane; falling back to map bell", arenaBell.id)
            arenaBell = nil
        end
    end
    local firstBell = arenaBell or firstSaneMapBell()
    if not firstBell then
        Toast.show(L.T("no_bell_for_map"), 4000)
        return
    end
    local mapLevel = Data.levelNameForMap(boss.map)
    local level = Data.levelNameForBell(firstBell.id)
    if mapLevel and level and mapLevel ~= level then
        U.log("bell %s level %s != map %s level %s; using map bell instead",
            firstBell.id, tostring(level), boss.map, tostring(mapLevel))
        arenaBell = nil
        firstBell = firstSaneMapBell()
        level = firstBell and Data.levelNameForBell(firstBell.id) or mapLevel
    end
    if arenaBell then
        U.log("arena cache hit bell=%s at (%.0f, %.0f, %.0f)", arena.bell, arena.x or 0, arena.y or 0, arena.z or 0)
    else
        U.log("arena cache miss; first visit uses map bell %s (next time will be faster)", firstBell.id)
    end
    if not level then
        Toast.show(L.T("no_bell_level"), 4000)
        return
    end

    local bm = U.worldSubsystem("BellManager")
    local startBell = ""
    pcall(function() startBell = U.str(bm.RecentlyInteractedBellID) end)
    -- If the player opened rematch from the fight's own bell, remember a different
    -- quit target so exit does not drop them back into the encounter volume.
    local arenaBellId = arenaBell and arenaBell.id or (firstBell and firstBell.id) or ""
    if startBell == "" or startBell == arenaBellId then
        local here = U.location(U.playerPawn())
        local origin = here or (arenaBell and arenaBell.loc) or (firstBell and firstBell.loc)
        local altMap = startBell ~= "" and Data.bellById(startBell)
        local mapForQuit = (altMap and altMap.map) or boss.map
        local alt = alternateBellAwayFrom(mapForQuit, arenaBellId, origin)
        if not alt and mapForQuit ~= boss.map then
            alt = alternateBellAwayFrom(boss.map, arenaBellId, origin)
        end
        if alt then
            U.log("startBell %s is arena/empty; quit target → %s", tostring(startBell), alt.id)
            startBell = alt.id
        end
    end

    local ok, err = Save.takeSnapshot({ bossId = boss.id, bossName = boss.name, startBell = startBell, startWorld = U.worldName() })
    if not ok then
        Toast.show(L.T("cannot_start", tostring(err)), 5000)
        return
    end

    st = { phase = "idle", boss = boss, level = level, mapBells = mapBells, startBell = startBell }
    loadingToast(arenaBell and L.T("going") or L.T("first_visit_slow"))
    clearStickyCombatMusic()

    local transform = U.bellTravelTransform(firstBell) or firstBell.transform
    -- Same-map: hop next to a grounded arena, or into a known sky pocket arena (暗魔天堡).
    if arenaBell and arena.x and arena.z and inLevel(level) then
        local arenaLoc = { X = arena.x, Y = arena.y, Z = arena.z }
        if U.saneWorldLoc(arenaLoc) then
            transform = approachTransform(arenaLoc, arenaBell.loc, APPROACH_DISTANCE)
            st.finalHop = true
        elseif U.isSkyArenaLoc(arenaLoc) then
            -- Do not hop into the pocket here. One entry teleport runs later, once,
            -- after the boss is frozen and before countdown.
            st.skyArenaHop = true
            U.log("arena cache sky pocket for %s; bell first, enter Z=%.0f once before countdown", boss.id, arena.z)
        else
            U.log("arena cache XYZ not usable for %s; traveling to bell only", boss.id)
        end
    end

    local function depart()
        local tok, terr = travel(level, transform, firstBell.id)
        if not tok then
            Curtain.reveal(0.3)
            setPlayerTransitFrozen(false)
            Save.clearState()
            st = { phase = "idle" }
            Toast.show(terr, 5000)
        end
    end
    if Config.LoadingCurtain == false then return depart() end
    -- Fade to black first; the teleport and the loading hitch happen behind it.
    setPhase("departing")
    setPlayerTransitFrozen(true)
    Curtain.fadeOut(DEPART_FADE_S)
    U.delay(math.floor(DEPART_FADE_S * 1000) + 80, "challenge.depart", function()
        if st.phase ~= "departing" then return end
        Curtain.cover()
        depart()
    end)
end

local function arrived()
    local pawn = U.playerPawn()
    if not pawn then return false end
    if not string.find(U.worldName(), st.travel.level, 1, true) then return false end
    local here = U.location(pawn)
    if not here then return false end
    if not (U.saneWorldLoc(here) or U.isSkyArenaLoc(here)) then return false end
    return U.dist(here, st.travel.loc) < ARRIVAL_RADIUS
end

local function tickTraveling()
    if elapsed() > TRAVEL_TIMEOUT_S then return abort(L.T("travel_timeout")) end
    if Config.LoadingCurtain ~= false then setPlayerTransitFrozen(true) end
    if not arrived() then
        st.arrivedAt = nil
        return
    end
    -- Wait for collision/streaming under the feet before we unfreeze / hop again.
    if not Streaming.idle() and elapsed() < TRAVEL_TIMEOUT_S then return end
    st.arrivedAt = st.arrivedAt or os.clock()
    local settle = st.travel.sameMap and SETTLE_SAME_MAP_S or SETTLE_CROSS_MAP_S
    if os.clock() - st.arrivedAt < settle then return end
    U.log("arrived after %.1fs", elapsedS())
    if not st.travel.sameMap then loadingToast(L.T("loading_boss")) end
    setPhase("locating")
end

-- Spawners placed for cutscenes ignore Spawn() and only react to the sequence entry points.
-- ClaimSeqSpawn first: it is what ties the spawner back into the Level Sequence / Flow Graph
-- that also brings minions, formations, death banners ("斩"), and phase music.
local function spawnStarted(spawner)
    local pending, hasAI = false, false
    pcall(function() pending = spawner:IsSpawnPending() == true end)
    pcall(function() hasAI = U.valid(spawner.SpawnedAI) end)
    return pending or hasAI
end

-- Both entry points can spawn, so the second one only runs when the first did not start anything;
-- calling both put two copies of the same boss in the arena.
local function trySequenceSpawn(spawner)
    local okClaim = pcall(function() spawner:ClaimSeqSpawn(false, true, true) end)
    local started = okClaim and spawnStarted(spawner)
    U.log("ClaimSeqSpawn() ok=%s started=%s", tostring(okClaim), tostring(started))
    if started then return true end
    local okSeq = pcall(function() spawner:SpawnFromSequence() end)
    U.log("SpawnFromSequence() ok=%s started=%s", tostring(okSeq), tostring(okSeq and spawnStarted(spawner)))
    return okClaim or okSeq
end

local function spawnerId(spawner)
    local id = ""
    pcall(function() id = U.str(spawner.SpawnerID) end)
    return id or ""
end

local function spawnerLooksSequenced(spawner)
    return string.find(spawnerId(spawner), "Seq", 1, true) ~= nil
end

-- "Jianou_Seq076" -> 76. Spawners placed for one story sequence share its number.
local function seqNumber(id)
    return tonumber(string.match(id or "", "_Seq(%d+)"))
end

-- "Jianou_Seq076" / "LionDanceBattle_Seq062" -> family prefix used by the same encounter.
local function encounterPrefix(id)
    if not id or id == "" or id == "None" then return nil end
    local prefix = string.match(id, "^([%w]+)_Seq") or string.match(id, "^([%w_]-)_Seq")
    return prefix
end

local SUPPORT_RADIUS = 12000
local SUPPORT_LOG_RADIUS = 6000

local function bossClassSet()
    local set = {}
    for _, b in ipairs(Data.bosses()) do set[string.lower(b.class)] = true end
    return set
end

local function mobGroupKey(spawner)
    local key = nil
    pcall(function()
        local g = spawner.MobGroup
        if U.valid(g) then key = U.address(g) end
    end)
    return key
end

-- Boss-only Spawn() skips the encounter's minions and formation members. Spawners that share the
-- boss spawner's MobGroup (or its "<Name>_Seq" family) belong to the same fight; other bosses,
-- such as the next phase, never do: spawning them here put both phases in the arena at once.
local function activateEncounterSupport(center, mainSpawner)
    if not center then return end
    local mainKey = U.address(mainSpawner)
    local mainId = spawnerId(mainSpawner)
    local prefix = encounterPrefix(mainId)
    local seq = seqNumber(mainId)
    local group = mobGroupKey(mainSpawner)
    local bosses = bossClassSet()
    local activated = 0

    for _, s in ipairs(Data.allSpawners()) do
        local loc = U.address(s) ~= mainKey and U.location(s)
        local d = loc and U.dist(loc, center) or math.huge
        if d <= SUPPORT_RADIUS then
            local sid = spawnerId(s)
            local cls = Data.spawnerClass(s)
            local isBoss = cls ~= nil and bosses[string.lower(cls)] == true
            local sameGroup = group ~= nil and mobGroupKey(s) == group
            local sameFamily = (prefix ~= nil and sid ~= "" and string.find(sid, prefix, 1, true) == 1)
                or (seq ~= nil and seqNumber(sid) == seq)
            local use = (sameGroup or sameFamily) and not isBoss
            if use then
                pcall(function() s.ShouldSpawn = true end)
                pcall(function() s.SpawnerSaveInfo.IsAlive = true end)
                local spawned = spawnerLooksSequenced(s) and trySequenceSpawn(s)
                if not spawned then pcall(function() s:Spawn() end) end
                activated = activated + 1
            end
            if d <= SUPPORT_LOG_RADIUS then
                U.log("nearby spawner %s class=%s dist=%.0f group=%s family=%s boss=%s used=%s",
                    sid, tostring(cls), d, tostring(sameGroup), tostring(sameFamily), tostring(isBoss), tostring(use))
            end
        end
    end

    for _, party in ipairs(FindAllOf("PBZMonsterPartySpawner") or {}) do
        if U.valid(party) then
            local loc = U.location(party)
            if loc and U.dist(loc, center) <= 12000 then
                local ok = false
                for _, name in ipairs({ "ActivateMonsterParty", "ActivateParty", "Spawn" }) do
                    local called = pcall(function() party[name](party) end)
                    if called then
                        ok = true
                        U.log("party %s via %s", U.str(party.PartyID), name)
                        break
                    end
                end
                if ok then activated = activated + 1 end
            end
        end
    end

    -- Do NOT Play nearby LevelSequenceActors here. That starts the story fight early
    -- (countdown skipped, boss dragged outside the arena) — seen with 火流星.
    U.log("encounter support activated=%d prefix=%s", activated, tostring(prefix))
end

-- Multi-phase BGM is driven by the game's boss-fight music stage, which the arena sequence
-- normally advances. Rematch skips that sequence, so push the stage ourselves.
local function cheatManager()
    local pc = U.playerController()
    if not U.valid(pc) then return nil end
    local ok, cm = pcall(function() return pc.CheatManager end)
    if ok and U.valid(cm) then return cm end
    local cmClass = StaticFindObject("/Script/ProjectPBZ.PBZCheatManager")
    if U.valid(cmClass) then
        local created = StaticConstructObject(cmClass, pc)
        if U.valid(created) then
            pcall(function() pc.CheatManager = created end)
            return created
        end
    end
    return FindFirstOf("PBZCheatManager")
end

-- Rematch should feel like ringing a Melodious Bell: HP, medicine bottles, quick items,
-- backpack restore — not HP alone.
local function findMelodiousBellNearPlayer()
    local pawnLoc = U.location(U.playerPawn())
    local best, bestDist = nil, math.huge
    for _, cn in ipairs({ "BP_MelodiousBell_C", "MelodiousBell" }) do
        for _, b in ipairs(FindAllOf(cn) or {}) do
            if U.valid(b) then
                local loc = U.location(b)
                local d = (pawnLoc and loc and U.dist(loc, pawnLoc)) or 0
                if d < bestDist then best, bestDist = b, d end
            end
        end
    end
    return best
end

restorePlayerFullHealth = function()
    local pawn = U.playerPawn()
    if not U.valid(pawn) then return end
    restoreActorFullHealth(pawn)
    pcall(function()
        local lib = StaticFindObject("/Script/ProjectPBZ.Default__PBZRestoreQueryLibrary")
        if U.valid(lib) then lib:ResetHealthToMax(pawn) end
    end)
    local cm = cheatManager()
    if U.valid(cm) then
        pcall(function() cm:GM_FullHeal() end)
    end

    local bp = U.worldSubsystem("PBZBackPackSubsystem") or FindFirstOf("PBZBackPackSubsystem")
    if U.valid(bp) then
        pcall(function() bp:RestoreQuickItems() end)
        pcall(function() bp:RestoreShaqiWeaponBullet() end)
        -- Do NOT StartInteractBell here: that opens the bell interaction flow mid-rematch.
    end

    local bell = findMelodiousBellNearPlayer()
    if U.valid(bell) then
        pcall(function() bell:RestoreHealth() end)
        -- Blueprint display name has spaces.
        pcall(function() bell["Restore BackPack Data"](bell) end)
        pcall(function() bell.Restore_BackPack_Data(bell) end)
        -- IsPlaySound=false, IsPushUI=false, IsRestore=true — restore without menu.
        pcall(function() bell:DoInteractNoAnim(false, false, true) end)
        U.log("player bell-like restore via %s", U.fullName(bell))
    else
        U.log("player bell-like restore: no MelodiousBell loaded; heal+quick items only")
    end
end

local function setBossFightMusicStage(stage)
    local audio = U.gameInstanceSubsystem("PBZPersistentAudioSubsystem")
    if audio then
        local ok, err = pcall(function() audio:SetBossFightMusicStageEnabled(true) end)
        U.log("SetBossFightMusicStageEnabled(true) ok=%s %s", tostring(ok), ok and "" or tostring(err))
    else
        U.log("PBZPersistentAudioSubsystem not found")
    end
    local cm = cheatManager()
    if not cm then
        U.log("Gm_SetBossFightMusicStage skipped: no cheat manager")
        return
    end
    local ok, err = pcall(function() cm:Gm_SetBossFightMusicStage(stage) end)
    U.log("Gm_SetBossFightMusicStage(%s) ok=%s %s", tostring(stage), tostring(ok), ok and "" or tostring(err))
    if not ok then
        ok, err = pcall(function() cm:Gm_SetBossFightMusicStage(stage > 0) end)
        U.log("Gm_SetBossFightMusicStage(bool) ok=%s %s", tostring(ok), ok and "" or tostring(err))
    end
end

local NEXT_STAGE_RADIUS = 5000

-- Phases named "<Boss>_P2" are found from the codex. Others, such as 七星剑阵：大师兄 followed by
-- 大师兄的绝望剑意, only show up as the boss spawner of the next story sequence next to this one
-- (Jianou_Seq076 -> Jianou_Seq077, LionDanceBattle_Seq062 -> LionDancerP2_Seq063).
local function nextStageOf(boss)
    local byName = Data.nextStage(boss)
    if byName then return byName end
    local seq = seqNumber(st.spawnerId)
    if not seq or not st.spawnerLoc then return nil end
    local current = string.lower(boss.class)
    for _, s in ipairs(Data.allSpawners()) do
        if seqNumber(spawnerId(s)) == seq + 1 then
            local cls = Data.spawnerClass(s)
            local loc = U.location(s)
            if cls and string.lower(cls) ~= current and loc and U.dist(loc, st.spawnerLoc) <= NEXT_STAGE_RADIUS then
                for _, b in ipairs(Data.bosses()) do
                    if string.lower(b.class) == string.lower(cls) then return b end
                end
            end
        end
    end
    return nil
end

local MUSIC_VOLUME_RADIUS = 15000
local MUSIC_TYPE_COMBAT = 1

local function compact(s)
    return string.lower((string.gsub(tostring(s or ""), "[^%w]", "")))
end

local function arrayItems(arr)
    local items = {}
    pcall(function() arr:ForEach(function(_, elem) table.insert(items, elem:get()) end) end)
    return items
end

-- Softly drop exploration priority so combat can take over. Do NOT ClearMusic: that stops the
-- Wwise playback and SetMusicState alone often leaves silence until the game re-engages naturally.
clearStickyCombatMusic = function()
    local music = U.worldSubsystem("MusicSubsystem")
    if not music then return end
    pcall(function() music:UpdateGameplayMusic(true) end)
    U.log("refreshed gameplay music (no ClearMusic)")
end

-- Score a name match against the stage id.
-- Exact / key-inside-wanted beats wanted-inside-key, so phase-1 "GuiChai_Red" does not
-- pick the longer "GuiChai_Red_P2" entry. Phase-2 ids still prefer their own P2 key.
local function musicMatchScore(wanted, key)
    if key == "" or wanted == "" then return nil end
    if key == wanted then return 2000000 + #key end
    local i, j = string.find(wanted, key, 1, true)
    if i then
        -- Prefer keys that cover the end of wanted (…_P2 matches P2 at the end).
        return 1000000 + j * 1000 + #key
    end
    i, j = string.find(key, wanted, 1, true)
    if i then return 1000 + #wanted end
    return nil
end

-- Arena music volumes map "specific enemy" names to Ak combat states. Setting the state switches
-- the sticky previous-boss track without clearing playback.
applyStageMusic = function(stage)
    local music = U.worldSubsystem("MusicSubsystem")
    local center = st.spawnerLoc
    if not U.saneWorldLoc(center) then
        center = U.location(bossPawn()) or U.location(U.playerPawn())
    end
    if not music or not center then
        U.log("stage music: no music subsystem")
        return
    end
    local wanted = compact(string.gsub(stage.id, "^BP_Monster_", ""))
    local best, bestScore, bestName = nil, -1, nil
    for _, vol in ipairs(FindAllOf("PBZMusicVolume") or {}) do
        local loc = U.location(vol)
        if loc and U.dist(loc, center) <= MUSIC_VOLUME_RADIUS then
            local names = arrayItems(vol.SpecificEnemyNames)
            local states = arrayItems(vol.SpecificMusicState_InCombat)
            local labels = {}
            for i, n in ipairs(names) do
                local name = U.str(n)
                table.insert(labels, name)
                local key = compact(name)
                local score = key ~= "" and musicMatchScore(wanted, key) or nil
                if score and score > bestScore then
                    local state = states[i]
                    if U.valid(state) then
                        best, bestScore, bestName = state, score, name
                    end
                end
            end
            U.log("music volume %s dist=%.0f enemies=[%s]", U.fullName(vol):match("[^%.]+$") or "?", U.dist(loc, center), table.concat(labels, ","))
        end
    end
    if best then
        local ok, err = pcall(function() music:SetMusicState(best, MUSIC_TYPE_COMBAT, true) end)
        U.log("stage music: %s -> %s ok=%s %s", bestName, U.fullName(best), tostring(ok), ok and "" or tostring(err))
        if ok then
            pcall(function() music:UpdateGameplayMusic(false) end)
            return
        end
    end
    pcall(function() music:UpdateGameplayMusic(false) end)
    U.log("stage music: no specific state for %s, asked the game to refresh combat music", stage.id)
end

local function startSpawn(spawner)
    if not st.vetoed then st.vetoed = Save.enterVeto() end
    -- A previous phase's death flag must not carry into this spawn, or the next tick "wins" immediately.
    st.bossDied = false
    st.playerDied = false
    st.spawnerKey, st.spawnerClass = remember(spawner)
    st.spawnerId = spawnerId(spawner)
    st.spawnerLoc = U.location(spawner)
    local hasAI = false
    pcall(function() hasAI = U.valid(spawner.SpawnedAI) and not isDead(spawner.SpawnedAI) end)
    if not hasAI then
        pcall(function() spawner.ShouldSpawn = true end)
        pcall(function() spawner.SpawnerSaveInfo.IsAlive = true end)
        local spawned = false
        if spawnerLooksSequenced(spawner) then
            spawned = trySequenceSpawn(spawner)
        end
        if not spawned then
            local ok, err = pcall(function() spawner:Spawn() end)
            U.log("Spawn() ok=%s %s", tostring(ok), ok and "" or tostring(err))
            spawned = ok
            if not spawned then spawned = trySequenceSpawn(spawner) end
        end
        if not spawned then return abort(L.T("spawn_failed")) end
    end
    activateEncounterSupport(st.spawnerLoc, spawner)
    st.altSpawnTried = false
    setPhase("spawning")
end

-- Spawner found somewhere in the loaded map: either fight here or make one jump next to it.
-- The streaming source stays where it is until the jump lands, so the boss area remains loaded.
local function onSpawnerFound(spawner)
    Data.learnArenas()
    local spawnerLoc = U.location(spawner)
    local pawnLoc = U.location(U.playerPawn())
    -- Soft/unloaded actors and pocket arenas both report huge Z. Pocket arenas (暗魔天堡)
-- are real: stream that region, spawn the boss there, then teleport the player up to it.
    if not U.saneWorldLoc(spawnerLoc) then
        U.log("spawner loc not ground-sane (%.0f, %.0f, %.0f) skyArena=%s",
            spawnerLoc and spawnerLoc.X or 0, spawnerLoc and spawnerLoc.Y or 0,
            spawnerLoc and spawnerLoc.Z or 0, tostring(U.isSkyArenaLoc(spawnerLoc)))
        if U.isSkyArenaLoc(spawnerLoc) then
            st.skyArenaHop = true
            st.finalHop = true
            Streaming.moveTo(spawnerLoc)
            U.log("sky arena: spawning in pocket Z=%.0f; player will teleport in after AI exists", spawnerLoc.Z)
            return startSpawn(spawner)
        end
        if not st.skyApproachDone then
            local bell = Data.nearestBell(st.boss.map, spawnerLoc)
            if bell and pawnLoc and U.horizDist(pawnLoc, bell.loc) > NEAR_BOSS_RADIUS then
                st.skyApproachDone = true
                U.log("soft spawner: approaching nearest bell %s (horiz=%.0f)",
                    bell.id, U.horizDist(pawnLoc, bell.loc))
                local transform = U.bellTravelTransform(bell) or bell.transform
                local ok, err = travel(st.level, transform, bell.id)
                if not ok then return abort(err) end
                return
            end
        end
        U.log("soft spawner: spawning after XY approach (or already near)")
        Streaming.clear()
        return startSpawn(spawner)
    end
    if st.finalHop or U.dist(spawnerLoc, pawnLoc) <= NEAR_BOSS_RADIUS then
        Streaming.clear()
        return startSpawn(spawner)
    end
    local bell = Data.nearestBell(st.boss.map, spawnerLoc)
    local transform = approachTransform(spawnerLoc, (bell and bell.loc) or pawnLoc, APPROACH_DISTANCE)
    U.log("boss spawner found %.0f away, jumping next to it", U.dist(spawnerLoc, pawnLoc))
    local ok, err = travel(st.level, transform, bell and bell.id or st.travel.bell)
    if not ok then
        -- Spawn from here rather than abort under a black curtain; placePlayerNearBoss
        -- will pull the player in once AI exists.
        U.log("onSpawnerFound hop failed: %s; spawn in place", tostring(err))
        Streaming.moveTo(spawnerLoc)
        st.finalHop = true
        return startSpawn(spawner)
    end
    st.finalHop = true
end

local function spawnerCount()
    return #Data.allSpawners()
end

local function hopToCachedArena()
    local arena = Data.arena(st.boss.id)
    if not arena or arena.unsupported or not arena.x or arena.z == nil then return false end
    local arenaLoc = { X = arena.x, Y = arena.y, Z = arena.z }
    if U.isSkyArenaLoc(arenaLoc) then
        -- Single sky entry is placePlayerNearBoss before countdown — not here.
        st.skyArenaHop = true
        U.log("skip hopToCachedArena for sky pocket; enter once before countdown")
        return false
    end
    if not U.saneWorldLoc(arenaLoc) then
        U.log("skip hopToCachedArena: unusable coords z=%s", tostring(arena.z))
        return false
    end
    local pawnLoc = U.location(U.playerPawn())
    if not pawnLoc then return false end
    if U.dist(pawnLoc, arenaLoc) <= NEAR_BOSS_RADIUS then
        st.finalHop = true
        return false
    end
    -- One attempt only. A failed hop used to clear finalHop and retry every tick under the
    -- black curtain (seen with 亡命徒：荆野: K2_TeleportTo moved=false for a minute+).
    if st.cachedHopTried then
        Streaming.moveTo(arenaLoc)
        st.finalHop = true
        return false
    end
    st.cachedHopTried = true
    local bell = (arena.bell ~= "" and Data.bellById(arena.bell)) or Data.nearestBell(st.boss.map, arenaLoc)
    local transform = approachTransform(arenaLoc, (bell and bell.loc) or pawnLoc, APPROACH_DISTANCE)
    if not U.saneWorldLoc(transform.Translation) then
        U.log("skip hopToCachedArena: approach transform not sane")
        st.finalHop = true
        return false
    end
    U.log("cached arena %.0f away, jumping next to it", U.dist(pawnLoc, arenaLoc))
    local ok, err = travel(st.level, transform, bell and bell.id or st.travel.bell)
    if not ok then
        U.log("hopToCachedArena failed: %s; stream arena and continue locating", tostring(err))
        Streaming.moveTo(arenaLoc)
        st.finalHop = true
        return false
    end
    st.finalHop = true
    return true
end

local function findBossSpawner()
    if Data.findSpawnerForBoss then
        return Data.findSpawnerForBoss(st.boss)
    end
    return Data.findSpawner(st.boss.class)
end

local function skyPocketLoc()
    local arena = Data.arena(st.boss.id)
    if not arena or not arena.x or arena.z == nil then return nil, arena end
    local loc = { X = arena.x, Y = arena.y, Z = arena.z }
    -- Only real high-Z pockets. Ignore a stale skyArena flag on ground / soft junk coords.
    if U.isSkyArenaLoc(loc) then return loc, arena end
    return nil, arena
end

local function livingBossNear(center, radius)
    radius = radius or 25000
    local best, bestDist = nil, math.huge
    for _, a in ipairs(FindAllOf(st.boss.class) or {}) do
        local loc = U.location(a)
        if U.valid(a) and not isDead(a) and loc and U.saneWorldLoc(loc) then
            local d = center and U.dist(loc, center) or 0
            if d < radius and d < bestDist then best, bestDist = a, d end
        end
    end
    return best
end

-- 拳痴：铁狂 fights when the player drops into the clearing. ClaimSeq on RenTuZi_Ice alone
-- never loads BP_Monster_LuanShi. Only poke the family MobGroup + nearest MobDomain —
-- never ActivateAllGroups / LevelSequence:Play (those hard-crash).
local function pulseSeqEncounterTriggers(center, familyName)
    local pawn = U.playerPawn()
    if not U.valid(pawn) or not center then return end

    for _, s in ipairs(Data.findSeqFamilySpawners(st.boss) or {}) do
        local group = nil
        pcall(function() group = s.MobGroup end)
        if U.valid(group) then
            pcall(function() group:Activate() end)
            pcall(function() group:OnActorEnterDomain(pawn) end)
            U.log("seq family: MobGroup:Activate from %s", spawnerId(s))
        end
    end

    local best, bestDist = nil, math.huge
    for _, cn in ipairs({ "BP_MobDomain_C", "MobDomain" }) do
        for _, d in ipairs(FindAllOf(cn) or {}) do
            local loc = U.location(d)
            if U.valid(d) and loc then
                local dist = U.dist(loc, center)
                if dist < bestDist and dist <= 12000 then
                    best, bestDist = d, dist
                end
            end
        end
    end
    if U.valid(best) then
        pcall(function() best:OnTriggerEnteredEvent(pawn) end)
        if familyName and familyName ~= "" then
            pcall(function() best:ActivateGroup(familyName) end)
        end
        U.log("seq family: pulsed nearest MobDomain dist=%.0f %s", bestDist, U.fullName(best))
    end
end

local function adoptSeqFamilyBoss(boss)
    if not (U.valid(boss) and not isDead(boss)) then return false end
    if not bossLocUsable(U.location(boss)) then
        if not rescueSoftBossToPlayer(boss) then return false end
        boss = bossPawn() or boss
    end
    if Config.LoadingCurtain ~= false then Curtain.cover() end
    setBoss(boss)
    st.spawnerLoc = U.location(boss) or st.seqFamilyLoc
    st.frozenKey, st.frozenClass = st.bossKey, st.bossClass
    hardFreezeBoss(boss)
    placePlayerNearBoss()
    dismissEarlyNextStage()
    st.revealArmed = false
    setPhase("preparing")
    loadingToast(L.T("positioning"))
    return true
end

local function tickSeqFamilyLocating()
    local familyName = Data.bossSeqFamily and Data.bossSeqFamily(st.boss)
    if not familyName then return false end
    if Config.LoadingCurtain ~= false then setPlayerTransitFrozen(true) end

    if not st.seqFamilyStarted then
        local family = Data.findSeqFamilySpawners(st.boss)
        if #family == 0 then
            if not st.seqFamilyWaitLogged then
                st.seqFamilyWaitLogged = true
                U.log("seq family %s: no ground spawners yet near arena", familyName)
            end
            if elapsed() < SEQ_FAMILY_TIMEOUT_S then
                local arena = Data.arena(st.boss.id)
                if arena and arena.x then
                    Streaming.moveTo({ X = arena.x, Y = arena.y, Z = arena.z })
                end
                return true
            end
            return false
        end
        local anchor = nil
        for _, s in ipairs(family) do
            local loc = U.location(s)
            if loc and U.saneWorldLoc(loc) then
                anchor = loc
                break
            end
        end
        if not anchor then
            local arena = Data.arena(st.boss.id)
            if arena and arena.x then
                anchor = { X = arena.x, Y = arena.y, Z = arena.z }
            else
                anchor = U.location(family[1])
            end
        end
        st.seqFamilyLoc = anchor
        st.seqFamilyStarted = true
        st.seqFamilyAt = os.clock()
        Streaming.moveTo(anchor)
        loadingToast(L.T("triggering_seq"))
        U.log("seq family %s: ClaimSeqSpawn %d spawner(s) at (%.0f, %.0f, %.0f)",
            familyName, #family, anchor.X, anchor.Y, anchor.Z)
        for _, s in ipairs(family) do
            local sid = spawnerId(s)
            local cls = Data.spawnerClass(s)
            U.log("seq family member %s class=%s", sid, tostring(cls))
            if spawnerLooksSequenced(s) then
                trySequenceSpawn(s)
            else
                pcall(function() s:Spawn() end)
            end
        end
        pulseSeqEncounterTriggers(anchor, familyName)
        return true
    end

    local waited = os.clock() - (st.seqFamilyAt or os.clock())
    if waited < 1.0 then return true end
    if not Streaming.idle() and waited < SEQ_FAMILY_TIMEOUT_S then return true end

    local spawner = findBossSpawner()
    if spawner then
        st.finalHop = true
        onSpawnerFound(spawner)
        return true
    end

    local living = livingBossNear(st.seqFamilyLoc)
    if living and adoptSeqFamilyBoss(living) then
        U.log("seq family: living boss near arena")
        return true
    end
    local raw = findLivingBossRaw()
    if raw and adoptSeqFamilyBoss(raw) then
        U.log("seq family: living boss (raw/soft) adopted")
        return true
    end

    if waited < SEQ_FAMILY_TIMEOUT_S then
        if math.floor(waited) ~= (st.seqFamilyNudge or -1) and math.floor(waited) % 4 == 0 then
            st.seqFamilyNudge = math.floor(waited)
            local family = Data.findSeqFamilySpawners(st.boss)
            for _, s in ipairs(family) do
                if spawnerLooksSequenced(s) then trySequenceSpawn(s) end
                pcall(function() s:Spawn() end)
            end
            pulseSeqEncounterTriggers(st.seqFamilyLoc, familyName)
            if st.seqFamilyLoc then Streaming.moveTo(st.seqFamilyLoc) end
        end
        return true
    end

    Streaming.clear()
    abort(L.T("seq_arena_fail", st.boss.name))
    return true
end

-- Sky-pocket bosses (暗魔天堡 / 龙柱): keep the player on the ground bell under the curtain,
-- stream the pocket in, then spawn. Do not teleport into soft Z≈2e6 junk (false sky coords).
local function tickSkyLocating(skyLoc, arena)
    st.skyArenaHop = true
    if Config.LoadingCurtain ~= false then setPlayerTransitFrozen(true) end
    if not st.skyStreamStarted then
        st.skyStreamStarted = true
        st.skyStreamAt = os.clock()
        Streaming.moveTo(skyLoc)
        loadingToast(L.T("loading_sky"))
        U.log("sky locate: streaming pocket Z=%.0f bell=%s id=%s",
            skyLoc.Z, tostring(arena and arena.bell), st.boss.id)
        return
    end
    local waited = os.clock() - (st.skyStreamAt or os.clock())
    if waited < 1.5 then return end
    if not Streaming.idle() and elapsed() < SKY_LOCATE_TIMEOUT_S then
        if math.floor(waited) ~= (st.skyStreamNudge or -1) and math.floor(waited) % 3 == 0 then
            st.skyStreamNudge = math.floor(waited)
            Streaming.moveTo(skyLoc)
        end
        return
    end

    local spawner = findBossSpawner()
    if spawner then
        st.finalHop = true
        return onSpawnerFound(spawner)
    end

    for _, a in ipairs(FindAllOf(st.boss.class) or {}) do
        local loc = U.location(a)
        if U.valid(a) and not isDead(a) and U.isSkyArenaLoc(loc) then
            U.log("sky locate: living boss already in pocket")
            if Config.LoadingCurtain ~= false then Curtain.cover() end
            setBoss(a)
            st.spawnerLoc = loc
            st.frozenKey, st.frozenClass = st.bossKey, st.bossClass
            hardFreezeBoss(a)
            placePlayerNearBoss()
            dismissEarlyNextStage()
            st.revealArmed = false
            setPhase("preparing")
            loadingToast(L.T("positioning"))
            return
        end
    end

    if elapsed() < SKY_LOCATE_TIMEOUT_S then return end
    Streaming.clear()
    -- Never markUnsupported: ground scans cannot see these spawners.
    return abort(L.T("sky_arena_fail", st.boss.name))
end

-- Objects in regions that are still loading or unloading must not be touched, so every
-- spawner lookup waits until the engine reports that streaming has settled.
local function tickLocating()
    local skyLoc, arena = skyPocketLoc()
    if skyLoc then return tickSkyLocating(skyLoc, arena) end

    local settled = elapsedS() >= LOCATE_SETTLE_S and Streaming.idle()
    if not settled and elapsed() < LOCATE_TIMEOUT_S then return end
    -- Known boss spot: one short hop next to it, instead of scanning every bell on the map.
    if not st.finalHop and hopToCachedArena() then return end

    -- 拳痴：铁狂 etc.: MobDomain / Seq* family before class-matched spawner (often missing).
    if Data.bossSeqFamily and Data.bossSeqFamily(st.boss) then
        if tickSeqFamilyLocating() then return end
    end

    local spawner = findBossSpawner()
    if spawner then return onSpawnerFound(spawner) end

    -- skyInvalid without usable Z: ground scanning will never find the pocket spawner.
    if Data.isSkyArenaBoss and Data.isSkyArenaBoss(st.boss) then
        return abort(L.T("sky_coords_missing", st.boss.name))
    end

    Streaming.clear()
    st.scanQueue = {}
    for _, b in ipairs(st.mapBells) do
        if U.dist(b.loc, st.travel.loc) > NEAR_BOSS_RADIUS then table.insert(st.scanQueue, b) end
    end
    st.scanTotal = #st.scanQueue
    st.stepAt = nil
    st.finalHop = false
    st.scanBaseSpawners = spawnerCount()
    st.scanLoadedMore = false
    setPhase("scanning")
end

local function markUnsupportedIfGroundBoss()
    if Data.isSkyArenaBoss and Data.isSkyArenaBoss(st.boss) then
        U.log("skip unsupported mark for sky/sequence boss %s", st.boss.id)
        return false
    end
    if Data.bossSeqFamily and Data.bossSeqFamily(st.boss) then
        U.log("skip unsupported mark for seq-family boss %s", st.boss.id)
        return false
    end
    Data.markUnsupported(st.boss)
    return true
end

local function nextScanStep()
    local bell = table.remove(st.scanQueue, 1)
    if not bell then
        Streaming.clear()
        -- Only remember "unsupported" when the scan provably loaded other regions;
        -- otherwise the failure says nothing about this boss.
        if st.scanLoadedMore then
            markUnsupportedIfGroundBoss()
            return abort(L.T("unsupported_no_spawner", st.boss.name))
        end
        return abort(L.T("stream_fail", st.boss.name))
    end
    local ok, err = Streaming.moveTo(bell.loc)
    if not ok then
        U.log("streaming source failed: %s", tostring(err))
        Streaming.clear()
        return abort(L.T("locate_stream_fail"))
    end
    st.stepAt = os.time()
    local done = st.scanTotal - #st.scanQueue
    U.log("scanning region %d/%d near %s", done, st.scanTotal, bell.id)
    Toast.show(L.T("locating", st.boss.name, done, st.scanTotal), 4000)
end

local function tickScanning()
    if not st.stepAt then return nextScanStep() end
    local since = os.time() - st.stepAt
    if since < SCAN_SETTLE_S then return end
    if not Streaming.idle() then
        if since >= SCAN_STEP_TIMEOUT_S then
            U.log("region still streaming after %ds, skipping", since)
            return nextScanStep()
        end
        return
    end
    local spawner = findBossSpawner()
    if spawner then return onSpawnerFound(spawner) end
    local count = spawnerCount()
    if count ~= st.scanBaseSpawners then st.scanLoadedMore = true end
    U.log("region settled after %ds, %d spawners loaded (at arrival %d)", since, count, st.scanBaseSpawners or -1)
    Data.learnArenas()
    -- When moving the streaming source loads nothing new, the whole map is already resident
    -- and every spawner was checked, so the boss is simply not spawned by an AI spawner here.
    local scanned = st.scanTotal - #st.scanQueue
    if not st.scanLoadedMore and scanned >= SCAN_STABLE_REGIONS and Data.unresolvedSpawnerCount() == 0 then
        Streaming.clear()
        U.log("map fully loaded (%d spawners, all resolved), boss has no spawner here", count)
        markUnsupportedIfGroundBoss()
        return abort(L.T("unsupported_no_map_spawner", st.boss.name))
    end
    nextScanStep()
end

-- Keep the player inside the fight volume. 700uu is often still outside walled arenas
-- (seen with 暗魔天堡 / 魔渊); prefer a tight offset on solid ground only.
local PLACE_NEAR_DISTANCES = { 180, 280, 400, 550, 700, 1000 }

-- Only teleport the player once before countdown. beginFight / pull must not move them again.
placePlayerNearBoss = function()
    if st.playerPlaced then
        faceEachOther(U.playerPawn(), bossPawn())
        return true
    end
    local pawn = U.playerPawn()
    local boss = bossPawn()
    local bossLoc = U.location(boss)
    local p = U.location(pawn)
    if not pawn or not bossLoc or not p then return false end
    if not U.teleportAllowedLoc(bossLoc) then
        U.log("placePlayerNearBoss: boss loc not allowed (%.0f, %.0f, %.0f)",
            bossLoc.X, bossLoc.Y, bossLoc.Z)
        return false
    end
    st.spawnerLoc = bossLoc
    if U.isSkyArenaLoc(bossLoc) then
        Streaming.moveTo(bossLoc)
        U.log("placePlayerNearBoss: entering sky arena at Z=%.0f", bossLoc.Z)
    end
    local function finishPlace(at)
        st.playerPlaced = true
        -- Always the stand point in front of the boss (same Z). Do NOT use ground-bell
        -- XY projected into the sky pocket — that lands hundreds of meters away.
        st.skyRespawnLoc = { X = at.X, Y = at.Y, Z = bossLoc.Z }
        faceEachOther(pawn, boss)
        Data.rememberArenaLoc(st.rootBoss or st.boss, bossLoc, st.spawnerId)
        return true
    end
    if U.horizDist(p, bossLoc) <= PLACE_NEAR_DISTANCES[1] + 50
        and math.abs((p.Z or 0) - bossLoc.Z) < 80 then
        return finishPlace({ X = p.X, Y = p.Y, Z = bossLoc.Z })
    end
    for _, d in ipairs(PLACE_NEAR_DISTANCES) do
        local xf, yaw = approachTransform(bossLoc, p, d)
        xf.Translation.Z = bossLoc.Z
        if U.teleportAllowedLoc(xf.Translation) then
            local rot = { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }
            local ok, moved = pcall(function() return pawn:K2_TeleportTo(xf.Translation, rot) end)
            if ok and moved then
                pcall(function() U.playerController():SetControlRotation(rot) end)
                U.log("player placed %.0f from boss at (%.0f, %.0f, %.0f)",
                    d, xf.Translation.X, xf.Translation.Y, xf.Translation.Z)
                return finishPlace(xf.Translation)
            end
        end
    end
    U.log("could not place player near boss")
    return false
end

-- If the encounter sequence left the boss outside the fight volume, pull it next to the player.
-- Never pull a real sky-arena boss down — send the player up instead.
-- Soft junk locs (Z≈2e6) are rescued onto the player's ground footing.
local function pullBossToPlayer()
    local pawn = U.playerPawn()
    local boss = bossPawn() or findLivingBossRaw()
    local p = U.location(pawn)
    local b = boss and U.location(boss)
    if not U.valid(boss) or not p then return false end
    if U.isSkyArenaLoc(b) then
        setBoss(boss)
        return placePlayerNearBoss()
    end
    if not U.saneWorldLoc(p) then
        U.log("pullBossToPlayer skipped: player loc bad")
        return false
    end
    if not b or not U.saneWorldLoc(b) then
        return rescueSoftBossToPlayer(boss)
    end
    if U.dist(p, b) <= PLACE_NEAR_DISTANCES[#PLACE_NEAR_DISTANCES] then
        setBoss(boss)
        faceEachOther(pawn, boss)
        return true
    end
    -- Do not drag a distant special-arena boss across the map to a wrong bell.
    if U.dist(p, b) > 12000 then
        U.log("pullBossToPlayer skipped: boss %.0f away (place player instead)", U.dist(p, b))
        return false
    end
    local xf, yaw = approachTransform(p, b, APPROACH_DISTANCE)
    if not U.saneWorldLoc(xf.Translation) then return false end
    -- approachTransform(target=player, from=boss) puts a point near the player; teleport the boss there.
    local rot = { Pitch = 0.0, Yaw = yaw + 180.0, Roll = 0.0 }
    local ok, moved = pcall(function() return boss:K2_TeleportTo(xf.Translation, rot) end)
    U.log("pull boss to player ok=%s moved=%s distWas=%.0f", tostring(ok), tostring(moved), U.dist(p, b))
    if ok and moved then
        setBoss(boss)
        st.spawnerLoc = xf.Translation
        setFrozen(boss, true)
        faceEachOther(pawn, boss)
        return true
    end
    return false
end

local function tickSpawning()
    local spawner = U.live(st.spawnerClass, st.spawnerKey)
    local ai = nil
    if spawner then pcall(function() ai = spawner.SpawnedAI end) end
    if not (U.valid(ai) and not isDead(ai)) then
        ai = findLivingBossRaw()
    end
    if U.valid(ai) and not isDead(ai) then
        setBoss(ai)
        -- Hold black until freeze + place + streaming settle, then reveal into countdown.
        if Config.LoadingCurtain ~= false then Curtain.cover() end
        -- Freeze BEFORE bringing the player in, or the boss swings during the hop
        -- (seen with 暗魔天堡 attacking before countdown).
        st.frozenKey, st.frozenClass = st.bossKey, st.bossClass
        setFrozen(ai, true)
        local bloc = U.location(ai)
        if U.teleportAllowedLoc(bloc) then
            st.spawnerLoc = bloc
            Data.rememberArenaLoc(st.rootBoss or st.boss, bloc, st.spawnerId)
        else
            -- Soft / junk Z: pull boss to the player before placePlayerNearBoss.
            rescueSoftBossToPlayer(ai)
            ai = bossPawn() or ai
        end
        local placed = placePlayerNearBoss()
        if not placed then pullBossToPlayer() end
        setFrozen(ai, true)
        faceEachOther(U.playerPawn(), ai)
        dismissEarlyNextStage()
        st.revealArmed = false
        setPhase("preparing")
        loadingToast(L.T("positioning"))
        return
    end
    if not st.altSpawnTried and elapsed() > ALT_SPAWN_AFTER_S and spawner then
        st.altSpawnTried = true
        trySequenceSpawn(spawner)
    end
    if elapsed() > SPAWN_TIMEOUT_S then
        abort(st.rootBoss and L.T("boss_missing_named", st.boss.name) or L.T("boss_missing_end"))
    end
end

-- Remember addresses of next-phase actors we discarded so transition never adopts them.
local function noteVetoedNext(key)
    if not key then return end
    if not st.vetoedNextKeys then st.vetoedNextKeys = {} end
    st.vetoedNextKeys[key] = true
end

-- Drop next-phase actors that the encounter sequence brought in early.
-- 火流星 keeps GuiChai_Red_P2 in the same fight; adopting that leftover when P1 dies
-- marks the rematch complete before a real P2 fight starts.
local function dismissStageActors(stage, tag)
    if not stage then return 0 end
    local removed = 0
    for _, a in ipairs(FindAllOf(stage.class) or {}) do
        if U.valid(a) and not isDead(a) then
            local key = U.address(a)
            noteVetoedNext(key)
            local spawner = Data.findSpawner(stage.class)
            local viaSpawner = false
            if spawner then
                pcall(function()
                    if U.address(spawner.SpawnedAI) == key then
                        spawner:Despawn()
                        viaSpawner = true
                    end
                end)
            end
            if not viaSpawner then pcall(function() a:K2_DestroyActor() end) end
            removed = removed + 1
            U.log("%s %s removed (spawner=%s)", tag or "early", stage.id, tostring(viaSpawner))
        end
    end
    return removed
end

-- A level sequence started for the encounter can bring the next phase in early; it must only
-- appear once the current phase is down.
dismissEarlyNextStage = function()
    local nxt = nextStageOf(st.boss)
    if not nxt then return end
    dismissStageActors(nxt, "early")
end

local function beginFight()
    if st.phase ~= "countdown" then return end
    U.log("beginFight (%s sky=%s)", st.boss and st.boss.id or "?", tostring(st.skyArenaHop))
    dismissEarlyNextStage()
    local boss = bossPawn()
    if boss and isDead(boss) then boss = nil end
    if not boss then boss = reacquireBoss() end
    if not boss then boss = respawnBossForRematch() or reacquireBoss() end
    if not (boss and not isDead(boss) and bossLocUsable(U.location(boss))) then
        U.log("beginFight: no living boss after countdown, aborting")
        return abort(L.T("boss_spawn_fail_end"))
    end
    setBoss(boss)
    st.frozenKey, st.frozenClass = st.bossKey, st.bossClass
    -- Do not teleport again here — placement already happened once before countdown.
    faceEachOther(U.playerPawn(), boss)
    unfreezeBoss()
    -- Sky pocket: player stayed transit-frozen (zero-g) through countdown; release only now.
    setPlayerTransitFrozen(false)
    st.bossDied = false
    st.playerDied = false
    st.missingBossSince = nil
    st.victoryRematchSpawn = nil
    -- After a death-rematch the engine may briefly lose the boss handle; don't false-victory.
    -- Real kills still win (grace only helps when a living boss can be reacquired).
    if st.rematchAfterDefeat then
        st.fightGraceUntil = os.clock() + 8
        st.rematchAfterDefeat = nil
        U.log("fight grace armed for %.0fs after defeat-rematch", 8)
    else
        st.fightGraceUntil = nil
    end
    setPhase("fighting")
    Toast.show(L.T("fight_start", st.boss.name), 2000)
    -- Always set this boss's track. Otherwise the previous rematch's combat music keeps playing
    -- through phase 1 (seen with 舞狮尊主 still on 雷婷 / 剑欧's BGM).
    applyStageMusic(st.boss)
end

-- Numbers are driven by timers rather than the 300 ms tick so each one lasts a full second.
local function startCountdown()
    local seconds = math.floor(tonumber(Config.CountdownSeconds) or 3)
    setPhase("countdown")
    if seconds <= 0 then return beginFight() end
    local id = os.time() .. "-" .. tostring(math.random(1, 1e6))
    st.countdownId = id
    for i = 0, seconds do
        U.delay(i * 1000, "challenge.countdown", function()
            if st.phase ~= "countdown" or st.countdownId ~= id then return end
            if i < seconds then
                Toast.show(L.T("countdown", st.boss.name, seconds - i), 1100)
            else
                beginFight()
            end
        end)
    end
end

-- The boss stays frozen behind the black screen until the world around it has finished streaming in.
local function tickPreparing()
    local boss = bossPawn()
    if boss and isDead(boss) then boss = nil end
    if boss and not bossLocUsable(U.location(boss)) then
        if rescueSoftBossToPlayer(boss) then
            boss = bossPawn() or boss
        else
            boss = nil
        end
    end
    if not boss then boss = reacquireBoss() end
    if not boss then
        local raw = findLivingBossRaw()
        if raw then
            if bossLocUsable(U.location(raw)) then
                setBoss(raw)
                boss = raw
            elseif rescueSoftBossToPlayer(raw) then
                boss = bossPawn() or raw
            end
        end
    end
    -- Post-victory rematch: never adopt the corpse; keep ClaimSeqSpawn until a living AI appears.
    if (not boss or isDead(boss)) and st.victoryRematchSpawn then
        if not st.victorySpawnAt or (os.clock() - st.victorySpawnAt) >= 0.8 then
            st.victorySpawnAt = os.clock()
            boss = respawnBossForRematch()
            U.log("preparing: victoryRematchSpawn retry")
        end
    end
    -- SpawnedAI can report a soft (0,0,0) shell for a beat after the player hops in
    -- (seen with 追命：六绝凶镰 → instant "Boss 加载失败" while cleanup still found a living AI).
    if not boss and elapsedS() >= 1.0 then
        boss = ensureBossForRematch()
    end
    if not boss or isDead(boss) then
        if elapsed() < PREPARE_TIMEOUT_S then
            if not st.prepareMissingLogged then
                st.prepareMissingLogged = true
                U.log("preparing: boss not usable yet; waiting up to %ds", PREPARE_TIMEOUT_S)
            end
            return
        end
        st.victoryRematchSpawn = nil
        return abort(L.T("boss_load_failed"))
    end
    st.victoryRematchSpawn = nil
    st.prepareMissingLogged = nil
    if st.rematchAfterDefeat and not st.playerHealedForRematch then
        st.playerHealedForRematch = true
        restorePlayerFullHealth()
    end
    -- The freeze slot is keyed by pawn + controller, so a reattached controller already gets a
    -- full pass. Forcing one every tick re-ran StopAI / PauseLogic / StopMovement 3x a second.
    if not controllerOf(boss) then
        hardFreezeBoss(boss)
    else
        setFrozen(boss, true)
    end
    st.frozenKey, st.frozenClass = st.bossKey, st.bossClass
    if st.revealArmed then return end
    local minS = (st.skyArenaHop or U.isSkyArenaLoc(U.location(boss))) and PREPARE_MIN_SKY_S or PREPARE_MIN_S
    local ready = elapsedS() >= minS and Streaming.idle()
    if not ready and elapsed() < PREPARE_TIMEOUT_S then return end
    U.log("arena ready after %.1fs (streaming idle=%s)", elapsedS(), tostring(Streaming.idle()))
    dismissEarlyNextStage()
    -- Re-seat if the boss was soft during the first place, or if we respawned mid-prepare.
    if not st.playerPlaced or U.horizDist(U.location(U.playerPawn()), U.location(boss)) > PLACE_NEAR_DISTANCES[#PLACE_NEAR_DISTANCES] then
        st.playerPlaced = false
        placePlayerNearBoss()
    end
    faceEachOther(U.playerPawn(), boss)
    st.revealArmed = true
    -- At Z≈1e6–1e7 sky pockets (暗魔天堡), restoring Walking+gravity before countdown
    -- can void-fall / native-crash before beginFight. Keep transit freeze until fight starts.
    local skyHold = st.skyArenaHop or U.isSkyArenaLoc(U.location(boss))
    if skyHold then
        st.skyArenaHop = true
        setPlayerTransitFrozen(true)
        U.log("sky arena: holding player zero-g through countdown")
    else
        setPlayerTransitFrozen(false)
    end
    Curtain.reveal(REVEAL_FADE_S)
    local id = os.time() .. "-" .. tostring(math.random(1, 1e6))
    st.prepareRevealId = id
    U.delay(COUNTDOWN_AFTER_REVEAL_MS, "challenge.prepareReveal", function()
        if st.phase ~= "preparing" or st.prepareRevealId ~= id then return end
        startCountdown()
    end)
end

local function tickCountdown()
    local boss = bossPawn()
    if not boss or isDead(boss) or not bossLocUsable(U.location(boss)) then
        boss = reacquireBoss()
    end
    if (not boss or isDead(boss)) and st.rematchAfterDefeat then
        boss = respawnBossForRematch() or reacquireBoss()
    end
    if boss and not isDead(boss) then
        -- No AI controller ⇒ previous freeze was a soft shell; force full StopAI pass.
        if not controllerOf(boss) then
            hardFreezeBoss(boss)
        else
            setFrozen(boss, true)
        end
        st.frozenKey, st.frozenClass = st.bossKey, st.bossClass
    end
    if st.skyArenaHop then
        -- Re-assert zero-g; reveal/other systems may flip movement mode back on.
        local pawn = U.playerPawn()
        pcall(function()
            local move = pawn and pawn.CharacterMovement
            if U.valid(move) then
                move.GravityScale = 0
                pcall(function() move:SetMovementMode(0) end)
            end
        end)
    end
    -- Sequence leftovers of the next phase must stay gone for the whole countdown.
    dismissEarlyNextStage()
end

-- Rematch skips some story LevelSequences / AIScripts that normally push「斩」.
-- Force the same UI the game uses: BP_GameplayHelper.Push BossDeadUI.
local BOSS_DEAD_CLASS_PATH = "/Game/PBZContent/UI/InGame/Dead/W_BossDead.W_BossDead_C"
local BOSS_DEAD_RED_CLASS_PATH = "/Game/PBZContent/UI/InGame/Dead/W_BossDead_Red.W_BossDead_Red_C"
local GAMEPLAY_HELPER_CDO = "/Game/PBZContent/Blueprint/BP_GameplayHelper.Default__BP_GameplayHelper_C"
local PUSH_BOSS_DEAD_FN = "/Game/PBZContent/Blueprint/BP_GameplayHelper.BP_GameplayHelper_C:Push BossDeadUI"
local BOSS_DEAD_WIDGET_CLASSES = { "W_BossDead_C", "W_BossDead_Red_C", "W_BossDeadRed_C" }

local cachedBossDeadClass = nil
local cachedBossDeadRedClass = nil
local cachedGameplayHelper = nil

function M.cacheBossDeadWidget(widget)
    if not U.valid(widget) then return end
    local ok, cls = pcall(function() return widget:GetClass() end)
    if not (ok and U.valid(cls)) then return end
    local name = U.className(widget)
    if name == "W_BossDead_Red_C" or name == "W_BossDeadRed_C" then
        cachedBossDeadRedClass = cls
    else
        cachedBossDeadClass = cls
    end
    U.log("cached %s class: %s", name, U.fullName(cls))
end

local function findGameplayHelper()
    if U.valid(cachedGameplayHelper) then return cachedGameplayHelper end
    local tries = {
        function() return StaticFindObject(GAMEPLAY_HELPER_CDO) end,
        function() return FindFirstOf("BP_GameplayHelper_C") end,
        function() return FindObject("BlueprintFunctionLibrary", "Default__BP_GameplayHelper_C") end,
        function() return FindObject(nil, "Default__BP_GameplayHelper_C") end,
    }
    for _, fn in ipairs(tries) do
        local ok, obj = pcall(fn)
        if ok and U.valid(obj) then
            cachedGameplayHelper = obj
            U.log("found BP_GameplayHelper: %s", U.fullName(obj))
            return obj
        end
    end
    return nil
end

local function bossDeadWidgetCount()
    local n = 0
    for _, cls in ipairs(BOSS_DEAD_WIDGET_CLASSES) do
        for _, w in ipairs(FindAllOf(cls) or {}) do
            if U.valid(w) then n = n + 1 end
        end
    end
    return n
end

local function clearBossDeadWidgets()
    local n = 0
    for _, cls in ipairs(BOSS_DEAD_WIDGET_CLASSES) do
        for _, w in ipairs(FindAllOf(cls) or {}) do
            if U.valid(w) then
                pcall(function() w:DeactivateWidget() end)
                pcall(function() w:RemoveFromParent() end)
                n = n + 1
            end
        end
    end
    if n > 0 then U.log("cleared %d leftover BossDead widget(s)", n) end
end

local function resolveBossDeadClass(useRed)
    if useRed and U.valid(cachedBossDeadRedClass) then return cachedBossDeadRedClass end
    if not useRed and U.valid(cachedBossDeadClass) then return cachedBossDeadClass end
    local path = useRed and BOSS_DEAD_RED_CLASS_PATH or BOSS_DEAD_CLASS_PATH
    local ok, cls = pcall(function() return StaticFindObject(path) end)
    if ok and U.valid(cls) then
        if useRed then cachedBossDeadRedClass = cls else cachedBossDeadClass = cls end
        return cls
    end
    local short = useRed and "W_BossDead_Red_C" or "W_BossDead_C"
    ok, cls = pcall(function() return FindObject("WidgetBlueprintGeneratedClass", short) end)
    if ok and U.valid(cls) then
        if useRed then cachedBossDeadRedClass = cls else cachedBossDeadClass = cls end
        return cls
    end
    for _, w in ipairs(FindAllOf(short) or {}) do
        if U.valid(w) then
            local okc, c = pcall(function() return w:GetClass() end)
            if okc and U.valid(c) then
                if useRed then cachedBossDeadRedClass = c else cachedBossDeadClass = c end
                return c
            end
        end
    end
    if useRed then return resolveBossDeadClass(false) end
    return nil
end

local function pushBossDeadViaHelper(useRed)
    local helper = findGameplayHelper()
    local ctx = U.playerController() or U.playerPawn()
    if not U.valid(helper) or not U.valid(ctx) then return false end
    local red = useRed and true or false

    -- Spaced BP names often aren't exposed as Lua functions; try ProcessEvent first.
    local okFn, ufn = pcall(function() return StaticFindObject(PUSH_BOSS_DEAD_FN) end)
    if okFn and U.valid(ufn) then
        local ok, err = pcall(function()
            helper:ProcessEvent(ufn, {
                ["Use BossDead_Red"] = red,
                Use_BossDead_Red = red,
                __WorldContext = ctx,
            })
        end)
        if ok then
            U.log("Push BossDeadUI via ProcessEvent red=%s", tostring(red))
            return true
        end
        U.log("ProcessEvent Push BossDeadUI failed: %s", tostring(err))
    else
        U.log("Push BossDeadUI UFunction not found")
    end

    for _, name in ipairs({ "Push BossDeadUI", "PushBossDeadUI", "Push_BossDeadUI" }) do
        local ok, err = pcall(function()
            local f = helper[name]
            if f == nil then error("nil " .. name) end
            f(helper, red, ctx)
        end)
        if ok then
            U.log("Push BossDeadUI via index %s red=%s", name, tostring(red))
            return true
        end
        U.log("call %s failed: %s", name, tostring(err))
    end
    return false
end

local function pushBossDeadFallback(useRed)
    local cls = resolveBossDeadClass(useRed)
    if not U.valid(cls) then
        U.log("BossDead fallback: class not loaded yet")
        return false
    end
    local pc = U.playerController()
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not U.valid(pc) or not U.valid(wbl) then return false end
    local ok, w = pcall(function() return wbl:Create(pc, cls, pc) end)
    if not ok or not U.valid(w) then
        U.log("BossDead fallback create failed: %s", tostring(w))
        return false
    end
    pcall(function() w:SetVisibility(0) end) -- Visible
    pcall(function() w:AddToViewport(2000) end)
    pcall(function() w:SetAlignmentInViewport({ X = 0.5, Y = 0.5 }) end)
    pcall(function()
        local wll = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local size = wll:GetViewportSize(pc)
        w:SetPositionInViewport({ X = size.X * 0.5, Y = size.Y * 0.5 }, true)
    end)
    pcall(function() w:ActivateWidget() end)
    pcall(function() w:BP_OnActivated() end)
    pcall(function()
        local ns = w.NS_BossKill
        if U.valid(ns) then
            ns:ActivateSystem(true)
            U.log("NS_BossKill ActivateSystem ok")
        end
    end)
    -- Keep a short-lived reference path only via address lookup later; schedule cleanup.
    local key = U.address(w)
    local clsName = U.className(w)
    U.delay(4500, "challenge.bossDeadClear", function()
        local live = U.live(clsName, key)
        if live then
            pcall(function() live:DeactivateWidget() end)
            pcall(function() live:RemoveFromParent() end)
        end
    end)
    U.log("BossDead fallback widget pushed (%s)", U.fullName(cls))
    return true
end

local function showBossKillBanner(useRed)
    -- The game often pushes「斩」itself on the final kill. Clearing and re-pushing made it flash twice.
    if bossDeadWidgetCount() > 0 then
        U.log("BossDead already on screen, skip push")
        return true
    end
    if st.bossDeadPushing then return false end
    st.bossDeadPushing = true
    if pushBossDeadViaHelper(useRed) then
        -- Helper may create the widget a tick later; only fall back if nothing appears.
        U.delay(300, "challenge.bossDeadCheck", function()
            st.bossDeadPushing = nil
            if bossDeadWidgetCount() == 0 then
                U.log("helper Push produced no widget; fallback once")
                pushBossDeadFallback(useRed)
            end
        end)
        return true
    end
    st.bossDeadPushing = nil
    return pushBossDeadFallback(useRed)
end

-- Victory rematch (optional PostFightChoice): MUST ClaimSeqSpawn a fresh boss.
-- After「斩」the old SpawnedAI often still reports IsDead=false for a beat; reusing it
-- freezes a corpse that then vanishes during countdown (seen with 新娘阿花).
local function rematchAfterVictory()
    if st.phase ~= "choosing" and st.phase ~= "fighting" then
        U.log("rematchAfterVictory ignored (phase=%s)", tostring(st.phase))
        return
    end
    EndChoice.hide()
    clearBossDeadWidgets()
    st.bossDied = false
    st.playerDied = false
    st.fightGraceUntil = nil
    st.missingBossSince = nil
    st.countdownId = nil
    st.prepareRevealId = nil
    st.playerPlaced = false
    st.revealArmed = false
    st.rematchAfterDefeat = true
    st.victoryRematchSpawn = true
    st.playerHealedForRematch = nil
    st.bossKey, st.bossClass = nil, nil
    st.frozenKey, st.frozenClass = nil, nil
    Toast.show(L.T("rematch_again", (st.rootBoss or st.boss).name or ""), 3000)
    U.log("post-fight rematch: force respawn + countdown")
    if Config.LoadingCurtain ~= false then Curtain.cover() end
    setPlayerTransitFrozen(true)

    U.delay(200, "challenge.victoryRematch", function()
        if st.phase == "ending" or st.phase == "reloading" or st.phase == "idle" then return end
        local boss = respawnBossForRematch()
        if not (boss and not isDead(boss) and bossLocUsable(U.location(boss))) then
            -- Sequence spawn can lag; preparing will keep retrying while victoryRematchSpawn.
            U.log("victory rematch: spawn not ready yet, entering preparing to retry")
            setPhase("preparing")
            loadingToast(L.T("spawning_boss"))
            return
        end
        st.victoryRematchSpawn = nil
        restoreActorFullHealth(boss)
        hardFreezeBoss(boss)
        st.frozenKey, st.frozenClass = st.bossKey, st.bossClass
        restorePlayerFullHealth()
        st.playerPlaced = false
        placePlayerNearBoss()
        faceEachOther(U.playerPawn(), boss)
        setPhase("preparing")
    end)
end

local function victory()
    showBossKillBanner(false)
    local name = (st.rootBoss or st.boss).name
    -- Default (F8 off): same as before — toast then restore saves / return to bell.
    if not EndChoice.isEnabled() then
        Toast.show(L.T("victory_return", name), Config.VictoryReturnDelayMs)
        return returnToStart("victory", Config.VictoryReturnDelayMs)
    end

    Toast.show(L.T("victory", name), 3000)
    setPhase("choosing")
    unfreezeBoss()
    setPlayerTransitFrozen(false)
    local delayMs = math.max(500, tonumber(Config.PostFightChoiceDelayMs) or 2500)
    local token = os.clock()
    st.choiceToken = token
    U.log("post-fight choice armed in %dms", delayMs)
    U.delay(delayMs, "challenge.postFightChoice", function()
        if st.phase ~= "choosing" or st.choiceToken ~= token then return end
        local ok = EndChoice.show({
            bossName = name,
            onRematch = rematchAfterVictory,
            onQuit = function()
                Toast.show(L.T("quitting_return"), 3000)
                returnToStart("victory", 800)
            end,
        })
        if not ok then
            Toast.show(L.T("victory_return", name), Config.VictoryReturnDelayMs)
            returnToStart("victory", Config.VictoryReturnDelayMs)
        end
    end)
end

local function livePawnOf(boss)
    for _, a in ipairs(FindAllOf(boss.class) or {}) do
        if U.valid(a) and not isDead(a) then
            local key = U.address(a)
            -- Never reuse a next-phase actor we already discarded (火流星 P2 leftover).
            if not (st.vetoedNextKeys and st.vetoedNextKeys[key]) then
                return a
            end
        end
    end
    return nil
end

local function enterStage(stage, pawn)
    clearBossDeadWidgets()
    if Config.LoadingCurtain ~= false then Curtain.cover() end
    st.boss = stage
    setBoss(pawn)
    st.bossDied = false
    st.playerDied = false
    st.playerPlaced = false
    st.revealArmed = false
    st.transitionReminded = nil
    st.transitionClearedEarly = nil
    st.vetoedNextKeys = nil
    st.musicStage = (st.musicStage or 0) + 1
    setBossFightMusicStage(st.musicStage)
    st.frozenKey, st.frozenClass = st.bossKey, st.bossClass
    setFrozen(pawn, true)
    U.log("stage %s is up (preparing under curtain)", stage.id)
    Toast.show(L.T("next_stage", stage.name), 3000)
    setPhase("preparing")
end

-- After a phase dies the game may run its own transition; give it a moment, then spawn the next phase ourselves.
-- The death performance plays out first, then the screen fades to black so the old body is never
-- seen next to the new phase.
local function tickTransition()
    local stage = st.nextStage
    -- Drop any P2 that was already in the arena with P1. Adopting it immediately is what
    -- made 火流星 jump to "挑战成功" one second after P1 died.
    if not st.transitionClearedEarly then
        st.transitionClearedEarly = true
        local n = dismissStageActors(stage, "transition-leftover")
        U.log("transition: cleared %d leftover %s before wait", n, stage.id)
    end
    -- Slow loads (e.g. 七星阵大师兄 P2) look like a hang; keep reminding the player.
    if not st.transitionReminded and elapsed() >= STAGE_FADE_AT_S then
        st.transitionReminded = true
        Toast.show(L.T("next_stage_loading", stage.name), 10000)
    end
    if elapsed() >= STAGE_FADE_AT_S and Config.LoadingCurtain ~= false then Curtain.fadeOut(STAGE_FADE_S) end
    -- Do not adopt a live P2 until the wait ends — dying leftovers can still report IsDead=false.
    if elapsed() < STAGE_WAIT_S then return end
    local pawn = livePawnOf(stage)
    if pawn then return enterStage(stage, pawn) end
    local body = U.live(st.deadClass, st.deadKey)
    if body then
        pcall(function() body:SetActorHiddenInGame(true) end)
        U.log("previous stage body hidden")
    end
    st.deadKey, st.deadClass = nil, nil
    local spawner = Data.findSpawner(stage.class)
    if not spawner then
        U.log("no spawner for %s, finishing after %s", stage.id, st.boss.id)
        return victory()
    end
    U.log("spawning next stage %s", stage.id)
    clearBossDeadWidgets()
    st.rootBoss = st.rootBoss or st.boss
    st.boss = stage
    st.bossDied = false
    st.vetoedNextKeys = nil
    st.musicStage = (st.musicStage or 0) + 1
    setBossFightMusicStage(st.musicStage)
    startSpawn(spawner)
end

local function playerDeadWidgetCount()
    local n = 0
    for _, w in ipairs(FindAllOf("W_PlayerDead_C") or {}) do
        if U.valid(w) then
            local hidden = false
            pcall(function()
                local vis = w:GetVisibility()
                -- ESlateVisibility: Collapsed=1, Hidden=2
                if vis == 1 or vis == 2 then hidden = true end
            end)
            if not hidden then n = n + 1 end
        end
    end
    return n
end

local function clearPlayerDeadWidgets()
    local n = 0
    for _, w in ipairs(FindAllOf("W_PlayerDead_C") or {}) do
        if U.valid(w) then
            pcall(function() w:DeactivateWidget() end)
            pcall(function() w:RemoveFromParent() end)
            n = n + 1
        end
    end
    if n > 0 then U.log("cleared %d leftover PlayerDead widget(s)", n) end
end

-- Stand on the boss's XY plane, `distance` in front (from `from` toward boss).
local function frontOfBossLoc(bossLoc, from, distance)
    if not bossLoc then return nil end
    from = from or { X = bossLoc.X + 200, Y = bossLoc.Y, Z = bossLoc.Z }
    local xf = approachTransform(bossLoc, from, distance or 180)
    return { X = xf.Translation.X, Y = xf.Translation.Y, Z = bossLoc.Z }
end

-- After player death the live boss actor often reports a bogus near-origin location.
-- Prefer remembered sky-pocket / spawner coords so we never fall out of 暗魔天堡.
local function resolveDefeatBossLoc()
    local live = U.location(bossPawn())
    if st.skyArenaHop then
        if live and U.isSkyArenaLoc(live) then return live, "live" end
        if st.spawnerLoc and U.isSkyArenaLoc(st.spawnerLoc) then return st.spawnerLoc, "spawner" end
        local arena = Data.arena((st.rootBoss or st.boss).id)
        if arena and arena.x and arena.z then
            local a = { X = arena.x, Y = arena.y, Z = arena.z }
            if U.isSkyArenaLoc(a) then return a, "arenaCache" end
        end
        if st.skyRespawnLoc and U.isSkyArenaLoc(st.skyRespawnLoc) then
            -- Approximate boss as "a step past" the previous stand point toward cache XY.
            return {
                X = st.skyRespawnLoc.X - 100,
                Y = st.skyRespawnLoc.Y - 50,
                Z = st.skyRespawnLoc.Z,
            }, "skyRespawnApprox"
        end
        return live, "liveFallback"
    end
    if live and U.teleportAllowedLoc(live) then return live, "live" end
    if st.spawnerLoc and U.teleportAllowedLoc(st.spawnerLoc) then return st.spawnerLoc, "spawner" end
    return live or st.spawnerLoc, "any"
end

local function pickDefeatStandLoc(bossLoc)
    if not bossLoc or not U.teleportAllowedLoc(bossLoc) then return nil end
    if st.skyArenaHop and not U.isSkyArenaLoc(bossLoc) then return nil end
    if st.skyRespawnLoc and U.teleportAllowedLoc(st.skyRespawnLoc) then
        local zOk = (not st.skyArenaHop) or U.isSkyArenaLoc(st.skyRespawnLoc)
        if zOk and U.horizDist(st.skyRespawnLoc, bossLoc) < 2500 then
            return { X = st.skyRespawnLoc.X, Y = st.skyRespawnLoc.Y, Z = bossLoc.Z }
        end
    end
    local from = st.skyRespawnLoc or { X = bossLoc.X + 200, Y = bossLoc.Y, Z = bossLoc.Z }
    for _, d in ipairs(PLACE_NEAR_DISTANCES) do
        local cand = frontOfBossLoc(bossLoc, from, d)
        if cand and U.teleportAllowedLoc(cand) then
            if (not st.skyArenaHop) or U.isSkyArenaLoc(cand) then
                return cand
            end
        end
    end
    return nil
end

local function tickFighting()
    -- Keep sequence-spawned next phases out of the arena during the current phase.
    dismissEarlyNextStage()

    -- Player death has priority: freeze boss during 陨落, then rematch (never false-victory).
    if st.playerDied then
        st.unfreezeUntil = nil
        local hold = bossPawn()
        if not hold or not bossLocUsable(U.location(hold)) then
            hold = reacquireBoss()
        end
        if hold then hardFreezeBoss(hold) end
        if not st.defeatUiWaitAt then
            st.defeatUiWaitAt = os.clock()
            st.fightGraceUntil = nil
            U.log("waiting %.1fs for 陨落 UI before rematch", (tonumber(Config.DefeatUiMs) or 5500) / 1000)
            return
        end
        local need = (tonumber(Config.DefeatUiMs) or 5500) / 1000
        if (os.clock() - st.defeatUiWaitAt) < need then
            return
        end
        return rematchOnDefeat()
    end

    local boss = bossPawn()
    -- Soft-rescued bosses (e.g. 炎如 spawner Z≈2e6) can log as released but stay frozen;
    -- reassert for a short window after beginFight.
    if boss and not isDead(boss) and st.unfreezeUntil and os.clock() < st.unfreezeUntil then
        forceUnfreezeBoss(boss)
    elseif st.unfreezeUntil and os.clock() >= st.unfreezeUntil then
        st.unfreezeUntil = nil
    end
    if not boss or isDead(boss) then
        local again = reacquireBoss()
        if again and not isDead(again) then
            boss = again
            st.bossDied = false
            U.log("tickFighting: recovered living boss after missing/dead handle")
        end
    end

    -- Grace only suppresses FALSE downs (missing handle while a living boss can be found).
    -- Real kills (bossDied / IsDead with no living reacquire) must still win/transition.
    if st.fightGraceUntil and os.clock() < st.fightGraceUntil then
        if not boss or isDead(boss) then
            local again = reacquireBoss()
            if again and not isDead(again) then
                U.log("fight grace: living boss recovered, ignore false down")
                st.bossDied = false
                return
            end
            if not st.bossDied and not boss then
                U.log("fight grace: boss missing without death event, waiting")
                return
            end
            -- Real death signal with no living boss → fall through.
        end
    end

    local bossDown = st.bossDied or (boss and isDead(boss))
    if bossDown then
        local nextStage = nextStageOf(st.boss)
        if nextStage then
            U.log("%s down, waiting for %s", st.boss.id, nextStage.id)
            showBossKillBanner(false)
            st.rootBoss = st.rootBoss or st.boss
            st.nextStage = nextStage
            st.deadKey, st.deadClass = st.bossKey, st.bossClass
            st.bossKey, st.bossClass = nil, nil
            st.bossDied = false
            st.fightGraceUntil = nil
            st.transitionReminded = nil
            st.transitionClearedEarly = nil
            Toast.show(L.T("next_stage_soon", nextStage.name), 12000)
            return setPhase("transition")
        end
        st.fightGraceUntil = nil
        return victory()
    end

    -- Missing boss without a death signal is NOT a win (was causing false「斩」after rematch).
    if not boss then
        U.log("tickFighting: boss handle missing, trying reacquire")
        if not reacquireBoss() then
            if st.missingBossSince == nil then st.missingBossSince = os.clock() end
            if os.clock() - st.missingBossSince > 8 then
                st.missingBossSince = nil
                return abort(L.T("boss_lost_end"))
            end
        else
            st.missingBossSince = nil
        end
        return
    end
    st.missingBossSince = nil
end

-- After any rematch death: revive in front of the boss and start countdown again.
-- Leaving the challenge still uses quit / abort / victory -> returnToStart.
rematchOnDefeat = function()
    if st.defeatRetrying then return end
    st.defeatRetrying = true
    st.playerDied = false
    st.defeatUiWaitAt = nil
    Toast.show(L.T("defeat_respawn"), 4000)
    U.log("rematch defeat: respawn in front of boss, then countdown")
    if Config.LoadingCurtain ~= false then Curtain.cover() end
    clearPlayerDeadWidgets()

    U.delay(200, "challenge.defeatRetry", function()
        if st.phase == "ending" or st.phase == "reloading" or st.phase == "idle" then
            st.defeatRetrying = false
            return
        end
        local pawn = U.playerPawn()
        -- Must be the real sky/arena boss — soft (0,0,0) shells freeze nothing visible.
        local boss = ensureBossForRematch()
        if not boss then
            -- Sequence spawn may need a moment; one more try after a short wait is handled
            -- by staying in preparing only if we already have a boss. Here we abort.
            boss = respawnBossForRematch() or reacquireBoss()
        end
        if not (boss and not isDead(boss) and bossLocUsable(U.location(boss))) then
            U.log("defeat rematch: still no usable boss after respawn")
            st.defeatRetrying = false
            Toast.show(L.T("defeat_return"), Config.DefeatReturnDelayMs)
            return returnToStart("defeat", Config.DefeatReturnDelayMs)
        end
        if Config.LoadingCurtain ~= false then Curtain.cover() end

        restoreActorFullHealth(boss)
        st.bossDied = false
        st.playerDied = false
        st.fightGraceUntil = nil
        st.missingBossSince = nil
        st.countdownId = nil
        st.prepareRevealId = nil
        st.rematchAfterDefeat = true
        st.playerHealedForRematch = nil
        st.frozenKey, st.frozenClass = st.bossKey, st.bossClass
        hardFreezeBoss(boss)
        local bloc = U.location(boss)
        U.log("defeat rematch boss frozen at (%.0f,%.0f,%.0f) hasController=%s",
            bloc and bloc.X or 0, bloc and bloc.Y or 0, bloc and bloc.Z or 0,
            tostring(controllerOf(boss) ~= nil))

        local bossLoc, locSrc = resolveDefeatBossLoc()
        local liveNow = U.location(boss)
        U.log("defeat bossLoc src=%s live=(%.0f,%.0f,%.0f) resolved=(%.0f,%.0f,%.0f) skyHop=%s",
            tostring(locSrc),
            liveNow and liveNow.X or 0, liveNow and liveNow.Y or 0, liveNow and liveNow.Z or 0,
            bossLoc and bossLoc.X or 0, bossLoc and bossLoc.Y or 0, bossLoc and bossLoc.Z or 0,
            tostring(st.skyArenaHop))

        local dest = pickDefeatStandLoc(bossLoc)
        if not dest then
            U.log("defeat: no valid stand loc (skyHop=%s), aborting rematch", tostring(st.skyArenaHop))
            st.defeatRetrying = false
            Toast.show(L.T("defeat_return"), Config.DefeatReturnDelayMs)
            return returnToStart("defeat", Config.DefeatReturnDelayMs)
        end

        -- Zero-g before the hop so a bad frame cannot void-fall out of the pocket.
        setPlayerTransitFrozen(true)
        if U.isSkyArenaLoc(dest) then
            Streaming.moveTo(dest)
            st.skyArenaHop = true
        end

        local rot = { Pitch = 0.0, Yaw = yawFacing(dest, bossLoc or dest), Roll = 0.0 }
        local ok, moved = pcall(function() return pawn:K2_TeleportTo(dest, rot) end)
        pcall(function() U.playerController():SetControlRotation(rot) end)
        st.playerPlaced = true
        st.skyRespawnLoc = dest
        U.log("defeat respawn ok=%s moved=%s at (%.0f, %.0f, %.0f)",
            tostring(ok), tostring(moved), dest.X, dest.Y, dest.Z)

        restorePlayerFullHealth()
        hardFreezeBoss(boss)
        faceEachOther(pawn, boss)
        st.defeatRetrying = false
        st.revealArmed = false
        setPhase("preparing")
        Toast.show(L.T("rematch_again", st.boss.name), 3000)
    end)
end

-- After rematch, land at the melodious bell next to this boss — never at the menu
-- start bell if that ID belongs to another map (localTeleport of foreign XY = fall death).
local function bossReturnBell()
    local boss = st.rootBoss or st.boss
    if not boss then return nil end
    local arena = Data.arena(boss.id)
    if arena and arena.bell and arena.bell ~= "" then
        local b = Data.bellById(arena.bell)
        if b and U.saneWorldLoc(b.loc) then return b end
    end
    local loc = nil
    if arena and arena.x and arena.y then
        loc = { X = arena.x, Y = arena.y, Z = arena.z or 0 }
    elseif st.spawnerLoc then
        loc = st.spawnerLoc
    end
    if loc then
        local b = Data.nearestBell(boss.map, loc)
        if b and U.saneWorldLoc(b.loc) then return b end
    end
    for _, b in ipairs(Data.bellsInMap(boss.map) or {}) do
        if U.saneWorldLoc(b.loc) then return b end
    end
    return nil
end

local function pickSafeQuitBell()
    local bossBell = bossReturnBell()
    local avoidId = bossBell and bossBell.id
    local boss = st.rootBoss or st.boss
    local mapId = boss and boss.map
    local start = st.startBell and st.startBell ~= "" and Data.bellById(st.startBell) or nil
    if start and U.saneWorldLoc(start.loc) and start.id ~= avoidId then
        return start, "start bell"
    end
    local origin = (start and start.loc)
        or (bossBell and bossBell.loc)
        or st.spawnerLoc
        or U.location(U.playerPawn())
    if mapId then
        local alt = alternateBellAwayFrom(mapId, avoidId, origin)
        if alt then
            U.log("quit bell: avoiding arena %s → %s", tostring(avoidId), alt.id)
            return alt, "safe quit bell"
        end
    end
    if start and U.saneWorldLoc(start.loc) then
        return start, "start bell (same as arena)"
    end
    return bossBell, "boss bell fallback"
end

-- After quit, kill any living rematch-class AI near the player / arena so the
-- vanilla encounter volume cannot immediately re-aggro at the return point.
local function suppressBossAfterQuit(bossInfo)
    if not (bossInfo and bossInfo.class) then return end
    local here = U.location(U.playerPawn())
    local arena = Data.arena(bossInfo.id)
    local arenaLoc = arena and arena.x and { X = arena.x, Y = arena.y, Z = arena.z or 0 } or st.spawnerLoc
    local function nearThreat(loc)
        if not loc or U.isSoftWorldLoc(loc) then return false end
        if here and U.dist(loc, here) < 12000 then return true end
        if arenaLoc and U.teleportAllowedLoc(arenaLoc) and U.dist(loc, arenaLoc) < 12000 then return true end
        if U.isSkyArenaLoc(loc) then return true end
        return false
    end
    for _, a in ipairs(FindAllOf(bossInfo.class) or {}) do
        local loc = U.location(a)
        if nearThreat(loc) and not isDead(a) then
            hardFreezeBoss(a)
            pcall(function() a:SetActorHiddenInGame(true) end)
            pcall(function() a:K2_DestroyActor() end)
            U.log("quit suppress: destroyed leftover %s", bossInfo.class)
        end
    end
    local spawner = Data.findSpawner and Data.findSpawner(bossInfo.class) or nil
    if U.valid(spawner) then
        pcall(function() spawner:Despawn() end)
        pcall(function() spawner.ShouldSpawn = false end)
        pcall(function()
            if spawner.SpawnerSaveInfo then spawner.SpawnerSaveInfo.IsAlive = false end
        end)
        U.log("quit suppress: disabled spawner for %s", bossInfo.class)
    end
end

-- Returns ok, moved. `moved` means the pawn was teleported in this world and the ground there
-- may not be streamed in yet.
local function snapToBell(bell, tag)
    if not bell then
        U.log("snap to %s: no bell", tag or "bell")
        return false
    end
    local xf = U.bellTravelTransform(bell) or bell.transform
    if not (xf and U.saneWorldLoc(xf.Translation)) then
        U.log("snap to %s %s refused: bad transform", tag or "bell", tostring(bell.id))
        return false
    end
    local here = U.location(U.playerPawn())
    if here and U.dist(here, xf.Translation) < ARRIVAL_RADIUS then
        U.log("already at %s %s", tag or "bell", bell.id)
        return true
    end
    local level = Data.levelNameForBell(bell.id) or ((st.rootBoss or st.boss) and (st.rootBoss or st.boss).map)
    if level and not inLevel(level) then
        local sub = saveSub()
        if not sub then return false end
        local ok, err = pcall(function() sub:TeleportTo(FName(level), xf, FName(bell.id)) end)
        U.log("snap to %s %s via TeleportTo ok=%s %s", tag or "bell", bell.id, tostring(ok), ok and "" or tostring(err))
        -- TeleportTo always needs a landing settle (second return); a single `ok` made
        -- finishReload skip landing and reveal mid–World Partition.
        return ok, ok and true or nil
    end
    -- Gravity off before the jump: the destination cells load after the pawn gets there.
    setPlayerTransitFrozen(true)
    local ok = localTeleport(xf)
    U.log("snap to %s %s ok=%s at (%.0f, %.0f, %.0f)", tag or "bell", bell.id, tostring(ok),
        xf.Translation.X, xf.Translation.Y, xf.Translation.Z)
    return ok, ok
end

local function snapToBossBell()
    return snapToBell(bossReturnBell(), "boss bell")
end

-- Quit / abort: go back to a safe start bell (never the fight arena if avoidable). Victory: boss nearby bell.
local function snapToFinishBell()
    if st.endReason == "quit" or st.endReason == "abort" or st.endReason == "error" or st.endReason == "recover" then
        local bell, tag = pickSafeQuitBell()
        if bell then
            return snapToBell(bell, tag)
        end
        U.log("safe quit bell unavailable; falling back to boss bell")
    end
    return snapToBossBell()
end

finishReload = function()
    if st.phase ~= "reloading" and st.phase ~= "ending" then
        -- Still force a reveal if a prior timeout left the curtain stuck.
        if Curtain.isCovered() then
            setPlayerTransitFrozen(false)
            Curtain.reveal(0.8)
        end
        return
    end
    U.log("=== challenge finished (%s), returning to bell", tostring(st.endReason))
    Save.clearState()
    -- Soft loads often leave the pawn at the arena; put them on the chosen ground bell.
    -- pcall → okCall, snapOk, needsLanding
    local okCall, snapOk, needsLanding = pcall(snapToFinishBell)
    if okCall and snapOk and needsLanding then
        -- Revealing right after a long jump dropped the player through ground that had not
        -- loaded yet. Stay black and weightless until streaming there has finished.
        setPhase("landing")
        st.landingIdleTicks = 0
        return
    end
    if not okCall then
        U.log("snapToFinishBell error: %s", tostring(snapOk))
    end
    completeReturn()
end

local LANDING_MIN_S = 1.0
local LANDING_IDLE_TICKS = 2
local LANDING_TIMEOUT_S = 15

completeReturn = function()
    local reason = st.endReason
    local bossInfo = st.rootBoss or st.boss
    if reason == "quit" or reason == "abort" or reason == "error" or reason == "recover" then
        pcall(function() suppressBossAfterQuit(bossInfo) end)
    end
    setPlayerTransitFrozen(false)
    Curtain.reveal(0.8)
    st = { phase = "idle" }
    -- Defer arena rescans so they do not stack on top of the load hitch.
    U.delay(5000, "challenge.postReloadLearn", function()
        if st.phase == "idle" then pcall(function() Data.learnArenas() end) end
    end)
    U.delay(1500, "challenge.backToast", function()
        if reason == "victory" then
            Toast.show(L.T("done_near_boss_bell"), 3000)
        elseif reason == "quit" then
            Toast.show(L.T("done_start_bell"), 3000)
        else
            Toast.show(L.T("done_returned"), 3000)
        end
    end)
end

-- Streaming can report idle for a moment right after the jump, before the new cells are
-- requested, so idle has to hold over consecutive ticks.
local function tickLanding()
    setPlayerTransitFrozen(true)
    if Streaming.idle() then
        st.landingIdleTicks = (st.landingIdleTicks or 0) + 1
    else
        st.landingIdleTicks = 0
    end
    local ready = elapsedS() >= LANDING_MIN_S and st.landingIdleTicks >= LANDING_IDLE_TICKS
    if not ready and elapsedS() < LANDING_TIMEOUT_S then return end
    U.log("landed after %.1fs (streaming idle=%s)", elapsedS(), tostring(Streaming.idle()))
    completeReturn()
end

local function nearReturnBell()
    local bell
    if st.endReason == "quit" or st.endReason == "abort" or st.endReason == "error" or st.endReason == "recover" then
        bell = pickSafeQuitBell()
    else
        bell = bossReturnBell() or (st.startBell and Data.bellById(st.startBell))
    end
    local here = U.location(U.playerPawn())
    return bell and here and U.saneWorldLoc(bell.loc) and U.dist(here, bell.loc) < ARRIVAL_RADIUS
end

local function reloadLocMoved()
    local before, now = st.reloadLoc, U.location(U.playerPawn())
    return before and now and U.dist(before, now) > 500
end

-- Loading a slot inside the same world may keep the pawn at the same address and fire no
-- map-load event, so arrival back at the start bell / a moved pawn also counts.
local function tickReloading()
    local addr = pawnAddress()
    if not addr then st.reloadPawnGone = true end
    if os.time() - (st.reloadLogAt or 0) >= 3 then
        st.reloadLogAt = os.time()
        U.log("reloading %ds: pawn=%s (before %s) gone=%s nearReturn=%s moved=%s", elapsed(), tostring(addr),
            tostring(st.reloadPawn), tostring(st.reloadPawnGone == true), tostring(nearReturnBell() == true),
            tostring(reloadLocMoved() == true))
    end
    local reason = nil
    if addr and addr ~= st.reloadPawn then reason = "new pawn"
    elseif addr and st.reloadPawnGone then reason = "pawn back"
    elseif addr and elapsed() >= RELOAD_MIN_S and nearReturnBell() then reason = "at boss bell"
    elseif addr and elapsed() >= RELOAD_MIN_S and reloadLocMoved() then reason = "pawn moved"
    end
    if reason and elapsed() > 2 then
        st.reloadSeenAt = st.reloadSeenAt or os.time()
        if os.time() - st.reloadSeenAt >= 2 then
            U.log("reload detected: %s", reason)
            return finishReload()
        end
    else
        st.reloadSeenAt = nil
    end
    -- Soft loads often never change pawn address; do not leave the curtain stuck.
    if elapsed() >= RELOAD_MIN_S + 3 then
        U.log("reload settled after %ds without clear signal, finishing", elapsed())
        return finishReload()
    end
    if elapsed() > RELOAD_TIMEOUT_S then
        U.log("reload not detected within %ds, finishing anyway", RELOAD_TIMEOUT_S)
        return finishReload()
    end
end

-- Opening a bell menu means the player is back in control, which ends any pending reload.
function M.onBellMenuOpen()
    if st.phase ~= "reloading" then return end
    U.log("reload detected: bell menu opened")
    finishReload()
end

function M.tick()
    local p = st.phase
    -- Never keep a black curtain after the challenge has ended.
    if p == "idle" then
        if Curtain.isCovered() then
            setPlayerTransitFrozen(false)
            Curtain.reveal(0.3)
        end
        return
    end
    -- Camera fade during WP transition hard-crashes; only re-hold when streaming is idle
    -- (or outside travel/reload phases).
    if Curtain.holdAllowed() then
        local transit = (p == "traveling" or p == "departing" or p == "reloading")
        if (not transit) or Streaming.idle() then
            Curtain.hold()
        end
    end
    if p == "traveling" then tickTraveling()
    elseif p == "locating" then tickLocating()
    elseif p == "scanning" then tickScanning()
    elseif p == "spawning" then tickSpawning()
    elseif p == "preparing" then tickPreparing()
    elseif p == "countdown" then tickCountdown()
    elseif p == "fighting" then tickFighting()
    elseif p == "transition" then tickTransition()
    elseif p == "choosing" then EndChoice.tick()
    elseif p == "reloading" then tickReloading()
    elseif p == "landing" then tickLanding()
    end
end

function M.onEnemyDied(character)
    if st.phase ~= "fighting" then return end
    if st.bossKey and U.address(character) == st.bossKey then
        U.log("boss died")
        st.bossDied = true
    end
end

function M.onPlayerDeadWidget()
    local p = st.phase
    if st.defeatRetrying then
        U.log("ignore PlayerDead during defeatRetrying")
        return
    end
    if p == "fighting" then
        U.log("player died")
        st.playerDied = true
        return
    end
    -- Mid-setup fall (common if death left the pawn outside the sky pocket): re-seat, don't abort.
    if (p == "preparing" or p == "countdown") and st.skyArenaHop then
        U.log("player died during sky setup; re-placing into pocket")
        clearPlayerDeadWidgets()
        setPlayerTransitFrozen(true)
        local bossLoc = select(1, resolveDefeatBossLoc())
        local dest = pickDefeatStandLoc(bossLoc) or st.skyRespawnLoc
        local pawn = U.playerPawn()
        if pawn and dest and U.isSkyArenaLoc(dest) then
            Streaming.moveTo(dest)
            local rot = { Pitch = 0.0, Yaw = yawFacing(dest, bossLoc or dest), Roll = 0.0 }
            pcall(function() pawn:K2_TeleportTo(dest, rot) end)
            pcall(function()
                if pawn.RestoreFullHealth then pawn:RestoreFullHealth() end
            end)
            st.skyRespawnLoc = dest
            U.log("re-placed after mid-setup death at (%.0f, %.0f, %.0f)", dest.X, dest.Y, dest.Z)
        end
        return
    end
    if p == "transition" or p == "spawning" or p == "preparing" or p == "countdown"
        or p == "locating" or p == "scanning" or p == "traveling" then
        U.log("player died")
        st.playerDied = true
        returnToStart("defeat", Config.DefeatReturnDelayMs)
    end
end

function M.onMapLoaded()
    -- Do not SetManualCameraFade from LoadMap PostHook unless streaming is idle —
    -- same crash class as holding fade mid–World Partition travel.
    if Curtain.holdAllowed() and Streaming.idle() then
        Curtain.hold()
    end
    if st.phase == "reloading" then
        U.log("map loaded while reloading")
    end
end

-- Last-resort exit when the challenge logic keeps failing: get the player back with the save restored.
function M.forceEnd(reason)
    if st.phase == "idle" or st.phase == "ending" or st.phase == "reloading" then return end
    if st.phase == "landing" then return completeReturn() end
    EndChoice.hide()
    U.log("force end: %s", tostring(reason))
    Toast.show(L.T("error_returning"), 4000)
    returnToStart("error", 1500)
end

function M.quit()
    if st.phase == "idle" then return end
    if st.phase == "ending" or st.phase == "reloading" or st.phase == "landing" then return end
    -- Cancel defeat-rematch / post-fight choice timers so they cannot restart after quit.
    EndChoice.hide()
    st.playerDied = false
    st.defeatRetrying = false
    st.defeatUiWaitAt = nil
    st.countdownId = nil
    st.prepareRevealId = nil
    st.choiceToken = nil
    Toast.show(L.T("quitting_return"), 3000)
    returnToStart("quit", 800)
end

function M.togglePostFightChoice()
    return EndChoice.toggle()
end

function M.killBoss()
    local boss = bossPawn()
    if st.phase ~= "fighting" or not boss then return end
    local geKill = FindObject("BlueprintGeneratedClass", "GE_Kill_C")
    local asl = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
    if not U.valid(geKill) or not U.valid(asl) then
        U.log("kill: GE_Kill_C or AbilitySystemBlueprintLibrary missing")
        return
    end
    local target = asl:GetAbilitySystemComponent(boss)
    local source = asl:GetAbilitySystemComponent(U.playerPawn())
    local ok, err = pcall(function()
        source:BP_ApplyGameplayEffectToTarget(geKill, target, 1.0, source:MakeEffectContext())
    end)
    U.log("kill boss ok=%s %s", tostring(ok), ok and "" or tostring(err))
    if ok then st.bossDied = true end
end

-- Called once on mod start: a leftover state file means the game closed mid-challenge.
function M.recoverIfNeeded()
    local state = Save.readState()
    if not state or not state.active then return end
    U.log("found unfinished challenge (%s), restoring saves", tostring(state.bossName))
    if Save.restoreFiles(state) then
        Save.clearState()
        U.log("recovery done")
        U.delay(15000, "challenge.recoverVeto", function() Save.exitVeto() end)
        if U.playerPawn() then
            U.log("in game during recovery; reloading slot")
            st = { phase = "reloading", endReason = "recover", phaseAt = os.time(), reloadPawn = pawnAddress(),
                   startBell = state.startBell }
            Save.reloadSlot(state.continueSlot or Save.continueSlotName())
        end
    else
        U.log("recovery failed; snapshot kept in %s", U.DataDir)
    end
end

return M
