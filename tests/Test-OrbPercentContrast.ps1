$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$mainPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CodexRateWidget.ps1'
$source = Get-Content -LiteralPath $mainPath -Encoding UTF8 -Raw

$requiredFragments = @(
    "Remaining = 0.0;   Color = '#FFF0642F'",
    "Remaining = 20.0;  Color = '#FFE58B2F'",
    "Remaining = 40.0;  Color = '#FFD0A43A'",
    "Remaining = 60.0;  Color = '#FF31A58F'",
    "Remaining = 80.0;  Color = '#FF3EA5DA'",
    "Remaining = 100.0; Color = '#FF2F75D6'",
    'x:Name="OrbAtmosphereFill"',
    'function Get-OrbThemeColor',
    'function Set-OrbTheme',
    "[ValidateSet('Auto', 'Classic', 'Gradient')][string]`$OrbStyle = 'Auto'",
    "if (`$script:OrbStyle -eq 'Gradient')",
    '$script:OrbWaterTransitionDurationMs = 600.0',
    'if ($Remaining -ge 52.0)',
    "ConvertTo-OrbColor '#FF263746'",
    'Update-OrbWaterLevel $QARemaining -Immediate',
    'x:Name="OrbPercentText" Text="--%" Foreground="#FF101923"',
    '<DropShadowEffect Color="#FFFFFF" BlurRadius="3" ShadowDepth="0" Opacity="0.72"/>'
)

foreach ($fragment in $requiredFragments) {
    if (-not $source.Contains($fragment)) {
        throw ('Missing orb percent contrast contract fragment: ' + $fragment)
    }
}

foreach ($legacyFragment in @(
    'x:Name="OrbPercentText" Text="--%" Foreground="#FFFFA62B"',
    'x:Name="OrbPercentText" Text="--%" Foreground="#FFD8E0E8"',
    'x:Name="OrbPercentText" Text="--%" Foreground="#FF465A70"',
    'x:Name="OrbPercentText" Text="--%" Foreground="#FF66788A"'
)) {
    if ($source.Contains($legacyFragment)) {
        throw ('Superseded orb contrast fragment remains: ' + $legacyFragment)
    }
}

Write-Output 'ORB_PERCENT_CONTRAST_TESTS=PASS'
