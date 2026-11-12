# 宿敌再战 Mod 安装逻辑（被 installer.ps1 引用，也可单独加载做测试）

$PackageRoot = Split-Path -Parent $PSScriptRoot
$Payload = Join-Path $PackageRoot 'payload'
$ModName = 'PBZBossRematch'
$DocName = '宿敌再战Mod_使用说明.md'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---------------- 路径识别 ----------------

function Test-GameRoot([string]$dir) {
    if (-not $dir) { return $false }
    return (Test-Path -LiteralPath (Join-Path $dir 'platform\steam\PBZ.exe')) -and
           (Test-Path -LiteralPath (Join-Path $dir 'ProjectPBZ'))
}

function Resolve-GameRoot([string]$path) {
    if (-not $path) { return $null }
    $path = $path.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $dir = if (Test-Path -LiteralPath $path -PathType Leaf) { Split-Path -Parent $path } else { $path }
    for ($i = 0; $i -lt 5 -and $dir; $i++) {
        if (Test-GameRoot $dir) { return (Resolve-Path -LiteralPath $dir).Path }
        $dir = Split-Path -Parent $dir
    }
    return $null
}

function Find-SteamGame {
    $steamPaths = @()
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            if ($p.SteamPath) { $steamPaths += $p.SteamPath }
            if ($p.InstallPath) { $steamPaths += $p.InstallPath }
        } catch {}
    }
    $libraries = @()
    foreach ($sp in ($steamPaths | Select-Object -Unique)) {
        $sp = $sp -replace '/', '\'
        $libraries += $sp
        $vdf = Join-Path $sp 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libraries += ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    foreach ($lib in ($libraries | Select-Object -Unique)) {
        $candidate = Join-Path $lib 'steamapps\common\PBZ'
        if (Test-GameRoot $candidate) { return $candidate }
    }
    return $null
}

function Get-SteamSaveIds([string]$root) {
    $dir = Join-Path $root 'ProjectPBZ\Saved\SaveGames\Steam'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Directory |
        Where-Object { $_.Name -match '^\d+$' } |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { $_.Name })
}

function Test-GameRunning([string]$root) {
    $exe = Join-Path $root 'platform\steam\PBZ.exe'
    foreach ($p in (Get-Process -Name 'PBZ' -ErrorAction SilentlyContinue)) {
        try { if ($p.Path -and ($p.Path -ieq $exe -or $p.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase))) { return $true } }
        catch { return $true }
    }
    return $false
}

# ---------------- 文件操作 ----------------

function Write-TextNoBom([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, $Utf8NoBom)
}

function Set-ModsTxtEntry([string]$modsTxt, [string]$name, [int]$value) {
    $text = if (Test-Path -LiteralPath $modsTxt) { [System.IO.File]::ReadAllText($modsTxt) } else { "Keybinds : 1`r`n" }
    $pattern = "(?m)^\s*$([regex]::Escape($name))\s*:\s*\d+\s*$"
    if ($text -match $pattern) {
        $text = [regex]::Replace($text, $pattern, "$name : $value")
    } elseif ($value -eq 1) {
        $anchor = [regex]::Match($text, '(?m)^\s*;\s*Built-in keybinds')
        if (-not $anchor.Success) { $anchor = [regex]::Match($text, '(?m)^\s*Keybinds\s*:') }
        $line = "$name : $value`r`n"
        $text = if ($anchor.Success) { $text.Insert($anchor.Index, $line) } else { $text.TrimEnd() + "`r`n" + $line }
    }
    Write-TextNoBom $modsTxt $text
}

function Remove-ModsTxtEntry([string]$modsTxt, [string]$name) {
    if (-not (Test-Path -LiteralPath $modsTxt)) { return }
    $text = [System.IO.File]::ReadAllText($modsTxt)
    $text = [regex]::Replace($text, "(?m)^\s*$([regex]::Escape($name))\s*:\s*\d+\s*\r?\n?", '')
    Write-TextNoBom $modsTxt $text
}

function Update-ModConfig([string]$configPath, [string]$root, [string]$steamId) {
    $text = [System.IO.File]::ReadAllText($configPath)
    $rootLua = $root -replace '\\', '/'
    $text = [regex]::Replace($text, '(?m)^(\s*GameRoot\s*=\s*)"[^"]*"', ('${1}"' + $rootLua + '"'))
    $text = [regex]::Replace($text, '(?m)^(\s*SteamId\s*=\s*)"[^"]*"', ('${1}"' + $steamId + '"'))
    Write-TextNoBom $configPath $text
}

