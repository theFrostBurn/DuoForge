#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CodexModel,
    [Parameter(Mandatory)][ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')][string]$CodexEffort,
    [Parameter(Mandatory)][string]$ClaudeModel,
    [Parameter(Mandatory)][ValidateSet('low', 'medium', 'high', 'xhigh', 'max')][string]$ClaudeEffort,
    [string]$Workspace,
    [string]$ResumeRunId,
    [switch]$ResolveRecommendedQuestions,
    [Parameter(Mandatory)][switch]$ConfirmLive
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmLive) { throw '실제 구독 호출에는 -ConfirmLive가 필요합니다.' }

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$module = Import-Module (Join-Path $projectRoot 'src\DuoForge\DuoForge.psd1') -Force -PassThru
if ([string]::IsNullOrWhiteSpace($Workspace)) { $Workspace = Join-Path $projectRoot 'results\live-dual-e2e' }
$codexSource = Join-Path $PSScriptRoot 'fixtures\dual-live\codex\source.md'
$claudeSource = Join-Path $PSScriptRoot 'fixtures\dual-live\claude\source.md'
$beforeHashes = [ordered]@{
    codex = (Get-FileHash -LiteralPath $codexSource -Algorithm SHA256).Hash
    claude = (Get-FileHash -LiteralPath $claudeSource -Algorithm SHA256).Hash
}

$doctorBefore = Invoke-DuoForgeDoctor
if (-not [bool]$doctorBefore.readyForDocumentModes) {
    throw ('문서 모드 사전 진단이 실패했습니다: ' + ($doctorBefore.recommendations -join ' '))
}

