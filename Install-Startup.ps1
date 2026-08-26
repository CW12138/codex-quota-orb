$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$launcher = Join-Path $scriptDir 'Launch-CodexRateWatcher.vbs'
$startupDir = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir 'Codex Quota Orb.lnk'
$legacyShortcutPath = Join-Path $startupDir 'Codex Rate Widget.lnk'

if (-not (Test-Path -LiteralPath $launcher)) {
    throw "找不到启动器：$launcher"
}

# Keep exactly one watcher and one startup entry. Older development installs used
# a second shortcut that could win the mutex and launch stale source code.
$watcherProcesses = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ieq 'powershell.exe' -and $_.CommandLine -like '*Watch-CodexAndLaunchWidget.ps1*' }
foreach ($watcherProcess in $watcherProcesses) {
    Stop-Process -Id $watcherProcess.ProcessId -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $legacyShortcutPath) {
    Remove-Item -LiteralPath $legacyShortcutPath -Force
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = (Get-Command wscript.exe).Source
$shortcut.Arguments = ('"{0}"' -f $launcher)
$shortcut.WorkingDirectory = $scriptDir
$shortcut.Description = 'Open Codex Quota Orb when interactive Codex starts'
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,167"
$shortcut.Save()

Start-Process -FilePath (Get-Command wscript.exe).Source -ArgumentList ('"{0}"' -f $launcher) | Out-Null

Write-Host "已启用 Codex Quota Orb 启动识别：$shortcutPath" -ForegroundColor Green
Write-Host '以后在 PowerShell 中运行 codex 时，悬浮窗会自动打开。'
Write-Host '双击 Launch-CodexRateWidget.vbs 仍可立即打开悬浮窗。'
