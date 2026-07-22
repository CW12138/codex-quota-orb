param(
    [switch]$ShowDiagnostics,
    [switch]$HeadlessProbe,
    [switch]$DirectWorker,
    [switch]$ResetCreditsWorker,
    [switch]$QASolidWindow,
    [string]$QARenderPath,
    [ValidateRange(0, 100)][double]$QARemaining = 64.0,
    [ValidateSet('orb', 'capacity', 'daily', 'skill', 'skill-chain', 'agent', 'reset-credits')][string]$QAView = 'orb',
    [int]$AutoCloseSeconds = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$mutex = $null
if (-not $HeadlessProbe -and -not $DirectWorker -and -not $ResetCreditsWorker -and -not $QARenderPath) {
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\CodexRateLimitWidget', [ref]$createdNew)
    if (-not $createdNew) {
        $mutex.Dispose()
        exit 0
    }
}

$defaultCodexHome = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
$script:CodexHome = if ($env:CODEX_HOME) {
    $env:CODEX_HOME
} elseif (Test-Path -LiteralPath $defaultCodexHome) {
    $defaultCodexHome
} else {
    $codexCommandForHome = Get-Command codex -ErrorAction SilentlyContinue
    if ($codexCommandForHome -and $codexCommandForHome.Source) {
        $npmDir = Split-Path -Parent $codexCommandForHome.Source
        $derivedUserRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $npmDir))
        $derivedCodexHome = Join-Path $derivedUserRoot '.codex'
        if (Test-Path -LiteralPath $derivedCodexHome) { $derivedCodexHome } else { $defaultCodexHome }
    } else {
        $defaultCodexHome
    }
}
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:RuntimeDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexRateWidget'
$script:CurrentSnapshot = $null
$script:LastRolloutPath = $null
$script:LastRolloutWriteTicks = 0L
$script:ExitRequested = $false
$script:IsRefreshing = $false
$script:DirectWorkerProcess = $null
$script:PendingDirectRefresh = $false
$script:ResetCreditsWorkerProcess = $null
$script:IsResetCreditsRefreshing = $false
$script:ResetCreditsSnapshot = $null
$script:IsAnalyticsRefreshing = $false
$script:AnalyticsSnapshot = $null
$script:AccountUsage = $null
$script:ActiveAnalyticsTab = 'daily'
$script:ActiveSkillView = 'primary'
$script:LastRateHistorySignature = $null
$script:ViewMode = 'orb'
$script:OrbWaterLevel = 0.0
$script:WavePhase = 0.0
$script:OrbIsDragging = $false
$script:OrbPointerMoved = $false

try {
    if (-not (Test-Path -LiteralPath $script:RuntimeDir)) {
        New-Item -ItemType Directory -Path $script:RuntimeDir -Force | Out-Null
    }
} catch {
    $script:RuntimeDir = Join-Path $script:ScriptDir '.runtime'
    if (-not (Test-Path -LiteralPath $script:RuntimeDir)) {
        New-Item -ItemType Directory -Path $script:RuntimeDir -Force | Out-Null
    }
}
$script:SettingsPath = Join-Path $script:RuntimeDir 'settings.json'
$script:UsageCachePath = Join-Path $script:RuntimeDir 'usage-cache.json'
$script:RateHistoryPath = Join-Path $script:RuntimeDir 'rate-history.jsonl'
$script:UsageAnalyticsPath = Join-Path $script:ScriptDir 'UsageAnalytics.py'

function Write-Diagnostic {
    param([string]$Message)
    if ($ShowDiagnostics) {
        Write-Host ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message)
    }
}

function Find-CodexExecutable {
    $candidates = New-Object System.Collections.Generic.List[string]
    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        $npmRoot = Split-Path -Parent $command.Source
        $candidates.Add((Join-Path $npmRoot 'node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'))
        $candidates.Add((Join-Path $npmRoot 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'))
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-CodexHomeCandidates {
    $homes = New-Object System.Collections.Generic.List[string]
    if ($script:CodexHome) { $homes.Add($script:CodexHome) }

    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($command -and $command.Source -match '^(.*)\\AppData\\') {
        $homes.Add((Join-Path $Matches[1] '.codex'))
    }

    if ($env:USERPROFILE) {
        $homes.Add((Join-Path $env:USERPROFILE '.codex'))
    }

    return $homes |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -Unique
}

function Read-CodexChatGptAuth {
    foreach ($codexHome in (Get-CodexHomeCandidates)) {
        $authPath = Join-Path $codexHome 'auth.json'
        if (-not (Test-Path -LiteralPath $authPath -PathType Leaf)) { continue }

        try {
            $auth = Get-Content -LiteralPath $authPath -Encoding UTF8 -Raw | ConvertFrom-Json
            if ($auth.tokens -and $auth.tokens.access_token) {
                return [pscustomobject]@{
                    AccessToken = [string]$auth.tokens.access_token
                    AccountId   = if ($auth.tokens.account_id) { [string]$auth.tokens.account_id } else { $null }
                }
            }
        } catch {
            Write-Diagnostic 'Codex 登录信息暂时不可读取。'
        }
    }

    throw '未找到可用的 Codex ChatGPT 登录。'
}

function Read-ResetCreditsFromOfficialService {
    $auth = Read-CodexChatGptAuth
    $headers = @{
        Authorization = ('Bearer ' + $auth.AccessToken)
        Accept        = 'application/json'
        'User-Agent'  = 'CodexQuotaOrb/1.2.0'
    }
    if ($auth.AccountId) {
        $headers['ChatGPT-Account-Id'] = $auth.AccountId
    }

    try {
        # Read-only endpoint used by the installed Codex app. Never call the
        # separate consume endpoint from this project.
        $response = Invoke-RestMethod -Method Get `
            -Uri 'https://chatgpt.com/backend-api/wham/rate-limit-reset-credits' `
            -Headers $headers -TimeoutSec 15
    } catch {
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($statusCode -eq 401 -or $statusCode -eq 403) {
            throw 'Codex 登录已失效，请先在 Codex App 或 CLI 中重新登录。'
        }
        throw '重置卡服务暂时无法读取。'
    }

    $availableCredits = New-Object System.Collections.Generic.List[object]
    foreach ($credit in @($response.credits)) {
        if (-not $credit) { continue }
        if ([string]$credit.status -ne 'available') { continue }
        if ($credit.PSObject.Properties['is_supported_by_plan'] -and -not [bool]$credit.is_supported_by_plan) { continue }
        if (-not $credit.expires_at) { continue }

        try {
            $expiresAt = [DateTimeOffset]::Parse([string]$credit.expires_at).ToLocalTime()
        } catch {
            continue
        }

        $availableCredits.Add([pscustomobject]@{ ExpiresAt = $expiresAt })
    }

    $serverCount = if ($response.PSObject.Properties['available_count']) {
        [Math]::Max(0, [int]$response.available_count)
    } else {
        $availableCredits.Count
    }

    return [pscustomobject]@{
        AvailableCount = $serverCount
        Credits        = @($availableCredits | Sort-Object ExpiresAt)
        ObservedAt     = [DateTimeOffset]::Now
    }
}

function ConvertTo-RateSnapshot {
    param(
        [Parameter(Mandatory = $true)]$RateLimits,
        [Parameter(Mandatory = $true)][ValidateSet('direct', 'session')][string]$Source,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ObservedAt
    )

    $primary = if ($Source -eq 'direct') { $RateLimits.primary } else { $RateLimits.primary }
    if (-not $primary) {
        return $null
    }

    $used = if ($Source -eq 'direct') { $primary.usedPercent } else { $primary.used_percent }
    $resetEpoch = if ($Source -eq 'direct') { $primary.resetsAt } else { $primary.resets_at }
    $windowMinutes = if ($Source -eq 'direct') { $primary.windowDurationMins } else { $primary.window_minutes }
    $planType = if ($Source -eq 'direct') { $RateLimits.planType } else { $RateLimits.plan_type }
    $limitId = if ($Source -eq 'direct') { $RateLimits.limitId } else { $RateLimits.limit_id }

    if ($null -eq $used) {
        return $null
    }

    $resetAt = $null
    if ($null -ne $resetEpoch) {
        $resetAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$resetEpoch).ToLocalTime()
    }

    [pscustomobject]@{
        Source        = $Source
        UsedPercent   = [double]$used
        Remaining     = [Math]::Max(0.0, [Math]::Min(100.0, 100.0 - [double]$used))
        ResetAt       = $resetAt
        WindowMinutes = if ($null -ne $windowMinutes) { [long]$windowMinutes } else { $null }
        PlanType      = [string]$planType
        LimitId       = [string]$limitId
        ObservedAt    = $ObservedAt.ToLocalTime()
    }
}

function Read-AccountDataFromAppServer {
    $exe = Find-CodexExecutable
    if (-not $exe) {
        throw '未找到 codex.exe。'
    }

    $process = $null
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $exe
        $startInfo.Arguments = 'app-server --stdio'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $process.StandardInput.AutoFlush = $true

        $initialize = @{
            id = 0
            method = 'initialize'
            params = @{
                clientInfo = @{
                    name = 'codex_rate_widget'
                    title = 'Codex Quota Orb'
                    version = '1.2.0'
                }
            }
        } | ConvertTo-Json -Compress -Depth 8
        $initialized = @{ method = 'initialized'; params = @{} } | ConvertTo-Json -Compress -Depth 4
        $rateRequest = @{ id = 2; method = 'account/rateLimits/read'; params = @{} } | ConvertTo-Json -Compress -Depth 4
        $usageRequest = @{ id = 3; method = 'account/usage/read'; params = @{} } | ConvertTo-Json -Compress -Depth 4

        $process.StandardInput.WriteLine($initialize)
        $process.StandardInput.WriteLine($initialized)
        $process.StandardInput.WriteLine($rateRequest)
        $process.StandardInput.WriteLine($usageRequest)

        $deadline = [DateTime]::UtcNow.AddSeconds(8)
        $rateSeen = $false
        $usageSeen = $false
        $rateLimits = $null
        $usage = $null
        $rateError = $null
        $usageError = $null
        while ([DateTime]::UtcNow -lt $deadline -and (-not $rateSeen -or -not $usageSeen)) {
            $readTask = $process.StandardOutput.ReadLineAsync()
            $remainingMs = [Math]::Max(50, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (-not $readTask.Wait($remainingMs)) {
                break
            }

            $line = $readTask.Result
            if ($null -eq $line) {
                break
            }

            try {
                $message = $line | ConvertFrom-Json
            } catch {
                continue
            }

            if (-not ($message.PSObject.Properties.Name -contains 'id')) {
                continue
            }

            if ($message.id -eq 2) {
                $rateSeen = $true
                if ($message.PSObject.Properties.Name -contains 'error' -and $message.error) {
                    $rateError = [string]$message.error.message
                } elseif ($message.PSObject.Properties.Name -contains 'result' -and $message.result -and $message.result.rateLimits) {
                    $rateLimits = $message.result.rateLimits
                }
            } elseif ($message.id -eq 3) {
                $usageSeen = $true
                if ($message.PSObject.Properties.Name -contains 'error' -and $message.error) {
                    $usageError = [string]$message.error.message
                } elseif ($message.PSObject.Properties.Name -contains 'result' -and $message.result) {
                    $usage = $message.result
                }
            }
        }

        if (-not $rateSeen -and -not $usageSeen) {
            throw '读取账户接口超时。'
        }

        return [pscustomobject]@{
            RateLimits = $rateLimits
            Usage      = $usage
            RateError  = $rateError
            UsageError = $usageError
        }
    } finally {
        if ($process) {
            try {
                if (-not $process.HasExited) {
                    # Only terminate the child process created by this function.
                    $process.Kill()
                    $process.WaitForExit(1500) | Out-Null
                }
            } catch {}
            $process.Dispose()
        }
    }
}

function Read-RateLimitFromAppServer {
    $accountData = Read-AccountDataFromAppServer
    if ($accountData.RateLimits) {
        return ConvertTo-RateSnapshot -RateLimits $accountData.RateLimits -Source direct -ObservedAt ([DateTimeOffset]::Now)
    }
    if ($accountData.RateError) {
        throw $accountData.RateError
    }
    throw 'app-server 未返回 rateLimits。'
}

function Get-LatestRolloutFile {
    $candidates = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($codexHome in (Get-CodexHomeCandidates)) {
        for ($offset = 0; $offset -le 2; $offset++) {
            $date = (Get-Date).Date.AddDays(-$offset)
            $dayDir = Join-Path (Join-Path (Join-Path (Join-Path $codexHome 'sessions') $date.ToString('yyyy')) $date.ToString('MM')) $date.ToString('dd')
            if (Test-Path -LiteralPath $dayDir) {
                Get-ChildItem -LiteralPath $dayDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
                    $candidates.Add($_)
                }
            }
        }
    }

    return $candidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
}

function Read-RateLimitFromSessionEvents {
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($codexHome in (Get-CodexHomeCandidates)) {
        for ($offset = 0; $offset -le 7; $offset++) {
            $date = (Get-Date).Date.AddDays(-$offset)
            $dayDir = Join-Path (Join-Path (Join-Path (Join-Path $codexHome 'sessions') $date.ToString('yyyy')) $date.ToString('MM')) $date.ToString('dd')
            if (Test-Path -LiteralPath $dayDir) {
                Get-ChildItem -LiteralPath $dayDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
                    $files.Add($_)
                }
            }
        }
    }

    foreach ($file in ($files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 4)) {
        # Recent token-count snapshots occur near the tail. Keep this gate bounded so
        # image/tool-heavy sessions cannot block the WPF dispatcher during startup.
        $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Tail 120 -ErrorAction SilentlyContinue)
        for ($index = $lines.Count - 1; $index -ge 0; $index--) {
            $line = $lines[$index]
            if ($line -notlike '*"type":"token_count"*' -or $line -notlike '*"rate_limits"*') {
                continue
            }

            try {
                $event = $line | ConvertFrom-Json
            } catch {
                continue
            }

            if ($event.type -eq 'event_msg' -and $event.payload.type -eq 'token_count' -and $event.payload.rate_limits) {
                $observedAt = [DateTimeOffset]::Parse([string]$event.timestamp)
                return ConvertTo-RateSnapshot -RateLimits $event.payload.rate_limits -Source session -ObservedAt $observedAt
            }
        }
    }

    return $null
}

if ($DirectWorker) {
    $workerAccount = Read-AccountDataFromAppServer
    $workerSnapshot = if ($workerAccount.RateLimits) {
        ConvertTo-RateSnapshot -RateLimits $workerAccount.RateLimits -Source direct -ObservedAt ([DateTimeOffset]::Now)
    } else {
        $null
    }
    [pscustomobject]@{
        Rate = if ($workerSnapshot) {
            [pscustomobject]@{
                Source        = $workerSnapshot.Source
                UsedPercent   = $workerSnapshot.UsedPercent
                Remaining     = $workerSnapshot.Remaining
                ResetEpoch    = if ($workerSnapshot.ResetAt) { ([DateTimeOffset]$workerSnapshot.ResetAt).ToUnixTimeSeconds() } else { $null }
                WindowMinutes = $workerSnapshot.WindowMinutes
                PlanType      = $workerSnapshot.PlanType
                LimitId       = $workerSnapshot.LimitId
                ObservedEpoch = ([DateTimeOffset]$workerSnapshot.ObservedAt).ToUnixTimeMilliseconds()
            }
        } else { $null }
        Usage      = $workerAccount.Usage
        RateError  = $workerAccount.RateError
        UsageError = $workerAccount.UsageError
    } | ConvertTo-Json -Compress -Depth 8
    exit 0
}

