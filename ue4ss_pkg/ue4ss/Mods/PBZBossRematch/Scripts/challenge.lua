local U = require("util")
local Config = require("config")
local Data = require("gamedata")
local Save = require("savesnap")
local Toast = require("toast")
local Streaming = require("streaming")

local M = {}

local TRAVEL_TIMEOUT_S = 120
local SETTLE_AFTER_ARRIVAL_S = 3
local LOCATE_TIMEOUT_S = 20
local SCAN_SETTLE_S = 2
local SCAN_STEP_TIMEOUT_S = 20
local SPAWN_TIMEOUT_S = 15
local ALT_SPAWN_AFTER_S = 6
local ARRIVAL_RADIUS = 3000
local NEAR_BOSS_RADIUS = 3000
local APPROACH_DISTANCE = 700
local NEAR_BOSS_DISTANCES = { 700, 500, 1000, 1400 }
local PLAYER_HEIGHT_OFFSET = 120
local RELOAD_TIMEOUT_S = 20
local RELOAD_MIN_S = 5
local SCAN_STABLE_REGIONS = 3

-- idle -> traveling -> locating [-> scanning -> traveling -> locating] -> spawning -> fighting -> ending -> reloading -> idle
local st = { phase = "idle" }

function M.phase() return st.phase end
function M.isActive() return st.phase ~= "idle" end

local function setPhase(p)
    U.log("phase %s -> %s", st.phase, p)
    st.phase = p
    st.phaseAt = os.time()
end

local function elapsed() return os.time() - (st.phaseAt or os.time()) end

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

local function travel(level, transform, bellId)
    local sub = saveSub()
    if not sub then return false, "找不到存档子系统" end
    st.travel = { level = level, loc = transform.Translation, bell = bellId }
    U.log("TeleportTo level=%s bell=%s at (%.0f, %.0f, %.0f)", level, bellId,
        transform.Translation.X, transform.Translation.Y, transform.Translation.Z)
    local ok, err = pcall(function() sub:TeleportTo(FName(level), transform, FName(bellId)) end)
    if not ok then return false, "传送失败: " .. tostring(err) end
    st.arrivedAt = nil
    setPhase("traveling")
    return true
end

local function pawnAddress()
    local pawn = U.playerPawn()
    return pawn and U.address(pawn) or nil
end

local function returnToStart(reason, delayMs)
    if st.phase == "ending" or st.phase == "reloading" then return end
    st.endReason = reason
    setPhase("ending")
    Streaming.clear()
    U.delay(delayMs or 0, "challenge.return", function()
        Save.exitVeto()
        if not Save.restoreFiles() then
            Toast.show("存档恢复失败，请查看 rematch.log", 8000)
            U.log("restore failed; state kept for recovery on next launch")
            setPhase("idle")
            return
        end
        local state = Save.readState()
        local slot = (state and state.continueSlot) or Save.continueSlotName()
        st.reloadPawn = pawnAddress()
        st.startBell = state and state.startBell
        setPhase("reloading")
        -- The real save is back on disk at this point, so the state file must not survive:
        -- recovery on a later launch would otherwise delete saves made after this challenge.
        Save.clearState()
        if not Save.reloadSlot(slot) then
            Toast.show("读档失败：存档已恢复，请手动回到主菜单读档", 8000)
            setPhase("idle")
            return
        end
        local reloadAt = st.phaseAt
        U.delay((RELOAD_TIMEOUT_S + 2) * 1000, "challenge.reloadFallback", function()
            if st.phase == "reloading" and st.phaseAt == reloadAt then
                U.log("reload fallback timer fired, back to idle")
                st = { phase = "idle" }
            end
        end)
    end)
end

local function abort(msg)
    U.log("abort: %s", msg)
    Toast.show(msg, 5000)
    returnToStart("abort", 3000)
end

