# 宿敌再战 Mod 安装逻辑（被 installer.ps1 引用，也可单独加载做测试）

$InstallerDir = $PSScriptRoot
if (-not $InstallerDir -and $MyInvocation.MyCommand.Path) {
    $InstallerDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $InstallerDir) {
    throw 'Installer script directory is unknown. Please run via 安装宿敌再战Mod.bat / Install Boss Rematch.bat'
}
$PackageRoot = Split-Path -Parent $InstallerDir
$Payload = Join-Path $PackageRoot 'payload'
$ModName = 'PBZBossRematch'
$DocName = '宿敌再战Mod_使用说明.md'
$DocNameEn = 'PBZBossRematch_Usage_EN.md'
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
    if (-not (Test-Path -LiteralPath $dir)) { return ,@() }
    # The comma keeps a one-element result an array. Without it PowerShell
    # returns a string, and $ids[0] is the first character of the Steam id.
    $names = @(Get-ChildItem -LiteralPath $dir -Directory |
        Where-Object { $_.Name -match '^\d+$' } |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { $_.Name })
    return ,$names
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
            & $log (T 'LogBackup' $bk)
        } else {
            & $log (T 'LogNoSaves')
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
        & $log ($(if ($hadUe4ss) { T 'LogUe4ssUpdated' } else { T 'LogUe4ssInstalled' }))
    } else {
        & $log (T 'LogUe4ssKeep')
    }

    $configPath = Join-Path $modDir 'Scripts\config.lua'
    $skipMod = @()
    if (Test-Path -LiteralPath $configPath) { $skipMod += 'Scripts\config.lua' }
    Copy-Tree (Join-Path $Payload $ModName) $modDir $skipMod
    New-Item -ItemType Directory -Force -Path (Join-Path $modDir 'data\snapshot') | Out-Null
    & $log ($(if ($skipMod.Count) { T 'LogModUpdated' } else { T 'LogModInstalled' }))

    $ids = Get-SteamSaveIds $root
    $steamId = if ($ids.Count -gt 0) { [string]$ids[0] } else { '' }
    Update-ModConfig $configPath $root $steamId
    if ($steamId) {
        & $log (T 'LogSaveFolder' $steamId)
        if ($ids.Count -gt 1) { & $log (T 'LogMultiSave') }
    } else {
        & $log (T 'LogNoSaveWarn')
    }

    $modsTxt = Join-Path $ue4ssDir 'Mods\mods.txt'
    Set-ModsTxtEntry $modsTxt $ModName 1
    if (Test-Path -LiteralPath (Join-Path $ue4ssDir 'Mods\PBZBossProbe')) { Set-ModsTxtEntry $modsTxt 'PBZBossProbe' 0 }
    & $log (T 'LogModsEnabled' $ModName)

    $manifestPath = Join-Path $modDir 'install_manifest.txt'
    $prevManifest = if (Test-Path -LiteralPath $manifestPath) { [System.IO.File]::ReadAllText($manifestPath) } else { '' }
    $ue4ssByUs = $weInstalledUe4ss -or ($prevManifest -match 'ue4ss_installed_by_tool=1')
    Write-TextNoBom $manifestPath ("installed_at=$stamp`r`nue4ss_installed_by_tool=$([int]$ue4ssByUs)`r`n")

    $doc = Join-Path $Payload $DocName
    if (Test-Path -LiteralPath $doc) {
        Copy-Item -LiteralPath $doc -Destination (Join-Path $root $DocName) -Force
        & $log (T 'LogDocCopied' $DocName)
    }
    $docEn = Join-Path $Payload $DocNameEn
    if (Test-Path -LiteralPath $docEn) {
        Copy-Item -LiteralPath $docEn -Destination (Join-Path $root $DocNameEn) -Force
        & $log (T 'LogDocEnCopied' $DocNameEn)
    }
    & $log (T 'LogInstallDone')
}

function Uninstall-Mod([string]$root, [scriptblock]$log, [scriptblock]$confirm) {
    $steamDir = Join-Path $root 'platform\steam'
    $ue4ssDir = Join-Path $steamDir 'ue4ss'
    $modDir = Join-Path $ue4ssDir "Mods\$ModName"
    if (-not (Test-Path -LiteralPath $modDir)) {
        & $log (T 'LogModMissing' $ModName)
        return
    }
    if (Test-Path -LiteralPath (Join-Path $modDir 'data\challenge_state.lua')) {
        $go = & $confirm (T 'ConfirmUnfinished')
        if (-not $go) { & $log (T 'LogUninstallCancel'); return }
    }
    $manifestPath = Join-Path $modDir 'install_manifest.txt'
    $ue4ssByUs = (Test-Path -LiteralPath $manifestPath) -and ([System.IO.File]::ReadAllText($manifestPath) -match 'ue4ss_installed_by_tool=1')

    Remove-Item -LiteralPath $modDir -Recurse -Force
    Remove-ModsTxtEntry (Join-Path $ue4ssDir 'Mods\mods.txt') $ModName
    & $log (T 'LogModRemoved' $ModName)

    if ($ue4ssByUs) {
        $removeFramework = & $confirm (T 'ConfirmRemoveUe4ss')
        if ($removeFramework) {
            Remove-Item -LiteralPath (Join-Path $steamDir 'dwmapi.dll') -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $ue4ssDir -Recurse -Force -ErrorAction SilentlyContinue
            & $log (T 'LogUe4ssRemoved')
        }
    }
    & $log (T 'LogUninstallDone')
}

