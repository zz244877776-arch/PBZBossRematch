local Config = require("config")

local M = {}

local scriptPath = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
M.ScriptDir = scriptPath:match("^(.*)/[^/]+$") or "."
M.ModDir = M.ScriptDir:match("^(.*)/Scripts$") or M.ScriptDir
M.GameRoot = M.ModDir:match("^(%a:.*)/platform/steam/ue4ss/Mods/[^/]+$") or Config.GameRoot
if not M.ModDir:match("^%a:") then
    M.ModDir = Config.GameRoot .. "/platform/steam/ue4ss/Mods/PBZBossRematch"
end
M.DataDir = M.ModDir .. "/data"

local logFile = io.open(M.DataDir .. "/rematch.log", "a")

function M.log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    print("[BossRematch] " .. msg .. "\n")
    if logFile then
        logFile:write(os.date("[%m-%d %H:%M:%S] "), msg, "\n")
        logFile:flush()
    end
end

function M.str(v)
    if v == nil then return "" end
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return tostring(v) end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and s then return s end
    return tostring(v)
end

function M.unwrap(v)
    local ok, r = pcall(function() return v:get() end)
    if ok and r ~= nil then return r end
    return v
end

function M.valid(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

function M.fullName(obj)
    local ok, n = pcall(function() return obj:GetFullName() end)
    return ok and n or "<?>"
end

function M.className(obj)
    local ok, n = pcall(function() return obj:GetClass():GetFName():ToString() end)
    return ok and n or ""
end

function M.address(obj)
    local ok, a = pcall(function() return obj:GetAddress() end)
    return ok and a or nil
end

-- Lua wrappers must not be kept across frames: once the engine frees the object, touching the
-- wrapper (even IsValid) can crash UE4SS. Keep the address and look the object up again here.
function M.live(className, addr)
    if not addr then return nil end
    for _, o in ipairs(FindAllOf(className) or {}) do
        if M.address(o) == addr then return o end
    end
    return nil
end

function M.location(actor)
    local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
    if ok and loc then return { X = loc.X, Y = loc.Y, Z = loc.Z } end
    return nil
end

function M.dist(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Ground-level sanity: World-Partition soft / unloaded actors often report Z≈1e6–3e6 (void junk).
-- Valid outdoor/cave arenas stay within ~±20k (e.g. 新娘阿花). Bell_NLES_001 at Z≈-32510 is void.
-- Real sky pockets (龙柱试炼 / 暗魔天堡) sit around Z≥1e7. Mid-range junk must NOT count as sky —
-- the old Z≥1e5 threshold mistook 拳痴：铁狂 soft coords (Z≈2e6) for a pocket arena.
M.MAX_SANE_ABS_Z = 28000
M.SKY_ARENA_MIN_Z = 5000000

function M.saneWorldLoc(loc)
    if not loc then return false end
    local z = loc.Z
    if z == nil then z = loc.z end
    if type(z) ~= "number" then return false end
    return math.abs(z) < M.MAX_SANE_ABS_Z
end

function M.isSkyArenaLoc(loc)
    if not loc then return false end
    local z = loc.Z
    if z == nil then z = loc.z end
    return type(z) == "number" and z >= M.SKY_ARENA_MIN_Z
end

function M.teleportAllowedLoc(loc)
    return M.saneWorldLoc(loc) or M.isSkyArenaLoc(loc)
end

-- After player death, UE often leaves a soft actor at the world origin. Freezing that
-- does nothing to the real sky-arena boss still fighting at Z≈1e7.
function M.isSoftWorldLoc(loc)
    if not loc then return true end
    local x = loc.X or loc.x or 0
    local y = loc.Y or loc.y or 0
    local z = loc.Z or loc.z or 0
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return true end
    return math.abs(x) < 100 and math.abs(y) < 100 and math.abs(z) < 100
end

function M.horizDist(a, b)
    if not a or not b then return math.huge end
    local dx, dy = a.X - b.X, a.Y - b.Y
    return math.sqrt(dx * dx + dy * dy)
end

function M.readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("a")
    f:close()
    return data
end

function M.writeFile(path, data)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    f:write(data)
    f:close()
    return true
end

function M.fileExists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function serialize(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "table" then
        local parts = { "{\n" }
        local keys = {}
        for k in pairs(v) do table.insert(keys, k) end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            local key = type(k) == "string" and string.format("[%q]", k) or string.format("[%s]", tostring(k))
            table.insert(parts, indent .. "  " .. key .. " = " .. serialize(v[k], indent .. "  ") .. ",\n")
        end
        table.insert(parts, indent .. "}")
        return table.concat(parts)
    elseif t == "string" then
        return string.format("%q", v)
    else
        return tostring(v)
    end
end

function M.saveTable(path, tbl)
    return M.writeFile(path, "return " .. serialize(tbl) .. "\n")
end

function M.loadTable(path)
    local chunk = loadfile(path)
    if not chunk then return nil end
    local ok, t = pcall(chunk)
    if ok and type(t) == "table" then return t end
    return nil
end

function M.playerController()
    local pcs = FindAllOf("PlayerController") or {}
    for _, pc in ipairs(pcs) do
        local ok, isLocal = pcall(function() return pc:IsLocalPlayerController() end)
        if ok and isLocal then return pc end
    end
    return pcs[1]
end

function M.playerPawn()
    local pc = M.playerController()
    if not M.valid(pc) then return nil end
    local ok, pawn = pcall(function() return pc.Pawn end)
    if ok and M.valid(pawn) then return pawn end
    return nil
end

function M.worldName()
    local pc = M.playerController()
    local ok, n = pcall(function() return pc:GetWorld():GetFullName() end)
    return ok and n or ""
end

-- World subsystems survive in memory for a while after a level change, so pick the one in the player's world.
function M.worldSubsystem(className)
    local world = M.worldName()
    local first = nil
    for _, s in ipairs(FindAllOf(className) or {}) do
        if M.valid(s) then
            first = first or s
            local ok, w = pcall(function() return s:GetWorld():GetFullName() end)
            if ok and w == world then return s end
        end
    end
    return first
end

function M.gameInstanceSubsystem(className)
    for _, s in ipairs(FindAllOf(className) or {}) do
        if M.valid(s) then return s end
    end
    return nil
end

function M.transformTable(t)
    return {
        Rotation = { X = t.Rotation.X, Y = t.Rotation.Y, Z = t.Rotation.Z, W = t.Rotation.W },
        Translation = { X = t.Translation.X, Y = t.Translation.Y, Z = t.Translation.Z },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
end

-- Prefer TeleportTransform when its Z is sane; otherwise fall back to BellLocation.
function M.bellTravelTransform(bell)
    if not bell then return nil end
    local t = bell.transform
    if t and M.saneWorldLoc(t.Translation) then return t end
    if M.saneWorldLoc(bell.loc) then
        return {
            Rotation = (t and t.Rotation) or { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
            Translation = { X = bell.loc.X, Y = bell.loc.Y, Z = bell.loc.Z },
            Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
        }
    end
    return t
end

function M.gameThread(name, fn)
    ExecuteInGameThread(function()
        local ok, err = pcall(fn)
        if not ok then M.log("%s error: %s", name, tostring(err)) end
    end)
end

-- UE4SS sometimes loses a delayed callback: UE4SS.log then shows
-- "[Lua::Registry::get_function_ref] Ref was not function" and the timer never fires (seen once
-- between the reveal and the countdown, which left the boss frozen until the fight was aborted).
-- Every delay is therefore also kept here, and the game-thread tick runs the ones UE4SS dropped.
local timers = {}
local timerSeq = 0
local TIMER_LATE_S = 0.3

local function fireTimer(id)
    local t = timers[id]
    if not t then return end
    timers[id] = nil
    t.fn()
end

function M.delay(ms, name, fn)
    timerSeq = timerSeq + 1
    local id = timerSeq
    timers[id] = { due = os.clock() + ms / 1000, name = name, fn = fn }
    ExecuteWithDelay(ms, function()
        M.gameThread(name, function() fireTimer(id) end)
    end)
end

-- Game thread only. Runs timers that are overdue, oldest first.
function M.pumpTimers()
    local now = os.clock()
    local overdue = {}
    for id, t in pairs(timers) do
        if now - t.due >= TIMER_LATE_S then table.insert(overdue, { id = id, due = t.due }) end
    end
    if #overdue == 0 then return end
    table.sort(overdue, function(a, b)
        if a.due ~= b.due then return a.due < b.due end
        return a.id < b.id
    end)
    for _, entry in ipairs(overdue) do
        local t = timers[entry.id]
        if t then
            M.log("timer %s did not fire; run from the tick %.1fs late", t.name, now - t.due)
            local ok, err = pcall(fireTimer, entry.id)
            if not ok then M.log("%s error: %s", t.name, tostring(err)) end
        end
    end
end

return M
