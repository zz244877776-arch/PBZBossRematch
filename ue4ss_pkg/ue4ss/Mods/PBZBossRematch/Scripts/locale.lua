-- In-game UI strings (Chinese / English). Language follows resolved game text by default.
local U = require("util")
local Config = require("config")

local M = {}
-- gamedata is required lazily inside refresh() to avoid a circular require.

local STRINGS = {
    zh = {
        entry_label = "宿敌再战",
        exit_label = "退出挑战",
        back = "返回",
        rematch = "再战",
        quit = "退出",
        victory_title = "挑战成功：%s",
        choice_enabled = "已开启：胜利后选择再战或退出（%s 关闭）",
        choice_disabled = "已关闭：胜利后直接返回铃铛（%s 开启选择）",

        loading = "宿敌再战：%s  %s",
        going = "前往中…",
        first_visit_slow = "首次前往该地图，加载较慢…",
        loading_boss = "加载 Boss…",
        loading_sky = "加载天空擂台…",
        triggering_seq = "触发序列擂台…",
        positioning = "就位中…",
        spawning_boss = "刷出 Boss…",
        locating = "正在定位 %s（%d/%d）",

        already_challenging = "已经在挑战中",
        unsupported = "%s 暂不支持再战",
        unsupported_no_spawner = "%s 暂不支持再战（找不到刷怪点）",
        unsupported_no_map_spawner = "%s 暂不支持再战（地图中没有它的刷怪点）",
        no_bell_for_map = "找不到前往该地图的铃铛",
        no_bell_level = "找不到铃铛所在关卡",
        cannot_start = "无法开始挑战：%s",
        travel_timeout = "传送超时",
        spawn_failed = "刷出 Boss 失败",
        boss_load_failed = "Boss 加载失败",
        boss_missing_end = "Boss 没有出现",
        boss_missing_named = "%s 没有出现，挑战结束",
        boss_spawn_fail_end = "Boss 未能刷出，挑战结束",
        boss_lost_end = "Boss 丢失，挑战结束",
        seq_arena_fail = "%s 序列擂台未能刷出 Boss",
        sky_arena_fail = "%s 天空擂台未能加载（刷怪点未出现）",
        sky_coords_missing = "%s 天空擂台坐标缺失，请先在原流程打过一次后再试",
        stream_fail = "没能加载地图其他区域，暂时无法定位 %s",
        locate_stream_fail = "无法定位 Boss（加载区域失败）",

        fight_start = "开战：%s",
        countdown = "准备迎战 %s  %d",
        rematch_again = "再次迎战：%s",
        victory_return = "挑战成功：%s，即将返回",
        victory = "挑战成功：%s",
        quitting_return = "退出挑战，正在返回出发铃铛…",
        next_stage = "下一阶段：%s",
        next_stage_loading = "正在加载下一阶段：%s，请稍候…",
        next_stage_soon = "即将进入下一阶段：%s，请稍候…",
        defeat_respawn = "战败：在 Boss 面前复活…",
        defeat_return = "挑战失败，即将返回",
        done_near_boss_bell = "挑战完成，已回到 Boss 附近铃铛",
        done_start_bell = "已退出挑战，回到出发铃铛",
        done_returned = "已返回出发铃铛",
        error_returning = "宿敌再战出错，正在返回",
        save_restore_fail = "存档恢复失败，请查看 rematch.log",
        reload_fail_manual = "读档失败：存档已恢复，请手动回到主菜单读档",

        no_challengable = "没有可再战的 Boss",
        unsupported_tag = "（暂不支持）",
        not_scouted_tag = "（未勘察）",
        map_count = "%s（%d）",
    },
    en = {
        entry_label = "Boss Rematch",
        exit_label = "Quit Challenge",
        back = "Back",
        rematch = "Rematch",
        quit = "Quit",
        victory_title = "Victory: %s",
        choice_enabled = "On: choose Rematch or Quit after victory (%s to turn off)",
        choice_disabled = "Off: return to the bell after victory (%s to enable choice)",

        loading = "Boss Rematch: %s  %s",
        going = "Traveling…",
        first_visit_slow = "First visit to this map — loading may take longer…",
        loading_boss = "Loading boss…",
        loading_sky = "Loading sky arena…",
        triggering_seq = "Triggering sequence arena…",
        positioning = "Getting ready…",
        spawning_boss = "Spawning boss…",
        locating = "Locating %s (%d/%d)",

        already_challenging = "Already in a challenge",
        unsupported = "%s rematch is not supported yet",
        unsupported_no_spawner = "%s rematch unavailable (spawner not found)",
        unsupported_no_map_spawner = "%s rematch unavailable (no spawner on this map)",
        no_bell_for_map = "No bell found for that map",
        no_bell_level = "Could not resolve the bell's level",
        cannot_start = "Could not start challenge: %s",
        travel_timeout = "Travel timed out",
        spawn_failed = "Failed to spawn boss",
        boss_load_failed = "Failed to load boss",
        boss_missing_end = "Boss did not appear",
        boss_missing_named = "%s did not appear — challenge ended",
        boss_spawn_fail_end = "Boss failed to spawn — challenge ended",
        boss_lost_end = "Boss was lost — challenge ended",
        seq_arena_fail = "%s sequence arena failed to spawn the boss",
        sky_arena_fail = "%s sky arena failed to load (spawner missing)",
        sky_coords_missing = "%s sky arena coords missing — clear it once in the story first",
        stream_fail = "Could not stream other map regions — cannot locate %s yet",
        locate_stream_fail = "Could not locate boss (region load failed)",

        fight_start = "Fight: %s",
        countdown = "Ready for %s  %d",
        rematch_again = "Rematch: %s",
        victory_return = "Victory: %s — returning soon",
        victory = "Victory: %s",
        quitting_return = "Leaving challenge — returning to start bell…",
        next_stage = "Next phase: %s",
        next_stage_loading = "Loading next phase: %s…",
        next_stage_soon = "Entering next phase: %s…",
        defeat_respawn = "Defeat — respawning at the boss…",
        defeat_return = "Challenge failed — returning soon",
        done_near_boss_bell = "Done — back at the nearby bell",
        done_start_bell = "Left challenge — back at the start bell",
        done_returned = "Returned to the start bell",
        error_returning = "Boss Rematch error — returning",
        save_restore_fail = "Save restore failed — see rematch.log",
        reload_fail_manual = "Reload failed: saves restored — load manually from the title menu",

        no_challengable = "No rematchable bosses",
        unsupported_tag = " (unsupported)",
        not_scouted_tag = " (not scouted)",
        map_count = "%s (%d)",
    },
}

