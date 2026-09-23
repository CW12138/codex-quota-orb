Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.Security

$script:CqoVaultEntropy = [Text.Encoding]::UTF8.GetBytes('CodexQuotaOrb.AccountVault.v1')
$script:CqoQuotaFailurePattern = '(?i)(rate[ _-]?limit|usage[ _-]?limit|quota|token.{0,24}(exhaust|limit)|额度.{0,12}(耗尽|用完|不足)|限额)'

function Write-CqoAtomicText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [ValidateSet('UTF8', 'ASCII')][string]$Encoding = 'UTF8'
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = Join-Path $directory ('.cqo-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $backupPath = Join-Path $directory ('.cqo-' + [Guid]::NewGuid().ToString('N') + '.bak')
    try {
        $textEncoding = if ($Encoding -eq 'UTF8') { New-Object Text.UTF8Encoding($false) } else { [Text.Encoding]::ASCII }
        [IO.File]::WriteAllText($temporaryPath, $Value, $textEncoding)
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporaryPath, $Path, $backupPath)
        } else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Protect-CqoSecret {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$PlainText)

    $plainBytes = [Text.Encoding]::UTF8.GetBytes($PlainText)
    try {
        $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $script:CqoVaultEntropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Convert]::ToBase64String($protectedBytes)
    } finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Unprotect-CqoSecret {
    param([Parameter(Mandatory = $true)][string]$CipherText)

    $protectedBytes = [Convert]::FromBase64String($CipherText)
    $plainBytes = $null
    try {
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $script:CqoVaultEntropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Text.Encoding]::UTF8.GetString($plainBytes)
    } finally {
        [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
        if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
    }
}

function Initialize-CqoAccountStore {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
        [Parameter(Mandatory = $true)][string]$CodexHome
    )

    $root = Join-Path $RuntimeDirectory 'accounts'
    $vault = Join-Path $root 'vault'
    $profiles = Join-Path $root 'profiles'
    foreach ($directory in @($root, $vault, $profiles)) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }

    return [pscustomobject]@{
        Root         = $root
        Vault        = $vault
        Profiles     = $profiles
        RegistryPath = Join-Path $root 'accounts.json'
        CodexHome    = [IO.Path]::GetFullPath($CodexHome)
        AuthPath     = Join-Path ([IO.Path]::GetFullPath($CodexHome)) 'auth.json'
    }
}

function New-CqoEmptyRegistry {
    [pscustomobject]@{
        version  = 1
        activeId = $null
        accounts = @()
    }
}

function Get-CqoAccountRegistry {
    param([Parameter(Mandatory = $true)]$Store)

    if (-not (Test-Path -LiteralPath $Store.RegistryPath -PathType Leaf)) {
        return New-CqoEmptyRegistry
    }

    try {
        $registry = Get-Content -LiteralPath $Store.RegistryPath -Encoding UTF8 -Raw | ConvertFrom-Json
        if (-not $registry) { return New-CqoEmptyRegistry }
        if (-not ($registry.PSObject.Properties.Name -contains 'accounts')) {
            $registry | Add-Member -NotePropertyName accounts -NotePropertyValue @()
        }
        if (-not ($registry.PSObject.Properties.Name -contains 'activeId')) {
            $registry | Add-Member -NotePropertyName activeId -NotePropertyValue $null
        }
        return $registry
    } catch {
        throw ('账号注册表已损坏：' + $_.Exception.Message)
    }
}

function Save-CqoAccountRegistry {
    param(
        [Parameter(Mandatory = $true)]$Store,
        [Parameter(Mandatory = $true)]$Registry
    )

    $json = $Registry | ConvertTo-Json -Depth 12
    Write-CqoAtomicText -Path $Store.RegistryPath -Value $json
}

