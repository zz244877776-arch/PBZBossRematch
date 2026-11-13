-- 宿敌再战：在铃铛菜单中选择已击败的 Boss 重新挑战，挑战结束后恢复存档并返回出发铃铛。

local U = require("util")
local Config = require("config")
local Data = require("gamedata")
local BellUI = require("bellui")
local Challenge = require("challenge")
local Save = require("savesnap")
local Streaming = require("streaming")
local TICK_MS = 300
local LEARN_INTERVAL_S = 30

U.log("===== PBZBossRematch loading (mod dir %s) =====", U.ModDir)

BellUI.OnBossChosen = function(boss)
    U.delay(400, "challenge.start", function() Challenge.start(boss) end)
end

local lastLearnAt = 0
local MAX_CHALLENGE_ERRORS = 5
local challengeErrors = 0

local function tickChallenge()
    local ok, err = pcall(Challenge.tick)
    if ok then
        challengeErrors = 0
        return
    end
    challengeErrors = challengeErrors + 1
    U.log("challenge tick error (%d): %s", challengeErrors, tostring(err))
    if challengeErrors >= MAX_CHALLENGE_ERRORS then
        challengeErrors = 0
        Challenge.forceEnd(err)
    end
end

local Toast = require("toast")

-- A new world or player controller frees the old widgets; forget them before anything touches them.
local worldKey = nil
local function forgetStaleWidgets()
    local key = U.worldName() .. "|" .. tostring(U.address(U.playerController()))
    if key == worldKey then return end
    if worldKey then U.log("world changed, dropping widget references") end
    worldKey = key
    BellUI.reset()
    Toast.reset()
    Streaming.forget()
end

LoopAsync(TICK_MS, function()
    U.gameThread("tick", function()
        forgetStaleWidgets()
        if Challenge.phase() == "reloading" and BellUI.menuOpen() then Challenge.onBellMenuOpen() end
        BellUI.tick(not Challenge.isActive())
        tickChallenge()
        if not Challenge.isActive() and os.time() - lastLearnAt >= LEARN_INTERVAL_S and U.playerPawn() and Streaming.idle() then
            lastLearnAt = os.time()
            Data.learnArenas()
        end
    end)
    return false
end)

local function tryHook(path, fn)
    local ok, err = pcall(RegisterHook, path, fn)
    U.log("hook %s: %s", path, ok and "ok" or tostring(err))
end

tryHook("/Script/CommonUI.CommonButtonBase:HandleButtonClicked", function(self)
    BellUI.handleClick(self:get())
end)

tryHook("/Script/CommonUI.CommonButtonBase:HandleFocusReceived", function(self)
    BellUI.onButtonFocused(self:get())
end)

tryHook("/Script/ProjectPBZ.PBZSaveLoadSubsystem:OnSaveGameFinished", function(self, slotName)
    if Challenge.isActive() then
        local slot = U.str(slotName:get())
        U.log("game saved during challenge: %s", slot)
        Save.noteSaved(slot)
    end
end)

tryHook("/Script/ProjectPBZ.PBZCodexSubsystem:OnCodexTrackedEnemyDied", function(self, died)
    Challenge.onEnemyDied(died:get())
end)

NotifyOnNewObject("/Script/UMG.UserWidget", function(widget)
    if Challenge.isActive() and U.className(widget) == "W_PlayerDead_C" then
        Challenge.onPlayerDeadWidget()
    end
end)

RegisterLoadMapPostHook(function()
    BellUI.reset()
    Toast.reset()
    U.gameThread("onMapLoaded", function() Challenge.onMapLoaded() end)
    lastLearnAt = os.time() - LEARN_INTERVAL_S + 10
end)

local function bindKey(name, fn)
    local key = Key[name]
    if not key then
        U.log("unknown key name in config: %s", tostring(name))
        return
    end
    RegisterKeyBind(key, function() U.gameThread("key " .. name, fn) end)
end

bindKey(Config.ExitKey, function() Challenge.quit() end)
if Config.EnableKillKey then
    bindKey(Config.KillKey, function() Challenge.killBoss() end)
end

U.gameThread("recover", function() Challenge.recoverIfNeeded() end)

U.log("PBZBossRematch loaded")
