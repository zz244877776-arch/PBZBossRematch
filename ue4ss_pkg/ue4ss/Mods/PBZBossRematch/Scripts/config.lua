-- 宿敌再战 配置
return {
    -- 游戏安装目录（自动识别失败时使用）
    GameRoot = "",

    -- 存档所在的 Steam 用户文件夹名（ProjectPBZ/Saved/SaveGames/Steam/ 下的数字文件夹）
    SteamId = "",

    -- 挑战中主动退出并返回出发铃铛（Home 快捷键 + 系统菜单「退出游戏」页里的按钮）
    ExitKey = "HOME",
    ExitLabel = "退出挑战",
    -- 「退出挑战」按钮在「退出游戏」页里的位置，都是屏幕高度的比例：X 从屏幕左边算起，Y 从顶部算起。
    -- 默认值对应列表第四行；位置偏了就改这两个数。
    ExitButtonX = 0.087,
    ExitButtonY = 0.49,

    -- 挑战中一键击杀当前 Boss（测试用，设为 false 关闭；UE4SS 键名是 DEL）
    EnableKillKey = true,
    KillKey = "DEL",

    -- 胜利 / 失败后多久自动返回（毫秒）。胜利稍长一点，留给「斩」字和死亡演出。
    VictoryReturnDelayMs = 8000,
    DefeatReturnDelayMs = 7000,

    -- 战败「陨落」UI 至少播放多久后再在 Boss 前复活（毫秒）。
    -- 不要等控件自行消失——游戏往往会一直挂着 W_PlayerDead 直到复活。
    DefeatUiMs = 5500,

    -- 前往 Boss 时先黑屏，等场景和 Boss 加载完成后再显示画面
    LoadingCurtain = true,

    -- 画面出现后 Boss 定格的倒计时秒数（0 = 不倒计时）
    CountdownSeconds = 3,

    -- 不在列表中显示的图鉴条目（Lua 匹配模式，匹配图鉴行名）
    -- 多阶段 Boss 的后续阶段由第一阶段自动转入，不能单独挑战
    HiddenBossPatterns = { "_P2$", "Variants$", "_Tutorial$" },

    -- 是否只显示已在图鉴中解锁的 Boss
    OnlyDiscovered = true,

    -- 铃铛菜单入口按钮文字
    EntryLabel = "宿敌再战",

    -- 挑战胜利后弹出「再战 / 退出」选择（默认关，保持原先「斩」后回铃铛）。
    -- 游戏内按下面的键开关；开关状态会写入 data/prefs.lua。
    PostFightChoiceEnabled = false,
    PostFightChoiceToggleKey = "F8",
    -- 弹出选择前先等「斩」字演出（毫秒）
    PostFightChoiceDelayMs = 2500,
}