local cachedCode = nil
local cachedCulture = nil

local function normalizeCode(raw)
    if not raw or raw == "" then return nil end
    local s = string.lower(tostring(raw))
    s = string.gsub(s, "%s+", "")
    if s == "zh" or string.find(s, "^zh") or string.find(s, "chinese") or string.find(s, "hans") or string.find(s, "hant") then
        return "zh"
    end
    if s == "en" or string.find(s, "^en") or string.find(s, "english") then
        return "en"
    end
    -- Other game languages: fall back to English UI for the mod.
    return "en"
end

-- UTF-8 CJK Unified Ideographs (common 3-byte sequences).
local function hasCjk(s)
    if not s or s == "" then return false end
    return string.find(s, "[\228-\233][\128-\191][\128-\191]") ~= nil
end

local function codeFromText(s)
    if not s or s == "" then return nil end
    if hasCjk(s) then return "zh" end
    if string.find(s, "[A-Za-z]") then return "en" end
    return nil
end

-- Prefer already-rendered UI / resolved loc strings. Do NOT Create scratch widgets just to
-- probe language — that hard-crashes CommonUI while the bell menu is open.
local textHintCode = nil
local textHintSample = nil
-- Once the live bell menu labels decide the language, ignore ValueCache/Hans flips mid-list.
local menuSticky = false

local function applyCode(code, tag, wipeCaches)
    local prev = cachedCode
    cachedCode = code
    cachedCulture = tag or code
    if wipeCaches and prev ~= cachedCode then
        pcall(function()
            local Data = require("gamedata")
            Data.clearBossRows()
            pcall(function() require("bellui").clearLocCache() end)
        end)
    end
    return cachedCode
