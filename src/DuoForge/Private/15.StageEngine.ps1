function New-DuoForgeStageRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StepKey,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][int]$Round,
        [Parameter(Mandatory)][string]$Stage,
        [string[]]$DependsOn = @(),
        [ValidateSet('workflow-v1', 'workflow-v2')][string]$WorkflowVersion = 'workflow-v2',
        [ValidateSet('A', 'B', 'merged')][string]$TargetDocumentId,
        [string[]]$SourceDocumentIds = @()
    )

    $record = [ordered]@{
        stepKey = $StepKey
        provider = $Provider
        round = $Round
        stage = $Stage
        dependsOn = @($DependsOn)
        status = 'PENDING'
        attemptCount = 0
        totalAttemptCount = 0
        inputGeneration = 1
        inputHash = $null
        artifactPath = $null
        artifactHash = $null
        lastError = $null
        retryMode = $null
        lastPromptKind = $null
        history = @()
    }
    if ($WorkflowVersion -eq 'workflow-v2') {
        $record.performedBy = $Provider
        $record.targetDocumentId = if ([string]::IsNullOrWhiteSpace($TargetDocumentId)) { $null } else { $TargetDocumentId }
        $record.sourceDocumentIds = @($SourceDocumentIds)
    }
    return $record
}

function New-DuoForgeStageGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('shared-document', 'document-merge', 'dual-document')][string]$Mode,
        [ValidateRange(2, 3)][int]$MaxRounds = 2,
        [ValidateSet('alternate', 'codex', 'claude')][string]$FirstSynthesizer = 'alternate',
        [ValidateRange(0, 100)][int]$ContextBatchCount = 0,
        [AllowEmptyCollection()][string[]]$ContextBatchDocumentIds = @(),
        [ValidateSet('workflow-v1', 'workflow-v2')][string]$WorkflowVersion = 'workflow-v2'
    )

    if ($Mode -eq 'document-merge' -and $WorkflowVersion -ne 'workflow-v2') {
        throw (New-DuoForgeException -Code 'DF-WORKFLOW-MODE' -Message 'document-merge는 workflow-v2에서만 지원합니다.')
    }

    $steps = [System.Collections.Generic.List[object]]::new()
    $contextBarrier = [System.Collections.Generic.List[string]]::new()
    if ($ContextBatchCount -gt 0) {
        for ($batch = 1; $batch -le $ContextBatchCount; $batch++) {
            $batchId = 'batch-{0:D3}' -f $batch
            $hasSemanticBatchLineage = (
                $ContextBatchDocumentIds.Count -ge $batch -and [string]$ContextBatchDocumentIds[$batch - 1] -in @('A', 'B')
            )
            $contextSourceDocumentIds = if ($Mode -eq 'shared-document') { @('brief') } elseif ($hasSemanticBatchLineage) { @([string]$ContextBatchDocumentIds[$batch - 1]) } else { @('A', 'B') }
            foreach ($provider in @('codex', 'claude')) {
                $key = "context-$batchId-$provider-analysis"
                $recordParameters = @{
                    StepKey = $key
                    Provider = $provider
                    Round = 0
                    Stage = 'context-batch-analysis'
                    WorkflowVersion = $WorkflowVersion
                    SourceDocumentIds = $contextSourceDocumentIds
                }
                if ($Mode -eq 'document-merge' -and $hasSemanticBatchLineage) { $recordParameters.TargetDocumentId = 'merged' }
                $record = New-DuoForgeStageRecord @recordParameters
                $record.contextBatchId = $batchId
                $steps.Add($record)
                $contextBarrier.Add($key)
            }
        }
    }
    $previousBarrier = @($contextBarrier)
    if ($Mode -in @('shared-document', 'document-merge')) {
        $sourceDocumentIds = if ($Mode -eq 'shared-document') { @('brief') } else { @('A', 'B') }
        $targetDocumentId = 'merged'
        $initialDraftStage = if ($Mode -eq 'document-merge') { 'independent-merge-draft' } else { 'independent-draft' }
        $first = if ($FirstSynthesizer -eq 'claude') { 'claude' } else { 'codex' }
        for ($round = 1; $round -le $MaxRounds; $round++) {
            if ($round -eq 1) {
                $drafts = @('codex', 'claude') | ForEach-Object { "r$('{0:D2}' -f $round)-$_-$initialDraftStage" }
                foreach ($provider in @('codex', 'claude')) {
                    $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $round)-$provider-$initialDraftStage" -Provider $provider -Round $round -Stage $initialDraftStage -DependsOn $previousBarrier -WorkflowVersion $WorkflowVersion -TargetDocumentId $targetDocumentId -SourceDocumentIds $sourceDocumentIds))
                }
                $reviewDependencies = $drafts
                $reviewStage = 'cross-review'
            }
            else {
                $reviewDependencies = $previousBarrier
                $reviewStage = 'joint-document-review'
            }

            $reviews = @('codex', 'claude') | ForEach-Object { "r$('{0:D2}' -f $round)-$_-$reviewStage" }
            foreach ($provider in @('codex', 'claude')) {
                $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $round)-$provider-$reviewStage" -Provider $provider -Round $round -Stage $reviewStage -DependsOn $reviewDependencies -WorkflowVersion $WorkflowVersion -TargetDocumentId $targetDocumentId -SourceDocumentIds $sourceDocumentIds))
            }

            $responseStage = if ($round -eq 1 -and $Mode -eq 'shared-document') { 'author-response' } else { 'review-response' }
            $responses = @('codex', 'claude') | ForEach-Object { "r$('{0:D2}' -f $round)-$_-$responseStage" }
            foreach ($provider in @('codex', 'claude')) {
                $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $round)-$provider-$responseStage" -Provider $provider -Round $round -Stage $responseStage -DependsOn $reviews -WorkflowVersion $WorkflowVersion -TargetDocumentId $targetDocumentId -SourceDocumentIds $sourceDocumentIds))
            }

            $synthesizer = if (($round % 2) -eq 1) { $first } elseif ($first -eq 'codex') { 'claude' } else { 'codex' }
            $synthesisKey = "r$('{0:D2}' -f $round)-$synthesizer-synthesis"
            $steps.Add((New-DuoForgeStageRecord -StepKey $synthesisKey -Provider $synthesizer -Round $round -Stage 'synthesis' -DependsOn $responses -WorkflowVersion $WorkflowVersion -TargetDocumentId $targetDocumentId -SourceDocumentIds $sourceDocumentIds))
            $previousBarrier = @($synthesisKey)
        }

        $lastSynthesizer = $steps[$steps.Count - 1].provider
        $validator = if ($lastSynthesizer -eq 'codex') { 'claude' } else { 'codex' }
        $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $MaxRounds)-$validator-final-validation" -Provider $validator -Round $MaxRounds -Stage 'final-validation' -DependsOn $previousBarrier -WorkflowVersion $WorkflowVersion -TargetDocumentId $targetDocumentId -SourceDocumentIds $sourceDocumentIds))
    }
    elseif ($WorkflowVersion -eq 'workflow-v1') {
        for ($round = 1; $round -le $MaxRounds; $round++) {
            $reviews = @('codex', 'claude') | ForEach-Object { "r$('{0:D2}' -f $round)-$_-cross-review" }
            foreach ($provider in @('codex', 'claude')) {
                $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $round)-$provider-cross-review" -Provider $provider -Round $round -Stage 'cross-review' -DependsOn $previousBarrier -WorkflowVersion 'workflow-v1'))
            }
            $responses = @('codex', 'claude') | ForEach-Object { "r$('{0:D2}' -f $round)-$_-owner-response" }
            foreach ($provider in @('codex', 'claude')) {
                $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $round)-$provider-owner-response" -Provider $provider -Round $round -Stage 'owner-response' -DependsOn $reviews -WorkflowVersion 'workflow-v1'))
            }
            $revisions = @('codex', 'claude') | ForEach-Object { "r$('{0:D2}' -f $round)-$_-owned-document-revision" }
            foreach ($provider in @('codex', 'claude')) {
                $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $round)-$provider-owned-document-revision" -Provider $provider -Round $round -Stage 'owned-document-revision' -DependsOn $responses -WorkflowVersion 'workflow-v1'))
            }
            $previousBarrier = $revisions
        }
    }
    else {
        for ($round = 1; $round -le $MaxRounds; $round++) {
            $roundPrefix = 'r{0:D2}' -f $round
            $reviews = @('codex', 'claude') | ForEach-Object { "$roundPrefix-$_-document-review" }
            foreach ($provider in @('codex', 'claude')) {
                $steps.Add((New-DuoForgeStageRecord -StepKey "$roundPrefix-$provider-document-review" -Provider $provider -Round $round -Stage 'document-review' -DependsOn $previousBarrier -WorkflowVersion 'workflow-v2' -SourceDocumentIds @('A', 'B')))
            }
            $responses = @('codex', 'claude') | ForEach-Object { "$roundPrefix-$_-review-response" }
            foreach ($provider in @('codex', 'claude')) {
                $steps.Add((New-DuoForgeStageRecord -StepKey "$roundPrefix-$provider-review-response" -Provider $provider -Round $round -Stage 'review-response' -DependsOn $reviews -WorkflowVersion 'workflow-v2' -SourceDocumentIds @('A', 'B')))
            }

            $editorA = if (($round % 2) -eq 1) { 'codex' } else { 'claude' }
            $editorB = if ($editorA -eq 'codex') { 'claude' } else { 'codex' }
            $revisionA = "$roundPrefix-$editorA-document-a-revision"
            $revisionB = "$roundPrefix-$editorB-document-b-revision"
            $steps.Add((New-DuoForgeStageRecord -StepKey $revisionA -Provider $editorA -Round $round -Stage 'document-revision' -DependsOn $responses -WorkflowVersion 'workflow-v2' -TargetDocumentId A -SourceDocumentIds @('A', 'B')))
            $steps.Add((New-DuoForgeStageRecord -StepKey $revisionB -Provider $editorB -Round $round -Stage 'document-revision' -DependsOn $responses -WorkflowVersion 'workflow-v2' -TargetDocumentId B -SourceDocumentIds @('A', 'B')))
            $previousBarrier = @($revisionA, $revisionB)
        }

        foreach ($documentId in @('A', 'B')) {
            $lastEditor = if ($documentId -eq 'A') {
                if (($MaxRounds % 2) -eq 1) { 'codex' } else { 'claude' }
            }
            else {
                if (($MaxRounds % 2) -eq 1) { 'claude' } else { 'codex' }
            }
            $validator = if ($lastEditor -eq 'codex') { 'claude' } else { 'codex' }
            $documentToken = $documentId.ToLowerInvariant()
            $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $MaxRounds)-$validator-document-$documentToken-validation" -Provider $validator -Round $MaxRounds -Stage 'document-validation' -DependsOn $previousBarrier -WorkflowVersion 'workflow-v2' -TargetDocumentId $documentId -SourceDocumentIds @($documentId)))
        }
    }

    return [ordered]@{
        schemaVersion = if ($WorkflowVersion -eq 'workflow-v2') { 2 } else { 1 }
        workflowVersion = $WorkflowVersion
        mode = $Mode
        maxRounds = $MaxRounds
        steps = @($steps)
    }
}

