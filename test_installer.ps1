$ErrorActionPreference = 'Stop'
$work = Split-Path -Parent $MyInvocation.MyCommand.Path
$fake = Join-Path $work 'test_game\PBZ'
if (Test-Path $fake) { Remove-Item $fake -Recurse -Force }
New-Item -ItemType Directory -Force "$fake\platform\steam", "$fake\ProjectPBZ\Saved\SaveGames\Steam\111", "$fake\ProjectPBZ\Saved\SaveGames\Steam\222" | Out-Null
Set-Content "$fake\platform\steam\PBZ.exe" 'x'
Set-Content "$fake\ProjectPBZ\Saved\SaveGames\Steam\222\PBZSaveGame.sav" 'old'
(Get-Item "$fake\ProjectPBZ\Saved\SaveGames\Steam\222").LastWriteTime = (Get-Date).AddDays(-3)
Set-Content "$fake\ProjectPBZ\Saved\SaveGames\Steam\111\PBZSaveGame.sav" 'new'

$dist = Get-ChildItem (Join-Path $work 'dist') -Directory | Select-Object -First 1
. (Join-Path $dist.FullName 'installer\installer_core.ps1')

$log = { param($m) Write-Host "  log: $m" }
$yes = { param($m) Write-Host "  confirm -> yes"; return $true }

function Check($name, $cond) { Write-Host ("[{0}] {1}" -f $(if ($cond) { 'PASS' } else { 'FAIL' }), $name) }

Write-Host "--- resolve"
Check 'root from folder' ((Resolve-GameRoot $fake) -eq (Resolve-Path $fake).Path)
Check 'root from exe' ((Resolve-GameRoot "$fake\platform\steam\PBZ.exe") -eq (Resolve-Path $fake).Path)
Check 'root from subfolder' ((Resolve-GameRoot "$fake\ProjectPBZ\Saved") -eq (Resolve-Path $fake).Path)
Check 'reject random folder' ($null -eq (Resolve-GameRoot $env:WINDIR))
Check 'reject missing path' ($null -eq (Resolve-GameRoot 'Z:\nope\PBZ.exe'))
Check 'steam ids newest first' ((Get-SteamSaveIds $fake)[0] -eq '111')

Write-Host "--- install #1"
Install-Mod $fake $true $true $log
$mod = "$fake\platform\steam\ue4ss\Mods\PBZBossRematch"
$cfg = [IO.File]::ReadAllText("$mod\Scripts\config.lua")
$mods = [IO.File]::ReadAllText("$fake\platform\steam\ue4ss\Mods\mods.txt")
Check 'dwmapi copied' (Test-Path "$fake\platform\steam\dwmapi.dll")
Check 'UE4SS.dll copied' (Test-Path "$fake\platform\steam\ue4ss\UE4SS.dll")
Check 'mod scripts copied' ((Get-ChildItem "$mod\Scripts" -Filter *.lua).Count -eq 9)
Check 'snapshot dir' (Test-Path "$mod\data\snapshot")
Check 'config GameRoot' ($cfg -match ('GameRoot = "' + [regex]::Escape(((Resolve-Path $fake).Path -replace '\\','/')) + '"'))
Check 'config SteamId' ($cfg -match 'SteamId = "111"')
Check 'config chinese intact' ($cfg -match 'ExitKey')
Check 'mods.txt entry once' (([regex]::Matches($mods, '(?m)^PBZBossRematch : 1')).Count -eq 1)
Check 'mods.txt before keybinds' ($mods.IndexOf('PBZBossRematch') -lt $mods.IndexOf('Keybinds : 1'))
Check 'manifest ue4ss by tool' ([IO.File]::ReadAllText("$mod\install_manifest.txt") -match 'ue4ss_installed_by_tool=1')
Check 'save backup made' ((Get-ChildItem "$fake\_rematch_backup" -Directory).Count -ge 1)
Check 'doc copied' ((Get-ChildItem $fake -Filter *.md).Count -eq 1)
Check 'hot reload off for players' ([IO.File]::ReadAllText("$fake\platform\steam\ue4ss\UE4SS-settings.ini") -match '(?m)^EnableHotReloadSystem = 0')

