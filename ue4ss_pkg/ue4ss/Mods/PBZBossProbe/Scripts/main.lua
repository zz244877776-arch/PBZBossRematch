-- PBZBossProbe: read-only discovery mod.
-- F7: snapshot current world (player location, interesting actors, active widgets)
-- F8: toggle widget creation logging
-- F9: dump DataTables (list of all tables, codex bosses, bells)
-- F6: dump progress (cycle records, codex kills per boss)
-- Ctrl+F6: dump AI spawners in the current world

local OUT_DIR = "E:/SteamLibrary/steamapps/common/PBZ/_modwork/probe/"
local LOG_PATH = OUT_DIR .. "probe.log"

local logFile = io.open(LOG_PATH, "a")

local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    local line = string.format("[%s] %s", os.date("%H:%M:%S"), msg)
    print("[PBZBossProbe] " .. msg .. "\n")
    if logFile then
        logFile:write(line, "\n")
        logFile:flush()
    end
end

local function str(v)
    if v == nil then return "nil" end
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return tostring(v) end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and s then return s end
    return tostring(v)
end

local function softPath(v)
    local tries = {
        function() return v:ToString() end,
        function() return v.ObjectID.AssetPath.PackageName:ToString() .. "." .. v.ObjectID.AssetPath.AssetName:ToString() end,
        function() return v.SoftObjectPtr.ObjectID.AssetPath.PackageName:ToString() .. "." .. v.SoftObjectPtr.ObjectID.AssetPath.AssetName:ToString() end,
        function() return v.ObjectID.AssetPathName:ToString() end,
        function() return v:get():GetFullName() end,
    }
    for _, f in ipairs(tries) do
        local ok, r = pcall(f)
        if ok and type(r) == "string" and r ~= "" then return r end
    end
    return "<soft?>"
end

local function tagName(v)
    local ok, r = pcall(function() return v.TagName:ToString() end)
    return ok and r or "<tag?>"
end

local function locText(v)
    local ok, r = pcall(function() return v.ValueCache:ToString() end)
    if ok and r and r ~= "" then return r end
    local ok2, k = pcall(function() return v.Namespace:ToString() .. "/" .. v.Key:ToString() end)
    return ok2 and k or "<loc?>"
end

local function vec(v)
    local ok, r = pcall(function() return string.format("(%.0f, %.0f, %.0f)", v.X, v.Y, v.Z) end)
    return ok and r or "(?)"
end

local INTEREST = { "boss", "bell", "checkpoint", "shrine", "arena", "encounter", "challenge", "rematch", "teleport" }

local function isInteresting(name)
    local lower = string.lower(name)
    for _, k in ipairs(INTEREST) do
        if string.find(lower, k, 1, true) then return true end
    end
    return false
end

local function safeFullName(obj)
    local ok, n = pcall(function() return obj:GetFullName() end)
    return ok and n or "<?>"
end

local function safeClassName(obj)
    local ok, n = pcall(function() return obj:GetClass():GetFullName() end)
    return ok and n or "<?>"
end

local function locationOf(actor)
    local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
    if ok and loc then return vec(loc) end
    return "(?)"
end

local function currentWorldName()
    local ok, n = pcall(function() return FindFirstOf("PlayerController"):GetWorld():GetFullName() end)
    return ok and n or "<?>"
end

local seenClasses = {}

RegisterLoadMapPostHook(function()
    seenClasses = {}
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function() log("LoadMap done, world=%s", currentWorldName()) end)
    end)
end)

RegisterBeginPlayPostHook(function(ctx)
    local actor = ctx:get()
    local cls = safeClassName(actor)
    if isInteresting(cls) and not seenClasses[cls] then
        seenClasses[cls] = true
        log("BeginPlay class=%s obj=%s loc=%s", cls, safeFullName(actor), locationOf(actor))
    end
end)

local widgetLogging = true
local seenWidgets = {}

