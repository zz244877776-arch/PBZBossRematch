local U = require("util")
local Config = require("config")
local Data = require("gamedata")
local Save = require("savesnap")
local Toast = require("toast")
local Streaming = require("streaming")
local Curtain = require("curtain")

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
local STAGE_WAIT_S = 6
local STAGE_FADE_AT_S = 4
local STAGE_FADE_S = 1.0
local PREPARE_MIN_S = 2
local PREPARE_TIMEOUT_S = 15
local REVEAL_FADE_S = 0.8

-- idle -> traveling -> locating [-> scanning -> traveling -> locating] -> spawning -> preparing -> countdown
--   -> fighting -> ending -> reloading -> idle
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
    if not (ok and moved) then return false, "同地图传送失败" end
    pcall(function() U.playerController():SetControlRotation(rot) end)
    return true
end

local function travel(level, transform, bellId)
    st.travel = { level = level, loc = transform.Translation, bell = bellId }
    local same = inLevel(level)
    U.log("travel level=%s bell=%s sameMap=%s at (%.0f, %.0f, %.0f)", level, bellId, tostring(same),
        transform.Translation.X, transform.Translation.Y, transform.Translation.Z)
    if same then
        local ok, err = localTeleport(transform)
        if not ok then
            U.log("local move failed: %s", tostring(err))
            local here = U.location(U.playerPawn())
            if here then st.travel.loc = here end
            st.finalHop = false
        end
        st.arrivedAt = nil
        setPhase("traveling")
        return true
    end
    -- Cross-map travel has to land on the bell itself. A point in an unloaded cell hangs TeleportTo.
    local bell = Data.bellById(bellId)
    local xf = (bell and bell.transform) or transform
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

-- The game's own hit-stop keeps rewriting time dilation, so the boss is also stopped through
-- its character freeze, the SGameAI component and the behavior tree. The AI controller can be
-- possessed a moment after spawning, so the controller-side calls repeat when it changes.
local function setFrozen(pawn, frozen)
    if not U.valid(pawn) then return end
    local d = frozen and 0.0 or 1.0
    pcall(function() pawn.CustomTimeDilation = d end)
    local controller = controllerOf(pawn)
    if controller then pcall(function() controller.CustomTimeDilation = d end) end
    local key = tostring(U.address(pawn)) .. "/" .. tostring(controller and U.address(controller))
    if frozen and st.freezeKey == key then return end
    st.freezeKey = frozen and key or nil
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

local function unfreezeBoss()
    if st.frozenKey then
        local p = U.live(st.frozenClass, st.frozenKey)
        if p then setFrozen(p, false) end
        U.log("boss released")
        st.frozenKey, st.frozenClass = nil, nil
    end
end

local function returnToStart(reason, delayMs)
    if st.phase == "ending" or st.phase == "reloading" then return end
    st.endReason = reason
    setPhase("ending")
    unfreezeBoss()
    Curtain.reveal(0.3)
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
    if arenaBell then
        U.log("arena cache hit bell=%s at (%.0f, %.0f, %.0f)", arena.bell, arena.x or 0, arena.y or 0, arena.z or 0)
    else
        U.log("arena cache miss; first visit uses map bell %s (next time will be faster)", firstBell.id)
        Toast.show("首次前往该地图，正在加载……", 3000)
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
    if Config.LoadingCurtain ~= false then Curtain.cover() end

    local transform = firstBell.transform
    -- Only step straight to the boss when this map is already loaded. Otherwise fast-travel
    -- to its bell, and the later hop runs once that move is a same-map teleport.
    if arenaBell and arena.x and inLevel(level) then
        local arenaLoc = { X = arena.x, Y = arena.y, Z = arena.z }
        transform = approachTransform(arenaLoc, arenaBell.loc, APPROACH_DISTANCE)
        st.finalHop = true
    end

    local tok, terr = travel(level, transform, firstBell.id)
    if not tok then
        Curtain.reveal(0.3)
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

    for _, seq in ipairs(FindAllOf("LevelSequenceActor") or {}) do
        if U.valid(seq) then
            local loc = U.location(seq)
            if loc and U.dist(loc, center) <= 12000 then
                local played = pcall(function() seq:Play() end)
                if not played then
                    played = pcall(function()
                        local player = seq.SequencePlayer
                        if player then player:Play() end
                    end)
                end
                if played then
                    activated = activated + 1
                    U.log("played LevelSequenceActor %s", U.fullName(seq))
                end
            end
        end
    end

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

