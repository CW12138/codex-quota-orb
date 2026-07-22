$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$mainPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CodexRateWidget.ps1'
$source = Get-Content -LiteralPath $mainPath -Encoding UTF8 -Raw

$requiredFragments = @(
    "[switch]`$ResetCreditsWorker",
    "Invoke-RestMethod -Method Get",
    "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
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
    'rate-limit-reset-credits/consume',
    'rateLimitResetCredit/consume',
    'x:Name="HintText"'
)) {
    if ($source -match $forbiddenPattern) {
        throw ('Forbidden reset-credits behavior or text found: ' + $forbiddenPattern)
    }
}

Write-Output 'RESET_CREDITS_CONTRACT_TESTS=PASS'