if ($ResetCreditsWorker) {
    try {
        $resetCredits = Read-ResetCreditsFromOfficialService
        [pscustomobject]@{
            AvailableCount = [int]$resetCredits.AvailableCount
            Credits        = @($resetCredits.Credits | ForEach-Object {
                [pscustomobject]@{
                    ExpiresEpoch = ([DateTimeOffset]$_.ExpiresAt).ToUnixTimeSeconds()
                }
            })
            ObservedEpoch  = ([DateTimeOffset]$resetCredits.ObservedAt).ToUnixTimeMilliseconds()
        } | ConvertTo-Json -Compress -Depth 5
        exit 0
    } catch {
        [Console]::Error.WriteLine('RESET_CREDITS_QUERY_FAILED')
        exit 1
    }
}

if ($HeadlessProbe) {
    try {
        try {
            $probeSnapshot = Read-RateLimitFromAppServer
        } catch {
            Write-Diagnostic ('Direct read unavailable: ' + $_.Exception.Message)
            $probeSnapshot = Read-RateLimitFromSessionEvents
        }

        if (-not $probeSnapshot) {
            throw '未找到可用额度快照。'
        }
        $probeSnapshot | ConvertTo-Json -Depth 6
        exit 0
    } finally {
        if ($mutex) {
            try { $mutex.ReleaseMutex() } catch {}
            $mutex.Dispose()
        }
    }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Codex Quota Orb"
        Width="88" Height="88"
        WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="True" Topmost="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="Grayscale"
        TextOptions.TextHintingMode="Fixed"
        FontFamily="SF Pro Text, PingFang SC, Microsoft YaHei UI, Segoe UI"
        FontWeight="Medium">
    <Window.Resources>
        <FontFamily x:Key="InterfaceTextFont">SF Pro Text, PingFang SC, Microsoft YaHei UI, Segoe UI</FontFamily>
        <FontFamily x:Key="InterfaceDisplayFont">SF Pro Display, SF Pro Text, PingFang SC, Microsoft YaHei UI, Segoe UI</FontFamily>
        <LinearGradientBrush x:Key="GlassEdgeBrush" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#A6FFFFFF" Offset="0"/>
            <GradientStop Color="#48DDF5FF" Offset="0.18"/>
            <GradientStop Color="#10FFFFFF" Offset="0.43"/>
            <GradientStop Color="#16000000" Offset="0.7"/>
            <GradientStop Color="#73C9EDFF" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="GlassInnerEdgeBrush" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#4DFFFFFF" Offset="0"/>
            <GradientStop Color="#0CFFFFFF" Offset="0.3"/>
            <GradientStop Color="#28000000" Offset="0.68"/>
            <GradientStop Color="#42B9E6F7" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="GlassSpecularBrush" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#34FFFFFF" Offset="0"/>
            <GradientStop Color="#16D9F4FF" Offset="0.16"/>
            <GradientStop Color="#02FFFFFF" Offset="0.42"/>
            <GradientStop Color="#00000000" Offset="0.62"/>
            <GradientStop Color="#1E356D8A" Offset="0.82"/>
            <GradientStop Color="#2CAFE5F8" Offset="1"/>
        </LinearGradientBrush>
        <DrawingBrush x:Key="GlassTexture" TileMode="Tile" Viewport="0,0,42,42" ViewportUnits="Absolute" Stretch="None">
            <DrawingBrush.Drawing>
                <DrawingGroup>
                    <GeometryDrawing Brush="#20FFFFFF">
                        <GeometryDrawing.Geometry><EllipseGeometry Center="7,9" RadiusX="0.7" RadiusY="0.7"/></GeometryDrawing.Geometry>
                    </GeometryDrawing>
                    <GeometryDrawing Brush="#14000000">
                        <GeometryDrawing.Geometry><EllipseGeometry Center="24,6" RadiusX="0.55" RadiusY="0.55"/></GeometryDrawing.Geometry>
                    </GeometryDrawing>
                    <GeometryDrawing Brush="#18FFFFFF">
                        <GeometryDrawing.Geometry><EllipseGeometry Center="34,23" RadiusX="0.65" RadiusY="0.65"/></GeometryDrawing.Geometry>
                    </GeometryDrawing>
                    <GeometryDrawing Brush="#12000000">
                        <GeometryDrawing.Geometry><EllipseGeometry Center="15,31" RadiusX="0.6" RadiusY="0.6"/></GeometryDrawing.Geometry>
                    </GeometryDrawing>
                </DrawingGroup>
            </DrawingBrush.Drawing>
        </DrawingBrush>
        <Style x:Key="WindowButton" TargetType="Button">
            <Setter Property="Width" Value="27"/>
            <Setter Property="Height" Value="27"/>
            <Setter Property="Margin" Value="3,0,0,0"/>
            <Setter Property="Foreground" Value="#AEAEB2"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontFamily" Value="Segoe UI Symbol"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonSurface" Background="{TemplateBinding Background}" CornerRadius="13.5">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonSurface" Property="Background" Value="#18FFFFFF"/>
                                <Setter Property="Foreground" Value="#F5F5F7"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonSurface" Property="Background" Value="#28FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ActionButton" TargetType="Button">
            <Setter Property="Height" Value="34"/>
            <Setter Property="Foreground" Value="#F0FFFFFF"/>
            <Setter Property="Background" Value="#2E79BFF4"/>
            <Setter Property="BorderBrush" Value="#66DDF5FF"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontFamily" Value="{StaticResource InterfaceTextFont}"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border x:Name="ActionSurface" Background="{TemplateBinding Background}" CornerRadius="17">
                                <Border.Effect>
                                    <DropShadowEffect Color="#000000" BlurRadius="11" ShadowDepth="3" Opacity="0.18"/>
                                </Border.Effect>
                            </Border>
                            <Border CornerRadius="17" BorderThickness="1" IsHitTestVisible="False">
                                <Border.BorderBrush>
                                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                        <GradientStop Color="#73FFFFFF" Offset="0"/>
                                        <GradientStop Color="#18FFFFFF" Offset="0.44"/>
                                        <GradientStop Color="#4DFFFFFF" Offset="1"/>
                                    </LinearGradientBrush>
                                </Border.BorderBrush>
                            </Border>
                            <Border Margin="3" CornerRadius="14" BorderThickness="1" BorderBrush="#26000000" IsHitTestVisible="False"/>
                            <Border Margin="2" CornerRadius="15" IsHitTestVisible="False">
                                <Border.Background>
                                    <RadialGradientBrush Center="0.22,0.02" GradientOrigin="0.14,0" RadiusX="0.9" RadiusY="0.92">
                                        <GradientStop Color="#2EFFFFFF" Offset="0"/>
                                        <GradientStop Color="#09D9F4FF" Offset="0.38"/>
                                        <GradientStop Color="#00000000" Offset="0.72"/>
                                    </RadialGradientBrush>
                                </Border.Background>
                            </Border>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ActionSurface" Property="Background" Value="#467ECDF7"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ActionSurface" Property="Background" Value="#5A73BEEB"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="TabButton" TargetType="Button" BasedOn="{StaticResource ActionButton}">
            <Setter Property="Height" Value="29"/>
            <Setter Property="Margin" Value="0,0,6,0"/>
            <Setter Property="Background" Value="#18FFFFFF"/>
            <Setter Property="BorderBrush" Value="#3CFFFFFF"/>
            <Setter Property="Foreground" Value="#BFFFFFFF"/>
            <Setter Property="FontSize" Value="10"/>
        </Style>
        <Style x:Key="AnalyticsProgress" TargetType="ProgressBar">
            <Setter Property="Height" Value="7"/>
            <Setter Property="Minimum" Value="0"/>
            <Setter Property="Maximum" Value="100"/>
            <Setter Property="Background" Value="#55343438"/>
            <Setter Property="Foreground" Value="#0A84FF"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Grid>
                            <Border Background="{TemplateBinding Background}" CornerRadius="3.5"/>
                            <Border x:Name="PART_Indicator" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}" CornerRadius="3.5"/>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="SlimProgress" TargetType="ProgressBar">
            <Setter Property="Height" Value="12"/>
            <Setter Property="Background" Value="#55343438"/>
            <Setter Property="Foreground" Value="#0A84FF"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Grid>
                            <Border Background="{TemplateBinding Background}" CornerRadius="6"/>
                            <Border x:Name="PART_Indicator" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}" CornerRadius="6">
                                <Border.Effect>
                                    <DropShadowEffect Color="#0A84FF" BlurRadius="9" ShadowDepth="0" Opacity="0.35"/>
                                </Border.Effect>
                            </Border>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid x:Name="OrbView" Width="88" Height="88" HorizontalAlignment="Center" VerticalAlignment="Center">
            <Ellipse x:Name="OrbRippleOuter" Width="76" Height="76" Stroke="Transparent" Opacity="0.34"/>
            <Grid x:Name="OrbSurface" Width="76" Height="76" Cursor="Hand" ToolTip="点击展开额度详情">
                <Grid.Effect>
                    <DropShadowEffect Color="#465DA8" BlurRadius="15" ShadowDepth="3" Opacity="0.34"/>
                </Grid.Effect>

                <Ellipse>
                    <Ellipse.Fill>
                        <RadialGradientBrush Center="0.38,0.3" GradientOrigin="0.27,0.18" RadiusX="0.78" RadiusY="0.78">
                            <GradientStop Color="#96F8FCFF" Offset="0"/>
                            <GradientStop Color="#72DCE8F2" Offset="0.46"/>
                            <GradientStop Color="#6A9CB2C9" Offset="0.76"/>
                            <GradientStop Color="#866C83A4" Offset="1"/>
                        </RadialGradientBrush>
                    </Ellipse.Fill>
                </Ellipse>

                <Canvas x:Name="OrbWaterCanvas" Width="100" Height="100" HorizontalAlignment="Center" VerticalAlignment="Center" IsHitTestVisible="False">
                    <Canvas.LayoutTransform>
                        <ScaleTransform ScaleX="0.76" ScaleY="0.76"/>
                    </Canvas.LayoutTransform>
                    <Canvas.Clip>
                        <EllipseGeometry Center="50,50" RadiusX="49.5" RadiusY="49.5"/>
                    </Canvas.Clip>
                    <Canvas.OpacityMask>
                        <RadialGradientBrush Center="0.5,0.46" GradientOrigin="0.42,0.34" RadiusX="0.56" RadiusY="0.56">
                            <GradientStop Color="#FFFFFFFF" Offset="0"/>
                            <GradientStop Color="#F2FFFFFF" Offset="0.72"/>
                            <GradientStop Color="#9AFFFFFF" Offset="0.9"/>
                            <GradientStop Color="#28FFFFFF" Offset="1"/>
                        </RadialGradientBrush>
                    </Canvas.OpacityMask>
                    <Rectangle Width="100" Height="100">
                        <Rectangle.Fill>
                            <RadialGradientBrush Center="0.42,0.3" GradientOrigin="0.31,0.18" RadiusX="0.72" RadiusY="0.72">
                                <GradientStop Color="#52FFFFFF" Offset="0"/>
                                <GradientStop Color="#36DDEAF3" Offset="0.55"/>
                                <GradientStop Color="#287493AD" Offset="1"/>
                            </RadialGradientBrush>
                        </Rectangle.Fill>
                    </Rectangle>
                    <Rectangle x:Name="OrbWaterFill" Width="100" Height="56" Canvas.Top="44">
                        <Rectangle.Fill>
                            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                                <GradientStop Color="#A06EB2CF" Offset="0"/>
                                <GradientStop Color="#C33876AB" Offset="0.34"/>
                                <GradientStop Color="#DF14356A" Offset="0.72"/>
                                <GradientStop Color="#E90A2048" Offset="1"/>
                            </LinearGradientBrush>
                        </Rectangle.Fill>
                    </Rectangle>
                    <Rectangle x:Name="OrbWaterGloss" Width="100" Height="56" Canvas.Top="44">
                        <Rectangle.Fill>
                            <RadialGradientBrush Center="0.28,0.08" GradientOrigin="0.24,0.02" RadiusX="0.72" RadiusY="0.62">
                                <GradientStop Color="#70E4F6F7" Offset="0"/>
                                <GradientStop Color="#405B9DB8" Offset="0.3"/>
                                <GradientStop Color="#2450528F" Offset="0.62"/>
                                <GradientStop Color="#00001935" Offset="1"/>
                            </RadialGradientBrush>
                        </Rectangle.Fill>
                    </Rectangle>
                    <Rectangle x:Name="OrbWaterSheen" Width="100" Height="56" Canvas.Top="44" Opacity="0.72">
                        <Rectangle.Fill>
                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                <GradientStop Color="#38E1F2F5" Offset="0"/>
                                <GradientStop Color="#1C4962A0" Offset="0.46"/>
                                <GradientStop Color="#48291148" Offset="1"/>
                            </LinearGradientBrush>
                        </Rectangle.Fill>
                    </Rectangle>
                    <Path x:Name="OrbWaveBack" Canvas.Top="34" Stroke="#70A8CEDA" StrokeThickness="1.2" Opacity="0.76"
                          Data="M -90,12 C -70,1 -50,1 -30,12 C -10,23 10,23 30,12 C 50,1 70,1 90,12 C 110,23 130,23 150,12 C 170,1 190,1 210,12 C 230,23 250,23 270,12 L 270,116 L -90,116 Z">
                        <Path.Fill>
                            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                                <GradientStop Color="#5E4C91AD" Offset="0"/>
                                <GradientStop Color="#4819537C" Offset="0.36"/>
                                <GradientStop Color="#240A2037" Offset="1"/>
                            </LinearGradientBrush>
                        </Path.Fill>
                    </Path>
                    <Path Canvas.Top="40" Fill="Transparent" Stroke="#76020A13" StrokeThickness="3.1" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Opacity="0.48"
                          Data="M -90,10 C -70,20 -50,20 -30,10 C -10,0 10,0 30,10 C 50,20 70,20 90,10 C 110,0 130,0 150,10 C 170,20 190,20 210,10 C 230,0 250,0 270,10"/>
                    <Path x:Name="OrbWaveFront" Canvas.Top="38" Stroke="#9CCAE3EC" StrokeThickness="1.45" Opacity="0.86"
                          Data="M -90,10 C -70,20 -50,20 -30,10 C -10,0 10,0 30,10 C 50,20 70,20 90,10 C 110,0 130,0 150,10 C 170,20 190,20 210,10 C 230,0 250,0 270,10 L 270,116 L -90,116 Z">
                        <Path.Fill>
                            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                                <GradientStop Color="#70509BB8" Offset="0"/>
                                <GradientStop Color="#6A1D5C86" Offset="0.34"/>
                                <GradientStop Color="#360B2645" Offset="1"/>
                            </LinearGradientBrush>
                        </Path.Fill>
                    </Path>
                    <Path x:Name="OrbWaveGlint" Canvas.Top="38" Fill="Transparent" Stroke="#B8E3F3F7" StrokeThickness="1.45" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Opacity="0.8"
                          Data="M -90,10 C -70,20 -50,20 -30,10 C -10,0 10,0 30,10 C 50,20 70,20 90,10 C 110,0 130,0 150,10 C 170,20 190,20 210,10 C 230,0 250,0 270,10"/>
                    <Ellipse Width="5" Height="5" Canvas.Left="24" Canvas.Top="72" Fill="#58D7EDF2"/>
                    <Ellipse Width="3" Height="3" Canvas.Left="71" Canvas.Top="61" Fill="#70D7EDF2"/>
                    <Ellipse Width="7" Height="7" Canvas.Left="62" Canvas.Top="82" Fill="#34B8D5DF"/>
                </Canvas>

                <Ellipse IsHitTestVisible="False">
                    <Ellipse.Fill>
                        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                            <GradientStop Color="#42FFFFFF" Offset="0"/>
                            <GradientStop Color="#12FFFFFF" Offset="0.36"/>
                            <GradientStop Color="#0C3D79A1" Offset="0.64"/>
                            <GradientStop Color="#24263C64" Offset="1"/>
                        </LinearGradientBrush>
                    </Ellipse.Fill>
                </Ellipse>
                <Ellipse IsHitTestVisible="False">
                    <Ellipse.Fill>
                        <RadialGradientBrush Center="0.43,0.38" GradientOrigin="0.34,0.27" RadiusX="0.66" RadiusY="0.66">
                            <GradientStop Color="#00000000" Offset="0.46"/>
                            <GradientStop Color="#10395D83" Offset="0.7"/>
                            <GradientStop Color="#3E5B70A0" Offset="1"/>
                        </RadialGradientBrush>
                    </Ellipse.Fill>
                </Ellipse>
                <Ellipse Width="70" Height="70" IsHitTestVisible="False" Opacity="0.82">
                    <Ellipse.Fill>
                        <LinearGradientBrush StartPoint="0.06,0.92" EndPoint="0.94,0.08">
                            <GradientStop Color="#365CCBFF" Offset="0"/>
                            <GradientStop Color="#1E7A6CFF" Offset="0.22"/>
                            <GradientStop Color="#0AF7B2DC" Offset="0.48"/>
                            <GradientStop Color="#18FFFFFF" Offset="0.68"/>
                            <GradientStop Color="#38A7EFFF" Offset="1"/>
                        </LinearGradientBrush>
                    </Ellipse.Fill>
                    <Ellipse.OpacityMask>
                        <RadialGradientBrush Center="0.5,0.5" RadiusX="0.55" RadiusY="0.55">
                            <GradientStop Color="#00000000" Offset="0.64"/>
                            <GradientStop Color="#70FFFFFF" Offset="0.86"/>
                            <GradientStop Color="#FFFFFFFF" Offset="1"/>
                        </RadialGradientBrush>
                    </Ellipse.OpacityMask>
                </Ellipse>
                <Ellipse Width="74" Height="74" StrokeThickness="1.1" IsHitTestVisible="False">
                    <Ellipse.Stroke>
                        <LinearGradientBrush StartPoint="0,1" EndPoint="1,0">
                            <GradientStop Color="#A9CCF7FF" Offset="0"/>
                            <GradientStop Color="#628178F8" Offset="0.28"/>
                            <GradientStop Color="#5EF5B5E4" Offset="0.54"/>
                            <GradientStop Color="#D4FFFFFF" Offset="0.78"/>
                            <GradientStop Color="#A6B8F4FF" Offset="1"/>
                        </LinearGradientBrush>
                    </Ellipse.Stroke>
                </Ellipse>
                <Path Data="M 16,25 C 22,16 34,12 45,14" Stroke="#88FFFFFF" StrokeThickness="1.35" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Fill="Transparent" IsHitTestVisible="False"/>
                <Path Data="M 8,48 C 5,37 8,24 16,15" Stroke="#7895D8FF" StrokeThickness="1.25" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Fill="Transparent" IsHitTestVisible="False"/>
                <Ellipse Width="58" Height="30" VerticalAlignment="Bottom" Margin="0,0,0,4" Opacity="0.64" IsHitTestVisible="False">
                    <Ellipse.Fill>
                        <RadialGradientBrush Center="0.5,0.82" GradientOrigin="0.5,0.82" RadiusX="0.58" RadiusY="0.7">
                            <GradientStop Color="#78FFFFFF" Offset="0"/>
                            <GradientStop Color="#466F91B5" Offset="0.38"/>
                            <GradientStop Color="#28614AB0" Offset="0.72"/>
                            <GradientStop Color="#00001838" Offset="1"/>
                        </RadialGradientBrush>
                    </Ellipse.Fill>
                </Ellipse>
                <Ellipse Width="48" Height="22" VerticalAlignment="Top" Margin="0,5,0,0" Opacity="0.42" IsHitTestVisible="False">
                    <Ellipse.Fill>
                        <RadialGradientBrush Center="0.36,0.12" GradientOrigin="0.32,0.08" RadiusX="0.72" RadiusY="0.72">
                            <GradientStop Color="#54FFFFFF" Offset="0"/>
                            <GradientStop Color="#1C4C7EA8" Offset="0.45"/>
                            <GradientStop Color="#00000000" Offset="1"/>
                        </RadialGradientBrush>
                    </Ellipse.Fill>
                </Ellipse>
                <Ellipse Width="30" Height="27" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,8,7,0" Opacity="0.78" IsHitTestVisible="False">
                    <Ellipse.Fill>
                        <RadialGradientBrush Center="0.62,0.34" GradientOrigin="0.58,0.3" RadiusX="0.62" RadiusY="0.62">
                            <GradientStop Color="#C8FFFFFF" Offset="0"/>
                            <GradientStop Color="#52F3E9FF" Offset="0.34"/>
                            <GradientStop Color="#1685C9FF" Offset="0.66"/>
                            <GradientStop Color="#00000000" Offset="1"/>
                        </RadialGradientBrush>
                    </Ellipse.Fill>
                </Ellipse>
                <TextBlock x:Name="OrbPercentText" Text="--%" Foreground="#FF101923" FontFamily="{StaticResource InterfaceDisplayFont}" FontSize="18" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" IsHitTestVisible="False">
                    <TextBlock.Effect>
                        <DropShadowEffect Color="#FFFFFF" BlurRadius="3" ShadowDepth="0" Opacity="0.72"/>
                    </TextBlock.Effect>
                </TextBlock>
                <Grid x:Name="OrbPercentWaterLayer" Width="76" Height="76" IsHitTestVisible="False">
                    <Grid.Clip>
                        <PathGeometry FillRule="Nonzero" Figures="M -90,10 C -70,20 -50,20 -30,10 C -10,0 10,0 30,10 C 50,20 70,20 90,10 C 110,0 130,0 150,10 C 170,20 190,20 210,10 C 230,0 250,0 270,10 L 270,116 L -90,116 Z">
                            <PathGeometry.Transform>
                                <TransformGroup>
                                    <ScaleTransform ScaleX="0.76" ScaleY="0.76"/>
                                    <TranslateTransform x:Name="OrbPercentClipTranslate" X="0" Y="0"/>
                                </TransformGroup>
                            </PathGeometry.Transform>
                        </PathGeometry>
                    </Grid.Clip>
                    <TextBlock x:Name="OrbPercentWaterText" Text="--%" Foreground="#FFFFFFFF" FontFamily="{StaticResource InterfaceDisplayFont}" FontSize="18" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center">
                        <TextBlock.Effect>
                            <DropShadowEffect Color="#071529" BlurRadius="3" ShadowDepth="1" Opacity="0.9"/>
                        </TextBlock.Effect>
                    </TextBlock>
                </Grid>
                <Border x:Name="OrbHitTarget" Background="#01FFFFFF" CornerRadius="38"/>
            </Grid>
        </Grid>

        <Border x:Name="GlowBorder" Margin="12" Visibility="Collapsed" CornerRadius="32" BorderThickness="1" BorderBrush="{StaticResource GlassEdgeBrush}">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#AD121A24" Offset="0"/>
                    <GradientStop Color="#9F070C13" Offset="0.52"/>
                    <GradientStop Color="#A7102532" Offset="1"/>
                </LinearGradientBrush>
            </Border.Background>
            <Border.Effect>
                <DropShadowEffect Color="#020815" BlurRadius="28" ShadowDepth="7" Opacity="0.48"/>
            </Border.Effect>
            <Grid Margin="21,17,21,18">
                <Grid.RowDefinitions>
                    <RowDefinition Height="38"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="16"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <Border Grid.RowSpan="6" Margin="-8,-6,-8,-7" CornerRadius="24" IsHitTestVisible="False">
                    <Border.Background>
                        <RadialGradientBrush Center="0.18,0.06" GradientOrigin="0.12,0.02" RadiusX="0.88" RadiusY="0.78">
                            <GradientStop Color="#42FFFFFF" Offset="0"/>
                            <GradientStop Color="#183D9BC4" Offset="0.38"/>
                            <GradientStop Color="#00001536" Offset="1"/>
                        </RadialGradientBrush>
                    </Border.Background>
                </Border>
                <Border Grid.RowSpan="6" Margin="-8,-6,-8,-7" CornerRadius="24" Background="{StaticResource GlassSpecularBrush}" Opacity="0.9" IsHitTestVisible="False"/>
                <Border Grid.RowSpan="6" Margin="-8,-6,-8,-7" CornerRadius="24" IsHitTestVisible="False">
                    <Border.Background>
                        <RadialGradientBrush Center="0.76,1.06" GradientOrigin="0.82,1.1" RadiusX="0.82" RadiusY="0.48">
                            <GradientStop Color="#323C91B8" Offset="0"/>
                            <GradientStop Color="#16215470" Offset="0.38"/>
                            <GradientStop Color="#00000000" Offset="0.76"/>
                        </RadialGradientBrush>
                    </Border.Background>
                </Border>
                <Border Grid.RowSpan="6" Margin="-8,-6,-8,-7" CornerRadius="24" Background="{StaticResource GlassTexture}" Opacity="0.22" IsHitTestVisible="False"/>
                <Border Grid.RowSpan="6" Margin="-5,-3,-5,-4" CornerRadius="22" BorderThickness="1.15" BorderBrush="{StaticResource GlassInnerEdgeBrush}" IsHitTestVisible="False"/>
                <Border Grid.RowSpan="6" Margin="-2,0,-2,-1" CornerRadius="19" BorderThickness="1" BorderBrush="#36000000" IsHitTestVisible="False"/>

                <Grid Grid.Row="0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                        <Border x:Name="StatusHalo" Width="22" Height="22" CornerRadius="11" Background="#260A84FF" Margin="0,0,10,0">
                            <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#0A84FF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <StackPanel>
                            <TextBlock Text="C O D E X" Foreground="#BFFFFFFF" FontSize="9" FontWeight="Bold"/>
                            <TextBlock Text="Weekly capacity" Foreground="#F5FFFFFF" FontSize="15" FontWeight="Bold" Margin="0,-1,0,0"/>
                        </StackPanel>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button x:Name="RefreshButton" Style="{StaticResource WindowButton}" Content="↻" ToolTip="刷新额度"/>
                        <Button x:Name="HideButton" Style="{StaticResource WindowButton}" Content="—" ToolTip="收拢为水球"/>
                        <Button x:Name="CloseButton" Style="{StaticResource WindowButton}" Content="×" ToolTip="退出"/>
                    </StackPanel>
                </Grid>

                <Grid Grid.Row="1" Margin="0,9,0,8" Height="78">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Grid Grid.Column="0" VerticalAlignment="Center">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="18"/>
                            <RowDefinition Height="60"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Text="R E M A I N I N G" Foreground="#BFFFFFFF" FontSize="9" FontWeight="Bold" VerticalAlignment="Top"/>
                        <TextBlock x:Name="PercentText" Grid.Row="1" Text="--%" Foreground="#FFFFFFFF" FontFamily="{StaticResource InterfaceDisplayFont}" FontSize="48" FontWeight="Bold" VerticalAlignment="Center"/>
                    </Grid>
                    <StackPanel Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Border x:Name="SourceBadge" Background="#242A4E76" CornerRadius="10" Padding="10,5">
                            <TextBlock x:Name="SourceText" Text="CONNECTING" Foreground="#64AFFF" FontSize="9" FontWeight="Bold"/>
                        </Border>
                        <TextBlock x:Name="UsedText" Text="正在读取额度" Foreground="#E8FFFFFF" FontSize="11" FontWeight="SemiBold" HorizontalAlignment="Right" Margin="0,6,2,0"/>
                    </StackPanel>
                </Grid>

                <Grid x:Name="ProgressTrack" Grid.Row="2" Height="12">
                    <Border Background="#55343438" CornerRadius="6"/>
                    <Border x:Name="CapacityFill" HorizontalAlignment="Left" Width="0" Background="#0A84FF" CornerRadius="6">
                        <Border.Effect>
                            <DropShadowEffect Color="#0A84FF" BlurRadius="9" ShadowDepth="0" Opacity="0.35"/>
                        </Border.Effect>
                    </Border>
                </Grid>

                <Grid Grid.Row="3" Margin="0,13,0,0">
                    <StackPanel>
                        <TextBlock Text="R E S E T" Foreground="#8FFFFFFF" FontSize="8" FontWeight="Bold"/>
                        <TextBlock x:Name="ResetText" Text="等待快照" Foreground="#FFFFFFFF" FontSize="12" FontWeight="SemiBold" Margin="0,3,0,0"/>
                    </StackPanel>
                    <StackPanel HorizontalAlignment="Right">
                        <TextBlock Text="U P D A T E D" Foreground="#8FFFFFFF" FontSize="8" FontWeight="Bold" HorizontalAlignment="Right"/>
                        <TextBlock x:Name="UpdatedText" Text="--:--" Foreground="#F0FFFFFF" FontSize="12" FontWeight="SemiBold" Margin="0,3,0,0" HorizontalAlignment="Right"/>
                    </StackPanel>
                </Grid>

                <Button x:Name="AnalyticsButton" Grid.Row="4" Content="查看用量分析  ›" Style="{StaticResource ActionButton}" Margin="0,12,0,0"/>
                <Button x:Name="ResetCreditsButton" Grid.Row="5" Content="查看重置卡  ›" Style="{StaticResource ActionButton}" Margin="0,8,0,0"/>
            </Grid>
        </Border>

        <Border x:Name="AnalyticsBorder" Margin="12" Visibility="Collapsed" CornerRadius="32" BorderThickness="1" BorderBrush="{StaticResource GlassEdgeBrush}">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#AD121A24" Offset="0"/>
                    <GradientStop Color="#9F070C13" Offset="0.52"/>
                    <GradientStop Color="#A7102532" Offset="1"/>
                </LinearGradientBrush>
            </Border.Background>
            <Border.Effect>
                <DropShadowEffect Color="#020815" BlurRadius="28" ShadowDepth="7" Opacity="0.48"/>
            </Border.Effect>
            <Grid Margin="21,17,21,17">
                <Grid.RowDefinitions>
                    <RowDefinition Height="38"/>
                    <RowDefinition Height="64"/>
                    <RowDefinition Height="38"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="22"/>
                </Grid.RowDefinitions>

                <Border Grid.RowSpan="5" Margin="-8,-6,-8,-6" CornerRadius="24" IsHitTestVisible="False">
                    <Border.Background>
                        <RadialGradientBrush Center="0.18,0.05" GradientOrigin="0.12,0.02" RadiusX="0.92" RadiusY="0.8">
                            <GradientStop Color="#42FFFFFF" Offset="0"/>
                            <GradientStop Color="#183D9BC4" Offset="0.38"/>
                            <GradientStop Color="#00001536" Offset="1"/>
                        </RadialGradientBrush>
                    </Border.Background>
                </Border>
                <Border Grid.RowSpan="5" Margin="-8,-6,-8,-6" CornerRadius="24" Background="{StaticResource GlassSpecularBrush}" Opacity="0.9" IsHitTestVisible="False"/>
                <Border Grid.RowSpan="5" Margin="-8,-6,-8,-6" CornerRadius="24" IsHitTestVisible="False">
                    <Border.Background>
                        <RadialGradientBrush Center="0.76,1.05" GradientOrigin="0.82,1.08" RadiusX="0.84" RadiusY="0.46">
                            <GradientStop Color="#323C91B8" Offset="0"/>
                            <GradientStop Color="#16215470" Offset="0.38"/>
                            <GradientStop Color="#00000000" Offset="0.76"/>
                        </RadialGradientBrush>
                    </Border.Background>
                </Border>
                <Border Grid.RowSpan="5" Margin="-8,-6,-8,-6" CornerRadius="24" Background="{StaticResource GlassTexture}" Opacity="0.22" IsHitTestVisible="False"/>
                <Border Grid.RowSpan="5" Margin="-5,-3,-5,-3" CornerRadius="22" BorderThickness="1.15" BorderBrush="{StaticResource GlassInnerEdgeBrush}" IsHitTestVisible="False"/>
                <Border Grid.RowSpan="5" Margin="-2,0,-2,0" CornerRadius="19" BorderThickness="1" BorderBrush="#36000000" IsHitTestVisible="False"/>

                <Grid Grid.Row="0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Button x:Name="BackButton" Grid.Column="0" Style="{StaticResource WindowButton}" Content="‹" ToolTip="返回额度页" Margin="0,0,8,0"/>
                    <StackPanel Grid.Column="1" VerticalAlignment="Center">
                        <TextBlock Text="C O D E X" Foreground="#BFFFFFFF" FontSize="9" FontWeight="Bold"/>
                        <TextBlock Text="Usage analytics" Foreground="#F5FFFFFF" FontSize="15" FontWeight="Bold" Margin="0,-1,0,0"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button x:Name="AnalyticsRefreshButton" Style="{StaticResource WindowButton}" Content="↻" ToolTip="刷新统计"/>
                        <Button x:Name="AnalyticsHideButton" Style="{StaticResource WindowButton}" Content="—" ToolTip="收拢为水球"/>
                        <Button x:Name="AnalyticsCloseButton" Style="{StaticResource WindowButton}" Content="×" ToolTip="退出"/>
                    </StackPanel>
                </Grid>

                <Grid Grid.Row="1" Margin="0,8,0,4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0">
                        <TextBlock Text="7  D A Y  T O T A L" Foreground="#8FFFFFFF" FontSize="8" FontWeight="Bold"/>
                        <TextBlock x:Name="SevenDayTotalText" Text="--" Foreground="#FFFFFFFF" FontSize="29" FontWeight="Bold" Margin="0,1,0,0"/>
                    </StackPanel>
                    <StackPanel Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Border Background="#242A4E76" CornerRadius="10" Padding="10,5">
                            <TextBlock x:Name="AnalyticsSourceText" Text="LOCAL EVENTS" Foreground="#64AFFF" FontSize="9" FontWeight="Bold"/>
                        </Border>
                        <TextBlock x:Name="OfficialRateText" Text="官方额度 --" Foreground="#BFFFFFFF" FontSize="10" HorizontalAlignment="Right" Margin="0,5,2,0"/>
                    </StackPanel>
                </Grid>

                <UniformGrid Grid.Row="2" Columns="3" Margin="0,4,0,5">
                    <Button x:Name="DailyTabButton" Content="7 日" Style="{StaticResource TabButton}"/>
                    <Button x:Name="SkillTabButton" Content="Skill" Style="{StaticResource TabButton}"/>
                    <Button x:Name="AgentTabButton" Content="Agent" Style="{StaticResource TabButton}" Margin="0"/>
                </UniformGrid>

                <Grid Grid.Row="3">
                    <Grid x:Name="DailyPanel">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Grid Grid.Row="0" Margin="1,4,1,7">
                            <TextBlock Text="每日 TOKEN · 七日占比" Foreground="#D0FFFFFF" FontSize="10" FontWeight="Bold"/>
                            <TextBlock x:Name="DailySourceText" Text="等待统计" Foreground="#8FFFFFFF" FontSize="9" HorizontalAlignment="Right"/>
                        </Grid>
                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                            <StackPanel x:Name="DailyRowsPanel"/>
                        </ScrollViewer>
                        <TextBlock x:Name="RateHistoryText" Grid.Row="2" Text="官方额度日拆分正在积累快照" Foreground="#8FFFFFFF" FontSize="9" Margin="1,7,0,0" TextWrapping="Wrap"/>
                    </Grid>

                    <Grid x:Name="SkillPanel" Visibility="Collapsed">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Grid Grid.Row="0" Margin="1,4,1,7">
                            <TextBlock x:Name="SkillSectionTitle" Text="SKILL · 主归因 TOKEN" Foreground="#D0FFFFFF" FontSize="10" FontWeight="Bold"/>
                            <TextBlock x:Name="SkillCoverageText" Text="覆盖率 --" Foreground="#64AFFF" FontSize="9" FontWeight="Bold" HorizontalAlignment="Right"/>
                        </Grid>
                        <UniformGrid Grid.Row="1" Columns="2" Margin="0,0,0,6">
                            <Button x:Name="SkillPrimaryButton" Content="12 Skill" Style="{StaticResource TabButton}"/>
                            <Button x:Name="SkillChainButton" Content="路由链" Style="{StaticResource TabButton}" Margin="0"/>
                        </UniformGrid>
                        <Grid Grid.Row="2">
                            <ScrollViewer x:Name="SkillPrimaryScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                <StackPanel x:Name="SkillRowsPanel"/>
                            </ScrollViewer>
                            <ScrollViewer x:Name="SkillChainScroll" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                <StackPanel x:Name="SkillChainRowsPanel"/>
                            </ScrollViewer>
                        </Grid>
                        <TextBlock x:Name="SkillHintText" Grid.Row="3" Text="主归因只计最终 Skill；关联 Token 不可相加。" Foreground="#8FFFFFFF" FontSize="9" Margin="1,7,0,0" TextWrapping="Wrap"/>
                    </Grid>

                    <Grid x:Name="AgentPanel" Visibility="Collapsed">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Grid Grid.Row="0" Margin="1,4,1,7">
                            <TextBlock Text="AGENT · THREAD 归因" Foreground="#D0FFFFFF" FontSize="10" FontWeight="Bold"/>
                            <TextBlock Text="包含主 Agent" Foreground="#64AFFF" FontSize="9" FontWeight="Bold" HorizontalAlignment="Right"/>
                        </Grid>
                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                            <StackPanel x:Name="AgentRowsPanel"/>
                        </ScrollViewer>
                        <TextBlock Grid.Row="2" Text="按线程角色汇总本机捕获到的 Token；不与账户级总量混用分母。" Foreground="#8FFFFFFF" FontSize="9" Margin="1,7,0,0" TextWrapping="Wrap"/>
                    </Grid>
                </Grid>

                <TextBlock x:Name="AnalyticsStatusText" Grid.Row="4" Text="准备本地统计…" Foreground="#9FFFFFFF" FontSize="9" VerticalAlignment="Bottom" TextTrimming="CharacterEllipsis"/>
            </Grid>
        </Border>

        <Border x:Name="ResetCreditsBorder" Margin="12" Visibility="Collapsed" CornerRadius="32" BorderThickness="1" BorderBrush="{StaticResource GlassEdgeBrush}">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#AD121A24" Offset="0"/>
                    <GradientStop Color="#9F070C13" Offset="0.52"/>
                    <GradientStop Color="#A7102532" Offset="1"/>
                </LinearGradientBrush>
            </Border.Background>
            <Border.Effect>
                <DropShadowEffect Color="#020815" BlurRadius="28" ShadowDepth="7" Opacity="0.48"/>
            </Border.Effect>
            <Grid Margin="21,17,21,17">
                <Grid.RowDefinitions>
                    <RowDefinition Height="38"/>
                    <RowDefinition Height="76"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <Border Grid.RowSpan="3" Margin="-8,-6,-8,-6" CornerRadius="24" IsHitTestVisible="False">
                    <Border.Background>
                        <RadialGradientBrush Center="0.18,0.05" GradientOrigin="0.12,0.02" RadiusX="0.92" RadiusY="0.8">
                            <GradientStop Color="#42FFFFFF" Offset="0"/>
                            <GradientStop Color="#183D9BC4" Offset="0.38"/>
                            <GradientStop Color="#00001536" Offset="1"/>
                        </RadialGradientBrush>
                    </Border.Background>
                </Border>
                <Border Grid.RowSpan="3" Margin="-8,-6,-8,-6" CornerRadius="24" Background="{StaticResource GlassSpecularBrush}" Opacity="0.9" IsHitTestVisible="False"/>
                <Border Grid.RowSpan="3" Margin="-8,-6,-8,-6" CornerRadius="24" IsHitTestVisible="False">
                    <Border.Background>
                        <RadialGradientBrush Center="0.76,1.05" GradientOrigin="0.82,1.08" RadiusX="0.84" RadiusY="0.46">
                            <GradientStop Color="#323C91B8" Offset="0"/>
                            <GradientStop Color="#16215470" Offset="0.38"/>
                            <GradientStop Color="#00000000" Offset="0.76"/>
                        </RadialGradientBrush>
                    </Border.Background>
                </Border>
                <Border Grid.RowSpan="3" Margin="-8,-6,-8,-6" CornerRadius="24" Background="{StaticResource GlassTexture}" Opacity="0.22" IsHitTestVisible="False"/>
                <Border Grid.RowSpan="3" Margin="-5,-3,-5,-3" CornerRadius="22" BorderThickness="1.15" BorderBrush="{StaticResource GlassInnerEdgeBrush}" IsHitTestVisible="False"/>
                <Border Grid.RowSpan="3" Margin="-2,0,-2,0" CornerRadius="19" BorderThickness="1" BorderBrush="#36000000" IsHitTestVisible="False"/>

                <Grid Grid.Row="0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Button x:Name="ResetCreditsBackButton" Grid.Column="0" Style="{StaticResource WindowButton}" Content="‹" ToolTip="返回额度页" Margin="0,0,8,0"/>
                    <StackPanel Grid.Column="1" VerticalAlignment="Center">
                        <TextBlock Text="C O D E X" Foreground="#BFFFFFFF" FontSize="9" FontWeight="Bold"/>
                        <TextBlock Text="Reset credits" Foreground="#F5FFFFFF" FontSize="15" FontWeight="Bold" Margin="0,-1,0,0"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button x:Name="ResetCreditsRefreshButton" Style="{StaticResource WindowButton}" Content="↻" ToolTip="重新查询重置卡"/>
                        <Button x:Name="ResetCreditsHideButton" Style="{StaticResource WindowButton}" Content="—" ToolTip="收拢为水球"/>
                        <Button x:Name="ResetCreditsCloseButton" Style="{StaticResource WindowButton}" Content="×" ToolTip="退出"/>
                    </StackPanel>
                </Grid>

                <Border Grid.Row="1" Margin="0,9,0,4" Padding="14,9" CornerRadius="17" Background="#24FFFFFF" BorderBrush="#38FFFFFF" BorderThickness="1">
                    <Grid>
                        <StackPanel VerticalAlignment="Center">
                            <TextBlock Text="A V A I L A B L E" Foreground="#8FFFFFFF" FontSize="8" FontWeight="Bold"/>
                            <TextBlock x:Name="ResetCreditsCountText" Text="查询中…" Foreground="#FFFFFFFF" FontSize="25" FontWeight="Bold" Margin="0,1,0,0"/>
                        </StackPanel>
                        <Border HorizontalAlignment="Right" VerticalAlignment="Center" Background="#2430D158" CornerRadius="10" Padding="10,5">
                            <TextBlock Text="只读查询" Foreground="#7EE39A" FontSize="9" FontWeight="Bold"/>
                        </Border>
                    </Grid>
                </Border>

                <Grid Grid.Row="2" Margin="0,11,0,0">
                    <ScrollViewer x:Name="ResetCreditsScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel x:Name="ResetCreditsRowsPanel"/>
                    </ScrollViewer>
                    <StackPanel x:Name="ResetCreditsStatePanel" HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="260">
                        <TextBlock x:Name="ResetCreditsStateText" Text="正在查询重置卡…" Foreground="#BFFFFFFF" FontSize="11" FontWeight="SemiBold" TextAlignment="Center" TextWrapping="Wrap"/>
                        <Button x:Name="ResetCreditsRetryButton" Content="重新查询" Style="{StaticResource ActionButton}" Width="150" Margin="0,14,0,0" Visibility="Collapsed"/>
                    </StackPanel>
                </Grid>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

