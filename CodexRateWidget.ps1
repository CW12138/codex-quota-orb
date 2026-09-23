param(
    [switch]$ShowDiagnostics,
    [switch]$HeadlessProbe,
    [switch]$DirectWorker,
    [switch]$ResetCreditsWorker,
    [switch]$AnalyticsWorker,
    [switch]$AccountWorker,
    [ValidateSet('list', 'capture', 'switch', 'import-custom')][string]$AccountAction = 'list',
    [string]$AccountId,
    [string]$AccountLabel,
    [string]$AccountImportDirectory,
    [switch]$QASolidWindow,
    [string]$QARenderPath,
    [string]$QATrayIconPath,
    [ValidateRange(0, 100)][double]$QARemaining = 64.0,
    [switch]$QAFiveHourAvailable,
    [switch]$QACustomProvider,
    [ValidateSet('orb', 'capacity', 'account', 'daily', 'skill', 'skill-chain', 'agent', 'tool', 'reset-credits')][string]$QAView = 'orb',
    [ValidateSet('Auto', 'Classic', 'Gradient')][string]$OrbStyle = 'Auto',
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

if (-not ('CodexQuotaOrb.TrayNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexQuotaOrb {
    public static class TrayNative {
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
    }
}
'@
}

$mutex = $null
if (-not $HeadlessProbe -and -not $DirectWorker -and -not $ResetCreditsWorker -and -not $AnalyticsWorker -and -not $AccountWorker -and -not $QARenderPath -and -not $QATrayIconPath) {
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
$script:OrbStyle = $OrbStyle
if ($script:OrbStyle -eq 'Auto') {
    $orbStylePath = Join-Path $script:ScriptDir 'orb-style.txt'
    if (Test-Path -LiteralPath $orbStylePath -PathType Leaf) {
        $savedOrbStyle = (Get-Content -LiteralPath $orbStylePath -Encoding UTF8 -Raw).Trim()
        $script:OrbStyle = if ($savedOrbStyle -in @('Classic', 'Gradient')) { $savedOrbStyle } else { 'Classic' }
    } else {
        $script:OrbStyle = 'Classic'
    }
}
$script:RuntimeDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexRateWidget'
$script:CurrentSnapshot = $null
$script:FiveHourSnapshot = $null
$script:WeeklySnapshot = $null
$script:IsCustomProviderActive = $false
$script:FiveHourUsesWeeklyFallback = $true
$script:LastRolloutPath = $null
$script:LastRolloutWriteTicks = 0L
$script:ExitRequested = $false
$script:IsRefreshing = $false
$script:DirectWorkerProcess = $null
$script:DirectWorkerStartedAt = $null
$script:DirectWorkerOutputTask = $null
$script:DirectWorkerErrorTask = $null
$script:PendingDirectRefresh = $false
$script:ResetCreditsWorkerProcess = $null
$script:ResetCreditsWorkerOutputTask = $null
$script:ResetCreditsWorkerErrorTask = $null
$script:ResetCreditsWorkerStartedAt = $null
$script:IsResetCreditsRefreshing = $false
$script:ResetCreditsSnapshot = $null
$script:AnalyticsWorkerProcess = $null
$script:AnalyticsWorkerStartedAt = $null
$script:AnalyticsWorkerOutputTask = $null
$script:AnalyticsWorkerErrorTask = $null
$script:IsAnalyticsRefreshing = $false
$script:AnalyticsSnapshot = $null
$script:AccountWorkerProcess = $null
$script:AccountWorkerOutputTask = $null
$script:AccountWorkerErrorTask = $null
$script:AccountWorkerAction = $null
$script:AccountWorkerIdentityId = $null
$script:AccountRegistrationProcess = $null
$script:AccountRegistrationIdentityId = $null
$script:IsAccountIdentityVerifying = $false
$script:QuotaSwitchPrompted = $false
$script:AccountUsage = $null
$script:ActiveAnalyticsTab = 'daily'
$script:ActiveSkillView = 'primary'
$script:LastRateHistorySignature = $null
$script:ViewMode = 'orb'
$script:OrbWaterLevel = 0.0
$script:OrbWaterTarget = 0.0
$script:OrbWaterTransitionFrom = 0.0
$script:OrbWaterTransitionStartedAt = [DateTime]::UtcNow
$script:OrbWaterTransitionDurationMs = 600.0
$script:OrbWaterTransitionActive = $false
$script:WavePhase = 0.0
$script:OrbIsDragging = $false
$script:OrbPointerMoved = $false
$script:PanelIsDragging = $false
$script:TrayIconResource = $null
$script:OrbThemeAnchors = @(
    [pscustomobject]@{ Remaining = 0.0;   Color = '#FFF0642F' }
    [pscustomobject]@{ Remaining = 20.0;  Color = '#FFE58B2F' }
    [pscustomobject]@{ Remaining = 40.0;  Color = '#FFD0A43A' }
    [pscustomobject]@{ Remaining = 60.0;  Color = '#FF31A58F' }
    [pscustomobject]@{ Remaining = 80.0;  Color = '#FF3EA5DA' }
    [pscustomobject]@{ Remaining = 100.0; Color = '#FF2F75D6' }
)

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
$script:AccountModulePath = Join-Path $script:ScriptDir 'AccountSwitcher.psm1'
if (Test-Path -LiteralPath $script:AccountModulePath -PathType Leaf) {
    Import-Module $script:AccountModulePath -Force
    $script:AccountStore = Initialize-CqoAccountStore -RuntimeDirectory $script:RuntimeDir -CodexHome $script:CodexHome
} else {
    $script:AccountStore = $null
}

if ($AccountWorker) {
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    try {
        if (-not $script:AccountStore) { throw '账号切换模块不存在。' }
        $result = switch ($AccountAction) {
            'list' { Get-CqoAccountRegistry -Store $script:AccountStore }
            'capture' { Save-CqoCurrentChatGptAccount -Store $script:AccountStore -Label $AccountLabel }
            'switch' {
                if (-not $AccountId) { throw '缺少目标账号 ID。' }
                try {
                    Switch-CqoIdentity -Store $script:AccountStore -IdentityId $AccountId
                } catch {
                    $recoveryPlans = $_.Exception.Data['CqoRecoveryPlans']
                    $recoveryId = $_.Exception.Data['CqoRecoveryIdentityId']
                    if (-not $recoveryPlans -or -not $recoveryId) { throw }
                    [pscustomobject]@{
                        switched = $false
                        recoveryPlans = @($recoveryPlans)
                        recoveryId = [string]$recoveryId
                        error = $_.Exception.Message
                    }
                }
            }
            'import-custom' {
                if (-not $AccountImportDirectory) { throw '缺少配置目录。' }
                Import-CqoCustomProfile `
                    -Store $script:AccountStore `
                    -AuthPath (Join-Path $AccountImportDirectory 'auth.json') `
                    -ConfigPath (Join-Path $AccountImportDirectory 'config.toml') `
                    -Label $AccountLabel
            }
        }
        $wire = [pscustomobject]@{ success = $true; result = $result }
    } catch {
        $wire = [pscustomobject]@{ success = $false; error = $_.Exception.Message }
    }
    # A long-lived descendant can inherit stdout and keep ReadToEndAsync open
    # after this worker exits. Send one complete result line and flush it.
    [Console]::Out.WriteLine(($wire | ConvertTo-Json -Compress -Depth 20))
    [Console]::Out.Flush()
    exit 0
}

function Write-Diagnostic {
    param([string]$Message)
    if ($ShowDiagnostics) {
        Write-Host ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message)
    }
}

function New-QuotaTrayBitmap {
    param(
        [ValidateRange(16, 512)]
        [int]$Size = 32
    )

    $bitmap = [System.Drawing.Bitmap]::new(
        $Size,
        $Size,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $resources = New-Object System.Collections.Generic.List[System.IDisposable]
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $scale = [single]($Size / 32.0)
        $graphics.ScaleTransform($scale, $scale)

        $outerRect = [System.Drawing.RectangleF]::new(1.5, 1.5, 29.0, 29.0)
        $innerRect = [System.Drawing.RectangleF]::new(4.0, 4.0, 24.0, 24.0)
        $outerBrush = [System.Drawing.SolidBrush]::new(
            [System.Drawing.Color]::FromArgb(255, 7, 30, 61)
        )
        $resources.Add($outerBrush)
        $graphics.FillEllipse($outerBrush, $outerRect)

        $atmosphereBrush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
            $innerRect,
            [System.Drawing.Color]::FromArgb(255, 218, 247, 255),
            [System.Drawing.Color]::FromArgb(255, 95, 157, 198),
            [System.Drawing.Drawing2D.LinearGradientMode]::Vertical
        )
        $resources.Add($atmosphereBrush)
        $graphics.FillEllipse($atmosphereBrush, $innerRect)

        $clipPath = [System.Drawing.Drawing2D.GraphicsPath]::new()
        $resources.Add($clipPath)
        $clipPath.AddEllipse($innerRect)
        $graphics.SetClip($clipPath)

        # A deliberately fixed half-full waterline stays legible in the 16 px tray.
        $waterPath = [System.Drawing.Drawing2D.GraphicsPath]::new()
        $resources.Add($waterPath)
        $waterPath.StartFigure()
        $waterPath.AddBezier(3.5, 16.1, 7.5, 13.8, 11.8, 18.1, 16.0, 16.0)
        $waterPath.AddBezier(16.0, 16.0, 20.2, 13.9, 24.1, 18.0, 28.5, 15.6)
        $waterPath.AddLine(28.5, 15.6, 28.5, 29.0)
        $waterPath.AddLine(28.5, 29.0, 3.5, 29.0)
        $waterPath.AddLine(3.5, 29.0, 3.5, 16.1)
        $waterPath.CloseFigure()
        $waterRect = [System.Drawing.RectangleF]::new(3.5, 14.0, 25.0, 15.0)
        $waterBrush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
            $waterRect,
            [System.Drawing.Color]::FromArgb(255, 62, 165, 218),
            [System.Drawing.Color]::FromArgb(255, 20, 73, 160),
            [System.Drawing.Drawing2D.LinearGradientMode]::Vertical
        )
        $resources.Add($waterBrush)
        $graphics.FillPath($waterBrush, $waterPath)

        $crestPen = [System.Drawing.Pen]::new(
            [System.Drawing.Color]::FromArgb(230, 218, 249, 255),
            1.15
        )
        $crestPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $crestPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $resources.Add($crestPen)
        $graphics.DrawBezier($crestPen, 3.8, 16.0, 7.7, 13.9, 11.8, 18.0, 16.0, 16.0)
        $graphics.DrawBezier($crestPen, 16.0, 16.0, 20.1, 14.0, 24.1, 17.9, 28.2, 15.7)

        $bubbleBrush = [System.Drawing.SolidBrush]::new(
            [System.Drawing.Color]::FromArgb(150, 218, 249, 255)
        )
        $resources.Add($bubbleBrush)
        $graphics.FillEllipse($bubbleBrush, [System.Drawing.RectangleF]::new(21.2, 21.2, 2.5, 2.5))
        $graphics.FillEllipse($bubbleBrush, [System.Drawing.RectangleF]::new(10.0, 24.0, 1.6, 1.6))
        $graphics.ResetClip()

        $rimPen = [System.Drawing.Pen]::new(
            [System.Drawing.Color]::FromArgb(230, 169, 204, 247),
            1.2
        )
        $resources.Add($rimPen)
        $graphics.DrawEllipse($rimPen, [System.Drawing.RectangleF]::new(2.7, 2.7, 26.6, 26.6))

        $highlightPen = [System.Drawing.Pen]::new(
            [System.Drawing.Color]::FromArgb(220, 255, 255, 255),
            1.6
        )
        $highlightPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $highlightPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $resources.Add($highlightPen)
        $graphics.DrawArc($highlightPen, [System.Drawing.RectangleF]::new(6.0, 5.6, 19.0, 18.0), 190.0, 72.0)

        $shineBrush = [System.Drawing.SolidBrush]::new(
            [System.Drawing.Color]::FromArgb(225, 255, 255, 255)
        )
        $resources.Add($shineBrush)
        $graphics.FillEllipse($shineBrush, [System.Drawing.RectangleF]::new(8.3, 7.0, 3.2, 2.0))
        return $bitmap
    } catch {
        $bitmap.Dispose()
        throw
    } finally {
        foreach ($resource in $resources) { $resource.Dispose() }
        $graphics.Dispose()
    }
}

function New-QuotaTrayIconResource {
    $bitmap = New-QuotaTrayBitmap -Size 32
    $handle = [IntPtr]::Zero
    try {
        $handle = $bitmap.GetHicon()
        return ([System.Drawing.Icon]::FromHandle($handle)).Clone()
    } finally {
        if ($handle -ne [IntPtr]::Zero) {
            [void][CodexQuotaOrb.TrayNative]::DestroyIcon($handle)
        }
        $bitmap.Dispose()
    }
}