Write-Host "--- install #2 (update, user edited config)"
$edited = $cfg -replace 'ExitKey = "HOME"', 'ExitKey = "INS"'
[IO.File]::WriteAllText("$mod\Scripts\config.lua", $edited, (New-Object Text.UTF8Encoding($false)))
Set-Content "$mod\data\arena_cache.lua" 'return {}'
Install-Mod $fake $false $false $log
$cfg2 = [IO.File]::ReadAllText("$mod\Scripts\config.lua")
$mods2 = [IO.File]::ReadAllText("$fake\platform\steam\ue4ss\Mods\mods.txt")
Check 'user config kept' ($cfg2 -match 'ExitKey = "INS"')
Check 'arena cache kept' (Test-Path "$mod\data\arena_cache.lua")
Check 'mods.txt still once' (([regex]::Matches($mods2, '(?m)^PBZBossRematch : 1')).Count -eq 1)
Check 'manifest still by tool' ([IO.File]::ReadAllText("$mod\install_manifest.txt") -match 'ue4ss_installed_by_tool=1')

Write-Host "--- uninstall with pending challenge"
Set-Content "$mod\data\challenge_state.lua" 'return {active=true}'
Uninstall-Mod $fake $log $yes
Check 'mod removed' (-not (Test-Path $mod))
Check 'mods.txt entry removed or framework gone' (-not (Test-Path "$fake\platform\steam\ue4ss\Mods\mods.txt") -or -not ([IO.File]::ReadAllText("$fake\platform\steam\ue4ss\Mods\mods.txt") -match 'PBZBossRematch'))
Check 'framework removed' (-not (Test-Path "$fake\platform\steam\dwmapi.dll"))
Check 'game exe untouched' (Test-Path "$fake\platform\steam\PBZ.exe")
Check 'saves untouched' (Test-Path "$fake\ProjectPBZ\Saved\SaveGames\Steam\111\PBZSaveGame.sav")

Write-Host "--- existing third-party UE4SS is kept"
Remove-Item "$fake\platform\steam\ue4ss" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$fake\platform\steam\ue4ss\Mods" | Out-Null
Set-Content "$fake\platform\steam\dwmapi.dll" 'other'
Set-Content "$fake\platform\steam\ue4ss\Mods\mods.txt" "OtherMod : 1`r`n`r`n; Built-in keybinds, do not move up!`r`nKeybinds : 1`r`n"
Install-Mod $fake $false $false $log
Check 'other dwmapi kept' ((Get-Content "$fake\platform\steam\dwmapi.dll") -eq 'other')
$mods3 = [IO.File]::ReadAllText("$fake\platform\steam\ue4ss\Mods\mods.txt")
Check 'other mod kept' ($mods3 -match 'OtherMod : 1')
Check 'our mod added' ($mods3 -match 'PBZBossRematch : 1')
Check 'manifest not by tool' ([IO.File]::ReadAllText("$fake\platform\steam\ue4ss\Mods\PBZBossRematch\install_manifest.txt") -match 'ue4ss_installed_by_tool=0')

Write-Host "--- single save folder"
$one = Join-Path $work 'test_game\One'
New-Item -ItemType Directory -Force "$one\platform\steam", "$one\ProjectPBZ\Saved\SaveGames\Steam\76561198330139348" | Out-Null
Set-Content "$one\platform\steam\PBZ.exe" 'x'
Set-Content "$one\ProjectPBZ\Saved\SaveGames\Steam\76561198330139348\PBZSaveGame.sav" 'save'
Install-Mod $one $true $false $log
$oneCfg = [IO.File]::ReadAllText("$one\platform\steam\ue4ss\Mods\PBZBossRematch\Scripts\config.lua")
Check 'single id not truncated' ($oneCfg -match 'SteamId = "76561198330139348"')
$none = Get-SteamSaveIds (Join-Path $work 'test_game\Missing')
Check 'no save folders' (($null -eq $none) -or ($none.Count -eq 0))

Remove-Item (Join-Path $work 'test_game') -Recurse -Force