function Save-CqoVaultValue {
    param(
        [Parameter(Mandatory = $true)]$Store,
        [Parameter(Mandatory = $true)][string]$IdentityId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    $vaultPath = Join-Path $Store.Vault ($IdentityId + '.dpapi')
    Write-CqoAtomicText -Path $vaultPath -Value (Protect-CqoSecret -PlainText $Value) -Encoding ASCII
    return $vaultPath
}

function Get-CqoVaultValue {
    param(
        [Parameter(Mandatory = $true)]$Store,
        [Parameter(Mandatory = $true)][string]$IdentityId
    )

    $vaultPath = Join-Path $Store.Vault ($IdentityId + '.dpapi')
    if (-not (Test-Path -LiteralPath $vaultPath -PathType Leaf)) {
        throw '目标身份的加密凭据不存在。'
    }
    $cipherText = (Get-Content -LiteralPath $vaultPath -Encoding ASCII -Raw).Trim()
    return Unprotect-CqoSecret -CipherText $cipherText
}

function Find-CqoCodexExecutable {
    $commands = @(Get-Command codex -CommandType Application -ErrorAction SilentlyContinue)
    $nativeCommand = @($commands | Where-Object {
        $_.Source -and ([IO.Path]::GetExtension([string]$_.Source) -ieq '.exe')
    }) | Select-Object -First 1
    if ($nativeCommand) {
        return [string]$nativeCommand.Source
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    $command = $commands | Select-Object -First 1
    if ($command -and $command.Source) {
        $npmRoot = Split-Path -Parent $command.Source
        $candidates.Add((Join-Path $npmRoot 'node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'))
        $candidates.Add((Join-Path $npmRoot 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'))
    }
    $candidates.Add((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\OpenAI\Codex\bin\codex.exe'))
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw '未找到 codex.exe。'
}

function Start-CqoRpcProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Arguments,
        [hashtable]$Environment,
        [switch]$ForceChatGptProvider
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Find-CqoCodexExecutable
    # New Codex builds do not accept --profile for app-server commands. The
    # account RPC only needs the built-in provider override; interactive
    # runtime commands continue to use the identity profile.
    # The widget only needs account, quota, and thread RPCs.  Do not let its
    # short-lived app-server workers start the user's Code Mode host or the
    # node_repl MCP server; Codex's Windows host process currently lacks
    # CREATE_NO_WINDOW and can flash a terminal when it is spawned.
    $prefix = '--disable code_mode_host '
    $codexHome = if ($Environment -and $Environment.ContainsKey('CODEX_HOME')) {
        [string]$Environment['CODEX_HOME']
    } elseif ($env:CODEX_HOME) {
        [string]$env:CODEX_HOME
    } else {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    }
    $configPath = Join-Path $codexHome 'config.toml'
    # Adding enabled=false to a home without this MCP server creates a
    # transport-less server entry, which current Codex rejects before any RPC.
    if ((Test-Path -LiteralPath $configPath -PathType Leaf) -and
        ((Get-Content -LiteralPath $configPath -Encoding UTF8 -Raw) -match '(?m)^\s*\[mcp_servers\.node_repl\]\s*$')) {
        $prefix += '-c mcp_servers.node_repl.enabled=false '
    }
    if ($ForceChatGptProvider) {
        $prefix += '-c model_provider=\"openai\" -c cli_auth_credentials_store=\"file\" '
    }
    $startInfo.Arguments = $prefix + $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($Environment) {
        foreach ($name in $Environment.Keys) {
            $startInfo.EnvironmentVariables[[string]$name] = [string]$Environment[$name]
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $process.StandardInput.AutoFlush = $true
    return $process
}

function Invoke-CqoRpcRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [hashtable]$Params = @{},
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 8,
        [hashtable]$Environment,
        [switch]$ForceChatGptProvider
    )

    $arguments = 'app-server --stdio'
    $process = $null
    try {
        $process = Start-CqoRpcProcess -Arguments $arguments -Environment $Environment -ForceChatGptProvider:$ForceChatGptProvider
        $errorReadTask = $process.StandardError.ReadToEndAsync()
        $initialize = @{
            id = 0
            method = 'initialize'
            params = @{
                clientInfo = @{
                    name = 'codex_quota_orb'
                    title = 'Codex Quota Orb'
                    version = '1.5.2'
                }
                capabilities = @{ experimentalApi = $true }
            }
        } | ConvertTo-Json -Compress -Depth 10
        $initialized = @{ method = 'initialized'; params = @{} } | ConvertTo-Json -Compress -Depth 4
        $request = @{ id = 1; method = $Method; params = $Params } | ConvertTo-Json -Compress -Depth 20
        $process.StandardInput.WriteLine($initialize)
        $process.StandardInput.WriteLine($initialized)
        $process.StandardInput.WriteLine($request)

        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            $readTask = $process.StandardOutput.ReadLineAsync()
            $remainingMs = [Math]::Max(50, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (-not $readTask.Wait($remainingMs)) { break }
            $line = $readTask.Result
            if ($null -eq $line) { break }
            try { $message = $line | ConvertFrom-Json } catch { continue }
            if (-not ($message.PSObject.Properties.Name -contains 'id') -or [int]$message.id -ne 1) { continue }
            if ($message.PSObject.Properties.Name -contains 'error' -and $message.error) {
                throw [string]$message.error.message
            }
            return $message.result
        }

        $stderr = if ($errorReadTask.Wait(500)) { ([string]$errorReadTask.Result).Trim() } else { '' }
        if ($stderr) { throw $stderr }
        throw ('App Server 请求超时：' + $Method)
    } finally {
        if ($process) {
            try { $process.StandardInput.Close() } catch {}
            if (-not $process.HasExited) {
                try {
                    $process.Kill()
                    [void]$process.WaitForExit(5000)
                } catch {}
            }
            $process.Dispose()
        }
    }
}

function Get-CqoCurrentAccountInfo {
    param(
        [hashtable]$Environment,
        [switch]$ForceChatGptProvider,
        [switch]$RefreshToken
    )

    $result = Invoke-CqoRpcRequest -Method 'account/read' -Params @{ refreshToken = [bool]$RefreshToken } -TimeoutSeconds 12 -Environment $Environment -ForceChatGptProvider:$ForceChatGptProvider
    if (-not $result -or -not $result.account) {
        return [pscustomobject]@{
            Type = 'none'
            Email = $null
            PlanType = $null
            RequiresOpenAiAuth = if ($result) { [bool]$result.requiresOpenaiAuth } else { $false }
        }
    }

    return [pscustomobject]@{
        Type = [string]$result.account.type
        Email = if ($result.account.PSObject.Properties.Name -contains 'email') { [string]$result.account.email } else { $null }
        PlanType = if ($result.account.PSObject.Properties.Name -contains 'planType') { [string]$result.account.planType } else { $null }
        RequiresOpenAiAuth = [bool]$result.requiresOpenaiAuth
    }
}

function Get-CqoCurrentQuotaCache {
    param(
        [hashtable]$Environment,
        [switch]$ForceChatGptProvider
    )

    try {
        $result = Invoke-CqoRpcRequest -Method 'account/rateLimits/read' -TimeoutSeconds 10 -Environment $Environment -ForceChatGptProvider:$ForceChatGptProvider
        if (-not $result -or -not $result.rateLimits) { return $null }
        $candidates = New-Object System.Collections.Generic.List[object]
        foreach ($windowName in @('primary', 'secondary')) {
            $windowProperty = $result.rateLimits.PSObject.Properties[$windowName]
            $window = if ($windowProperty) { $windowProperty.Value } else { $null }
            if (-not $window) { continue }
            $usedProperty = $window.PSObject.Properties['usedPercent']
            if (-not $usedProperty -or $null -eq $usedProperty.Value) { continue }
            $durationProperty = $window.PSObject.Properties['windowDurationMins']
            $resetProperty = $window.PSObject.Properties['resetsAt']
            [void]$candidates.Add([pscustomobject]@{
                Name = $windowName
                Remaining = [Math]::Max(0.0, [Math]::Min(100.0, 100.0 - [double]$usedProperty.Value))
                WindowMinutes = if ($durationProperty -and $null -ne $durationProperty.Value) { [long]$durationProperty.Value } else { $null }
                ResetsAt = if ($resetProperty -and $null -ne $resetProperty.Value) { [long]$resetProperty.Value } else { $null }
            })
        }
        if ($candidates.Count -eq 0) { return $null }

        # The API does not guarantee that primary is the five-hour window.
        # Use the advertised duration, matching the quota view's classifier.
        $weekly = @($candidates | Sort-Object @{ Expression = {
            if ($null -ne $_.WindowMinutes) { [long]$_.WindowMinutes } else { -1L }
        }; Descending = $true })[0]
        $fiveHourCandidates = @($candidates | Where-Object {
            $null -ne $_.WindowMinutes -and
            [long]$_.WindowMinutes -ge 240 -and
            [long]$_.WindowMinutes -le 360
        })
        $fiveHour = if ($fiveHourCandidates.Count -gt 0) {
            @($fiveHourCandidates | Sort-Object @{ Expression = { [Math]::Abs([long]$_.WindowMinutes - 300L) } })[0]
        } else { $weekly }
        $usesWeeklyFallback = (
            $candidates.Count -eq 1 -or
            ($fiveHour.Name -eq $weekly.Name -and $fiveHour.WindowMinutes -eq $weekly.WindowMinutes)
        )
        return [pscustomobject]@{
            observedAt = [DateTimeOffset]::Now.ToString('o')
            primaryRemaining = [double]$fiveHour.Remaining
            secondaryRemaining = [double]$weekly.Remaining
            primaryWindowMinutes = $fiveHour.WindowMinutes
            secondaryWindowMinutes = $weekly.WindowMinutes
            primaryResetsAt = $fiveHour.ResetsAt
            secondaryResetsAt = $weekly.ResetsAt
            fiveHourUsesWeeklyFallback = [bool]$usesWeeklyFallback
        }
    } catch {
        return $null
    }
}

function Get-CqoAccountById {
    param(
        [Parameter(Mandatory = $true)]$Registry,
        [Parameter(Mandatory = $true)][string]$IdentityId
    )

    return @($Registry.accounts | Where-Object { [string]$_.id -eq $IdentityId }) | Select-Object -First 1
}

function Save-CqoCurrentChatGptAccount {
    param(
        [Parameter(Mandatory = $true)]$Store,
        [string]$Label,
        [switch]$ForceNew,
        [switch]$DoNotActivate,
        [string]$ExistingIdentityId,
        [string]$AuthPath,
        [hashtable]$Environment
    )

    $resolvedAuthPath = if ($AuthPath) { [IO.Path]::GetFullPath($AuthPath) } else { [string]$Store.AuthPath }
    if (-not (Test-Path -LiteralPath $resolvedAuthPath -PathType Leaf)) {
        throw '当前 Codex 登录缓存不存在。请先通过 ChatGPT 登录。'
    }

    # The user's base config may point at a custom provider. Force the built-in
    # OpenAI provider while identifying the browser-authenticated subscription.
    $accountInfo = Get-CqoCurrentAccountInfo -Environment $Environment -ForceChatGptProvider
    if ($accountInfo.Type -ne 'chatgpt') {
        throw '当前不是 ChatGPT 包月账号登录。'
    }

    $registry = Get-CqoAccountRegistry -Store $Store
    $account = $null
    if ($ExistingIdentityId) {
        $account = Get-CqoAccountById -Registry $registry -IdentityId $ExistingIdentityId
        if (-not $account -or [string]$account.kind -ne 'chatgpt' -or
            -not ([string]$account.email).Equals([string]$accountInfo.Email, [StringComparison]::OrdinalIgnoreCase)) {
            throw '重新认证的邮箱与所选账号不一致。'
        }
    } elseif (-not $ForceNew -and $accountInfo.Email) {
        $account = @($registry.accounts | Where-Object {
            [string]$_.kind -eq 'chatgpt' -and
            [string]$_.email -and
            ([string]$_.email).Equals($accountInfo.Email, [StringComparison]::OrdinalIgnoreCase)
        }) | Select-Object -First 1
    }

    $identityId = if ($account) { [string]$account.id } else { [Guid]::NewGuid().ToString('N') }
    $existingProfileName = if ($account -and $account.profileName) {
        [string]$account.profileName
    } else { $null }
    $profile = Write-CqoChatGptProfile -Store $Store -IdentityId $identityId -ProfileName $existingProfileName
    $profileName = [string]$profile.Name
    $profilePath = [string]$profile.Path
    $quota = if ($Environment) {
        Get-CqoCurrentQuotaCache -Environment $Environment -ForceChatGptProvider
    } else {
        Get-CqoCurrentQuotaCache -ForceChatGptProvider
    }
    # Network requests can rotate credentials. Save the latest file afterwards.
    $authText = Get-Content -LiteralPath $resolvedAuthPath -Encoding UTF8 -Raw
    [void](Save-CqoVaultValue -Store $Store -IdentityId $identityId -Value $authText)
    $displayLabel = if ($Label) {
        $Label
    } elseif ($accountInfo.Email) {
        $accountInfo.Email
    } else {
        'ChatGPT 账号'
    }
    $now = [DateTimeOffset]::Now.ToString('o')
    $newAccount = [pscustomobject]@{
        id = $identityId
        kind = 'chatgpt'
        label = $displayLabel
        email = $accountInfo.Email
        planType = $accountInfo.PlanType
        profileName = $profileName
        profilePath = $profilePath
        envKeyName = $null
        quota = $quota
        reauthRequired = $false
        updatedAt = $now
    }

    $remaining = @($registry.accounts | Where-Object { [string]$_.id -ne $identityId })
    $registry.accounts = @($remaining + $newAccount)
    if (-not $DoNotActivate) { $registry.activeId = $identityId }
    Save-CqoAccountRegistry -Store $Store -Registry $registry
    return $newAccount
}

function ConvertFrom-CqoTomlString {
    param([string]$Value)
    if (-not $Value) { return $null }
    $trimmed = $Value.Trim()
    if ($trimmed.Length -ge 2 -and (($trimmed[0] -eq '"' -and $trimmed[-1] -eq '"') -or ($trimmed[0] -eq "'" -and $trimmed[-1] -eq "'"))) {
        return $trimmed.Substring(1, $trimmed.Length - 2)
    }
    return $trimmed
}

function Get-CqoTomlValue {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $match = [regex]::Match($Text, ('(?m)^\s*' + [regex]::Escape($Name) + '\s*=\s*(.+?)\s*$'))
    if (-not $match.Success) { return $null }
    return ConvertFrom-CqoTomlString $match.Groups[1].Value
}

function Quote-CqoTomlString {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Write-CqoChatGptProfile {
    param(
        [Parameter(Mandatory = $true)]$Store,
        [Parameter(Mandatory = $true)][string]$IdentityId,
        [string]$ProfileName
    )
    $resolvedProfileName = if ($ProfileName) { $ProfileName } else { 'cqo-' + $IdentityId.Substring(0, 10) }
    $profilePath = Join-Path $Store.CodexHome ($resolvedProfileName + '.config.toml')
    $profileText = @(
        'model_provider = "openai"'
        'cli_auth_credentials_store = "file"'
    ) -join [Environment]::NewLine
    Write-CqoAtomicText -Path $profilePath -Value $profileText
    return [pscustomobject]@{ Name = $resolvedProfileName; Path = $profilePath }
}

function ConvertTo-CqoCustomProfileText {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigText,
        [Parameter(Mandatory = $true)][string]$ProviderName,
        [Parameter(Mandatory = $true)][string]$EnvironmentKeyName
    )

    $providerHeaderPattern = '^\s*\[\s*model_providers\.' + [regex]::Escape($ProviderName) + '\s*\]\s*$'
    $lines = @($ConfigText -split '\r?\n')
    $output = New-Object System.Collections.Generic.List[string]
    $insideProvider = $false
    $foundProvider = $false
    $providerSettingsWritten = $false
    foreach ($line in $lines) {
        $isSection = $line -match '^\s*\[[^\]]+\]\s*$'
        if ($isSection -and $insideProvider -and -not $providerSettingsWritten) {
            $output.Add('requires_openai_auth = false')
            $output.Add(('env_key = {0}' -f (Quote-CqoTomlString $EnvironmentKeyName)))
            $providerSettingsWritten = $true
        }
        if ($isSection) {
            $insideProvider = $line -match $providerHeaderPattern
            if ($insideProvider) { $foundProvider = $true }
        }
        if ($insideProvider -and $line -match '^\s*(requires_openai_auth|env_key)\s*=') { continue }
        $output.Add($line)
    }
    if ($insideProvider -and -not $providerSettingsWritten) {
        $output.Add('requires_openai_auth = false')
        $output.Add(('env_key = {0}' -f (Quote-CqoTomlString $EnvironmentKeyName)))
        $providerSettingsWritten = $true
    }
    if (-not $foundProvider) { throw ('config.toml 中未找到 [model_providers.{0}]。' -f $ProviderName) }
    return ($output -join [Environment]::NewLine).TrimEnd()
}

function Import-CqoCustomProfile {
    param(
        [Parameter(Mandatory = $true)]$Store,
        [string]$AuthPath,
        [string]$ConfigPath,
        [string]$ApiKey,
        [string]$ConfigText,
        [string]$Label
    )

    if (-not $ApiKey) {
        if (-not $AuthPath -or -not (Test-Path -LiteralPath $AuthPath -PathType Leaf)) { throw '未找到 auth.json。' }
        $auth = Get-Content -LiteralPath $AuthPath -Encoding UTF8 -Raw | ConvertFrom-Json
        $apiKeyProperty = $auth.PSObject.Properties['OPENAI_API_KEY']
        if (-not $apiKeyProperty -or -not [string]$apiKeyProperty.Value) {
            throw 'auth.json 中未找到 OPENAI_API_KEY。'
        }
        $ApiKey = [string]$apiKeyProperty.Value
    }
    if (-not $ConfigText) {
        if (-not $ConfigPath -or -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw '未找到 config.toml。' }
        $ConfigText = Get-Content -LiteralPath $ConfigPath -Encoding UTF8 -Raw
    }
    $providerName = Get-CqoTomlValue -Text $ConfigText -Name 'model_provider'
    $model = Get-CqoTomlValue -Text $ConfigText -Name 'model'
    $baseUrl = Get-CqoTomlValue -Text $ConfigText -Name 'base_url'
    if (-not $providerName) { throw 'config.toml 中未找到 model_provider。' }
    if (-not $baseUrl) { throw 'config.toml 中未找到自定义 Provider 的 base_url。' }
    if (-not $model) { throw 'config.toml 中未找到 model。' }

    $identityId = [Guid]::NewGuid().ToString('N')
    $shortId = $identityId.Substring(0, 10)
    $profileName = 'cqo-' + $shortId
    $envKeyName = 'CQO_PROVIDER_KEY_' + $shortId.ToUpperInvariant()
    # Codex resolves -p <name> from $CODEX_HOME/<name>.config.toml.
    $profilePath = Join-Path $Store.CodexHome ($profileName + '.config.toml')
    $profileText = ConvertTo-CqoCustomProfileText -ConfigText $ConfigText -ProviderName $providerName -EnvironmentKeyName $envKeyName
    Write-CqoAtomicText -Path $profilePath -Value $profileText
    [void](Save-CqoVaultValue -Store $Store -IdentityId $identityId -Value $ApiKey)

    $registry = Get-CqoAccountRegistry -Store $Store
    $newAccount = [pscustomobject]@{
        id = $identityId
        kind = 'custom'
        label = if ($Label) { $Label } else { $providerName + ' · ' + $model }
        email = $null
        planType = $null
        profileName = $profileName
        profilePath = $profilePath
        envKeyName = $envKeyName
        baseUrl = $baseUrl
        model = $model
        quota = $null
        updatedAt = [DateTimeOffset]::Now.ToString('o')
    }
    $registry.accounts = @($registry.accounts) + $newAccount
    Save-CqoAccountRegistry -Store $Store -Registry $registry
    return $newAccount
}

function Get-CqoActiveLaunchContext {
    param(
        [Parameter(Mandatory = $true)]$Store,
        [string]$IdentityId
    )

    $registry = Get-CqoAccountRegistry -Store $Store
    $resolvedId = if ($IdentityId) { $IdentityId } else { [string]$registry.activeId }
    $identity = if ($resolvedId) { Get-CqoAccountById -Registry $registry -IdentityId $resolvedId } else { $null }
    $environment = @{ CODEX_HOME = [string]$Store.CodexHome }
    $profileName = $null
    if ($identity) {
        $profileName = [string]$identity.profileName
        if ([string]$identity.kind -eq 'custom') {
            $environment[[string]$identity.envKeyName] = Get-CqoVaultValue -Store $Store -IdentityId ([string]$identity.id)
        }
    }
    return [pscustomobject]@{
        Identity = $identity
        ProfileName = $profileName
        Environment = $environment
    }
}

function Test-CqoQuotaFailureText {
    param([AllowNull()][string]$Text)
    if (-not $Text) { return $false }
    return [regex]::IsMatch($Text, $script:CqoQuotaFailurePattern)
}

function Get-CqoTurnStatusType {
    param($Turn)
    if (-not $Turn -or -not ($Turn.PSObject.Properties.Name -contains 'status')) { return '' }
    if ($Turn.status -is [string]) { return ([string]$Turn.status).ToLowerInvariant() }
    if ($Turn.status -and $Turn.status.PSObject.Properties.Name -contains 'type') {
        return ([string]$Turn.status.type).ToLowerInvariant()
    }
    return ([string]$Turn.status).ToLowerInvariant()
}

function Test-CqoTurnQuotaFailure {
    param($Turn)
    if (-not $Turn) { return $false }
    $status = Get-CqoTurnStatusType -Turn $Turn
    if ($status -notin @('failed', 'error', 'interrupted', 'cancelled', 'canceled')) { return $false }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Turn.PSObject.Properties.Name -contains 'error' -and $Turn.error) {
        $candidates.Add(($Turn.error | ConvertTo-Json -Compress -Depth 12))
    }
    foreach ($item in @($Turn.items)) {
        if (-not $item) { continue }
        $type = ([string]$item.type).ToLowerInvariant()
        $role = if ($item.PSObject.Properties.Name -contains 'role') { ([string]$item.role).ToLowerInvariant() } else { '' }
        if ($role -eq 'user' -or $type -in @('usermessage', 'user_message')) { continue }
        if ($type -match 'error|failure|failed' -or $role -eq 'system') {
            $candidates.Add(($item | ConvertTo-Json -Compress -Depth 12))
        }
    }
    return Test-CqoQuotaFailureText -Text ($candidates -join [Environment]::NewLine)
}

function Get-CqoTurnUserText {
    param($Turn)
    if (-not $Turn) { return $null }

    foreach ($item in @($Turn.items)) {
        if (-not $item) { continue }
        $type = [string]$item.type
        if ($type -notin @('userMessage', 'user_message', 'message')) { continue }
        if ($item.PSObject.Properties.Name -contains 'role' -and [string]$item.role -and [string]$item.role -ne 'user') { continue }

        if ($item.PSObject.Properties.Name -contains 'text' -and [string]$item.text) {
            return [string]$item.text
        }
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($content in @($item.content)) {
            if (-not $content) { continue }
            if ($content -is [string]) {
                $parts.Add([string]$content)
            } elseif ($content.PSObject.Properties.Name -contains 'text' -and [string]$content.text) {
                $parts.Add([string]$content.text)
            }
        }
        if ($parts.Count -gt 0) { return ($parts -join [Environment]::NewLine) }
    }
    return $null
}

function Test-CqoRolloutHasActiveTurn {
    param([AllowNull()][string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

    $active = $false
    $stream = $null
    $reader = $null
    try {
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line -match '^\{[^{}]{0,160}"type":"event_msg","payload":\{"type":"task_started"') {
                $active = $true
            } elseif ($line -match '^\{[^{}]{0,160}"type":"event_msg","payload":\{"type":"task_complete"') {
                $active = $false
            }
        }
    } catch {
        return $false
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
    return $active
}

function Get-CqoThreadResumePlans {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Threads)

    $plans = New-Object System.Collections.Generic.List[object]
    foreach ($summary in $Threads) {
        $threadId = [string]$summary.id
        if (-not $threadId) { continue }
        $wasActive = (Get-CqoTurnStatusType -Turn $summary) -eq 'active'
        $resumeId = $threadId
        $prompt = if ($wasActive) {
            '继续完成刚才被暂停的任务。先核对工作区现状，保留已经完成的改动，然后从未完成处继续。'
        } else { $null }
        $sanitized = $false
        $cwd = if ($summary.PSObject.Properties.Name -contains 'cwd') { [string]$summary.cwd } else { $null }

        try {
            $read = Invoke-CqoRpcRequest -Method 'thread/read' -Params @{ threadId = $threadId; includeTurns = $true } -TimeoutSeconds 8
            if (-not $read -or -not $read.thread) { throw 'thread/read 未返回会话。' }
            if ($read -and $read.thread) {
                $rolloutActive = ($read.thread.PSObject.Properties.Name -contains 'path') -and
                    (Test-CqoRolloutHasActiveTurn -Path ([string]$read.thread.path))
                if ($rolloutActive) {
                    $wasActive = $true
                    $prompt = '继续完成刚才被暂停的任务。先核对工作区现状，保留已经完成的改动，然后从未完成处继续。'
                }
                if ($read.thread.PSObject.Properties.Name -contains 'cwd' -and [string]$read.thread.cwd) {
                    $cwd = [string]$read.thread.cwd
                }
                $turns = @($read.thread.turns)
                if ($turns.Count -gt 0) {
                    $lastTurn = $turns[-1]
                    if ((Get-CqoTurnStatusType -Turn $lastTurn) -in @('inprogress', 'in_progress', 'active')) {
                        $wasActive = $true
                        $prompt = '继续完成刚才被暂停的任务。先核对工作区现状，保留已经完成的改动，然后从未完成处继续。'
                    }
                    if (-not $rolloutActive -and (Test-CqoTurnQuotaFailure -Turn $lastTurn)) {
                        $originalRequest = Get-CqoTurnUserText -Turn $lastTurn
                        # Establish the safe fallback before any fork RPC. Even
                        # if the server call throws, the failed thread will not
                        # be resumed or submitted to the model.
                        $resumeId = $null
                        $sanitized = $true
                        $prompt = if ($originalRequest) {
                            $originalRequest + [Environment]::NewLine + [Environment]::NewLine + '先核对工作区现状，保留已经完成的改动，然后从未完成处继续。'
                        } else {
                            '继续完成刚才未完成的任务。先核对工作区现状，保留已经完成的改动，然后从未完成处继续。'
                        }
                        $previousCompleted = $null
                        if ($turns.Count -gt 1) {
                            for ($index = $turns.Count - 2; $index -ge 0; $index--) {
                                if ((Get-CqoTurnStatusType -Turn $turns[$index]) -eq 'completed') {
                                    $previousCompleted = $turns[$index]
                                    break
                                }
                            }
                        }

                        if ($previousCompleted -and $previousCompleted.id) {
                            $fork = Invoke-CqoRpcRequest -Method 'thread/fork' -Params @{
                                threadId = $threadId
                                lastTurnId = [string]$previousCompleted.id
                            } -TimeoutSeconds 10
                            if ($fork -and $fork.thread -and $fork.thread.id) {
                                $resumeId = [string]$fork.thread.id
                                $sanitized = $true
                            }
                        } else {
                            $startParams = @{}
                            if ($cwd) { $startParams.cwd = $cwd }
                            if ($read.thread.PSObject.Properties.Name -contains 'model' -and [string]$read.thread.model) {
                                $startParams.model = [string]$read.thread.model
                            }
                            $fresh = Invoke-CqoRpcRequest -Method 'thread/start' -Params $startParams -TimeoutSeconds 10
                            if ($fresh -and $fresh.thread -and $fresh.thread.id) {
                                $resumeId = [string]$fresh.thread.id
                                $sanitized = $true
                            }
                        }

                    }
                }
            }
        } catch {
            throw ('无法检查 Codex 会话 {0}，账号尚未切换：{1}' -f $threadId, $_.Exception.Message)
        }

        $plans.Add([pscustomobject]@{
            originalThreadId = $threadId
            threadId = $resumeId
            cwd = $cwd
            wasActive = [bool]$wasActive
            sanitized = [bool]$sanitized
            prompt = $prompt
        })
    }
    return $plans.ToArray()
}

function Restart-CqoDaemon {
    param($LaunchContext)

    $exe = Find-CqoCodexExecutable
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $exe
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add('app-server')
    # Account switching does not use Code Mode or MCP. Keep the managed daemon
    # restart quiet on Windows until Codex applies CREATE_NO_WINDOW upstream.
    $arguments.Add('--disable')
    $arguments.Add('code_mode_host')
    $arguments.Add('-c')
    $arguments.Add('mcp_servers.node_repl.enabled=false')
    $arguments.Add('daemon')
    $arguments.Add('restart')
    $startInfo.Arguments = ($arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_.Replace('"', '') + '"' } else { $_ } }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    # Daemon status text is not part of the account worker JSON response.
    # Never let a daemon inherit the worker's output pipes.
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($LaunchContext) {
        foreach ($name in $LaunchContext.Environment.Keys) {
            $startInfo.EnvironmentVariables[[string]$name] = [string]$LaunchContext.Environment[$name]
        }
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    try {
        $process.StandardInput.Close()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(20000)) {
            $process.Kill()
            throw 'Codex 后台服务操作超时，请重试。'
        }
        if ($process.ExitCode -ne 0) { throw '无法重启 Codex App Server daemon。' }
    } finally {
        $process.Dispose()
    }
}

function Get-CqoProcessSessionId {
    param([AllowNull()][string]$CommandLine)
    if (-not $CommandLine) { return $null }
    $match = [regex]::Match($CommandLine, '(?i)(?:^|\s)resume\s+["'']?(?<id>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})["'']?(?=\s|$)')
    if ($match.Success) { return $match.Groups['id'].Value }
    return $null
}

function Get-CqoProcessResumePlans {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Processes)

    if ($Processes.Count -eq 0) { return @() }
    $orderedProcesses = @($Processes | Sort-Object CreationDate)
    $oldestStart = [datetime]$orderedProcesses[0].CreationDate
    $cutoff = ([DateTimeOffset]$oldestStart.AddMinutes(-2)).ToUnixTimeSeconds()
    $summaries = New-Object System.Collections.Generic.List[object]
    $cursor = $null
    for ($page = 0; $page -lt 10; $page++) {
        $params = @{ limit = 100; sortKey = 'created_at'; sortDirection = 'desc'; sourceKinds = @('cli') }
        if ($cursor) { $params.cursor = $cursor }
        $result = Invoke-CqoRpcRequest -Method 'thread/list' -Params $params -TimeoutSeconds 12
        $batch = @($result.data | Where-Object { $null -ne $_ })
        foreach ($thread in $batch) { if ($thread -and $thread.id) { $summaries.Add($thread) } }
        if (-not $result.nextCursor -or $batch.Count -eq 0) { break }
        $lastCreated = if ($batch[-1].createdAt) { [long]$batch[-1].createdAt } else { 0L }
        if ($lastCreated -lt $cutoff) { break }
        $cursor = [string]$result.nextCursor
    }

    $usedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $plans = New-Object System.Collections.Generic.List[object]
    foreach ($process in $orderedProcesses) {
        $sessionId = Get-CqoProcessSessionId -CommandLine ([string]$process.CommandLine)
        $summary = $null
        if ($sessionId) {
            $found = @($summaries | Where-Object { [string]$_.id -eq $sessionId } | Select-Object -First 1)
            if ($found.Count -gt 0) { $summary = $found[0] }
            if (-not $summary) {
                $read = Invoke-CqoRpcRequest -Method 'thread/read' -Params @{ threadId = $sessionId } -TimeoutSeconds 8
                if (-not $read -or -not $read.thread) { throw '无法读取当前终端的 Codex 会话。' }
                $summary = $read.thread
            }
        } else {
            $start = [datetime]$process.CreationDate
            $matches = @($summaries | Where-Object { -not $usedIds.Contains([string]$_.id) -and $_.createdAt } | ForEach-Object {
                [pscustomobject]@{
                    Thread = $_
                    Delta = [Math]::Abs(([DateTimeOffset]::FromUnixTimeSeconds([long]$_.createdAt).LocalDateTime - $start).TotalSeconds)
                }
            } | Sort-Object Delta)
            if ($matches.Count -gt 0 -and $matches[0].Delta -le 120 -and
                ($matches.Count -eq 1 -or ($matches[1].Delta - $matches[0].Delta) -gt 15)) {
                $summary = $matches[0].Thread
            }
        }

        if (-not $summary) {
            throw '无法确认运行中的 Codex 终端会话；账号尚未切换。'
        }
        if (-not $usedIds.Add([string]$summary.id)) {
            throw '多个 Codex 终端指向同一会话；账号尚未切换。'
        }
        foreach ($plan in @(Get-CqoThreadResumePlans -Threads @($summary))) {
            $plan | Add-Member -NotePropertyName processId -NotePropertyValue ([int]$process.ProcessId)
            $plans.Add($plan)
        }
    }
    return $plans.ToArray()
}

function Get-CqoInteractiveCodexProcesses {
    $excluded = '(?i)\b(app-server|app|exec|review|login|logout|mcp|plugin|completion|update|doctor|sandbox|debug|apply|cloud|features|remote-control)\b'
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -ieq 'codex.exe' -and $_.CommandLine -and $_.CommandLine -notmatch $excluded
    } | Sort-Object CreationDate -Descending)
}