function M.start(boss)
    if M.isActive() then
        Toast.show("已经在挑战中", 2000)
        return
    end
    local arena = Data.arena(boss.id)
    if arena and arena.unsupported then
        Toast.show(boss.name .. " 暂不支持再战", 3000)
        return
    end
    U.log("=== start challenge: %s (%s, map %s)", boss.name, boss.id, boss.map)

    local mapBells = Data.bellsInMap(boss.map)
    local arenaBell = arena and arena.bell and arena.bell ~= "" and Data.bellById(arena.bell) or nil
    local firstBell = arenaBell or mapBells[1]
    if not firstBell then
        Toast.show("找不到前往该地图的铃铛", 4000)
        return
    end
    local level = Data.levelNameForBell(firstBell.id)
    if not level then
        Toast.show("找不到铃铛所在关卡", 4000)
        return
    end

    local bm = U.worldSubsystem("BellManager")
    local startBell = ""
    pcall(function() startBell = U.str(bm.RecentlyInteractedBellID) end)

    local ok, err = Save.takeSnapshot({ bossId = boss.id, bossName = boss.name, startBell = startBell, startWorld = U.worldName() })
    if not ok then
        Toast.show("无法开始挑战：" .. tostring(err), 5000)
        return
    end

    st = { phase = "idle", boss = boss, level = level, mapBells = mapBells }
    Toast.show("宿敌再战：" .. boss.name, 3000)

    local transform = firstBell.transform
    if arenaBell and arena.x then
        local arenaLoc = { X = arena.x, Y = arena.y, Z = arena.z }
        transform = approachTransform(arenaLoc, arenaBell.loc, APPROACH_DISTANCE)
        st.finalHop = true
    end

    local tok, terr = travel(level, transform, firstBell.id)
    if not tok then
        Save.clearState()
        st = { phase = "idle" }
        Toast.show(terr, 5000)
    end
end

local function arrived()
    local pawn = U.playerPawn()
    if not pawn then return false end
    if not string.find(U.worldName(), st.travel.level, 1, true) then return false end
    return U.dist(U.location(pawn), st.travel.loc) < ARRIVAL_RADIUS
end

local function tickTraveling()
    if elapsed() > TRAVEL_TIMEOUT_S then return abort("传送超时") end
    if not arrived() then
        st.arrivedAt = nil
        return
    end
    st.arrivedAt = st.arrivedAt or os.time()
    if os.time() - st.arrivedAt < SETTLE_AFTER_ARRIVAL_S then return end
    setPhase("locating")
end

-- Spawners placed for cutscenes ignore Spawn() and only react to the sequence entry points.
local function trySequenceSpawn(spawner)
    local ok = pcall(function() spawner:SpawnFromSequence() end)
    U.log("SpawnFromSequence() ok=%s", tostring(ok))
    if ok then return true end
    ok = pcall(function() spawner:ClaimSeqSpawn(false, true, true) end)
    U.log("ClaimSeqSpawn() ok=%s", tostring(ok))
    return ok
end

local function startSpawn(spawner)
    if not st.vetoed then st.vetoed = Save.enterVeto() end
    st.spawner = spawner
    st.spawnerLoc = U.location(spawner)
    local hasAI = false
    pcall(function() hasAI = U.valid(spawner.SpawnedAI) end)
    if not hasAI then
        pcall(function() spawner.ShouldSpawn = true end)
        pcall(function() spawner.SpawnerSaveInfo.IsAlive = true end)
        local ok, err = pcall(function() spawner:Spawn() end)
        U.log("Spawn() ok=%s %s", tostring(ok), ok and "" or tostring(err))
        if not ok and not trySequenceSpawn(spawner) then return abort("刷出 Boss 失败") end
    end
    st.altSpawnTried = false
    setPhase("spawning")
end

-- Spawner found somewhere in the loaded map: either fight here or make one jump next to it.
-- The streaming source stays where it is until the jump lands, so the boss area remains loaded.
local function onSpawnerFound(spawner)
    Data.learnArenas()
    local spawnerLoc = U.location(spawner)
    local pawnLoc = U.location(U.playerPawn())
    if st.finalHop or U.dist(spawnerLoc, pawnLoc) <= NEAR_BOSS_RADIUS then
        Streaming.clear()
        return startSpawn(spawner)
    end
    local bell = Data.nearestBell(st.boss.map, spawnerLoc)
    local transform = approachTransform(spawnerLoc, (bell and bell.loc) or pawnLoc, APPROACH_DISTANCE)
    st.finalHop = true
    U.log("boss spawner found %.0f away, jumping next to it", U.dist(spawnerLoc, pawnLoc))
    local ok, err = travel(st.level, transform, bell and bell.id or st.travel.bell)
    if not ok then abort(err) end