function Get-DuoForgeContextBatchDocumentIdsInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $path = Join-Path $RunDirectory 'inputs\context-plan.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $plan = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $path)
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($batch in @($plan.batches)) { $values.Add([string](Get-DuoForgeObjectValue -Object $batch -Name 'documentId' -Default '')) }
    return @($values)
}

function Get-DuoForgeContextEvidenceContractForStepInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Step
    )

    if ([string]$Step.stage -ne 'context-batch-analysis') { return $null }
    $path = Join-Path $RunDirectory 'inputs\context-plan.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw (New-DuoForgeException -Code 'DF-RUN-STORAGE-CONTRACT' -Message '문맥 배치 단계의 context-plan을 찾을 수 없습니다.') }
    $plan = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $path)
    if ([int](Get-DuoForgeObjectValue -Object $plan -Name 'schemaVersion' -Default 1) -ne 2) { return $null }
    $batchId = [string](Get-DuoForgeObjectValue -Object $Step -Name 'contextBatchId' -Default '')
    $batch = @($plan.batches | Where-Object { [string]$_.batchId -eq $batchId })
    if ($batch.Count -ne 1) { throw (New-DuoForgeException -Code 'DF-RUN-STORAGE-CONTRACT' -Message "문맥 배치 단계의 계획 항목이 없거나 중복되었습니다: $batchId") }
    $contract = Get-DuoForgeObjectValue -Object $batch[0] -Name 'evidenceContract'
    if ($contract -isnot [System.Collections.IDictionary]) { throw (New-DuoForgeException -Code 'DF-RUN-STORAGE-CONTRACT' -Message "schema 2 문맥 배치의 CORE 근거 계약이 없습니다: $batchId") }
    foreach ($name in @('sourceDocumentId', 'path', 'location', 'excerptHash')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $contract -Name $name -Default ''))) { throw (New-DuoForgeException -Code 'DF-RUN-STORAGE-CONTRACT' -Message "schema 2 문맥 배치의 CORE 근거 계약이 불완전합니다: $batchId/$name") }
    }
    return ConvertTo-DuoForgeHashtable -InputObject $contract
}

function Initialize-DuoForgeStageGraph {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $path = Join-Path $RunDirectory 'steps.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $stored = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $path)
        foreach ($step in @($stored.steps)) {
            if (-not $step.Contains('totalAttemptCount')) { $step.totalAttemptCount = [int](Get-DuoForgeObjectValue -Object $step -Name 'attemptCount' -Default 0) }
            if (-not $step.Contains('inputGeneration')) { $step.inputGeneration = 1 }
        }
        return $stored
    }
    $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
    $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
    $firstSynthesizer = if ([string]::IsNullOrWhiteSpace([string]$manifest.firstSynthesizer)) { 'alternate' } else { [string]$manifest.firstSynthesizer }
    $contextPlanPath = Join-Path $RunDirectory 'inputs\context-plan.json'
    $contextBatchCount = if (Test-Path -LiteralPath $contextPlanPath -PathType Leaf) { @((Read-DuoForgeJson -Path $contextPlanPath).batches).Count } else { 0 }
    $contextBatchDocumentIds = @(Get-DuoForgeContextBatchDocumentIdsInternal -RunDirectory $RunDirectory)
    $graph = New-DuoForgeStageGraph -Mode ([string]$manifest.mode) -MaxRounds ([int]$manifest.maxRounds) -FirstSynthesizer $firstSynthesizer -ContextBatchCount $contextBatchCount -ContextBatchDocumentIds $contextBatchDocumentIds -WorkflowVersion $workflowVersion
    Write-DuoForgeJsonAtomic -Path $path -Value $graph
    return $graph
}

