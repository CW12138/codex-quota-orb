$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$mainPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CodexRateWidget.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ('Unable to parse CodexRateWidget.ps1: ' + (($parseErrors | ForEach-Object Message) -join '; '))
}

$functionAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Find-CodexExecutable'
}, $true)
if (-not $functionAst) {
    throw 'Find-CodexExecutable was not found.'
}

Invoke-Expression $functionAst.Extent.Text

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('CodexQuotaOrbExecutable-' + [Guid]::NewGuid().ToString('N'))
$fakeExecutable = Join-Path $testRoot 'codex.exe'
[void][IO.Directory]::CreateDirectory($testRoot)
[IO.File]::WriteAllBytes($fakeExecutable, [byte[]]@())
$script:MockCodexSource = $fakeExecutable

function Get-Command {
    param(
        [Parameter(Position = 0)][string]$Name,
        $CommandType
    )

    if ($Name -eq 'codex') {
        return [pscustomobject]@{ Source = $script:MockCodexSource }
    }
    return $null
}

try {
    $resolved = Find-CodexExecutable
    if (-not [string]::Equals($resolved, $fakeExecutable, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('Standalone Codex executable was not preferred: ' + [string]$resolved)
    }
} finally {
    if ([IO.File]::Exists($fakeExecutable)) { [IO.File]::Delete($fakeExecutable) }
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $false) }
}

Write-Output 'CODEX_EXECUTABLE_TESTS=PASS'