function Get-CqoCommandLineProfile {
    param([AllowNull()][string]$CommandLine)
    if (-not $CommandLine) { return $null }
    $match = [regex]::Match(
        $CommandLine,
        '(?i)(?:^|\s)(?:-p|--profile)(?:\s+|=)(?:"([^"]+)"|''([^'']+)''|([^\s]+))'
    )
    if (-not $match.Success) { return $null }
    foreach ($index in 1..3) {
        if ($match.Groups[$index].Success) { return $match.Groups[$index].Value }
    }
    return $null
}

function Sync-CqoActiveIdentity {
    param(
        [Parameter(Mandatory = $true)]$Store,
        [switch]$Detailed
    )

    $registry = Get-CqoAccountRegistry -Store $Store
    $interactiveProcesses = @(Get-CqoInteractiveCodexProcesses)
    if ($interactiveProcesses.Count -eq 0) {
        if ($Detailed) { return [pscustomobject]@{ Registry = $registry; Resolved = $false; Identity = $null } }
        return $registry
    }

    # The newest interactive Codex process is the best available description
    # of what the user is actually using. A managed -p profile is definitive;
    # a default launch is reconciled through account/read instead of trusting
    # the last picker selection persisted in accounts.json.
    $currentProcess = $interactiveProcesses | Select-Object -First 1
    $profileName = Get-CqoCommandLineProfile -CommandLine ([string]$currentProcess.CommandLine)
    $observedIdentity = $null
    if ($profileName) {
        $observedIdentity = @($registry.accounts | Where-Object {
            [string]$_.profileName -and
            ([string]$_.profileName).Equals($profileName, [StringComparison]::OrdinalIgnoreCase)
        }) | Select-Object -First 1
    } else {
        try {
            $accountInfo = Get-CqoCurrentAccountInfo -Environment @{ CODEX_HOME = [string]$Store.CodexHome }
            if ($accountInfo.Type -eq 'chatgpt' -and $accountInfo.Email) {
                $observedIdentity = @($registry.accounts | Where-Object {
                    [string]$_.kind -eq 'chatgpt' -and
                    [string]$_.email -and
                    ([string]$_.email).Equals([string]$accountInfo.Email, [StringComparison]::OrdinalIgnoreCase)
                }) | Select-Object -First 1
            }
        } catch {
            if ($Detailed) { return [pscustomobject]@{ Registry = $registry; Resolved = $false; Identity = $null } }
            return $registry
        }
    }

    if ($observedIdentity -and [string]$registry.activeId -ne [string]$observedIdentity.id) {
        $registry.activeId = [string]$observedIdentity.id
        Save-CqoAccountRegistry -Store $Store -Registry $registry
    }
    if ($Detailed) {
        return [pscustomobject]@{
            Registry = $registry
            Resolved = [bool]$observedIdentity
            Identity = $observedIdentity
        }
    }
    return $registry
}

