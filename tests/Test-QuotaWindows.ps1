$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$mainPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CodexRateWidget.ps1'
$source = Get-Content -LiteralPath $mainPath -Encoding UTF8 -Raw
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ('Unable to parse CodexRateWidget.ps1: ' + (($parseErrors | ForEach-Object Message) -join '; '))
}

function Get-FunctionAst {
    param([Parameter(Mandatory = $true)][string]$Name)
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $Name
    }, $true)
    if (-not $functionAst) { throw ('Function was not found: ' + $Name) }
    return $functionAst
}

$snapshotFunction = Get-FunctionAst 'ConvertTo-RateSnapshot'
$pairFunction = Get-FunctionAst 'ConvertTo-RateWindowPair'
Invoke-Expression $snapshotFunction.Extent.Text
Invoke-Expression $pairFunction.Extent.Text

$observedAt = [DateTimeOffset]::Parse('2026-07-29T12:00:00+08:00')
$weeklyReset = [DateTimeOffset]::Parse('2026-08-03T12:00:00+08:00').ToUnixTimeSeconds()
$fiveHourReset = [DateTimeOffset]::Parse('2026-07-29T16:30:00+08:00').ToUnixTimeSeconds()

# Current service shape: only the weekly window is present. Both UI slots must
# show that same authoritative value until the real five-hour window returns.
$weeklyOnly = [pscustomobject]@{
    planType = 'plus'
    limitId = 'codex'
    primary = [pscustomobject]@{
        usedPercent = 27.0
        windowDurationMins = 10080
        resetsAt = $weeklyReset
    }
    secondary = $null
}
$fallbackPair = ConvertTo-RateWindowPair -RateLimits $weeklyOnly -Source direct -ObservedAt $observedAt
if (-not $fallbackPair.FiveHourUsesWeeklyFallback) {
    throw 'Weekly-only response did not enable the 5h fallback.'
}
if ($fallbackPair.FiveHour.UsedPercent -ne 27.0 -or $fallbackPair.Weekly.UsedPercent -ne 27.0) {
    throw 'Weekly-only response was not mirrored into both quota slots.'
}
if ($fallbackPair.FiveHour.ResetAt.ToUnixTimeSeconds() -ne $weeklyReset -or
    $fallbackPair.Weekly.ResetAt.ToUnixTimeSeconds() -ne $weeklyReset) {
    throw 'Weekly-only reset time was not preserved in both quota slots.'
}

# Restored service shape: 5h and one-week windows have independent usage and
# reset timestamps.
$restored = [pscustomobject]@{
    planType = 'plus'
    limitId = 'codex'
    primary = [pscustomobject]@{
        usedPercent = 41.0
        windowDurationMins = 300
        resetsAt = $fiveHourReset
    }
    secondary = [pscustomobject]@{
        usedPercent = 18.0
        windowDurationMins = 10080
        resetsAt = $weeklyReset
    }
}
$restoredPair = ConvertTo-RateWindowPair -RateLimits $restored -Source direct -ObservedAt $observedAt
if ($restoredPair.FiveHourUsesWeeklyFallback) {
    throw 'A real five-hour window was incorrectly treated as a fallback.'
}
if ($restoredPair.FiveHour.WindowMinutes -ne 300 -or $restoredPair.FiveHour.UsedPercent -ne 41.0) {
    throw 'The five-hour window was not selected correctly.'
}
if ($restoredPair.Weekly.WindowMinutes -ne 10080 -or $restoredPair.Weekly.UsedPercent -ne 18.0) {
    throw 'The weekly window was not selected correctly.'
}
if ($restoredPair.FiveHour.ResetAt.ToUnixTimeSeconds() -ne $fiveHourReset -or
    $restoredPair.Weekly.ResetAt.ToUnixTimeSeconds() -ne $weeklyReset) {
    throw 'The two reset timestamps were not kept with their own windows.'
}

# Classification must remain duration-based if a future response reverses the
# primary and secondary positions.
$reversed = [pscustomobject]@{
    planType = 'plus'
    limitId = 'codex'
    primary = $restored.secondary
    secondary = $restored.primary
}
$reversedPair = ConvertTo-RateWindowPair -RateLimits $reversed -Source direct -ObservedAt $observedAt
if ($reversedPair.FiveHour.WindowMinutes -ne 300 -or $reversedPair.Weekly.WindowMinutes -ne 10080) {
    throw 'Quota windows were classified by position instead of duration.'
}

$dualWindowTitle = 'Text="5h ' + [char]0x00B7 + ' 1' + [char]0x5468 + [char]0x989D + [char]0x5EA6 + '"'
foreach ($fragment in @(
    $dualWindowTitle,
    'x:Name="FiveHourFallbackText"',
    'x:Name="FiveHourResetText"',
    'x:Name="WeeklyPercentText"',
    'x:Name="WeeklyResetText"',
    'function Apply-RateWindows',
    'Save-RateHistorySnapshot $WeeklySnapshot'
)) {
    if (-not $source.Contains($fragment)) {
        throw ('Missing 5h/weekly UI contract fragment: ' + $fragment)
    }
}

if ($source.Contains('x:Name="OrbWindowLabel"')) {
    throw 'The compact orb must remain percentage-only; explain its 5h role in the product page instead.'
}

Write-Output 'QUOTA_WINDOW_TESTS=PASS'
