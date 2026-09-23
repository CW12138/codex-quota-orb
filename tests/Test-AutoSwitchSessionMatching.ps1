$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'AccountSwitcher.psm1') -Force
$module = Get-Module AccountSwitcher

& $module {
    $rolloutPath = Join-Path ([IO.Path]::GetTempPath()) ('cqo-active-turn-' + [Guid]::NewGuid().ToString('N') + '.jsonl')
    $taskStarted = '{"timestamp":"2026-09-23T00:00:00Z","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"test"}}'
    $taskComplete = '{"timestamp":"2026-09-23T00:00:01Z","ordinal":2,"type":"event_msg","payload":{"type":"task_complete","turn_id":"test"}}'
    try {
        [IO.File]::WriteAllLines($rolloutPath, @($taskStarted), (New-Object Text.UTF8Encoding($false)))
        if (-not (Test-CqoRolloutHasActiveTurn -Path $rolloutPath)) { throw 'An unfinished task was not detected.' }
        [IO.File]::AppendAllText($rolloutPath, $taskComplete + [Environment]::NewLine)
        if (Test-CqoRolloutHasActiveTurn -Path $rolloutPath) { throw 'A completed task was classified as active.' }
    } finally {
        if (Test-Path -LiteralPath $rolloutPath) { Remove-Item -LiteralPath $rolloutPath -Force }
    }

    $firstId = '11111111-1111-4111-8111-111111111111'
    $secondId = '22222222-2222-4222-8222-222222222222'
    $base = (Get-Date).AddMinutes(-5)
    $firstStart = $base
    $secondStart = $base.AddMinutes(2)
    $script:TestSessions = @(
        [pscustomobject]@{ id=$secondId; createdAt=([DateTimeOffset]$secondStart.AddSeconds(21)).ToUnixTimeSeconds(); status=[pscustomobject]@{ type='notLoaded' }; cwd='C:\second' },
        [pscustomobject]@{ id=$firstId; createdAt=([DateTimeOffset]$firstStart.AddSeconds(23)).ToUnixTimeSeconds(); status=[pscustomobject]@{ type='notLoaded' }; cwd='C:\first' }
    )
    function script:Invoke-CqoRpcRequest {
        param($Method,$Params,$TimeoutSeconds,$Environment,[switch]$ForceChatGptProvider)
        if ($Method -eq 'thread/list') {
            return [pscustomobject]@{ data=$script:TestSessions; nextCursor=$null }
        }
        if ($Method -eq 'thread/read') {
            $thread = @($script:TestSessions | Where-Object { $_.id -eq $Params.threadId } | Select-Object -First 1)
            if ($thread.Count -eq 0) { throw 'Unknown thread' }
            return [pscustomobject]@{ thread=[pscustomobject]@{
                id=$thread[0].id; cwd=$thread[0].cwd
                turns=@([pscustomobject]@{ status='completed'; items=@() })
            } }
        }
        throw ('Unexpected method: ' + $Method)
    }

    $processes = @(
        [pscustomobject]@{ ProcessId=201; CreationDate=$firstStart; CommandLine='"C:\codex.exe"' },
        [pscustomobject]@{ ProcessId=202; CreationDate=$secondStart; CommandLine='"C:\codex.exe"' }
    )
    $plans = @(Get-CqoProcessResumePlans -Processes $processes)
    if ($plans.Count -ne 2 -or $plans[0].threadId -ne $firstId -or $plans[1].threadId -ne $secondId) {
        throw 'Bare Codex terminals were not matched to their own persisted sessions.'
    }
    if ($plans[0].processId -ne 201 -or $plans[1].processId -ne 202 -or $plans[0].cwd -ne 'C:\first') {
        throw 'Session plans lost their terminal or working-directory association.'
    }

    $explicit = [pscustomobject]@{ ProcessId=203; CreationDate=$base.AddHours(1); CommandLine=('"C:\codex.exe" -p work resume "' + $firstId + '"') }
    $explicitPlans = @(Get-CqoProcessResumePlans -Processes @($explicit))
    if ($explicitPlans.Count -ne 1 -or $explicitPlans[0].threadId -ne $firstId) {
        throw 'An explicit resume id must win over process start-time matching.'
    }

    $script:TestSessions = @($script:TestSessions[0])
    try {
        [void](Get-CqoProcessResumePlans -Processes $processes)
        throw 'Expected ambiguous multi-terminal preflight to fail.'
    } catch {
        if ($_.Exception.Message -notmatch 'Codex') { throw }
    }

    $script:TestSessions = @()
    try {
        [void](Get-CqoProcessResumePlans -Processes @($processes[0]))
        throw 'Expected unmatched single-terminal preflight to fail.'
    } catch {
        if ($_.Exception.Message -notmatch 'Codex') { throw }
    }
}

Write-Output 'AUTO_SWITCH_SESSION_MATCHING_TESTS=PASS'
