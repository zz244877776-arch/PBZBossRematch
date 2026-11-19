local U = require("util")
local Config = require("config")

local M = {}

local ARENA_CACHE_PATH = U.DataDir .. "/arena_cache.lua"
local BELL_TYPE_MELODIOUS = 0

local bossRows = nil
local bellRows = nil
local arenaCache = U.loadTable(ARENA_CACHE_PATH) or {}

-- Drop void / soft-actor junk coords. Keep real high-Z pocket arenas (龙柱 / 暗魔天堡).
local function sanitizeArenaCache()
    local changed = 0
    for id, a in pairs(arenaCache) do
        if a and a.z ~= nil then
            local loc = { X = a.x or 0, Y = a.y or 0, Z = a.z }
            if U.isSkyArenaLoc(loc) then
                a.skyArena = true
                a.skyInvalid = nil
            elseif not U.saneWorldLoc(loc) then
                U.log("arena cache: clearing void/soft coords for %s (z=%s)", id, tostring(a.z))
                a.x, a.y, a.z = nil, nil, nil
                a.skyInvalid = true
                a.skyArena = nil
                changed = changed + 1
            end
        end
    end
    if changed > 0 then
        U.saveTable(ARENA_CACHE_PATH, arenaCache)
        U.log("arena cache: cleared %d void entr(y/ies)", changed)
    end
end
sanitizeArenaCache()

-- Real sky pockets only (Z≥~1e7). Soft WP junk around Z≈2e6 must never be re-seeded here.
local KNOWN_SKY_ARENAS = {
}

local function seedKnownSkyArenas()
    local changed = 0
    for id, seed in pairs(KNOWN_SKY_ARENAS) do
        local a = arenaCache[id]
        local loc = a and a.z ~= nil and { X = a.x or 0, Y = a.y or 0, Z = a.z } or nil
        local hasSky = loc and U.isSkyArenaLoc(loc)
        if a and a.unsupported and not hasSky then
            U.log("arena seed: clearing false unsupported for %s", id)
        end
        if not hasSky then
            arenaCache[id] = {
                map = seed.map,
                bell = seed.bell,
                x = seed.x, y = seed.y, z = seed.z,
                skyArena = true,
                skyInvalid = false,
                spawnerId = (a and a.spawnerId) or seed.spawnerId or "",
            }
            changed = changed + 1
            U.log("arena seed: restored sky pocket %s bell=%s at (%d,%d,%d)",
                id, seed.bell, seed.x, seed.y, seed.z)
        elseif a.unsupported then
            a.unsupported = nil
            a.skyArena = true
            a.skyInvalid = false
            changed = changed + 1
        end
    end
    if changed > 0 then
        U.saveTable(ARENA_CACHE_PATH, arenaCache)
    end
end
seedKnownSkyArenas()

-- Ground sequence bosses whose class-matched AISpawner is soft until the Seq* family loads.
-- 拳痴：铁狂 fights on the clearing under 镜林入口 (Bell_LZSJ_019), not in a sky pocket.
-- LuanShi_Seq030 on the ground is RenTuZi_Ice (minion); ClaimSeqSpawn the family, then wait
-- for BP_Monster_LuanShi. Do NOT put LuanShi_Seq030 in spawnerId (would pick the rabbit as boss).
local KNOWN_GROUND_ARENAS = {
    ["BP_Monster_LuanShi"] = {
        map = "FuJiZhiLin",
        bell = "Bell_LZSJ_019",
        x = -44402, y = 161651, z = -314,
        seqFamily = "LuanShi",
    },
}

local function seedKnownGroundArenas()
    local changed = 0
    for id, seed in pairs(KNOWN_GROUND_ARENAS) do
        local a = arenaCache[id]
        local loc = a and a.z ~= nil and { X = a.x or 0, Y = a.y or 0, Z = a.z } or nil
        local groundOk = loc and U.saneWorldLoc(loc)
        local falseSky = a and (a.skyArena or (loc and U.isSkyArenaLoc(loc)))
        if not groundOk or falseSky or (a and a.unsupported) or (a and a.skyInvalid) then
            arenaCache[id] = {
                map = seed.map,
                bell = seed.bell,
                x = seed.x, y = seed.y, z = seed.z,
                seqFamily = seed.seqFamily,
                skyArena = nil,
                skyInvalid = nil,
                unsupported = nil,
                spawnerId = "",
            }
            changed = changed + 1
            U.log("arena seed: ground sequence %s bell=%s at (%d,%d,%d) family=%s",
                id, seed.bell, seed.x, seed.y, seed.z, tostring(seed.seqFamily))
        elseif a and not a.seqFamily and seed.seqFamily then
            a.seqFamily = seed.seqFamily
            changed = changed + 1
        end
    end
    if changed > 0 then
        U.saveTable(ARENA_CACHE_PATH, arenaCache)
    end
