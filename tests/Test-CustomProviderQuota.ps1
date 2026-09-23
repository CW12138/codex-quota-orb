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

$reader = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Read-AccountDataFromAppServer'
}, $true).Extent.Text
$customGuard = $reader.IndexOf("kind -eq 'custom'", [StringComparison]::Ordinal)
$codexLookup = $reader.IndexOf('$exe = Find-CodexExecutable', [StringComparison]::Ordinal)
if ($customGuard -lt 0 -or $codexLookup -lt 0 -or $customGuard -gt $codexLookup) {
    throw 'A custom provider must bypass Codex quota/usage process startup.'
}

$infinity = [char]0x221E
$middleDot = [char]0x00B7
foreach ($fragment in @(
    'function Apply-CustomProviderState',
    '$script:IsCustomProviderActive = $true',
    ('$OrbPercentText.Text = ''' + $infinity + ''''),
    ('$OrbPercentWaterText.Text = ''' + $infinity + ''''),
    ('$SourceText.Text = ''CUSTOM ' + $middleDot + ' ' + $infinity + ''''),
    '$FiveHourUsedText.Text =',
    'CustomProviderActive',
    'Apply-CustomProviderState',
    '[switch]$QACustomProvider'
)) {
    if (-not $source.Contains($fragment)) {
        throw ('Missing custom-provider quota contract: ' + $fragment)
    }
}

Write-Output 'CUSTOM_PROVIDER_QUOTA_TESTS=PASS'
