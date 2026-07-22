param(
    [switch]$RunOnce,
    [switch]$ShowDiagnostics
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$widgetLauncher = Join-Path $scriptDir 'Launch-CodexRateWidget.vbs'
$runtimeDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexRateWidget'
$logPath = Join-Path $runtimeDir 'watcher.log'

if (-not (Test-Path -LiteralPath $widgetLauncher)) {
    throw "Widget launcher not found: $widgetLauncher"
}

if (-not (Test-Path -LiteralPath $runtimeDir)) {
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
}

function Write-WatcherLog {
    param([string]$Message)

    $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message
    try {
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch {}

    if ($ShowDiagnostics) {
        Write-Host $line
    }
}

function Test-InteractiveCodexProcess {
    param([Parameter(Mandatory = $true)]$Process)

    $commandLine = [string]$Process.CommandLine
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        return $false
    }

    # The user's normal interactive launch is simply `codex`. Ignore app-server,
    # login, exec, and every other subcommand so the widget cannot trigger itself.
    return $commandLine.Trim() -match '(?i)codex\.exe"?\s*$'
}

function Start-WidgetForInteractiveCodex {
    param([Parameter(Mandatory = $true)]$Process)

    if (-not (Test-InteractiveCodexProcess -Process $Process)) {
        return $false
    }

    Write-WatcherLog ('Detected interactive Codex process PID {0}; launching widget.' -f $Process.ProcessId)
    Start-Process -FilePath (Get-Command wscript.exe).Source -ArgumentList ('"{0}"' -f $widgetLauncher) | Out-Null
    return $true
}

$mutex = $null
try {
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\CodexRateWidgetWatcher', [ref]$createdNew)
    if (-not $createdNew) {
        if ($ShowDiagnostics) {
            Write-Host 'The Codex widget watcher is already running.'
        }
        exit 0
    }

    Write-WatcherLog 'Watcher started.'

    $seenProcessIds = New-Object 'System.Collections.Generic.HashSet[int]'
    $activeProcesses = Get-CimInstance Win32_Process -Filter "Name = 'codex.exe'" -ErrorAction SilentlyContinue
    foreach ($process in $activeProcesses) {
        [void]$seenProcessIds.Add([int]$process.ProcessId)
        if (Start-WidgetForInteractiveCodex -Process $process) {
            break
        }
    }

    if ($RunOnce) {
        exit 0
    }

    while ($true) {
        Start-Sleep -Seconds 2
        $activeProcessIds = New-Object 'System.Collections.Generic.HashSet[int]'

        foreach ($nativeProcess in [System.Diagnostics.Process]::GetProcessesByName('codex')) {
            try {
                $processId = [int]$nativeProcess.Id
                [void]$activeProcessIds.Add($processId)

                if (-not $seenProcessIds.Contains($processId)) {
                    try {
                        $process = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $processId) -ErrorAction Stop
                        if ($process) {
                            Start-WidgetForInteractiveCodex -Process $process | Out-Null
                        }
                    } catch {
                        Write-WatcherLog ('Unable to inspect Codex PID {0}: {1}' -f $processId, $_.Exception.Message)
                    }
                }
            } finally {
                $nativeProcess.Dispose()
            }
        }

        $seenProcessIds = $activeProcessIds
    }
} catch {
    Write-WatcherLog ('Watcher stopped after an error: ' + $_.Exception.Message)
    throw
} finally {
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        try { $mutex.Dispose() } catch {}
    }
}
