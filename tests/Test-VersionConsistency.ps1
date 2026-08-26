$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Encoding UTF8 -Raw).Trim()
$widget = Get-Content -LiteralPath (Join-Path $root 'CodexRateWidget.ps1') -Encoding UTF8 -Raw
$readme = Get-Content -LiteralPath (Join-Path $root 'README.md') -Encoding UTF8 -Raw

if ($version -ne '1.4.0') {
    throw ('Unexpected VERSION value: ' + $version)
}
if (-not $widget.Contains(("version = '{0}'" -f $version))) {
    throw 'The app-server handshake version does not match VERSION.'
}
if (-not $readme.Contains(('| 2026-08-26 | {0} |' -f $version))) {
    throw 'The README latest-update row does not match VERSION.'
}
if ($widget -match 'CodexQuotaOrb/\d+\.\d+\.\d+') {
    throw 'A separately hard-coded User-Agent version remains in the widget.'
}

Write-Output 'VERSION_CONSISTENCY_TESTS=PASS'