if ($QASolidWindow) {
    $xaml.Window.AllowsTransparency = 'False'
    $xaml.Window.Background = '#000000'
}

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$OrbView = $window.FindName('OrbView')
$OrbSurface = $window.FindName('OrbSurface')
$OrbHitTarget = $window.FindName('OrbHitTarget')
$OrbRippleOuter = $window.FindName('OrbRippleOuter')
$OrbWaterCanvas = $window.FindName('OrbWaterCanvas')
$OrbWaterFill = $window.FindName('OrbWaterFill')
$OrbWaterGloss = $window.FindName('OrbWaterGloss')
$OrbWaterSheen = $window.FindName('OrbWaterSheen')
$OrbWaveBack = $window.FindName('OrbWaveBack')
$OrbWaveFront = $window.FindName('OrbWaveFront')
$OrbWaveGlint = $window.FindName('OrbWaveGlint')
$OrbPercentText = $window.FindName('OrbPercentText')
$OrbPercentWaterText = $window.FindName('OrbPercentWaterText')
$OrbPercentClipTranslate = $window.FindName('OrbPercentClipTranslate')
$GlowBorder = $window.FindName('GlowBorder')
$StatusHalo = $window.FindName('StatusHalo')
$StatusDot = $window.FindName('StatusDot')
$PercentText = $window.FindName('PercentText')
$SourceBadge = $window.FindName('SourceBadge')
$SourceText = $window.FindName('SourceText')
$UsedText = $window.FindName('UsedText')
$ProgressTrack = $window.FindName('ProgressTrack')
$CapacityFill = $window.FindName('CapacityFill')
$ResetText = $window.FindName('ResetText')
$UpdatedText = $window.FindName('UpdatedText')
$AnalyticsButton = $window.FindName('AnalyticsButton')
$ResetCreditsButton = $window.FindName('ResetCreditsButton')
$RefreshButton = $window.FindName('RefreshButton')
$HideButton = $window.FindName('HideButton')
$CloseButton = $window.FindName('CloseButton')
$AnalyticsBorder = $window.FindName('AnalyticsBorder')
$BackButton = $window.FindName('BackButton')
$AnalyticsRefreshButton = $window.FindName('AnalyticsRefreshButton')
$AnalyticsHideButton = $window.FindName('AnalyticsHideButton')
$AnalyticsCloseButton = $window.FindName('AnalyticsCloseButton')
$SevenDayTotalText = $window.FindName('SevenDayTotalText')
$AnalyticsSourceText = $window.FindName('AnalyticsSourceText')
$OfficialRateText = $window.FindName('OfficialRateText')
$DailyTabButton = $window.FindName('DailyTabButton')
$SkillTabButton = $window.FindName('SkillTabButton')
$AgentTabButton = $window.FindName('AgentTabButton')
$DailyPanel = $window.FindName('DailyPanel')
$SkillPanel = $window.FindName('SkillPanel')
$AgentPanel = $window.FindName('AgentPanel')
$DailyRowsPanel = $window.FindName('DailyRowsPanel')
$SkillRowsPanel = $window.FindName('SkillRowsPanel')
$SkillChainRowsPanel = $window.FindName('SkillChainRowsPanel')
$AgentRowsPanel = $window.FindName('AgentRowsPanel')
$DailySourceText = $window.FindName('DailySourceText')
$RateHistoryText = $window.FindName('RateHistoryText')
$SkillCoverageText = $window.FindName('SkillCoverageText')
$SkillSectionTitle = $window.FindName('SkillSectionTitle')
$SkillPrimaryButton = $window.FindName('SkillPrimaryButton')
$SkillChainButton = $window.FindName('SkillChainButton')
$SkillPrimaryScroll = $window.FindName('SkillPrimaryScroll')
$SkillChainScroll = $window.FindName('SkillChainScroll')
$SkillHintText = $window.FindName('SkillHintText')
$AnalyticsStatusText = $window.FindName('AnalyticsStatusText')
$ResetCreditsBorder = $window.FindName('ResetCreditsBorder')
$ResetCreditsBackButton = $window.FindName('ResetCreditsBackButton')
$ResetCreditsRefreshButton = $window.FindName('ResetCreditsRefreshButton')
$ResetCreditsHideButton = $window.FindName('ResetCreditsHideButton')
$ResetCreditsCloseButton = $window.FindName('ResetCreditsCloseButton')
$ResetCreditsCountText = $window.FindName('ResetCreditsCountText')
$ResetCreditsScroll = $window.FindName('ResetCreditsScroll')
$ResetCreditsRowsPanel = $window.FindName('ResetCreditsRowsPanel')
$ResetCreditsStatePanel = $window.FindName('ResetCreditsStatePanel')
$ResetCreditsStateText = $window.FindName('ResetCreditsStateText')
$ResetCreditsRetryButton = $window.FindName('ResetCreditsRetryButton')

