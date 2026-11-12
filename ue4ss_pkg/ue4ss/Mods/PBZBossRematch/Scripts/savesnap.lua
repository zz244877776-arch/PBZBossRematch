local U = require("util")
local Config = require("config")

local M = {}

local STATE_PATH = U.DataDir .. "/challenge_state.lua"
local SNAPSHOT_DIR = U.DataDir .. "/snapshot"
local VETO_SOURCE = "PBZBossRematch"
local VETO_REASON_MODE_GATE = 2
local MAIN_SLOT = "PBZSaveGame"
local SAVE_ROOT = U.GameRoot .. "/ProjectPBZ/Saved/SaveGames/Steam"

local function saveSubsystem()
    return U.gameInstanceSubsystem("PBZSaveLoadSubsystem")
end

function M.continueSlotName()
    local sub = saveSubsystem()
    if sub then
        local ok, n = pcall(function() return sub:GetContinueSlotName() end)
        local s = ok and U.str(n) or ""
        if s ~= "" then return s end
    end
    return MAIN_SLOT
end

local function slotPath(slot)
    return M.SaveDir .. "/" .. slot .. ".sav"
end

local function snapshotPath(slot)
    return SNAPSHOT_DIR .. "/" .. slot:gsub("[/\\]", "__") .. ".sav"
end

function M.readState()
    return U.loadTable(STATE_PATH)
end

function M.writeState(state)
    return U.saveTable(STATE_PATH, state)
end

function M.clearState()
    os.remove(STATE_PATH)
end

-- ===== Rolling auto-saves =====
-- "Continue" loads the newest file in these folders, so saves written during a challenge must go.

local ROLLING_DIRS = { "1RealTime", "2Hourly", "3Daily" }
local savedDuringChallenge = {}

function M.noteSaved(slot)
    if slot and slot ~= "" then savedDuringChallenge[slot] = true end
end

local function listFiles(dir)
    local ok, p = pcall(io.popen, 'dir /b /a-d "' .. dir:gsub("/", "\\") .. '" 2>nul')
    if not ok or not p then return nil end
    local names = {}
    for line in p:lines() do table.insert(names, line) end
    p:close()
    return names
end

local function listDirsNewestFirst(dir)
    local ok, p = pcall(io.popen, 'dir /b /ad /o-d "' .. dir:gsub("/", "\\") .. '" 2>nul')
    if not ok or not p then return nil end
    local names = {}
    for line in p:lines() do table.insert(names, line) end
    p:close()
    return names
end

local function dirWithMainSave(id)
    if not id or id == "" then return nil end
    local dir = SAVE_ROOT .. "/" .. id
    if U.fileExists(dir .. "/" .. MAIN_SLOT .. ".sav") then return dir end
    return nil
end

-- A wrong SteamId (the installer used to keep only the first digit) must not block the challenge.
local function resolveSaveDir()
    local configured = dirWithMainSave(Config.SteamId)
    if configured then return configured end
    local names = listDirsNewestFirst(SAVE_ROOT)
    if names then
        for _, name in ipairs(names) do
            if name:match("^%d+$") then
                local dir = dirWithMainSave(name)
                if dir then
                    U.log("SteamId %q has no %s.sav, using folder %s", Config.SteamId, MAIN_SLOT, name)
                    return dir
                end
            end
        end
    end
    return SAVE_ROOT .. "/" .. (Config.SteamId or "")
end

M.SaveDir = resolveSaveDir()
U.log("save dir %s", M.SaveDir)

local SAVE_NAME_PATTERN = "^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d+%.sav$"

-- Newest rolling save name per folder; anything sorting after it was written during the challenge.
local function newestRollingSaves()
    local newest = {}
    for _, sub in ipairs(ROLLING_DIRS) do
        local names = listFiles(M.SaveDir .. "/" .. sub)
        if not names then return nil end
        local top = ""
        for _, name in ipairs(names) do
            if name:match(SAVE_NAME_PATTERN) and name > top then top = name end
        end
        newest[sub] = top
    end
    return newest
