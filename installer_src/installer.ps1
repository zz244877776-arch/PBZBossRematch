# Boss Rematch one-click installer / 宿敌再战 Mod 一键安装工具
# Launched by 安装宿敌再战Mod.bat or Install Boss Rematch.bat

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Windows PowerShell 5.1 plain ". script.ps1" uses ANSI (e.g. GBK) and mangles UTF-8.
# Load companions via BOM-aware StreamReader (UTF-16 package / UTF-8 sources both OK).
function Import-InstallerScript([string]$Path) {
    $reader = New-Object System.IO.StreamReader($Path, $true)
    try { $text = $reader.ReadToEnd() } finally { $reader.Close() }
    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) {
        $text = $text.Substring(1)
    }
    . ([scriptblock]::Create($text))
}

Import-InstallerScript (Join-Path $PSScriptRoot 'installer_i18n.ps1')
Import-InstallerScript (Join-Path $PSScriptRoot 'installer_core.ps1')

Set-InstallerLang (Get-DefaultInstallerLang)

# ---------------- UI ----------------

$form = New-Object System.Windows.Forms.Form
$form.Size = New-Object System.Drawing.Size(720, 560)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$title = New-Object System.Windows.Forms.Label
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(20, 12)
$title.AutoSize = $true
$form.Controls.Add($title)

$langLabel = New-Object System.Windows.Forms.Label
$langLabel.Location = New-Object System.Drawing.Point(500, 18)
$langLabel.AutoSize = $true
$form.Controls.Add($langLabel)

$langBox = New-Object System.Windows.Forms.ComboBox
$langBox.DropDownStyle = 'DropDownList'
$langBox.Location = New-Object System.Drawing.Point(560, 14)
$langBox.Size = New-Object System.Drawing.Size(120, 24)
[void]$langBox.Items.Add('中文')
[void]$langBox.Items.Add('English')
$langBox.SelectedIndex = if ((Get-InstallerLang) -eq 'en') { 1 } else { 0 }
$form.Controls.Add($langBox)

$hint = New-Object System.Windows.Forms.Label
$hint.Location = New-Object System.Drawing.Point(22, 52)
$hint.Size = New-Object System.Drawing.Size(670, 36)
$form.Controls.Add($hint)

$pathBox = New-Object System.Windows.Forms.TextBox
$pathBox.Location = New-Object System.Drawing.Point(22, 92)
$pathBox.Size = New-Object System.Drawing.Size(660, 24)
$form.Controls.Add($pathBox)

function New-Button([string]$text, [int]$x, [int]$y, [int]$w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 30)
    $form.Controls.Add($b)
    return $b
}

$btnExe = New-Button '' 22 124 150
$btnDir = New-Button '' 182 124 160
$btnAuto = New-Button '' 352 124 120

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(22, 164)
$status.Size = New-Object System.Drawing.Size(670, 20)
$form.Controls.Add($status)

$chkUe4ss = New-Object System.Windows.Forms.CheckBox
$chkUe4ss.Location = New-Object System.Drawing.Point(22, 192)
$chkUe4ss.Size = New-Object System.Drawing.Size(660, 22)
$chkUe4ss.Checked = $true
$form.Controls.Add($chkUe4ss)

$chkBackup = New-Object System.Windows.Forms.CheckBox
$chkBackup.Location = New-Object System.Drawing.Point(22, 217)
$chkBackup.Size = New-Object System.Drawing.Size(660, 22)
$chkBackup.Checked = $true
$form.Controls.Add($chkBackup)

$btnInstall = New-Button '' 22 250 140
$btnUninstall = New-Button '' 172 250 100
$btnDoc = New-Button '' 282 250 130
$btnDocEn = New-Button '' 422 250 130
$btnInstall.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.Location = New-Object System.Drawing.Point(22, 292)
$logBox.Size = New-Object System.Drawing.Size(660, 200)
$form.Controls.Add($logBox)

$log = {
    param([string]$msg)
    $logBox.AppendText((Get-Date -Format 'HH:mm:ss') + '  ' + $msg + "`r`n")
    [System.Windows.Forms.Application]::DoEvents()
}