NotifyOnNewObject("/Script/UMG.UserWidget", function(widget)
    if not widgetLogging then return end
    local cls = safeClassName(widget)
    if not seenWidgets[cls] then
        seenWidgets[cls] = true
        log("NewWidget class=%s", cls)
    end
end)

local function snapshot()
    log("===== SNAPSHOT =====")
    log("World: %s", currentWorldName())
    local pawnOk, pawn = pcall(function() return FindFirstOf("PlayerController").Pawn end)
    if pawnOk and pawn and pawn:IsValid() then
        log("PlayerPawn: %s at %s", safeClassName(pawn), locationOf(pawn))
    end
    local counts = {}
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        local cls = safeClassName(a)
        if isInteresting(cls) then
            counts[cls] = (counts[cls] or 0) + 1
            if counts[cls] <= 3 then log("  Actor %s at %s", safeFullName(a), locationOf(a)) end
        end
    end
    for cls, n in pairs(counts) do log("  count %4d  %s", n, cls) end
    for _, w in ipairs(FindAllOf("UserWidget") or {}) do
        local ok, inViewport = pcall(function() return w:IsInViewport() end)
        if ok and inViewport then log("  ActiveWidget %s", safeFullName(w)) end
    end
    log("===== END SNAPSHOT =====")
end

local function rowStructName(dt)
    local ok, n = pcall(function() return dt.RowStruct:GetFName():ToString() end)
    return ok and n or "<?>"
end

