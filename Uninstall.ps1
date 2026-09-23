[CmdletBinding()]
param(
    [switch]$RemoveData
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$installDirectory = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$installMarker = Join-Path $installDirectory '.installed'
if (-not (Test-Path -LiteralPath (Join-Path $installDirectory 'CodexRateWidget.ps1')) -or
    -not (Test-Path -LiteralPath $installMarker) -or
    (Get-Content -LiteralPath $installMarker -Raw).Trim() -ne 'CodexQuotaOrb') {
    throw "Refusing to uninstall from an unexpected directory: $installDirectory"
}

& (Join-Path $installDirectory 'Uninstall-Startup.ps1')

$programsDirectory = [Environment]::GetFolderPath('Programs')
foreach ($shortcutName in @('Codex Quota Orb.lnk', 'Codex - Active Identity.lnk', 'Uninstall Codex Quota Orb.lnk')) {
    $shortcutPath = Join-Path $programsDirectory $shortcutName
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
}

$processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -ieq 'powershell.exe' -and
        $_.CommandLine -and
        ($_.CommandLine -like ('*' + $installDirectory + '\CodexRateWidget.ps1*') -or
         $_.CommandLine -like ('*' + $installDirectory + '\Watch-CodexAndLaunchWidget.ps1*'))
    }
foreach ($process in $processes) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
}

if ($RemoveData) {
    $dataDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexRateWidget'
    if (Test-Path -LiteralPath $dataDirectory) {
        $accountRegistryPath = Join-Path $dataDirectory 'accounts\accounts.json'
        if (Test-Path -LiteralPath $accountRegistryPath -PathType Leaf) {
            try {
                $accountRegistry = Get-Content -LiteralPath $accountRegistryPath -Encoding UTF8 -Raw | ConvertFrom-Json
                $allowedProfileRoot = [IO.Path]::GetFullPath($(if ($env:CODEX_HOME) {
                    $env:CODEX_HOME
                } else {
                    Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
                })).TrimEnd('\')
                foreach ($account in @($accountRegistry.accounts)) {
                    if (-not $account.profilePath) { continue }
                    $profilePath = [IO.Path]::GetFullPath([string]$account.profilePath)
                    $profileName = Split-Path -Leaf $profilePath
                    $profileParent = [IO.Path]::GetFullPath((Split-Path -Parent $profilePath)).TrimEnd('\')
                    if ($profileParent.Equals($allowedProfileRoot, [StringComparison]::OrdinalIgnoreCase) -and
                        $profileName -like 'cqo-*.config.toml' -and
                        (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
                        Remove-Item -LiteralPath $profilePath -Force
                    }
                }
            } catch {
                Write-Warning ('Unable to remove generated Codex profiles: ' + $_.Exception.Message)
            }
        }
        Remove-Item -LiteralPath $dataDirectory -Recurse -Force
        Write-Host "Removed local widget data: $dataDirectory"
    }
} else {
    Write-Host 'Local usage history was kept. Run Uninstall.ps1 -RemoveData to remove it.'
}

$escapedInstallDirectory = $installDirectory.Replace("'", "''")
$cleanupCommand = "Start-Sleep -Seconds 1; Remove-Item -LiteralPath '$escapedInstallDirectory' -Recurse -Force"
Start-Process -FilePath (Get-Command powershell.exe).Source -WindowStyle Hidden `
    -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cleanupCommand) | Out-Null

Write-Host 'Codex Quota Orb was uninstalled.' -ForegroundColor Green
