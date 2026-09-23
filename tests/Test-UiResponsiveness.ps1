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

Invoke-Expression (Get-FunctionAst 'Get-WorkerOutputState').Extent.Text
$unfinished = New-Object 'System.Threading.Tasks.TaskCompletionSource[string]'
$finished = New-Object 'System.Threading.Tasks.TaskCompletionSource[string]'
$finished.SetResult('done')
$exitedWorker = [pscustomobject]@{ ExitTime = [DateTime]::Now }
$timer = [Diagnostics.Stopwatch]::StartNew()
if ((Get-WorkerOutputState $exitedWorker $unfinished.Task $finished.Task) -ne 'pending') {
    throw 'An inherited output pipe must remain pending without blocking the dispatcher.'
}
if ($timer.ElapsedMilliseconds -gt 500) { throw 'Worker readiness check blocked the dispatcher.' }
$exitedWorker.ExitTime = [DateTime]::Now.AddSeconds(-6)
if ((Get-WorkerOutputState $exitedWorker $unfinished.Task $finished.Task) -ne 'timeout') {
    throw 'An inherited pipe must time out after the worker exits.'
}
if ((Get-WorkerOutputState $exitedWorker $finished.Task $finished.Task) -ne 'ready') {
    throw 'Completed output must remain readable even after the deadline.'
}
if ((Get-WorkerOutputState $exitedWorker $finished.Task $unfinished.Task -ResultLine) -ne 'ready') {
    throw 'A complete account result line must remain readable while a descendant holds stderr open.'
}
$accountStart = (Get-FunctionAst 'Start-AccountWorker').Extent.Text
if (-not $accountStart.Contains('StandardOutput.ReadLineAsync()')) {
    throw 'Account workers must read their flushed result line without waiting for pipe EOF.'
}
foreach ($name in @('Complete-AccountWorkerIfReady', 'Complete-DirectRefreshIfReady', 'Complete-ResetCreditsRefreshIfReady', 'Complete-AnalyticsRefreshIfReady')) {
    $body = (Get-FunctionAst $name).Extent.Text
    if (-not $body.Contains('Get-WorkerOutputState') -or $body.Contains('.ReadToEnd()')) {
        throw ($name + ' can block on worker output.')
    }
}
if ($source.Contains('$window.DragMove()')) { throw 'Panel dragging must not enter a nested modal dispatcher loop.' }
if ($source.Contains('$AnalyticsSourceText.Text = ($dailyView.Source + '' · 0 TOKEN'')')) {
    throw 'Analytics source badge must display the refreshed token total.'
}

Write-Output 'UI_RESPONSIVENESS_TESTS=PASS'
