local U = require("util")
local Config = require("config")

local M = {}

local ARENA_CACHE_PATH = U.DataDir .. "/arena_cache.lua"
local BELL_TYPE_MELODIOUS = 0

local bossRows = nil
local bellRows = nil
local arenaCache = U.loadTable(ARENA_CACHE_PATH) or {}

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

function M.bosses()
    if bossRows then return bossRows end
    local rows = {}
    forEachTableOf("CodexEnemyRow", function(rowName, row)
        if row.bIsBoss then
            local id = U.str(rowName)
            table.insert(rows, {
                id = id,
                class = id .. "_C",
                name = U.str(row.Enemy_CH_Hans_Name),
                map = U.str(row.OwnMapID),
                order = tonumber(U.str(row.DisplayOrder)) or 0,
                hidden = isHidden(id),
            })
        end
    end)
    table.sort(rows, function(a, b) return a.order < b.order end)
    if #rows > 0 then bossRows = rows end
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

local function assetName(path)
    return string.match(path, "%.([%w_]+)$") or path
end

local function softObjectPathStr(p)
    local ok, r = pcall(function()
        return p.AssetPath.PackageName:ToString() .. "." .. p.AssetPath.AssetName:ToString()
    end)
    return ok and r or ""
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
    for _, b in ipairs(M.bells()) do
        if b.map == mapId and b.type == BELL_TYPE_MELODIOUS then
            local d = U.dist(b.loc, loc)
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

-- ===== Boss spawners =====

-- Only some spawners carry the spawned class in their object name; the rest are plain
-- "BP_AISpawner_C_UAID_..." and need their soft Class reference resolved.
local spawnerClassCache = {}
local methodStats = {}
local getClassToSpawnBroken = false

local function classFromPath(path)
    if type(path) ~= "string" or path == "" or path == "None" then return nil end
    if string.find(path, ":", 1, true) or string.find(path, " ", 1, true) then return nil end
    local cls = string.match(path, "%.([%a][%w_]*)'?$") or string.match(path, "^([%a][%w_]*)$")
    if not cls or cls == "None" then return nil end
    if not string.find(cls, "_C$") then cls = cls .. "_C" end
    return cls
end

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
    arenaCache[boss.id] = { map = boss.map, unsupported = true }
    U.saveTable(ARENA_CACHE_PATH, arenaCache)
end

function M.learnArenas()
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
        local prev = arenaCache[id]
        local keep = false
        if prev and not prev.unsupported and prev.x then
            for _, cand in ipairs(c.list) do
                if U.dist(cand.loc, { X = prev.x, Y = prev.y, Z = prev.z }) < 500 then keep = true end
            end
        end
        if not keep then
            local b, s, loc = c.boss, c.list[1].spawner, c.list[1].loc
            local bell = M.nearestBell(b.map, loc)
            learned = learned + 1
            arenaCache[b.id] = {
                map = b.map,
                x = math.floor(loc.X), y = math.floor(loc.Y), z = math.floor(loc.Z),
                bell = bell and bell.id or "",
                spawnerId = U.str(s.SpawnerID),
            }
        end
    end
    if learned > 0 then
        U.saveTable(ARENA_CACHE_PATH, arenaCache)
        U.log("learned %d boss arena(s) in %s", learned, U.worldName())
    end
    return learned
end

-- ===== List shown in the bell menu =====

function M.availableBossesByMap()
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