$confirm = {
    param([string]$msg)
    $r = [System.Windows.Forms.MessageBox]::Show($form, $msg, (T 'ConfirmTitle'), 'YesNo', 'Question')
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Update-Status {
    $root = Resolve-GameRoot $pathBox.Text
    if (-not $root) {
        $status.ForeColor = [System.Drawing.Color]::Firebrick
        $status.Text = if ($pathBox.Text) { T 'StatusInvalid' } else { T 'StatusEmpty' }
        $btnInstall.Enabled = $false
        $btnUninstall.Enabled = $false
        return $null
    }
    $steamDir = Join-Path $root 'platform\steam'
    $hasUe4ss = Test-Path -LiteralPath (Join-Path $steamDir 'dwmapi.dll')
    $hasMod = Test-Path -LiteralPath (Join-Path $steamDir "ue4ss\Mods\$ModName")
    $status.ForeColor = [System.Drawing.Color]::DarkGreen
    $ue = if ($hasUe4ss) { T 'Installed' } else { T 'NotInstalled' }
    $mod = if ($hasMod) { T 'Installed' } else { T 'NotInstalled' }
    $status.Text = (T 'StatusLine' $root $ue $mod)
    $chkUe4ss.Checked = -not $hasUe4ss
    $btnInstall.Enabled = $true
    $btnUninstall.Enabled = $hasMod
    return $root
}

function Apply-UiLanguage {
    $form.Text = T 'FormTitle'
    $title.Text = T 'Title'
    $langLabel.Text = T 'LangLabel'
    $hint.Text = T 'Hint'
    $btnExe.Text = T 'PickExe'
    $btnDir.Text = T 'PickDir'
    $btnAuto.Text = T 'AutoFind'
    $chkUe4ss.Text = T 'ChkUe4ss'
    $chkBackup.Text = T 'ChkBackup'
    $btnInstall.Text = T 'Install'
    $btnUninstall.Text = T 'Uninstall'
    $btnDoc.Text = T 'OpenDoc'
    $btnDocEn.Text = T 'OpenDocEn'
    [void](Update-Status)
}

$langBox.Add_SelectedIndexChanged({
    Set-InstallerLang ($(if ($langBox.SelectedIndex -eq 1) { 'en' } else { 'zh' }))
    Apply-UiLanguage
})

$pathBox.Add_TextChanged({ [void](Update-Status) })

$btnExe.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = T 'DlgExeTitle'
    $dlg.Filter = T 'DlgExeFilter'
    if ($dlg.ShowDialog($form) -eq 'OK') {
        $root = Resolve-GameRoot $dlg.FileName
        $pathBox.Text = if ($root) { $root } else { $dlg.FileName }
    }
})

$btnDir.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = T 'DlgDirDesc'
    if ($dlg.ShowDialog($form) -eq 'OK') {
        $root = Resolve-GameRoot $dlg.SelectedPath
        $pathBox.Text = if ($root) { $root } else { $dlg.SelectedPath }
    }
})

$btnAuto.Add_Click({
    $found = Find-SteamGame
    if ($found) {
        $pathBox.Text = $found
        & $log (T 'SteamFound' $found)
    } else {
        & $log (T 'SteamNotFound')
    }
})

$btnInstall.Add_Click({
    $root = Update-Status
    if (-not $root) { return }
    if (Test-GameRunning $root) {
        [System.Windows.Forms.MessageBox]::Show($form, (T 'GameRunning'), (T 'TipTitle'), 'OK', 'Warning') | Out-Null
        return
    }
    $form.UseWaitCursor = $true
    try {
        Install-Mod $root $chkUe4ss.Checked $chkBackup.Checked $log
        [System.Windows.Forms.MessageBox]::Show($form, (T 'InstallDone'), (T 'DoneTitle'), 'OK', 'Information') | Out-Null
    } catch {
        $msg = T 'InstallFail' $_.Exception.Message
        & $log $msg
        [System.Windows.Forms.MessageBox]::Show($form, $msg, (T 'ErrorTitle'), 'OK', 'Error') | Out-Null
    } finally {
        $form.UseWaitCursor = $false
        [void](Update-Status)
    }
})

$btnUninstall.Add_Click({
    $root = Update-Status
    if (-not $root) { return }
    if (Test-GameRunning $root) {
        [System.Windows.Forms.MessageBox]::Show($form, (T 'GameRunningUn'), (T 'TipTitle'), 'OK', 'Warning') | Out-Null
        return
    }
    if (-not (& $confirm (T 'ConfirmUninstall'))) { return }
    try {
        Uninstall-Mod $root $log $confirm
    } catch {
        & $log (T 'UninstallFail' $_.Exception.Message)
    } finally {
        [void](Update-Status)
    }
})

$btnDoc.Add_Click({
    $doc = Join-Path $Payload $DocName
    if (-not (Test-Path -LiteralPath $doc)) { $doc = Join-Path $PackageRoot $DocName }
    if (Test-Path -LiteralPath $doc) { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$doc`"" }
})

$btnDocEn.Add_Click({
    $doc = Join-Path $Payload $DocNameEn
    if (-not (Test-Path -LiteralPath $doc)) { $doc = Join-Path $PackageRoot $DocNameEn }
    if (Test-Path -LiteralPath $doc) { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$doc`"" }
    else { & $log (T 'DocEnMissing' $DocNameEn) }
})

Apply-UiLanguage

$form.Add_Shown({
    $found = Find-SteamGame
    if ($found) {
        $pathBox.Text = $found
        & $log (T 'AutoFound' $found)
    } else {
        [void](Update-Status)
        & $log (T 'AutoNotFound')
    }
})

[void]$form.ShowDialog()