if ([string]::IsNullOrWhiteSpace($ResumeRunId)) {
    $request = New-DuoForgeStartRequest `
        -Mode dual-document `
        -CodexDocument $codexSource `
        -ClaudeDocument $claudeSource `
        -CodexModel $CodexModel `
        -CodexReasoningEffort $CodexEffort `
        -ClaudeModel $ClaudeModel `
        -ClaudeReasoningEffort $ClaudeEffort `
        -DocumentType prd `
        -MaxRounds 2 `
        -Workspace $Workspace `
        -Name 'dual-document-live-e2e'
    $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport $doctorBefore
    if (-not [bool]$validation.valid) { throw ('실행 전 검증 실패: ' + (($validation.errors | ConvertTo-Json -Depth 20 -Compress))) }
    $run = New-DuoForgeRun -ValidationResult $validation
}
else {
    $existing = Get-DuoForgeRun -RunId $ResumeRunId -ResultsRoot $Workspace
    if ([string]$existing.manifest.providerSelections.codex.model -ne $CodexModel -or [string]$existing.manifest.providerSelections.codex.reasoningEffort -ne $CodexEffort -or [string]$existing.manifest.providerSelections.claude.model -ne $ClaudeModel -or [string]$existing.manifest.providerSelections.claude.reasoningEffort -ne $ClaudeEffort) {
        throw '재개 요청의 모델·추론 선택이 저장된 매니페스트와 다릅니다.'
    }
    $run = [ordered]@{ runId = $ResumeRunId; runDirectory = [string]$existing.runDirectory; manifest = $existing.manifest }
}
$result = & $module {
    param($runId, $resultsRoot)
    Invoke-DuoForgeResumeLiveInternal -RunId $runId -ResultsRoot $resultsRoot -LiveConsent $true
} $run.runId $Workspace

if ([string]$result.status -eq 'AWAITING_USER' -and $ResolveRecommendedQuestions) {
    $pending = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'decisions\pending.json') -Encoding UTF8 | ConvertFrom-Json -Depth 100
    $decisionPath = Join-Path $run.runDirectory 'decisions\user-answers.jsonl'
    $answeredIssueIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if (Test-Path -LiteralPath $decisionPath -PathType Leaf) {
        foreach ($record in @(Get-Content -LiteralPath $decisionPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -Depth 50 })) {
            if ([string]$record.action -eq 'ANSWER') { $null = $answeredIssueIds.Add([string]$record.issueId) }
        }
    }
    $latestQuestions = [ordered]@{}
    foreach ($question in @($pending.questions)) { $latestQuestions[[string]$question.issueKey] = $question }
    $questions = @($latestQuestions.Values)
    foreach ($question in $questions) {
        $recommended = [string]$question.recommendedOption
        if ($recommended -notin @($question.options)) { throw "권장안이 선택지에 없습니다: $($question.issueKey)" }
        $answerParameters = @{
            RunId = $run.runId
            IssueId = [string]$question.issueKey
            Choice = $recommended
            ResultsRoot = $Workspace
        }
        if ($answeredIssueIds.Contains([string]$question.issueKey)) { $answerParameters.ReplacePrevious = $true }
        $null = Set-DuoForgeIssueAnswer @answerParameters
    }
    $result = & $module {
        param($runId, $resultsRoot)
        Invoke-DuoForgeResumeLiveInternal -RunId $runId -ResultsRoot $resultsRoot -LiveConsent $true
    } $run.runId $Workspace
}

$runState = Get-DuoForgeRun -RunId $run.runId -ResultsRoot $Workspace
$afterHashes = [ordered]@{
    codex = (Get-FileHash -LiteralPath $codexSource -Algorithm SHA256).Hash
    claude = (Get-FileHash -LiteralPath $claudeSource -Algorithm SHA256).Hash
}
$events = @(Get-Content -LiteralPath (Join-Path $run.runDirectory 'events.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json -Depth 50 })
$steps = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'steps.json') -Encoding UTF8 | ConvertFrom-Json -Depth 100
$finalFiles = @(Get-ChildItem -LiteralPath (Join-Path $run.runDirectory 'final') -File)
$pendingAfter = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'decisions\pending.json') -Encoding UTF8 | ConvertFrom-Json -Depth 100
$decisionRecords = if (Test-Path -LiteralPath (Join-Path $run.runDirectory 'decisions\user-answers.jsonl') -PathType Leaf) { @(Get-Content -LiteralPath (Join-Path $run.runDirectory 'decisions\user-answers.jsonl') -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -Depth 50 }) } else { @() }
$forbiddenEvents = @($events | Where-Object { [string]$_.type -match '(?i)(tool|command|shell|web|mcp)' })
$providerWorkRoot = Join-Path $run.runDirectory 'provider-work'
$remainingProviderWork = if (Test-Path -LiteralPath $providerWorkRoot -PathType Container) { @(Get-ChildItem -LiteralPath $providerWorkRoot -Force).Count } else { 0 }
$doctorAfter = Invoke-DuoForgeDoctor

$verification = [ordered]@{
    runId = $run.runId
    runDirectory = $run.runDirectory
    status = [string]$result.status
    committedSteps = @($steps.steps | Where-Object { [string]$_.status -eq 'COMMITTED' }).Count
    totalSteps = @($steps.steps).Count
    finalFiles = @($finalFiles | ForEach-Object { $_.Name })
    forbiddenEvents = $forbiddenEvents.Count
    originalHashesUnchanged = $beforeHashes.codex -eq $afterHashes.codex -and $beforeHashes.claude -eq $afterHashes.claude
    providerWorkArtifacts = $remainingProviderWork
    subscriptionsReadyAfter = [bool]$doctorAfter.providers.codex.subscription -and [bool]$doctorAfter.providers.claude.subscription
    pendingQuestions = @($pendingAfter.questions).Count
    uniquePendingQuestions = @($pendingAfter.questions.issueKey | Sort-Object -Unique).Count
    decisionRecords = @($decisionRecords).Count
    answeredIssueIds = @($decisionRecords | Where-Object { [string]$_.action -eq 'ANSWER' } | ForEach-Object { [string]$_.issueId } | Sort-Object -Unique).Count
    selections = $run.manifest.providerSelections
}

if ($verification.status -notin @('COMPLETED', 'AWAITING_USER')) { throw ('라이브 E2E가 안전한 종료 상태에 도달하지 않았습니다: ' + ($verification | ConvertTo-Json -Depth 20 -Compress)) }
if ($verification.committedSteps -ne $verification.totalSteps) { throw ('모든 단계가 커밋되지 않았습니다: ' + ($verification | ConvertTo-Json -Depth 20 -Compress)) }
if (-not $verification.originalHashesUnchanged -or $verification.forbiddenEvents -ne 0 -or $verification.providerWorkArtifacts -ne 0 -or -not $verification.subscriptionsReadyAfter) {
    throw ('라이브 E2E 안전 검증이 실패했습니다: ' + ($verification | ConvertTo-Json -Depth 20 -Compress))
}
$verification | ConvertTo-Json -Depth 30
