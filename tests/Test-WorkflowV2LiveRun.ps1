#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][ValidateSet('shared-document', 'document-merge', 'dual-document')][string]$Mode,
    [string]$ResultsRoot
)

$ErrorActionPreference = 'Stop'

function Assert-LiveInvariant {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw "라이브 E2E 검증 실패: $Code" }
}

function Read-JsonFile {
    param([string]$Path)
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
}

function Test-HashEqual {
    param([string]$Left, [string]$Right)
    $leftHex = $Left -replace '^(?i)sha256:', ''
    $rightHex = $Right -replace '^(?i)sha256:', ''
    return [string]::Equals($leftHex, $rightHex, [StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativeSafePath {
    param([string]$Root, [string]$Path)
    return [System.IO.Path]::GetRelativePath($Root, $Path)
}

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
    $ResultsRoot = Join-Path $projectRoot 'results\workflow-v2-live-e2e'
}
$resultsFull = [System.IO.Path]::GetFullPath($ResultsRoot)
$runDirectory = [System.IO.Path]::GetFullPath((Join-Path $resultsFull $RunId))
$resultsBoundary = $resultsFull.TrimEnd('\') + '\'
Assert-LiveInvariant ($runDirectory.StartsWith($resultsBoundary, [StringComparison]::OrdinalIgnoreCase)) 'RUN_BOUNDARY'
Assert-LiveInvariant (Test-Path -LiteralPath $runDirectory -PathType Container) 'RUN_NOT_FOUND'

$fixtureRoot = Join-Path $PSScriptRoot 'fixtures\workflow-v2-live'
$inputPaths = if ($Mode -eq 'shared-document') {
    @((Join-Path $fixtureRoot 'shared\brief.md'))
}
else {
    @(
        (Join-Path $fixtureRoot 'document-a\source.md'),
        (Join-Path $fixtureRoot 'document-a\context.md'),
        (Join-Path $fixtureRoot 'document-b\source.md'),
        (Join-Path $fixtureRoot 'document-b\context.md')
    )
}
$expectedInputHashes = @{}
foreach ($path in $inputPaths) {
    $fullPath = [System.IO.Path]::GetFullPath($path)
    Assert-LiveInvariant (Test-Path -LiteralPath $fullPath -PathType Leaf) 'FIXTURE_MISSING'
    $expectedInputHashes[$fullPath] = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
}

$manifest = Read-JsonFile (Join-Path $runDirectory 'manifest.json')
$state = Read-JsonFile (Join-Path $runDirectory 'state.json')
$issues = Read-JsonFile (Join-Path $runDirectory 'issues.json')
$inventory = Read-JsonFile (Join-Path $runDirectory 'inputs\inventory.json')
$steps = Read-JsonFile (Join-Path $runDirectory 'steps.json')
$eventPath = Join-Path $runDirectory 'events.jsonl'
$eventText = Get-Content -LiteralPath $eventPath -Raw -Encoding UTF8
$events = @($eventText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -Depth 100 })

Assert-LiveInvariant ([string]$manifest.mode -ceq $Mode) 'MODE_MISMATCH'
Assert-LiveInvariant ([string]$manifest.workflowVersion -ceq 'workflow-v2') 'WORKFLOW_VERSION'
Assert-LiveInvariant ([string]$manifest.promptTemplateVersion -ceq 'duoforge-stage-v3') 'PROMPT_CONTRACT'
$manifestText = $manifest | ConvertTo-Json -Depth 100 -Compress
Assert-LiveInvariant ($manifestText -notmatch '(?i)codexDocument|claudeDocument') 'LEGACY_DOCUMENT_FIELDS'
Assert-LiveInvariant ($null -eq $inventory.roles.PSObject.Properties['codex']) 'LEGACY_CODEX_ROLE'
Assert-LiveInvariant ($null -eq $inventory.roles.PSObject.Properties['claude']) 'LEGACY_CLAUDE_ROLE'

if ($Mode -eq 'shared-document') {
    Assert-LiveInvariant ($null -ne $inventory.roles.shared) 'SHARED_ROLE'
}
else {
    Assert-LiveInvariant ($null -ne $inventory.roles.documents.A) 'DOCUMENT_A_ROLE'
    Assert-LiveInvariant ($null -ne $inventory.roles.documents.B) 'DOCUMENT_B_ROLE'
    Assert-LiveInvariant (@($inventory.roles.documents.A.context).Count -eq 1) 'DOCUMENT_A_CONTEXT'
    Assert-LiveInvariant (@($inventory.roles.documents.B.context).Count -eq 1) 'DOCUMENT_B_CONTEXT'
}

$snapshots = @($inventory.snapshots)
Assert-LiveInvariant ($snapshots.Count -eq $inputPaths.Count) 'SNAPSHOT_COUNT'
foreach ($snapshot in $snapshots) {
    $sourcePath = [System.IO.Path]::GetFullPath([string]$snapshot.sourcePath)
    Assert-LiveInvariant ($expectedInputHashes.ContainsKey($sourcePath)) 'UNEXPECTED_SOURCE'
    Assert-LiveInvariant (Test-HashEqual ([string]$snapshot.sourceHash) ([string]$expectedInputHashes[$sourcePath])) 'SOURCE_HASH_BASELINE'
    Assert-LiveInvariant (Test-HashEqual ([string]$snapshot.snapshotHash) ([string]$snapshot.sourceHash)) 'SNAPSHOT_HASH_RECORD'
    Assert-LiveInvariant (Test-HashEqual ((Get-FileHash -LiteralPath ([string]$snapshot.snapshotPath) -Algorithm SHA256).Hash) ([string]$snapshot.snapshotHash)) 'SNAPSHOT_HASH_CURRENT'
    Assert-LiveInvariant (Test-HashEqual ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash) ([string]$expectedInputHashes[$sourcePath])) 'SOURCE_HASH_CURRENT'
}

$module = Import-Module (Join-Path $projectRoot 'src\DuoForge\DuoForge.psd1') -Force -PassThru
$expectedGraph = & $module {
    param($ExpectedMode, $Rounds, $FirstSynthesizer, $BatchCount)
    New-DuoForgeStageGraph -Mode $ExpectedMode -MaxRounds $Rounds -FirstSynthesizer $FirstSynthesizer -ContextBatchCount $BatchCount -WorkflowVersion workflow-v2
} $Mode ([int]$manifest.maxRounds) ([string]$manifest.firstSynthesizer) ([int]$manifest.executionPlan.contextBatchCount)
$expectedByKey = @{}
foreach ($step in @($expectedGraph.steps)) { $expectedByKey[[string]$step.stepKey] = $step }
Assert-LiveInvariant (@($steps.steps).Count -eq @($expectedGraph.steps).Count) 'STEP_COUNT'

foreach ($step in @($steps.steps)) {
    $key = [string]$step.stepKey
    Assert-LiveInvariant ($expectedByKey.ContainsKey($key)) 'UNEXPECTED_STEP'
    $expected = $expectedByKey[$key]
    Assert-LiveInvariant ([string]$step.provider -ceq [string]$expected.provider) 'STEP_PROVIDER'
    Assert-LiveInvariant ([string]$step.performedBy -ceq [string]$expected.performedBy) 'STEP_PERFORMED_BY'
    Assert-LiveInvariant ([string]$step.stage -ceq [string]$expected.stage) 'STEP_STAGE'
    Assert-LiveInvariant ([string]$step.targetDocumentId -ceq [string]$expected.targetDocumentId) 'STEP_TARGET'
    Assert-LiveInvariant ((@($step.sourceDocumentIds) -join ',') -ceq (@($expected.sourceDocumentIds) -join ',')) 'STEP_SOURCES'
    Assert-LiveInvariant ([string]$step.status -ceq 'COMMITTED') 'STEP_NOT_COMMITTED'
    Assert-LiveInvariant (Test-Path -LiteralPath ([string]$step.artifactPath) -PathType Leaf) 'STAGE_ARTIFACT_MISSING'
    Assert-LiveInvariant (Test-HashEqual ((Get-FileHash -LiteralPath ([string]$step.artifactPath) -Algorithm SHA256).Hash) ([string]$step.artifactHash)) 'STAGE_ARTIFACT_HASH'
    $wrapper = Read-JsonFile ([string]$step.artifactPath)
    $stageResult = $wrapper.result
    $schemaValid = & $module {
        param($Result, $ExpectedStep)
        try {
            $normalizedResult = ConvertTo-DuoForgeHashtable -InputObject $Result
            $expectedStage = [string](Get-DuoForgeObjectValue -Object $ExpectedStep -Name 'stage')
            $expectedProvider = [string](Get-DuoForgeObjectValue -Object $ExpectedStep -Name 'provider')
            $expectedTarget = Get-DuoForgeObjectValue -Object $ExpectedStep -Name 'targetDocumentId'
            $expectedSources = @(Get-DuoForgeObjectValue -Object $ExpectedStep -Name 'sourceDocumentIds' -Default @())
            $validation = Test-DuoForgeStageResultInternal -Result $normalizedResult -ExpectedStage $expectedStage -ExpectedProvider $expectedProvider -WorkflowVersion workflow-v2 -ExpectedTargetDocumentId $expectedTarget -ExpectedSourceDocumentIds $expectedSources
            return [bool]$validation.valid
        }
        catch { return $false }
    } $stageResult $expected
    Assert-LiveInvariant $schemaValid 'STAGE_RESULT_SCHEMA'
}

$callCounts = [ordered]@{
    codex = @($steps.steps | Where-Object { [string]$_.provider -eq 'codex' } | Measure-Object -Property attemptCount -Sum).Sum
    claude = @($steps.steps | Where-Object { [string]$_.provider -eq 'claude' } | Measure-Object -Property attemptCount -Sum).Sum
}
foreach ($provider in @('codex', 'claude')) {
    $providerPlan = $manifest.executionPlan.providers.$provider
    Assert-LiveInvariant ([int]$callCounts[$provider] -ge [int]$providerPlan.baseCalls) 'CALL_COUNT_BELOW_BASE'
    Assert-LiveInvariant ([int]$callCounts[$provider] -le [int]$providerPlan.maximumCalls) 'CALL_COUNT_ABOVE_LIMIT'
}

$forbiddenEventTypes = @($events | Where-Object { [string]$_.type -match '(?i)(tool|command|shell|web|mcp)' })
Assert-LiveInvariant ($forbiddenEventTypes.Count -eq 0) 'FORBIDDEN_EVENT_TYPE'
$forbiddenJsonKeyPattern = '"(?i:stdout|stderr|prompt|promptText|document|documentText|context|contextText|raw|rawOutput|responseText|secret|apiKey|accessToken|refreshToken|authorization|password|content|text)"\s*:'
Assert-LiveInvariant ($eventText -notmatch $forbiddenJsonKeyPattern) 'FORBIDDEN_EVENT_DATA_KEY'
$canaries = @('WORKFLOW-V2-DOCUMENT-A', 'WORKFLOW-V2-DOCUMENT-B', '로컬 메모 도구 기획 개요')
foreach ($canary in $canaries) { Assert-LiveInvariant (-not $eventText.Contains($canary, [StringComparison]::Ordinal)) 'DOCUMENT_CONTENT_IN_EVENTS' }

$logsRoot = Join-Path $runDirectory 'logs'
$logFiles = if (Test-Path -LiteralPath $logsRoot -PathType Container) { @(Get-ChildItem -LiteralPath $logsRoot -Recurse -File -Force) } else { @() }
foreach ($logFile in $logFiles) {
    $logText = Get-Content -LiteralPath $logFile.FullName -Raw -Encoding UTF8
    Assert-LiveInvariant ($logText -notmatch $forbiddenJsonKeyPattern) 'FORBIDDEN_LOG_DATA_KEY'
    foreach ($canary in $canaries) { Assert-LiveInvariant (-not $logText.Contains($canary, [StringComparison]::Ordinal)) 'DOCUMENT_CONTENT_IN_LOGS' }
}

$providerWorkRoot = Join-Path $runDirectory 'provider-work'
$providerWorkCount = if (Test-Path -LiteralPath $providerWorkRoot -PathType Container) { @(Get-ChildItem -LiteralPath $providerWorkRoot -Force).Count } else { 0 }
Assert-LiveInvariant ($providerWorkCount -eq 0) 'PROVIDER_WORK_REMAINS'

$expectedFinalNames = switch ($Mode) {
    'shared-document' { @('PRD.md', 'DEBATE_SUMMARY.md', 'DECISIONS.md', 'OPEN_QUESTIONS.md', 'artifacts.json') }
    'document-merge' { @('PRD.md', 'source-trace.md', 'DEBATE_SUMMARY.md', 'DECISIONS.md', 'OPEN_QUESTIONS.md', 'artifacts.json') }
    'dual-document' { @('document-A-final.md', 'document-B-final.md', 'comparison.md', 'adoption-log.md', 'OPEN_QUESTIONS.md', 'artifacts.json') }
}
$finalRoot = Join-Path $runDirectory 'final'
$actualFinalNames = @(Get-ChildItem -LiteralPath $finalRoot -File | ForEach-Object { $_.Name } | Sort-Object)
Assert-LiveInvariant (($actualFinalNames -join ',') -ceq ((@($expectedFinalNames) | Sort-Object) -join ',')) 'FINAL_FILE_SET'
$artifactIndex = Read-JsonFile (Join-Path $finalRoot 'artifacts.json')
foreach ($artifact in @($artifactIndex.files)) {
    $artifactPath = Join-Path $finalRoot ([string]$artifact.name)
    Assert-LiveInvariant (Test-Path -LiteralPath $artifactPath -PathType Leaf) 'FINAL_ARTIFACT_MISSING'
    Assert-LiveInvariant (Test-HashEqual ((Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash) ([string]$artifact.sha256)) 'FINAL_ARTIFACT_HASH'
}
if ($Mode -eq 'document-merge') {
    $traceText = Get-Content -LiteralPath (Join-Path $finalRoot 'source-trace.md') -Raw -Encoding UTF8
    Assert-LiveInvariant ($traceText.Contains('원천 문서', [StringComparison]::Ordinal)) 'SOURCE_TRACE_COLUMNS'
    Assert-LiveInvariant ($traceText.Contains('제안 작업자', [StringComparison]::Ordinal)) 'SOURCE_TRACE_PROVIDER_COLUMN'
}
if ($Mode -eq 'dual-document') {
    $adoptionText = Get-Content -LiteralPath (Join-Path $finalRoot 'adoption-log.md') -Raw -Encoding UTF8
    Assert-LiveInvariant ($adoptionText.Contains('원천 문서', [StringComparison]::Ordinal)) 'ADOPTION_SOURCE_COLUMN'
    Assert-LiveInvariant ($adoptionText.Contains('편집 작업자', [StringComparison]::Ordinal)) 'ADOPTION_EDITOR_COLUMN'
}

$safeStatus = [string]$state.status
$allowedStatuses = @('COMPLETED', 'COMPLETED_PARTIAL', 'AWAITING_USER', 'AWAITING_EVIDENCE')
Assert-LiveInvariant ($safeStatus -in $allowedStatuses) 'UNSAFE_END_STATE'
$statusBlockingIssues = if ($safeStatus -in @('AWAITING_USER', 'AWAITING_EVIDENCE')) {
    @($issues.issues | Where-Object {
        [bool]$_.blocking -and
        [string]$_.severity -in @('critical', 'major') -and
        [string]$_.resolutionStatus -ceq $safeStatus
    })
}
else {
    @()
}
if ($safeStatus -in @('AWAITING_USER', 'AWAITING_EVIDENCE')) {
    Assert-LiveInvariant ($statusBlockingIssues.Count -gt 0) 'WAITING_STATUS_WITHOUT_BLOCKING_ISSUE'
}
[ordered]@{
    schemaVersion = 1
    runId = $RunId
    mode = $Mode
    workflowVersion = [string]$manifest.workflowVersion
    status = $safeStatus
    statusBlockingIssues = $statusBlockingIssues.Count
    totalSteps = @($steps.steps).Count
    committedSteps = @($steps.steps | Where-Object { [string]$_.status -eq 'COMMITTED' }).Count
    calls = $callCounts
    inputHashesUnchanged = $true
    snapshotHashesVerified = $snapshots.Count
    forbiddenEventTypes = 0
    forbiddenEventDataKeys = 0
    documentCanariesInEventsOrLogs = 0
    providerWorkArtifacts = 0
    finalFiles = $actualFinalNames
    runDirectory = Get-RelativeSafePath -Root $projectRoot -Path $runDirectory
} | ConvertTo-Json -Depth 10
