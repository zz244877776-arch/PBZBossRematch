# 宿敌再战 Mod 一键安装工具
# 由安装包根目录的“安装宿敌再战Mod.bat”启动。

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $PSScriptRoot 'installer_core.ps1')

# ---------------- 界面 ----------------

$form = New-Object System.Windows.Forms.Form
$form.Text = '宿敌再战 Mod 一键安装工具'
$form.Size = New-Object System.Drawing.Size(720, 540)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = '《影之刃零》宿敌再战 Mod'
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(20, 15)
$title.AutoSize = $true
$form.Controls.Add($title)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = '选择游戏程序（PBZ.exe）或游戏安装文件夹，然后点击“安装 / 更新”。安装前请先关闭游戏。'
$hint.Location = New-Object System.Drawing.Point(22, 52)
$hint.Size = New-Object System.Drawing.Size(670, 20)
$form.Controls.Add($hint)

$pathBox = New-Object System.Windows.Forms.TextBox
$pathBox.Location = New-Object System.Drawing.Point(22, 82)
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

$btnExe = New-Button '选择游戏程序…' 22 114 150
$btnDir = New-Button '选择游戏文件夹…' 182 114 150
$btnAuto = New-Button '自动查找' 342 114 110

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(22, 152)
$status.Size = New-Object System.Drawing.Size(670, 20)
$form.Controls.Add($status)

$chkUe4ss = New-Object System.Windows.Forms.CheckBox
$chkUe4ss.Text = '安装 / 更新 UE4SS 框架（Mod 运行必需；已装过可不勾选）'
$chkUe4ss.Location = New-Object System.Drawing.Point(22, 180)
$chkUe4ss.Size = New-Object System.Drawing.Size(660, 22)
$chkUe4ss.Checked = $true
$form.Controls.Add($chkUe4ss)

$chkBackup = New-Object System.Windows.Forms.CheckBox
$chkBackup.Text = '安装前备份存档（保存到游戏目录下的 _rematch_backup 文件夹）'
$chkBackup.Location = New-Object System.Drawing.Point(22, 205)
$chkBackup.Size = New-Object System.Drawing.Size(660, 22)
$chkBackup.Checked = $true
$form.Controls.Add($chkBackup)

$btnInstall = New-Button '安装 / 更新' 22 238 150
$btnUninstall = New-Button '卸载' 182 238 110
$btnDoc = New-Button '打开使用说明' 302 238 130
$btnInstall.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.Location = New-Object System.Drawing.Point(22, 280)
$logBox.Size = New-Object System.Drawing.Size(660, 200)
$form.Controls.Add($logBox)

$log = {
    param([string]$msg)
    $logBox.AppendText((Get-Date -Format 'HH:mm:ss') + '  ' + $msg + "`r`n")
    [System.Windows.Forms.Application]::DoEvents()
}

$confirm = {
    param([string]$msg)
    $r = [System.Windows.Forms.MessageBox]::Show($form, $msg, '确认', 'YesNo', 'Question')
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Update-Status {
    $root = Resolve-GameRoot $pathBox.Text
    if (-not $root) {
        $status.ForeColor = [System.Drawing.Color]::Firebrick
        $status.Text = if ($pathBox.Text) { '这个位置不是《影之刃零》的安装目录。' } else { '尚未选择游戏位置。' }
        $btnInstall.Enabled = $false
        $btnUninstall.Enabled = $false
        return $null
    }
    $steamDir = Join-Path $root 'platform\steam'
    $hasUe4ss = Test-Path -LiteralPath (Join-Path $steamDir 'dwmapi.dll')
    $hasMod = Test-Path -LiteralPath (Join-Path $steamDir "ue4ss\Mods\$ModName")
    $status.ForeColor = [System.Drawing.Color]::DarkGreen
    $status.Text = "游戏目录：$root    UE4SS：$(if ($hasUe4ss) { '已安装' } else { '未安装' })    本 Mod：$(if ($hasMod) { '已安装' } else { '未安装' })"
    $chkUe4ss.Checked = -not $hasUe4ss
    $btnInstall.Enabled = $true
    $btnUninstall.Enabled = $hasMod
    return $root
}

$pathBox.Add_TextChanged({ [void](Update-Status) })

$btnExe.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = '选择《影之刃零》游戏程序'
    $dlg.Filter = '影之刃零 (PBZ.exe)|PBZ.exe|程序 (*.exe)|*.exe'
    if ($dlg.ShowDialog($form) -eq 'OK') {
        $root = Resolve-GameRoot $dlg.FileName
        $pathBox.Text = if ($root) { $root } else { $dlg.FileName }
    }
})

$btnDir.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择《影之刃零》安装文件夹（一般是 steamapps\common\PBZ）'
    if ($dlg.ShowDialog($form) -eq 'OK') {
        $root = Resolve-GameRoot $dlg.SelectedPath
        $pathBox.Text = if ($root) { $root } else { $dlg.SelectedPath }
    }
})

$btnAuto.Add_Click({
    $found = Find-SteamGame
    if ($found) {
        $pathBox.Text = $found
        & $log "在 Steam 库中找到游戏：$found"
    } else {
        & $log "没有在 Steam 库中自动找到游戏，请手动选择。"
    }
})

$btnInstall.Add_Click({
    $root = Update-Status
    if (-not $root) { return }
    if (Test-GameRunning $root) {
        [System.Windows.Forms.MessageBox]::Show($form, '游戏正在运行，请先完全退出游戏再安装。', '提示', 'OK', 'Warning') | Out-Null
        return
    }
    $form.UseWaitCursor = $true
    try {
        Install-Mod $root $chkUe4ss.Checked $chkBackup.Checked $log
        [System.Windows.Forms.MessageBox]::Show($form, '安装完成！启动游戏后，在铃铛菜单中选择“宿敌再战”即可。', '完成', 'OK', 'Information') | Out-Null
    } catch {
        & $log "安装失败：$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($form, "安装失败：$($_.Exception.Message)", '错误', 'OK', 'Error') | Out-Null
    } finally {
        $form.UseWaitCursor = $false
        [void](Update-Status)
    }
})

$btnUninstall.Add_Click({
    $root = Update-Status
    if (-not $root) { return }
    if (Test-GameRunning $root) {
        [System.Windows.Forms.MessageBox]::Show($form, '游戏正在运行，请先完全退出游戏再卸载。', '提示', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not (& $confirm '确定要卸载宿敌再战 Mod 吗？')) { return }
    try {
        Uninstall-Mod $root $log $confirm
    } catch {
        & $log "卸载失败：$($_.Exception.Message)"
    } finally {
        [void](Update-Status)
    }
})

$btnDoc.Add_Click({
    $doc = Join-Path $Payload $DocName
    if (Test-Path -LiteralPath $doc) { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$doc`"" }
})

$form.Add_Shown({
    $found = Find-SteamGame
    if ($found) {
        $pathBox.Text = $found
        & $log "已自动找到游戏：$found"
    } else {
        [void](Update-Status)
        & $log "没有自动找到游戏，请点击“选择游戏程序”或“选择游戏文件夹”。"
    }
})

[void]$form.ShowDialog()