end

local function removeRollingSavesAfter(state)
    local fallbackCutoff = os.date("%Y%m%d-%H%M%S", state.createdAt) .. "-000.sav"
    local removed, listed = 0, false
    for _, sub in ipairs(ROLLING_DIRS) do
        local dir = M.SaveDir .. "/" .. sub
        local names = listFiles(dir)
        local cutoff = state.newestRolling and state.newestRolling[sub] or fallbackCutoff
        if names then
            listed = true
            for _, name in ipairs(names) do
                if name:match(SAVE_NAME_PATTERN) and name > cutoff and os.remove(dir .. "/" .. name) then
                    removed = removed + 1
                end
            end
        end
    end
    for slot in pairs(savedDuringChallenge) do
        local path = slotPath(slot)
        if slot ~= MAIN_SLOT and U.fileExists(path) and os.remove(path) then removed = removed + 1 end
    end
    savedDuringChallenge = {}
    U.log("removed %d rolling save(s) written during the challenge (dir listing %s, cutoff %s)",
        removed, listed and "ok" or "unavailable", state.newestRolling and "by name" or "by time")
end

-- Copies the current save files aside and records an active challenge, so a crash can be recovered on next launch.
function M.takeSnapshot(info)
    local slots = { MAIN_SLOT }
    local cont = M.continueSlotName()
    if cont ~= MAIN_SLOT then table.insert(slots, cont) end

    local saved = {}
    for _, slot in ipairs(slots) do
        local data = U.readFile(slotPath(slot))
        if data and #data > 0 then
            local ok, err = U.writeFile(snapshotPath(slot), data)
            if not ok then return false, "写入快照失败: " .. tostring(err) end
            table.insert(saved, { slot = slot, size = #data })
        end
    end
    if #saved == 0 then return false, "找不到存档文件: " .. slotPath(MAIN_SLOT) end

    savedDuringChallenge = {}
    info.active = true
    info.slots = saved
    info.newestRolling = newestRollingSaves()
    info.continueSlot = cont
    info.createdAt = os.time()
    M.writeState(info)
    U.log("snapshot taken: %d slot(s), continue=%s", #saved, cont)
    return true
end

function M.restoreFiles(state)
    state = state or M.readState()
    if not state or not state.slots then return false, "没有快照" end
    if state.createdAt then removeRollingSavesAfter(state) end
    local restored = 0
    for _, s in ipairs(state.slots) do
        local data = U.readFile(snapshotPath(s.slot))
        if data and #data == s.size then
            local ok, err = U.writeFile(slotPath(s.slot), data)
            if ok then restored = restored + 1 else U.log("restore %s failed: %s", s.slot, tostring(err)) end
        else
            U.log("snapshot for %s missing or size mismatch", s.slot)
        end
    end
    U.log("restored %d/%d save file(s)", restored, #state.slots)
    return restored == #state.slots
end

function M.enterVeto()
    local sub = saveSubsystem()
    if not sub then return false end
    local ok, err = pcall(function() sub:EnterSaveVeto(FName(VETO_SOURCE), VETO_REASON_MODE_GATE) end)
    U.log("EnterSaveVeto ok=%s %s", tostring(ok), ok and "" or tostring(err))
    return ok
end

function M.exitVeto()
    local sub = saveSubsystem()
    if not sub then return false end
    local ok, err = pcall(function() sub:ExitSaveVeto(FName(VETO_SOURCE)) end)
    U.log("ExitSaveVeto ok=%s %s", tostring(ok), ok and "" or tostring(err))
    return ok
end

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

function M.reloadSlot(slot)
    local cm = cheatManager()
    if not cm then
        U.log("reload failed: no cheat manager")
        return false
    end
    local ok, err = pcall(function() cm:GM_LoadGame(slot) end)
    U.log("GM_LoadGame(%s) ok=%s %s", slot, tostring(ok), ok and "" or tostring(err))
    return ok
end

return M