function Get-DuoForgeReadySteps {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Graph)

    $committed = @{}
    foreach ($step in $Graph.steps) {
        if ([string]$step.status -eq 'COMMITTED') { $committed[[string]$step.stepKey] = $true }
    }
    return @($Graph.steps | Where-Object {
        $isReady = [string]$_.status -in @('PENDING', 'FAILED', 'STALE')
        if ($isReady) {
            foreach ($dependency in @($_.dependsOn)) {
                if (-not $committed.ContainsKey([string]$dependency)) {
                    $isReady = $false
                    break
                }
            }
        }
        $isReady
    })
}

function Test-DuoForgeFormatRecoveryErrorInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Code)

    return $Code -in @(
        'DF-STAGE-SCHEMA', 'DF-PROVIDER-JSON', 'DF-CLAUDE-ENVELOPE',
        'DF-CLAUDE-RESULT', 'DF-CLAUDE-STRUCTURED-OUTPUT', 'DF-CODEX-LAST-MESSAGE'
    )
}

function Repair-DuoForgeCorruptedStageArtifactsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Graph
    )

    $invalidKeys = [System.Collections.Generic.List[string]]::new()
    $invalidReasons = [ordered]@{}
    $workflowVersion = [string](Get-DuoForgeObjectValue -Object $Graph -Name 'workflowVersion' -Default 'workflow-v1')
    foreach ($step in @($Graph.steps | Where-Object { [string]$_.status -eq 'COMMITTED' })) {
        $valid = $true
        $path = [string]$step.artifactPath
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $valid = $false
            $invalidReasons[[string]$step.stepKey] = 'ARTIFACT_MISSING'
        }
        elseif ((Get-DuoForgeSha256 -Path $path) -ne [string]$step.artifactHash) {
            $valid = $false
            $invalidReasons[[string]$step.stepKey] = 'ARTIFACT_HASH_MISMATCH'
        }
        else {
            try {
                $wrapper = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $path)
                $issueTargets = if ($workflowVersion -eq 'workflow-v2') { Get-DuoForgeIssueTargetMapsInternal -RunDirectory $RunDirectory -Graph $Graph -ExcludeStepKey ([string]$step.stepKey) } else { $null }
                $contextEvidenceContract = Get-DuoForgeContextEvidenceContractForStepInternal -RunDirectory $RunDirectory -Step $step
                $null = Test-DuoForgeStageResultInternal -Result $wrapper.result -ExpectedStage ([string]$step.stage) -ExpectedProvider ([string]$step.provider) -WorkflowVersion $workflowVersion -ExpectedTargetDocumentId (Get-DuoForgeObjectValue -Object $step -Name 'targetDocumentId') -ExpectedSourceDocumentIds @(Get-DuoForgeObjectValue -Object $step -Name 'sourceDocumentIds' -Default @()) -DefinitionIssueTargets $(if ($null -eq $issueTargets) { $null } else { $issueTargets.definitionTargets }) -ReferenceIssueTargets $(if ($null -eq $issueTargets) { $null } else { $issueTargets.referenceTargets }) -ReservedIssueFingerprints $(if ($null -eq $issueTargets) { $null } else { $issueTargets.reservedFingerprints }) -ContextEvidenceContract $contextEvidenceContract -ThrowOnIssueReferenceIntegrityError -ThrowOnError
            }
            catch {
                if ($_.Exception.Data.Contains('DuoForgeCode') -and [string]$_.Exception.Data['DuoForgeCode'] -eq 'DF-ISSUE-REFERENCE-INTEGRITY') { throw }
                $valid = $false
                $invalidReasons[[string]$step.stepKey] = 'ARTIFACT_SCHEMA_INVALID'
            }
        }
        if (-not $valid) { $invalidKeys.Add([string]$step.stepKey) }
    }
    if ($invalidKeys.Count -eq 0) { return [ordered]@{ repaired = $false; invalidSteps = @(); staleSteps = @(); invalidReasons = [ordered]@{} } }

    $staleKeys = @{}
    foreach ($key in $invalidKeys) { $staleKeys[$key] = $true }
    do {
        $added = $false
        foreach ($step in @($Graph.steps)) {
            if ($staleKeys.ContainsKey([string]$step.stepKey)) { continue }
            if (@($step.dependsOn | Where-Object { $staleKeys.ContainsKey([string]$_) }).Count -gt 0) {
                $staleKeys[[string]$step.stepKey] = $true
                $added = $true
            }
        }
    } while ($added)

    $historyDirectory = Join-Path $RunDirectory 'history\stages'
    [System.IO.Directory]::CreateDirectory($historyDirectory) | Out-Null
    foreach ($step in @($Graph.steps | Where-Object { $staleKeys.ContainsKey([string]$_.stepKey) })) {
        $oldPath = [string]$step.artifactPath
        $historyRecord = [ordered]@{
            invalidatedAt = Get-DuoForgeUtcNow
            previousStatus = [string]$step.status
            previousArtifactHash = [string]$step.artifactHash
            reason = if ([string]$step.stepKey -in @($invalidKeys)) { [string]$invalidReasons[[string]$step.stepKey] } else { 'DEPENDS_ON_INVALID_ARTIFACT' }
            preservedPath = $null
        }
        if (-not [string]::IsNullOrWhiteSpace($oldPath) -and (Test-Path -LiteralPath $oldPath -PathType Leaf)) {
            $suffix = Get-DuoForgeArtifactHistorySuffixInternal -ArtifactHash ([string]$step.artifactHash)
            $preservedPath = Join-Path $historyDirectory ("{0}-{1}.json" -f [string]$step.stepKey, $suffix)
            [System.IO.File]::Copy($oldPath, $preservedPath, $true)
            $historyRecord.preservedPath = $preservedPath
        }
        $existingHistory = [System.Collections.Generic.List[object]]::new()
        if ($step.Contains('history')) { foreach ($entry in @($step.history)) { $existingHistory.Add($entry) } }
        $existingHistory.Add($historyRecord)
        $step.history = @($existingHistory)
        if ([string]$historyRecord.previousStatus -eq 'COMMITTED') {
            if (-not $step.Contains('totalAttemptCount')) { $step.totalAttemptCount = [int](Get-DuoForgeObjectValue -Object $step -Name 'attemptCount' -Default 0) }
            $step.attemptCount = 0
            $step.inputGeneration = [int](Get-DuoForgeObjectValue -Object $step -Name 'inputGeneration' -Default 1) + 1
        }
        $step.status = 'STALE'
        $step.inputHash = $null
        $step.artifactPath = $null
        $step.artifactHash = $null
        $step.lastError = $null
        $step.retryMode = $null
        $step.lastPromptKind = $null
    }
    Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'STAGE_ARTIFACTS_INVALIDATED' -Status 'RESUMABLE_ERROR' -Data ([ordered]@{ invalidSteps = @($invalidKeys); staleSteps = @($staleKeys.Keys); rules = @($invalidReasons.Values | Sort-Object -Unique) })
    return [ordered]@{ repaired = $true; invalidSteps = @($invalidKeys); staleSteps = @($staleKeys.Keys); invalidReasons = $invalidReasons }
}