if ($QATrayIconPath) {
    $preview = New-QuotaTrayBitmap -Size 32
    try {
        $previewDirectory = Split-Path -Parent $QATrayIconPath
        if ($previewDirectory -and -not (Test-Path -LiteralPath $previewDirectory)) {
            New-Item -ItemType Directory -Path $previewDirectory -Force | Out-Null
        }
        $preview.Save($QATrayIconPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $preview.Dispose()
    }
    exit 0
}

function Find-CodexExecutable {
    $candidates = New-Object System.Collections.Generic.List[string]
    $command = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        if ([IO.Path]::GetExtension([string]$command.Source) -ieq '.exe') {
            $candidates.Add([string]$command.Source)
        }

        $npmRoot = Split-Path -Parent $command.Source
        $candidates.Add((Join-Path $npmRoot 'node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'))
        $candidates.Add((Join-Path $npmRoot 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'))
    }

    $candidates.Add((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\OpenAI\Codex\bin\codex.exe'))

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
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

function ConvertTo-ResetCreditsSnapshot {
    param(
        [Parameter(Mandatory = $true)]$RateLimitResetCredits,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ObservedAt
    )

    $availableCountProperty = $RateLimitResetCredits.PSObject.Properties['availableCount']
    if (-not $availableCountProperty -or $null -eq $availableCountProperty.Value) {
        throw 'app-server 未返回重置卡可用数量。'
    }

    $availableCredits = New-Object System.Collections.Generic.List[object]
    foreach ($credit in @($RateLimitResetCredits.credits)) {
        if (-not $credit) { continue }
        if ([string]$credit.status -ne 'available') { continue }
        if ($null -eq $credit.expiresAt) { continue }

        try {
            $expiresAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$credit.expiresAt).ToLocalTime()
        } catch {
            continue
        }

        $availableCredits.Add([pscustomobject]@{ ExpiresAt = $expiresAt })
    }

    return [pscustomobject]@{
        # The app-server contract makes availableCount authoritative because
        # credit detail rows can be omitted or capped.
        AvailableCount = [Math]::Max(0, [int]$availableCountProperty.Value)
        Credits        = @($availableCredits | Sort-Object ExpiresAt)
        ObservedAt     = $ObservedAt.ToLocalTime()
    }
}

function ConvertTo-RateSnapshot {
    param(
        [Parameter(Mandatory = $true)]$RateLimits,
        [Parameter(Mandatory = $true)][ValidateSet('direct', 'session')][string]$Source,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ObservedAt,
        [ValidateSet('primary', 'secondary')][string]$WindowName = 'primary'
    )

    $windowProperty = $RateLimits.PSObject.Properties[$WindowName]
    $window = if ($windowProperty) { $windowProperty.Value } else { $null }
    if (-not $window) {
        return $null
    }

    $usedName = if ($Source -eq 'direct') { 'usedPercent' } else { 'used_percent' }
    $resetName = if ($Source -eq 'direct') { 'resetsAt' } else { 'resets_at' }
    $durationName = if ($Source -eq 'direct') { 'windowDurationMins' } else { 'window_minutes' }
    $planName = if ($Source -eq 'direct') { 'planType' } else { 'plan_type' }
    $limitName = if ($Source -eq 'direct') { 'limitId' } else { 'limit_id' }

    $usedProperty = $window.PSObject.Properties[$usedName]
    $resetProperty = $window.PSObject.Properties[$resetName]
    $durationProperty = $window.PSObject.Properties[$durationName]
    $planProperty = $RateLimits.PSObject.Properties[$planName]
    $limitProperty = $RateLimits.PSObject.Properties[$limitName]

    $used = if ($usedProperty) { $usedProperty.Value } else { $null }
    $resetEpoch = if ($resetProperty) { $resetProperty.Value } else { $null }
    $windowMinutes = if ($durationProperty) { $durationProperty.Value } else { $null }
    $planType = if ($planProperty) { $planProperty.Value } else { $null }
    $limitId = if ($limitProperty) { $limitProperty.Value } else { $null }

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
        WindowName    = $WindowName
    }
}

function ConvertTo-RateWindowPair {
    param(
        [Parameter(Mandatory = $true)]$RateLimits,
        [Parameter(Mandatory = $true)][ValidateSet('direct', 'session')][string]$Source,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ObservedAt
    )

    $candidates = @(
        @(
            ConvertTo-RateSnapshot -RateLimits $RateLimits -Source $Source -ObservedAt $ObservedAt -WindowName primary
            ConvertTo-RateSnapshot -RateLimits $RateLimits -Source $Source -ObservedAt $ObservedAt -WindowName secondary
        ) | Where-Object { $null -ne $_ }
    )

    if ($candidates.Count -eq 0) {
        return $null
    }

    # Codex historically exposes a five-hour window and a one-week window.
    # Classify by the server-provided duration instead of assuming that primary
    # and secondary always arrive in the same order.
    $weekly = @($candidates |
        Sort-Object @{ Expression = {
            if ($null -ne $_.WindowMinutes) { [long]$_.WindowMinutes } else { -1L }
        }; Descending = $true })[0]

    $fiveHourCandidates = @($candidates | Where-Object {
        $null -ne $_.WindowMinutes -and
        [long]$_.WindowMinutes -ge 240 -and
        [long]$_.WindowMinutes -le 360
    })
    $fiveHour = if ($fiveHourCandidates.Count -gt 0) {
        @($fiveHourCandidates |
            Sort-Object @{ Expression = { [Math]::Abs([long]$_.WindowMinutes - 300L) } })[0]
    } else {
        # While Codex exposes only the weekly window, mirror it into the 5h slot.
        # The moment a real five-hour window returns, the duration gate above
        # selects it automatically and each card keeps its own reset timestamp.
        $weekly
    }

    $fiveHourUsesWeeklyFallback = (
        $candidates.Count -eq 1 -or
        ($fiveHour.WindowName -eq $weekly.WindowName -and
         $fiveHour.WindowMinutes -eq $weekly.WindowMinutes)
    )

    return [pscustomobject]@{
        FiveHour                  = $fiveHour
        Weekly                    = $weekly
        FiveHourUsesWeeklyFallback = [bool]$fiveHourUsesWeeklyFallback
    }
}

function ConvertTo-RateWire {
    param($Snapshot)
    if (-not $Snapshot) { return $null }

    return [pscustomobject]@{
        Source        = $Snapshot.Source
        UsedPercent   = $Snapshot.UsedPercent
        Remaining     = $Snapshot.Remaining
        ResetEpoch    = if ($Snapshot.ResetAt) { ([DateTimeOffset]$Snapshot.ResetAt).ToUnixTimeSeconds() } else { $null }
        WindowMinutes = $Snapshot.WindowMinutes
        PlanType      = $Snapshot.PlanType
        LimitId       = $Snapshot.LimitId
        ObservedEpoch = ([DateTimeOffset]$Snapshot.ObservedAt).ToUnixTimeMilliseconds()
        WindowName    = $Snapshot.WindowName
    }
}

function ConvertFrom-RateWire {
    param($Wire)
    if (-not $Wire) { return $null }
    $windowNameProperty = $Wire.PSObject.Properties['WindowName']

    return [pscustomobject]@{
        Source        = if ($Wire.Source) { [string]$Wire.Source } else { 'direct' }
        UsedPercent   = [double]$Wire.UsedPercent
        Remaining     = [double]$Wire.Remaining
        ResetAt       = if ($null -ne $Wire.ResetEpoch) { [DateTimeOffset]::FromUnixTimeSeconds([long]$Wire.ResetEpoch).ToLocalTime() } else { $null }
        WindowMinutes = if ($null -ne $Wire.WindowMinutes) { [long]$Wire.WindowMinutes } else { $null }
        PlanType      = [string]$Wire.PlanType
        LimitId       = [string]$Wire.LimitId
        ObservedAt    = if ($null -ne $Wire.ObservedEpoch) {
            [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Wire.ObservedEpoch).ToLocalTime()
        } else {
            [DateTimeOffset]::Now
        }
        WindowName    = if ($windowNameProperty -and $windowNameProperty.Value) { [string]$windowNameProperty.Value } else { 'primary' }
    }
}

function Read-AccountDataFromAppServer {
    $identitySynchronized = $false
    $launchContext = if ($script:AccountStore) {
        try {
            $syncResult = Sync-CqoActiveIdentity -Store $script:AccountStore -Detailed
            $identitySynchronized = [bool]$syncResult.Resolved
        } catch {
            Write-Diagnostic ('Unable to reconcile the active Codex identity: ' + $_.Exception.Message)
        }
        Get-CqoActiveLaunchContext -Store $script:AccountStore
    } else { $null }

    if ($launchContext -and $launchContext.Identity -and [string]$launchContext.Identity.kind -eq 'custom') {
        return [pscustomobject]@{
            RateLimits               = $null
            RateLimitResetCredits    = $null
            ResetCreditsFieldPresent = $false
            Usage                    = $null
            RateError                = $null
            UsageError               = $null
            IdentitySynchronized     = $identitySynchronized
            CustomProviderActive     = $true
        }
    }

    $exe = Find-CodexExecutable
    if (-not $exe) {
        throw '未找到 codex.exe。'
    }

    $process = $null
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $exe
        $startInfo.Arguments = if ($launchContext -and $launchContext.Identity -and [string]$launchContext.Identity.kind -eq 'chatgpt') {
            '--disable code_mode_host -c mcp_servers.node_repl.enabled=false -c model_provider=\"openai\" -c cli_auth_credentials_store=\"file\" app-server --stdio'
        } else {
            '--disable code_mode_host -c mcp_servers.node_repl.enabled=false app-server --stdio'
        }
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        if ($launchContext) {
            foreach ($name in $launchContext.Environment.Keys) {
                $startInfo.EnvironmentVariables[[string]$name] = [string]$launchContext.Environment[$name]
            }
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        [void]$process.Start()
        # Drain stderr concurrently. A verbose or newly updated Codex CLI must not
        # fill the redirected pipe and deadlock this worker.
        $errorReadTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.AutoFlush = $true

        $initialize = @{
            id = 0
            method = 'initialize'
            params = @{
                clientInfo = @{
                    name = 'codex_rate_widget'
                    title = 'Codex Quota Orb'
                    version = '1.5.2'
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
        $rateLimitResetCredits = $null
        $resetCreditsFieldPresent = $false
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
                } elseif ($message.PSObject.Properties.Name -contains 'result' -and $message.result) {
                    $rateLimitsProperty = $message.result.PSObject.Properties['rateLimits']
                    if ($rateLimitsProperty) {
                        $rateLimits = $rateLimitsProperty.Value
                    }
                    $resetCreditsProperty = $message.result.PSObject.Properties['rateLimitResetCredits']
                    if ($resetCreditsProperty) {
                        $resetCreditsFieldPresent = $true
                        $rateLimitResetCredits = $resetCreditsProperty.Value
                    }
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
            RateLimits              = $rateLimits
            RateLimitResetCredits   = $rateLimitResetCredits
            ResetCreditsFieldPresent = [bool]$resetCreditsFieldPresent
            Usage                   = $usage
            RateError               = $rateError
            UsageError              = $usageError
            IdentitySynchronized    = $identitySynchronized
            CustomProviderActive    = $false
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

function Read-RateWindowsFromAppServer {
    $accountData = Read-AccountDataFromAppServer
    if ($accountData.RateLimits) {
        return ConvertTo-RateWindowPair -RateLimits $accountData.RateLimits -Source direct -ObservedAt ([DateTimeOffset]::Now)
    }
    if ($accountData.RateError) {
        throw $accountData.RateError
    }
    throw 'app-server 未返回 rateLimits。'
}

function Read-ResetCreditsFromAppServer {
    $observedAt = [DateTimeOffset]::Now
    $accountData = Read-AccountDataFromAppServer
    if ($accountData.ResetCreditsFieldPresent -and $null -ne $accountData.RateLimitResetCredits) {
        return ConvertTo-ResetCreditsSnapshot `
            -RateLimitResetCredits $accountData.RateLimitResetCredits `
            -ObservedAt $observedAt
    }
    if ($accountData.RateError) {
        throw $accountData.RateError
    }
    throw '当前 app-server 未提供 rateLimitResetCredits。'
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

function Read-BoundedFileTailLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1, 10000)][int]$MaxLines = 120,
        [ValidateRange(4096, 16777216)][int]$MaxBytes = 4194304
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite,
            65536,
            [System.IO.FileOptions]::SequentialScan
        )
        $bytesToRead = [int][Math]::Min([long]$MaxBytes, $stream.Length)
        if ($bytesToRead -le 0) {
            return @()
        }

        $startOffset = $stream.Length - $bytesToRead
        [void]$stream.Seek($startOffset, [System.IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] $bytesToRead
        $totalRead = 0
        while ($totalRead -lt $bytesToRead) {
            $read = $stream.Read($buffer, $totalRead, $bytesToRead - $totalRead)
            if ($read -le 0) { break }
            $totalRead += $read
        }

        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $totalRead)
        if ($startOffset -gt 0) {
            # The byte window normally begins inside a JSONL record. Discard that
            # partial record instead of parsing a potentially huge tool payload.
            $firstLineBreak = $text.IndexOf("`n", [StringComparison]::Ordinal)
            if ($firstLineBreak -lt 0) {
                return @()
            }
            $text = $text.Substring($firstLineBreak + 1)
        }

        $lines = @($text -split "`r?`n")
        if ($lines.Count -gt 0 -and [string]::IsNullOrEmpty([string]$lines[$lines.Count - 1])) {
            $lines = @($lines | Select-Object -First ($lines.Count - 1))
        }
        return @($lines | Select-Object -Last $MaxLines)
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Read-RateWindowsFromSessionEvents {
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
        # Get-Content -Tail can scan an entire JSONL file when a tool payload creates
        # a very long line. Read a hard-bounded byte window instead.
        $lines = @(Read-BoundedFileTailLines -Path $file.FullName -MaxLines 120 -MaxBytes 4194304)
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
                return ConvertTo-RateWindowPair -RateLimits $event.payload.rate_limits -Source session -ObservedAt $observedAt
            }
        }
    }

    return $null
}

function Read-RateLimitFromHistory {
    $lines = @(Read-BoundedFileTailLines -Path $script:RateHistoryPath -MaxLines 20 -MaxBytes 262144)
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        try {
            $item = $lines[$index] | ConvertFrom-Json
            if ($null -eq $item.usedPercent -or -not $item.timestamp) { continue }
            $usedPercent = [Math]::Max(0.0, [Math]::Min(100.0, [double]$item.usedPercent))
            return [pscustomobject]@{
                Source        = if ($item.source) { [string]$item.source } else { 'history' }
                UsedPercent   = $usedPercent
                Remaining     = 100.0 - $usedPercent
                ResetAt       = if ($null -ne $item.resetEpoch) { [DateTimeOffset]::FromUnixTimeSeconds([long]$item.resetEpoch).ToLocalTime() } else { $null }
                WindowMinutes = if ($null -ne $item.windowMinutes) { [long]$item.windowMinutes } else { $null }
                PlanType      = $null
                LimitId       = if ($item.limitId) { [string]$item.limitId } else { 'codex' }
                ObservedAt    = [DateTimeOffset]::Parse([string]$item.timestamp).ToLocalTime()
            }
        } catch {
            continue
        }
    }
    return $null
}

if ($DirectWorker) {
    $workerAccount = $null
    $workerWindows = $null
    $workerFailure = $null
    try {
        $workerAccount = Read-AccountDataFromAppServer
        if ($workerAccount.RateLimits) {
            $workerWindows = ConvertTo-RateWindowPair -RateLimits $workerAccount.RateLimits -Source direct -ObservedAt ([DateTimeOffset]::Now)
        }
    } catch {
        $workerFailure = $_.Exception.Message
        # This fallback remains inside the worker process, never on the WPF thread.
        $workerWindows = Read-RateWindowsFromSessionEvents
    }
    $workerSnapshot = if ($workerWindows) { $workerWindows.FiveHour } else { $null }
    [pscustomobject]@{
        # Rate remains for compatibility with installed 1.3.x UI workers.
        Rate = (ConvertTo-RateWire $workerSnapshot)
        Rates = if ($workerWindows) {
            [pscustomobject]@{
                FiveHour                   = (ConvertTo-RateWire $workerWindows.FiveHour)
                Weekly                     = (ConvertTo-RateWire $workerWindows.Weekly)
                FiveHourUsesWeeklyFallback = [bool]$workerWindows.FiveHourUsesWeeklyFallback
            }
        } else { $null }
        Usage      = if ($workerAccount) { $workerAccount.Usage } else { $null }
        RateError  = if ($workerAccount) { $workerAccount.RateError } else { $workerFailure }
        UsageError = if ($workerAccount) { $workerAccount.UsageError } else { $workerFailure }
        IdentitySynchronized = if ($workerAccount) { [bool]$workerAccount.IdentitySynchronized } else { $false }
        CustomProviderActive = if ($workerAccount) { [bool]$workerAccount.CustomProviderActive } else { $false }
    } | ConvertTo-Json -Compress -Depth 8
    exit 0
}

if ($ResetCreditsWorker) {
    try {
        $resetCredits = Read-ResetCreditsFromAppServer
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

if ($AnalyticsWorker) {
    try {
        if (-not (Test-Path -LiteralPath $script:UsageAnalyticsPath -PathType Leaf)) {
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
        $userProfile = [Environment]::GetFolderPath('UserProfile')
        foreach ($userSkillRoot in @(
            (Join-Path $userProfile '.agents\skills'),
            (Join-Path $userProfile '.codex\skills')
        )) {
            if (Test-Path -LiteralPath $userSkillRoot) {
                $arguments.Add('--skill-root')
                $arguments.Add($userSkillRoot)
            }
        }
        $codexConfigPath = Join-Path $userProfile '.codex\config.toml'
        if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) {
            $arguments.Add('--codex-config')
            $arguments.Add($codexConfigPath)
        }
        $arguments.Add('--cache')
        $arguments.Add($script:UsageCachePath)
        $arguments.Add('--rate-history')
        $arguments.Add($script:RateHistoryPath)
        $arguments.Add('--days')
        $arguments.Add('7')

        $output = & $pythonCommand.Source @arguments
        if ($LASTEXITCODE -ne 0 -or -not $output) { throw '统计进程未返回数据。' }
        $output
        exit 0
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}

if ($HeadlessProbe) {
    try {
        try {
            $probeWindows = Read-RateWindowsFromAppServer
        } catch {
            Write-Diagnostic ('Direct read unavailable: ' + $_.Exception.Message)
            $probeWindows = Read-RateWindowsFromSessionEvents
        }

        if (-not $probeWindows) {
            throw '未找到可用额度快照。'
        }
        $probeSnapshot = $probeWindows.FiveHour
        [pscustomobject]@{
            Source                      = $probeSnapshot.Source
            UsedPercent                 = $probeSnapshot.UsedPercent
            Remaining                   = $probeSnapshot.Remaining
            ResetAt                     = $probeSnapshot.ResetAt
            WindowMinutes               = $probeSnapshot.WindowMinutes
            PlanType                    = $probeSnapshot.PlanType
            LimitId                     = $probeSnapshot.LimitId
            ObservedAt                  = $probeSnapshot.ObservedAt
            Weekly                      = (ConvertTo-RateWire $probeWindows.Weekly)
            FiveHourUsesWeeklyFallback  = [bool]$probeWindows.FiveHourUsesWeeklyFallback
        } | ConvertTo-Json -Depth 6
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
        <LinearGradientBrush x:Key="AccountGlassEdgeBrush" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#D8F3FCFF" Offset="0"/>
            <GradientStop Color="#71BFEAFF" Offset="0.24"/>
            <GradientStop Color="#24FFFFFF" Offset="0.52"/>
            <GradientStop Color="#315D91AD" Offset="0.76"/>
            <GradientStop Color="#A0BDEBFF" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="AccountGlassSurfaceBrush" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#F220394C" Offset="0"/>
            <GradientStop Color="#EE152636" Offset="0.46"/>
            <GradientStop Color="#F00D1C2A" Offset="0.72"/>
            <GradientStop Color="#F2183543" Offset="1"/>
        </LinearGradientBrush>
        <RadialGradientBrush x:Key="AccountGlassGlowBrush" Center="0.13,0.02" GradientOrigin="0.08,-0.03" RadiusX="0.92" RadiusY="0.72">
            <GradientStop Color="#62BDEEFF" Offset="0"/>
            <GradientStop Color="#283B93C1" Offset="0.35"/>
            <GradientStop Color="#0A7E6FBC" Offset="0.65"/>
            <GradientStop Color="#00000000" Offset="1"/>
        </RadialGradientBrush>
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
        <Style TargetType="{x:Type ScrollBar}">
            <Setter Property="Width" Value="7"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ScrollBar}">
                        <Grid Width="7" Background="Transparent">
                            <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True" Focusable="False">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Opacity="0" Focusable="False"/>
                                </Track.DecreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb MinHeight="28" Margin="1,0">
                                        <Thumb.Template>
                                            <ControlTemplate TargetType="{x:Type Thumb}">
                                                <Border x:Name="ThumbSurface" Background="#5689B9D2" CornerRadius="2.5"/>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True">
                                                        <Setter TargetName="ThumbSurface" Property="Background" Value="#8ABFE6F7"/>
                                                    </Trigger>
                                                    <Trigger Property="IsDragging" Value="True">
                                                        <Setter TargetName="ThumbSurface" Property="Background" Value="#B8DDF5FF"/>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Thumb.Template>
                                    </Thumb>
                                </Track.Thumb>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Opacity="0" Focusable="False"/>
                                </Track.IncreaseRepeatButton>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
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
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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
            <Setter Property="Height" Value="30"/>
            <Setter Property="Margin" Value="0,0,6,0"/>
            <Setter Property="Background" Value="#12FFFFFF"/>
            <Setter Property="BorderBrush" Value="#2CFFFFFF"/>
            <Setter Property="Foreground" Value="#BFFFFFFF"/>
            <Setter Property="FontSize" Value="10"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="SegmentSurface" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="15">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="SegmentSurface" Property="Background" Value="#28FFFFFF"/>
                                <Setter Property="Foreground" Value="#FFFFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="SegmentSurface" Property="Background" Value="#3A6FB4D9"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="SecondaryActionButton" TargetType="Button" BasedOn="{StaticResource ActionButton}">
            <Setter Property="Background" Value="#18FFFFFF"/>
            <Setter Property="BorderBrush" Value="#38FFFFFF"/>
            <Setter Property="Foreground" Value="#D8FFFFFF"/>
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
                    <Rectangle x:Name="OrbAtmosphereFill" Width="100" Height="100">
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
                    <Path x:Name="OrbWaveShade" Canvas.Top="40" Fill="Transparent" Stroke="#76020A13" StrokeThickness="3.1" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Opacity="0.48"
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
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <Border Grid.RowSpan="5" Margin="-8,-6,-8,-7" CornerRadius="24" IsHitTestVisible="False">
                    <Border.Background>
                        <RadialGradientBrush Center="0.18,0.06" GradientOrigin="0.12,0.02" RadiusX="0.88" RadiusY="0.78">
                            <GradientStop Color="#42FFFFFF" Offset="0"/>
                            <GradientStop Color="#183D9BC4" Offset="0.38"/>
                            <GradientStop Color="#00001536" Offset="1"/>
                        </RadialGradientBrush>
                    </Border.Background>
                </Border>
                <Border Grid.RowSpan="5" Margin="-8,-6,-8,-7" CornerRadius="24" Background="{StaticResource GlassSpecularBrush}" Opacity="0.9" IsHitTestVisible="False"/>
                <Border Grid.RowSpan="5" Margin="-8,-6,-8,-7" CornerRadius="24" IsHitTestVisible="False">
                    <Border.Background>
                        <RadialGradientBrush Center="0.76,1.06" GradientOrigin="0.82,1.1" RadiusX="0.82" RadiusY="0.48">
                            <GradientStop Color="#323C91B8" Offset="0"/>
                            <GradientStop Color="#16215470" Offset="0.38"/>
                            <GradientStop Color="#00000000" Offset="0.76"/>
                        </RadialGradientBrush>
                    </Border.Background>
                </Border>
                <Border Grid.RowSpan="5" Margin="-8,-6,-8,-7" CornerRadius="24" Background="{StaticResource GlassTexture}" Opacity="0.22" IsHitTestVisible="False"/>
                <Border Grid.RowSpan="5" Margin="-5,-3,-5,-4" CornerRadius="22" BorderThickness="1.15" BorderBrush="{StaticResource GlassInnerEdgeBrush}" IsHitTestVisible="False"/>
                <Border Grid.RowSpan="5" Margin="-2,0,-2,-1" CornerRadius="19" BorderThickness="1" BorderBrush="#36000000" IsHitTestVisible="False"/>

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
                            <TextBlock Text="5h · 1周额度" Foreground="#F5FFFFFF" FontSize="15" FontWeight="Bold" Margin="0,-1,0,0"/>
                        </StackPanel>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button x:Name="AccountSwitchButton" Style="{StaticResource WindowButton}" Content="⇄" FontFamily="Segoe UI Symbol" FontSize="13" ToolTip="切换账号或配置" AutomationProperties.Name="切换账号或配置"/>
                        <Button x:Name="OrbStyleToggleButton" Style="{StaticResource WindowButton}" ToolTip="切换悬浮球样式" AutomationProperties.Name="切换悬浮球样式">
                            <Grid Width="18" Height="10">
                                <Ellipse x:Name="ClassicStyleDot" Width="8" Height="8" HorizontalAlignment="Left" Fill="#FF4D9FE8" Stroke="#F2FFFFFF" StrokeThickness="1.3"/>
                                <Ellipse x:Name="GradientStyleDot" Width="8" Height="8" HorizontalAlignment="Right" Stroke="#54FFFFFF" StrokeThickness="1">
                                    <Ellipse.Fill>
                                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                            <GradientStop Color="#FF2F75D6" Offset="0"/>
                                            <GradientStop Color="#FF31A58F" Offset="0.5"/>
                                            <GradientStop Color="#FFF0642F" Offset="1"/>
                                        </LinearGradientBrush>
                                    </Ellipse.Fill>
                                </Ellipse>
                            </Grid>
                        </Button>
                        <Button x:Name="RefreshButton" Style="{StaticResource WindowButton}" Content="↻" ToolTip="刷新额度"/>
                        <Button x:Name="HideButton" Style="{StaticResource WindowButton}" Content="—" ToolTip="收拢为水球"/>
                        <Button x:Name="CloseButton" Style="{StaticResource WindowButton}" Content="×" ToolTip="退出"/>
                    </StackPanel>
                </Grid>

                <Grid Grid.Row="1" Margin="0,9,0,9" Height="180">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Border Grid.Column="0" Margin="0,0,5,0" CornerRadius="18" BorderThickness="1" BorderBrush="#35FFFFFF" Background="#2A142130">
                        <Grid Margin="14,11,14,12">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="22"/>
                                <RowDefinition Height="46"/>
                                <RowDefinition Height="8"/>
                                <RowDefinition Height="24"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <Grid Grid.Row="0">
                                <TextBlock Text="5h" Foreground="#F5FFFFFF" FontSize="13" FontWeight="Bold" VerticalAlignment="Center"/>
                                <TextBlock x:Name="FiveHourFallbackText" Text="周窗口回退" Foreground="#FFFFC866" FontSize="7.5" FontWeight="Bold" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                            </Grid>
                            <TextBlock x:Name="PercentText" Grid.Row="1" Text="--%" Foreground="#FFFFFFFF" FontFamily="{StaticResource InterfaceDisplayFont}" FontSize="35" FontWeight="Bold" VerticalAlignment="Center"/>
                            <Grid x:Name="ProgressTrack" Grid.Row="2" Height="7">
                                <Border Background="#55343438" CornerRadius="3.5"/>
                                <Border x:Name="CapacityFill" HorizontalAlignment="Left" Width="0" Background="#0A84FF" CornerRadius="3.5"/>
                            </Grid>
                            <TextBlock x:Name="FiveHourUsedText" Grid.Row="3" Text="正在读取额度" Foreground="#CFFFFFFF" FontSize="9.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                            <StackPanel Grid.Row="4" Margin="0,5,0,0">
                                <TextBlock Text="R E S E T" Foreground="#7FFFFFFF" FontSize="7.5" FontWeight="Bold"/>
                                <TextBlock x:Name="FiveHourResetText" Text="等待快照" Foreground="#F2FFFFFF" FontSize="9.5" FontWeight="SemiBold" TextWrapping="Wrap" LineHeight="14" Margin="0,3,0,0"/>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <Border Grid.Column="1" Margin="5,0,0,0" CornerRadius="18" BorderThickness="1" BorderBrush="#35FFFFFF" Background="#2A142130">
                        <Grid Margin="14,11,14,12">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="22"/>
                                <RowDefinition Height="46"/>
                                <RowDefinition Height="8"/>
                                <RowDefinition Height="24"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <TextBlock Grid.Row="0" Text="1周" Foreground="#F5FFFFFF" FontSize="13" FontWeight="Bold" VerticalAlignment="Center"/>
                            <TextBlock x:Name="WeeklyPercentText" Grid.Row="1" Text="--%" Foreground="#FFFFFFFF" FontFamily="{StaticResource InterfaceDisplayFont}" FontSize="35" FontWeight="Bold" VerticalAlignment="Center"/>
                            <Grid x:Name="WeeklyProgressTrack" Grid.Row="2" Height="7">
                                <Border Background="#55343438" CornerRadius="3.5"/>
                                <Border x:Name="WeeklyCapacityFill" HorizontalAlignment="Left" Width="0" Background="#0A84FF" CornerRadius="3.5"/>
                            </Grid>
                            <TextBlock x:Name="WeeklyUsedText" Grid.Row="3" Text="正在读取额度" Foreground="#CFFFFFFF" FontSize="9.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                            <StackPanel Grid.Row="4" Margin="0,5,0,0">
                                <TextBlock Text="R E S E T" Foreground="#7FFFFFFF" FontSize="7.5" FontWeight="Bold"/>
                                <TextBlock x:Name="WeeklyResetText" Text="等待快照" Foreground="#F2FFFFFF" FontSize="9.5" FontWeight="SemiBold" TextWrapping="Wrap" LineHeight="14" Margin="0,3,0,0"/>
                            </StackPanel>
                        </Grid>
                    </Border>
                </Grid>

                <Grid Grid.Row="2" Margin="0,0,0,0">
                    <Border x:Name="SourceBadge" Background="#242A4E76" CornerRadius="10" Padding="10,5" HorizontalAlignment="Left">
                        <TextBlock x:Name="SourceText" Text="CONNECTING" Foreground="#64AFFF" FontSize="9" FontWeight="Bold"/>
                    </Border>
                    <StackPanel HorizontalAlignment="Right" Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="UPDATED" Foreground="#7FFFFFFF" FontSize="8" FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <TextBlock x:Name="UpdatedText" Text="--:--" Foreground="#F0FFFFFF" FontSize="10" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    </StackPanel>
                </Grid>

                <Button x:Name="AnalyticsButton" Grid.Row="3" Content="查看用量分析  ›" Style="{StaticResource ActionButton}" Margin="0,12,0,0"/>
                <Button x:Name="ResetCreditsButton" Grid.Row="4" Content="查看重置卡  ›" Style="{StaticResource SecondaryActionButton}" Margin="0,8,0,0"/>
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
                        <TextBlock Text="Token 与工作流" Foreground="#F5FFFFFF" FontSize="15" FontWeight="Bold" Margin="0,-1,0,0"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button x:Name="AnalyticsRefreshButton" Style="{StaticResource WindowButton}" Content="↻" ToolTip="刷新统计"/>
                        <Button x:Name="AnalyticsHideButton" Style="{StaticResource WindowButton}" Content="—" ToolTip="收拢为水球"/>
                        <Button x:Name="AnalyticsCloseButton" Style="{StaticResource WindowButton}" Content="×" ToolTip="退出"/>
                    </StackPanel>
                </Grid>

                <Border Grid.Row="1" Margin="0,7,0,4" Padding="12,7" CornerRadius="15" Background="#16FFFFFF" BorderBrush="#28FFFFFF" BorderThickness="1">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0">
                            <TextBlock Text="7  D A Y  T O T A L" Foreground="#8FFFFFFF" FontSize="8" FontWeight="Bold"/>
                            <TextBlock x:Name="SevenDayTotalText" Text="--" Foreground="#FFFFFFFF" FontSize="27" FontWeight="Bold" Margin="0,0,0,0"/>
                        </StackPanel>
                        <StackPanel Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center">
                            <Border Background="#242A4E76" CornerRadius="10" Padding="10,5">
                                <TextBlock x:Name="AnalyticsSourceText" Text="LOCAL · 0 TOKEN" Foreground="#64AFFF" FontSize="9" FontWeight="Bold"/>
                            </Border>
                            <TextBlock x:Name="OfficialRateText" Text="官方额度 --" Foreground="#BFFFFFFF" FontSize="10" HorizontalAlignment="Right" Margin="0,5,2,0"/>
                        </StackPanel>
                    </Grid>
                </Border>

                <UniformGrid Grid.Row="2" Columns="4" Margin="0,4,0,5">
                    <Button x:Name="DailyTabButton" Content="Token" Style="{StaticResource TabButton}"/>
                    <Button x:Name="SkillTabButton" Content="Skill" Style="{StaticResource TabButton}"/>
                    <Button x:Name="AgentTabButton" Content="Agent" Style="{StaticResource TabButton}"/>
                    <Button x:Name="ToolTabButton" Content="Tool" Style="{StaticResource TabButton}" Margin="0"/>
                </UniformGrid>

                <Grid Grid.Row="3">
                    <Border CornerRadius="17" Background="#10000000" BorderBrush="#18FFFFFF" BorderThickness="1" IsHitTestVisible="False"/>
                    <Grid x:Name="DailyPanel">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
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
                        <StackPanel x:Name="WorkflowHintsPanel" Grid.Row="3" Margin="1,6,0,0"/>
                    </Grid>

                    <Grid x:Name="SkillPanel" Visibility="Collapsed">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Grid Grid.Row="0" Margin="1,4,1,7">
                            <TextBlock x:Name="SkillSectionTitle" Text="SKILL · 使用情况" Foreground="#D0FFFFFF" FontSize="10" FontWeight="Bold"/>
                            <TextBlock x:Name="SkillCoverageText" Text="归因覆盖 --" Foreground="#64AFFF" FontSize="9" FontWeight="Bold" HorizontalAlignment="Right"/>
                        </Grid>
                        <UniformGrid Grid.Row="1" Columns="2" Margin="0,0,0,6">
                            <Button x:Name="SkillPrimaryButton" Content="可用 Skill" Style="{StaticResource TabButton}"/>
                            <Button x:Name="SkillChainButton" Content="组合链" Style="{StaticResource TabButton}" Margin="0"/>
                        </UniformGrid>
                        <Grid Grid.Row="2">
                            <ScrollViewer x:Name="SkillPrimaryScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                <StackPanel x:Name="SkillRowsPanel"/>
                            </ScrollViewer>
                            <ScrollViewer x:Name="SkillChainScroll" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                <StackPanel x:Name="SkillChainRowsPanel"/>
                            </ScrollViewer>
                        </Grid>
                        <TextBlock x:Name="SkillHintText" Grid.Row="3" Text="参与 Token 会重复归因；归因覆盖率仍按每个 Turn 只计一次。" Foreground="#8FFFFFFF" FontSize="9" Margin="1,7,0,0" TextWrapping="Wrap"/>
                    </Grid>

                    <Grid x:Name="AgentPanel" Visibility="Collapsed">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Grid Grid.Row="0" Margin="1,4,1,7">
                            <TextBlock Text="AGENT · 使用情况" Foreground="#D0FFFFFF" FontSize="10" FontWeight="Bold"/>
                            <TextBlock x:Name="AgentSummaryText" Text="主/子 Agent" Foreground="#64AFFF" FontSize="9" FontWeight="Bold" HorizontalAlignment="Right"/>
                        </Grid>
                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                            <StackPanel x:Name="AgentRowsPanel"/>
                        </ScrollViewer>
                        <TextBlock Grid.Row="2" Text="主 Agent 按项目显示，子 Agent 按角色显示；这里是本地 Token，不等于官方额度。" Foreground="#8FFFFFFF" FontSize="9" Margin="1,7,0,0" TextWrapping="Wrap"/>
                    </Grid>

                    <Grid x:Name="ToolPanel" Visibility="Collapsed">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Grid Grid.Row="0" Margin="1,4,1,7">
                            <TextBlock Text="TOOL · 本地调用" Foreground="#D0FFFFFF" FontSize="10" FontWeight="Bold"/>
                            <TextBlock x:Name="ToolSummaryText" Text="等待统计" Foreground="#64AFFF" FontSize="9" FontWeight="Bold" HorizontalAlignment="Right"/>
                        </Grid>
                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                            <StackPanel x:Name="ToolRowsPanel"/>
                        </ScrollViewer>
                        <TextBlock x:Name="ToolHintText" Grid.Row="2" Text="仅读取已有本地记录；不调用模型，不连接或探测 MCP Server。" Foreground="#8FFFFFFF" FontSize="9" Margin="1,7,0,0" TextWrapping="Wrap"/>
                    </Grid>

                    <Border x:Name="AnalyticsLoadingPanel" CornerRadius="17" Background="#E80A1420" BorderBrush="#35A9DCFA" BorderThickness="1" Padding="26">
                        <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="260">
                            <Border Width="42" Height="42" CornerRadius="21" Background="#283F9ED8" BorderBrush="#5BCBF0FF" BorderThickness="1" HorizontalAlignment="Center">
                                <TextBlock Text="↻" Foreground="#8DD8FFFF" FontFamily="Segoe UI Symbol" FontSize="20" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <TextBlock x:Name="AnalyticsLoadingTitle" Text="正在整理本地使用记录" Foreground="#F5FFFFFF" FontSize="13" FontWeight="SemiBold" TextAlignment="Center" Margin="0,14,0,0"/>
                            <TextBlock x:Name="AnalyticsLoadingText" Text="仅汇总本机已有记录，首次打开可能需要几秒。" Foreground="#96D6E8F2" FontSize="9.5" TextAlignment="Center" TextWrapping="Wrap" LineHeight="15" Margin="0,7,0,0"/>
                        </StackPanel>
                    </Border>
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

        <Grid x:Name="AccountFlyoutLayer" Visibility="Collapsed" Background="Transparent">
            <Border Width="354" MaxHeight="452" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="14"
                    CornerRadius="26" BorderThickness="1.25" BorderBrush="{StaticResource AccountGlassEdgeBrush}"
                    Background="{StaticResource AccountGlassSurfaceBrush}" ClipToBounds="True">
                <Border.Effect>
                    <DropShadowEffect Color="#020812" BlurRadius="34" ShadowDepth="9" Opacity="0.72"/>
                </Border.Effect>
                <Grid Margin="19,16,19,17">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <Border Grid.RowSpan="5" Margin="-10,-8,-10,-9" CornerRadius="21" Background="{StaticResource AccountGlassGlowBrush}" Opacity="0.92" IsHitTestVisible="False"/>
                    <Border Grid.RowSpan="5" Margin="-10,-8,-10,-9" CornerRadius="21" Background="{StaticResource GlassSpecularBrush}" Opacity="0.78" IsHitTestVisible="False"/>
                    <Border Grid.RowSpan="5" Margin="-10,-8,-10,-9" CornerRadius="21" Background="{StaticResource GlassTexture}" Opacity="0.16" IsHitTestVisible="False"/>
                    <Border Grid.RowSpan="5" Margin="-7,-5,-7,-6" CornerRadius="19" BorderThickness="1" BorderBrush="#62D6F2FF" IsHitTestVisible="False"/>
                    <Border Grid.RowSpan="5" Margin="-4,-2,-4,-3" CornerRadius="17" BorderThickness="1" BorderBrush="#26020B12" IsHitTestVisible="False"/>

                    <Grid Grid.Row="0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0" Margin="8,6,12,2">
                            <TextBlock Text="A C C O U N T   S W I T C H E R" Foreground="#B6E5F7FF" FontFamily="Segoe UI" FontSize="7.5" FontWeight="Bold"/>
                            <TextBlock Text="账号与配置" Foreground="#FFFFFFFF" FontSize="16" FontWeight="Bold" Margin="0,3,0,0"/>
                        </StackPanel>
                        <Button x:Name="AccountFlyoutCloseButton" Grid.Column="1" Style="{StaticResource WindowButton}" Content="×" Background="#1FFFFFFF" Foreground="#D8F5FCFF" Margin="3,3,1,0" HorizontalAlignment="Right" VerticalAlignment="Top" ToolTip="关闭"/>
                    </Grid>

                    <Border Grid.Row="1" Margin="0,12,0,11" Padding="12,9" CornerRadius="14" Background="#3B5FA4B4" BorderBrush="#8DE8F8FF" BorderThickness="1">
                        <TextBlock x:Name="ActiveIdentityText" Text="尚未登记当前账号" Foreground="#F2F8FDFF" FontSize="10" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                    </Border>

                    <ScrollViewer Grid.Row="2" MaxHeight="272" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel>
                            <TextBlock Text="CHATGPT 账号" Foreground="#A8CFEFFF" FontSize="8" FontWeight="Bold" Margin="2,0,0,7"/>
                            <StackPanel x:Name="ChatGptAccountsPanel"/>
                            <TextBlock Text="自定义配置" Foreground="#A8CFEFFF" FontSize="8" FontWeight="Bold" Margin="2,11,0,7"/>
                            <StackPanel x:Name="CustomAccountsPanel"/>
                        </StackPanel>
                    </ScrollViewer>

                    <ScrollViewer Grid.Row="3" MaxHeight="58" Margin="2,8,2,0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <TextBlock x:Name="AccountFlyoutStatusText" Text="" Foreground="#C6E7F5FF" FontSize="9" Margin="0,1,4,1" TextWrapping="Wrap"/>
                    </ScrollViewer>

                    <Grid Grid.Row="4" Margin="0,11,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Button x:Name="SaveCurrentAccountButton" Grid.Column="0" Content="保存当前" Style="{StaticResource ActionButton}" Background="#3A5A91AC" BorderBrush="#7BCDEEFF" Height="31" FontSize="9" Margin="0,0,4,0"/>
                        <Button x:Name="AddAccountButton" Grid.Column="1" Content="添加账号" Style="{StaticResource ActionButton}" Background="#3A5A91AC" BorderBrush="#7BCDEEFF" Height="31" FontSize="9" Margin="4,0,4,0"/>
                        <Button x:Name="ImportCustomButton" Grid.Column="2" Content="导入配置" Style="{StaticResource ActionButton}" Background="#3A5A91AC" BorderBrush="#7BCDEEFF" Height="31" FontSize="9" Margin="4,0,0,0"/>
                    </Grid>
                </Grid>
            </Border>
        </Grid>
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
$OrbAtmosphereFill = $window.FindName('OrbAtmosphereFill')
$OrbWaterFill = $window.FindName('OrbWaterFill')
$OrbWaterGloss = $window.FindName('OrbWaterGloss')
$OrbWaterSheen = $window.FindName('OrbWaterSheen')
$OrbWaveBack = $window.FindName('OrbWaveBack')
$OrbWaveShade = $window.FindName('OrbWaveShade')
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
$FiveHourFallbackText = $window.FindName('FiveHourFallbackText')
$FiveHourUsedText = $window.FindName('FiveHourUsedText')
$ProgressTrack = $window.FindName('ProgressTrack')
$CapacityFill = $window.FindName('CapacityFill')
$FiveHourResetText = $window.FindName('FiveHourResetText')
$WeeklyPercentText = $window.FindName('WeeklyPercentText')
$WeeklyUsedText = $window.FindName('WeeklyUsedText')
$WeeklyProgressTrack = $window.FindName('WeeklyProgressTrack')
$WeeklyCapacityFill = $window.FindName('WeeklyCapacityFill')
$WeeklyResetText = $window.FindName('WeeklyResetText')
$UpdatedText = $window.FindName('UpdatedText')
$AnalyticsButton = $window.FindName('AnalyticsButton')
$ResetCreditsButton = $window.FindName('ResetCreditsButton')
$AccountSwitchButton = $window.FindName('AccountSwitchButton')
$OrbStyleToggleButton = $window.FindName('OrbStyleToggleButton')
$ClassicStyleDot = $window.FindName('ClassicStyleDot')
$GradientStyleDot = $window.FindName('GradientStyleDot')
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
$ToolTabButton = $window.FindName('ToolTabButton')
$DailyPanel = $window.FindName('DailyPanel')
$SkillPanel = $window.FindName('SkillPanel')
$AgentPanel = $window.FindName('AgentPanel')
$ToolPanel = $window.FindName('ToolPanel')
$DailyRowsPanel = $window.FindName('DailyRowsPanel')
$SkillRowsPanel = $window.FindName('SkillRowsPanel')
$SkillChainRowsPanel = $window.FindName('SkillChainRowsPanel')
$AgentRowsPanel = $window.FindName('AgentRowsPanel')
$ToolRowsPanel = $window.FindName('ToolRowsPanel')
$AgentSummaryText = $window.FindName('AgentSummaryText')
$ToolSummaryText = $window.FindName('ToolSummaryText')
$ToolHintText = $window.FindName('ToolHintText')
$AnalyticsLoadingPanel = $window.FindName('AnalyticsLoadingPanel')
$AnalyticsLoadingTitle = $window.FindName('AnalyticsLoadingTitle')
$AnalyticsLoadingText = $window.FindName('AnalyticsLoadingText')
$WorkflowHintsPanel = $window.FindName('WorkflowHintsPanel')
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
$AccountFlyoutLayer = $window.FindName('AccountFlyoutLayer')
$AccountFlyoutCloseButton = $window.FindName('AccountFlyoutCloseButton')
$ActiveIdentityText = $window.FindName('ActiveIdentityText')
$ChatGptAccountsPanel = $window.FindName('ChatGptAccountsPanel')
$CustomAccountsPanel = $window.FindName('CustomAccountsPanel')
$AccountFlyoutStatusText = $window.FindName('AccountFlyoutStatusText')
$SaveCurrentAccountButton = $window.FindName('SaveCurrentAccountButton')
$AddAccountButton = $window.FindName('AddAccountButton')
$ImportCustomButton = $window.FindName('ImportCustomButton')

$script:ClassicOrbVisuals = [pscustomobject]@{
    AtmosphereFill   = $OrbAtmosphereFill.Fill.Clone()
    WaterFill        = $OrbWaterFill.Fill.Clone()
    WaterGloss       = $OrbWaterGloss.Fill.Clone()
    WaterSheen       = $OrbWaterSheen.Fill.Clone()
    WaveBackStroke   = $OrbWaveBack.Stroke.Clone()
    WaveBackFill     = $OrbWaveBack.Fill.Clone()
    WaveShadeStroke  = $OrbWaveShade.Stroke.Clone()
    WaveFrontStroke  = $OrbWaveFront.Stroke.Clone()
    WaveFrontFill    = $OrbWaveFront.Fill.Clone()
    PercentForeground = $OrbPercentText.Foreground.Clone()
    PercentEffect    = $OrbPercentText.Effect.Clone()
}

function New-Brush {
    param([string]$Color)
    return [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($Color))
}

function Set-AccountBackdropBlur {
    param([bool]$Enabled)
    # The chooser is its own compact surface. Hide the quota card completely
    # while it is open so no rectangular backdrop remains around the flyout.
    if ($Enabled) {
        $GlowBorder.Visibility = 'Collapsed'
    } elseif ($script:ViewMode -eq 'capacity') {
        $GlowBorder.Visibility = 'Visible'
    }
}

function Quote-WorkerArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Format-AccountOperationError {
    param([AllowNull()][string]$Message)
    if (-not $Message) { return '账号操作失败，请重试。' }
    if ($Message -match '(?i)invalidated oauth token|401 Unauthorized|access token could not be refreshed|logged out|signed in to another account|登录已失效') {
        return '该账号的登录已失效。请点击该账号旁的“重新认证”。'
    }
    if ($Message -match '(?i)ParameterArgumentValidationErrorEmptyArrayNotAllowed|参数.*Threads|empty array') {
        return '当前没有需要续接的终端会话。请重新点击目标账号完成切换。'
    }

    $candidate = @($Message -split '\r?\n' | Where-Object {
        $_.Trim() -and $_ -notmatch '^\s*(At |所在位置|\+ |~+|CategoryInfo|FullyQualifiedErrorId)'
    } | Select-Object -First 1)
    $friendly = if ($candidate.Count -gt 0) { [string]$candidate[0].Trim() } else { '账号操作失败，请重试。' }
    $friendly = $friendly -replace '^\s*(Switch-CqoIdentity|Save-CqoCurrentChatGptAccount|Import-CqoCustomProfile)\s*:\s*', ''
    if ($friendly.Length -gt 180) { $friendly = $friendly.Substring(0, 177) + '…' }
    return $friendly
}

function Format-IdentityQuota {
    param(
        $Identity,
        [bool]$IsActive = $false
    )
    if ([string]$Identity.kind -eq 'custom') {
        $model = if ($Identity.PSObject.Properties.Name -contains 'model' -and $Identity.model) { [string]$Identity.model } else { '自定义模型' }
        return ($model + ' · 不监控额度')
    }
    if ($IsActive -and $script:FiveHourSnapshot) {
        $weekly = if ($script:WeeklySnapshot) { [double]$script:WeeklySnapshot.Remaining } else { [double]$script:FiveHourSnapshot.Remaining }
        return ('实时 · 5h {0:0}% · 1周 {1:0}%' -f [double]$script:FiveHourSnapshot.Remaining, $weekly)
    }
    if (-not $Identity.quota) {
        return $(if ($Identity.planType) { ([string]$Identity.planType).ToUpperInvariant() + ' · 尚无额度缓存' } else { '尚无额度缓存' })
    }

    $parts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Identity.quota.primaryRemaining) { $parts.Add(('5h {0:0}%' -f [double]$Identity.quota.primaryRemaining)) }
    if ($null -ne $Identity.quota.secondaryRemaining) { $parts.Add(('1周 {0:0}%' -f [double]$Identity.quota.secondaryRemaining)) }
    $observed = $null
    try { $observed = [DateTimeOffset]::Parse([string]$Identity.quota.observedAt).ToLocalTime() } catch {}
    $quotaText = if ($parts.Count -gt 0) { $parts -join ' · ' } else { '额度缓存不可用' }
    if ($observed) { $quotaText += (' · {0:MM/dd HH:mm}' -f $observed.LocalDateTime) }
    return $quotaText
}

function New-IdentityChoiceButton {
    param(
        [Parameter(Mandatory = $true)]$Identity,
        [Parameter(Mandatory = $true)][bool]$IsActive
    )

    $button = New-Object System.Windows.Controls.Button
    $button.Style = $window.FindResource('ActionButton')
    $button.Height = 53
    $button.Margin = New-Object System.Windows.Thickness(0, 0, 0, 7)
    $button.Padding = New-Object System.Windows.Thickness(12, 7, 10, 7)
    $button.HorizontalContentAlignment = 'Stretch'
    $button.Tag = [string]$Identity.id
    $needsReauth = [string]$Identity.kind -eq 'chatgpt' -and
        ($Identity.PSObject.Properties.Name -contains 'reauthRequired') -and [bool]$Identity.reauthRequired
    # Keep account rows in the same glass palette as the flyout.  The previous
    # opaque gray fills made the active identity look almost identical to an
    # inactive row, especially against the dark flyout surface.
    $button.Background = New-Brush $(if ($IsActive) { '#4A63C4D8' } else { '#201B3A4D' })
    $button.BorderBrush = New-Brush $(if ($IsActive) { '#C7F3FFFF' } else { '#477EAEC5' })

    $grid = New-Object System.Windows.Controls.Grid
    $activeColumn = New-Object System.Windows.Controls.ColumnDefinition
    $activeColumn.Width = 'Auto'
    $mainColumn = New-Object System.Windows.Controls.ColumnDefinition
    $mainColumn.Width = '*'
    $stateColumn = New-Object System.Windows.Controls.ColumnDefinition
    $stateColumn.Width = 'Auto'
    [void]$grid.ColumnDefinitions.Add($activeColumn)
    [void]$grid.ColumnDefinitions.Add($mainColumn)
    [void]$grid.ColumnDefinitions.Add($stateColumn)

    if ($IsActive) {
        $activeMark = New-Object System.Windows.Controls.Border
        $activeMark.Width = 3
        $activeMark.Height = 30
        $activeMark.CornerRadius = New-Object System.Windows.CornerRadius(2)
        $activeMark.Background = New-Brush '#D5F8FFFF'
        $activeMark.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
        $activeMark.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($activeMark, 0)
        [void]$grid.Children.Add($activeMark)
    }

    $stack = New-Object System.Windows.Controls.StackPanel
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = [string]$Identity.label
    $title.Foreground = New-Brush '#F8FFFFFF'
    $title.FontSize = 11
    $title.FontWeight = [System.Windows.FontWeights]::SemiBold
    $title.TextTrimming = 'CharacterEllipsis'
    $detail = New-Object System.Windows.Controls.TextBlock
    $detail.Text = Format-IdentityQuota -Identity $Identity -IsActive $IsActive
    $detail.Foreground = New-Brush '#C4DDEBF2'
    $detail.FontSize = 8.5
    $detail.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
    $detail.TextTrimming = 'CharacterEllipsis'
    [void]$stack.Children.Add($title)
    [void]$stack.Children.Add($detail)
    [System.Windows.Controls.Grid]::SetColumn($stack, 1)
    [void]$grid.Children.Add($stack)

    $state = New-Object System.Windows.Controls.TextBlock
    $state.Text = if ($needsReauth) { '需认证' } elseif ($IsActive) { '已登录' } else { '切换' }
    $state.Foreground = New-Brush $(if ($IsActive) { '#C8F4FFFF' } else { '#8BD8FFFF' })
    $state.FontSize = 9
    $state.FontWeight = [System.Windows.FontWeights]::Bold
    $state.VerticalAlignment = 'Center'
    $state.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
    [System.Windows.Controls.Grid]::SetColumn($state, 2)
    [void]$grid.Children.Add($state)
    $button.Content = $grid
    $button.Add_Click({
        param($sender, $eventArgs)
        $registry = Get-CqoAccountRegistry -Store $script:AccountStore
        $chosen = @($registry.accounts | Where-Object { [string]$_.id -eq [string]$sender.Tag } | Select-Object -First 1)
        if ($chosen.Count -gt 0 -and
            ($chosen[0].PSObject.Properties.Name -contains 'reauthRequired') -and [bool]$chosen[0].reauthRequired) {
            Start-AccountRegistration -IdentityId ([string]$sender.Tag)
        } elseif ([string]$sender.Tag -eq [string]$registry.activeId) {
            Start-ManagedResumeWindow -IdentityId ([string]$sender.Tag)
        } else {
            Start-AccountWorker -Action 'switch' -IdentityId ([string]$sender.Tag)
        }
        $eventArgs.Handled = $true
    })
    if ([string]$Identity.kind -ne 'chatgpt') { return $button }

    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 7)
    $mainColumn = New-Object System.Windows.Controls.ColumnDefinition
    $mainColumn.Width = '*'
    $verifyColumn = New-Object System.Windows.Controls.ColumnDefinition
    $verifyColumn.Width = 'Auto'
    [void]$row.ColumnDefinitions.Add($mainColumn)
    [void]$row.ColumnDefinitions.Add($verifyColumn)
    $button.Margin = New-Object System.Windows.Thickness(0)
    [System.Windows.Controls.Grid]::SetColumn($button, 0)
    [void]$row.Children.Add($button)

    $verify = New-Object System.Windows.Controls.Button
    $verify.Style = $window.FindResource('ActionButton')
    $verify.Content = if ($needsReauth) { '重新认证' } else { '验证' }
    $verify.ToolTip = '打开官方 Codex 登录页面，重新认证并切换到此账号'
    $verify.Tag = [string]$Identity.id
    $verify.Width = 72
    $verify.Height = 53
    $verify.FontSize = 9
    $verify.Margin = New-Object System.Windows.Thickness(6, 0, 0, 0)
    $verify.Background = New-Brush $(if ($needsReauth) { '#475D748B' } else { '#20375870' })
    $verify.BorderBrush = New-Brush $(if ($needsReauth) { '#A7E5FFFF' } else { '#477EAEC5' })
    $verify.Add_Click({
        param($sender, $eventArgs)
        Start-AccountRegistration -IdentityId ([string]$sender.Tag)
        $eventArgs.Handled = $true
    })
    [System.Windows.Controls.Grid]::SetColumn($verify, 1)
    [void]$row.Children.Add($verify)
    return $row
}

function Add-IdentityEmptyState {
    param(
        [Parameter(Mandatory = $true)]$Panel,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $empty = New-Object System.Windows.Controls.TextBlock
    $empty.Text = $Text
    $empty.Foreground = New-Brush '#78FFFFFF'
    $empty.FontSize = 9
    $empty.Margin = New-Object System.Windows.Thickness(2, 4, 0, 5)
    [void]$Panel.Children.Add($empty)
}

function Refresh-AccountFlyout {
    param([switch]$ClearStatus)

    $ChatGptAccountsPanel.Children.Clear()
    $CustomAccountsPanel.Children.Clear()
    if ($ClearStatus) { $AccountFlyoutStatusText.Text = '' }
    if (-not $script:AccountStore) {
        $ActiveIdentityText.Text = '账号切换模块不可用'
        Add-IdentityEmptyState -Panel $ChatGptAccountsPanel -Text '安装文件不完整'
        Add-IdentityEmptyState -Panel $CustomAccountsPanel -Text '安装文件不完整'
        return
    }

    try {
        $registry = if ($QARenderPath -and $QAView -eq 'account') {
            $qaNow = [DateTimeOffset]::Now
            [pscustomobject]@{
                activeId = 'qa-primary'
                accounts = @(
                    [pscustomobject]@{ id = 'qa-primary'; kind = 'chatgpt'; label = '主账号 · Plus'; planType = 'plus'; quota = $null },
                    [pscustomobject]@{ id = 'qa-secondary'; kind = 'chatgpt'; label = '备用账号 · Plus'; planType = 'plus'; reauthRequired = $true; quota = [pscustomobject]@{ primaryRemaining = 82; secondaryRemaining = 47; observedAt = $qaNow.AddMinutes(-18).ToString('o') } },
                    [pscustomobject]@{ id = 'qa-custom'; kind = 'custom'; label = '自定义服务'; model = 'gpt-5.6-sol'; quota = $null }
                )
            }
        } else {
            Get-CqoAccountRegistry -Store $script:AccountStore
        }
        $accounts = @($registry.accounts)
        $activeId = if ($script:IsAccountIdentityVerifying) { $null } else { [string]$registry.activeId }
        $active = @($accounts | Where-Object { [string]$_.id -eq $activeId }) | Select-Object -First 1
        $ActiveIdentityText.Text = if ($script:IsAccountIdentityVerifying) {
            '正在核对当前 Codex 身份…'
        } elseif ($active) {
            '当前：' + [string]$active.label
        } else {
            '尚未登记当前账号'
        }
        $AccountSwitchButton.ToolTip = if ($active) { '当前身份：' + [string]$active.label } else { '切换账号或配置' }

        $chatgpt = @($accounts | Where-Object { [string]$_.kind -eq 'chatgpt' })
        $custom = @($accounts | Where-Object { [string]$_.kind -eq 'custom' })
        foreach ($identity in $chatgpt) {
            [void]$ChatGptAccountsPanel.Children.Add((New-IdentityChoiceButton -Identity $identity -IsActive ([string]$identity.id -eq $activeId)))
        }
        foreach ($identity in $custom) {
            [void]$CustomAccountsPanel.Children.Add((New-IdentityChoiceButton -Identity $identity -IsActive ([string]$identity.id -eq $activeId)))
        }
        if ($chatgpt.Count -eq 0) { Add-IdentityEmptyState -Panel $ChatGptAccountsPanel -Text '先保存当前包月账号，再添加第二个账号' }
        if ($custom.Count -eq 0) { Add-IdentityEmptyState -Panel $CustomAccountsPanel -Text '尚未导入 auth.json + config.toml' }
    } catch {
        $ActiveIdentityText.Text = '读取账号列表失败'
        $AccountFlyoutStatusText.Text = '失败：' + (Format-AccountOperationError -Message $_.Exception.Message)
    }
}

function Show-AccountFlyout {
    $script:IsAccountIdentityVerifying = $true
    Refresh-AccountFlyout -ClearStatus
    if ($script:ViewMode -eq 'capacity') {
        Resize-WindowAroundCenter -Width 382 -Height 480
    }
    Set-AccountBackdropBlur $true
    $AccountFlyoutLayer.Visibility = 'Visible'
    $AccountFlyoutStatusText.Text = '正在同步当前 Codex 会话…'
    Set-AccountControlsEnabled $false
    Start-DirectRefreshAsync
    [void]$AccountFlyoutCloseButton.Focus()
}

function Hide-AccountFlyout {
        $AccountFlyoutLayer.Visibility = 'Collapsed'
        Set-AccountBackdropBlur $false
        if ($script:ViewMode -eq 'capacity') {
            Resize-WindowAroundCenter -Width 420 -Height 410
        }
}

function Set-AccountControlsEnabled {
    param([bool]$Enabled)
    $ChatGptAccountsPanel.IsEnabled = $Enabled
    $CustomAccountsPanel.IsEnabled = $Enabled
    $SaveCurrentAccountButton.IsEnabled = $Enabled
    $AddAccountButton.IsEnabled = $Enabled
    $ImportCustomButton.IsEnabled = $Enabled
    $AccountFlyoutCloseButton.IsEnabled = $true
}

function Complete-AccountIdentityVerification {
    param([bool]$Resolved)
    if (-not $script:IsAccountIdentityVerifying) { return }
    $script:IsAccountIdentityVerifying = $false
    if ($AccountFlyoutLayer.Visibility -ne [System.Windows.Visibility]::Visible) { return }
    Refresh-AccountFlyout
    $AccountFlyoutStatusText.Text = if ($Resolved) {
        '已与当前 Codex 会话同步。'
    } else {
        '暂时无法确认当前会话；显示最近一次已选择的身份。'
    }
    Set-AccountControlsEnabled $true
}

function Get-WorkerOutputState {
    param($Worker, $OutputTask, $ErrorTask, [switch]$ResultLine)
    if ($ResultLine -and $OutputTask.IsCompleted) { return 'ready' }
    if ($OutputTask.IsCompleted -and $ErrorTask.IsCompleted) { return 'ready' }
    # An exited worker can leave its pipe open in a descendant. Never wait on
    # that pipe on WPF's dispatcher, even after HasExited becomes true.
    if (([DateTime]::Now - $Worker.ExitTime).TotalSeconds -ge 5) { return 'timeout' }
    return 'pending'
}

function Start-AccountWorker {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('capture', 'switch', 'import-custom')][string]$Action,
        [string]$IdentityId,
        [string]$ImportDirectory
    )
    if ($script:AccountWorkerProcess -or $script:AccountRegistrationProcess) { return }

    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File {0} -AccountWorker -AccountAction {1}' -f `
        (Quote-WorkerArgument $script:ScriptPath), $Action
    if ($IdentityId) { $arguments += ' -AccountId ' + (Quote-WorkerArgument $IdentityId) }
    if ($ImportDirectory) { $arguments += ' -AccountImportDirectory ' + (Quote-WorkerArgument $ImportDirectory) }

    $workerInfo = New-Object System.Diagnostics.ProcessStartInfo
    $workerInfo.FileName = (Get-Command powershell.exe).Source
    $workerInfo.Arguments = $arguments
    $workerInfo.UseShellExecute = $false
    $workerInfo.CreateNoWindow = $true
    $workerInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $workerInfo.RedirectStandardOutput = $true
    $workerInfo.RedirectStandardError = $true
    $workerInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $worker = New-Object System.Diagnostics.Process
    $worker.StartInfo = $workerInfo
    [void]$worker.Start()
    $script:AccountWorkerProcess = $worker
    $script:AccountWorkerOutputTask = $worker.StandardOutput.ReadLineAsync()
    $script:AccountWorkerErrorTask = $worker.StandardError.ReadToEndAsync()
    $script:AccountWorkerAction = $Action
    $script:AccountWorkerIdentityId = $IdentityId
    $AccountFlyoutStatusText.Text = switch ($Action) {
        'capture' { '正在加密保存当前账号…' }
        'switch' { '正在暂停任务并切换身份…' }
        default { '正在验证并导入配置…' }
    }
    Set-AccountControlsEnabled $false
}

function Start-ManagedResumeWindow {
    param(
        $Plan,
        [Parameter(Mandatory = $true)][string]$IdentityId
    )
    $resumeDirectory = Join-Path $script:RuntimeDir 'resume'
    if (-not (Test-Path -LiteralPath $resumeDirectory)) {
        New-Item -ItemType Directory -Path $resumeDirectory -Force | Out-Null
    }
    $promptPath = $null
    if ($Plan -and $Plan.prompt) {
        $promptPath = Join-Path $resumeDirectory ([Guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $promptPath -Value ([string]$Plan.prompt) -Encoding UTF8 -NoNewline
    }
    $helper = Join-Path $script:ScriptDir 'Resume-CodexSession.ps1'
    $argumentLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File {0} -IdentityId {1} -RuntimeDirectory {2} -CodexHome {3}' -f `
        (Quote-WorkerArgument $helper), (Quote-WorkerArgument $IdentityId), (Quote-WorkerArgument $script:RuntimeDir), (Quote-WorkerArgument $script:CodexHome)
    if ($Plan -and $Plan.threadId) { $argumentLine += ' -SessionId ' + (Quote-WorkerArgument ([string]$Plan.threadId)) }
    if ($promptPath) { $argumentLine += ' -PromptPath ' + (Quote-WorkerArgument $promptPath) }
    if ($Plan -and $Plan.cwd) { $argumentLine += ' -WorkingDirectory ' + (Quote-WorkerArgument ([string]$Plan.cwd)) }
    Start-CqoVisibleTerminal -PowerShellArguments $argumentLine
}

function Start-CqoVisibleTerminal {
    param([Parameter(Mandatory = $true)][string]$PowerShellArguments)

    $powershellPath = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source
    $windowsTerminal = Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($windowsTerminal) {
        $terminalArguments = '-w new -- {0} {1}' -f `
            (Quote-WorkerArgument $powershellPath), $PowerShellArguments
        try {
            Start-Process -FilePath $windowsTerminal.Source -ArgumentList $terminalArguments | Out-Null
            return
        } catch {
            Write-Diagnostic ('Windows Terminal launch failed; using PowerShell: ' + $_.Exception.Message)
        }
    }

    Start-Process -FilePath $powershellPath -ArgumentList $PowerShellArguments -WindowStyle Normal | Out-Null
}

function Complete-AccountWorkerIfReady {
    $worker = $script:AccountWorkerProcess
    if (-not $worker -or -not $worker.HasExited) { return }
    $outputState = Get-WorkerOutputState $worker $script:AccountWorkerOutputTask $script:AccountWorkerErrorTask -ResultLine
    if ($outputState -eq 'pending') { return }
    $switchCompleted = $false
    $reauthId = $null
    try {
        if ($outputState -eq 'timeout') { throw '账号操作已结束，但结果管道未关闭。请刷新账号列表后检查当前身份。' }
        $output = [string]$script:AccountWorkerOutputTask.Result
        if (-not $output) { throw '账号操作未返回结果。' }
        $wire = $output | ConvertFrom-Json
        if (-not $wire.success) {
            if ($script:AccountWorkerAction -eq 'switch' -and $script:AccountWorkerIdentityId -and
                [string]$wire.error -match '登录已失效|凭据与登记信息不一致|加密凭据不存在') {
                $reauthId = [string]$script:AccountWorkerIdentityId
            }
            throw [string]$wire.error
        }
        $result = $wire.result
        if ($script:AccountWorkerAction -eq 'switch' -and $result -and $result.recoveryPlans) {
            $recoveryFailures = 0
            foreach ($plan in @($result.recoveryPlans)) {
                try {
                    Start-ManagedResumeWindow -Plan $plan -IdentityId ([string]$result.recoveryId)
                } catch {
                    $recoveryFailures++
                    Write-Diagnostic ('Unable to reopen a rolled-back session: ' + $_.Exception.Message)
                }
            }
            $reason = Format-AccountOperationError -Message ([string]$result.error)
            $AccountFlyoutStatusText.Text = if ($recoveryFailures -gt 0) {
                '切换失败：' + $reason + '；原账号已恢复，部分会话需手动重新打开。'
            } else {
                '切换失败：' + $reason + '；已恢复原账号并重新打开会话。'
            }
        } elseif ($script:AccountWorkerAction -eq 'switch' -and $result -and $result.identity) {
            # The credential/daemon transaction is already complete at this
            # point. Opening a visible continuation is a follow-up action and
            # must not turn a successful account switch into an error banner.
            $switchCompleted = $true
            $resumeFailures = 0
            foreach ($plan in @($result.threads)) {
                try {
                    Start-ManagedResumeWindow -Plan $plan -IdentityId ([string]$result.identity.id)
                } catch {
                    $resumeFailures++
                    Write-Diagnostic ('Unable to reopen a switched session: ' + $_.Exception.Message)
                }
            }
            $AccountFlyoutStatusText.Text = if ($resumeFailures -gt 0) {
                '账号已切换；部分会话未能自动打开，请手动启动 Codex。'
            } elseif (@($result.threads).Count -gt 0) {
                '切换完成，已打开会话续接窗口。'
            } else {
                '账号切换完成。'
            }
            $script:QuotaSwitchPrompted = $false
            Start-DirectRefreshAsync
            Start-AnalyticsRefreshAsync
        } elseif ($script:AccountWorkerAction -eq 'capture') {
            $AccountFlyoutStatusText.Text = '当前账号已加密保存。'
        } elseif ($script:AccountWorkerAction -eq 'import-custom') {
            $AccountFlyoutStatusText.Text = '自定义配置已安全导入。'
        }
        Refresh-AccountFlyout
    } catch {
        $AccountFlyoutStatusText.Text = if ($switchCompleted) {
            '账号已切换；界面刷新未完成，请重新打开账号面板确认当前身份。'
        } else {
            '失败：' + (Format-AccountOperationError -Message $_.Exception.Message)
        }
        Refresh-AccountFlyout
    } finally {
        $worker.Dispose()
        $script:AccountWorkerProcess = $null
        $script:AccountWorkerOutputTask = $null
        $script:AccountWorkerErrorTask = $null
        $script:AccountWorkerAction = $null
        $script:AccountWorkerIdentityId = $null
        Set-AccountControlsEnabled $true
    }
    if ($reauthId) {
        try {
            Start-AccountRegistration -IdentityId $reauthId
        } catch {
            $AccountFlyoutStatusText.Text = '无法打开重新认证窗口：' + (Format-AccountOperationError -Message $_.Exception.Message)
        }
    }
}

function Start-AccountRegistration {
    param([string]$IdentityId)
    if ($script:AccountRegistrationProcess -or $script:AccountWorkerProcess) { return }
    $helper = Join-Path $script:ScriptDir 'Register-CodexAccount.ps1'
    $argumentLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File {0} -RuntimeDirectory {1} -CodexHome {2}' -f `
        (Quote-WorkerArgument $helper), (Quote-WorkerArgument $script:RuntimeDir), (Quote-WorkerArgument $script:CodexHome)
    if ($IdentityId) { $argumentLine += ' -IdentityId ' + (Quote-WorkerArgument $IdentityId) }
    $script:AccountRegistrationProcess = Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList $argumentLine -PassThru
    $script:AccountRegistrationIdentityId = $IdentityId
    $AccountFlyoutStatusText.Text = if ($IdentityId) {
        '请在新窗口用所选账号完成官方登录；验证后将自动切换并续接会话。'
    } else {
        '请在新窗口完成官方 ChatGPT 登录…'
    }
    Set-AccountControlsEnabled $false
}

function Complete-AccountRegistrationIfReady {
    $process = $script:AccountRegistrationProcess
    if (-not $process -or -not $process.HasExited) { return }
    try {
        $AccountFlyoutStatusText.Text = if ($process.ExitCode -eq 0) {
            if ($script:AccountRegistrationIdentityId) { '账号已重新认证并切换。' } else { '新账号已登记。' }
        } else {
            if ($script:AccountRegistrationIdentityId) { '重新认证未完成；原账号保持不变。' } else { '账号登记未完成，已恢复原账号。' }
        }
        Refresh-AccountFlyout
        Start-DirectRefreshAsync
    } finally {
        $process.Dispose()
        $script:AccountRegistrationProcess = $null
        $script:AccountRegistrationIdentityId = $null
        Set-AccountControlsEnabled $true
    }
}

function ConvertTo-OrbColor {
    param([string]$Color)
    return [System.Windows.Media.ColorConverter]::ConvertFromString($Color)
}

function Mix-OrbColor {
    param(
        [System.Windows.Media.Color]$From,
        [System.Windows.Media.Color]$To,
        [double]$Amount,
        [byte]$Alpha = 255
    )

    $mix = [Math]::Max(0.0, [Math]::Min(1.0, $Amount))
    $red = [byte][Math]::Round($From.R + (($To.R - $From.R) * $mix))
    $green = [byte][Math]::Round($From.G + (($To.G - $From.G) * $mix))
    $blue = [byte][Math]::Round($From.B + (($To.B - $From.B) * $mix))
    return [System.Windows.Media.Color]::FromArgb($Alpha, $red, $green, $blue)
}

function Get-OrbThemeColor {
    param([double]$Remaining)

    $level = [Math]::Max(0.0, [Math]::Min(100.0, $Remaining))
    for ($index = 0; $index -lt ($script:OrbThemeAnchors.Count - 1); $index++) {
        $lower = $script:OrbThemeAnchors[$index]
        $upper = $script:OrbThemeAnchors[$index + 1]
        if ($level -le [double]$upper.Remaining) {
            $span = [double]$upper.Remaining - [double]$lower.Remaining
            $amount = if ($span -gt 0) { ($level - [double]$lower.Remaining) / $span } else { 0.0 }
            return Mix-OrbColor (ConvertTo-OrbColor $lower.Color) (ConvertTo-OrbColor $upper.Color) $amount
        }
    }

    return ConvertTo-OrbColor $script:OrbThemeAnchors[-1].Color
}

function Set-OrbTheme {
    param([double]$Remaining)

    $theme = Get-OrbThemeColor $Remaining
    $white = [System.Windows.Media.Colors]::White
    $black = [System.Windows.Media.Colors]::Black

    $atmosphereStops = $OrbAtmosphereFill.Fill.GradientStops
    $atmosphereStops[0].Color = Mix-OrbColor $theme $white 0.50 136
    $atmosphereStops[1].Color = Mix-OrbColor $theme $white 0.16 168
    $atmosphereStops[2].Color = Mix-OrbColor $theme $black 0.26 184

    $waterStops = $OrbWaterFill.Fill.GradientStops
    $waterStops[0].Color = Mix-OrbColor $theme $white 0.42 176
    $waterStops[1].Color = Mix-OrbColor $theme $white 0.08 207
    $waterStops[2].Color = Mix-OrbColor $theme $black 0.34 229
    $waterStops[3].Color = Mix-OrbColor $theme $black 0.57 240

    $glossStops = $OrbWaterGloss.Fill.GradientStops
    $glossStops[0].Color = Mix-OrbColor $theme $white 0.72 112
    $glossStops[1].Color = Mix-OrbColor $theme $white 0.24 64
    $glossStops[2].Color = Mix-OrbColor $theme $black 0.20 36
    $glossStops[3].Color = Mix-OrbColor $theme $black 0.52 0

    $sheenStops = $OrbWaterSheen.Fill.GradientStops
    $sheenStops[0].Color = Mix-OrbColor $theme $white 0.64 56
    $sheenStops[1].Color = Mix-OrbColor $theme $white 0.08 36
    $sheenStops[2].Color = Mix-OrbColor $theme $black 0.48 72

    $OrbWaveBack.Stroke.Color = Mix-OrbColor $theme $white 0.52 120
    $backStops = $OrbWaveBack.Fill.GradientStops
    $backStops[0].Color = Mix-OrbColor $theme $white 0.22 94
    $backStops[1].Color = Mix-OrbColor $theme $black 0.18 72
    $backStops[2].Color = Mix-OrbColor $theme $black 0.58 36

    $OrbWaveShade.Stroke.Color = Mix-OrbColor $theme $black 0.72 118

    $OrbWaveFront.Stroke.Color = Mix-OrbColor $theme $white 0.64 172
    $frontStops = $OrbWaveFront.Fill.GradientStops
    $frontStops[0].Color = Mix-OrbColor $theme $white 0.28 112
    $frontStops[1].Color = Mix-OrbColor $theme $black 0.12 106
    $frontStops[2].Color = Mix-OrbColor $theme $black 0.54 54

    if ($Remaining -ge 52.0) {
        $OrbPercentText.Foreground.Color = [System.Windows.Media.Colors]::White
        $OrbPercentText.Effect.Color = ConvertTo-OrbColor '#FF071529'
        $OrbPercentText.Effect.Opacity = 0.9
    } else {
        $OrbPercentText.Foreground.Color = ConvertTo-OrbColor '#FF263746'
        $OrbPercentText.Effect.Color = ConvertTo-OrbColor '#F2FFFFFF'
        $OrbPercentText.Effect.Opacity = 0.82
    }
}

function Restore-ClassicOrbTheme {
    $OrbAtmosphereFill.Fill = $script:ClassicOrbVisuals.AtmosphereFill.Clone()
    $OrbWaterFill.Fill = $script:ClassicOrbVisuals.WaterFill.Clone()
    $OrbWaterGloss.Fill = $script:ClassicOrbVisuals.WaterGloss.Clone()
    $OrbWaterSheen.Fill = $script:ClassicOrbVisuals.WaterSheen.Clone()
    $OrbWaveBack.Stroke = $script:ClassicOrbVisuals.WaveBackStroke.Clone()
    $OrbWaveBack.Fill = $script:ClassicOrbVisuals.WaveBackFill.Clone()
    $OrbWaveShade.Stroke = $script:ClassicOrbVisuals.WaveShadeStroke.Clone()
    $OrbWaveFront.Stroke = $script:ClassicOrbVisuals.WaveFrontStroke.Clone()
    $OrbWaveFront.Fill = $script:ClassicOrbVisuals.WaveFrontFill.Clone()
    $OrbPercentText.Foreground = $script:ClassicOrbVisuals.PercentForeground.Clone()
    $OrbPercentText.Effect = $script:ClassicOrbVisuals.PercentEffect.Clone()
}

function Update-OrbStyleToggleVisual {
    $isGradient = $script:OrbStyle -eq 'Gradient'
    $ClassicStyleDot.Opacity = if ($isGradient) { 0.38 } else { 1.0 }
    $GradientStyleDot.Opacity = if ($isGradient) { 1.0 } else { 0.38 }
    $ClassicStyleDot.Stroke = New-Brush $(if ($isGradient) { '#42FFFFFF' } else { '#F2FFFFFF' })
    $ClassicStyleDot.StrokeThickness = if ($isGradient) { 1.0 } else { 1.5 }
    $GradientStyleDot.Stroke = New-Brush $(if ($isGradient) { '#F2FFFFFF' } else { '#42FFFFFF' })
    $GradientStyleDot.StrokeThickness = if ($isGradient) { 1.5 } else { 1.0 }
    $OrbStyleToggleButton.ToolTip = if ($isGradient) { '切换为原版蓝色' } else { '切换为渐变色' }
}

function Set-OrbStyleMode {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Classic', 'Gradient')]
        [string]$Style,
        [switch]$Persist
    )

    $script:OrbStyle = $Style
    $level = if ($script:CurrentSnapshot) { [double]$script:CurrentSnapshot.Remaining } else { [double]$script:OrbWaterLevel }
    $script:OrbWaterLevel = [Math]::Max(0.0, [Math]::Min(100.0, $level))
    $script:OrbWaterTarget = $script:OrbWaterLevel
    $script:OrbWaterTransitionActive = $false

    if ($script:OrbStyle -eq 'Gradient') {
        Set-OrbTheme $script:OrbWaterLevel
    } else {
        Restore-ClassicOrbTheme
    }
    Set-OrbWaterGeometry $script:OrbWaterLevel
    Update-OrbStyleToggleVisual

    if ($null -ne $waveTimer) {
        $waveTimer.Interval = if ($script:OrbStyle -eq 'Gradient') {
            [TimeSpan]::FromMilliseconds(50)
        } else {
            [TimeSpan]::FromMilliseconds(160)
        }
    }

    if ($Persist) {
        try {
            Set-Content -LiteralPath (Join-Path $script:ScriptDir 'orb-style.txt') -Value $script:OrbStyle -Encoding ASCII
        } catch {
            Write-Diagnostic ('Unable to persist orb style: ' + $_.Exception.Message)
        }
    }
}

function Set-OrbWaterGeometry {
    param([double]$Remaining)

    $level = [Math]::Max(0.0, [Math]::Min(100.0, $Remaining))
    $waterLine = 96.0 - (0.92 * $level)
    $bodyTop = [Math]::Min(100.0, $waterLine + 5.0)
    [System.Windows.Controls.Canvas]::SetTop($OrbWaterFill, $bodyTop)
    $OrbWaterFill.Height = [Math]::Max(0.0, 104.0 - $bodyTop)
    [System.Windows.Controls.Canvas]::SetTop($OrbWaterGloss, $bodyTop)
    $OrbWaterGloss.Height = [Math]::Max(0.0, 104.0 - $bodyTop)
    [System.Windows.Controls.Canvas]::SetTop($OrbWaterSheen, $bodyTop)
    $OrbWaterSheen.Height = [Math]::Max(0.0, 104.0 - $bodyTop)

    $OrbPercentClipTranslate.X = -$script:WavePhase * 0.76
    $OrbPercentClipTranslate.Y = ($waterLine - 10.0) * 0.76
    if ($script:OrbStyle -eq 'Gradient') {
        Set-OrbTheme $level
    }
}

function Get-QuotaAccentColor {
    param([double]$Remaining)
    if ($Remaining -ge 25) { return '#0A84FF' }
    if ($Remaining -ge 10) { return '#FF9F0A' }
    return '#FF453A'
}

function Format-QuotaResetText {
    param($Snapshot)
    if (-not $Snapshot -or -not $Snapshot.ResetAt) {
        return '重置时间暂不可用'
    }

    $reset = [DateTimeOffset]$Snapshot.ResetAt
    $remaining = $reset - [DateTimeOffset]::Now
    if ($remaining.TotalSeconds -le 0) {
        return '额度周期正在刷新'
    }

    $parts = New-Object System.Collections.Generic.List[string]
    if ($remaining.Days -gt 0) { $parts.Add(('{0}天' -f $remaining.Days)) }
    if ($remaining.Hours -gt 0 -or $remaining.Days -gt 0) { $parts.Add(('{0}小时' -f $remaining.Hours)) }
    $parts.Add(('{0}分钟' -f $remaining.Minutes))
    return ("{0:MM月dd日 HH:mm}`n剩余 {1}" -f $reset.LocalDateTime, ($parts -join ' '))
}

function Update-Countdown {
    if ($script:IsCustomProviderActive) { return }
    $FiveHourResetText.Text = Format-QuotaResetText $script:FiveHourSnapshot
    $WeeklyResetText.Text = Format-QuotaResetText $script:WeeklySnapshot
}

function Set-QuotaProgressFill {
    param(
        [Parameter(Mandatory = $true)]$Track,
        [Parameter(Mandatory = $true)]$Fill,
        $Snapshot
    )

    if (-not $Snapshot -or $Track.ActualWidth -le 0) {
        $Fill.Width = 0
        return
    }

    $fillWidth = $Track.ActualWidth * ([double]$Snapshot.Remaining / 100.0)
    if ($fillWidth -gt 0) {
        $fillWidth = [Math]::Max(7.0, $fillWidth)
    }
    $Fill.Width = [Math]::Min($Track.ActualWidth, $fillWidth)
}

function Update-ProgressFill {
    Set-QuotaProgressFill -Track $ProgressTrack -Fill $CapacityFill -Snapshot $script:FiveHourSnapshot
    Set-QuotaProgressFill -Track $WeeklyProgressTrack -Fill $WeeklyCapacityFill -Snapshot $script:WeeklySnapshot
}

function Update-OrbWaterLevel {
    param(
        [double]$Remaining,
        [switch]$Immediate
    )

    $target = [Math]::Max(0.0, [Math]::Min(100.0, $Remaining))
    if ($Immediate -or $script:OrbStyle -eq 'Classic') {
        $script:OrbWaterLevel = $target
        $script:OrbWaterTarget = $target
        $script:OrbWaterTransitionActive = $false
        Set-OrbWaterGeometry $script:OrbWaterLevel
        return
    }

    if ($script:OrbWaterTransitionActive -and [Math]::Abs($script:OrbWaterTarget - $target) -lt 0.01) {
        return
    }
    if (-not $script:OrbWaterTransitionActive -and [Math]::Abs($script:OrbWaterLevel - $target) -lt 0.01) {
        Set-OrbWaterGeometry $script:OrbWaterLevel
        return
    }

    $script:OrbWaterTransitionFrom = $script:OrbWaterLevel
    $script:OrbWaterTarget = $target
    $script:OrbWaterTransitionStartedAt = [DateTime]::UtcNow
    $script:OrbWaterTransitionActive = $true
}

function Update-OrbAnimationFrame {
    if ($OrbView.Visibility -ne [System.Windows.Visibility]::Visible) { return }

    if ($script:OrbStyle -eq 'Gradient' -and $script:OrbWaterTransitionActive) {
        $elapsed = ([DateTime]::UtcNow - $script:OrbWaterTransitionStartedAt).TotalMilliseconds
        $progress = [Math]::Max(0.0, [Math]::Min(1.0, $elapsed / $script:OrbWaterTransitionDurationMs))
        $eased = 1.0 - [Math]::Pow(1.0 - $progress, 3.0)
        $script:OrbWaterLevel = $script:OrbWaterTransitionFrom + (($script:OrbWaterTarget - $script:OrbWaterTransitionFrom) * $eased)
        if ($progress -ge 1.0) {
            $script:OrbWaterLevel = $script:OrbWaterTarget
            $script:OrbWaterTransitionActive = $false
        }
        Set-OrbWaterGeometry $script:OrbWaterLevel
    }

    $phaseStep = if ($script:OrbStyle -eq 'Gradient') { 0.56 } else { 1.8 }
    $script:WavePhase = ($script:WavePhase + $phaseStep) % 80.0
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

function Apply-RateWindows {
    param(
        $FiveHourSnapshot,
        $WeeklySnapshot,
        [bool]$FiveHourUsesWeeklyFallback = $false,
        [switch]$SkipHistory
    )

    if (-not $FiveHourSnapshot -and -not $WeeklySnapshot) { return }
    if (-not $WeeklySnapshot) { $WeeklySnapshot = $FiveHourSnapshot }
    if (-not $FiveHourSnapshot) {
        $FiveHourSnapshot = $WeeklySnapshot
        $FiveHourUsesWeeklyFallback = $true
    }

    $script:IsCustomProviderActive = $false
    $script:CurrentSnapshot = $FiveHourSnapshot
    $script:FiveHourSnapshot = $FiveHourSnapshot
    $script:WeeklySnapshot = $WeeklySnapshot
    $script:FiveHourUsesWeeklyFallback = $FiveHourUsesWeeklyFallback

    $remaining = [double]$FiveHourSnapshot.Remaining
    $weeklyRemaining = [double]$WeeklySnapshot.Remaining
    $accent = Get-QuotaAccentColor $remaining
    $weeklyAccent = Get-QuotaAccentColor $weeklyRemaining
    $soft = if ($remaining -ge 25) { '#260A84FF' } elseif ($remaining -ge 10) { '#26FF9F0A' } else { '#26FF453A' }
    $badge = if ($remaining -ge 25) { '#242A4E76' } elseif ($remaining -ge 10) { '#332B210E' } else { '#33321B1B' }

    $accentBrush = New-Brush $accent
    $weeklyAccentBrush = New-Brush $weeklyAccent
    $PercentText.Text = ('{0:0}%' -f $remaining)
    $WeeklyPercentText.Text = ('{0:0}%' -f $weeklyRemaining)
    $PercentText.FontSize = 35
    $WeeklyPercentText.FontSize = 35
    $OrbPercentText.Text = ('{0:0}%' -f $remaining)
    $OrbPercentWaterText.Text = $OrbPercentText.Text
    $OrbPercentText.FontSize = 18
    $OrbPercentWaterText.FontSize = 18
    Update-OrbWaterLevel $remaining
    $CapacityFill.Background = $accentBrush
    $WeeklyCapacityFill.Background = $weeklyAccentBrush
    $StatusDot.Fill = $accentBrush
    $StatusHalo.Background = New-Brush $soft
    $SourceBadge.Background = New-Brush $badge
    $planLabel = if ($FiveHourSnapshot.PlanType) { $FiveHourSnapshot.PlanType.ToUpperInvariant() } else { 'CODEX' }
    $FiveHourUsedText.Text = ('已用 {0:0}% · {1}' -f ([double]$FiveHourSnapshot.UsedPercent), $planLabel)
    $WeeklyUsedText.Text = ('已用 {0:0}% · {1}' -f ([double]$WeeklySnapshot.UsedPercent), $planLabel)
    $FiveHourFallbackText.Visibility = if ($FiveHourUsesWeeklyFallback) { 'Visible' } else { 'Collapsed' }
    $UpdatedText.Text = ('{0:HH:mm:ss}' -f $FiveHourSnapshot.ObservedAt.LocalDateTime)
    Update-ProgressFill

    if ($FiveHourSnapshot.Source -eq 'direct') {
        $SourceText.Text = 'LIVE API'
        $SourceText.Foreground = $accentBrush
    } else {
        $SourceText.Text = 'EVENT SNAPSHOT'
        $SourceText.Foreground = $accentBrush
    }

    Update-Countdown
    if (-not $SkipHistory) {
        # Preserve the historical weekly series even after the orb starts using
        # the restored five-hour window.
        Save-RateHistorySnapshot $WeeklySnapshot
    }

    if ($script:AnalyticsSnapshot) {
        Apply-AnalyticsSnapshot $script:AnalyticsSnapshot
    }

    if (-not $QARenderPath -and $remaining -le 0 -and -not $script:QuotaSwitchPrompted -and $script:AccountStore) {
        $script:QuotaSwitchPrompted = $true
        if (-not $window.IsVisible) { $window.Show() }
        $window.WindowState = [System.Windows.WindowState]::Normal
        Show-CapacityView
        Show-AccountFlyout
        $AccountFlyoutStatusText.Text = '当前账号额度已耗尽。请选择另一个账号或配置；不会使用或重置任何额度卡。'
        $window.Activate()
    } elseif ($remaining -gt 0) {
        $script:QuotaSwitchPrompted = $false
    }
}

function Apply-Snapshot {
    param($Snapshot)
    if (-not $Snapshot) { return }
    Apply-RateWindows -FiveHourSnapshot $Snapshot -WeeklySnapshot $Snapshot -FiveHourUsesWeeklyFallback $true
}

function Apply-CustomProviderState {
    $script:IsCustomProviderActive = $true
    $script:CurrentSnapshot = $null
    $script:FiveHourSnapshot = $null
    $script:WeeklySnapshot = $null
    $script:AccountUsage = $null
    $script:FiveHourUsesWeeklyFallback = $false
    $script:QuotaSwitchPrompted = $false

    $accentBrush = New-Brush '#64D2FF'
    $PercentText.Text = '∞'
    $WeeklyPercentText.Text = '∞'
    $PercentText.FontSize = 38
    $WeeklyPercentText.FontSize = 38
    $OrbPercentText.Text = '∞'
    $OrbPercentWaterText.Text = '∞'
    $OrbPercentText.FontSize = 26
    $OrbPercentWaterText.FontSize = 26
    Update-OrbWaterLevel 100 -Immediate

    $CapacityFill.Width = 0
    $WeeklyCapacityFill.Width = 0
    $CapacityFill.Background = $accentBrush
    $WeeklyCapacityFill.Background = $accentBrush
    $StatusDot.Fill = $accentBrush
    $StatusHalo.Background = New-Brush '#2664D2FF'
    $SourceBadge.Background = New-Brush '#24305B70'
    $SourceText.Text = 'CUSTOM · ∞'
    $SourceText.Foreground = $accentBrush
    $FiveHourUsedText.Text = '自定义配置 · 不监控额度'
    $WeeklyUsedText.Text = '自定义配置 · 不监控额度'
    $FiveHourFallbackText.Visibility = 'Collapsed'
    $FiveHourResetText.Text = '无需额度快照'
    $WeeklyResetText.Text = '无需额度快照'
    $UpdatedText.Text = '—'

    if ($script:AnalyticsSnapshot) {
        Apply-AnalyticsSnapshot $script:AnalyticsSnapshot
    }
}

function Apply-EmptyState {
    param([string]$Message)
    $script:IsCustomProviderActive = $false
    $script:CurrentSnapshot = $null
    $script:FiveHourSnapshot = $null
    $script:WeeklySnapshot = $null
    $script:FiveHourUsesWeeklyFallback = $true
    $PercentText.Text = '--%'
    $WeeklyPercentText.Text = '--%'
    $PercentText.FontSize = 35
    $WeeklyPercentText.FontSize = 35
    $OrbPercentText.Text = '--%'
    $OrbPercentWaterText.Text = '--%'
    $OrbPercentText.FontSize = 18
    $OrbPercentWaterText.FontSize = 18
    Update-OrbWaterLevel 0
    $CapacityFill.Width = 0
    $WeeklyCapacityFill.Width = 0
    $SourceText.Text = 'WAITING'
    $FiveHourUsedText.Text = $Message
    $WeeklyUsedText.Text = $Message
    $FiveHourFallbackText.Visibility = 'Visible'
    $FiveHourResetText.Text = '等待 5h 或周额度快照'
    $WeeklyResetText.Text = '启动 Codex 后自动出现'
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

function Get-ToolCategoryLabel {
    param([string]$Name)
    switch ($Name) {
        'command' { return '命令执行' }
        'file' { return '文件修改' }
        'web' { return '网页查询' }
        'connector' { return 'MCP / 连接器' }
        'agent' { return 'Agent 协作' }
        'document' { return '文档与数据' }
        'media' { return '图片与媒体' }
        'workflow' { return '工作流控制' }
        default { return '其他工具' }
    }
}

function Get-SkillStatusLabel {
    param([string]$Status)
    switch ($Status) {
        'frequent' { return '常用' }
        'occasional' { return '偶尔使用' }
        'installed_only' { return '仅安装' }
        default { return '未使用' }
    }
}

function Format-AnalyticsLastUsed {
    param($Value)
    if (-not $Value) { return '暂无记录' }
    try {
        $day = [DateTime]::ParseExact([string]$Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        if ($day.Date -eq (Get-Date).Date) { return '今天' }
        if ($day.Date -eq (Get-Date).Date.AddDays(-1)) { return '昨天' }
        return $day.ToString('MM/dd')
    } catch {
        return [string]$Value
    }
}

function Render-UsageRows {
    param(
        $Panel,
        $Rows,
        [ValidateSet('daily', 'skill', 'chain', 'agent', 'tool')][string]$Mode
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
        $stackedLayout = $Mode -in @('skill', 'chain', 'agent', 'tool')
        $row = [System.Windows.Controls.Grid]::new()
        $row.Height = if ($Mode -eq 'skill') { 60 } elseif ($Mode -in @('chain', 'agent', 'tool')) { 52 } else { 36 }
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
        } elseif ($Mode -eq 'agent' -and $item.kind) {
            ('{0} · {1}' -f $(if ([string]$item.kind -eq 'ROOT') { '主' } else { '子' }), ([string]$item.name))
        } elseif ($Mode -eq 'tool') {
            Get-ToolCategoryLabel ([string]$item.category)
        } else {
            Get-AnalyticsLabel ([string]$item.name)
        }

        if ($Mode -eq 'skill') {
            $label = [System.Windows.Controls.StackPanel]::new()
            $label.VerticalAlignment = 'Center'
            $scopeText = if ($item.scope) { [string]$item.scope } else { 'OTHER' }
            $label.ToolTip = ('参与 {0} · 主归因 {1} · {2} Turn · {3}' -f `
                (Format-TokenCount ([long]$item.associatedTokens)),
                (Format-TokenCount ([long]$item.primaryTokens)),
                ([long]$item.turns),
                $scopeText)

            $skillName = [System.Windows.Controls.TextBlock]::new()
            $skillName.Text = $labelText
            $skillName.Foreground = New-Brush $(if ([long]$item.turns -gt 0) { '#D1D1D6' } else { '#70FFFFFF' })
            $skillName.FontSize = 11
            $skillName.FontWeight = 'SemiBold'
            $skillName.TextTrimming = 'CharacterEllipsis'

            $skillDetail = [System.Windows.Controls.TextBlock]::new()
            $skillDetail.Text = if ([long]$item.turns -gt 0) {
                '{0} · 使用 {1} 次 · 最近 {2}' -f (Get-SkillStatusLabel ([string]$item.status)), ([long]$item.turns), (Format-AnalyticsLastUsed $item.lastUsed)
            } else {
                '{0} · {1}{2}' -f (Get-SkillStatusLabel ([string]$item.status)), $scopeText, $(if ($item.available) { ' · 当前可用' } else { ' · 未公布' })
            }
            $skillDetail.Foreground = New-Brush '#78FFFFFF'
            $skillDetail.FontSize = 9
            $skillDetail.Margin = '0,1,0,0'
            [void]$label.Children.Add($skillName)
            [void]$label.Children.Add($skillDetail)
        } elseif ($Mode -eq 'agent') {
            $label = [System.Windows.Controls.StackPanel]::new()
            $label.VerticalAlignment = 'Center'
            $label.ToolTip = ('{0} Turn · {1} 会话 · 模型 {2} · effort {3}' -f `
                ([long]$item.turns),
                ([long]$item.sessions),
                (@($item.models) -join ', '),
                (@($item.efforts) -join ', '))

            $agentName = [System.Windows.Controls.TextBlock]::new()
            $agentName.Text = $labelText
            $agentName.Foreground = New-Brush '#D1D1D6'
            $agentName.FontSize = 11
            $agentName.FontWeight = 'SemiBold'
            $agentName.TextTrimming = 'CharacterEllipsis'

            $agentDetail = [System.Windows.Controls.TextBlock]::new()
            $agentDetail.Text = ('完成 {0}/{1} · Tool {2} · 最近 {3}' -f `
                ([long]$item.completedTurns), ([long]$item.turns), ([long]$item.toolCalls), (Format-AnalyticsLastUsed $item.lastUsed))
            $agentDetail.Foreground = New-Brush $(if ([long]$item.toolFailures -gt 0) { '#FFFF9F0A' } else { '#78FFFFFF' })
            $agentDetail.FontSize = 9
            $agentDetail.Margin = '0,1,0,0'
            [void]$label.Children.Add($agentName)
            [void]$label.Children.Add($agentDetail)
        } elseif ($Mode -eq 'tool') {
            $label = [System.Windows.Controls.StackPanel]::new()
            $label.VerticalAlignment = 'Center'
            $label.ToolTip = (@($item.tools) -join ', ')

            $toolName = [System.Windows.Controls.TextBlock]::new()
            $toolName.Text = $labelText
            $toolName.Foreground = New-Brush '#D1D1D6'
            $toolName.FontSize = 11
            $toolName.FontWeight = 'SemiBold'
            $toolName.TextTrimming = 'CharacterEllipsis'

            $toolDetail = [System.Windows.Controls.TextBlock]::new()
            $toolDetail.Text = ('调用 {0} · 失败 {1} · 最近 {2}' -f `
                ([long]$item.calls), ([long]$item.failures), (Format-AnalyticsLastUsed $item.lastUsed))
            $toolDetail.Foreground = New-Brush $(if ([long]$item.failures -gt 0) { '#FFFF9F0A' } else { '#78FFFFFF' })
            $toolDetail.FontSize = 9
            $toolDetail.Margin = '0,1,0,0'
            [void]$label.Children.Add($toolName)
            [void]$label.Children.Add($toolDetail)
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
        $value.Text = if ($Mode -eq 'tool') { '{0:N0} 次' -f ([long]$item.calls) } else { Format-TokenCount ([long]$item.tokens) }
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
        $SkillSectionTitle.Text = 'SKILL · 多 SKILL 调用链'
        $SkillHintText.Text = '按本地载入证据显示 Skill 组合顺序；每条链内 Token 只计一次。'
    } elseif ($script:AnalyticsSnapshot) {
        $SkillSectionTitle.Text = 'SKILL · 使用情况'
        $installedCount = [long]$script:AnalyticsSnapshot.installedSkillCount
        $availableCount = [long]$script:AnalyticsSnapshot.availableSkillCount
        $unattributed = [double]$script:AnalyticsSnapshot.unattributedSkillPercent
        $SkillHintText.Text = ('已安装 {0} · 当前公布 {1} · 未归因 {2:0.0}% · 参与 Token 会重复。' -f $installedCount, $availableCount, $unattributed)
    } else {
        $SkillSectionTitle.Text = 'SKILL · 使用情况'
        $SkillHintText.Text = '参与 Token 会重复归因；归因覆盖率仍按每个 Turn 只计一次。'
    }
}

function Apply-AnalyticsSnapshot {
    param($Snapshot)
    if (-not $Snapshot) { return }

    Write-Diagnostic 'Applying analytics snapshot.'
    $AnalyticsLoadingPanel.Visibility = 'Collapsed'
    $dailyView = Get-DisplayDailyUsage $Snapshot
    $SevenDayTotalText.Text = Format-TokenCount ([long]$dailyView.Total)
    $AnalyticsSourceText.Text = ($dailyView.Source + ' · ' + (Format-TokenCount ([long]$dailyView.Total)) + ' TOKEN')
    $DailySourceText.Text = if ($dailyView.Source -eq 'ACCOUNT API') { '当前账号每日桶（兜底）' } else { '本机全部账号会话' }
    Render-UsageRows -Panel $DailyRowsPanel -Rows $dailyView.Rows -Mode daily
    Write-Diagnostic 'Rendered daily analytics rows.'
    Render-UsageRows -Panel $SkillRowsPanel -Rows @($Snapshot.skills) -Mode skill
    Write-Diagnostic 'Rendered skill analytics rows.'
    Render-UsageRows -Panel $SkillChainRowsPanel -Rows @($Snapshot.skillChains) -Mode chain
    Write-Diagnostic 'Rendered skill route chains.'
    Render-UsageRows -Panel $AgentRowsPanel -Rows @($Snapshot.agentBreakdown) -Mode agent
    Write-Diagnostic 'Rendered agent analytics rows.'
    Render-UsageRows -Panel $ToolRowsPanel -Rows @($Snapshot.tools.rows) -Mode tool
    Write-Diagnostic 'Rendered Tool analytics rows.'

    $SkillPrimaryButton.Content = ('{0} 可用' -f ([long]$Snapshot.availableSkillCount))
    $SkillCoverageText.Text = ('归因覆盖 {0:0.0}%' -f ([double]$Snapshot.skillCoveragePercent))
    $rootAgent = @($Snapshot.agentSummary | Where-Object { [string]$_.name -eq 'ROOT' } | Select-Object -First 1)
    $subAgent = @($Snapshot.agentSummary | Where-Object { [string]$_.name -eq 'SUBAGENT' } | Select-Object -First 1)
    $AgentSummaryText.Text = ('主 {0:0.0}% · 子 {1:0.0}%' -f `
        $(if ($rootAgent.Count) { [double]$rootAgent[0].sharePercent } else { 0.0 }),
        $(if ($subAgent.Count) { [double]$subAgent[0].sharePercent } else { 0.0 }))
    $ToolSummaryText.Text = ('调用 {0} · 失败 {1}' -f `
        ([long]$Snapshot.tools.calls),
        ([long]$Snapshot.tools.failures))
    $ToolHintText.Text = ('MCP {0}/{1} · 插件 {2}；纯本地读取，不调用模型。' -f `
        ([long]$Snapshot.tools.enabledMcpServers),
        ([long]$Snapshot.tools.configuredMcpServers),
        ([long]$Snapshot.tools.enabledPlugins))

    $WorkflowHintsPanel.Children.Clear()
    $workflowHints = @($Snapshot.workflowHints | Select-Object -First 3)
    if ($workflowHints.Count -eq 0) {
        $workflowHints = @('当前没有需要处理的工作流提醒。')
    }
    foreach ($hintText in $workflowHints) {
        $hint = [System.Windows.Controls.TextBlock]::new()
        $hint.Text = ('• ' + [string]$hintText)
        $hint.Foreground = New-Brush '#9FFFFFFF'
        $hint.FontSize = 9
        $hint.TextWrapping = 'Wrap'
        $hint.Margin = '0,1,0,0'
        [void]$WorkflowHintsPanel.Children.Add($hint)
    }
    Set-SkillView $script:ActiveSkillView
    $OfficialRateText.Text = if ($script:IsCustomProviderActive) {
        '自定义配置 · 不监控额度'
    } elseif ($script:FiveHourSnapshot -and $script:WeeklySnapshot) {
        '官方额度：5h 已用 {0:0}% · 1周已用 {1:0}%' -f
            ([double]$script:FiveHourSnapshot.UsedPercent),
            ([double]$script:WeeklySnapshot.UsedPercent)
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
    $AnalyticsStatusText.Text = ('本地索引 {0} 个文件 · 0 Token · {1}' -f $Snapshot.scannedFiles, $generated)
    Write-Diagnostic 'Analytics snapshot applied.'
}

function Set-AnalyticsTab {
    param([ValidateSet('daily', 'skill', 'agent', 'tool')][string]$Name)
    $script:ActiveAnalyticsTab = $Name
    $DailyPanel.Visibility = if ($Name -eq 'daily') { 'Visible' } else { 'Collapsed' }
    $SkillPanel.Visibility = if ($Name -eq 'skill') { 'Visible' } else { 'Collapsed' }
    $AgentPanel.Visibility = if ($Name -eq 'agent') { 'Visible' } else { 'Collapsed' }
    $ToolPanel.Visibility = if ($Name -eq 'tool') { 'Visible' } else { 'Collapsed' }
    if ($Name -eq 'skill') { Set-SkillView $script:ActiveSkillView }

    foreach ($entry in @(
        [pscustomobject]@{ Name = 'daily'; Button = $DailyTabButton },
        [pscustomobject]@{ Name = 'skill'; Button = $SkillTabButton },
        [pscustomobject]@{ Name = 'agent'; Button = $AgentTabButton },
        [pscustomobject]@{ Name = 'tool'; Button = $ToolTabButton }
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
    Set-AccountBackdropBlur $false
    $AccountFlyoutLayer.Visibility = 'Collapsed'
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
    Set-AccountBackdropBlur $false
    $AccountFlyoutLayer.Visibility = 'Collapsed'
    $OrbView.Visibility = 'Collapsed'
    $GlowBorder.Visibility = 'Collapsed'
    $ResetCreditsBorder.Visibility = 'Collapsed'
    $AnalyticsBorder.Visibility = 'Visible'
    Resize-WindowAroundCenter -Width 440 -Height 560
    Set-AnalyticsTab $script:ActiveAnalyticsTab
    if ($script:AnalyticsSnapshot) {
        Apply-AnalyticsSnapshot $script:AnalyticsSnapshot
    } else {
        $AnalyticsLoadingTitle.Text = '正在整理本地使用记录'
        $AnalyticsLoadingText.Text = '仅汇总本机已有记录，首次打开可能需要几秒。'
        $AnalyticsLoadingPanel.Visibility = 'Visible'
    }
    Start-AnalyticsRefreshAsync
}

function Show-CapacityView {
    $script:ViewMode = 'capacity'
    Set-AccountBackdropBlur $false
    $AccountFlyoutLayer.Visibility = 'Collapsed'
    $OrbView.Visibility = 'Collapsed'
    $AnalyticsBorder.Visibility = 'Collapsed'
    $ResetCreditsBorder.Visibility = 'Collapsed'
    $GlowBorder.Visibility = 'Visible'
    Resize-WindowAroundCenter -Width 420 -Height 410
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
    Set-AccountBackdropBlur $false
    $AccountFlyoutLayer.Visibility = 'Collapsed'
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
        $workerInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $workerInfo.RedirectStandardOutput = $true
        $workerInfo.RedirectStandardError = $true

        $worker = New-Object System.Diagnostics.Process
        $worker.StartInfo = $workerInfo
        [void]$worker.Start()
        $script:DirectWorkerProcess = $worker
        $script:DirectWorkerStartedAt = [DateTime]::UtcNow
        $script:DirectWorkerOutputTask = $worker.StandardOutput.ReadToEndAsync()
        $script:DirectWorkerErrorTask = $worker.StandardError.ReadToEndAsync()
        $script:PendingDirectRefresh = $false
        $RefreshButton.IsEnabled = $false
        $RefreshButton.Content = '···'
        $AnalyticsRefreshButton.IsEnabled = $false
        $AnalyticsRefreshButton.Content = '···'
    } catch {
        Write-Diagnostic ('Unable to start direct worker: ' + $_.Exception.Message)
        Complete-AccountIdentityVerification $false
    }
}

function Complete-DirectRefreshIfReady {
    $worker = $script:DirectWorkerProcess
    if (-not $worker) {
        return
    }
    if (-not $worker.HasExited) {
        if ($script:DirectWorkerStartedAt -and ([DateTime]::UtcNow - $script:DirectWorkerStartedAt).TotalSeconds -ge 15) {
            Write-Diagnostic 'Direct worker exceeded 15 seconds and was stopped.'
            $runAgain = $script:PendingDirectRefresh
            Stop-OwnedProcess $worker
            $script:DirectWorkerProcess = $null
            $script:DirectWorkerStartedAt = $null
            $script:DirectWorkerOutputTask = $null
            $script:DirectWorkerErrorTask = $null
            $script:PendingDirectRefresh = $false
            $RefreshButton.Content = '↻'
            $RefreshButton.IsEnabled = $true
            $AnalyticsRefreshButton.Content = '↻'
            $AnalyticsRefreshButton.IsEnabled = $true
            Complete-AccountIdentityVerification $false
            if ($runAgain) { Start-DirectRefreshAsync }
        }
        return
    }

    $outputState = Get-WorkerOutputState $worker $script:DirectWorkerOutputTask $script:DirectWorkerErrorTask
    if ($outputState -eq 'pending') { return }
    $identitySynchronized = $false
    try {
        if ($outputState -eq 'timeout') { throw '额度结果管道未关闭，请重试。' }
        $output = ([string]$script:DirectWorkerOutputTask.Result).Trim()
        $errorText = ([string]$script:DirectWorkerErrorTask.Result).Trim()
        if ($worker.ExitCode -eq 0 -and $output) {
            $wire = $output | ConvertFrom-Json
            $identitySyncProperty = $wire.PSObject.Properties['IdentitySynchronized']
            $identitySynchronized = [bool]($identitySyncProperty -and $identitySyncProperty.Value)
            $customProviderProperty = $wire.PSObject.Properties['CustomProviderActive']
            $customProviderActive = [bool]($customProviderProperty -and $customProviderProperty.Value)
            $script:AccountUsage = if ($wire.Usage) { $wire.Usage } else { $null }
            if ($customProviderActive) {
                Apply-CustomProviderState
            } elseif ($wire.Rates -and $wire.Rates.FiveHour -and $wire.Rates.Weekly) {
                $fiveHourSnapshot = ConvertFrom-RateWire $wire.Rates.FiveHour
                $weeklySnapshot = ConvertFrom-RateWire $wire.Rates.Weekly
                Apply-RateWindows `
                    -FiveHourSnapshot $fiveHourSnapshot `
                    -WeeklySnapshot $weeklySnapshot `
                    -FiveHourUsesWeeklyFallback ([bool]$wire.Rates.FiveHourUsesWeeklyFallback)
            } elseif ($wire.Rate) {
                # Compatibility path for a worker from an older installed copy.
                Apply-Snapshot (ConvertFrom-RateWire $wire.Rate)
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
        $script:DirectWorkerStartedAt = $null
        $script:DirectWorkerOutputTask = $null
        $script:DirectWorkerErrorTask = $null
        $script:PendingDirectRefresh = $false
        $RefreshButton.Content = '↻'
        $RefreshButton.IsEnabled = $true
        $AnalyticsRefreshButton.Content = '↻'
        $AnalyticsRefreshButton.IsEnabled = $true
        Complete-AccountIdentityVerification $identitySynchronized
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
        $workerInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $workerInfo.RedirectStandardOutput = $true
        $workerInfo.RedirectStandardError = $true

        $worker = New-Object System.Diagnostics.Process
        $worker.StartInfo = $workerInfo
        [void]$worker.Start()
        $script:ResetCreditsWorkerProcess = $worker
        $script:ResetCreditsWorkerOutputTask = $worker.StandardOutput.ReadToEndAsync()
        $script:ResetCreditsWorkerErrorTask = $worker.StandardError.ReadToEndAsync()
        $script:ResetCreditsWorkerStartedAt = [DateTime]::UtcNow
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
    if (-not $worker) { return }
    if (-not $worker.HasExited) {
        if (([DateTime]::UtcNow - $script:ResetCreditsWorkerStartedAt).TotalSeconds -lt 20) { return }
        Stop-OwnedProcess $worker
        $script:ResetCreditsWorkerProcess = $null
        $script:IsResetCreditsRefreshing = $false
        $ResetCreditsRefreshButton.Content = '↻'
        $ResetCreditsRefreshButton.IsEnabled = $true
        $ResetCreditsRetryButton.IsEnabled = $true
        Set-ResetCreditsState -Message '查询超时，请重试' -CanRetry
        return
    }
    $outputState = Get-WorkerOutputState $worker $script:ResetCreditsWorkerOutputTask $script:ResetCreditsWorkerErrorTask
    if ($outputState -eq 'pending') { return }

    try {
        if ($outputState -eq 'timeout') { throw '重置卡结果管道未关闭，请重试。' }
        $output = ([string]$script:ResetCreditsWorkerOutputTask.Result).Trim()
        [void]$script:ResetCreditsWorkerErrorTask.Result
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

    try {
        if ($script:AnalyticsWorkerProcess) {
            if (-not $script:AnalyticsWorkerProcess.HasExited) { return }
            $script:AnalyticsWorkerProcess.Dispose()
            $script:AnalyticsWorkerProcess = $null
        }

        $AnalyticsRefreshButton.IsEnabled = $false
        $AnalyticsRefreshButton.Content = '···'
        $AnalyticsStatusText.Text = '正在增量汇总本地会话…'
        if (-not $script:AnalyticsSnapshot) {
            $AnalyticsLoadingTitle.Text = '正在整理本地使用记录'
            $AnalyticsLoadingText.Text = '仅汇总本机已有记录，首次打开可能需要几秒。'
            $AnalyticsLoadingPanel.Visibility = 'Visible'
        }

        $workerInfo = New-Object System.Diagnostics.ProcessStartInfo
        $workerInfo.FileName = (Get-Command powershell.exe).Source
        $workerInfo.Arguments = ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -AnalyticsWorker' -f $script:ScriptPath)
        $workerInfo.UseShellExecute = $false
        $workerInfo.CreateNoWindow = $true
        $workerInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $workerInfo.RedirectStandardOutput = $true
        $workerInfo.RedirectStandardError = $true

        $worker = New-Object System.Diagnostics.Process
        $worker.StartInfo = $workerInfo
        [void]$worker.Start()
        $script:AnalyticsWorkerProcess = $worker
        $script:AnalyticsWorkerStartedAt = [DateTime]::UtcNow
        $script:AnalyticsWorkerOutputTask = $worker.StandardOutput.ReadToEndAsync()
        $script:AnalyticsWorkerErrorTask = $worker.StandardError.ReadToEndAsync()
        $script:IsAnalyticsRefreshing = $true
    } catch {
        $script:IsAnalyticsRefreshing = $false
        $AnalyticsStatusText.Text = '本地统计失败：' + $_.Exception.Message
        if (-not $script:AnalyticsSnapshot) {
            $AnalyticsLoadingTitle.Text = '暂时无法读取统计'
            $AnalyticsLoadingText.Text = '点击右上角刷新按钮重试；额度页仍可正常使用。'
            $AnalyticsLoadingPanel.Visibility = 'Visible'
        }
        Write-Diagnostic ('Analytics refresh failed: ' + $_.Exception.Message)
        $AnalyticsRefreshButton.IsEnabled = $true
        $AnalyticsRefreshButton.Content = '↻'
    }
}

function Complete-AnalyticsRefreshIfReady {
    $worker = $script:AnalyticsWorkerProcess
    if (-not $worker) { return }
    if (-not $worker.HasExited) {
        if ($script:AnalyticsWorkerStartedAt -and ([DateTime]::UtcNow - $script:AnalyticsWorkerStartedAt).TotalSeconds -ge 120) {
            Stop-OwnedProcess $worker
            $script:AnalyticsWorkerProcess = $null
            $script:AnalyticsWorkerStartedAt = $null
            $script:AnalyticsWorkerOutputTask = $null
            $script:AnalyticsWorkerErrorTask = $null
            $script:IsAnalyticsRefreshing = $false
            $AnalyticsStatusText.Text = '本地统计超时，请稍后重试'
            if (-not $script:AnalyticsSnapshot) {
                $AnalyticsLoadingTitle.Text = '统计用时较长'
                $AnalyticsLoadingText.Text = '点击右上角刷新按钮稍后重试；额度页仍可正常使用。'
                $AnalyticsLoadingPanel.Visibility = 'Visible'
            }
            $AnalyticsRefreshButton.IsEnabled = $true
            $AnalyticsRefreshButton.Content = '↻'
        }
        return
    }

    $outputState = Get-WorkerOutputState $worker $script:AnalyticsWorkerOutputTask $script:AnalyticsWorkerErrorTask
    if ($outputState -eq 'pending') { return }
    try {
        if ($outputState -eq 'timeout') { throw '统计结果管道未关闭，请重试。' }
        $output = ([string]$script:AnalyticsWorkerOutputTask.Result).Trim()
        $errorText = ([string]$script:AnalyticsWorkerErrorTask.Result).Trim()
        if ($worker.ExitCode -ne 0 -or -not $output) {
            if ($errorText) { throw $errorText }
            throw '统计进程未返回数据。'
        }
        $snapshot = $output | ConvertFrom-Json
        if ($snapshot.PSObject.Properties.Name -contains 'error' -and $snapshot.error) { throw [string]$snapshot.error }
        $script:AnalyticsSnapshot = $snapshot
        Apply-AnalyticsSnapshot $snapshot
    } catch {
        $AnalyticsStatusText.Text = '本地统计失败：' + $_.Exception.Message
        if (-not $script:AnalyticsSnapshot) {
            $AnalyticsLoadingTitle.Text = '暂时无法读取统计'
            $AnalyticsLoadingText.Text = '点击右上角刷新按钮重试；额度页仍可正常使用。'
            $AnalyticsLoadingPanel.Visibility = 'Visible'
        }
        Write-Diagnostic ('Analytics refresh failed: ' + $_.Exception.Message)
    } finally {
        $worker.Dispose()
        $script:AnalyticsWorkerProcess = $null
        $script:AnalyticsWorkerStartedAt = $null
        $script:AnalyticsWorkerOutputTask = $null
        $script:AnalyticsWorkerErrorTask = $null
        $script:IsAnalyticsRefreshing = $false
        $AnalyticsRefreshButton.IsEnabled = $true
        $AnalyticsRefreshButton.Content = '↻'
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
                $direct = Read-RateWindowsFromAppServer
                if ($direct) {
                    Apply-RateWindows `
                        -FiveHourSnapshot $direct.FiveHour `
                        -WeeklySnapshot $direct.Weekly `
                        -FiveHourUsesWeeklyFallback ([bool]$direct.FiveHourUsesWeeklyFallback)
                    return
                }
            } catch {
                Write-Diagnostic ('Direct read unavailable: ' + $_.Exception.Message)
            }
        }

        # The UI only reads the small widget-owned history cache. Session JSONL
        # parsing happens in DirectWorker so it cannot block WPF input/rendering.
        $snapshot = Read-RateLimitFromHistory
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
$script:TrayIconResource = New-QuotaTrayIconResource
$notifyIcon.Icon = $script:TrayIconResource
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
        $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
        $cursor = [System.Windows.Forms.Cursor]::Position
        $script:PanelDragOffsetX = ([double]$cursor.X / $dpi.DpiScaleX) - $window.Left
        $script:PanelDragOffsetY = ([double]$cursor.Y / $dpi.DpiScaleY) - $window.Top
        $script:PanelIsDragging = $window.CaptureMouse()
        $eventArgs.Handled = $true
    }
})

$window.Add_MouseMove({
    param($sender, $eventArgs)
    if (-not $script:PanelIsDragging -or $eventArgs.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
    $cursor = [System.Windows.Forms.Cursor]::Position
    $window.Left = ([double]$cursor.X / $dpi.DpiScaleX) - $script:PanelDragOffsetX
    $window.Top = ([double]$cursor.Y / $dpi.DpiScaleY) - $script:PanelDragOffsetY
    Ensure-WindowInsideWorkArea
    $eventArgs.Handled = $true
})
$window.Add_MouseLeftButtonUp({
    if ($script:PanelIsDragging) {
        $script:PanelIsDragging = $false
        $window.ReleaseMouseCapture()
    }
})
$window.Add_LostMouseCapture({ $script:PanelIsDragging = $false })

$ProgressTrack.Add_SizeChanged({ Update-ProgressFill })
$WeeklyProgressTrack.Add_SizeChanged({ Update-ProgressFill })

$AnalyticsButton.Add_Click({ Show-AnalyticsView })
$ResetCreditsButton.Add_Click({ Show-ResetCreditsView })
$AccountSwitchButton.Add_Click({
    if ($AccountFlyoutLayer.Visibility -eq [System.Windows.Visibility]::Visible) {
        Hide-AccountFlyout
    } else {
        Show-AccountFlyout
    }
})
$AccountFlyoutCloseButton.Add_Click({ Hide-AccountFlyout })
$SaveCurrentAccountButton.Add_Click({ Start-AccountWorker -Action 'capture' })
$AddAccountButton.Add_Click({ Start-AccountRegistration })
$ImportCustomButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '选择同时包含 auth.json 和 config.toml 的文件夹'
    $dialog.ShowNewFolderButton = $false
    try {
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $selectedDirectory = [IO.Path]::GetFullPath($dialog.SelectedPath)
        if (-not (Test-Path -LiteralPath (Join-Path $selectedDirectory 'auth.json') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $selectedDirectory 'config.toml') -PathType Leaf)) {
            $AccountFlyoutStatusText.Text = '所选文件夹必须同时包含 auth.json 和 config.toml。'
            return
        }
        Start-AccountWorker -Action 'import-custom' -ImportDirectory $selectedDirectory
    } finally {
        $dialog.Dispose()
    }
})
$OrbStyleToggleButton.Add_Click({
    $nextStyle = if ($script:OrbStyle -eq 'Gradient') { 'Classic' } else { 'Gradient' }
    Set-OrbStyleMode -Style $nextStyle -Persist
})
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
$ToolTabButton.Add_Click({ Set-AnalyticsTab 'tool' })
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

$OrbHitTarget.Add_LostMouseCapture({
    $script:OrbIsDragging = $false
    $script:OrbPointerMoved = $false
})

$analyticsWorkerTimer = New-Object System.Windows.Threading.DispatcherTimer
$analyticsWorkerTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$analyticsWorkerTimer.Add_Tick({
    Complete-AnalyticsRefreshIfReady
})

$accountWorkerTimer = New-Object System.Windows.Threading.DispatcherTimer
$accountWorkerTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$accountWorkerTimer.Add_Tick({
    Complete-AccountWorkerIfReady
    Complete-AccountRegistrationIfReady
})

$eventTimer = New-Object System.Windows.Threading.DispatcherTimer
$eventTimer.Interval = [TimeSpan]::FromSeconds(4)
$eventTimer.Add_Tick({
    try {
        $latest = Get-LatestRolloutFile
        if ($latest -and ($latest.FullName -ne $script:LastRolloutPath -or $latest.LastWriteTimeUtc.Ticks -ne $script:LastRolloutWriteTicks)) {
            $script:LastRolloutPath = $latest.FullName
            $script:LastRolloutWriteTicks = $latest.LastWriteTimeUtc.Ticks
            # Refresh in a child process. Large JSONL records must never be read on
            # the UI dispatcher, otherwise even a simple orb click can hang Windows.
            Start-DirectRefreshAsync
            if ($AnalyticsBorder.Visibility -eq [System.Windows.Visibility]::Visible) {
                Start-AnalyticsRefreshAsync
            }
        }
    } catch {
        Write-Diagnostic ('Event refresh failed: ' + $_.Exception.Message)
    }
})

$periodicRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$periodicRefreshTimer.Interval = [TimeSpan]::FromMinutes(1)
$periodicRefreshTimer.Add_Tick({
    # Event-driven refreshes remain the fast path. This timer is a quiet fallback
    # for periods when the local rollout file does not emit a detectable change.
    Start-DirectRefreshAsync
})

$waveTimer = New-Object System.Windows.Threading.DispatcherTimer
$waveTimer.Interval = if ($script:OrbStyle -eq 'Gradient') {
    [TimeSpan]::FromMilliseconds(50)
} else {
    [TimeSpan]::FromMilliseconds(160)
}
$waveTimer.Add_Tick({ Update-OrbAnimationFrame })

$window.Add_StateChanged({
    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
        $window.WindowState = [System.Windows.WindowState]::Normal
        Show-OrbView
    }
})

$window.Add_Loaded({
    Restore-WindowPosition
    Update-OrbStyleToggleVisual
    $window.Opacity = 1
    if (-not $QARenderPath) {
        $countdownTimer.Start()
        $directWorkerTimer.Start()
        $resetCreditsWorkerTimer.Start()
        $analyticsWorkerTimer.Start()
        $accountWorkerTimer.Start()
        $eventTimer.Start()
        $periodicRefreshTimer.Start()
    } elseif ($QAView -in @('daily', 'skill', 'skill-chain', 'agent', 'tool')) {
        # QA analytics renders still need to collect the supervised local worker
        # result before the screenshot timer fires.
        $analyticsWorkerTimer.Start()
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
            if ($QACustomProvider) {
                Apply-CustomProviderState
            } else {
            $qaObservedAt = [DateTimeOffset]::Now
            $qaWeeklyRemaining = if ($QAFiveHourAvailable) {
                [Math]::Min(100.0, $QARemaining + 21.0)
            } else {
                $QARemaining
            }
            $qaWeeklySnapshot = [pscustomobject]@{
                Source        = 'direct'
                Remaining     = $qaWeeklyRemaining
                UsedPercent   = 100.0 - $qaWeeklyRemaining
                ResetAt       = $qaObservedAt.AddDays(4).AddHours(8).AddMinutes(21)
                WindowMinutes = 10080L
                PlanType      = 'plus'
                LimitId       = 'codex'
                ObservedAt    = $qaObservedAt
                WindowName    = if ($QAFiveHourAvailable) { 'secondary' } else { 'primary' }
            }
            $qaFiveHourSnapshot = if ($QAFiveHourAvailable) {
                [pscustomobject]@{
                    Source        = 'direct'
                    Remaining     = $QARemaining
                    UsedPercent   = 100.0 - $QARemaining
                    ResetAt       = $qaObservedAt.AddHours(4).AddMinutes(21)
                    WindowMinutes = 300L
                    PlanType      = 'plus'
                    LimitId       = 'codex'
                    ObservedAt    = $qaObservedAt
                    WindowName    = 'primary'
                }
            } else {
                $qaWeeklySnapshot
            }
            Apply-RateWindows `
                -FiveHourSnapshot $qaFiveHourSnapshot `
                -WeeklySnapshot $qaWeeklySnapshot `
                -FiveHourUsesWeeklyFallback (-not $QAFiveHourAvailable) `
                -SkipHistory
            $SevenDayTotalText.Text = '1.28M'
            $OfficialRateText.Text = ('官方额度：5h 已用 {0:0}% · 1周已用 {1:0}%' -f
                (100.0 - $QARemaining), (100.0 - $qaWeeklyRemaining))
            Update-OrbWaterLevel $QARemaining -Immediate
            }
        } else {
            Refresh-Data -TryDirect $false
            Start-DirectRefreshAsync
        }
        switch ($QAView) {
            'orb' { Show-OrbView }
            'capacity' { Show-CapacityView }
            'account' {
                Show-CapacityView
                Show-AccountFlyout
            }
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
    $analyticsWorkerTimer.Stop()
    $accountWorkerTimer.Stop()
    $eventTimer.Stop()
    $periodicRefreshTimer.Stop()
    $waveTimer.Stop()
    Stop-OwnedProcess $script:DirectWorkerProcess
    $script:DirectWorkerProcess = $null
    Stop-OwnedProcess $script:ResetCreditsWorkerProcess
    $script:ResetCreditsWorkerProcess = $null
    Stop-OwnedProcess $script:AnalyticsWorkerProcess
    $script:AnalyticsWorkerProcess = $null
    Stop-OwnedProcess $script:AccountWorkerProcess
    $script:AccountWorkerProcess = $null
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    if ($script:TrayIconResource) {
        $script:TrayIconResource.Dispose()
        $script:TrayIconResource = $null
    }
})

try {
    [void]$window.ShowDialog()
} finally {
    try { $notifyIcon.Visible = $false; $notifyIcon.Dispose() } catch {}
    if ($script:TrayIconResource) {
        try { $script:TrayIconResource.Dispose() } catch {}
        $script:TrayIconResource = $null
    }
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
}
