$ErrorActionPreference = 'Stop'

$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Quota Orb.lnk'
if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
    Write-Host "已移除自动启动：$shortcutPath" -ForegroundColor Green
} else {
    Write-Host '未发现 Codex Quota Orb 自动启动项。'
}

$legacyShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Rate Widget.lnk'
if (Test-Path -LiteralPath $legacyShortcutPath) {
    Remove-Item -LiteralPath $legacyShortcutPath -Force
}

$watcherProcesses = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ieq 'powershell.exe' -and $_.CommandLine -like '*Watch-CodexAndLaunchWidget.ps1*' }

foreach ($watcherProcess in $watcherProcesses) {
    Stop-Process -Id $watcherProcess.ProcessId -Force -ErrorAction SilentlyContinue
}

if ($watcherProcesses) {
    Write-Host '已停止 Codex 启动监听器。' -ForegroundColor Green
}
