$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$widget = Get-Content -LiteralPath (Join-Path $root 'CodexRateWidget.ps1') -Encoding UTF8 -Raw
$analytics = Get-Content -LiteralPath (Join-Path $root 'UsageAnalytics.py') -Encoding UTF8 -Raw

$requiredContracts = New-Object System.Collections.Generic.List[string]
$requiredContracts.Add('x:Name="ToolTabButton"')
$requiredContracts.Add('x:Name="ToolPanel"')
$requiredContracts.Add('x:Name="ToolRowsPanel"')
$requiredContracts.Add('x:Name="WorkflowHintsPanel"')
$requiredContracts.Add('x:Name="AgentSummaryText"')
$requiredContracts.Add("Set-AnalyticsTab 'tool'")
$requiredContracts.Add('0 TOKEN')
$requiredContracts.Add("Join-Path `$userProfile '.codex\skills'")
$requiredContracts.Add("`$arguments.Add('--codex-config')")

foreach ($required in $requiredContracts) {
    if (-not $widget.Contains($required)) {
        throw ('Missing analytics UI/worker contract: ' + $required)
    }
}

foreach ($forbidden in @('codex mcp', 'requests.', 'urllib.request', 'openai.', 'subprocess.')) {
    if ($widget.Contains($forbidden) -or $analytics.Contains($forbidden)) {
        throw ('Analytics must not actively query MCP: ' + $forbidden)
    }
}

if (-not $analytics.Contains('"skillAttributionVersion": 4') -or
    -not $analytics.Contains('"primaryTokens": primary_tokens') -or
    -not $analytics.Contains('"agentBreakdown": agent_breakdown_rows') -or
    -not $analytics.Contains('"tools": {') -or
    -not $analytics.Contains('"workflowHints": workflow_hints[:3]')) {
    throw 'The Skill, Agent, Tool, or deterministic hint contract is incomplete.'
}

Write-Output 'ANALYTICS_TAXONOMY_TESTS=PASS'
