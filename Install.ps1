[CmdletBinding()]
param(
    [string]$InstallDirectory = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\CodexQuotaOrb'),
    [ValidateSet('Auto', 'Classic', 'Gradient')][string]$OrbStyle = 'Auto',
    [switch]$NoAutoStart,
    [switch]$NoShortcuts,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repository = 'CW12138/codex-quota-orb'
$requiredFiles = @(
    'CodexRateWidget.ps1',
    'UsageAnalytics.py',
    'Watch-CodexAndLaunchWidget.ps1',
    'Launch-CodexRateWidget.vbs',
    'Launch-CodexRateWatcher.vbs',
    'Install-Startup.ps1',
    'Uninstall-Startup.ps1',
    'Install.ps1',
    'Install.cmd',
    'Uninstall.ps1',
    'Uninstall.cmd',
    'README.md',
    'CHANGELOG.md',
    'PRIVACY.md',
    'SECURITY.md',
    'LICENSE',
    'VERSION'
)

function Stop-InstalledProcesses {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $resolvedDirectory = [System.IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ieq 'powershell.exe' -and
            $_.CommandLine -and
            ($_.CommandLine -like ('*' + $resolvedDirectory + '\CodexRateWidget.ps1*') -or
             $_.CommandLine -like ('*' + $resolvedDirectory + '\Watch-CodexAndLaunchWidget.ps1*'))
        }

    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function New-Shortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $Target
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Description = $Description
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,167"
    $shortcut.Save()
}

$temporaryDirectory = $null
try {
    $localSource = $PSScriptRoot
    if ($localSource -and (Test-Path -LiteralPath (Join-Path $localSource 'CodexRateWidget.ps1'))) {
        $sourceDirectory = $localSource
    } else {
        $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('CodexQuotaOrb-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
        $archivePath = Join-Path $temporaryDirectory 'source.zip'
        $archiveUrl = "https://github.com/$repository/archive/refs/heads/main.zip"

        Write-Host "Downloading Codex Quota Orb from $repository ..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing
        Expand-Archive -LiteralPath $archivePath -DestinationPath $temporaryDirectory -Force
        $sourceDirectory = Get-ChildItem -LiteralPath $temporaryDirectory -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'CodexRateWidget.ps1') } |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not $sourceDirectory) {
            throw 'The downloaded package did not contain CodexRateWidget.ps1.'
        }
    }

    foreach ($fileName in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory $fileName))) {
            throw "Required file is missing: $fileName"
        }
    }

    $resolvedInstallDirectory = [System.IO.Path]::GetFullPath($InstallDirectory)
    $resolvedOrbStyle = $OrbStyle
    if ($resolvedOrbStyle -eq 'Auto') {
        $sourceStylePath = Join-Path $sourceDirectory 'orb-style.txt'
        $installedStylePath = Join-Path $resolvedInstallDirectory 'orb-style.txt'
        if (Test-Path -LiteralPath $sourceStylePath -PathType Leaf) {
            $sourceStyle = (Get-Content -LiteralPath $sourceStylePath -Encoding UTF8 -Raw).Trim()
            $resolvedOrbStyle = if ($sourceStyle -in @('Classic', 'Gradient')) { $sourceStyle } else { 'Classic' }
        } elseif (Test-Path -LiteralPath $installedStylePath -PathType Leaf) {
            $installedStyle = (Get-Content -LiteralPath $installedStylePath -Encoding UTF8 -Raw).Trim()
            $resolvedOrbStyle = if ($installedStyle -in @('Classic', 'Gradient')) { $installedStyle } else { 'Classic' }
        } else {
            $resolvedOrbStyle = 'Classic'
        }
    }

    Stop-InstalledProcesses -Directory $resolvedInstallDirectory
    New-Item -ItemType Directory -Path $resolvedInstallDirectory -Force | Out-Null

    foreach ($fileName in $requiredFiles) {
        $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $sourceDirectory $fileName))
        $destinationPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedInstallDirectory $fileName))
        if (-not $sourcePath.Equals($destinationPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        }
    }
    Set-Content -LiteralPath (Join-Path $resolvedInstallDirectory 'orb-style.txt') -Value $resolvedOrbStyle -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $resolvedInstallDirectory '.installed') -Value 'CodexQuotaOrb' -Encoding ASCII

    $wscriptPath = (Get-Command wscript.exe).Source

    if (-not $NoShortcuts) {
        $programsDirectory = [Environment]::GetFolderPath('Programs')
        $startMenuShortcut = Join-Path $programsDirectory 'Codex Quota Orb.lnk'
        $uninstallShortcut = Join-Path $programsDirectory 'Uninstall Codex Quota Orb.lnk'
        $powershellPath = (Get-Command powershell.exe).Source

        New-Shortcut -Path $startMenuShortcut -Target $wscriptPath `
            -Arguments ('"{0}"' -f (Join-Path $resolvedInstallDirectory 'Launch-CodexRateWidget.vbs')) `
            -WorkingDirectory $resolvedInstallDirectory -Description 'Open Codex Quota Orb'
        New-Shortcut -Path $uninstallShortcut -Target $powershellPath `
            -Arguments ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $resolvedInstallDirectory 'Uninstall.ps1')) `
            -WorkingDirectory $resolvedInstallDirectory -Description 'Uninstall Codex Quota Orb'
    }

    if (-not $NoAutoStart) {
        & (Join-Path $resolvedInstallDirectory 'Install-Startup.ps1')
    }

    if (-not $NoLaunch) {
        Start-Process -FilePath $wscriptPath -ArgumentList ('"{0}"' -f (Join-Path $resolvedInstallDirectory 'Launch-CodexRateWidget.vbs')) | Out-Null
    }

    Write-Host ''
    Write-Host 'Codex Quota Orb is installed.' -ForegroundColor Green
    Write-Host "Location: $resolvedInstallDirectory"
    Write-Host "Orb style: $resolvedOrbStyle"
    Write-Host 'Open it any time from the Start Menu.'
    if (-not (Get-Command python.exe -ErrorAction SilentlyContinue) -and -not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Warning 'Python was not found. The quota orb works, but local analytics requires Python 3.10+ on PATH.'
    }
} finally {
    if ($temporaryDirectory -and (Test-Path -LiteralPath $temporaryDirectory)) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