function Copy-Tree([string]$src, [string]$dst, [string[]]$skipRelative) {
    $src = (Resolve-Path -LiteralPath $src).Path
    foreach ($item in (Get-ChildItem -LiteralPath $src -Recurse -Force)) {
        $rel = $item.FullName.Substring($src.Length).TrimStart('\')
        if ($skipRelative -contains $rel) { continue }
        $target = Join-Path $dst $rel
        if ($item.PSIsContainer) {
            New-Item -ItemType Directory -Force -Path $target | Out-Null
        } else {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        }
    }
}

# ---------------- 安装 / 卸载 ----------------

function Install-Mod([string]$root, [bool]$installUe4ss, [bool]$backupSaves, [scriptblock]$log) {
    $steamDir = Join-Path $root 'platform\steam'
    $ue4ssDir = Join-Path $steamDir 'ue4ss'
    $modDir = Join-Path $ue4ssDir "Mods\$ModName"
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    if ($backupSaves) {
        $saves = Join-Path $root 'ProjectPBZ\Saved\SaveGames'
        if (Test-Path -LiteralPath $saves) {
            $bk = Join-Path $root "_rematch_backup\saves_$stamp"
            New-Item -ItemType Directory -Force -Path $bk | Out-Null
            Copy-Item -LiteralPath $saves -Destination $bk -Recurse -Force
            & $log "已备份存档到：$bk"
        } else {
            & $log "未找到存档文件夹，跳过备份。"
        }
    }

    $hadUe4ss = (Test-Path -LiteralPath (Join-Path $steamDir 'dwmapi.dll')) -and (Test-Path -LiteralPath $ue4ssDir)
    $weInstalledUe4ss = $false
    if ($installUe4ss -or -not $hadUe4ss) {
        $skip = @()
        if (Test-Path -LiteralPath (Join-Path $ue4ssDir 'Mods\mods.txt')) { $skip += 'ue4ss\Mods\mods.txt' }
        if (Test-Path -LiteralPath (Join-Path $ue4ssDir 'UE4SS-settings.ini')) { $skip += 'ue4ss\UE4SS-settings.ini' }
        Copy-Tree (Join-Path $Payload 'ue4ss_runtime') $steamDir $skip
        $weInstalledUe4ss = -not $hadUe4ss
        & $log ($(if ($hadUe4ss) { "已更新 UE4SS 框架（保留了你原有的 mods.txt 和 UE4SS-settings.ini）。" } else { "已安装 UE4SS 框架。" }))
    } else {
        & $log "检测到已安装的 UE4SS，保持不变。"
    }

    $configPath = Join-Path $modDir 'Scripts\config.lua'
    $skipMod = @()
    if (Test-Path -LiteralPath $configPath) { $skipMod += 'Scripts\config.lua' }
    Copy-Tree (Join-Path $Payload $ModName) $modDir $skipMod
    New-Item -ItemType Directory -Force -Path (Join-Path $modDir 'data\snapshot') | Out-Null
    & $log ($(if ($skipMod.Count) { "已更新 Mod 脚本（保留了你原有的 config.lua 设置）。" } else { "已安装 Mod 脚本。" }))

    $ids = Get-SteamSaveIds $root
    $steamId = if ($ids.Count -gt 0) { $ids[0] } else { '' }
    Update-ModConfig $configPath $root $steamId
    if ($steamId) {
        & $log "存档文件夹：ProjectPBZ\Saved\SaveGames\Steam\$steamId"
        if ($ids.Count -gt 1) { & $log "（发现多个存档文件夹，已选择最近使用的那个。如需更换，请修改 config.lua 中的 SteamId。）" }
    } else {
        & $log "警告：还没有找到存档文件夹。请先进游戏存一次档，再重新运行本工具。"
    }

    $modsTxt = Join-Path $ue4ssDir 'Mods\mods.txt'
    Set-ModsTxtEntry $modsTxt $ModName 1
    if (Test-Path -LiteralPath (Join-Path $ue4ssDir 'Mods\PBZBossProbe')) { Set-ModsTxtEntry $modsTxt 'PBZBossProbe' 0 }
    & $log "已在 mods.txt 中启用 $ModName。"

    $manifestPath = Join-Path $modDir 'install_manifest.txt'
    $prevManifest = if (Test-Path -LiteralPath $manifestPath) { [System.IO.File]::ReadAllText($manifestPath) } else { '' }
    $ue4ssByUs = $weInstalledUe4ss -or ($prevManifest -match 'ue4ss_installed_by_tool=1')
    Write-TextNoBom $manifestPath ("installed_at=$stamp`r`nue4ss_installed_by_tool=$([int]$ue4ssByUs)`r`n")

    $doc = Join-Path $Payload $DocName
    if (Test-Path -LiteralPath $doc) {
        Copy-Item -LiteralPath $doc -Destination (Join-Path $root $DocName) -Force
        & $log "使用说明已复制到游戏目录：$DocName"
    }
    & $log "安装完成。启动游戏后，在铃铛菜单中即可看到“宿敌再战”。"
}

function Uninstall-Mod([string]$root, [scriptblock]$log, [scriptblock]$confirm) {
    $steamDir = Join-Path $root 'platform\steam'
    $ue4ssDir = Join-Path $steamDir 'ue4ss'
    $modDir = Join-Path $ue4ssDir "Mods\$ModName"
    if (-not (Test-Path -LiteralPath $modDir)) {
        & $log "没有找到已安装的 $ModName。"
        return
    }
    if (Test-Path -LiteralPath (Join-Path $modDir 'data\challenge_state.lua')) {
        $go = & $confirm "检测到一场没有正常结束的挑战（存档快照尚未恢复）。`r`n`r`n建议先启动一次游戏，让 Mod 自动恢复存档后再卸载。`r`n`r`n仍然要卸载吗？"
        if (-not $go) { & $log "已取消卸载。"; return }
    }
    $manifestPath = Join-Path $modDir 'install_manifest.txt'
    $ue4ssByUs = (Test-Path -LiteralPath $manifestPath) -and ([System.IO.File]::ReadAllText($manifestPath) -match 'ue4ss_installed_by_tool=1')

    Remove-Item -LiteralPath $modDir -Recurse -Force
    Remove-ModsTxtEntry (Join-Path $ue4ssDir 'Mods\mods.txt') $ModName
    & $log "已删除 $ModName。"

    if ($ue4ssByUs) {
        $removeFramework = & $confirm "UE4SS 框架是本工具安装的。要一起删除吗？`r`n（如果你还装了其他依赖 UE4SS 的 Mod，请选“否”。）"
        if ($removeFramework) {
            Remove-Item -LiteralPath (Join-Path $steamDir 'dwmapi.dll') -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $ue4ssDir -Recurse -Force -ErrorAction SilentlyContinue
            & $log "已删除 UE4SS 框架。"
        }
    }
    & $log "卸载完成。"
}