end
seedKnownGroundArenas()

local function rowStructName(dt)
    local ok, n = pcall(function() return dt.RowStruct:GetFName():ToString() end)
    return ok and n or ""
end

local function forEachTableOf(structName, fn)
    for _, dt in ipairs(FindAllOf("DataTable") or {}) do
        if rowStructName(dt) == structName then
            dt:ForEachRow(fn)
        end
    end
end

local function isHidden(id)
    for _, pat in ipairs(Config.HiddenBossPatterns) do
        if string.find(id, pat) then return true end
    end
    return false
end

local function assetName(path)
    return string.match(path, "%.([%w_]+)$") or path
end

local function softObjectPathStr(p)
    local ok, r = pcall(function()
        return p.AssetPath.PackageName:ToString() .. "." .. p.AssetPath.AssetName:ToString()
    end)
    return ok and r or ""
end

-- SoftClassPtr / SoftObjectPath -> "/Game/.../BP_Monster_X.BP_Monster_X_C" (or engine Conv string).
local function softClassPathFrom(soft)
    if soft == nil then return "" end
    local lib = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if U.valid(lib) then
        local ok, s = pcall(function() return lib:Conv_SoftClassReferenceToString(soft) end)
        if ok then
            local str = U.str(s)
            if str ~= "" and str ~= "None" then return str end
        end
    end
    local readers = {
        function(p) return softObjectPathStr(p) end,
        function(p) return softObjectPathStr(p.ObjectID) end,
        function(p) return softObjectPathStr(p.SoftObjectPtr and p.SoftObjectPtr.ObjectID) end,
        function(p)
            return p.AssetPath.PackageName:ToString() .. "." .. p.AssetPath.AssetName:ToString()
        end,
        function(p) return U.str(p) end,
    }
    for _, read in ipairs(readers) do
        local ok, s = pcall(function() return read(U.unwrap(soft)) end)
        if ok then
            local str = U.str(s)
            if str ~= "" and str ~= "None" then return str end
        end
    end
    return ""
end

local function classFromPath(path)
    if type(path) ~= "string" or path == "" or path == "None" then return nil end
    if string.find(path, ":", 1, true) or string.find(path, " ", 1, true) then
        -- Engine Conv often returns BlueprintGeneratedClass'/Game/Foo.Bar_C'
        local quoted = string.match(path, "'([^']+)'")
        if quoted then path = quoted end
    end
    if string.find(path, ":", 1, true) or string.find(path, " ", 1, true) then return nil end
    local cls = string.match(path, "%.([%a][%w_]*)'?$") or string.match(path, "^([%a][%w_]*)$")
    if not cls or cls == "None" then return nil end
    if not string.find(cls, "_C$") then cls = cls .. "_C" end
    return cls
end

local function collectSoftClassPaths(arr)
    local list = {}
    if arr == nil then return list end
    pcall(function()
        arr:ForEach(function(_, elem)
            local path = softClassPathFrom(U.unwrap(elem))
            if path ~= "" then table.insert(list, path) end
        end)
    end)
    return list
end

local function flowLocParts(flow)
    local ns, key, cache = "", "", ""
    if flow == nil then return ns, key, cache end
    pcall(function() ns = U.str(flow.Namespace) end)
    pcall(function() key = U.str(flow.Key) end)
    pcall(function() cache = U.str(flow.ValueCache) end)
    if ns == "None" then ns = "" end
    if key == "None" then key = "" end
    if cache == "None" then cache = "" end
    return ns, key, cache
end

-- Prefer the game's loc table (same path as map names). ValueCache / Hans are often
-- baked Chinese even when the client language is English.
local function resolveFlowLocName(ns, key, cache, hansFallback)
    if key ~= "" and M.LocResolver then
        local ok, s = pcall(M.LocResolver, ns or "", key)
        if ok and s and s ~= "" then
            pcall(function() require("locale").observeText(s) end)
            return s, "lockey"
        end
    end
    if cache ~= "" then return cache, "cache" end
    if hansFallback and hansFallback ~= "" then return hansFallback, "hans" end
    return "", "none"
end

function M.clearBossRows()
    bossRows = nil
    mapNames = {}
    usedNames = {}
end

-- Re-resolve boss display names after LocResolver is ready / language changes.
function M.refreshBossNames()
    if not bossRows then return 0 end
    local n = 0
    for _, b in ipairs(bossRows) do
        local name, src = resolveFlowLocName(b.nameNs, b.nameKey, b.nameCache, b.nameHans)
        if name ~= "" and name ~= b.name then
            b.name = name
            n = n + 1
        elseif name ~= "" then
            b.name = name
        end
        b.nameSource = src
    end
    return n
