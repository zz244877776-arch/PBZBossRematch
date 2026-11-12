-- 宿敌再战 配置
return {
    -- 游戏安装目录（自动识别失败时使用）
    GameRoot = "",

    -- 存档所在的 Steam 用户文件夹名（ProjectPBZ/Saved/SaveGames/Steam/ 下的数字文件夹）
    SteamId = "",

    -- 挑战中主动退出并返回出发铃铛
    ExitKey = "HOME",

    -- 挑战中一键击杀当前 Boss（测试用，设为 false 关闭）
    EnableKillKey = true,
    KillKey = "END",

    -- 胜利 / 失败后多久自动返回（毫秒）。胜利稍长一点，留给「斩」字和死亡演出。
    VictoryReturnDelayMs = 8000,
    DefeatReturnDelayMs = 7000,

    -- 不在列表中显示的图鉴条目（Lua 匹配模式，匹配图鉴行名）
    -- 多阶段 Boss 的后续阶段由第一阶段自动转入，不能单独挑战
    HiddenBossPatterns = { "_P2$", "Variants$", "_Tutorial$" },

    -- 是否只显示已在图鉴中解锁的 Boss
    OnlyDiscovered = true,

    -- 铃铛菜单入口按钮文字
    EntryLabel = "宿敌再战",
}