function New-Brush {
    param([string]$Color)
    return [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($Color))
}

function Update-Countdown {
    if (-not $script:CurrentSnapshot -or -not $script:CurrentSnapshot.ResetAt) {
        $ResetText.Text = '重置时间暂不可用'
        return
    }

    $reset = [DateTimeOffset]$script:CurrentSnapshot.ResetAt
    $remaining = $reset - [DateTimeOffset]::Now
    if ($remaining.TotalSeconds -le 0) {
        $ResetText.Text = '额度周期正在刷新'
        return
    }

    $parts = New-Object System.Collections.Generic.List[string]
    if ($remaining.Days -gt 0) { $parts.Add(('{0}天' -f $remaining.Days)) }
    if ($remaining.Hours -gt 0 -or $remaining.Days -gt 0) { $parts.Add(('{0}小时' -f $remaining.Hours)) }
    $parts.Add(('{0}分钟' -f $remaining.Minutes))
    $ResetText.Text = ('{0:MM月dd日 HH:mm} · {1}' -f $reset.LocalDateTime, ($parts -join ' '))
}

function Update-ProgressFill {
    if (-not $script:CurrentSnapshot -or $ProgressTrack.ActualWidth -le 0) {
        $CapacityFill.Width = 0
        return
    }

    $fillWidth = $ProgressTrack.ActualWidth * ([double]$script:CurrentSnapshot.Remaining / 100.0)
    if ($fillWidth -gt 0) {
        $fillWidth = [Math]::Max(12.0, $fillWidth)
    }
    $CapacityFill.Width = [Math]::Min($ProgressTrack.ActualWidth, $fillWidth)
}