function Repair-DuoForgeInterruptedStartedStepsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Graph,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$State
    )

    $recovered = [System.Collections.Generic.List[object]]::new()
    foreach ($step in @($Graph.steps | Where-Object { [string]$_.status -eq 'STARTED' })) {
        $retryExhausted = [int]$step.attemptCount -ge 2
        $errorCode = if ($retryExhausted) { 'DF-STAGE-RETRY-EXHAUSTED' } else { 'DF-STAGE-INTERRUPTED' }
        $retryMode = if ($retryExhausted) { 'RETRY_EXHAUSTED' } else { 'STANDARD_RETRY' }
        $providers = Get-DuoForgeObjectValue -Object $Manifest -Name 'providers' -Default ([ordered]@{})
        $diagnostic = Write-DuoForgeDiagnosticInternal -RunDirectory $RunDirectory -Code $errorCode -Category 'interrupted-process' -Phase 'recovery' -Scope 'run' `
            -Run ([ordered]@{ runId = Get-DuoForgeObjectValue -Object $Manifest -Name 'runId'; workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $Manifest; status = Get-DuoForgeObjectValue -Object $State -Name 'status'; lastCompletedStage = Get-DuoForgeObjectValue -Object $State -Name 'lastCompletedStage' }) `
            -Step ([ordered]@{ stepKey = $step.stepKey; provider = $step.provider; stage = $step.stage; targetDocumentId = Get-DuoForgeObjectValue -Object $step -Name 'targetDocumentId'; round = $step.round; attempt = $step.attemptCount }) `
            -Recovery ([ordered]@{ retryable = -not $retryExhausted; retryMode = $retryMode; scheduled = -not $retryExhausted }) `
            -ProviderVersions ([ordered]@{ codex = Get-DuoForgeObjectValue -Object (Get-DuoForgeObjectValue -Object $providers -Name 'codex') -Name 'version'; claude = Get-DuoForgeObjectValue -Object (Get-DuoForgeObjectValue -Object $providers -Name 'claude') -Name 'version' })
        $correlation = Get-DuoForgeDiagnosticCorrelationInternal -Diagnostic $diagnostic
        $step.status = 'FAILED'
        $step.retryMode = $retryMode
        $step.lastError = [ordered]@{
            category = 'interrupted-process'
            code = $errorCode
            exceptionType = 'InterruptedProcess'
            retryable = -not $retryExhausted
            attempt = [int]$step.attemptCount
            at = Get-DuoForgeUtcNow
            diagnosticId = $correlation.diagnosticId
            diagnosticsLocation = $correlation.diagnosticsLocation
            diagnosticsRelativePath = $correlation.diagnosticsRelativePath
            diagnosticWarningCode = $correlation.diagnosticWarningCode
        }
        $recovered.Add([ordered]@{
            stepKey = [string]$step.stepKey
            provider = [string]$step.provider
            stage = [string]$step.stage
            round = [int]$step.round
            attempt = [int]$step.attemptCount
            retryExhausted = $retryExhausted
            code = $errorCode
            retryable = -not $retryExhausted
            diagnosticId = $correlation.diagnosticId
            diagnosticsLocation = $correlation.diagnosticsLocation
            diagnosticsRelativePath = $correlation.diagnosticsRelativePath
            diagnosticWarningCode = $correlation.diagnosticWarningCode
            diagnosticsPath = [string]$diagnostic.diagnosticsPath
        })
    }
    return @($recovered)
}

function Add-DuoForgeProgressRunEventInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Status,
        [System.Collections.IDictionary]$Data = ([ordered]@{})
    )

    try { Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type $Type -Status $Status -Data $Data }
    catch { Write-Verbose 'DuoForge 진행 이벤트 기록 오류를 무시했습니다.' }
}

