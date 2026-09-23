$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot 'AccountSwitcher.psm1'
$resumePath = Join-Path $projectRoot 'Resume-CodexSession.ps1'
$registerPath = Join-Path $projectRoot 'Register-CodexAccount.ps1'
$launchPath = Join-Path $projectRoot 'Launch-ActiveCodex.ps1'

foreach ($path in @($modulePath, $resumePath, $registerPath, $launchPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw ('Unable to parse {0}: {1}' -f $path, (($errors | ForEach-Object Message) -join '; '))
    }
}

Import-Module $modulePath -Force
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('CodexQuotaOrb-AccountTest-' + [Guid]::NewGuid().ToString('N'))
$runtimeDirectory = Join-Path $testRoot 'runtime'
$codexHome = Join-Path $testRoot 'codex-home'
$importDirectory = Join-Path $testRoot 'import'
New-Item -ItemType Directory -Path $importDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $codexHome -Force | Out-Null

try {
    $secret = 'test-secret-do-not-use'
    Set-Content -LiteralPath (Join-Path $importDirectory 'auth.json') -Encoding UTF8 -Value ('{"OPENAI_API_KEY":"' + $secret + '"}')
    @'
model_provider = "custom"
model = "gpt-test"
disable_response_storage = true
model_reasoning_effort = "high"

[model_providers.custom]
name = "custom"
wire_api = "responses"
requires_openai_auth = false
base_url = "https://example.invalid"

[windows]
sandbox = "elevated"
'@ | Set-Content -LiteralPath (Join-Path $importDirectory 'config.toml') -Encoding UTF8

    $store = Initialize-CqoAccountStore -RuntimeDirectory $runtimeDirectory -CodexHome $codexHome
    $identity = Import-CqoCustomProfile `
        -Store $store `
        -AuthPath (Join-Path $importDirectory 'auth.json') `
        -ConfigPath (Join-Path $importDirectory 'config.toml') `
        -Label 'Test provider'

    $registryText = Get-Content -LiteralPath $store.RegistryPath -Encoding UTF8 -Raw
    if ($registryText.Contains($secret)) { throw 'The account registry leaked the API key.' }

    $vaultText = Get-Content -LiteralPath (Join-Path $store.Vault ([string]$identity.id + '.dpapi')) -Encoding ASCII -Raw
    if ($vaultText.Contains($secret)) { throw 'The DPAPI vault stored plaintext.' }

    $profileText = Get-Content -LiteralPath ([string]$identity.profilePath) -Encoding UTF8 -Raw
    if ($profileText.Contains($secret)) { throw 'The generated Codex profile leaked the API key.' }
    if ($profileText -notmatch 'env_key\s*=\s*"CQO_PROVIDER_KEY_') { throw 'The generated profile does not use env_key.' }
    if ($profileText -notmatch 'requires_openai_auth\s*=\s*false') { throw 'The custom profile auth contract changed.' }
    if ($profileText -notmatch '(?m)^\[windows\]\s*$' -or $profileText -notmatch 'sandbox\s*=\s*"elevated"') {
        throw 'The complete imported config was not preserved in the managed profile.'
    }

    $registry = Get-CqoAccountRegistry -Store $store
    $registry.activeId = [string]$identity.id
    $registry | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $store.RegistryPath -Encoding UTF8
    $context = Get-CqoActiveLaunchContext -Store $store
    if ([string]$context.ProfileName -ne [string]$identity.profileName) { throw 'The active profile was not resolved.' }
    if ([string]$context.Environment[[string]$identity.envKeyName] -ne $secret) { throw 'The DPAPI secret could not be restored.' }

    if (-not (Test-CqoQuotaFailureText 'You have reached your usage limit.')) { throw 'English quota failure was not detected.' }
    if (-not (Test-CqoQuotaFailureText '本账号额度已经耗尽。')) { throw 'Chinese quota failure was not detected.' }
    if (Test-CqoQuotaFailureText 'All requested tests passed.') { throw 'A normal completion was misclassified as quota failure.' }
    $failedQuotaTurn = [pscustomobject]@{
        status = 'failed'
        items = @(
            [pscustomobject]@{ type = 'userMessage'; role = 'user'; text = 'Please continue my work.' },
            [pscustomobject]@{ type = 'error'; message = 'You have reached your usage limit.' }
        )
    }
    if (-not (Test-CqoTurnQuotaFailure $failedQuotaTurn)) { throw 'A failed quota turn was not classified.' }
    $completedMentionTurn = [pscustomobject]@{
        status = 'completed'
        items = @([pscustomobject]@{ type = 'userMessage'; role = 'user'; text = 'Discuss token quota exhaustion.' })
    }
    if (Test-CqoTurnQuotaFailure $completedMentionTurn) { throw 'User-authored quota text was misclassified as a failure.' }
    $accountModule = Get-Module AccountSwitcher
    & $accountModule {
        function script:Invoke-CqoRpcRequest {
            param($Transport, $Method, $Params, $TimeoutSeconds, $Environment, [switch]$ForceChatGptProvider)
            return [pscustomobject]@{
                rateLimits = [pscustomobject]@{
                    # Deliberately reverse the usual order: duration, not the
                    # property name, identifies the five-hour quota.
                    primary = [pscustomobject]@{ usedPercent = 70; windowDurationMins = 10080; resetsAt = 200 }
                    secondary = [pscustomobject]@{ usedPercent = 20; windowDurationMins = 300; resetsAt = 100 }
                }
            }
        }
    }
    $reversedQuota = Get-CqoCurrentQuotaCache -Environment @{ CODEX_HOME = $codexHome } -ForceChatGptProvider
    if ($reversedQuota -is [array] -or [int]$reversedQuota.primaryRemaining -ne 80 -or [int]$reversedQuota.secondaryRemaining -ne 30 -or
        $reversedQuota.fiveHourUsesWeeklyFallback) {
        throw 'Quota cache did not classify reversed windows by duration.'
    }
    & $accountModule {
        function script:Invoke-CqoRpcRequest {
            param($Transport, $Method, $Params, $TimeoutSeconds, $Environment, [switch]$ForceChatGptProvider)
            return [pscustomobject]@{
                rateLimits = [pscustomobject]@{
                    primary = [pscustomobject]@{ usedPercent = 55; windowDurationMins = 10080; resetsAt = 300 }
                }
            }
        }
    }
    $weeklyOnlyQuota = Get-CqoCurrentQuotaCache -Environment @{ CODEX_HOME = $codexHome } -ForceChatGptProvider
    if ($weeklyOnlyQuota -is [array] -or [int]$weeklyOnlyQuota.primaryRemaining -ne 45 -or [int]$weeklyOnlyQuota.secondaryRemaining -ne 45 -or
        -not $weeklyOnlyQuota.fiveHourUsesWeeklyFallback) {
        throw 'Quota cache did not mirror a weekly-only response.'
    }
    $emptyResumePlans = @(& $accountModule { Get-CqoThreadResumePlans -Threads @() })
    if ($emptyResumePlans.Count -ne 0) { throw 'An empty loaded-thread list must produce no resume plans.' }

    & $accountModule {
        param($TestRoot)
        $refreshStore = Initialize-CqoAccountStore -RuntimeDirectory (Join-Path $TestRoot 'refresh-runtime') -CodexHome (Join-Path $TestRoot 'refresh-home')
        [void](Save-CqoVaultValue -Store $refreshStore -IdentityId 'refresh-target' -Value '{"revision":"saved"}')
        $refreshIdentity = [pscustomobject]@{ id='refresh-target'; email='refresh@example.invalid' }
        $script:SawForcedRefresh = $false
        function script:Invoke-CqoRpcRequest {
            param($Transport, $Method, $Params, $TimeoutSeconds, $Environment, [switch]$ForceChatGptProvider)
            if ($Method -eq 'account/read') {
                $script:SawForcedRefresh = [bool]$Params.refreshToken
                return [pscustomobject]@{
                    account = [pscustomobject]@{ type='chatgpt'; email='refresh@example.invalid'; planType='plus' }
                    requiresOpenaiAuth = $true
                }
            }
            if ($Method -eq 'account/rateLimits/read') { return [pscustomobject]@{ rateLimits = [pscustomobject]@{} } }
            throw ('Unexpected RPC method: ' + $Method)
        }
        Test-CqoChatGptIdentity -Store $refreshStore -Identity $refreshIdentity
        if (-not $script:SawForcedRefresh) { throw 'Target validation must explicitly refresh ChatGPT credentials before quota validation.' }

        function script:Invoke-CqoRpcRequest {
            param($Transport, $Method, $Params, $TimeoutSeconds, $Environment, [switch]$ForceChatGptProvider)
            if ($Method -eq 'account/read') {
                return [pscustomobject]@{ account=$null; requiresOpenaiAuth=$true }
            }
            throw 'Unexpected quota validation after a missing account.'
        }
        try {
            Test-CqoChatGptIdentity -Store $refreshStore -Identity $refreshIdentity
            throw 'Expected an expired-login rejection.'
        } catch {
            if ($_.Exception.Message -notmatch '登录已失效') { throw }
        }
    } $testRoot

    $implementation = Get-Content -LiteralPath $modulePath -Encoding UTF8 -Raw
    $forbiddenMethod = 'rateLimitResetCredit' + '/consume'
    if ($implementation.Contains($forbiddenMethod)) { throw 'The account switcher must never expose Reset Credit consumption.' }
    if (-not $implementation.Contains('model_provider = "openai"')) { throw 'ChatGPT identities must override a custom base provider.' }
    if (-not $implementation.Contains('cli_auth_credentials_store = "file"')) { throw 'ChatGPT identities must use isolated file-backed credentials.' }
    if (-not $implementation.Contains('[void]$process.WaitForExit(5000)')) { throw 'RPC workers must release their state database before the next account request.' }
    if (-not $implementation.Contains('StandardInput.Close()')) { throw 'Daemon workers must detach standard input from the launching console.' }
    if (-not $implementation.Contains('WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden')) { throw 'Codex RPC and daemon workers must stay hidden.' }
    if (-not $implementation.Contains('--disable code_mode_host')) { throw 'Background RPC workers must not start the visible Code Mode host.' }
    if (-not $implementation.Contains('mcp_servers.node_repl.enabled=false')) { throw 'Background RPC workers must not start node_repl.' }
    if (-not $implementation.Contains('[switch]$SkipPreviousCredentialCapture')) { throw 'Account registration cannot protect the previous credential slot.' }
    if ($implementation.Contains("`$arguments.Add('-p')")) { throw 'App Server commands must not receive the unsupported profile option.' }

    $registerImplementation = Get-Content -LiteralPath $registerPath -Encoding UTF8 -Raw
    if (-not $registerImplementation.Contains('-DoNotActivate')) { throw 'Registration must not activate an identity before the switch transaction.' }
    if (-not $registerImplementation.Contains('-SkipPreviousCredentialCapture')) { throw 'Registration may overwrite the previous account vault.' }
    if ($registerImplementation -match '(?m)^\s*&\s+\$codexExecutable\s+logout\s*$') { throw 'Registration must not log out and invalidate the existing ChatGPT account.' }
    if (-not $registerImplementation.Contains("`$isolatedEnvironment = @{ CODEX_HOME = `$stagingHome }")) { throw 'Registration must isolate the new ChatGPT login.' }
    if (-not $registerImplementation.Contains('cli_auth_credentials_store = "file"')) { throw 'Isolated registration must write credentials into its staging Codex home.' }
    $emailCheckAt = $registerImplementation.IndexOf('$signedIn = Get-CqoCurrentAccountInfo')
    $saveAt = $registerImplementation.IndexOf('$newAccount = Save-CqoCurrentChatGptAccount @saveArgs')
    if (-not $registerImplementation.Contains('[string]$IdentityId') -or
        -not $registerImplementation.Contains('登录的账号与所选账号不一致') -or
        -not $registerImplementation.Contains('$saveArgs.ExistingIdentityId') -or
        $emailCheckAt -lt 0 -or $saveAt -lt 0 -or $emailCheckAt -gt $saveAt) {
        throw 'Reauthentication must verify the selected email before updating its saved identity.'
    }

    $launchImplementation = Get-Content -LiteralPath $launchPath -Encoding UTF8 -Raw
    if (-not $launchImplementation.Contains('Get-CqoActiveLaunchContext')) { throw 'The active-identity launcher does not resolve the selected account.' }
    if (-not $launchImplementation.Contains("`$arguments.Add('-p')")) { throw 'The active-identity launcher does not apply the selected profile.' }

    $resumeImplementation = Get-Content -LiteralPath $resumePath -Encoding UTF8 -Raw
    if ($resumeImplementation.Contains("`$arguments.Add('--last')")) { throw 'Managed resumes must use an exact session id.' }
    if ($resumeImplementation.Contains('-NoExit')) { throw 'Resume helpers must close automatically instead of leaving empty terminal windows.' }
    if ($registerImplementation.Contains('-NoExit')) { throw 'Account registration must not leave empty resume terminals open.' }
    if (-not $resumeImplementation.Contains('exit $LASTEXITCODE')) { throw 'Managed terminals must surface Codex resume failures.' }

    $widgetPath = Join-Path $projectRoot 'CodexRateWidget.ps1'
    $widgetImplementation = Get-Content -LiteralPath $widgetPath -Encoding UTF8 -Raw
    foreach ($fragment in @(
        'x:Name="AccountSwitchButton"',
        'x:Name="AccountFlyoutLayer"',
        'function Start-ManagedResumeWindow',
        'function Start-CqoVisibleTerminal',
        "'-w new -- {0} {1}'",
        '-WindowStyle Normal',
        'function Format-AccountOperationError',
        'Sync-CqoActiveIdentity -Store $script:AccountStore -Detailed',
        '$script:IsAccountIdentityVerifying',
        '<Setter Property="FocusVisualStyle" Value="{x:Null}"/>',
        '--disable code_mode_host -c mcp_servers.node_repl.enabled=false -c model_provider=\"openai\" -c cli_auth_credentials_store=\"file\" app-server --stdio',
        'WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden',
        'RedirectStandardInput = $true',
        "`$remaining -le 0",
        "Start-AccountWorker -Action 'switch'"
    )) {
        if (-not $widgetImplementation.Contains($fragment)) { throw ('Missing account UI contract: ' + $fragment) }
    }
    if (-not $widgetImplementation.Contains('Start-AccountRegistration -IdentityId ([string]$sender.Tag)') -or
        -not $widgetImplementation.Contains("'重新认证'")) {
        throw 'Each ChatGPT account row must open its own reauthentication flow.'
    }

    if ($widgetImplementation.Contains("throw '没有可续接的 Codex 会话。'")) { throw 'Selecting the active identity must be able to open a fresh managed terminal.' }

    if (-not $implementation.Contains('Invoke-CimMethod -InputObject $hostProcess -MethodName Terminate')) {
        throw 'Old terminal hosts must be terminated with an explicit clean exit status.'
    }
    if (-not $implementation.Contains('Reason = [uint32]0')) {
        throw 'Old terminal hosts must exit with status zero for Windows Terminal graceful close.'
    }
    & $accountModule {
        param($TestRoot)
        $path = Join-Path $TestRoot 'utf8-auth.json'
        Write-CqoAtomicText -Path $path -Value '{"label":"账号"}'
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes[0] -ne 123) { throw 'Codex auth JSON must start with {, without a UTF-8 BOM.' }
        if ([IO.File]::ReadAllText($path) -ne '{"label":"账号"}') { throw 'UTF-8 atomic writes must preserve Unicode.' }

        $script:SwitchTestStops = 0
        $script:SwitchTestClosedHosts = $false
        $script:SwitchTestReject = $false
        $script:SwitchTestRejectMessage = 'invalid target'
        $script:SwitchTestRestartFails = $false
        $script:SwitchTestForeignLogin = $false
        $script:SwitchTestSkipQuotaRotation = $false
        function script:Test-CqoChatGptIdentity { param($Store,$Identity) if ($script:SwitchTestReject) { throw $script:SwitchTestRejectMessage } }
        function script:Get-CqoCurrentQuotaCache {
            param($Environment, [switch]$ForceChatGptProvider)
            if (-not $script:SwitchTestSkipQuotaRotation) {
                Write-CqoAtomicText -Path (Join-Path $Environment.CODEX_HOME 'auth.json') -Value '{"revision":"rotated"}'
            }
            return $null
        }
        function script:Get-CqoProcessResumePlans {
            param($Processes)
            return @([pscustomobject]@{ processId=2147483000; threadId='11111111-1111-4111-8111-111111111111'; cwd='C:\fake'; prompt=$null })
        }
        function script:Get-CqoInteractiveCodexProcesses {
            return @([pscustomobject]@{ ProcessId=2147483000; ParentProcessId=456; CommandLine='"C:\codex.exe"'; CreationDate=[DateTime]::Now })
        }
        function script:Stop-CqoInteractiveCodexProcesses {
            param($Processes,[switch]$CloseHostShells)
            $script:SwitchTestStops++
            $script:SwitchTestClosedHosts = [bool]$CloseHostShells
        }
        function script:Restart-CqoDaemon {
            param($LaunchContext)
            if ($script:SwitchTestRestartFails) { throw 'simulated daemon failure' }
            $bytes=[IO.File]::ReadAllBytes((Join-Path $LaunchContext.Environment.CODEX_HOME 'auth.json'))
            if ($bytes[0] -ne 123) { throw 'The daemon received BOM-prefixed auth.' }
        }
        function script:Get-CqoCurrentAccountInfo {
            param($Environment,[switch]$ForceChatGptProvider)
            if ($script:SwitchTestForeignLogin) { return [pscustomobject]@{ Type='chatgpt'; Email='foreign@example.invalid'; PlanType='plus' } }
            $authText = Get-Content -LiteralPath (Join-Path $Environment.CODEX_HOME 'auth.json') -Raw
            $email = if ($authText -match '"revision":"target"') { 'target@example.invalid' } else { 'previous@example.invalid' }
            return [pscustomobject]@{ Type='chatgpt'; Email=$email; PlanType='plus' }
        }
        $store = Initialize-CqoAccountStore -RuntimeDirectory (Join-Path $TestRoot 'switch-runtime') -CodexHome (Join-Path $TestRoot 'switch-home')
        $registry = [pscustomobject]@{ version=1; activeId='previous'; accounts=@(
            [pscustomobject]@{ id='previous'; kind='chatgpt'; email='previous@example.invalid'; profileName='previous'; quota=$null; updatedAt='' },
            [pscustomobject]@{ id='target'; kind='chatgpt'; email='target@example.invalid'; profileName='target'; quota=$null; updatedAt='' }
        ) }
        Save-CqoAccountRegistry $store $registry
        Write-CqoAtomicText -Path $store.AuthPath -Value '{"revision":"old"}'
        [void](Save-CqoVaultValue $store 'target' '{"revision":"target"}')
        $script:SwitchTestForeignLogin=$true
        try { [void](Switch-CqoIdentity $store 'target'); throw 'Expected foreign-login rejection.' } catch { if ($_.Exception.Message -notmatch 'Codex') { throw } }
        if ($script:SwitchTestStops -ne 0 -or (Get-CqoVaultValue $store 'target') -ne '{"revision":"target"}') {
            throw 'Foreign live credentials changed a registered vault or stopped a terminal.'
        }
        $script:SwitchTestForeignLogin=$false
        $result=Switch-CqoIdentity $store 'target'
        if (-not $result.switched -or @($result.threads).Count -ne 1 -or $result.threads[0].threadId -ne '11111111-1111-4111-8111-111111111111') {
            throw 'Switching with an interactive TUI must return the exact matched session.'
        }
        if (-not $script:SwitchTestClosedHosts) { throw 'Switching did not request closure of the previous Codex host shell.' }
        if ((Get-CqoVaultValue $store 'previous') -ne '{"revision":"rotated"}') { throw 'The previous vault captured stale credentials before quota refresh.' }
        if ((Get-Content $store.AuthPath -Raw) -ne '{"revision":"target"}') { throw 'The selected credentials were not installed.' }
        $script:SwitchTestReject=$true
        $stopsBefore=$script:SwitchTestStops
        try { [void](Switch-CqoIdentity $store 'previous'); throw 'Expected validation rejection.' } catch { if ($_.Exception.Message -ne 'invalid target') { throw } }
        if ($script:SwitchTestStops -ne $stopsBefore -or (Get-CqoAccountRegistry $store).activeId -ne 'target') { throw 'Invalid credentials interrupted active work.' }
        $script:SwitchTestReject=$false
        $script:SwitchTestRejectMessage='目标 ChatGPT 账号的登录已失效，请重新认证该账号。'
        $script:SwitchTestReject=$true
        try { [void](Switch-CqoIdentity $store 'target' -Force); throw 'Expected expired target rejection.' } catch {
            if ($_.Exception.Message -notmatch '登录已失效') { throw }
        }
        $marked = Get-CqoAccountById (Get-CqoAccountRegistry $store) 'target'
        if (-not $marked.reauthRequired -or $script:SwitchTestStops -ne $stopsBefore) {
            throw 'Expired credentials must mark the existing account for reauthentication before stopping terminals.'
        }
        $script:SwitchTestReject=$false
        $script:SwitchTestRejectMessage='invalid target'
        $previousVault = Get-CqoVaultValue $store 'previous'
        try {
            [void](Save-CqoCurrentChatGptAccount -Store $store -ExistingIdentityId 'previous' -Environment @{ CODEX_HOME = [string]$store.CodexHome } -DoNotActivate)
            throw 'Expected selected-email mismatch.'
        } catch {
            if ($_.Exception.Message -notmatch '邮箱与所选账号不一致') { throw }
        }
        if ((Get-CqoVaultValue $store 'previous') -ne $previousVault) {
            throw 'A different browser account overwrote the selected account vault.'
        }
        $script:SwitchTestSkipQuotaRotation=$true
        $refreshed = Save-CqoCurrentChatGptAccount -Store $store -Label 'Target' -ExistingIdentityId 'target' -Environment @{ CODEX_HOME = [string]$store.CodexHome } -DoNotActivate
        $script:SwitchTestSkipQuotaRotation=$false
        if ($refreshed.id -ne 'target' -or $refreshed.reauthRequired -or (Get-CqoAccountRegistry $store).activeId -ne 'target') {
            throw 'Reauthentication must update the same identity and clear its expired state.'
        }
        $script:SwitchTestRestartFails=$true
        try { [void](Switch-CqoIdentity $store 'previous'); throw 'Expected daemon failure.' } catch {
            if ($_.Exception.Message -ne 'simulated daemon failure') { throw }
            if (@($_.Exception.Data['CqoRecoveryPlans']).Count -ne 1) { throw 'Rollback did not provide a terminal recovery plan.' }
        }
        if ((Get-CqoAccountRegistry $store).activeId -ne 'target' -or (Get-Content $store.AuthPath -Raw) -ne '{"revision":"rotated"}') { throw 'Rollback failed to restore the latest previous credentials.' }

        $emptyStore = Initialize-CqoAccountStore -RuntimeDirectory (Join-Path $TestRoot 'empty-runtime') -CodexHome (Join-Path $TestRoot 'empty-home')
        $emptyRegistry = [pscustomobject]@{ version=1; activeId=$null; accounts=@(
            [pscustomobject]@{ id='target'; kind='chatgpt'; email='target@example.invalid'; profileName='target'; quota=$null; updatedAt='' }
        ) }
        Save-CqoAccountRegistry $emptyStore $emptyRegistry
        [void](Save-CqoVaultValue $emptyStore 'target' '{"revision":"target"}')
        try { [void](Switch-CqoIdentity $emptyStore 'target'); throw 'Expected empty-home daemon failure.' } catch {
            if ($_.Exception.Message -ne 'simulated daemon failure') { throw }
        }
        if ((Test-Path -LiteralPath $emptyStore.AuthPath) -or (Get-CqoAccountRegistry $emptyStore).activeId) {
            throw 'Rollback left target credentials in a home that had no prior login.'
        }

        $reconcileStore = Initialize-CqoAccountStore -RuntimeDirectory (Join-Path $TestRoot 'reconcile-runtime') -CodexHome (Join-Path $TestRoot 'reconcile-home')
        $reconcileRegistry = [pscustomobject]@{ version=1; activeId='api'; accounts=@(
            [pscustomobject]@{ id='api'; kind='custom'; email=$null; profileName='cqo-api' },
            [pscustomobject]@{ id='gmail'; kind='chatgpt'; email='owner@gmail.com'; profileName='cqo-gmail' }
        ) }
        Save-CqoAccountRegistry $reconcileStore $reconcileRegistry
        function script:Get-CqoInteractiveCodexProcesses {
            return @([pscustomobject]@{ CommandLine='"C:\codex.exe"'; CreationDate=[DateTime]::Now })
        }
        function script:Get-CqoCurrentAccountInfo {
            param($Environment,[switch]$ForceChatGptProvider)
            return [pscustomobject]@{ Type='chatgpt'; Email='owner@gmail.com'; PlanType='plus' }
        }
        $observedDefault = Sync-CqoActiveIdentity $reconcileStore -Detailed
        if (-not $observedDefault.Resolved -or (Get-CqoAccountRegistry $reconcileStore).activeId -ne 'gmail') {
            throw 'A default Codex launch did not replace the stale custom-provider active identity.'
        }
        $reconcileRegistry = Get-CqoAccountRegistry $reconcileStore
        $reconcileRegistry.activeId = 'gmail'
        Save-CqoAccountRegistry $reconcileStore $reconcileRegistry
        function script:Get-CqoInteractiveCodexProcesses {
            return @([pscustomobject]@{ CommandLine='"C:\codex.exe" --profile="cqo-api"'; CreationDate=[DateTime]::Now })
        }
        $observedProfile = Sync-CqoActiveIdentity $reconcileStore -Detailed
        if (-not $observedProfile.Resolved -or (Get-CqoAccountRegistry $reconcileStore).activeId -ne 'api') {
            throw 'An explicit managed profile did not become the observed active identity.'
        }
    } $testRoot
    Import-Module $modulePath -Force
    Write-Output 'ACCOUNT_SWITCHER_TESTS=PASS'
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedRoot)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