function Update-OrbWaterLevel {
    param([double]$Remaining)

    $script:OrbWaterLevel = [Math]::Max(0.0, [Math]::Min(100.0, $Remaining))
    $waterLine = 96.0 - (0.92 * $script:OrbWaterLevel)
    $bodyTop = [Math]::Min(100.0, $waterLine + 5.0)
    [System.Windows.Controls.Canvas]::SetTop($OrbWaterFill, $bodyTop)
    $OrbWaterFill.Height = [Math]::Max(0.0, 104.0 - $bodyTop)
    [System.Windows.Controls.Canvas]::SetTop($OrbWaterGloss, $bodyTop)
    $OrbWaterGloss.Height = [Math]::Max(0.0, 104.0 - $bodyTop)
    [System.Windows.Controls.Canvas]::SetTop($OrbWaterSheen, $bodyTop)
    $OrbWaterSheen.Height = [Math]::Max(0.0, 104.0 - $bodyTop)

    $OrbPercentClipTranslate.X = -$script:WavePhase * 0.76
    $OrbPercentClipTranslate.Y = ($waterLine - 10.0) * 0.76
}

function Update-OrbAnimationFrame {
    if ($OrbView.Visibility -ne [System.Windows.Visibility]::Visible) { return }

    $script:WavePhase = ($script:WavePhase + 1.8) % 80.0
    $waterLine = 96.0 - (0.92 * $script:OrbWaterLevel)
    $frontBob = [Math]::Sin($script:WavePhase * [Math]::PI / 40.0) * 1.3
    $backBob = [Math]::Cos($script:WavePhase * [Math]::PI / 40.0) * 1.0

    [System.Windows.Controls.Canvas]::SetLeft($OrbWaveFront, -$script:WavePhase)
    [System.Windows.Controls.Canvas]::SetLeft($OrbWaveBack, -80.0 + (($script:WavePhase * 0.62) % 80.0))
    [System.Windows.Controls.Canvas]::SetLeft($OrbWaveGlint, -$script:WavePhase)
    [System.Windows.Controls.Canvas]::SetTop($OrbWaveFront, $waterLine - 10.0 + $frontBob)
    [System.Windows.Controls.Canvas]::SetTop($OrbWaveBack, $waterLine - 12.0 + $backBob)
    [System.Windows.Controls.Canvas]::SetTop($OrbWaveGlint, $waterLine - 10.0 + $frontBob)
    $OrbPercentClipTranslate.X = -$script:WavePhase * 0.76
    $OrbPercentClipTranslate.Y = ($waterLine - 10.0 + $frontBob) * 0.76
    $OrbRippleOuter.Opacity = 0.42 + (0.15 * [Math]::Sin($script:WavePhase * [Math]::PI / 40.0))
}

function Save-RateHistorySnapshot {
    param($Snapshot)
    if (-not $Snapshot) { return }

    try {
        $resetEpoch = if ($Snapshot.ResetAt) { ([DateTimeOffset]$Snapshot.ResetAt).ToUnixTimeSeconds() } else { $null }
        $signature = ('{0}|{1}|{2}|{3}' -f ([double]$Snapshot.UsedPercent), $resetEpoch, $Snapshot.WindowMinutes, $Snapshot.LimitId)
        if ($signature -eq $script:LastRateHistorySignature) {
            return
        }
        $script:LastRateHistorySignature = $signature
        [pscustomobject]@{
            timestamp     = ([DateTimeOffset]$Snapshot.ObservedAt).ToString('o')
            usedPercent   = [double]$Snapshot.UsedPercent
            resetEpoch    = $resetEpoch
            windowMinutes = $Snapshot.WindowMinutes
            limitId       = [string]$Snapshot.LimitId
            source        = [string]$Snapshot.Source
        } | ConvertTo-Json -Compress | Add-Content -LiteralPath $script:RateHistoryPath -Encoding UTF8
    } catch {
        Write-Diagnostic ('Unable to persist rate history: ' + $_.Exception.Message)
    }
}

function Apply-Snapshot {
    param($Snapshot)
    if (-not $Snapshot) { return }

    $script:CurrentSnapshot = $Snapshot
    $remaining = [double]$Snapshot.Remaining
    $used = [double]$Snapshot.UsedPercent

    if ($remaining -ge 25) {
        $accent = '#0A84FF'
        $soft = '#260A84FF'
        $badge = '#242A4E76'
    } elseif ($remaining -ge 10) {
        $accent = '#FF9F0A'
        $soft = '#26FF9F0A'
        $badge = '#332B210E'
    } else {
        $accent = '#FF453A'
        $soft = '#26FF453A'
        $badge = '#33321B1B'
    }

    $accentBrush = New-Brush $accent
    $PercentText.Text = ('{0:0}%' -f $remaining)
    $OrbPercentText.Text = ('{0:0}%' -f $remaining)
    $OrbPercentWaterText.Text = $OrbPercentText.Text
    Update-OrbWaterLevel $remaining
    $CapacityFill.Background = $accentBrush
    $StatusDot.Fill = $accentBrush
    $StatusHalo.Background = New-Brush $soft
    $SourceBadge.Background = New-Brush $badge
    $UsedText.Text = ('已用 {0:0}% · {1}' -f $used, $(if ($Snapshot.PlanType) { $Snapshot.PlanType.ToUpperInvariant() } else { 'CODEX' }))
    $UpdatedText.Text = ('{0:HH:mm:ss}' -f $Snapshot.ObservedAt.LocalDateTime)
    Update-ProgressFill

    if ($Snapshot.Source -eq 'direct') {
        $SourceText.Text = 'LIVE API'
        $SourceText.Foreground = $accentBrush
    } else {
        $SourceText.Text = 'EVENT SNAPSHOT'
        $SourceText.Foreground = $accentBrush
    }

    Update-Countdown
    Save-RateHistorySnapshot $Snapshot

    if ($script:AnalyticsSnapshot) {
        Apply-AnalyticsSnapshot $script:AnalyticsSnapshot
    }
}

function Apply-EmptyState {
    param([string]$Message)
    $PercentText.Text = '--%'
    $OrbPercentText.Text = '--%'
    $OrbPercentWaterText.Text = '--%'
    Update-OrbWaterLevel 0
    $CapacityFill.Width = 0
    $SourceText.Text = 'WAITING'
    $UsedText.Text = $Message
    $ResetText.Text = '启动 Codex 完成一次响应后自动出现'
    $UpdatedText.Text = '--:--'
}

function Format-TokenCount {
    param([long]$Value)
    if ($Value -ge 1000000000) { return ('{0:0.0}B' -f ($Value / 1000000000.0)) }
    if ($Value -ge 1000000) { return ('{0:0.0}M' -f ($Value / 1000000.0)) }
    if ($Value -ge 1000) { return ('{0:0.0}K' -f ($Value / 1000.0)) }
    return ('{0:N0}' -f $Value)
}

function Get-AnalyticsLabel {
    param([string]$Name)
    switch ($Name) {
        'ROOT' { return '主 Agent' }
        'SUBAGENT' { return '子 Agent' }
        'UNATTRIBUTED' { return '未归因' }
        'MULTI_SKILL' { return '多 Skill' }
        default { return $Name }
    }
}

