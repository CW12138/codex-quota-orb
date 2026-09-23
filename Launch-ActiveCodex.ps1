[CmdletBinding()]
param(
    [string]$WorkingDirectory = $(if (Test-Path -LiteralPath 'D:\myGPT' -PathType Container) { 'D:\myGPT' } else { (Get-Location).Path }),
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$CodexArguments
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$runtimeDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexRateWidget'
$codexHome = if ($env:CODEX_HOME) {
    $env:CODEX_HOME
} else {
    Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
}

Import-Module (Join-Path $PSScriptRoot 'AccountSwitcher.psm1') -Force
$store = Initialize-CqoAccountStore -RuntimeDirectory $runtimeDirectory -CodexHome $codexHome
$context = Get-CqoActiveLaunchContext -Store $store
foreach ($name in $context.Environment.Keys) {
    [Environment]::SetEnvironmentVariable([string]$name, [string]$context.Environment[$name], 'Process')
}

$arguments = New-Object System.Collections.Generic.List[string]
if ($context.ProfileName) {
    $arguments.Add('-p')
    $arguments.Add([string]$context.ProfileName)
}
foreach ($argument in @($CodexArguments)) {
    $arguments.Add([string]$argument)
}

if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
    Set-Location -LiteralPath $WorkingDirectory
}

$widgetLauncher = Join-Path $PSScriptRoot 'Launch-CodexRateWidget.vbs'
if (Test-Path -LiteralPath $widgetLauncher -PathType Leaf) {
    Start-Process -FilePath (Get-Command wscript.exe).Source -ArgumentList ('"{0}"' -f $widgetLauncher) | Out-Null
}

$identityLabel = if ($context.Identity) { [string]$context.Identity.label } else { 'Codex 默认身份' }
Write-Host ('Starting Codex with: ' + $identityLabel) -ForegroundColor Cyan
& (Find-CqoCodexExecutable) @arguments
exit $LASTEXITCODE