end

local function spawnerCount()
    return #Data.allSpawners()
end

-- Objects in regions that are still loading or unloading must not be touched, so every
-- spawner lookup waits until the engine reports that streaming has settled.
local function tickLocating()
    local settled = elapsed() >= SCAN_SETTLE_S and Streaming.idle()
    if not settled and elapsed() < LOCATE_TIMEOUT_S then return end
    local spawner = Data.findSpawner(st.boss.class)
    if spawner then return onSpawnerFound(spawner) end
    Data.dumpSpawners(st.boss.map)
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

local function nextScanStep()
    local bell = table.remove(st.scanQueue, 1)
    if not bell then
        Streaming.clear()
        -- Only remember "unsupported" when the scan provably loaded other regions;
        -- otherwise the failure says nothing about this boss.
        if st.scanLoadedMore then
            Data.markUnsupported(st.boss)
            return abort(st.boss.name .. " 暂不支持再战（找不到刷怪点）")
        end
        return abort("没能加载地图其他区域，暂时无法定位 " .. st.boss.name)
    end
    local ok, err = Streaming.moveTo(bell.loc)
    if not ok then
        U.log("streaming source failed: %s", tostring(err))
        Streaming.clear()
        return abort("无法定位 Boss（加载区域失败）")
    end
    st.stepAt = os.time()
    local done = st.scanTotal - #st.scanQueue
    U.log("scanning region %d/%d near %s", done, st.scanTotal, bell.id)
    Toast.show(string.format("正在定位 %s（%d/%d）", st.boss.name, done, st.scanTotal), 4000)
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
    local spawner = Data.findSpawner(st.boss.class)
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
        Data.markUnsupported(st.boss)
        return abort(st.boss.name .. " 暂不支持再战（地图中没有它的刷怪点）")
    end
    nextScanStep()
end

