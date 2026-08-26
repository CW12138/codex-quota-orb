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

$tailFunction = Get-FunctionAst 'Read-BoundedFileTailLines'
Invoke-Expression $tailFunction.Extent.Text

$testPath = Join-Path ([IO.Path]::GetTempPath()) ('CodexQuotaOrbTail-' + [Guid]::NewGuid().ToString('N') + '.jsonl')
try {
    $largeRecord = 'x' * (6 * 1024 * 1024)
    $records = New-Object System.Collections.Generic.List[string]
    $records.Add($largeRecord)
    for ($index = 1; $index -le 140; $index++) {
        $records.Add(('{{"index":{0},"type":"token_count"}}' -f $index))
    }
    [IO.File]::WriteAllLines($testPath, $records, (New-Object Text.UTF8Encoding($false)))

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $tail = @(Read-BoundedFileTailLines -Path $testPath -MaxLines 120 -MaxBytes 1048576)
    $stopwatch.Stop()
    if ($stopwatch.Elapsed.TotalSeconds -ge 2) {
        throw ('Bounded tail reader exceeded two seconds: {0:N0} ms' -f $stopwatch.Elapsed.TotalMilliseconds)
    }
    if ($tail.Count -ne 120 -or $tail[-1] -notlike '*"index":140*') {
        throw 'Bounded tail reader returned the wrong records.'
    }
} finally {
    if ([IO.File]::Exists($testPath)) { [IO.File]::Delete($testPath) }
}

$refreshFunction = (Get-FunctionAst 'Refresh-Data').Extent.Text
if ($refreshFunction.Contains('Read-RateLimitFromSessionEvents') -or
    $refreshFunction.Contains('Read-RateWindowsFromSessionEvents')) {
    throw 'Refresh-Data must not parse Codex session JSONL on the WPF dispatcher.'
}

$analyticsFunction = (Get-FunctionAst 'Start-AnalyticsRefreshAsync').Extent.Text
if (-not $analyticsFunction.Contains('System.Diagnostics.ProcessStartInfo') -or
    $analyticsFunction.Contains('& $pythonCommand.Source')) {
    throw 'Usage analytics must run in a child process instead of the WPF dispatcher.'
}

$sessionReadReferences = [regex]::Matches($source, '\bRead-RateWindowsFromSessionEvents\b').Count
if ($sessionReadReferences -ne 3) {
    throw ('Unexpected session-reader call count; UI code may have regressed: ' + $sessionReadReferences)
}

Write-Output 'UI_RESPONSIVENESS_TESTS=PASS'