function Render-UsageRows {
    param(
        $Panel,
        $Rows,
        [ValidateSet('daily', 'skill', 'chain', 'agent')][string]$Mode
    )

    $Panel.Children.Clear()
    $items = @($Rows)
    if ($items.Count -eq 0) {
        $empty = [System.Windows.Controls.TextBlock]::new()
        $empty.Text = '暂无可用统计'
        $empty.Foreground = New-Brush '#9FFFFFFF'
        $empty.FontSize = 11
        $empty.Margin = '1,14,0,0'
        [void]$Panel.Children.Add($empty)
        return
    }

    $palette = @('#0A84FF', '#64D2FF', '#5E5CE6', '#BF5AF2', '#30D158', '#FFD60A', '#FF9F0A', '#FF453A')
    $index = 0
    foreach ($item in $items) {
        $stackedLayout = $Mode -in @('skill', 'chain')
        $row = [System.Windows.Controls.Grid]::new()
        $row.Height = if ($Mode -eq 'skill') { 60 } elseif ($Mode -eq 'chain') { 50 } else { 36 }
        $row.Margin = if ($stackedLayout) { '0,0,0,4' } else { '0,0,0,2' }
        if ($stackedLayout) {
            $topRow = [System.Windows.Controls.RowDefinition]::new()
            $topRow.Height = '*'
            $barRow = [System.Windows.Controls.RowDefinition]::new()
            $barRow.Height = '14'
            [void]$row.RowDefinitions.Add($topRow)
            [void]$row.RowDefinitions.Add($barRow)
        }

        $labelColumn = [System.Windows.Controls.ColumnDefinition]::new()
        $labelColumn.Width = if ($stackedLayout) { '*' } else { '126' }
        $barColumn = [System.Windows.Controls.ColumnDefinition]::new()
        $barColumn.Width = if ($stackedLayout) { '0' } else { '*' }
        $valueColumn = [System.Windows.Controls.ColumnDefinition]::new()
        $valueColumn.Width = if ($stackedLayout) { '72' } else { '76' }
        $percentColumn = [System.Windows.Controls.ColumnDefinition]::new()
        $percentColumn.Width = if ($stackedLayout) { '48' } else { '48' }
        [void]$row.ColumnDefinitions.Add($labelColumn)
        [void]$row.ColumnDefinitions.Add($barColumn)
        [void]$row.ColumnDefinitions.Add($valueColumn)
        [void]$row.ColumnDefinitions.Add($percentColumn)

        $labelText = if ($Mode -eq 'daily') {
            try {
                $day = [DateTime]::ParseExact([string]$item.date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
                $weekNames = @('周日', '周一', '周二', '周三', '周四', '周五', '周六')
                ('{0:MM/dd}  {1}' -f $day, $weekNames[[int]$day.DayOfWeek])
            } catch {
                [string]$item.date
            }
        } else {
            Get-AnalyticsLabel ([string]$item.name)
        }

        if ($Mode -eq 'skill') {
            $label = [System.Windows.Controls.StackPanel]::new()
            $label.VerticalAlignment = 'Center'
            $label.ToolTip = ('主归因 {0} · 关联 {1} · 参与 {2} Turn · 路由 {3} Turn' -f `
                (Format-TokenCount ([long]$item.tokens)),
                (Format-TokenCount ([long]$item.associatedTokens)),
                ([long]$item.turns),
                ([long]$item.routerTurns))

            $skillName = [System.Windows.Controls.TextBlock]::new()
            $skillName.Text = $labelText
            $skillName.Foreground = New-Brush $(if ([long]$item.turns -gt 0) { '#D1D1D6' } else { '#70FFFFFF' })
            $skillName.FontSize = 11
            $skillName.FontWeight = 'SemiBold'
            $skillName.TextTrimming = 'CharacterEllipsis'

            $skillDetail = [System.Windows.Controls.TextBlock]::new()
            $skillDetail.Text = if ([long]$item.turns -gt 0) {
                '关联 {0} · {1}T' -f (Format-TokenCount ([long]$item.associatedTokens)), ([long]$item.turns)
            } else {
                '未参与 · 0T'
            }
            $skillDetail.Foreground = New-Brush '#78FFFFFF'
            $skillDetail.FontSize = 9
            $skillDetail.Margin = '0,1,0,0'
            [void]$label.Children.Add($skillName)
            [void]$label.Children.Add($skillDetail)
        } else {
            $label = [System.Windows.Controls.TextBlock]::new()
            $label.Text = $labelText
            $label.Foreground = New-Brush '#D1D1D6'
            $label.FontSize = if ($Mode -eq 'chain') { 11 } else { 10 }
            $label.FontWeight = 'SemiBold'
            $label.VerticalAlignment = 'Center'
            $label.TextTrimming = 'CharacterEllipsis'
            if ($Mode -eq 'chain') {
                $label.ToolTip = ('{0} · {1} Turn' -f $labelText, ([long]$item.turns))
            }
        }
        [System.Windows.Controls.Grid]::SetColumn($label, 0)
        if ($stackedLayout) { [System.Windows.Controls.Grid]::SetRow($label, 0) }

        $shareValue = [Math]::Max(0.0, [Math]::Min(100.0, [double]$item.sharePercent))
        $barHost = [System.Windows.Controls.Grid]::new()
        $barHost.Height = if ($stackedLayout) { 8 } else { 7 }
        $barHost.Margin = if ($stackedLayout) { '0,3,0,3' } else { '4,0,12,0' }
        $barHost.VerticalAlignment = 'Center'
        $filledColumn = [System.Windows.Controls.ColumnDefinition]::new()
        $filledColumn.Width = [System.Windows.GridLength]::new([Math]::Max(0.01, $shareValue), [System.Windows.GridUnitType]::Star)
        $emptyColumn = [System.Windows.Controls.ColumnDefinition]::new()
        $emptyColumn.Width = [System.Windows.GridLength]::new([Math]::Max(0.01, 100.0 - $shareValue), [System.Windows.GridUnitType]::Star)
        [void]$barHost.ColumnDefinitions.Add($filledColumn)
        [void]$barHost.ColumnDefinitions.Add($emptyColumn)
        $track = [System.Windows.Controls.Border]::new()
        $track.Background = New-Brush '#55343438'
        $track.CornerRadius = '3.5'
        [System.Windows.Controls.Grid]::SetColumnSpan($track, 2)
        $fill = [System.Windows.Controls.Border]::new()
        $fill.Background = New-Brush $palette[$index % $palette.Count]
        $fill.CornerRadius = '3.5'
        [System.Windows.Controls.Grid]::SetColumn($fill, 0)
        [void]$barHost.Children.Add($track)
        [void]$barHost.Children.Add($fill)
        if ($stackedLayout) {
            [System.Windows.Controls.Grid]::SetRow($barHost, 1)
            [System.Windows.Controls.Grid]::SetColumn($barHost, 0)
            [System.Windows.Controls.Grid]::SetColumnSpan($barHost, 4)
        } else {
            [System.Windows.Controls.Grid]::SetColumn($barHost, 1)
        }

        $value = [System.Windows.Controls.TextBlock]::new()
        $value.Text = Format-TokenCount ([long]$item.tokens)
        $value.Foreground = New-Brush '#D0FFFFFF'
        $value.FontSize = if ($stackedLayout) { 11 } else { 10 }
        $value.HorizontalAlignment = 'Right'
        $value.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($value, 2)
        if ($stackedLayout) { [System.Windows.Controls.Grid]::SetRow($value, 0) }

        $percent = [System.Windows.Controls.TextBlock]::new()
        $percent.Text = ('{0:0.0}%' -f ([double]$item.sharePercent))
        $percent.Foreground = New-Brush '#9FFFFFFF'
        $percent.FontSize = if ($stackedLayout) { 10 } else { 9 }
        $percent.HorizontalAlignment = 'Right'
        $percent.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($percent, 3)
        if ($stackedLayout) { [System.Windows.Controls.Grid]::SetRow($percent, 0) }

        [void]$row.Children.Add($label)
        [void]$row.Children.Add($barHost)
        [void]$row.Children.Add($value)
        [void]$row.Children.Add($percent)
        [void]$Panel.Children.Add($row)
        $index++
    }
}

function Get-DisplayDailyUsage {
    param($LocalSnapshot)

    $dates = New-Object System.Collections.Generic.List[string]
    for ($offset = 6; $offset -ge 0; $offset--) {
        $dates.Add((Get-Date).Date.AddDays(-$offset).ToString('yyyy-MM-dd'))
    }

    $values = @{}
    foreach ($dateKey in $dates) { $values[$dateKey] = 0L }
    $source = 'ALL LOCAL'

    # Local rollout events live under the shared Codex home and therefore preserve
    # usage from every account used on this Windows profile. The account API only
    # represents the account that is logged in right now, so it must not replace
    # the combined local history when the user switches accounts.
    if ($LocalSnapshot -and $LocalSnapshot.daily) {
        foreach ($bucket in @($LocalSnapshot.daily)) {
            $dateKey = [string]$bucket.date
            if ($values.ContainsKey($dateKey)) {
                $values[$dateKey] = [long]$bucket.tokens
            }
        }
    } elseif ($script:AccountUsage -and $script:AccountUsage.dailyUsageBuckets -and @($script:AccountUsage.dailyUsageBuckets).Count -gt 0) {
        foreach ($bucket in @($script:AccountUsage.dailyUsageBuckets)) {
            $dateKey = [string]$bucket.startDate
            if ($values.ContainsKey($dateKey)) {
                $values[$dateKey] = [long]$bucket.tokens
            }
        }
        $source = 'ACCOUNT API'
    }

    $total = 0L
    foreach ($dateKey in $dates) { $total += [long]$values[$dateKey] }
    $rows = foreach ($dateKey in $dates) {
        $tokens = [long]$values[$dateKey]
        [pscustomobject]@{
            date         = $dateKey
            tokens       = $tokens
            sharePercent = if ($total -gt 0) { [Math]::Round(($tokens / [double]$total) * 100.0, 2) } else { 0.0 }
        }
    }

    return [pscustomobject]@{ Rows = @($rows); Total = $total; Source = $source }
}

function Set-SkillView {
    param([ValidateSet('primary', 'chain')][string]$Name)
    $script:ActiveSkillView = $Name
    $SkillPrimaryScroll.Visibility = if ($Name -eq 'primary') { 'Visible' } else { 'Collapsed' }
    $SkillChainScroll.Visibility = if ($Name -eq 'chain') { 'Visible' } else { 'Collapsed' }

    foreach ($entry in @(
        [pscustomobject]@{ Name = 'primary'; Button = $SkillPrimaryButton },
        [pscustomobject]@{ Name = 'chain'; Button = $SkillChainButton }
    )) {
        if ($entry.Name -eq $Name) {
            $entry.Button.Background = New-Brush '#467ECDF7'
            $entry.Button.BorderBrush = New-Brush '#70DDF5FF'
            $entry.Button.Foreground = New-Brush '#F5FFFFFF'
        } else {
            $entry.Button.Background = New-Brush '#18FFFFFF'
            $entry.Button.BorderBrush = New-Brush '#3CFFFFFF'
            $entry.Button.Foreground = New-Brush '#BFFFFFFF'
        }
    }

    if ($Name -eq 'chain') {
        $SkillSectionTitle.Text = 'SKILL · 前后路由逻辑'
        $SkillHintText.Text = '按证据顺序记录“前置 Skill → 最终 Skill”；每条链的 Token 只计一次。'
    } elseif ($script:AnalyticsSnapshot) {
        $SkillSectionTitle.Text = 'SKILL · 主归因 TOKEN'
        $installedCount = [long]$script:AnalyticsSnapshot.installedSkillCount
        $unattributed = [double]$script:AnalyticsSnapshot.unattributedSkillPercent
        $SkillHintText.Text = ('已安装 {0} 个 · 未归因 {1:0.0}% · 关联 Token 不可相加。' -f $installedCount, $unattributed)
    } else {
        $SkillSectionTitle.Text = 'SKILL · 主归因 TOKEN'
        $SkillHintText.Text = '主归因只计最终 Skill；关联 Token 不可相加。'
    }
}

function Apply-AnalyticsSnapshot {
    param($Snapshot)
    if (-not $Snapshot) { return }

    Write-Diagnostic 'Applying analytics snapshot.'
    $dailyView = Get-DisplayDailyUsage $Snapshot
    $SevenDayTotalText.Text = Format-TokenCount ([long]$dailyView.Total)
    $AnalyticsSourceText.Text = $dailyView.Source
    $DailySourceText.Text = if ($dailyView.Source -eq 'ACCOUNT API') { '当前账号每日桶（兜底）' } else { '本机全部账号会话' }
    Render-UsageRows -Panel $DailyRowsPanel -Rows $dailyView.Rows -Mode daily
    Write-Diagnostic 'Rendered daily analytics rows.'
    Render-UsageRows -Panel $SkillRowsPanel -Rows @($Snapshot.skills) -Mode skill
    Write-Diagnostic 'Rendered skill analytics rows.'
    Render-UsageRows -Panel $SkillChainRowsPanel -Rows @($Snapshot.skillChains) -Mode chain
    Write-Diagnostic 'Rendered skill route chains.'
    Render-UsageRows -Panel $AgentRowsPanel -Rows @($Snapshot.agents) -Mode agent
    Write-Diagnostic 'Rendered agent analytics rows.'

    $SkillPrimaryButton.Content = ('{0} Skill' -f ([long]$Snapshot.installedSkillCount))
    $SkillCoverageText.Text = ('{0} Skills · 覆盖 {1:0.0}%' -f ([long]$Snapshot.installedSkillCount), ([double]$Snapshot.skillCoveragePercent))
    Set-SkillView $script:ActiveSkillView
    $OfficialRateText.Text = if ($script:CurrentSnapshot) {
        '官方额度已用 {0:0}%' -f ([double]$script:CurrentSnapshot.UsedPercent)
    } else {
        '官方额度暂不可用'
    }

    $rateDelta = 0.0
    foreach ($row in @($Snapshot.rateDaily)) {
        $rateDelta += [double]$row.usedPercentDelta
    }
    $RateHistoryText.Text = if ($rateDelta -gt 0) {
        '本地快照识别到近 7 日官方额度增量 {0:0.0}%；该值不与原始 Token 混算。' -f $rateDelta
    } else {
        '官方额度日拆分正在积累快照；当前 usedPercent 仍以额度页为准。'
    }

    $generated = try { [DateTimeOffset]::Parse([string]$Snapshot.generatedAt).LocalDateTime.ToString('HH:mm:ss') } catch { '--:--' }
    $AnalyticsStatusText.Text = ('本地索引 {0} 个文件 · 缓存命中 {1} · {2}' -f $Snapshot.scannedFiles, $Snapshot.cacheHits, $generated)
    Write-Diagnostic 'Analytics snapshot applied.'
}

function Set-AnalyticsTab {
    param([ValidateSet('daily', 'skill', 'agent')][string]$Name)
    $script:ActiveAnalyticsTab = $Name
    $DailyPanel.Visibility = if ($Name -eq 'daily') { 'Visible' } else { 'Collapsed' }
    $SkillPanel.Visibility = if ($Name -eq 'skill') { 'Visible' } else { 'Collapsed' }
    $AgentPanel.Visibility = if ($Name -eq 'agent') { 'Visible' } else { 'Collapsed' }
    if ($Name -eq 'skill') { Set-SkillView $script:ActiveSkillView }

    foreach ($entry in @(
        [pscustomobject]@{ Name = 'daily'; Button = $DailyTabButton },
        [pscustomobject]@{ Name = 'skill'; Button = $SkillTabButton },
        [pscustomobject]@{ Name = 'agent'; Button = $AgentTabButton }
    )) {
        if ($entry.Name -eq $Name) {
            $entry.Button.Background = New-Brush '#467ECDF7'
            $entry.Button.BorderBrush = New-Brush '#70DDF5FF'
            $entry.Button.Foreground = New-Brush '#F5FFFFFF'
        } else {
            $entry.Button.Background = New-Brush '#18FFFFFF'
            $entry.Button.BorderBrush = New-Brush '#3CFFFFFF'
            $entry.Button.Foreground = New-Brush '#BFFFFFFF'
        }
    }
}

function Ensure-WindowInsideWorkArea {
    $area = [System.Windows.SystemParameters]::WorkArea
    if (($window.Left + $window.Width) -gt $area.Right) { $window.Left = $area.Right - $window.Width - 14 }
    if (($window.Top + $window.Height) -gt $area.Bottom) { $window.Top = $area.Bottom - $window.Height - 14 }
    if ($window.Left -lt $area.Left) { $window.Left = $area.Left + 14 }
    if ($window.Top -lt $area.Top) { $window.Top = $area.Top + 14 }
}

function Resize-WindowAroundCenter {
    param(
        [double]$Width,
        [double]$Height
    )

    $centerX = $window.Left + ($window.Width / 2.0)
    $centerY = $window.Top + ($window.Height / 2.0)
    $window.Width = $Width
    $window.Height = $Height
    $window.Left = $centerX - ($Width / 2.0)
    $window.Top = $centerY - ($Height / 2.0)
    Ensure-WindowInsideWorkArea
}

function Show-OrbView {
    $script:ViewMode = 'orb'
    $GlowBorder.Visibility = 'Collapsed'
    $AnalyticsBorder.Visibility = 'Collapsed'
    $ResetCreditsBorder.Visibility = 'Collapsed'
    $OrbView.Visibility = 'Visible'
    Resize-WindowAroundCenter -Width 88 -Height 88
    if ($script:CurrentSnapshot) {
        Update-OrbWaterLevel ([double]$script:CurrentSnapshot.Remaining)
    }
    Update-OrbAnimationFrame
}

function Show-AnalyticsView {
    $script:ViewMode = 'analytics'
    $OrbView.Visibility = 'Collapsed'
    $GlowBorder.Visibility = 'Collapsed'
    $ResetCreditsBorder.Visibility = 'Collapsed'
    $AnalyticsBorder.Visibility = 'Visible'
    Resize-WindowAroundCenter -Width 440 -Height 560
    Set-AnalyticsTab $script:ActiveAnalyticsTab
    if ($script:AnalyticsSnapshot) {
        Apply-AnalyticsSnapshot $script:AnalyticsSnapshot
    }
    Start-AnalyticsRefreshAsync
}

function Show-CapacityView {
    $script:ViewMode = 'capacity'
    $OrbView.Visibility = 'Collapsed'
    $AnalyticsBorder.Visibility = 'Collapsed'
    $ResetCreditsBorder.Visibility = 'Collapsed'
    $GlowBorder.Visibility = 'Visible'
    Resize-WindowAroundCenter -Width 380 -Height 362
    Update-ProgressFill
}

function Format-ResetCreditRemaining {
    param([Parameter(Mandatory = $true)][DateTimeOffset]$ExpiresAt)

    $remaining = $ExpiresAt - [DateTimeOffset]::Now
    if ($remaining.TotalSeconds -le 0) { return '即将到期' }
    if ($remaining.Days -gt 0) {
        return ('剩余 {0} 天 {1} 小时' -f $remaining.Days, $remaining.Hours)
    }
    if ($remaining.Hours -gt 0) {
        return ('剩余 {0} 小时 {1} 分钟' -f $remaining.Hours, $remaining.Minutes)
    }
    return ('剩余 {0} 分钟' -f [Math]::Max(1, $remaining.Minutes))
}

function Set-ResetCreditsState {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$CountText = '—',
        [switch]$CanRetry
    )

    $ResetCreditsCountText.Text = $CountText
    $ResetCreditsRowsPanel.Children.Clear()
    $ResetCreditsScroll.Visibility = 'Collapsed'
    $ResetCreditsStateText.Text = $Message
    $ResetCreditsStatePanel.Visibility = 'Visible'
    $ResetCreditsRetryButton.Visibility = if ($CanRetry) { 'Visible' } else { 'Collapsed' }
}

function New-ResetCreditRow {
    param(
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ExpiresAt
    )

    $row = New-Object System.Windows.Controls.Border
    $row.CornerRadius = New-Object System.Windows.CornerRadius(15)
    $row.Background = New-Brush '#20FFFFFF'
    $row.BorderBrush = New-Brush '#36FFFFFF'
    $row.BorderThickness = New-Object System.Windows.Thickness(1)
    $row.Padding = New-Object System.Windows.Thickness(14, 10, 14, 10)
    $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)

    $content = New-Object System.Windows.Controls.StackPanel
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = ('重置卡 {0}' -f $Index)
    $title.Foreground = New-Brush '#F5FFFFFF'
    $title.FontSize = 12
    $title.FontWeight = [System.Windows.FontWeights]::SemiBold

    $localExpiry = $ExpiresAt.ToLocalTime()
    $dateText = if ($localExpiry.Year -eq [DateTimeOffset]::Now.Year) {
        '{0:MM月dd日 HH:mm}' -f $localExpiry.LocalDateTime
    } else {
        '{0:yyyy年MM月dd日 HH:mm}' -f $localExpiry.LocalDateTime
    }
    $detail = New-Object System.Windows.Controls.TextBlock
    $detail.Text = ('{0} 到期 · {1}' -f $dateText, (Format-ResetCreditRemaining -ExpiresAt $localExpiry))
    $detail.Foreground = New-Brush '#B8FFFFFF'
    $detail.FontSize = 10.5
    $detail.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)

    [void]$content.Children.Add($title)
    [void]$content.Children.Add($detail)
    $row.Child = $content
    return $row
}

function Apply-ResetCreditsSnapshot {
    param([Parameter(Mandatory = $true)]$Snapshot)

    $script:ResetCreditsSnapshot = $Snapshot
    $availableCount = [Math]::Max(0, [int]$Snapshot.AvailableCount)
    $credits = @($Snapshot.Credits | Sort-Object ExpiresAt)
    $ResetCreditsCountText.Text = ('{0} 张' -f $availableCount)
    $ResetCreditsRowsPanel.Children.Clear()

    if ($availableCount -eq 0) {
        Set-ResetCreditsState -Message '当前无可用重置卡' -CountText '0 张'
        return
    }

    if ($credits.Count -eq 0) {
        Set-ResetCreditsState -Message '已读取可用数量，但到期时间暂不可用' -CountText ('{0} 张' -f $availableCount) -CanRetry
        return
    }

    for ($index = 0; $index -lt $credits.Count; $index++) {
        [void]$ResetCreditsRowsPanel.Children.Add((New-ResetCreditRow -Index ($index + 1) -ExpiresAt ([DateTimeOffset]$credits[$index].ExpiresAt)))
    }
    $ResetCreditsStatePanel.Visibility = 'Collapsed'
    $ResetCreditsScroll.Visibility = 'Visible'
}

function Show-ResetCreditsView {
    $script:ViewMode = 'reset-credits'
    $OrbView.Visibility = 'Collapsed'
    $GlowBorder.Visibility = 'Collapsed'
    $AnalyticsBorder.Visibility = 'Collapsed'
    $ResetCreditsBorder.Visibility = 'Visible'
    Resize-WindowAroundCenter -Width 400 -Height 430

    if ($QARenderPath) {
        $now = [DateTimeOffset]::Now
        Apply-ResetCreditsSnapshot ([pscustomobject]@{
            AvailableCount = 3
            Credits = @(
                [pscustomobject]@{ ExpiresAt = $now.AddDays(9).AddHours(3) },
                [pscustomobject]@{ ExpiresAt = $now.AddDays(18).AddHours(7) },
                [pscustomobject]@{ ExpiresAt = $now.AddDays(27).AddHours(12) }
            )
            ObservedAt = $now
        })
        return
    }

    Set-ResetCreditsState -Message '正在查询重置卡…' -CountText '查询中…'
    Start-ResetCreditsRefreshAsync
}

function Start-DirectRefreshAsync {
    if ($script:DirectWorkerProcess -and -not $script:DirectWorkerProcess.HasExited) {
        $script:PendingDirectRefresh = $true
        return
    }

    try {
        if ($script:DirectWorkerProcess) {
            $script:DirectWorkerProcess.Dispose()
            $script:DirectWorkerProcess = $null
        }

        $workerInfo = New-Object System.Diagnostics.ProcessStartInfo
        $workerInfo.FileName = (Get-Command powershell.exe).Source
        $workerInfo.Arguments = ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -DirectWorker' -f $script:ScriptPath)
        $workerInfo.UseShellExecute = $false
        $workerInfo.CreateNoWindow = $true
        $workerInfo.RedirectStandardOutput = $true
        $workerInfo.RedirectStandardError = $true

        $worker = New-Object System.Diagnostics.Process
        $worker.StartInfo = $workerInfo
        [void]$worker.Start()
        $script:DirectWorkerProcess = $worker
        $script:PendingDirectRefresh = $false
        $RefreshButton.IsEnabled = $false
        $RefreshButton.Content = '···'
        $AnalyticsRefreshButton.IsEnabled = $false
        $AnalyticsRefreshButton.Content = '···'
    } catch {
        Write-Diagnostic ('Unable to start direct worker: ' + $_.Exception.Message)
    }
}

function Complete-DirectRefreshIfReady {
    $worker = $script:DirectWorkerProcess
    if (-not $worker -or -not $worker.HasExited) {
        return
    }

    try {
        $output = $worker.StandardOutput.ReadToEnd().Trim()
        $errorText = $worker.StandardError.ReadToEnd().Trim()
        if ($worker.ExitCode -eq 0 -and $output) {
            $wire = $output | ConvertFrom-Json
            $script:AccountUsage = if ($wire.Usage) { $wire.Usage } else { $null }
            if ($wire.Rate) {
                $rateWire = $wire.Rate
                $snapshot = [pscustomobject]@{
                    Source        = 'direct'
                    UsedPercent   = [double]$rateWire.UsedPercent
                    Remaining     = [double]$rateWire.Remaining
                    ResetAt       = if ($null -ne $rateWire.ResetEpoch) { [DateTimeOffset]::FromUnixTimeSeconds([long]$rateWire.ResetEpoch).ToLocalTime() } else { $null }
                    WindowMinutes = if ($null -ne $rateWire.WindowMinutes) { [long]$rateWire.WindowMinutes } else { $null }
                    PlanType      = [string]$rateWire.PlanType
                    LimitId       = [string]$rateWire.LimitId
                    ObservedAt    = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$rateWire.ObservedEpoch).ToLocalTime()
                }
                Apply-Snapshot $snapshot
            } elseif (-not $script:CurrentSnapshot) {
                Apply-EmptyState '账户接口不可用；启动 Codex 完成响应后读取事件快照'
            }
            if ($script:AnalyticsSnapshot) {
                Apply-AnalyticsSnapshot $script:AnalyticsSnapshot
            }
        } else {
            if (-not $script:CurrentSnapshot) {
                Apply-EmptyState '账户接口不可用；启动 Codex 完成响应后读取事件快照'
            }
            if ($errorText) {
                Write-Diagnostic ('Direct worker unavailable: ' + $errorText)
            } else {
                Write-Diagnostic ('Direct worker exited with code {0}.' -f $worker.ExitCode)
            }
        }
    } catch {
        Write-Diagnostic ('Direct worker result failed: ' + $_.Exception.Message)
    } finally {
        $runAgain = $script:PendingDirectRefresh
        $worker.Dispose()
        $script:DirectWorkerProcess = $null
        $script:PendingDirectRefresh = $false
        $RefreshButton.Content = '↻'
        $RefreshButton.IsEnabled = $true
        $AnalyticsRefreshButton.Content = '↻'
        $AnalyticsRefreshButton.IsEnabled = $true
        if ($runAgain) {
            Start-DirectRefreshAsync
        }
    }
}

function Start-ResetCreditsRefreshAsync {
    if ($script:ResetCreditsWorkerProcess -and -not $script:ResetCreditsWorkerProcess.HasExited) { return }

    try {
        if ($script:ResetCreditsWorkerProcess) {
            $script:ResetCreditsWorkerProcess.Dispose()
            $script:ResetCreditsWorkerProcess = $null
        }

        Set-ResetCreditsState -Message '正在查询重置卡…' -CountText '查询中…'
        $workerInfo = New-Object System.Diagnostics.ProcessStartInfo
        $workerInfo.FileName = (Get-Command powershell.exe).Source
        $workerInfo.Arguments = ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -ResetCreditsWorker' -f $script:ScriptPath)
        $workerInfo.UseShellExecute = $false
        $workerInfo.CreateNoWindow = $true
        $workerInfo.RedirectStandardOutput = $true
        $workerInfo.RedirectStandardError = $true

        $worker = New-Object System.Diagnostics.Process
        $worker.StartInfo = $workerInfo
        [void]$worker.Start()
        $script:ResetCreditsWorkerProcess = $worker
        $script:IsResetCreditsRefreshing = $true
        $ResetCreditsRefreshButton.IsEnabled = $false
        $ResetCreditsRefreshButton.Content = '···'
        $ResetCreditsRetryButton.IsEnabled = $false
    } catch {
        $script:IsResetCreditsRefreshing = $false
        Set-ResetCreditsState -Message '暂时无法读取重置卡' -CanRetry
        Write-Diagnostic 'Unable to start reset-credits worker.'
    }
}

function Complete-ResetCreditsRefreshIfReady {
    $worker = $script:ResetCreditsWorkerProcess
    if (-not $worker -or -not $worker.HasExited) { return }

    try {
        $output = $worker.StandardOutput.ReadToEnd().Trim()
        [void]$worker.StandardError.ReadToEnd()
        if ($worker.ExitCode -ne 0 -or -not $output) {
            throw 'RESET_CREDITS_QUERY_FAILED'
        }

        $wire = $output | ConvertFrom-Json
        $credits = @($wire.Credits | ForEach-Object {
            if ($null -ne $_.ExpiresEpoch) {
                [pscustomobject]@{
                    ExpiresAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$_.ExpiresEpoch).ToLocalTime()
                }
            }
        })
        $snapshot = [pscustomobject]@{
            AvailableCount = [int]$wire.AvailableCount
            Credits        = $credits
            ObservedAt     = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$wire.ObservedEpoch).ToLocalTime()
        }
        Apply-ResetCreditsSnapshot $snapshot
    } catch {
        Set-ResetCreditsState -Message '暂时无法读取重置卡' -CanRetry
        Write-Diagnostic 'Reset-credits worker query failed.'
    } finally {
        $worker.Dispose()
        $script:ResetCreditsWorkerProcess = $null
        $script:IsResetCreditsRefreshing = $false
        $ResetCreditsRefreshButton.Content = '↻'
        $ResetCreditsRefreshButton.IsEnabled = $true
        $ResetCreditsRetryButton.IsEnabled = $true
    }
}

function Start-AnalyticsRefreshAsync {
    if ($script:IsAnalyticsRefreshing) { return }
    $script:IsAnalyticsRefreshing = $true

    try {
        if (-not (Test-Path -LiteralPath $script:UsageAnalyticsPath)) {
            throw '未找到 UsageAnalytics.py。'
        }
        $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
        if (-not $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction SilentlyContinue }
        if (-not $pythonCommand -or -not $pythonCommand.Source) { throw '未找到 Python。' }

        $arguments = New-Object System.Collections.Generic.List[string]
        $arguments.Add($script:UsageAnalyticsPath)
        foreach ($codexHome in (Get-CodexHomeCandidates)) {
            $arguments.Add('--codex-home')
            $arguments.Add([string]$codexHome)
        }
        if ($arguments.Count -le 1) { throw '未找到 Codex 本地目录。' }
        $userSkillRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.agents\skills'
        if (Test-Path -LiteralPath $userSkillRoot) {
            $arguments.Add('--skill-root')
            $arguments.Add($userSkillRoot)
        }
        $arguments.Add('--cache')
        $arguments.Add($script:UsageCachePath)
        $arguments.Add('--rate-history')
        $arguments.Add($script:RateHistoryPath)
        $arguments.Add('--days')
        $arguments.Add('7')

        $AnalyticsRefreshButton.IsEnabled = $false
        $AnalyticsRefreshButton.Content = '···'
        $AnalyticsStatusText.Text = '正在增量汇总本地会话…'
        $output = & $pythonCommand.Source @arguments
        if ($LASTEXITCODE -ne 0 -or -not $output) { throw '统计进程未返回数据。' }
        $snapshot = ($output -join "`n") | ConvertFrom-Json
        if ($snapshot.PSObject.Properties.Name -contains 'error' -and $snapshot.error) { throw [string]$snapshot.error }
        $script:AnalyticsSnapshot = $snapshot
        Apply-AnalyticsSnapshot $snapshot
    } catch {
        $AnalyticsStatusText.Text = '本地统计失败：' + $_.Exception.Message
        Write-Diagnostic ('Analytics refresh failed: ' + $_.Exception.Message)
    } finally {
        $AnalyticsRefreshButton.IsEnabled = $true
        $AnalyticsRefreshButton.Content = '↻'
        $script:IsAnalyticsRefreshing = $false
    }
}

function Stop-OwnedProcess {
    param($Process)
    if (-not $Process) { return }

    try {
        if (-not $Process.HasExited) {
            # Only terminate a child process created by this widget.
            $Process.Kill()
            $Process.WaitForExit(1500) | Out-Null
        }
    } catch {}
    try { $Process.Dispose() } catch {}
}

function Refresh-Data {
    param([bool]$TryDirect)
    if ($script:IsRefreshing) { return }
    $script:IsRefreshing = $true
    $RefreshButton.IsEnabled = $false
    $RefreshButton.Content = '···'

    try {
        if ($TryDirect) {
            try {
                Write-Diagnostic 'Reading account/rateLimits/read.'
                $direct = Read-RateLimitFromAppServer
                if ($direct) {
                    Apply-Snapshot $direct
                    return
                }
            } catch {
                Write-Diagnostic ('Direct read unavailable: ' + $_.Exception.Message)
            }
        }

        $snapshot = Read-RateLimitFromSessionEvents
        if ($snapshot) {
            Apply-Snapshot $snapshot
        } elseif (-not $script:CurrentSnapshot) {
            Apply-EmptyState '账户接口不可用；本地尚无事件快照'
        }
    } finally {
        $RefreshButton.Content = '↻'
        $RefreshButton.IsEnabled = $true
        $script:IsRefreshing = $false
    }
}

function Save-WindowPosition {
    try {
        @{
            centerX = $window.Left + ($window.Width / 2.0)
            centerY = $window.Top + ($window.Height / 2.0)
            left = $window.Left
            top = $window.Top
        } |
            ConvertTo-Json -Compress |
            Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    } catch {}
}

function Restore-WindowPosition {
    try {
        if (Test-Path -LiteralPath $script:SettingsPath) {
            $settings = Get-Content -LiteralPath $script:SettingsPath -Encoding UTF8 -Raw | ConvertFrom-Json
            $workArea = [System.Windows.SystemParameters]::WorkArea
            if ($settings.PSObject.Properties.Name -contains 'centerX' -and
                $settings.PSObject.Properties.Name -contains 'centerY' -and
                $null -ne $settings.centerX -and $null -ne $settings.centerY -and
                $settings.centerX -ge ($workArea.Left + 40) -and $settings.centerX -le ($workArea.Right - 40) -and
                $settings.centerY -ge ($workArea.Top + 40) -and $settings.centerY -le ($workArea.Bottom - 40)) {
                $window.Left = [double]$settings.centerX - ($window.Width / 2.0)
                $window.Top = [double]$settings.centerY - ($window.Height / 2.0)
                Ensure-WindowInsideWorkArea
                return
            }
            if ($settings.PSObject.Properties.Name -contains 'left' -and
                $settings.PSObject.Properties.Name -contains 'top' -and
                $settings.left -ge $workArea.Left -and $settings.left -le ($workArea.Right - 80) -and
                $settings.top -ge $workArea.Top -and $settings.top -le ($workArea.Bottom - 60)) {
                $window.Left = [double]$settings.left
                $window.Top = [double]$settings.top
                return
            }
        }
    } catch {}

    $area = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $area.Right - $window.Width - 24
    $window.Top = $area.Top + 24
}

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$notifyIcon.Text = 'Codex Quota Orb'
$notifyIcon.Visible = $true
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$showMenuItem = $trayMenu.Items.Add('展开额度详情')
$analyticsMenuItem = $trayMenu.Items.Add('显示用量分析')
$refreshMenuItem = $trayMenu.Items.Add('刷新额度')
[void]$trayMenu.Items.Add('-')
$exitMenuItem = $trayMenu.Items.Add('退出')
$notifyIcon.ContextMenuStrip = $trayMenu

$OrbHitTarget.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($eventArgs.ChangedButton -ne [System.Windows.Input.MouseButton]::Left) { return }

    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
    $cursor = [System.Windows.Forms.Cursor]::Position
    $script:OrbDragStartScreenX = [double]$cursor.X
    $script:OrbDragStartScreenY = [double]$cursor.Y
    $script:OrbDragOffsetX = ([double]$cursor.X / $dpi.DpiScaleX) - $window.Left
    $script:OrbDragOffsetY = ([double]$cursor.Y / $dpi.DpiScaleY) - $window.Top
    $script:OrbIsDragging = $true
    $script:OrbPointerMoved = $false
    [void]$OrbHitTarget.CaptureMouse()
    $eventArgs.Handled = $true
})

$OrbHitTarget.Add_MouseMove({
    param($sender, $eventArgs)
    if (-not $script:OrbIsDragging -or $eventArgs.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }

    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
    $cursor = [System.Windows.Forms.Cursor]::Position
    if ([Math]::Abs([double]$cursor.X - $script:OrbDragStartScreenX) -gt 4 -or
        [Math]::Abs([double]$cursor.Y - $script:OrbDragStartScreenY) -gt 4) {
        $script:OrbPointerMoved = $true
    }
    if ($script:OrbPointerMoved) {
        $window.Left = ([double]$cursor.X / $dpi.DpiScaleX) - $script:OrbDragOffsetX
        $window.Top = ([double]$cursor.Y / $dpi.DpiScaleY) - $script:OrbDragOffsetY
        Ensure-WindowInsideWorkArea
    }
    $eventArgs.Handled = $true
})

$OrbHitTarget.Add_MouseLeftButtonUp({
    param($sender, $eventArgs)
    $wasMoved = $script:OrbPointerMoved
    $script:OrbIsDragging = $false
    $script:OrbPointerMoved = $false
    if ($OrbHitTarget.IsMouseCaptured) { $OrbHitTarget.ReleaseMouseCapture() }
    $eventArgs.Handled = $true
    if (-not $wasMoved) { Show-CapacityView }
})

$window.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($script:ViewMode -ne 'orb' -and $eventArgs.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
        try { $window.DragMove() } catch {}
    }
})