end

function M.bosses()
    if bossRows then return bossRows end
    local rows = {}
    forEachTableOf("CodexEnemyRow", function(rowName, row)
        if row.bIsBoss then
            local id = U.str(rowName)
            local classPath = softClassPathFrom(row.EnemyClass)
            local class = classFromPath(classPath) or (id .. "_C")
            local replacedBy = softClassPathFrom(row.ReplacedByEnemyClass)
            local ns, key, cache = flowLocParts(row.EnemyName)
            local hans = U.str(row.Enemy_CH_Hans_Name)
            local name, src = resolveFlowLocName(ns, key, cache, hans)
            table.insert(rows, {
                id = id,
                class = class,
                classPath = classPath,
                replacedByPath = (replacedBy ~= "" and replacedBy) or nil,
                aliasPaths = collectSoftClassPaths(row.AliasEnemyClasses),
                name = name ~= "" and name or id,
                nameNs = ns,
                nameKey = key,
                nameCache = cache,
                nameHans = hans,
                nameSource = src,
                map = U.str(row.OwnMapID),
                order = tonumber(U.str(row.DisplayOrder)) or 0,
                hidden = isHidden(id),
            })
        end
    end)
    table.sort(rows, function(a, b) return a.order < b.order end)
    if #rows > 0 then
        bossRows = rows
        local withPath, withLockey = 0, 0
        for _, b in ipairs(rows) do
            if b.classPath and b.classPath ~= "" then withPath = withPath + 1 end
            if b.nameSource == "lockey" then withLockey = withLockey + 1 end
        end
        U.log("codex bosses loaded: %d (classPath=%d nameLockey=%d)", #rows, withPath, withLockey)
    end
    -- A second phase is reached through its first phase; one without a first phase on its map is a fight of its own.
    local chained = {}
    for _, b in ipairs(rows) do
        local nxt = M.nextStage(b)
        if nxt then chained[nxt.id] = true end
    end
    for _, b in ipairs(rows) do
        if b.hidden and string.find(b.id, "_P2$") and not chained[b.id] then b.hidden = false end
    end
    return rows
end

-- Multi-phase bosses keep each phase in its own class on the same map, e.g. LionDancer ->
-- LionDancer_P2, ChangHong_Spear -> ChangHong_P2, ZuoShang_Ending -> ZuoShang_P2.
function M.nextStage(boss)
    if string.find(boss.id, "_P2$") then return nil end
    for _, b in ipairs(M.bosses()) do
        local base = string.match(b.id, "^(.+)_P2$")
        if base and b.map == boss.map
            and (boss.id == base or string.sub(boss.id, 1, #base + 1) == base .. "_") then
            return b
        end
    end
    return nil
end

function M.bossByClass(cls)
    for _, b in ipairs(M.bosses()) do
        if b.class == cls then return b end
    end
    return nil
end

-- Prefer Codex SoftClass path on the boss entry; fall back to discovered/revealed paths.
function M.bossClassPath(boss)
    if not boss then return nil end
    if type(boss) == "string" then
        local want = string.lower(string.gsub(boss, "_C$", ""))
        for _, b in ipairs(M.bosses()) do
            if string.lower(b.id) == want or string.lower(string.gsub(b.class, "_C$", "")) == want then
                boss = b
                break
            end
        end
        if type(boss) == "string" then return M.findEnemyClassPath(boss) end
    end
    if boss.classPath and boss.classPath ~= "" then return boss.classPath end
    return M.findEnemyClassPath(boss.class or boss.id)
end

function M.discoveredClasses()
    local set = {}
    local codex = U.worldSubsystem("PBZCodexSubsystem")
    if not codex then return set end
    pcall(function()
        codex.DiscoveredEnemyPaths:ForEach(function(elem)
            set[assetName(softObjectPathStr(U.unwrap(elem)))] = true
        end)
    end)
    return set
end

function M.bells()
    if bellRows then return bellRows end
    local rows = {}
    forEachTableOf("BellDataStruct", function(rowName, row)
        local ok, entry = pcall(function()
            local t = row.TeleportTransform
            return {
                id = U.str(row.BellID),
                map = U.str(row.MapID),
                type = tonumber(U.str(row.BellType)) or -1,
                loc = { X = row.BellLocation.X, Y = row.BellLocation.Y, Z = row.BellLocation.Z },
                transform = U.transformTable(t),
            }
        end)
        if ok and entry and entry.id ~= "" and entry.id ~= "None" then
            table.insert(rows, entry)
        end
    end)
    if #rows > 0 then bellRows = rows end
    return rows
end

function M.bellById(id)
    for _, b in ipairs(M.bells()) do
        if b.id == id then return b end
    end
    return nil
end

function M.nearestBell(mapId, loc)
    local best, bestDist = nil, math.huge
    local useHoriz = loc and not U.saneWorldLoc(loc)
    for _, b in ipairs(M.bells()) do
        if b.map == mapId and b.type == BELL_TYPE_MELODIOUS and U.saneWorldLoc(b.loc) then
            local d = useHoriz and U.horizDist(b.loc, loc) or U.dist(b.loc, loc)
            if d < bestDist then best, bestDist = b, d end
        end
    end
    return best, bestDist
end

function M.bellsInMap(mapId)
    local list = {}
    for _, b in ipairs(M.bells()) do
        if b.map == mapId and b.type == BELL_TYPE_MELODIOUS then table.insert(list, b) end
    end
    return list
end

-- ===== Map names =====

local mapRows = nil
local mapNames = {}

-- Optional function(namespace, key) -> string, provided by the UI to resolve localization keys.
M.LocResolver = nil

local function textOf(v)
    if v == nil then return "" end
    if type(v) == "table" then
        if v.ReturnValue ~= nil then return textOf(v.ReturnValue) end
        for _, inner in pairs(v) do
            local s = textOf(inner)
            if s ~= "" then return s end
        end
        return ""
    end
    local s = U.str(v)
    if s:match("^table: ") or s:match("^userdata: ") then return "" end
    return s
end

local function maps()
    if mapRows then return mapRows end
    local rows = {}
    forEachTableOf("MapData", function(rowName, row)
        local entry = { id = U.str(row.MapID), order = tonumber(U.str(row.MapOrder)) or 999 }
        pcall(function() entry.cached = row.MapName.ValueCache:ToString() end)
        pcall(function() entry.ns = row.MapName.Namespace:ToString() end)
        pcall(function() entry.key = row.MapName.Key:ToString() end)
        rows[entry.id] = entry
    end)
    if next(rows) then mapRows = rows end
    return rows
end

function M.mapOrder(mapId)
    local m = maps()[mapId]
    return m and m.order or 999
end

local usedNames = {}

local function plausibleName(s, mapId, row)
    if not s or s == "" or s == mapId then return false end
    if row and (s == row.ns or s == row.key) then return false end
    return s ~= "Default"
end

function M.mapDisplayName(mapId)
    if mapNames[mapId] then return mapNames[mapId] end
    local row = maps()[mapId]
    local name, source = "", ""

    if row and row.key and row.key ~= "" and M.LocResolver then
        local ok, s = pcall(M.LocResolver, row.ns or "", row.key)
        if ok and plausibleName(s, mapId, row) then name, source = s, "lockey" end
    end
    if name == "" and row and plausibleName(row.cached, mapId, row) then
        name, source = row.cached, "cache"
    end
    if name == "" then
        local bm = U.worldSubsystem("BellManager")
        if bm then
            local ok, txt = pcall(function() return bm:GetMapNameTextFromMapID(FName(mapId)) end)
            local s = ok and textOf(txt) or ""
            if plausibleName(s, mapId, row) then name, source = s, "bellmanager" end
        end
    end

    U.log("map name %s -> %s via %s (key %s/%s)", mapId, name ~= "" and name or "<none>", source,
        row and row.ns or "?", row and row.key or "?")
    if name == "" then return mapId end
    if source == "lockey" then
        pcall(function() require("locale").observeText(name) end)
    end
    if usedNames[name] and usedNames[name] ~= mapId then
        name = name .. "·" .. mapId
    end
    usedNames[name] = mapId
    mapNames[mapId] = name
    return name
end

function M.levelNameForBell(bellId)
    local bm = U.worldSubsystem("BellManager")
    if not bm then return nil end
    local ok, n = pcall(function() return bm:GetLevelNameFromBellID(FName(bellId)) end)
    if ok then
        local s = U.str(n)
        if s ~= "" and s ~= "None" then return s end
    end
    return nil
end

function M.levelNameForMap(mapId)
    for _, b in ipairs(M.bellsInMap(mapId)) do
        local lv = M.levelNameForBell(b.id)
        if lv then return lv end
    end
    return nil
end

-- Spawner must sit near a bell that belongs to the boss's own map; otherwise we learned
-- a same-class actor from a different region (seen with 阿瑾 caching 陆家村 coords).
M.MAX_ARENA_BELL_DIST = 80000

function M.arenaBelongsToBossMap(arena, bossMap)
    if not arena or arena.unsupported then return false end
    if arena.bell and arena.bell ~= "" then
        local b = M.bellById(arena.bell)
        if b and b.map ~= bossMap then return false end
        -- Pocket arenas sit at Z≈1e7; bell travel points stay on the ground map. Skip
        -- level/distance checks that would drop a valid 暗魔天堡 cache.
        if arena.skyArena or arena.skyInvalid then return true end
        local mapLevel = M.levelNameForMap(bossMap)
        local bellLevel = M.levelNameForBell(arena.bell)
        if mapLevel and bellLevel and mapLevel ~= bellLevel then return false end
    elseif arena.skyArena or arena.skyInvalid then
        return arena.map == nil or arena.map == bossMap
    end
    if arena.x and arena.bell and arena.bell ~= "" then
        local b = M.bellById(arena.bell)
        if b and U.saneWorldLoc(b.loc) then
            local d = U.dist(b.loc, { X = arena.x, Y = arena.y, Z = arena.z })
            if d > M.MAX_ARENA_BELL_DIST then return false end
        end
    end
    return true
end

-- ===== Boss spawners =====

-- Only some spawners carry the spawned class in their object name; the rest are plain
-- "BP_AISpawner_C_UAID_..." and need their soft Class reference resolved.
local spawnerClassCache = {}
local methodStats = {}
local getClassToSpawnBroken = false

local function kismet()
    return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
end

local function classFromSoftRef(spawner)
    local lib = kismet()
    if U.valid(lib) then
        local ok, s = pcall(function() return lib:Conv_SoftClassReferenceToString(spawner.Class) end)
        local cls = ok and classFromPath(U.str(s))
        if cls then return cls, "kismet" end
    end
    local readers = {
        function(p) return U.str(p) end,
        function(p) return U.str(p.SoftObjectPtr.ObjectID.AssetPath.AssetName) end,
        function(p) return U.str(p.ObjectID.AssetPath.AssetName) end,
        function(p) return U.str(p.SoftObjectPtr.ObjectID.AssetPathName) end,
        function(p) return U.str(p.ObjectID.AssetPathName) end,
    }
    for i, read in ipairs(readers) do
        local ok, s = pcall(function() return read(spawner.Class) end)
        local cls = ok and classFromPath(s)
        if cls then return cls, "field" .. i end
    end
    return nil
end

local function classFromGetter(spawner)
    if getClassToSpawnBroken then return nil end
    local ok, c = pcall(function() return spawner:GetClassToSpawn() end)
    if not ok then
        getClassToSpawnBroken = true
        U.log("GetClassToSpawn unavailable: %s", tostring(c))
        return nil
    end
    c = U.unwrap(c)
    if not U.valid(c) then return nil end
    local okName, n = pcall(function() return c:GetFName():ToString() end)
    return okName and classFromPath(n) or nil, "getter"
end

function M.spawnerClass(spawner)
    local key = U.fullName(spawner)
    local cached = spawnerClassCache[key]
    if cached ~= nil then return cached or nil end
    local cls, method = string.match(key, "BP_AISpawner_C_(BP_Monster_[%w_]-_C)_UAID"), "name"
    if not cls then cls, method = classFromSoftRef(spawner) end
    if not cls then cls, method = classFromGetter(spawner) end
    method = cls and method or "unknown"
    methodStats[method] = (methodStats[method] or 0) + 1
    spawnerClassCache[key] = cls or false
    return cls
end

local function allSpawners()
    local list, seen = {}, {}
    for _, cn in ipairs({ "BP_AISpawner_C", "AISpawner" }) do
        for _, s in ipairs(FindAllOf(cn) or {}) do
            local a = U.address(s)
            if a and not seen[a] and U.valid(s) then
                seen[a] = true
                table.insert(list, s)
            end
        end
    end
    return list
end
M.allSpawners = allSpawners

function M.unresolvedSpawnerCount()
    local n = 0
    for _, s in ipairs(allSpawners()) do
        if not M.spawnerClass(s) then n = n + 1 end
    end
    return n
end

local function sameClass(a, b)
    return a and b and string.lower(a) == string.lower(b)
end

function M.findSpawner(bossClass)
    local pawnLoc = U.location(U.playerPawn())
    local best, bestDist = nil, math.huge
    for _, s in ipairs(allSpawners()) do
        if sameClass(M.spawnerClass(s), bossClass) then
            local d = U.dist(U.location(s), pawnLoc)
            if d < bestDist then best, bestDist = s, d end
        end
    end
    return best, bestDist
end

-- Class match first; then the cached SpawnerID; then a SpawnerID that starts with the boss id
-- when the class also matches (or is unresolved and the spawner sits in a sky pocket).
-- Do NOT match by SpawnerID prefix alone: LuanShi_Seq030 on the ground is RenTuZi_Ice.
function M.findSpawnerForBoss(boss)
    if not boss then return nil end
    local byClass, dist = M.findSpawner(boss.class)
    if byClass then return byClass, dist end
    local id = boss.id or (boss.class and string.gsub(boss.class, "_C$", "")) or ""
    local wantId = arenaCache[id] and arenaCache[id].spawnerId or ""
    -- Never treat a seq-family minion id as the boss spawner.
    if wantId ~= "" and arenaCache[id] and arenaCache[id].seqFamily then
        wantId = ""
    end
    local pawnLoc = U.location(U.playerPawn())
    local best, bestDist = nil, math.huge
    for _, s in ipairs(allSpawners()) do
        local sid = U.str(s.SpawnerID)
        local cls = M.spawnerClass(s)
        local loc = U.location(s)
        local match = false
        if wantId ~= "" and wantId ~= "None" and sid == wantId then
            match = true
        elseif id ~= "" and sid ~= "" and (sid == id or string.find(sid, id, 1, true) == 1) then
            if sameClass(cls, boss.class) then
                match = true
            elseif not cls and loc and U.isSkyArenaLoc(loc) then
                match = true
            end
        end
        if match then
            local d = (pawnLoc and loc and U.dist(loc, pawnLoc)) or 0
            if d < bestDist then best, bestDist = s, d end
        end
    end
    return best, bestDist
end

-- Short name used in SpawnerID prefixes: BP_Monster_LuanShi -> LuanShi.
function M.bossSeqFamily(boss)
    if not boss then return nil end
    local a = arenaCache[boss.id]
    if a and a.seqFamily and a.seqFamily ~= "" then return a.seqFamily end
    local seed = KNOWN_GROUND_ARENAS[boss.id]
    if seed and seed.seqFamily then return seed.seqFamily end
    return nil
end

-- Ground spawners tagged for the boss's Level Sequence (often minions, not the boss class).
-- Used to ClaimSeqSpawn the encounter so the real boss AI appears.
-- Include soft-loc family members too: some Seq* actors only resolve at WP soft Z.
function M.findSeqFamilySpawners(boss)
    local family = M.bossSeqFamily(boss)
    if not family or family == "" then return {} end
    local list = {}
    for _, s in ipairs(allSpawners()) do
        local sid = U.str(s.SpawnerID)
        if sid ~= "" and string.find(sid, family, 1, true) == 1 then
            table.insert(list, s)
        end
    end
    return list
end

-- SoftObjectPath string for a boss class. Prefer CodexEnemyRow SoftClass on the boss entry.
function M.findEnemyClassPath(bossClass)
    local want = string.lower(string.gsub(bossClass or "", "_C$", ""))
    if want == "" then return nil end
    for _, b in ipairs(M.bosses()) do
        local id = string.lower(b.id or "")
        local cls = string.lower(string.gsub(b.class or "", "_C$", ""))
        if id == want or cls == want then
            if b.classPath and b.classPath ~= "" then return b.classPath end
            break
        end
    end
    local codex = U.worldSubsystem("PBZCodexSubsystem")
    if not codex then return nil end
    local found = nil
    local function consider(path)
        if not path or path == "" then return end
        local name = string.lower(assetName(path))
        name = string.gsub(name, "_C$", "")
        if name == want then found = path end
    end
    pcall(function()
        codex.DiscoveredEnemyPaths:ForEach(function(elem)
            consider(softObjectPathStr(U.unwrap(elem)))
        end)
    end)
    if found then return found end
    pcall(function()
        codex.RevealedEnemyPaths:ForEach(function(elem)
            consider(softObjectPathStr(U.unwrap(elem)))
        end)
    end)
    return found
end

function M.isSkyArenaBoss(boss)
    if not boss then return false end
    local a = arenaCache[boss.id]
    if not a then return false end
    if a.skyArena then return true end
    if a.x and a.z and U.isSkyArenaLoc({ X = a.x, Y = a.y or 0, Z = a.z }) then return true end
    -- seqFamily ground bosses are never "sky missing coords".
    if a.seqFamily then return false end
    return a.skyInvalid == true
end

function M.clearUnsupported(bossId)
    local a = arenaCache[bossId]
    if not a or not a.unsupported then return false end
    a.unsupported = nil
    U.saveTable(ARENA_CACHE_PATH, arenaCache)
    U.log("cleared unsupported mark for %s", bossId)
    return true
end

function M.logSpawnerStats()
    local parts = {}
    for k, v in pairs(methodStats) do table.insert(parts, k .. "=" .. v) end
    table.sort(parts)
    U.log("spawner class resolution: %s", table.concat(parts, " "))
end

-- Writes every spawner-like actor of the current map to data/ so a failed lookup can be diagnosed.
function M.dumpSpawners(tag)
    local path = U.DataDir .. "/spawners_" .. (tag or "dump") .. "_" .. os.date("%H%M%S") .. ".tsv"
    local f = io.open(path, "w")
    if not f then return end
    f:write("world\t", U.worldName(), "\n")
    f:write("kind\tclass\tspawnerID\tlocation\textra\tobject\n")
    local function loc(a)
        local l = U.location(a)
        return l and string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) or ""
    end
    for _, s in ipairs(allSpawners()) do
        local ai = ""
        pcall(function() if U.valid(s.SpawnedAI) then ai = U.className(s.SpawnedAI) end end)
        f:write("ai\t", M.spawnerClass(s) or "?", "\t", U.str(s.SpawnerID), "\t", loc(s), "\t", ai, "\t", U.fullName(s), "\n")
    end
    for _, s in ipairs(FindAllOf("NPCSpawner") or {}) do
        local names = {}
        pcall(function() s.NPCNames:ForEach(function(_, v) table.insert(names, U.str(v:get())) end) end)
        f:write("npc\t\t\t", loc(s), "\t", table.concat(names, ","), "\t", U.fullName(s), "\n")
    end
    for _, s in ipairs(FindAllOf("PBZSaveStateSpawner") or {}) do
        local cls = ""
        pcall(function() cls = U.className(s.ReplicaArchetype) end)
        if cls == "" then pcall(function() cls = U.str(s.OriginalActorClass:GetFName()) end) end
        f:write("savestate\t", cls, "\t", U.str(s.OriginalActorName), "\t", loc(s), "\t\t", U.fullName(s), "\n")
    end
    for _, s in ipairs(FindAllOf("PBZMonsterPartySpawner") or {}) do
        f:write("party\t\t", U.str(s.PartyID), "\t", loc(s), "\t\t", U.fullName(s), "\n")
    end
    for _, a in ipairs(FindAllOf("PBZCharacter_NPC") or {}) do
        local cls = U.className(a)
        if string.find(cls, "^BP_Monster_") then
            f:write("pawn\t", cls, "\t\t", loc(a), "\t\t", U.fullName(a), "\n")
        end
    end
    f:close()
    M.logSpawnerStats()
    U.log("spawner dump written: %s", path)
end

function M.arena(bossId)
    return arenaCache[bossId]
end

function M.markUnsupported(boss)
    -- Keep any known sky coords so a later seed / manual fix can revive the entry.
    local prev = arenaCache[boss.id]
    arenaCache[boss.id] = {
        map = boss.map,
        unsupported = true,
        bell = prev and prev.bell or nil,
        x = prev and prev.x, y = prev and prev.y, z = prev and prev.z,
        skyArena = prev and prev.skyArena or nil,
        skyInvalid = prev and prev.skyInvalid or nil,
        spawnerId = prev and prev.spawnerId or nil,
    }
    U.saveTable(ARENA_CACHE_PATH, arenaCache)
end

-- After a sky-stored spawner finally produces a living boss on solid ground, remember that
-- XYZ so the next rematch can hop next to the real arena instead of a map-entry bell.
function M.rememberArenaLoc(boss, loc, spawnerId)
    if not boss or not loc then return false end
    if not U.saneWorldLoc(loc) and not U.isSkyArenaLoc(loc) then return false end
    local bell = M.nearestBell(boss.map, loc)
    arenaCache[boss.id] = {
        map = boss.map,
        x = math.floor(loc.X), y = math.floor(loc.Y), z = math.floor(loc.Z),
        bell = bell and bell.id or "",
        spawnerId = spawnerId or (arenaCache[boss.id] and arenaCache[boss.id].spawnerId) or "",
        skyArena = U.isSkyArenaLoc(loc) or nil,
        skyInvalid = nil,
        unsupported = nil,
    }
    U.saveTable(ARENA_CACHE_PATH, arenaCache)
    U.log("arena remembered %s at (%.0f, %.0f, %.0f) bell=%s sky=%s",
        boss.id, loc.X, loc.Y, loc.Z, arenaCache[boss.id].bell, tostring(arenaCache[boss.id].skyArena))
    return true
end

local lastLearnAt, lastLearnWorld = 0, ""

function M.learnArenas()
    -- FindAllOf + cache rewrite hitches the game; skip repeats in the same world
    -- (especially right after rematch reload when the player already feels stutter).
    local world = U.worldName() or ""
    local now = os.time()
    if world == lastLearnWorld and (now - lastLearnAt) < 45 then
        return 0
    end
    local bosses = {}
    for _, b in ipairs(M.bosses()) do bosses[string.lower(b.class)] = b end
    local learned = 0
    local candidates = {}
    for _, s in ipairs(allSpawners()) do
        local cls = M.spawnerClass(s)
        local b = cls and bosses[string.lower(cls)]
        local loc = b and U.location(s)
        if loc then
            candidates[b.id] = candidates[b.id] or { boss = b, list = {} }
            table.insert(candidates[b.id].list, { spawner = s, loc = loc })
        end
    end
    -- A boss can have several spawners (story and rematch versions); keep the cached one if it is still among them.
    for id, c in pairs(candidates) do
        local b = c.boss
        local prev = arenaCache[id]
        local keep = false
        if prev and M.arenaBelongsToBossMap(prev, b.map) and prev.x
            and U.saneWorldLoc({ X = prev.x, Y = prev.y, Z = prev.z }) then
            for _, cand in ipairs(c.list) do
                if U.saneWorldLoc(cand.loc) and U.dist(cand.loc, { X = prev.x, Y = prev.y, Z = prev.z }) < 500 then
                    keep = true
                end
            end
        end
        if not keep then
            local pick, pickBell, pickDist = nil, nil, math.huge
            for _, cand in ipairs(c.list) do
                if U.saneWorldLoc(cand.loc) then
                    local bell, d = M.nearestBell(b.map, cand.loc)
                    if bell and d < pickDist and d <= M.MAX_ARENA_BELL_DIST then
                        pick, pickBell, pickDist = cand, bell, d
                    end
                end
            end
            if not pick then
                local any = c.list[1]
                local skyBell = any and M.nearestBell(b.map, any.loc) or nil
                local sky = any and U.isSkyArenaLoc(any.loc)
                -- Soft/void junk must not wipe a proven "unsupported" mark — that made the
                -- rematch list never show （暂不支持） after a failed full-map scan.
                if prev and prev.unsupported and not sky then
                    if skyBell and (not prev.bell or prev.bell == "") then
                        prev.bell = skyBell.id
                    end
                    if any and prev.x == nil then
                        prev.x = math.floor(any.loc.X)
                        prev.y = math.floor(any.loc.Y)
                    end
                    prev.skyInvalid = true
                    prev.farFromMap = true
                    arenaCache[b.id] = prev
                    U.log("arena learn: keep unsupported for %s (soft spawner only)", b.id)
                else
                    -- Pocket arenas (暗魔天堡): keep full XYZ so rematch can teleport in.
                    -- Other soft/void junk: keep XY + nearest bell only.
                    arenaCache[b.id] = {
                        map = b.map,
                        bell = skyBell and skyBell.id or "",
                        x = any and math.floor(any.loc.X) or nil,
                        y = any and math.floor(any.loc.Y) or nil,
                        z = sky and math.floor(any.loc.Z) or nil,
                        spawnerId = any and U.str(any.spawner.SpawnerID) or "",
                        skyArena = sky or nil,
                        skyInvalid = not sky,
                        farFromMap = true,
                        -- Real sky pockets are challengeable; only soft junk may keep unsupported.
                        unsupported = sky and nil or (prev and prev.unsupported) or nil,
                    }
                    learned = learned + 1
                    U.log("arena learn sky/off-map %s: bell=%s xy=(%s,%s) z=%s skyArena=%s",
                        b.id, arenaCache[b.id].bell, tostring(arenaCache[b.id].x), tostring(arenaCache[b.id].y),
                        tostring(arenaCache[b.id].z), tostring(sky))
                end
            else
                local s, loc = pick.spawner, pick.loc
                learned = learned + 1
                -- A real ground spawner means rematch is possible again.
                arenaCache[b.id] = {
                    map = b.map,
                    x = math.floor(loc.X), y = math.floor(loc.Y), z = math.floor(loc.Z),
                    bell = pickBell and pickBell.id or "",
                    spawnerId = U.str(s.SpawnerID),
                }
            end
        end
    end
    lastLearnAt, lastLearnWorld = now, world
    if learned > 0 then
        U.saveTable(ARENA_CACHE_PATH, arenaCache)
        U.log("learned %d boss arena(s) in %s", learned, U.worldName())
    end
    return learned
end

-- ===== List shown in the bell menu =====

function M.availableBossesByMap()
    -- LocResolver (bell UI scratch widget) is often ready only after the menu opens.
    M.refreshBossNames()
    local discovered = Config.OnlyDiscovered and M.discoveredClasses() or nil
    local byMap, mapOrder = {}, {}
    for _, b in ipairs(M.bosses()) do
        if not b.hidden and (not discovered or discovered[b.class]) then
            if not byMap[b.map] then
                byMap[b.map] = {}
                table.insert(mapOrder, b.map)
            end
            table.insert(byMap[b.map], b)
        end
    end
    table.sort(mapOrder, function(a, b) return M.mapOrder(a) < M.mapOrder(b) end)
    return byMap, mapOrder
end

return M