function Resolve-DuoForgeStageFailureInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$WorkflowVersion,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Graph,
        [Parameter(Mandatory)]$Step,
        [Parameter(Mandatory)]$ErrorRecord,
        [scriptblock]$ProgressObserver,
        [int]$Invoked = 0
    )

    $preservedRetryMode = [string](Get-DuoForgeObjectValue -Object $Step -Name 'retryMode' -Default '')
    $Step.status = 'FAILED'
    $errorCode = if ($ErrorRecord.Exception.Data.Contains('DuoForgeCode')) { [string]$ErrorRecord.Exception.Data['DuoForgeCode'] } else { 'DF-STAGE-UNEXPECTED' }
    $failureCategory = if ($ErrorRecord.Exception.Data.Contains('DuoForgeFailureCategory')) { [string]$ErrorRecord.Exception.Data['DuoForgeFailureCategory'] } else { 'provider-error' }
    $targetStatus = if ($ErrorRecord.Exception.Data.Contains('DuoForgeFailureStatus')) { [string]$ErrorRecord.Exception.Data['DuoForgeFailureStatus'] } else { 'RESUMABLE_ERROR' }
    $retryable = if ($ErrorRecord.Exception.Data.Contains('DuoForgeRetryable')) {
        [bool]$ErrorRecord.Exception.Data['DuoForgeRetryable']
    }
    else {
        $errorCode -in @('DF-STAGE-SCHEMA', 'DF-PROVIDER-JSON', 'DF-CLAUDE-ENVELOPE', 'DF-CLAUDE-RESULT', 'DF-CLAUDE-STRUCTURED-OUTPUT', 'DF-CODEX-LAST-MESSAGE')
    }
    $formatRecovery = Test-DuoForgeFormatRecoveryErrorInternal -Code $errorCode
    $runtimeLimit = $errorCode -ceq 'DF-RUN-TIME-LIMIT'
    $referenceRepairRequired = $errorCode -ceq 'DF-STAGE-REFERENCE'
    $retryExhausted = -not $runtimeLimit -and $retryable -and [int]$Step.attemptCount -ge 2
    $retryScheduled = -not $runtimeLimit -and $retryable -and [int]$Step.attemptCount -lt 2
    $Step.retryMode = if ($runtimeLimit) { $preservedRetryMode } elseif ($referenceRepairRequired) { 'REFERENCE_REPAIR_REQUIRED' } elseif ($retryExhausted) { 'RETRY_EXHAUSTED' } elseif ($retryScheduled -and $formatRecovery) { 'FORMAT_REPAIR' } elseif ($retryScheduled) { 'STANDARD_RETRY' } else { $null }
    $processMetadata = if ($ErrorRecord.Exception.Data.Contains('DuoForgeProcess')) { Get-DuoForgeSafeProcessMetadataInternal -ProcessResult $ErrorRecord.Exception.Data['DuoForgeProcess'] } else { $null }
    $providers = Get-DuoForgeObjectValue -Object $Manifest -Name 'providers' -Default ([ordered]@{})
    $diagnostic = Write-DuoForgeDiagnosticInternal -RunDirectory $RunDirectory -Code $errorCode -Category $failureCategory -Phase 'stage' -Scope 'run' `
        -Run ([ordered]@{ runId = Get-DuoForgeObjectValue -Object $Manifest -Name 'runId'; workflowVersion = $WorkflowVersion; status = Get-DuoForgeObjectValue -Object $State -Name 'status'; lastCompletedStage = Get-DuoForgeObjectValue -Object $State -Name 'lastCompletedStage' }) `
        -Step ([ordered]@{ stepKey = $Step.stepKey; provider = $Step.provider; stage = $Step.stage; targetDocumentId = Get-DuoForgeObjectValue -Object $Step -Name 'targetDocumentId'; round = $Step.round; attempt = $Step.attemptCount }) `
        -Process $processMetadata -Recovery ([ordered]@{ retryable = $retryable; retryMode = [string]$Step.retryMode; scheduled = $retryScheduled }) `
        -ProviderVersions ([ordered]@{ codex = Get-DuoForgeObjectValue -Object (Get-DuoForgeObjectValue -Object $providers -Name 'codex') -Name 'version'; claude = Get-DuoForgeObjectValue -Object (Get-DuoForgeObjectValue -Object $providers -Name 'claude') -Name 'version' }) -ErrorRecord $ErrorRecord
    $correlation = Get-DuoForgeDiagnosticCorrelationInternal -Diagnostic $diagnostic
    $validationFailures = if ($ErrorRecord.Exception.Data.Contains('DuoForgeValidationFailures')) {
        @($ErrorRecord.Exception.Data['DuoForgeValidationFailures'])
    }
    elseif ($formatRecovery) {
        @([ordered]@{ code = 'DF-VAL-STRUCTURE'; path = '$'; count = 1; expected = @() })
    }
    else { @() }
    $Step.lastError = [ordered]@{
        category = $failureCategory
        code = $errorCode
        exceptionType = $ErrorRecord.Exception.GetType().Name
        retryable = $retryable
        attempt = [int]$Step.attemptCount
        at = Get-DuoForgeUtcNow
        validationFailures = @($validationFailures)
        diagnosticId = $correlation.diagnosticId
        diagnosticsLocation = $correlation.diagnosticsLocation
        diagnosticsRelativePath = $correlation.diagnosticsRelativePath
        diagnosticWarningCode = $correlation.diagnosticWarningCode
    }
    Write-DuoForgeJsonAtomic -Path (Join-Path $RunDirectory 'steps.json') -Value $Graph
    $failureData = [ordered]@{
        workflowVersion = $WorkflowVersion
        stepKey = [string]$Step.stepKey
        provider = [string]$Step.provider
        stage = [string]$Step.stage
        targetDocumentId = Get-DuoForgeObjectValue -Object $Step -Name 'targetDocumentId'
        round = [int]$Step.round
        attempt = [int]$Step.attemptCount
        failedAttempt = [int]$Step.attemptCount
        code = $errorCode
        category = $failureCategory
        retryable = $retryable
        retryMode = [string]$Step.retryMode
        diagnosticId = $correlation.diagnosticId
        diagnosticsLocation = $correlation.diagnosticsLocation
        diagnosticsRelativePath = $correlation.diagnosticsRelativePath
        diagnosticWarningCode = $correlation.diagnosticWarningCode
    }
    if ($retryScheduled) {
        Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'STAGE_RETRY_SCHEDULED' -Status 'RUNNING' -Data $failureData
        Invoke-DuoForgeProgressObserverInternal -Observer $ProgressObserver -Type 'STAGE_RETRY_SCHEDULED' -RunDirectory $RunDirectory -Data $failureData
        return [ordered]@{ retryScheduled = $true; result = $null }
    }
    if ($retryExhausted) { $targetStatus = 'FAILED_STAGE' }
    $updatedState = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status $targetStatus -Round ([int]$Step.round)
    Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'STAGE_FAILED' -Status $targetStatus -Data $failureData
    Invoke-DuoForgeProgressObserverInternal -Observer $ProgressObserver -Type 'STAGE_FAILED' -RunDirectory $RunDirectory -Data $failureData
    return [ordered]@{
        retryScheduled = $false
        result = [ordered]@{ status = $updatedState.status; invoked = $Invoked; failedStep = $Step.stepKey; code = $errorCode; category = $failureCategory; retryable = $retryable; diagnosticId = $correlation.diagnosticId; diagnosticsLocation = $correlation.diagnosticsLocation; diagnosticsRelativePath = $correlation.diagnosticsRelativePath; diagnosticsPath = [string]$diagnostic.diagnosticsPath; diagnosticWarningCode = $correlation.diagnosticWarningCode }
    }
}