$ProgressTrack.Add_SizeChanged({ Update-ProgressFill })

$AnalyticsButton.Add_Click({ Show-AnalyticsView })
$ResetCreditsButton.Add_Click({ Show-ResetCreditsView })
$RefreshButton.Add_Click({
    Refresh-Data -TryDirect $false
    Start-DirectRefreshAsync
})
$HideButton.Add_Click({
    Show-OrbView
})
$CloseButton.Add_Click({
    $script:ExitRequested = $true
    $window.Close()
})
$showMenuItem.Add_Click({
    if (-not $window.IsVisible) { $window.Show() }
    $window.WindowState = [System.Windows.WindowState]::Normal
    $window.Activate()
    Show-CapacityView
})
$analyticsMenuItem.Add_Click({
    if (-not $window.IsVisible) { $window.Show() }
    $window.WindowState = [System.Windows.WindowState]::Normal
    $window.Activate()
    Show-AnalyticsView
})
$refreshMenuItem.Add_Click({
    if (-not $window.IsVisible) { $window.Show() }
    Refresh-Data -TryDirect $false
    Start-DirectRefreshAsync
})
$exitMenuItem.Add_Click({
    $script:ExitRequested = $true
    $window.Close()
})
$notifyIcon.Add_DoubleClick({
    if (-not $window.IsVisible) { $window.Show() }
    $window.WindowState = [System.Windows.WindowState]::Normal
    $window.Activate()
    Show-CapacityView
})

