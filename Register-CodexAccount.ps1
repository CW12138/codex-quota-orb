[CmdletBinding()]
param(
    [string]$RuntimeDirectory = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexRateWidget'),
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex' }),
    [string]$IdentityId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# The browser login itself is isolated in CODEX_HOME; use the project as the
# terminal's working directory rather than the D:\myGPT category container.
Set-Location -LiteralPath $PSScriptRoot

Import-Module (Join-Path $PSScriptRoot 'AccountSwitcher.psm1') -Force
$store = Initialize-CqoAccountStore -RuntimeDirectory $RuntimeDirectory -CodexHome $CodexHome
$stagingRoot = Join-Path $store.Root 'login-staging'
$stagingHome = Join-Path $stagingRoot ([Guid]::NewGuid().ToString('N'))

function Quote-RegisterArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Start-RegisteredSession {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$IdentityId
    )

    $resumeDirectory = Join-Path $RuntimeDirectory 'resume'
    if (-not (Test-Path -LiteralPath $resumeDirectory)) {
        New-Item -ItemType Directory -Path $resumeDirectory -Force | Out-Null
    }
    $promptPath = $null
    if ($Plan.prompt) {
        $promptPath = Join-Path $resumeDirectory ([Guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $promptPath -Value ([string]$Plan.prompt) -Encoding UTF8 -NoNewline
    }

    $helper = Join-Path $PSScriptRoot 'Resume-CodexSession.ps1'
    $argumentLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File {0} -IdentityId {1} -RuntimeDirectory {2} -CodexHome {3}' -f `
        (Quote-RegisterArgument $helper), (Quote-RegisterArgument $IdentityId), (Quote-RegisterArgument $RuntimeDirectory), (Quote-RegisterArgument $CodexHome)
    if ($Plan.threadId) { $argumentLine += ' -SessionId ' + (Quote-RegisterArgument ([string]$Plan.threadId)) }
    if ($promptPath) { $argumentLine += ' -PromptPath ' + (Quote-RegisterArgument $promptPath) }
    if ($Plan.cwd) { $argumentLine += ' -WorkingDirectory ' + (Quote-RegisterArgument ([string]$Plan.cwd)) }
    Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList $argumentLine | Out-Null
}

try {
    $targetIdentity = $null
    if ($IdentityId) {
        $targetIdentity = @((Get-CqoAccountRegistry -Store $store).accounts | Where-Object {
            [string]$_.id -eq $IdentityId -and [string]$_.kind -eq 'chatgpt'
        } | Select-Object -First 1)[0]
        if (-not $targetIdentity) { throw '要重新认证的 ChatGPT 账号不存在。' }
    }
    try { [void](Save-CqoCurrentChatGptAccount -Store $store -DoNotActivate) } catch {}

    New-Item -ItemType Directory -Path $stagingHome -Force | Out-Null
    $stagingConfig = @(
        'model_provider = "openai"'
        'cli_auth_credentials_store = "file"'
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath (Join-Path $stagingHome 'config.toml') -Value $stagingConfig -Encoding UTF8 -NoNewline
    $isolatedEnvironment = @{ CODEX_HOME = $stagingHome }

    if ($targetIdentity) {
        Write-Host ('正在打开 Codex 官方登录页面；请在浏览器选择 ' + [string]$targetIdentity.email + '。') -ForegroundColor Cyan
    } else {
        Write-Host 'Opening an isolated official Codex ChatGPT sign-in flow...' -ForegroundColor Cyan
    }
    $codexExecutable = Find-CqoCodexExecutable
    $previousProcessCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $stagingHome, 'Process')
        & $codexExecutable login
        if ($LASTEXITCODE -ne 0) { throw 'Codex login did not complete.' }
    } finally {
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $previousProcessCodexHome, 'Process')
    }

    $stagedAuthPath = Join-Path $stagingHome 'auth.json'
    $activeBeforeRegistration = [string](Get-CqoAccountRegistry -Store $store).activeId
    if ($targetIdentity) {
        $signedIn = Get-CqoCurrentAccountInfo -Environment $isolatedEnvironment -ForceChatGptProvider -RefreshToken
        if ($signedIn.Type -ne 'chatgpt' -or
            -not ([string]$signedIn.Email).Equals([string]$targetIdentity.email, [StringComparison]::OrdinalIgnoreCase)) {
            throw ('登录的账号与所选账号不一致；请在浏览器中使用 ' + [string]$targetIdentity.email + ' 完成认证。')
        }
    }
    $saveArgs = @{ Store=$store; AuthPath=$stagedAuthPath; Environment=$isolatedEnvironment; DoNotActivate=$true }
    if ($targetIdentity) {
        $saveArgs.Label = [string]$targetIdentity.label
        $saveArgs.ExistingIdentityId = [string]$targetIdentity.id
    }
    $newAccount = Save-CqoCurrentChatGptAccount @saveArgs
    if ($targetIdentity -and [string]$newAccount.id -ne [string]$targetIdentity.id) {
        throw '重新认证未更新原账号，请检查账号登记信息。'
    }
    $sameIdentity = $activeBeforeRegistration -and $activeBeforeRegistration -eq [string]$newAccount.id
    $switchResult = Switch-CqoIdentity -Store $store -IdentityId ([string]$newAccount.id) -Force -SkipPreviousCredentialCapture:$sameIdentity
    foreach ($plan in @($switchResult.threads)) {
        Start-RegisteredSession -Plan $plan -IdentityId ([string]$newAccount.id)
    }
    $successPrefix = if ($targetIdentity) { '已重新认证并切换：' } else { '已添加并切换：' }
    Write-Host ($successPrefix + [string]$newAccount.label) -ForegroundColor Green
    Start-Sleep -Seconds 2
} catch {
    $recoveryPlans = $_.Exception.Data['CqoRecoveryPlans']
    $recoveryId = $_.Exception.Data['CqoRecoveryIdentityId']
    if ($recoveryPlans -and $recoveryId) {
        foreach ($plan in @($recoveryPlans)) {
            try { Start-RegisteredSession -Plan $plan -IdentityId ([string]$recoveryId) } catch {}
        }
    }
    Write-Host ('账号认证或切换失败：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '当前账号未退出。按回车关闭窗口。' -ForegroundColor Yellow
    [void](Read-Host)
    exit 1
} finally {
    $resolvedStagingRoot = [IO.Path]::GetFullPath($stagingRoot).TrimEnd('\') + '\'
    $resolvedStagingHome = [IO.Path]::GetFullPath($stagingHome)
    if ($resolvedStagingHome.StartsWith($resolvedStagingRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedStagingHome)) {
        Remove-Item -LiteralPath $resolvedStagingHome -Recurse -Force -ErrorAction SilentlyContinue
    }
}