function Invoke-DuoForgeStageEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][scriptblock]$ProviderInvoker,
        [scriptblock]$ProgressObserver,
        [scriptblock]$FinalRenderer
    )

    return Invoke-WithDuoForgeRunLock -RunDirectory $RunDirectory -ScriptBlock {
        $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $RunDirectory
        $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
        $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
        $null = Assert-DuoForgeStagePromptPolicyInternal -Manifest $manifest
        $state = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json')
        $graph = Initialize-DuoForgeStageGraph -RunDirectory $RunDirectory
        $stepsPath = Join-Path $RunDirectory 'steps.json'
        if ([string]$state.status -eq 'QUESTION_LIMIT_REACHED') {
            $reviewProgress = Get-DuoForgeDecisionReviewProgressInternal -RunDirectory $RunDirectory -State (ConvertTo-DuoForgeHashtable -InputObject $state) -InferPendingGate
            return [ordered]@{ status = 'QUESTION_LIMIT_REACHED'; invoked = 0; decisionReviewCycle = $reviewProgress.cycle; maxDecisionReviewCycles = $reviewProgress.maximum; limitReached = $true }
        }
        $artifactRepair = Repair-DuoForgeCorruptedStageArtifactsInternal -RunDirectory $RunDirectory -Graph $graph
        $interruptedSteps = @(Repair-DuoForgeInterruptedStartedStepsInternal -Graph $graph -RunDirectory $RunDirectory -Manifest $manifest -State $state)
        if ([bool]$artifactRepair.repaired -or $interruptedSteps.Count -gt 0) { Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph }
        foreach ($recovered in $interruptedSteps) {
            $durableRecovery = ConvertTo-DuoForgeHashtable -InputObject $recovered
            $durableRecovery.Remove('diagnosticsPath')
            Add-DuoForgeProgressRunEventInternal -RunDirectory $RunDirectory -Type 'STAGE_INTERRUPTED_RECOVERED' -Status ([string]$state.status) -Data $durableRecovery
            Invoke-DuoForgeProgressObserverInternal -Observer $ProgressObserver -Type 'STAGE_INTERRUPTED_RECOVERED' -RunDirectory $RunDirectory -Data $durableRecovery
        }
        Invoke-DuoForgeProgressObserverInternal -Observer $ProgressObserver -Type 'PROGRESS_REFRESHED' -RunDirectory $RunDirectory -Data ([ordered]@{
            artifactRepair = [bool]$artifactRepair.repaired
            interruptedRecovered = $interruptedSteps.Count
        })
        $blockedFailedSteps = @($graph.steps | Where-Object { [string]$_.status -eq 'FAILED' -and [string]$_.retryMode -in @('RETRY_EXHAUSTED', 'REFERENCE_REPAIR_REQUIRED') } | Select-Object -First 1)
        if ($blockedFailedSteps.Count -gt 0) {
            $failedStep = $blockedFailedSteps[0]
            $enteredFailedState = [string]$state.status -ne 'FAILED_STAGE'
            if ($enteredFailedState) {
                $state = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status 'FAILED_STAGE' -Round ([int]$failedStep.round)
            }
            $failureData = [ordered]@{
                stepKey = [string]$failedStep.stepKey
                provider = [string]$failedStep.provider
                stage = [string]$failedStep.stage
                round = [int]$failedStep.round
                attempt = [int]$failedStep.attemptCount
                code = [string]$failedStep.lastError.code
                retryable = $false
                diagnosticId = [string]$failedStep.lastError.diagnosticId
                diagnosticsLocation = [string]$failedStep.lastError.diagnosticsLocation
                diagnosticsRelativePath = [string]$failedStep.lastError.diagnosticsRelativePath
                diagnosticWarningCode = [string]$failedStep.lastError.diagnosticWarningCode
            }
            if ($enteredFailedState) {
                Add-DuoForgeProgressRunEventInternal -RunDirectory $RunDirectory -Type 'STAGE_FAILED' -Status 'FAILED_STAGE' -Data $failureData
                Invoke-DuoForgeProgressObserverInternal -Observer $ProgressObserver -Type 'STAGE_FAILED' -RunDirectory $RunDirectory -Data $failureData
            }
            $diagnosticsPath = Resolve-DuoForgeDiagnosticsPathInternal -RunDirectory $RunDirectory -Location ([string]$failedStep.lastError.diagnosticsLocation) -RelativePath ([string]$failedStep.lastError.diagnosticsRelativePath)
            return [ordered]@{ status = $state.status; invoked = 0; failedStep = [string]$failedStep.stepKey; code = [string]$failedStep.lastError.code; retryable = $false; diagnosticId = [string]$failedStep.lastError.diagnosticId; diagnosticsLocation = [string]$failedStep.lastError.diagnosticsLocation; diagnosticsRelativePath = [string]$failedStep.lastError.diagnosticsRelativePath; diagnosticsPath = $diagnosticsPath; diagnosticWarningCode = [string]$failedStep.lastError.diagnosticWarningCode }
        }
        if ([string]$state.status -in @('COMPLETED', 'COMPLETED_PARTIAL') -and -not [bool]$artifactRepair.repaired) {
            return [ordered]@{ status = $state.status; invoked = 0; skipped = @($graph.steps | Where-Object { $_.status -eq 'COMMITTED' }).Count }
        }
        if ([string]$state.status -in @('COMPLETED', 'COMPLETED_PARTIAL') -and [bool]$artifactRepair.repaired) {
            $state = ConvertTo-DuoForgeHashtable -InputObject $state
            $state.status = 'RESUMABLE_ERROR'
            $state.updatedAt = Get-DuoForgeUtcNow
            Write-DuoForgeJsonAtomic -Path (Join-Path $RunDirectory 'state.json') -Value $state
            Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'COMPLETED_OUTPUT_CORRUPTION_DETECTED' -Status 'RESUMABLE_ERROR' -Data ([ordered]@{ invalidSteps = @($artifactRepair.invalidSteps); staleSteps = @($artifactRepair.staleSteps) })
        }
        $invoked = 0
        $pendingPause = Get-DuoForgePendingPauseRequestInternal -RunDirectory $RunDirectory
        if ($null -ne $pendingPause) {
            $state = Set-DuoForgePauseCheckpointInternal -RunDirectory $RunDirectory -Reason 'user-request' -Checkpoint ([string]$state.lastCompletedStage) -Round ([int]$state.round) -PauseRequest $pendingPause
            return [ordered]@{ status = $state.status; invoked = 0; pausedReason = 'user-request'; checkpoint = [string]$state.lastCompletedStage }
        }
        $state = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status 'RUNNING'

        while ($true) {
            $ready = @(Get-DuoForgeReadySteps -Graph $graph)
            if ($ready.Count -eq 0) { break }
            foreach ($step in $ready) {
                $runtimeBudget = Get-DuoForgeRuntimeBudgetInternal -RunDirectory $RunDirectory
                if ([bool]$runtimeBudget.exhausted) {
                    try { throw (New-DuoForgeRuntimeLimitExceptionInternal -Budget $runtimeBudget) }
                    catch {
                        $failure = Resolve-DuoForgeStageFailureInternal -RunDirectory $RunDirectory -Manifest $manifest -WorkflowVersion $workflowVersion -State $state -Graph $graph -Step $step -ErrorRecord $_ -ProgressObserver $ProgressObserver -Invoked $invoked
                    }
                    return $failure.result
                }
                try {
                    $preflightIssueTargets = if ($workflowVersion -eq 'workflow-v2') {
                        Get-DuoForgeIssueTargetMapsInternal -RunDirectory $RunDirectory -Graph $graph -ExcludeStepKey ([string]$step.stepKey)
                    }
                    else { $null }
                    $basePrompt = New-DuoForgeStagePrompt -RunDirectory $RunDirectory -Graph $graph -Step $step
                }
                catch {
                    $failure = Resolve-DuoForgeStageFailureInternal -RunDirectory $RunDirectory -Manifest $manifest -WorkflowVersion $workflowVersion -State $state -Graph $graph -Step $step -ErrorRecord $_ -ProgressObserver $ProgressObserver -Invoked $invoked
                    if ([bool]$failure.retryScheduled) { continue }
                    return $failure.result
                }
                $step.status = 'STARTED'
                $step.attemptCount = [int]$step.attemptCount + 1
                $step.totalAttemptCount = [int](Get-DuoForgeObjectValue -Object $step -Name 'totalAttemptCount' -Default 0) + 1
                if ([string](Get-DuoForgeObjectValue -Object $step -Name 'retryMode') -ne 'FORMAT_REPAIR') {
                    $step.lastError = $null
                }
                Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph
                Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'STAGE_STARTED' -Status 'RUNNING' -Data ([ordered]@{
                    workflowVersion = $workflowVersion
                    stepKey = $step.stepKey
                    provider = $step.provider
                    stage = $step.stage
                    targetDocumentId = Get-DuoForgeObjectValue -Object $step -Name 'targetDocumentId'
                    round = $step.round
                    attempt = $step.attemptCount
                })
                Invoke-DuoForgeProgressObserverInternal -Observer $ProgressObserver -Type 'STAGE_STARTED' -RunDirectory $RunDirectory -Data ([ordered]@{
                    workflowVersion = $workflowVersion
                    stepKey = [string]$step.stepKey
                    provider = [string]$step.provider
                    stage = [string]$step.stage
                    targetDocumentId = Get-DuoForgeObjectValue -Object $step -Name 'targetDocumentId'
                    round = [int]$step.round
                    attempt = [int]$step.attemptCount
                    retryMode = [string](Get-DuoForgeObjectValue -Object $step -Name 'retryMode' -Default '')
                })

                try {
                    if ([string](Get-DuoForgeObjectValue -Object $step -Name 'retryMode') -eq 'FORMAT_REPAIR') {
                        $validationFailures = if ($null -ne $step.lastError -and $null -ne (Get-DuoForgeObjectValue -Object $step.lastError -Name 'validationFailures')) {
                            @($step.lastError.validationFailures)
                        }
                        elseif ($null -ne $step.lastError -and $null -ne (Get-DuoForgeObjectValue -Object $step.lastError -Name 'validationErrors')) {
                            @([ordered]@{ code = 'DF-VAL-LEGACY'; path = '$'; count = @($step.lastError.validationErrors).Count; expected = @() })
                        }
                        else { @() }
                        $prompt = New-DuoForgeFormatRepairPrompt -OriginalPrompt $basePrompt -Step $step -ValidationFailures $validationFailures
                    }
                    else {
                        $prompt = $basePrompt
                    }
                    $step.inputHash = [string]$prompt.sha256
                    $step.lastPromptKind = [string]$prompt.kind
                    $callStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    try {
                        $result = ConvertTo-DuoForgeHashtable -InputObject (& $ProviderInvoker $step $prompt $graph)
                    }
                    finally {
                        $callStopwatch.Stop()
                        $null = Add-DuoForgeRuntimeSecondsInternal -RunDirectory $RunDirectory -Seconds $callStopwatch.Elapsed.TotalSeconds
                    }
                    Invoke-DuoForgeProgressObserverInternal -Observer $ProgressObserver -Type 'STAGE_RESULT_RECEIVED' -RunDirectory $RunDirectory -Data ([ordered]@{
                        workflowVersion = $workflowVersion
                        stepKey = [string]$step.stepKey
                        provider = [string]$step.provider
                        stage = [string]$step.stage
                        targetDocumentId = Get-DuoForgeObjectValue -Object $step -Name 'targetDocumentId'
                        round = [int]$step.round
                        attempt = [int]$step.attemptCount
                    })
                    $adoptableIssueTargets = $null
                    $adoptableIssueProviders = $null
                    if ($workflowVersion -eq 'workflow-v2' -and [string]$manifest.promptTemplateVersion -in @('duoforge-stage-v4', 'duoforge-stage-v5')) {
                        $adoptableIssueTargets = [ordered]@{}
                        $adoptableIssueProviders = [ordered]@{}
                        foreach ($catalogIssue in @($basePrompt.adoptableIssues)) {
                            $catalogKey = [string](Get-DuoForgeObjectValue -Object $catalogIssue -Name 'issueKey' -Default '')
                            if ([string]::IsNullOrWhiteSpace($catalogKey)) { continue }
                            $adoptableIssueTargets[$catalogKey] = [string](Get-DuoForgeObjectValue -Object $catalogIssue -Name 'targetDocumentId' -Default '')
                            $adoptableIssueProviders[$catalogKey] = [string](Get-DuoForgeObjectValue -Object $catalogIssue -Name 'proposedByProvider' -Default '')
                        }
                    }
                    $contextEvidenceContract = Get-DuoForgeContextEvidenceContractForStepInternal -RunDirectory $RunDirectory -Step $step
                    $null = Test-DuoForgeStageResultInternal -Result $result -ExpectedStage ([string]$step.stage) -ExpectedProvider ([string]$step.provider) -WorkflowVersion $workflowVersion -ExpectedTargetDocumentId (Get-DuoForgeObjectValue -Object $step -Name 'targetDocumentId') -ExpectedSourceDocumentIds @(Get-DuoForgeObjectValue -Object $step -Name 'sourceDocumentIds' -Default @()) -DefinitionIssueTargets $(if ($null -eq $preflightIssueTargets) { $null } else { $preflightIssueTargets.definitionTargets }) -ReferenceIssueTargets $(if ($null -eq $preflightIssueTargets) { $null } else { $preflightIssueTargets.referenceTargets }) -ReservedIssueFingerprints $(if ($null -eq $preflightIssueTargets) { $null } else { $preflightIssueTargets.reservedFingerprints }) -AdoptableIssueTargets $adoptableIssueTargets -AdoptableIssueProviders $adoptableIssueProviders -ContextEvidenceContract $contextEvidenceContract -ThrowOnError
                    $artifactDirectory = Join-Path $RunDirectory ("rounds\round-{0:D2}\raw-redacted" -f [int]$step.round)
                    [System.IO.Directory]::CreateDirectory($artifactDirectory) | Out-Null
                    $artifactPath = Join-Path $artifactDirectory ($step.stepKey + '.json')
                    $safeResult = [ordered]@{
                        schemaVersion = 1
                        stepKey = $step.stepKey
                        provider = $step.provider
                        stage = $step.stage
                        round = $step.round
                        result = $result
                    }
                    Write-DuoForgeJsonAtomic -Path $artifactPath -Value $safeResult
                    $step.status = 'COMMITTED'
                    $step.artifactPath = $artifactPath
                    $step.artifactHash = Get-DuoForgeSha256 -Path $artifactPath
                    $step.retryMode = $null
                    $step.lastError = $null
                    $invoked++
                    Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph
                    $state = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status 'RUNNING' -LastCompletedStage $step.stepKey -Round ([int]$step.round)
                    $commitData = [ordered]@{
                        workflowVersion = $workflowVersion
                        stepKey = [string]$step.stepKey
                        provider = [string]$step.provider
                        stage = [string]$step.stage
                        targetDocumentId = Get-DuoForgeObjectValue -Object $step -Name 'targetDocumentId'
                        round = [int]$step.round
                        attempt = [int]$step.attemptCount
                        artifactHash = [string]$step.artifactHash
                        issueCount = @($result.issues).Count
                        responseCount = @($result.issueResponses).Count
                        adoptionCount = @($result.adoptions).Count
                        questionCount = @($result.openQuestions).Count
                    }
                    Add-DuoForgeProgressRunEventInternal -RunDirectory $RunDirectory -Type 'STAGE_COMMITTED' -Status 'RUNNING' -Data $commitData
                    Invoke-DuoForgeProgressObserverInternal -Observer $ProgressObserver -Type 'STAGE_COMMITTED' -RunDirectory $RunDirectory -Data $commitData
                    $pendingPause = Get-DuoForgePendingPauseRequestInternal -RunDirectory $RunDirectory
                    if ($null -ne $pendingPause) {
                        $state = Set-DuoForgePauseCheckpointInternal -RunDirectory $RunDirectory -Reason 'user-request' -Checkpoint ([string]$step.stepKey) -Round ([int]$step.round) -PauseRequest $pendingPause
                        return [ordered]@{ status = $state.status; invoked = $invoked; pausedReason = 'user-request'; checkpoint = [string]$step.stepKey }
                    }
                    if (Test-DuoForgePauseAfterRoundBoundaryInternal -RunDirectory $RunDirectory -Graph $graph -Step $step) {
                        $state = Set-DuoForgePauseCheckpointInternal -RunDirectory $RunDirectory -Reason 'pause-after-round' -Checkpoint ([string]$step.stepKey) -Round ([int]$step.round)
                        return [ordered]@{ status = $state.status; invoked = $invoked; pausedReason = 'pause-after-round'; checkpoint = [string]$step.stepKey; round = [int]$step.round }
                    }
                }
                catch {
                    $failure = Resolve-DuoForgeStageFailureInternal -RunDirectory $RunDirectory -Manifest $manifest -WorkflowVersion $workflowVersion -State $state -Graph $graph -Step $step -ErrorRecord $_ -ProgressObserver $ProgressObserver -Invoked $invoked
                    if ([bool]$failure.retryScheduled) { continue }
                    return $failure.result
                }
            }
        }

        $remaining = @($graph.steps | Where-Object { $_.status -ne 'COMMITTED' })
        if ($remaining.Count -gt 0) {
            $state = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status 'RESUMABLE_ERROR'
            return [ordered]@{ status = $state.status; invoked = $invoked; remaining = $remaining.Count }
        }

        try {
            $rendered = if ($null -ne $FinalRenderer) { & $FinalRenderer $RunDirectory $graph } else { Render-DuoForgeFinalArtifacts -RunDirectory $RunDirectory -Graph $graph }
            Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'FINAL_ARTIFACTS_RENDERED' -Status 'RUNNING' -Data ([ordered]@{ files = @($rendered.files | ForEach-Object { [System.IO.Path]::GetFileName($_) }); questionCount = @((Get-DuoForgeObjectValue -Object $rendered -Name 'questions' -Default @())).Count })
        }
        catch {
            $rendererCode = if ($_.Exception.Data.Contains('DuoForgeCode')) { [string]$_.Exception.Data['DuoForgeCode'] } else { 'DF-FINAL-RENDERER' }
            $providers = Get-DuoForgeObjectValue -Object $manifest -Name 'providers' -Default ([ordered]@{})
            $diagnostic = Write-DuoForgeDiagnosticInternal -RunDirectory $RunDirectory -Code $rendererCode -Category 'renderer-error' -Phase 'renderer' -Scope 'run' `
                -Run ([ordered]@{ runId = Get-DuoForgeObjectValue -Object $manifest -Name 'runId'; workflowVersion = $workflowVersion; status = Get-DuoForgeObjectValue -Object $state -Name 'status'; lastCompletedStage = Get-DuoForgeObjectValue -Object $state -Name 'lastCompletedStage' }) `
                -Recovery ([ordered]@{ retryable = $false; retryMode = ''; scheduled = $false }) `
                -ProviderVersions ([ordered]@{ codex = Get-DuoForgeObjectValue -Object (Get-DuoForgeObjectValue -Object $providers -Name 'codex') -Name 'version'; claude = Get-DuoForgeObjectValue -Object (Get-DuoForgeObjectValue -Object $providers -Name 'claude') -Name 'version' }) -ErrorRecord $_
            $correlation = Get-DuoForgeDiagnosticCorrelationInternal -Diagnostic $diagnostic
            $state = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status 'RESUMABLE_ERROR'
            $rendererData = [ordered]@{ category = 'renderer-error'; code = $rendererCode; exceptionType = $_.Exception.GetType().Name; diagnosticId = $correlation.diagnosticId; diagnosticsLocation = $correlation.diagnosticsLocation; diagnosticsRelativePath = $correlation.diagnosticsRelativePath; diagnosticWarningCode = $correlation.diagnosticWarningCode }
            Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'FINAL_ARTIFACTS_FAILED' -Status 'RESUMABLE_ERROR' -Data $rendererData
            Invoke-DuoForgeProgressObserverInternal -Observer $ProgressObserver -Type 'FINAL_ARTIFACTS_FAILED' -RunDirectory $RunDirectory -Data $rendererData
            return [ordered]@{ status = $state.status; invoked = $invoked; failedStep = 'final-renderer'; code = $rendererCode; diagnosticId = $correlation.diagnosticId; diagnosticsLocation = $correlation.diagnosticsLocation; diagnosticsRelativePath = $correlation.diagnosticsRelativePath; diagnosticsPath = [string]$diagnostic.diagnosticsPath; diagnosticWarningCode = $correlation.diagnosticWarningCode }
        }

        $ledger = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'issues.json')
        $completion = Test-DuoForgeCompletionAllowedInternal -Issues @($ledger.issues)
        if (-not $completion.allowed) {
            $awaitingEvidence = @($ledger.issues | Where-Object {
                [bool]$_.blocking -and [string]$_.resolutionStatus -eq 'AWAITING_EVIDENCE'
            }).Count -gt 0
            $renderedQuestions = @((Get-DuoForgeObjectValue -Object $rendered -Name 'questions' -Default @()))
            if (-not $awaitingEvidence -and $renderedQuestions.Count -gt 0) {
                $reviewGate = Register-DuoForgeDecisionReviewGateInternal -RunDirectory $RunDirectory -QuestionCount $renderedQuestions.Count
                if (-not [bool]$reviewGate.allowed) {
                    $state = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status 'QUESTION_LIMIT_REACHED' -LastCompletedStage $state.lastCompletedStage
                    Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'DECISION_REVIEW_LIMIT_REACHED' -Status 'QUESTION_LIMIT_REACHED' -Data ([ordered]@{ cycle = [int]$reviewGate.cycle; maximum = [int]$reviewGate.maximum; questionCount = [int]$reviewGate.questionCount })
                    $finalResult = [ordered]@{ status = 'QUESTION_LIMIT_REACHED'; invoked = $invoked; totalSteps = @($graph.steps).Count; decisionReviewCycle = [int]$reviewGate.cycle; maxDecisionReviewCycles = [int]$reviewGate.maximum; limitReached = $true }
                    Invoke-DuoForgeProgressObserverInternal -Observer $ProgressObserver -Type 'RUN_FINISHED' -RunDirectory $RunDirectory -Data $finalResult
                    return $finalResult
                }
                Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'DECISION_REVIEW_CYCLE_OPENED' -Status 'RUNNING' -Data ([ordered]@{ cycle = [int]$reviewGate.cycle; maximum = [int]$reviewGate.maximum; questionCount = [int]$reviewGate.questionCount })
            }
            $waitingStatus = if ($awaitingEvidence) { 'AWAITING_EVIDENCE' } else { 'AWAITING_USER' }
            $state = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status $waitingStatus -LastCompletedStage $state.lastCompletedStage
        }
        else {
            $contextPlanPath = Join-Path $RunDirectory 'inputs\context-plan.json'
            $contextStatus = if (Test-Path -LiteralPath $contextPlanPath -PathType Leaf) { [string](Read-DuoForgeJson -Path $contextPlanPath).completionStatus } else { 'COMPLETED' }
            $finalStatus = if ($contextStatus -eq 'COMPLETED_PARTIAL') { 'COMPLETED_PARTIAL' } else { [string]$completion.status }
            $state = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status $finalStatus -LastCompletedStage $state.lastCompletedStage
        }
        $reviewProgress = Get-DuoForgeDecisionReviewProgressInternal -RunDirectory $RunDirectory -State (ConvertTo-DuoForgeHashtable -InputObject $state)
        $finalResult = [ordered]@{ status = $state.status; invoked = $invoked; totalSteps = @($graph.steps).Count; decisionReviewCycle = $reviewProgress.cycle; maxDecisionReviewCycles = $reviewProgress.maximum; limitReached = [bool]$reviewProgress.limitReached }
        Invoke-DuoForgeProgressObserverInternal -Observer $ProgressObserver -Type 'RUN_FINISHED' -RunDirectory $RunDirectory -Data $finalResult
        return $finalResult
    }
}
