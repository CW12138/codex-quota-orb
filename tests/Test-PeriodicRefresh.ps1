$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$mainPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CodexRateWidget.ps1'
$source = Get-Content -LiteralPath $mainPath -Encoding UTF8 -Raw

if ($source -notmatch '\$periodicRefreshTimer\.Interval\s*=\s*\[TimeSpan\]::FromMinutes\(1\)') {
    throw 'The quota fallback refresh interval must remain one minute.'
}
if ($source -notmatch '\$periodicRefreshTimer\.Add_Tick\(\{\s*(?:#[^\r\n]*\r?\n\s*)*Start-DirectRefreshAsync\s*\}\)') {
    throw 'The periodic timer must trigger the supervised direct refresh worker.'
}
if ($source -notmatch '\$periodicRefreshTimer\.Start\(\)') {
    throw 'The periodic quota refresh timer is not started with the widget.'
}
if ($source -notmatch '\$periodicRefreshTimer\.Stop\(\)') {
    throw 'The periodic quota refresh timer is not stopped during shutdown.'
}

Write-Output 'PERIODIC_REFRESH_TESTS=PASS'
