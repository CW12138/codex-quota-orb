$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$installer = Get-Content -LiteralPath (Join-Path $root 'Install.ps1') -Encoding UTF8 -Raw
$releaseWorkflow = Get-Content -LiteralPath (Join-Path $root '.github\workflows\release.yml') -Encoding UTF8 -Raw
$readme = Get-Content -LiteralPath (Join-Path $root 'README.md') -Encoding UTF8 -Raw

$installerFragments = @(
    "[ValidateSet('Auto', 'Classic', 'Gradient')][string]`$OrbStyle = 'Auto'",
    "`$installedStylePath = Join-Path `$resolvedInstallDirectory 'orb-style.txt'",
    "Set-Content -LiteralPath (Join-Path `$resolvedInstallDirectory 'orb-style.txt') -Value `$resolvedOrbStyle"
)
foreach ($fragment in $installerFragments) {
    if (-not $installer.Contains($fragment)) {
        throw ('Missing dual-style installer contract fragment: ' + $fragment)
    }
}

foreach ($fragment in @(
    "CodexQuotaOrb-`$env:GITHUB_REF_NAME-Classic.zip",
    "CodexQuotaOrb-`$env:GITHUB_REF_NAME-Gradient.zip",
    "Set-Content -LiteralPath (Join-Path `$packageDirectory 'orb-style.txt') -Value `$style"
)) {
    if (-not $releaseWorkflow.Contains($fragment)) {
        throw ('Missing dual-style release contract fragment: ' + $fragment)
    }
}

foreach ($fragment in @(
    '## Latest update',
    '## Choose your orb style',
    '-OrbStyle Classic',
    '-OrbStyle Gradient',
    'assets/orb-classic.png',
    'assets/orb-gradient.png'
)) {
    if (-not $readme.Contains($fragment)) {
        throw ('Missing dual-style README contract fragment: ' + $fragment)
    }
}

Write-Output 'ORB_STYLE_DISTRIBUTION_TESTS=PASS'
