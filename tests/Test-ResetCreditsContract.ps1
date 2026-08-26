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

$requiredFragments = @(
    "[switch]`$ResetCreditsWorker",
    "function Read-ResetCreditsFromAppServer",
    "function ConvertTo-ResetCreditsSnapshot",
    "rateLimitResetCredits",
    "ResetCreditsFieldPresent",
    'x:Name="ResetCreditsButton"',
    'x:Name="ResetCreditsBorder"',
    'x:Name="ResetCreditsRowsPanel"',
    'x:Name="ResetCreditsRefreshButton"',
    "Sort-Object ExpiresAt"
)

foreach ($fragment in $requiredFragments) {
    if (-not $source.Contains($fragment)) {
        throw ('Missing reset-credits contract fragment: ' + $fragment)
    }
}

foreach ($forbiddenPattern in @(
    'auth\.json',
    'backend-api',
    'Invoke-RestMethod',
    'rateLimitResetCredit/consume',
    'x:Name="HintText"'
)) {
    if ($source -match $forbiddenPattern) {
        throw ('Forbidden reset-credits behavior or text found: ' + $forbiddenPattern)
    }
}

$converterAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'ConvertTo-ResetCreditsSnapshot'
}, $true)
if (-not $converterAst) { throw 'ConvertTo-ResetCreditsSnapshot was not found.' }
Invoke-Expression $converterAst.Extent.Text

$observedAt = [DateTimeOffset]::Parse('2026-07-29T12:00:00+08:00')
$firstExpiry = [DateTimeOffset]::Parse('2026-08-05T12:00:00+08:00').ToUnixTimeSeconds()
$payload = [pscustomobject]@{
    availableCount = 3
    credits = @(
        [pscustomobject]@{ status = 'available'; expiresAt = $firstExpiry },
        [pscustomobject]@{ status = 'consumed'; expiresAt = ($firstExpiry + 3600) },
        [pscustomobject]@{ status = 'available'; expiresAt = $null }
    )
}
$snapshot = ConvertTo-ResetCreditsSnapshot -RateLimitResetCredits $payload -ObservedAt $observedAt
if ($snapshot.AvailableCount -ne 3) {
    throw 'availableCount must remain authoritative when detail rows are omitted or unusable.'
}
if ($snapshot.Credits.Count -ne 1 -or
    $snapshot.Credits[0].ExpiresAt.ToUnixTimeSeconds() -ne $firstExpiry) {
    throw 'Available Reset Credit expiry details were not normalized correctly.'
}

Write-Output 'RESET_CREDITS_CONTRACT_TESTS=PASS'