-- A later phase gets its own combat music through the arena's music volume ("specific enemy" ->
-- music state). The game switches when that enemy engages; a phase spawned by this mod next to an
-- already-present player does not always trigger it, so set the matching state directly.
local function applyStageMusic(stage)
    local music = U.worldSubsystem("MusicSubsystem")
    local center = st.spawnerLoc or U.location(U.playerPawn())
    if not music or not center then
        U.log("stage music: no music subsystem")
        return
    end
    local wanted = compact(string.gsub(stage.id, "^BP_Monster_", ""))
    local applied = false
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
                if not applied and key ~= "" and (string.find(wanted, key, 1, true) or string.find(key, wanted, 1, true)) then
                    local state = states[i]
                    if U.valid(state) then
                        local ok, err = pcall(function() music:SetMusicState(state, MUSIC_TYPE_COMBAT, true) end)
                        U.log("stage music: %s -> %s ok=%s %s", name, U.fullName(state), tostring(ok), ok and "" or tostring(err))
                        applied = ok
                    end
                end
            end
            U.log("music volume %s dist=%.0f enemies=[%s]", U.fullName(vol):match("[^%.]+$") or "?", U.dist(loc, center), table.concat(labels, ","))
        end
    end
    if not applied then
        pcall(function() music:UpdateGameplayMusic(false) end)
        U.log("stage music: no specific state for %s, asked the game to refresh combat music", stage.id)
    end
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
        if not spawned then return abort("刷出 Boss 失败") end
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

local function hopToCachedArena()
    local arena = Data.arena(st.boss.id)
    if not arena or arena.unsupported or not arena.x then return false end
    local arenaLoc = { X = arena.x, Y = arena.y, Z = arena.z }
    local pawnLoc = U.location(U.playerPawn())
    if not pawnLoc then return false end
    if U.dist(pawnLoc, arenaLoc) <= NEAR_BOSS_RADIUS then
        st.finalHop = true
        return false
    end
    local bell = (arena.bell ~= "" and Data.bellById(arena.bell)) or Data.nearestBell(st.boss.map, arenaLoc)
    local transform = approachTransform(arenaLoc, (bell and bell.loc) or pawnLoc, APPROACH_DISTANCE)
    st.finalHop = true
    U.log("cached arena %.0f away, jumping next to it", U.dist(pawnLoc, arenaLoc))
    local ok, err = travel(st.level, transform, bell and bell.id or st.travel.bell)
    if not ok then abort(err) end
    return true
end

-- Objects in regions that are still loading or unloading must not be touched, so every
-- spawner lookup waits until the engine reports that streaming has settled.
local function tickLocating()
    local settled = elapsed() >= SCAN_SETTLE_S and Streaming.idle()
    if not settled and elapsed() < LOCATE_TIMEOUT_S then return end
    -- Known boss spot: one short hop next to it, instead of scanning every bell on the map.
    if not st.finalHop and hopToCachedArena() then return end
    local spawner = Data.findSpawner(st.boss.class)
    if spawner then return onSpawnerFound(spawner) end
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
    local bossLoc = st.spawnerLoc or U.location(bossPawn())
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
    local spawner = U.live(st.spawnerClass, st.spawnerKey)
    local ai = nil
    if spawner then pcall(function() ai = spawner.SpawnedAI end) end
    if U.valid(ai) and not isDead(ai) then
        setBoss(ai)
        placePlayerNearBoss()
        if st.rootBoss and not Curtain.isCovered() then
            setPhase("fighting")
            Toast.show("下一阶段：" .. st.boss.name, 3000)
            return
        end
        st.frozenKey, st.frozenClass = st.bossKey, st.bossClass
        setFrozen(ai, true)
        setPhase("preparing")
        return
    end
    if not st.altSpawnTried and elapsed() > ALT_SPAWN_AFTER_S and spawner then
        st.altSpawnTried = true
        trySequenceSpawn(spawner)
    end
    if elapsed() > SPAWN_TIMEOUT_S then
        abort(st.rootBoss and (st.boss.name .. " 没有出现，挑战结束") or "Boss 没有出现")
    end
end

-- A level sequence started for the encounter can bring the next phase in early; it must only
-- appear once the current phase is down.
local function dismissEarlyNextStage()
    local nxt = nextStageOf(st.boss)
    if not nxt then return end
    for _, a in ipairs(FindAllOf(nxt.class) or {}) do
        if U.valid(a) and not isDead(a) then
            local key = U.address(a)
            local spawner = Data.findSpawner(nxt.class)
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
            U.log("early %s removed (spawner=%s)", nxt.id, tostring(viaSpawner))
        end
    end
