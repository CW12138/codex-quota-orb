[CmdletBinding()]
param(
    [string]$SessionId,
    [Parameter(Mandatory = $true)][string]$IdentityId,
    [string]$PromptPath,
    [string]$WorkingDirectory,
    [string]$RuntimeDirectory = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexRateWidget'),
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex' })
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'AccountSwitcher.psm1') -Force
$store = Initialize-CqoAccountStore -RuntimeDirectory $RuntimeDirectory -CodexHome $CodexHome
$context = Get-CqoActiveLaunchContext -Store $store -IdentityId $IdentityId
foreach ($name in $context.Environment.Keys) {
    [Environment]::SetEnvironmentVariable([string]$name, [string]$context.Environment[$name], 'Process')
}

$prompt = $null
if ($PromptPath -and (Test-Path -LiteralPath $PromptPath -PathType Leaf)) {
    try {
        $prompt = Get-Content -LiteralPath $PromptPath -Encoding UTF8 -Raw
    } finally {
        Remove-Item -LiteralPath $PromptPath -Force -ErrorAction SilentlyContinue
    }
}

$arguments = New-Object System.Collections.Generic.List[string]
if ($context.ProfileName) {
    $arguments.Add('-p')
    $arguments.Add([string]$context.ProfileName)
}
if ($SessionId) {
    $arguments.Add('resume')
    $arguments.Add($SessionId)
    if ($prompt) { $arguments.Add($prompt) }
} elseif ($prompt) {
    $arguments.Add($prompt)
}

$resolvedWorkingDirectory = if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
    $WorkingDirectory
} elseif (Test-Path -LiteralPath 'D:\myGPT' -PathType Container) {
    'D:\myGPT'
} else {
    $null
}
if ($resolvedWorkingDirectory) {
    Set-Location -LiteralPath $resolvedWorkingDirectory
}

& (Find-CqoCodexExecutable) @arguments
exit $LASTEXITCODE