local function placePlayerNearBoss()
    local pawn = U.playerPawn()
    local bossLoc = st.spawnerLoc or U.location(st.bossPawn)
    local p = U.location(pawn)
    if not pawn or not bossLoc or not p then return end
    if U.dist(p, bossLoc) <= NEAR_BOSS_DISTANCES[#NEAR_BOSS_DISTANCES] then return end
    for _, d in ipairs(NEAR_BOSS_DISTANCES) do
        local xf, yaw = approachTransform(bossLoc, p, d)
        local rot = { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }
        local ok, moved = pcall(function() return pawn:K2_TeleportTo(xf.Translation, rot) end)
        if ok and moved then
            pcall(function() U.playerController():SetControlRotation(rot) end)
            U.log("player placed %.0f from boss", d)
            return
        end
    end
    U.log("could not place player near boss")
end

local function tickSpawning()
    local ai = nil
    pcall(function() ai = st.spawner.SpawnedAI end)
    if U.valid(ai) then
        st.bossPawn = ai
        placePlayerNearBoss()
        setPhase("fighting")
        Toast.show("挑战开始：" .. st.boss.name, 3000)
        return
    end
    if not st.altSpawnTried and elapsed() > ALT_SPAWN_AFTER_S then
        st.altSpawnTried = true
        trySequenceSpawn(st.spawner)
    end
    if elapsed() > SPAWN_TIMEOUT_S then abort("Boss 没有出现") end
end

local function isDead(actor)
    local ok, v = pcall(function() return actor:IsDead() end)
    return ok and v == true
end

local function tickFighting()
    if st.bossDied or not U.valid(st.bossPawn) or isDead(st.bossPawn) then
        Toast.show("挑战成功：" .. st.boss.name .. "，即将返回", Config.VictoryReturnDelayMs)
        return returnToStart("victory", Config.VictoryReturnDelayMs)
    end
    if st.playerDied then
        Toast.show("挑战失败，即将返回", Config.DefeatReturnDelayMs)
        return returnToStart("defeat", Config.DefeatReturnDelayMs)
    end
end

local function finishReload()
    U.log("=== challenge finished (%s), back at start", tostring(st.endReason))
    Save.clearState()
    st = { phase = "idle" }
    U.delay(4000, "challenge.backToast", function() Toast.show("已返回，进度未改变", 3000) end)
end

local function nearStartBell()
    local bell = st.startBell and Data.bellById(st.startBell)
    return bell and U.dist(U.location(U.playerPawn()), bell.loc) < ARRIVAL_RADIUS
end

-- Loading a slot inside the same world may keep the pawn at the same address and fire no
-- map-load event, so arrival back at the start bell also counts as a finished reload.
local function tickReloading()
    local addr = pawnAddress()
    if not addr then st.reloadPawnGone = true end
    if os.time() - (st.reloadLogAt or 0) >= 3 then
        st.reloadLogAt = os.time()
        U.log("reloading %ds: pawn=%s (before %s) gone=%s nearStart=%s", elapsed(), tostring(addr),
            tostring(st.reloadPawn), tostring(st.reloadPawnGone == true), tostring(nearStartBell() == true))
    end
    local reason = nil
    if addr and addr ~= st.reloadPawn then reason = "new pawn"
    elseif addr and st.reloadPawnGone then reason = "pawn back"
    elseif addr and elapsed() >= RELOAD_MIN_S and nearStartBell() then reason = "at start bell"
    end
    if reason and elapsed() > 2 then
        st.reloadSeenAt = st.reloadSeenAt or os.time()
        if os.time() - st.reloadSeenAt >= 3 then
            U.log("reload detected: %s", reason)
            return finishReload()
        end
    end
    if elapsed() > RELOAD_TIMEOUT_S then
        U.log("reload not detected within %ds, back to idle", RELOAD_TIMEOUT_S)
        Save.clearState()
        st = { phase = "idle" }
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
    if p == "traveling" then tickTraveling()
    elseif p == "locating" then tickLocating()
    elseif p == "scanning" then tickScanning()
    elseif p == "spawning" then tickSpawning()
    elseif p == "fighting" then tickFighting()
    elseif p == "reloading" then tickReloading()
    end
end

function M.onEnemyDied(character)
    if st.phase ~= "fighting" then return end
    if U.address(character) == U.address(st.bossPawn) then
        U.log("boss died")
        st.bossDied = true
    end
end

function M.onPlayerDeadWidget()
    local p = st.phase
    if p == "fighting" or p == "spawning" or p == "locating" or p == "scanning" or p == "traveling" then
        U.log("player died")
        st.playerDied = true
        if p ~= "fighting" then returnToStart("defeat", Config.DefeatReturnDelayMs) end
    end
end

function M.onMapLoaded()
    if st.phase == "reloading" then
        U.log("map loaded while reloading")
    end
end

-- Last-resort exit when the challenge logic keeps failing: get the player back with the save restored.
function M.forceEnd(reason)
    if st.phase == "idle" or st.phase == "ending" or st.phase == "reloading" then return end
    U.log("force end: %s", tostring(reason))
    Toast.show("宿敌再战出错，正在返回", 4000)
    returnToStart("error", 1500)
end

function M.quit()
    if st.phase == "idle" then return end
    if st.phase == "ending" or st.phase == "reloading" then return end
    Toast.show("退出挑战，正在返回", 3000)
    returnToStart("quit", 1500)
end

function M.killBoss()
    if st.phase ~= "fighting" or not U.valid(st.bossPawn) then return end
    local geKill = FindObject("BlueprintGeneratedClass", "GE_Kill_C")
    local asl = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
    if not U.valid(geKill) or not U.valid(asl) then
        U.log("kill: GE_Kill_C or AbilitySystemBlueprintLibrary missing")
        return
    end
    local target = asl:GetAbilitySystemComponent(st.bossPawn)
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