function Stop-CqoInteractiveCodexProcesses {
    param(
        [object[]]$Processes,
        [switch]$CloseHostShells
    )

    $targets = if ($null -ne $Processes) { @($Processes) } else { @(Get-CqoInteractiveCodexProcesses) }
    $hostIds = @($targets | ForEach-Object { [int]$_.ParentProcessId } | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    foreach ($process in $targets) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    }
    foreach ($process in $targets) {
        Wait-Process -Id $process.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
        if (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue) {
            throw ('The previous Codex process did not exit: {0}.' -f $process.ProcessId)
        }
    }
    if (-not $CloseHostShells) { return }

    # Close only the command shell that directly hosted a Codex TUI. A zero
    # termination status lets Windows Terminal's default closeOnExit=graceful
    # policy close the old tab instead of leaving an error tab behind. Never
    # terminate Windows Terminal itself or unrelated PowerShell sessions.
    foreach ($hostId in $hostIds) {
        $hostProcess = Get-CimInstance Win32_Process -Filter ('ProcessId = {0}' -f $hostId) -ErrorAction SilentlyContinue
        if ($hostProcess -and $hostProcess.Name -match '^(?i:powershell|pwsh|cmd)\.exe$') {
            $termination = Invoke-CimMethod -InputObject $hostProcess -MethodName Terminate -Arguments @{ Reason = [uint32]0 } -ErrorAction Stop
            if ($termination.ReturnValue -ne 0) {
                throw ('Unable to close the previous Codex terminal host: {0} (return value {1}).' -f $hostId, $termination.ReturnValue)
            }
            Wait-Process -Id $hostId -Timeout 5 -ErrorAction SilentlyContinue
            if (Get-Process -Id $hostId -ErrorAction SilentlyContinue) {
                throw ('The previous Codex terminal host did not exit: {0}.' -f $hostId)
            }
        }
    }
}

