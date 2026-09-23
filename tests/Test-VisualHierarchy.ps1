$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$mainPath = Join-Path $root 'CodexRateWidget.ps1'
$source = Get-Content -LiteralPath $mainPath -Encoding UTF8 -Raw

foreach ($fragment in @(
    'x:Key="SecondaryActionButton"',
    'Style="{StaticResource SecondaryActionButton}"',
    'x:Name="AnalyticsLoadingPanel"',
    'x:Name="AnalyticsLoadingTitle"',
    'x:Name="AnalyticsLoadingText"',
    'TargetType="{x:Type ScrollBar}"',
    'x:Name="AccountFlyoutLayer" Visibility="Collapsed" Background="Transparent"',
    'Resize-WindowAroundCenter -Width 382 -Height 480',
    'Resize-WindowAroundCenter -Width 420 -Height 410'
)) {
    if (-not $source.Contains($fragment)) {
        throw ('Missing visual-hierarchy contract: ' + $fragment)
    }
}

if ($source.Contains('Resize-WindowAroundCenter -Width 420 -Height 438')) {
    throw 'The expanded quota view must not restore the obsolete oversized height.'
}

if ($source.Contains('Resize-WindowAroundCenter -Width 420 -Height 520')) {
    throw 'The account chooser must not preserve the oversized quota-window backdrop.'
}

$loadingAssignments = [regex]::Matches($source, '\$AnalyticsLoadingPanel\.Visibility').Count
if ($loadingAssignments -lt 5) {
    throw 'Analytics loading, success, timeout, and failure states must all control the visible empty-state panel.'
}

Write-Output 'VISUAL_HIERARCHY_TESTS=PASS'