local function dumpDataTables()
    local tables = FindAllOf("DataTable") or {}
    local f = io.open(OUT_DIR .. "datatables.txt", "w")
    local codex, bells = {}, {}
    for _, dt in ipairs(tables) do
        local rs = rowStructName(dt)
        f:write(rs, "\t", safeFullName(dt), "\n")
        if rs == "CodexEnemyRow" then table.insert(codex, dt) end
        if rs == "BellDataStruct" then table.insert(bells, dt) end
    end
    f:close()
    log("DataTables: %d total, %d CodexEnemyRow, %d BellDataStruct", #tables, #codex, #bells)

    local cf = io.open(OUT_DIR .. "codex_enemies.tsv", "w")
    cf:write("table\trow\tisBoss\tname\tmapID\ttype\tunlockTag\trevealTag\tenemyClass\treplacedBy\tdisplayOrder\n")
    for _, dt in ipairs(codex) do
        local dtName = safeFullName(dt)
        local ok, err = pcall(function()
            dt:ForEachRow(function(rowName, row)
                local fields = {
                    dtName, str(rowName),
                    str(row.bIsBoss), str(row.Enemy_CH_Hans_Name), str(row.OwnMapID), str(row.EnemyType),
                    tagName(row.UnlockTag), tagName(row.RevealTag),
                    softPath(row.EnemyClass), softPath(row.ReplacedByEnemyClass), str(row.DisplayOrder),
                }
                cf:write(table.concat(fields, "\t"), "\n")
            end)
        end)
        if not ok then log("codex ForEachRow error: %s", tostring(err)) end
    end
    cf:close()

    local bf = io.open(OUT_DIR .. "bells.tsv", "w")
    bf:write("table\trow\tbellID\ttype\tname\tmapID\tlayer\tlocation\n")
    for _, dt in ipairs(bells) do
        local dtName = safeFullName(dt)
        local ok, err = pcall(function()
            dt:ForEachRow(function(rowName, row)
                local fields = {
                    dtName, str(rowName), str(row.BellID), str(row.BellType), locText(row.BellName),
                    str(row.MapID), str(row.MapLayer), vec(row.BellLocation),
                }
                bf:write(table.concat(fields, "\t"), "\n")
            end)
        end)
        if not ok then log("bell ForEachRow error: %s", tostring(err)) end
    end
    bf:close()
    log("DataTable dump written to %s", OUT_DIR)
end

local function dumpSpawners()
    local spawners = FindAllOf("AISpawner") or {}
    local f = io.open(OUT_DIR .. "spawners_" .. os.date("%H%M%S") .. ".tsv", "w")
    f:write("world\t" .. currentWorldName() .. "\n")
    f:write("spawnerID\tshouldSpawn\tisSpawning\thasAI\taiClass\tclass\tlocation\tmobGroup\tobject\n")
    for _, s in ipairs(spawners) do
        local hasAI, aiClass = false, ""
        pcall(function()
            local ai = s.SpawnedAI
            if ai and ai:IsValid() then hasAI = true; aiClass = safeClassName(ai) end
        end)
        local mg = ""
        pcall(function() if s.MobGroup and s.MobGroup:IsValid() then mg = safeFullName(s.MobGroup) end end)
        local fields = {
            str(s.SpawnerID), str(s.ShouldSpawn), str(s.IsSpawning), tostring(hasAI), aiClass,
            softPath(s.Class), locationOf(s), mg, safeFullName(s),
        }
        f:write(table.concat(fields, "\t"), "\n")
    end
    f:close()
    log("Spawner dump: %d spawners in %s", #spawners, currentWorldName())
end

local ENDINGS = { [0] = "None", "Annihilation", "DragonRoar", "DecisiveBattle", "Regret" }
local DIFFICULTIES = { [0] = "Handicapped", "Easy", "Normal", "Hard", "NightMare" }

local function softObjectPathStr(p)
    local tries = {
        function() return p.AssetPath.PackageName:ToString() .. "." .. p.AssetPath.AssetName:ToString() end,
        function() return p.AssetPathName:ToString() end,
        function() return p:ToString() end,
    }
    for _, f in ipairs(tries) do
        local ok, r = pcall(f)
        if ok and type(r) == "string" and r ~= "" then return r end
    end
    return "<path?>"
end

local function unwrap(v)
    local ok, r = pcall(function() return v:get() end)
    if ok and r ~= nil then return r end
    return v
end

local function assetName(path)
    return string.match(path, "%.([%w_]+)$") or path
end

local function codexBossRows()
    local rows = {}
    for _, dt in ipairs(FindAllOf("DataTable") or {}) do
        if rowStructName(dt) == "CodexEnemyRow" then
            dt:ForEachRow(function(rowName, row)
                if row.bIsBoss then
                    table.insert(rows, {
                        id = str(rowName),
                        name = str(row.Enemy_CH_Hans_Name),
                        map = str(row.OwnMapID),
                        order = tonumber(str(row.DisplayOrder)) or 0,
                    })
                end
            end)
        end
    end
    table.sort(rows, function(a, b) return a.map < b.map or (a.map == b.map and a.order < b.order) end)
    return rows
end

local function dumpProgress()
    local f = io.open(OUT_DIR .. "progress.txt", "w")
    local function out(fmt, ...)
        local line = string.format(fmt, ...)
        f:write(line, "\n")
    end

    local gs = FindFirstOf("PBZGameSystem")
    if gs and gs:IsValid() then
        out("== PBZGameSystem ==")
        for _, k in ipairs({ "CycleCount", "bIsFinishGame", "bHasCompleted", "HasGameTime", "CurrentCycleGameTime",
                             "DiedTimes", "NarrativePercentage", "DifficultModeByte", "bCanSelectNightMare", "CurrentLevelName" }) do
            local ok, v = pcall(function() return gs[k] end)
            out("%s = %s", k, ok and str(v) or "<err>")
        end
        out("-- CycleRecords --")
        local ok, err = pcall(function()
            gs.CycleRecords:ForEach(function(key, value)
                local cycle = unwrap(key)
                local r = unwrap(value)
                out("cycle %s: ending=%s difficulty=%s time=%ss completion=%s%% died=%s remainingDays=%s",
                    str(cycle), ENDINGS[r.Ending] or str(r.Ending), DIFFICULTIES[r.Difficulty] or str(r.Difficulty),
                    str(r.GameTimeSeconds), str(r.CompletionPercentage), str(r.DiedTimes), str(r.RemainingDays))
            end)
        end)
        if not ok then out("CycleRecords error: %s", tostring(err)) end
    else
        out("PBZGameSystem not found")
    end

    local killed = {}
    local discovered = {}
    local playerWorld = currentWorldName()
    out("")
    out("player world: %s", playerWorld)
    for i, codex in ipairs(FindAllOf("PBZCodexSubsystem") or {}) do
        local worldOk, worldName = pcall(function() return codex:GetWorld():GetFullName() end)
        out("")
        out("== CodexSubsystem #%d %s (world=%s) ==", i, safeFullName(codex), worldOk and worldName or "<?>")

        local nKill = 0
        local ok, err = pcall(function()
            codex.EnemyKillMapIDs:ForEach(function(key, value)
                local path = softObjectPathStr(unwrap(key))
                killed[assetName(path)] = str(unwrap(value))
                nKill = nKill + 1
            end)
        end)
        out("EnemyKillMapIDs: %d entries%s", nKill, ok and "" or (" error: " .. tostring(err)))

        local nSet = 0
        ok, err = pcall(function()
            codex.DiscoveredEnemyPaths:ForEach(function(elem)
                local path = softObjectPathStr(unwrap(elem))
                discovered[assetName(path)] = true
                nSet = nSet + 1
            end)
        end)
        out("DiscoveredEnemyPaths (TSet): %d entries%s", nSet, ok and "" or (" error: " .. tostring(err)))

        local nArr = 0
        ok, err = pcall(function()
            local arr = codex:GetDiscoveredEnemyPathStrings()
            arr:ForEach(function(_, elem)
                discovered[assetName(str(unwrap(elem)))] = true
                nArr = nArr + 1
            end)
        end)
        out("GetDiscoveredEnemyPathStrings(): %d entries%s", nArr, ok and "" or (" error: " .. tostring(err)))
    end

    out("")
    out("== Codex bosses ==")
    local total, done, seen = 0, 0, 0
    for _, b in ipairs(codexBossRows()) do
        total = total + 1
        local killMap = killed[b.id .. "_C"] or killed[b.id]
        local isSeen = discovered[b.id .. "_C"] or discovered[b.id]
        if killMap then done = done + 1 end
        if isSeen then seen = seen + 1 end
        out("%s\t%s\t%s\t%s\t%s", killMap and "KILLED" or "------", isSeen and "SEEN" or "----", b.map, b.name, b.id)
    end
    out("bosses killed: %d / %d, discovered: %d / %d", done, total, seen, total)

    out("")
    out("== All kill entries ==")
    for k, v in pairs(killed) do out("%s\t%s", v, k) end
    out("")
    out("== All discovered entries ==")
    for k in pairs(discovered) do out("%s", k) end
    f:close()
    log("Progress dump: killed %d/%d, discovered %d/%d codex bosses, written to progress.txt", done, total, seen, total)
end

-- ===== Respawn experiment =====

local bossClassSet = nil
local bossNameByClass = {}

local function ensureBossClasses()
    if bossClassSet then return end
    bossClassSet = {}
    for _, b in ipairs(codexBossRows()) do
        bossClassSet[b.id .. "_C"] = true
        bossNameByClass[b.id .. "_C"] = b.name
    end
end

local function playerLocation()
    local ok, loc = pcall(function() return FindFirstOf("PlayerController").Pawn:K2_GetActorLocation() end)
    if ok and loc then return { X = loc.X, Y = loc.Y, Z = loc.Z } end
    return nil
end

local function spawnerBossClass(s)
    local name = safeFullName(s)
    local cls = string.match(name, "BP_AISpawner_C_(BP_Monster_[%w_]-_C)_UAID")
    if cls and bossClassSet[cls] then return cls end
    return nil
end

local function nearestBossSpawner()
    ensureBossClasses()
    local p = playerLocation()
    if not p then return nil end
    local best, bestDist, bestCls = nil, math.huge, nil
    for _, s in ipairs(FindAllOf("BP_AISpawner_C") or {}) do
        local cls = spawnerBossClass(s)
        if cls then
            local ok, loc = pcall(function() return s:K2_GetActorLocation() end)
            if ok and loc then
                local dx, dy, dz = loc.X - p.X, loc.Y - p.Y, loc.Z - p.Z
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if d < bestDist then best, bestDist, bestCls = s, d, cls end
            end
        end
    end
    return best, bestDist, bestCls
end

local function describeSpawner(tag, s, dist, cls)
    local function field(fn)
        local ok, v = pcall(fn)
        return ok and str(v) or "<err>"
    end
    local hasAI = false
    pcall(function() hasAI = s.SpawnedAI ~= nil and s.SpawnedAI:IsValid() end)
    log("[%s] %s (%s) dist=%.0f id=%s", tag, bossNameByClass[cls] or "?", cls or "?", dist or -1, field(function() return s.SpawnerID end))
    log("[%s]   ShouldSpawn=%s InitialSpawn=%s SaveInfo.IsAlive=%s IsSpawning=%s hasAI=%s", tag,
        field(function() return s.ShouldSpawn end), field(function() return s.InitialSpawn end),
        field(function() return s.SpawnerSaveInfo.IsAlive end), field(function() return s.IsSpawning end), tostring(hasAI))
    log("[%s]   AutoRespawnOnDead=%s SetShouldNotSpawnAfterDead=%s bAutoStartAI=%s bHiddenByDefault=%s", tag,
        field(function() return s.AutoRespawnOnDead end), field(function() return s.SetShouldNotSpawnAfterDead end),
        field(function() return s.SpawnInfo.bAutoStartAI end), field(function() return s.SpawnInfo.bHiddenByDefault end))
end

local function withNearestBossSpawner(tag, fn)
    local s, dist, cls = nearestBossSpawner()
    if not s then
        log("[%s] no boss spawner found near player", tag)
        return
    end
    describeSpawner(tag, s, dist, cls)
    if fn then
        fn(s)
        ExecuteWithDelay(3000, function()
            ExecuteInGameThread(function()
                pcall(describeSpawner, tag .. "+3s", s, dist, cls)
                pcall(function()
                    local ai = s.SpawnedAI
                    if ai and ai:IsValid() then
                        log("[%s+3s] SpawnedAI=%s at %s", tag, safeFullName(ai), locationOf(ai))
                    end
                end)
            end)
        end)
    end
end

local function inspectBossSpawner()
    withNearestBossSpawner("inspect", nil)
end

local function respawnViaSpawn()
    withNearestBossSpawner("spawn", function(s)
        pcall(function() s.ShouldSpawn = true end)
        pcall(function() s.SpawnerSaveInfo.IsAlive = true end)
        local ok, err = pcall(function() s:Spawn() end)
        log("[spawn] Spawn() called ok=%s %s", tostring(ok), ok and "" or tostring(err))
    end)
end

local function respawnViaSeqClaim()
    withNearestBossSpawner("claim", function(s)
        pcall(function() s.ShouldSpawn = true end)
        pcall(function() s.SpawnerSaveInfo.IsAlive = true end)
        local ok, err = pcall(function() s:ClaimSeqSpawn(false, true, true) end)
        log("[claim] ClaimSeqSpawn(false,true,true) ok=%s %s", tostring(ok), ok and "" or tostring(err))
    end)
end

local KILL_RADIUS = 6000
local KILL_COOLDOWN = 3.0
local lastKillAt = -math.huge

local function isBossPawn(c)
    ensureBossClasses()
    local ok, cls = pcall(function() return c:GetClass():GetFName():ToString() end)
    return ok and bossClassSet[cls] == true
end

local function findNearestBossPawn()
    local p = playerLocation()
    if not p then return nil end
    local candidates = {}
    for _, c in ipairs(FindAllOf("PBZCharacter_NPC") or {}) do
        if c:IsValid() and isBossPawn(c) then table.insert(candidates, c) end
    end
    local s = nearestBossSpawner()
    if s then
        pcall(function()
            local ai = s.SpawnedAI
            if ai and ai:IsValid() then table.insert(candidates, ai) end
        end)
    end
    local best, bestDist = nil, math.huge
    for _, c in ipairs(candidates) do
        local ok, loc = pcall(function() return c:K2_GetActorLocation() end)
        if ok and loc then
            local dx, dy, dz = loc.X - p.X, loc.Y - p.Y, loc.Z - p.Z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d < bestDist then best, bestDist = c, d end
        end
    end
    return best, bestDist
end

local function killNearestBoss()
    local now = os.time()
    if now - lastKillAt < KILL_COOLDOWN then return end
    lastKillAt = now
    local boss, dist = findNearestBossPawn()
    if not boss then
        log("[kill] no boss pawn found")
        return
    end
    if dist > KILL_RADIUS then
        log("[kill] nearest boss %s is too far (%.0f > %d)", safeClassName(boss), dist, KILL_RADIUS)
        return
    end
    log("[kill] target %s dist=%.0f", safeFullName(boss), dist)

    local geKill = FindObject("BlueprintGeneratedClass", "GE_Kill_C")
    if not geKill or not geKill:IsValid() then
        log("[kill] GE_Kill_C not found")
        return
    end
    log("[kill] GE: %s", safeFullName(geKill))

    local asl = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
    local targetASC = asl:GetAbilitySystemComponent(boss)
    local playerASC = asl:GetAbilitySystemComponent(FindFirstOf("PlayerController").Pawn)
    log("[kill] targetASC=%s playerASC=%s", safeFullName(targetASC), safeFullName(playerASC))

    local ok, err = pcall(function()
        local ctx = playerASC:MakeEffectContext()
        playerASC:BP_ApplyGameplayEffectToTarget(geKill, targetASC, 1.0, ctx)
    end)
    log("[kill] apply GE_Kill from player ok=%s %s", tostring(ok), ok and "" or tostring(err))
    if not ok then
        ok, err = pcall(function()
            local ctx = targetASC:MakeEffectContext()
            targetASC:BP_ApplyGameplayEffectToSelf(geKill, 1.0, ctx)
        end)
        log("[kill] apply GE_Kill to self ok=%s %s", tostring(ok), ok and "" or tostring(err))
    end
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function()
            local valid = false
            pcall(function() valid = boss:IsValid() end)
            log("[kill+3s] boss object still valid=%s", tostring(valid))
            pcall(withNearestBossSpawner, "kill+3s", nil)
        end)
    end)
end

local function guarded(name, fn)
    return function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then log("%s error: %s", name, tostring(err)) end
        end)
    end
end

RegisterKeyBind(Key.F7, guarded("snapshot", snapshot))
RegisterKeyBind(Key.F8, function()
    widgetLogging = not widgetLogging
    log("Widget logging: %s", tostring(widgetLogging))
end)
RegisterKeyBind(Key.F9, guarded("dumpDataTables", dumpDataTables))
RegisterKeyBind(Key.F6, guarded("dumpProgress", dumpProgress))
RegisterKeyBind(Key.F6, { ModifierKey.CONTROL }, guarded("dumpSpawners", dumpSpawners))

RegisterKeyBind(Key.F7, { ModifierKey.CONTROL }, guarded("inspectBossSpawner", inspectBossSpawner))
RegisterKeyBind(Key.F8, { ModifierKey.CONTROL }, guarded("respawnViaSpawn", respawnViaSpawn))
RegisterKeyBind(Key.F9, { ModifierKey.CONTROL }, guarded("respawnViaSeqClaim", respawnViaSeqClaim))

RegisterKeyBind(Key.END, guarded("killNearestBoss", killNearestBoss))

log("PBZBossProbe v7 loaded")
