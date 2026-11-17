# UI / log strings for the one-click installer (Chinese and English).
# build_dist.py ships these scripts as UTF-16 LE for Windows PowerShell 5.1.

$script:InstallerLang = 'zh'

$InstallerStrings = @{
    zh = @{
        FormTitle       = "宿敌再战 Mod 一键安装工具"
        Title           = "《影之刃零》宿敌再战 Mod"
        Hint            = "选择游戏程序（PBZ.exe）或游戏安装文件夹，然后点击「安装 / 更新」。安装前请先关闭游戏。"
        LangLabel       = "语言"
        PickExe         = "选择游戏程序…"
        PickDir         = "选择游戏文件夹…"
        AutoFind        = "自动查找"
        ChkUe4ss        = "安装 / 更新 UE4SS 框架（Mod 运行必需；已装过可不勾选）"
        ChkBackup       = "安装前备份存档（保存到游戏目录下的 _rematch_backup 文件夹）"
        Install         = "安装 / 更新"
        Uninstall       = "卸载"
        OpenDoc         = "打开使用说明"
        OpenDocEn       = "English Guide"
        ConfirmTitle    = "确认"
        TipTitle        = "提示"
        DoneTitle       = "完成"
        ErrorTitle      = "错误"
        StatusInvalid   = "这个位置不是《影之刃零》的安装目录。"
        StatusEmpty     = "尚未选择游戏位置。"
        StatusLine      = "游戏目录：{0}    UE4SS：{1}    本 Mod：{2}"
        Installed       = "已安装"
        NotInstalled    = "未安装"
        DlgExeTitle     = "选择《影之刃零》游戏程序"
        DlgExeFilter    = "影之刃零 (PBZ.exe)|PBZ.exe|程序 (*.exe)|*.exe"
        DlgDirDesc      = "选择《影之刃零》安装文件夹（一般是 steamapps\common\PBZ）"
        GameRunning     = "游戏正在运行，请先完全退出游戏再安装。"
        GameRunningUn   = "游戏正在运行，请先完全退出游戏再卸载。"
        InstallDone     = "安装完成！启动游戏后，在铃铛菜单中选择「宿敌再战」即可。"
        InstallFail     = "安装失败：{0}"
        ConfirmUninstall = "确定要卸载宿敌再战 Mod 吗？"
        UninstallFail   = "卸载失败：{0}"
        AutoFound       = "已自动找到游戏：{0}"
        AutoNotFound    = "没有自动找到游戏，请点击「选择游戏程序」或「选择游戏文件夹」。"
        SteamFound      = "在 Steam 库中找到游戏：{0}"
        SteamNotFound   = "没有在 Steam 库中自动找到游戏，请手动选择。"
        DocEnMissing    = "找不到英文说明：{0}"
        LogBackup       = "已备份存档到：{0}"
        LogNoSaves      = "未找到存档文件夹，跳过备份。"
        LogUe4ssUpdated = "已更新 UE4SS 框架（保留了你原有的 mods.txt 和 UE4SS-settings.ini）。"
        LogUe4ssInstalled = "已安装 UE4SS 框架。"
        LogUe4ssKeep    = "检测到已安装的 UE4SS，保持不变。"
        LogModUpdated   = "已更新 Mod 脚本（保留了你原有的 config.lua 设置）。"
        LogModInstalled = "已安装 Mod 脚本。"
        LogSaveFolder   = "存档文件夹：ProjectPBZ\Saved\SaveGames\Steam\{0}"
        LogMultiSave    = "（发现多个存档文件夹，已选择最近使用的那个。如需更换，请修改 config.lua 中的 SteamId。）"
        LogNoSaveWarn   = "警告：还没有找到存档文件夹。请先进游戏存一次档，再重新运行本工具。"
        LogModsEnabled  = "已在 mods.txt 中启用 {0}。"
        LogDocCopied    = "使用说明已复制到游戏目录：{0}"
        LogDocEnCopied  = "English guide copied: {0}"
        LogInstallDone  = "安装完成。启动游戏后，在铃铛菜单中即可看到「宿敌再战」。"
        LogModMissing   = "没有找到已安装的 {0}。"
        ConfirmUnfinished = "检测到一场没有正常结束的挑战（存档快照尚未恢复）。`r`n`r`n建议先启动一次游戏，让 Mod 自动恢复存档后再卸载。`r`n`r`n仍然要卸载吗？"
        LogUninstallCancel = "已取消卸载。"
        LogModRemoved   = "已删除 {0}。"
        ConfirmRemoveUe4ss = "UE4SS 框架是本工具安装的。要一起删除吗？`r`n（如果你还装了其他依赖 UE4SS 的 Mod，请选「否」。）"
        LogUe4ssRemoved = "已删除 UE4SS 框架。"
        LogUninstallDone = "卸载完成。"
    }
    en = @{
        FormTitle       = "Boss Rematch - One-click Installer"
        Title           = "Phantom Blade Zero - Boss Rematch"
        Hint            = "Select PBZ.exe or the game install folder, then click Install / Update. Fully quit the game first."
        LangLabel       = "Language"
        PickExe         = "Choose game exe..."
        PickDir         = "Choose game folder..."
        AutoFind        = "Auto-detect"
        ChkUe4ss        = "Install / update UE4SS (required; uncheck if already installed)"
        ChkBackup       = "Back up saves before install (to _rematch_backup under the game folder)"
        Install         = "Install / Update"
        Uninstall       = "Uninstall"
        OpenDoc         = "Chinese Guide"
        OpenDocEn       = "English Guide"
        ConfirmTitle    = "Confirm"
        TipTitle        = "Notice"
        DoneTitle       = "Done"
        ErrorTitle      = "Error"
        StatusInvalid   = "This path is not a Phantom Blade Zero install folder."
        StatusEmpty     = "No game location selected yet."
        StatusLine      = "Game: {0}    UE4SS: {1}    Mod: {2}"
        Installed       = "Installed"
        NotInstalled    = "Not installed"
        DlgExeTitle     = "Select Phantom Blade Zero (PBZ.exe)"
        DlgExeFilter    = "Phantom Blade Zero (PBZ.exe)|PBZ.exe|Programs (*.exe)|*.exe"
        DlgDirDesc      = "Select the game folder (usually steamapps\common\PBZ)"
        GameRunning     = "The game is running. Fully quit it before installing."
        GameRunningUn   = "The game is running. Fully quit it before uninstalling."
        InstallDone     = "Install complete! In-game, open any bell and choose Boss Rematch."
        InstallFail     = "Install failed: {0}"
        ConfirmUninstall = "Uninstall Boss Rematch?"
        UninstallFail   = "Uninstall failed: {0}"
        AutoFound       = "Found game automatically: {0}"
        AutoNotFound    = "Could not auto-detect the game. Choose the exe or folder manually."
        SteamFound      = "Found game in Steam libraries: {0}"
        SteamNotFound   = "Not found in Steam libraries. Please choose manually."
        DocEnMissing    = "English guide not found: {0}"
        LogBackup       = "Save backup created: {0}"
        LogNoSaves      = "No save folder found; skipped backup."
        LogUe4ssUpdated = "Updated UE4SS (kept your existing mods.txt and UE4SS-settings.ini)."
        LogUe4ssInstalled = "Installed UE4SS."
        LogUe4ssKeep    = "Existing UE4SS detected; left unchanged."
        LogModUpdated   = "Updated mod scripts (kept your existing config.lua)."
        LogModInstalled = "Installed mod scripts."
        LogSaveFolder   = "Save folder: ProjectPBZ\Saved\SaveGames\Steam\{0}"
        LogMultiSave    = "(Multiple save folders found; picked the most recently used. Change SteamId in config.lua if needed.)"
        LogNoSaveWarn   = "Warning: no save folder yet. Launch the game once, save, then re-run this tool."
        LogModsEnabled  = "Enabled {0} in mods.txt."
        LogDocCopied    = "Chinese guide copied to game folder: {0}"
        LogDocEnCopied  = "English guide copied: {0}"
        LogInstallDone  = "Install complete. Open any bell in-game to see Boss Rematch."
        LogModMissing   = "{0} is not installed."
        ConfirmUnfinished = "An unfinished rematch was detected (save snapshot not restored yet).`r`n`r`nLaunch the game once so the mod can restore the save, then uninstall.`r`n`r`nUninstall anyway?"
        LogUninstallCancel = "Uninstall cancelled."
        LogModRemoved   = "Removed {0}."
        ConfirmRemoveUe4ss = "UE4SS was installed by this tool. Remove it too?`r`n(Choose No if you still use other UE4SS mods.)"
        LogUe4ssRemoved = "Removed UE4SS."
        LogUninstallDone = "Uninstall complete."
    }
}

function Get-InstallerLang {
    return $script:InstallerLang
}

function Set-InstallerLang([string]$lang) {
    if ($lang -ne 'en' -and $lang -ne 'zh') { $lang = 'zh' }
    $script:InstallerLang = $lang
}

function T {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(ValueFromRemainingArguments = $true)]$FormatArgs
    )
    $table = $InstallerStrings[$script:InstallerLang]
    if (-not $table -or -not $table.ContainsKey($Key)) {
        $table = $InstallerStrings['zh']
    }
    $text = [string]$table[$Key]
    $argsList = @($FormatArgs)
    if ($argsList.Count -gt 0) {
        return [string]::Format($text, [object[]]$argsList)
    }
    return $text
}

function Get-DefaultInstallerLang {
    try {
        $name = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
        if ($name -eq 'en') { return 'en' }
    } catch {}
    return 'zh'
}