function Test-CqoChatGptIdentity {
    param([Parameter(Mandatory = $true)]$Store, [Parameter(Mandatory = $true)]$Identity)

    # Authenticate before interrupting any work or replacing the global login.
    $probeHome = Join-Path $Store.Root ('verify-' + [Guid]::NewGuid().ToString('N'))
    $probeAuth = Join-Path $probeHome 'auth.json'
    New-Item -ItemType Directory -Path $probeHome -Force | Out-Null
    try {
        Write-CqoAtomicText -Path $probeAuth -Value (Get-CqoVaultValue -Store $Store -IdentityId $Identity.id)
        $environment = @{ CODEX_HOME = $probeHome }
        try {
            $info = Get-CqoCurrentAccountInfo -Environment $environment -ForceChatGptProvider -RefreshToken
        } catch {
            if ($_.Exception.Message -match '(?i)invalidated oauth token|401 Unauthorized|access token could not be refreshed|logged out|signed in to another account') {
                throw '目标 ChatGPT 账号的登录已失效，请重新认证该账号。'
            }
            throw
        }
        if ($info.Type -ne 'chatgpt') {
            throw '目标 ChatGPT 账号的登录已失效，请重新认证该账号。'
        }
        if ($info.Email -ne $Identity.email) {
            throw '目标账号的凭据与登记信息不一致，请重新认证该账号。'
        }
        try {
            [void](Invoke-CqoRpcRequest -Method 'account/rateLimits/read' -Environment $environment -ForceChatGptProvider -TimeoutSeconds 12)
        } catch {
            if ($_.Exception.Message -match '(?i)invalidated oauth token|401 Unauthorized|access token could not be refreshed|logged out|signed in to another account') {
                throw '目标 ChatGPT 账号的登录已失效，请重新认证该账号。'
            }
            throw
        }
    } finally {
        if (Test-Path -LiteralPath $probeAuth) {
            # Preserve any token rotation even if a later request failed.
            [void](Save-CqoVaultValue -Store $Store -IdentityId $Identity.id -Value (Get-Content -LiteralPath $probeAuth -Raw -Encoding UTF8))
        }
        $root = [IO.Path]::GetFullPath($Store.Root).TrimEnd('\') + '\'
        if ([IO.Path]::GetFullPath($probeHome).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $probeHome -Recurse -Force
        }
    }
}

function Switch-CqoIdentity {
    param(
        [Parameter(Mandatory = $true)]$Store,
        [Parameter(Mandatory = $true)][string]$IdentityId,
        [switch]$Force,
        [switch]$SkipPreviousCredentialCapture
    )

    $registry = Get-CqoAccountRegistry -Store $Store
    $target = Get-CqoAccountById -Registry $registry -IdentityId $IdentityId
    if (-not $target) { throw '目标身份不存在。' }
    if ([string]$registry.activeId -eq $IdentityId -and -not $Force) {
        return [pscustomobject]@{ switched = $false; identity = $target; threads = @() }
    }
    if ([string]$target.kind -eq 'chatgpt') {
        try {
            Test-CqoChatGptIdentity -Store $Store -Identity $target
        } catch {
            if ($_.Exception.Message -match '登录已失效|凭据与登记信息不一致|加密凭据不存在') {
                if ($target.PSObject.Properties.Name -contains 'reauthRequired') {
                    $target.reauthRequired = $true
                } else {
                    $target | Add-Member -NotePropertyName reauthRequired -NotePropertyValue $true
                }
                Save-CqoAccountRegistry -Store $Store -Registry $registry
            }
            throw
        }
    }

    $interactiveProcesses = @(Get-CqoInteractiveCodexProcesses)

    $previousId = [string]$registry.activeId
    $previousContext = Get-CqoActiveLaunchContext -Store $Store
    $previousIdentity = if ($previousId) { Get-CqoAccountById -Registry $registry -IdentityId $previousId } else { $null }
    if ($previousIdentity -and [string]$previousIdentity.kind -eq 'chatgpt' -and -not $SkipPreviousCredentialCapture) {
        $liveAccount = Get-CqoCurrentAccountInfo -Environment @{ CODEX_HOME = [string]$Store.CodexHome } -ForceChatGptProvider
        if ($liveAccount.Type -ne 'chatgpt' -or
            -not ([string]$liveAccount.Email).Equals([string]$previousIdentity.email, [StringComparison]::OrdinalIgnoreCase)) {
            throw '当前 Codex 登录与已登记账号不一致；账号尚未切换，请重新保存当前账号。'
        }
    }
    if ($previousId) {
        if ($previousIdentity) {
            $previousQuota = Get-CqoCurrentQuotaCache -Environment $previousContext.Environment -ForceChatGptProvider:([string]$previousIdentity.kind -eq 'chatgpt')
            if ($previousQuota) {
                $previousIdentity.quota = $previousQuota
                $previousIdentity.updatedAt = [DateTimeOffset]::Now.ToString('o')
                Save-CqoAccountRegistry -Store $Store -Registry $registry
            }
        }
    }
    $resumePlans = @(Get-CqoProcessResumePlans -Processes $interactiveProcesses)
    $previousAuth = if (Test-Path -LiteralPath $Store.AuthPath -PathType Leaf) {
        Get-Content -LiteralPath $Store.AuthPath -Encoding UTF8 -Raw
    } else { $null }
    if ($previousId -and $previousAuth -and -not $SkipPreviousCredentialCapture) {
        $previous = Get-CqoAccountById -Registry $registry -IdentityId $previousId
        if ($previous -and [string]$previous.kind -eq 'chatgpt') {
            [void](Save-CqoVaultValue -Store $Store -IdentityId $previousId -Value $previousAuth)
        }
    }

    $authReplaced = $false
    try {
        Stop-CqoInteractiveCodexProcesses -Processes $interactiveProcesses -CloseHostShells
        if ([string]$target.kind -eq 'chatgpt') {
            $targetAuth = Get-CqoVaultValue -Store $Store -IdentityId $IdentityId
            Write-CqoAtomicText -Path $Store.AuthPath -Value $targetAuth
            $authReplaced = $true
        }
        $registry.activeId = $IdentityId
        Save-CqoAccountRegistry -Store $Store -Registry $registry
        $targetContext = Get-CqoActiveLaunchContext -Store $Store -IdentityId $IdentityId
        Restart-CqoDaemon -LaunchContext $targetContext

        if ([string]$target.kind -eq 'chatgpt') {
            $accountInfo = Get-CqoCurrentAccountInfo -Environment $targetContext.Environment -ForceChatGptProvider
            if ($accountInfo.Type -ne 'chatgpt' -or $accountInfo.Email -ne $target.email) { throw '目标 ChatGPT 登录已失效或身份不匹配。' }
            [void](Save-CqoVaultValue -Store $Store -IdentityId $IdentityId -Value (Get-Content -LiteralPath $Store.AuthPath -Encoding UTF8 -Raw))
        }

        return [pscustomobject]@{
            switched = $true
            identity = $target
            previousId = $previousId
            threads = $resumePlans
        }
    } catch {
        $failure = $_
        if ($authReplaced) {
            if ($previousAuth) {
                Write-CqoAtomicText -Path $Store.AuthPath -Value $previousAuth
            } elseif (Test-Path -LiteralPath $Store.AuthPath -PathType Leaf) {
                Remove-Item -LiteralPath $Store.AuthPath -Force
            }
        }
        $registry.activeId = if ($previousId) { $previousId } else { $null }
        Save-CqoAccountRegistry -Store $Store -Registry $registry
        try { Restart-CqoDaemon -LaunchContext $previousContext } catch {}
        if ($previousId) {
            $recoveryPlans = @($resumePlans | Where-Object {
                ($_.PSObject.Properties.Name -contains 'processId') -and $_.processId -and
                -not (Get-Process -Id ([int]$_.processId) -ErrorAction SilentlyContinue)
            })
            if ($recoveryPlans.Count -gt 0) {
                $failure.Exception.Data['CqoRecoveryPlans'] = $recoveryPlans
                $failure.Exception.Data['CqoRecoveryIdentityId'] = $previousId
            }
        }
        throw $failure
    }
}

Export-ModuleMember -Function @(
    'Find-CqoCodexExecutable',
    'Initialize-CqoAccountStore',
    'Get-CqoAccountRegistry',
    'Sync-CqoActiveIdentity',
    'Save-CqoCurrentChatGptAccount',
    'Import-CqoCustomProfile',
    'Get-CqoActiveLaunchContext',
    'Get-CqoCurrentAccountInfo',
    'Get-CqoCurrentQuotaCache',
    'Switch-CqoIdentity',
    'Test-CqoQuotaFailureText',
    'Test-CqoTurnQuotaFailure'
)