$BackButton.Add_Click({ Show-CapacityView })
$AnalyticsRefreshButton.Add_Click({
    Start-AnalyticsRefreshAsync
    Refresh-Data -TryDirect $false
    Start-DirectRefreshAsync
})
$AnalyticsHideButton.Add_Click({ Show-OrbView })
$AnalyticsCloseButton.Add_Click({
    $script:ExitRequested = $true
    $window.Close()
})
$DailyTabButton.Add_Click({ Set-AnalyticsTab 'daily' })
$SkillTabButton.Add_Click({ Set-AnalyticsTab 'skill' })
$AgentTabButton.Add_Click({ Set-AnalyticsTab 'agent' })
$SkillPrimaryButton.Add_Click({ Set-SkillView 'primary' })
$SkillChainButton.Add_Click({ Set-SkillView 'chain' })
$ResetCreditsBackButton.Add_Click({ Show-CapacityView })
$ResetCreditsRefreshButton.Add_Click({ Start-ResetCreditsRefreshAsync })
$ResetCreditsRetryButton.Add_Click({ Start-ResetCreditsRefreshAsync })
$ResetCreditsHideButton.Add_Click({ Show-OrbView })
$ResetCreditsCloseButton.Add_Click({
    $script:ExitRequested = $true
    $window.Close()
})

$countdownTimer = New-Object System.Windows.Threading.DispatcherTimer
$countdownTimer.Interval = [TimeSpan]::FromSeconds(30)
$countdownTimer.Add_Tick({ Update-Countdown })

$directWorkerTimer = New-Object System.Windows.Threading.DispatcherTimer
$directWorkerTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$directWorkerTimer.Add_Tick({
    Complete-DirectRefreshIfReady
})

$resetCreditsWorkerTimer = New-Object System.Windows.Threading.DispatcherTimer
$resetCreditsWorkerTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$resetCreditsWorkerTimer.Add_Tick({
    Complete-ResetCreditsRefreshIfReady
})

$eventTimer = New-Object System.Windows.Threading.DispatcherTimer
$eventTimer.Interval = [TimeSpan]::FromSeconds(4)
$eventTimer.Add_Tick({
    try {
        $latest = Get-LatestRolloutFile
        if ($latest -and ($latest.FullName -ne $script:LastRolloutPath -or $latest.LastWriteTimeUtc.Ticks -ne $script:LastRolloutWriteTicks)) {
            $script:LastRolloutPath = $latest.FullName
            $script:LastRolloutWriteTicks = $latest.LastWriteTimeUtc.Ticks
            $snapshot = Read-RateLimitFromSessionEvents
            if ($snapshot -and (-not $script:CurrentSnapshot -or $snapshot.ObservedAt -gt $script:CurrentSnapshot.ObservedAt)) {
                Apply-Snapshot $snapshot
            }
            if ($AnalyticsBorder.Visibility -eq [System.Windows.Visibility]::Visible) {
                Start-AnalyticsRefreshAsync
            }
        }
    } catch {
        Write-Diagnostic ('Event refresh failed: ' + $_.Exception.Message)
    }
})

$waveTimer = New-Object System.Windows.Threading.DispatcherTimer
$waveTimer.Interval = [TimeSpan]::FromMilliseconds(160)
$waveTimer.Add_Tick({ Update-OrbAnimationFrame })

$window.Add_StateChanged({
    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
        $window.WindowState = [System.Windows.WindowState]::Normal
        Show-OrbView
    }
})

$window.Add_Loaded({
    Restore-WindowPosition
    $window.Opacity = 1
    if (-not $QARenderPath) {
        $countdownTimer.Start()
        $directWorkerTimer.Start()
        $resetCreditsWorkerTimer.Start()
        $eventTimer.Start()
    }
    # Started after the first layout pass below to avoid competing with startup rendering.

    if (-not $QARenderPath) {
        $latest = Get-LatestRolloutFile
        if ($latest) {
            $script:LastRolloutPath = $latest.FullName
            $script:LastRolloutWriteTicks = $latest.LastWriteTimeUtc.Ticks
        }
    }

    $window.Dispatcher.BeginInvoke([Action]{
        if ($QARenderPath) {
            $qaPercentText = ('{0:0}%' -f $QARemaining)
            $script:CurrentSnapshot = [pscustomobject]@{
                Remaining   = $QARemaining
                UsedPercent = 100.0 - $QARemaining
            }
            $PercentText.Text = $qaPercentText
            $OrbPercentText.Text = $qaPercentText
            $OrbPercentWaterText.Text = $qaPercentText
            $UsedText.Text = ('已用 {0:0}% · CODEX' -f (100.0 - $QARemaining))
            $ResetText.Text = '4 天 08:21'
            $UpdatedText.Text = '12:48:16'
            $SevenDayTotalText.Text = '1.28M'
            $OfficialRateText.Text = ('官方额度 {0}' -f $qaPercentText)
            Update-OrbWaterLevel $QARemaining
            Update-ProgressFill
        } else {
            Refresh-Data -TryDirect $false
            Start-DirectRefreshAsync
        }
        switch ($QAView) {
            'orb' { Show-OrbView }
            'capacity' { Show-CapacityView }
            'reset-credits' { Show-ResetCreditsView }
            'skill-chain' {
                $script:ActiveAnalyticsTab = 'skill'
                $script:ActiveSkillView = 'chain'
                Show-AnalyticsView
            }
            default {
                $script:ActiveAnalyticsTab = $QAView
                Show-AnalyticsView
            }
        }
        $waveTimer.Start()
    }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null

    if ($AutoCloseSeconds -gt 0) {
        $script:AutoCloseTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:AutoCloseTimer.Interval = [TimeSpan]::FromSeconds($AutoCloseSeconds)
        $script:AutoCloseTimer.Add_Tick({
            $script:AutoCloseTimer.Stop()
            $script:ExitRequested = $true
            $window.Close()
        })
        $script:AutoCloseTimer.Start()
    }

    if ($QARenderPath) {
        $script:QARenderTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:QARenderTimer.Interval = [TimeSpan]::FromSeconds(3)
        $script:QARenderTimer.Add_Tick({
            $script:QARenderTimer.Stop()
            $window.UpdateLayout()
            $visual = $window.Content
            $visual.UpdateLayout()
            Write-Diagnostic ('QA view={0} window={1}x{2} analytics={3}' -f $QAView, $window.ActualWidth, $window.ActualHeight, $AnalyticsBorder.Visibility)
            $pixelWidth = [Math]::Max(1, [int][Math]::Ceiling($visual.ActualWidth))
            $pixelHeight = [Math]::Max(1, [int][Math]::Ceiling($visual.ActualHeight))
            $renderTarget = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($pixelWidth, $pixelHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $renderTarget.Render($visual)
            $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($renderTarget))
            $renderDir = Split-Path -Parent $QARenderPath
            if ($renderDir -and -not (Test-Path -LiteralPath $renderDir)) {
                New-Item -ItemType Directory -Path $renderDir -Force | Out-Null
            }
            $stream = [System.IO.File]::Create($QARenderPath)
            try { $encoder.Save($stream) } finally { $stream.Dispose() }
            $script:ExitRequested = $true
            $window.Close()
        })
        $script:QARenderTimer.Start()
    }
})

$window.Add_Closing({
    Save-WindowPosition
    $countdownTimer.Stop()
    $directWorkerTimer.Stop()
    $resetCreditsWorkerTimer.Stop()
    $eventTimer.Stop()
    $waveTimer.Stop()
    Stop-OwnedProcess $script:DirectWorkerProcess
    $script:DirectWorkerProcess = $null
    Stop-OwnedProcess $script:ResetCreditsWorkerProcess
    $script:ResetCreditsWorkerProcess = $null
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
})

try {
    [void]$window.ShowDialog()
} finally {
    try { $notifyIcon.Visible = $false; $notifyIcon.Dispose() } catch {}
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
}