end

local function beginFight()
    dismissEarlyNextStage()
    unfreezeBoss()
    setPhase("fighting")
    Toast.show("开战：" .. st.boss.name, 2000)
    if st.rootBoss then applyStageMusic(st.boss) end
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
                Toast.show(string.format("准备迎战 %s  %d", st.boss.name, seconds - i), 1100)
            else
                beginFight()
            end
        end)
    end
end

-- The boss stays frozen behind the black screen until the world around it has finished streaming in.
local function tickPreparing()
    local boss = bossPawn()
    if not boss then return abort("Boss 加载失败") end
    setFrozen(boss, true)
    local ready = elapsed() >= PREPARE_MIN_S and Streaming.idle()
    if not ready and elapsed() < PREPARE_TIMEOUT_S then return end
    U.log("arena ready after %ds (streaming idle=%s)", elapsed(), tostring(Streaming.idle()))
    dismissEarlyNextStage()
    Curtain.reveal(REVEAL_FADE_S)
    startCountdown()
end

local function tickCountdown()
    local boss = bossPawn()
    if boss then setFrozen(boss, true) end
end

local function victory()
    local name = (st.rootBoss or st.boss).name
    Toast.show("挑战成功：" .. name .. "，即将返回", Config.VictoryReturnDelayMs)
    returnToStart("victory", Config.VictoryReturnDelayMs)
end

local function livePawnOf(boss)
    for _, a in ipairs(FindAllOf(boss.class) or {}) do
        if U.valid(a) and not isDead(a) then return a end
    end
    return nil
end

local function enterStage(stage, pawn)
    Curtain.reveal(REVEAL_FADE_S)
    st.boss = stage
    setBoss(pawn)
    st.bossDied = false
    st.playerDied = false
    st.musicStage = (st.musicStage or 0) + 1
    setBossFightMusicStage(st.musicStage)
    U.log("stage %s is up", stage.id)
    Toast.show("下一阶段：" .. stage.name, 3000)
    setPhase("fighting")
    applyStageMusic(stage)
end

-- After a phase dies the game may run its own transition; give it a moment, then spawn the next phase ourselves.
-- The death performance plays out first, then the screen fades to black so the old body is never
-- seen next to the new phase.
local function tickTransition()
    local stage = st.nextStage
    local pawn = livePawnOf(stage)
    if pawn then return enterStage(stage, pawn) end
    if elapsed() >= STAGE_FADE_AT_S and Config.LoadingCurtain ~= false then Curtain.fadeOut(STAGE_FADE_S) end
    if elapsed() < STAGE_WAIT_S then return end
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
    st.rootBoss = st.rootBoss or st.boss
    st.boss = stage
    st.bossDied = false
    st.musicStage = (st.musicStage or 0) + 1
    setBossFightMusicStage(st.musicStage)
    startSpawn(spawner)
end

local function tickFighting()
    local boss = bossPawn()
    if st.bossDied or not boss or isDead(boss) then
        local nextStage = nextStageOf(st.boss)
        if nextStage then
            U.log("%s down, waiting for %s", st.boss.id, nextStage.id)
            st.rootBoss = st.rootBoss or st.boss
            st.nextStage = nextStage
            st.deadKey, st.deadClass = st.bossKey, st.bossClass
            st.bossKey, st.bossClass = nil, nil
            st.bossDied = false
            return setPhase("transition")
        end
        return victory()
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
    Curtain.hold()
    local p = st.phase
    if p == "traveling" then tickTraveling()
    elseif p == "locating" then tickLocating()
    elseif p == "scanning" then tickScanning()
    elseif p == "spawning" then tickSpawning()
    elseif p == "preparing" then tickPreparing()
    elseif p == "countdown" then tickCountdown()
    elseif p == "fighting" then tickFighting()
    elseif p == "transition" then tickTransition()
    elseif p == "reloading" then tickReloading()
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
    if p == "fighting" or p == "transition" or p == "spawning" or p == "preparing" or p == "countdown"
        or p == "locating" or p == "scanning" or p == "traveling" then
        U.log("player died")
        st.playerDied = true
        if p ~= "fighting" then returnToStart("defeat", Config.DefeatReturnDelayMs) end
    end
end

function M.onMapLoaded()
    Curtain.hold()
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