end

-- Soft hint from a resolved loc string. Never overrides menuSticky; never treats baked
-- Chinese ValueCache as authority after the menu already chose English.
function M.observeText(s)
    local forced = Config.Language
    if forced and forced ~= "" and forced ~= "auto" then return cachedCode end
    if menuSticky then return cachedCode end
    local code = codeFromText(s)
    if not code then return cachedCode end
    textHintCode, textHintSample = code, s
    if cachedCode ~= code then
        U.log("locale observeText -> %s (%s)", code, tostring(s))
        cachedCode = code
        cachedCulture = "text:" .. tostring(s)
    end
    return cachedCode
end

-- Inspect live bell-menu button labels (already localized by the game). Safe to wipe
-- caches here: called during inject before any list is built.
-- Prefer Latin if any sample is English (avoids one stale CJK label flipping the whole UI).
function M.observeMenuTexts(texts)
    if not texts then return cachedCode end
    local zhSample, enSample = nil, nil
    for _, s in ipairs(texts) do
        local code = codeFromText(s)
        if code == "en" and not enSample then enSample = s end
        if code == "zh" and not zhSample then zhSample = s end
    end
    local sample = enSample or zhSample
    if not sample then return cachedCode end
    local code = enSample and "en" or "zh"
    textHintCode, textHintSample = code, sample
    menuSticky = true
    if cachedCode ~= code then
        U.log("locale observeMenuTexts -> %s (%s)", code, tostring(sample))
        return applyCode(code, "text:" .. tostring(sample), true)
    end
    cachedCode = code
    cachedCulture = "text:" .. tostring(sample)
    return cachedCode
end

local function detectFromApis()
    local ctx = U.playerController()
    local candidates = {}

    local pbz = StaticFindObject("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
    if U.valid(pbz) and U.valid(ctx) then
        pcall(function() table.insert(candidates, U.str(pbz:GetCurrentLanguage(ctx))) end)
        pcall(function() table.insert(candidates, U.str(pbz:GetCurrentCulture(ctx))) end)
    end

    local kis = StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary")
    if U.valid(kis) then
        pcall(function() table.insert(candidates, U.str(kis:GetCurrentLanguage())) end)
        pcall(function() table.insert(candidates, U.str(kis:GetCurrentCulture())) end)
    end

    for _, c in ipairs(candidates) do
        if c and c ~= "" and c ~= "None" then
            local code = normalizeCode(c)
            if code then return code, c end
        end
    end
    return "zh", "zh-Hans"
end

function M.refresh()
    local forced = Config.Language
    if forced and forced ~= "" and forced ~= "auto" then
        return applyCode(normalizeCode(forced) or "zh", forced, true)
    end
    -- Trust previously observed game text over Steam Culture (often stuck on zh-Hans).
    if textHintCode then
        return applyCode(textHintCode, "text:" .. tostring(textHintSample or ""), true)
    end
    local code, tag = detectFromApis()
    return applyCode(code, tag, true)
end

function M.code()
    if not cachedCode then M.refresh() end
    return cachedCode or "zh"
end

function M.culture()
    if not cachedCode then M.refresh() end
    return cachedCulture or ""
end

function M.isZh()
    return M.code() == "zh"
end

local function tableFor(code)
    return STRINGS[code] or STRINGS.en
end

function M.T(key, ...)
    local tab = tableFor(M.code())
    local fmt = tab[key] or STRINGS.zh[key] or STRINGS.en[key] or key
    if select("#", ...) > 0 then
        local ok, s = pcall(string.format, fmt, ...)
        if ok then return s end
    end
    return fmt
end

function M.entryLabel()
    if Config.EntryLabel and Config.EntryLabel ~= "" then return Config.EntryLabel end
    return M.T("entry_label")
end

function M.exitLabel()
    if Config.ExitLabel and Config.ExitLabel ~= "" then return Config.ExitLabel end
    return M.T("exit_label")
end

return M
