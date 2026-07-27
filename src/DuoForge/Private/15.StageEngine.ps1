function New-DuoForgeStageRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StepKey,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][int]$Round,
        [Parameter(Mandatory)][string]$Stage,
        [string[]]$DependsOn = @()
    )

    return [ordered]@{
        stepKey = $StepKey
        provider = $Provider
        round = $Round
        stage = $Stage
        dependsOn = @($DependsOn)
        status = 'PENDING'
        attemptCount = 0
        inputHash = $null
        artifactPath = $null
        artifactHash = $null
        lastError = $null
        retryMode = $null
        lastPromptKind = $null
        history = @()
    }
}

function New-DuoForgeStageGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('shared-document', 'dual-document')][string]$Mode,
        [ValidateRange(2, 3)][int]$MaxRounds = 2,
        [ValidateSet('alternate', 'codex', 'claude')][string]$FirstSynthesizer = 'alternate',
        [ValidateRange(0, 100)][int]$ContextBatchCount = 0
    )

    $steps = [System.Collections.Generic.List[object]]::new()
    $contextBarrier = [System.Collections.Generic.List[string]]::new()
    if ($ContextBatchCount -gt 0) {
        for ($batch = 1; $batch -le $ContextBatchCount; $batch++) {
            $batchId = 'batch-{0:D3}' -f $batch
            foreach ($provider in @('codex', 'claude')) {
                $key = "context-$batchId-$provider-analysis"
                $record = New-DuoForgeStageRecord -StepKey $key -Provider $provider -Round 0 -Stage 'context-batch-analysis'
                $record.contextBatchId = $batchId
                $steps.Add($record)
                $contextBarrier.Add($key)
            }
        }
    }
    $previousBarrier = @($contextBarrier)
    if ($Mode -eq 'shared-document') {
        $first = if ($FirstSynthesizer -eq 'claude') { 'claude' } else { 'codex' }
        for ($round = 1; $round -le $MaxRounds; $round++) {
            if ($round -eq 1) {
                $drafts = @('codex', 'claude') | ForEach-Object { "r$('{0:D2}' -f $round)-$_-independent-draft" }
                foreach ($provider in @('codex', 'claude')) {
                    $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $round)-$provider-independent-draft" -Provider $provider -Round $round -Stage 'independent-draft' -DependsOn $previousBarrier))
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
                $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $round)-$provider-$reviewStage" -Provider $provider -Round $round -Stage $reviewStage -DependsOn $reviewDependencies))
            }

            $responseStage = if ($round -eq 1) { 'author-response' } else { 'review-response' }
            $responses = @('codex', 'claude') | ForEach-Object { "r$('{0:D2}' -f $round)-$_-$responseStage" }
            foreach ($provider in @('codex', 'claude')) {
                $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $round)-$provider-$responseStage" -Provider $provider -Round $round -Stage $responseStage -DependsOn $reviews))
            }

            $synthesizer = if (($round % 2) -eq 1) { $first } elseif ($first -eq 'codex') { 'claude' } else { 'codex' }
            $synthesisKey = "r$('{0:D2}' -f $round)-$synthesizer-synthesis"
            $steps.Add((New-DuoForgeStageRecord -StepKey $synthesisKey -Provider $synthesizer -Round $round -Stage 'synthesis' -DependsOn $responses))
            $previousBarrier = @($synthesisKey)
        }

        $lastSynthesizer = $steps[$steps.Count - 1].provider
        $validator = if ($lastSynthesizer -eq 'codex') { 'claude' } else { 'codex' }
        $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $MaxRounds)-$validator-final-validation" -Provider $validator -Round $MaxRounds -Stage 'final-validation' -DependsOn $previousBarrier))
    }
    else {
        for ($round = 1; $round -le $MaxRounds; $round++) {
            $reviews = @('codex', 'claude') | ForEach-Object { "r$('{0:D2}' -f $round)-$_-cross-review" }
            foreach ($provider in @('codex', 'claude')) {
                $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $round)-$provider-cross-review" -Provider $provider -Round $round -Stage 'cross-review' -DependsOn $previousBarrier))
            }
            $responses = @('codex', 'claude') | ForEach-Object { "r$('{0:D2}' -f $round)-$_-owner-response" }
            foreach ($provider in @('codex', 'claude')) {
                $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $round)-$provider-owner-response" -Provider $provider -Round $round -Stage 'owner-response' -DependsOn $reviews))
            }
            $revisions = @('codex', 'claude') | ForEach-Object { "r$('{0:D2}' -f $round)-$_-owned-document-revision" }
            foreach ($provider in @('codex', 'claude')) {
                $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $round)-$provider-owned-document-revision" -Provider $provider -Round $round -Stage 'owned-document-revision' -DependsOn $responses))
            }
            $previousBarrier = $revisions
        }
    }

    return [ordered]@{
        schemaVersion = 1
        mode = $Mode
        maxRounds = $MaxRounds
        steps = @($steps)
    }
}

function Initialize-DuoForgeStageGraph {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $path = Join-Path $RunDirectory 'steps.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $path)
    }
    $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
    $firstSynthesizer = if ([string]::IsNullOrWhiteSpace([string]$manifest.firstSynthesizer)) { 'alternate' } else { [string]$manifest.firstSynthesizer }
    $contextPlanPath = Join-Path $RunDirectory 'inputs\context-plan.json'
    $contextBatchCount = if (Test-Path -LiteralPath $contextPlanPath -PathType Leaf) { @((Read-DuoForgeJson -Path $contextPlanPath).batches).Count } else { 0 }
    $graph = New-DuoForgeStageGraph -Mode ([string]$manifest.mode) -MaxRounds ([int]$manifest.maxRounds) -FirstSynthesizer $firstSynthesizer -ContextBatchCount $contextBatchCount
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
    foreach ($step in @($Graph.steps | Where-Object { [string]$_.status -eq 'COMMITTED' })) {
        $valid = $true
        $path = [string]$step.artifactPath
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $valid = $false
        }
        elseif ((Get-DuoForgeSha256 -Path $path) -ne [string]$step.artifactHash) {
            $valid = $false
        }
        else {
            try {
                $wrapper = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $path)
                $null = Test-DuoForgeStageResultInternal -Result $wrapper.result -ExpectedStage ([string]$step.stage) -ExpectedProvider ([string]$step.provider) -ThrowOnError
            }
            catch { $valid = $false }
        }
        if (-not $valid) { $invalidKeys.Add([string]$step.stepKey) }
    }
    if ($invalidKeys.Count -eq 0) { return [ordered]@{ repaired = $false; invalidSteps = @(); staleSteps = @() } }

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
            reason = if ([string]$step.stepKey -in @($invalidKeys)) { 'CORRUPTED_OR_MISSING' } else { 'DEPENDS_ON_INVALID_ARTIFACT' }
            preservedPath = $null
        }
        if (-not [string]::IsNullOrWhiteSpace($oldPath) -and (Test-Path -LiteralPath $oldPath -PathType Leaf)) {
            $suffix = if ([string]::IsNullOrWhiteSpace([string]$step.artifactHash)) { [Guid]::NewGuid().ToString('N').Substring(0, 12) } else { ([string]$step.artifactHash).Substring(0, [Math]::Min(12, ([string]$step.artifactHash).Length)) }
            $preservedPath = Join-Path $historyDirectory ("{0}-{1}.json" -f [string]$step.stepKey, $suffix)
            [System.IO.File]::Copy($oldPath, $preservedPath, $true)
            $historyRecord.preservedPath = $preservedPath
        }
        $existingHistory = [System.Collections.Generic.List[object]]::new()
        if ($step.Contains('history')) { foreach ($entry in @($step.history)) { $existingHistory.Add($entry) } }
        $existingHistory.Add($historyRecord)
        $step.history = @($existingHistory)
        $step.status = 'STALE'
        $step.inputHash = $null
        $step.artifactPath = $null
        $step.artifactHash = $null
        $step.lastError = $null
        $step.retryMode = $null
        $step.lastPromptKind = $null
    }
    Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'STAGE_ARTIFACTS_INVALIDATED' -Status 'RESUMABLE_ERROR' -Data ([ordered]@{ invalidSteps = @($invalidKeys); staleSteps = @($staleKeys.Keys) })
    return [ordered]@{ repaired = $true; invalidSteps = @($invalidKeys); staleSteps = @($staleKeys.Keys) }
}

function Invoke-DuoForgeStageEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][scriptblock]$ProviderInvoker
    )

    return Invoke-WithDuoForgeRunLock -RunDirectory $RunDirectory -ScriptBlock {
        $state = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json')
        $graph = Initialize-DuoForgeStageGraph -RunDirectory $RunDirectory
        $stepsPath = Join-Path $RunDirectory 'steps.json'
        $artifactRepair = Repair-DuoForgeCorruptedStageArtifactsInternal -RunDirectory $RunDirectory -Graph $graph
        if ([bool]$artifactRepair.repaired) { Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph }
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
                $step.status = 'STARTED'
                $step.attemptCount = [int]$step.attemptCount + 1
                if ([string](Get-DuoForgeObjectValue -Object $step -Name 'retryMode') -ne 'FORMAT_REPAIR') {
                    $step.lastError = $null
                }
                Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph
                Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'STAGE_STARTED' -Status 'RUNNING' -Data ([ordered]@{ stepKey = $step.stepKey; provider = $step.provider; attempt = $step.attemptCount })

                try {
                    $basePrompt = New-DuoForgeStagePrompt -RunDirectory $RunDirectory -Graph $graph -Step $step
                    if ([string](Get-DuoForgeObjectValue -Object $step -Name 'retryMode') -eq 'FORMAT_REPAIR') {
                        $validationErrors = if ($null -ne $step.lastError) { @($step.lastError.validationErrors) } else { @() }
                        $prompt = New-DuoForgeFormatRepairPrompt -OriginalPrompt $basePrompt -Step $step -ValidationErrors $validationErrors
                    }
                    else {
                        $prompt = $basePrompt
                    }
                    $step.inputHash = [string]$prompt.sha256
                    $step.lastPromptKind = [string]$prompt.kind
                    $runtimeBudget = Get-DuoForgeRuntimeBudgetInternal -RunDirectory $RunDirectory
                    if ([bool]$runtimeBudget.exhausted) { throw (New-DuoForgeRuntimeLimitExceptionInternal -Budget $runtimeBudget) }
                    $callStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    try {
                        $result = ConvertTo-DuoForgeHashtable -InputObject (& $ProviderInvoker $step $prompt $graph)
                    }
                    finally {
                        $callStopwatch.Stop()
                        $null = Add-DuoForgeRuntimeSecondsInternal -RunDirectory $RunDirectory -Seconds $callStopwatch.Elapsed.TotalSeconds
                    }
                    $null = Test-DuoForgeStageResultInternal -Result $result -ExpectedStage ([string]$step.stage) -ExpectedProvider ([string]$step.provider) -ThrowOnError
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
                    $step.status = 'FAILED'
                    $errorCode = if ($_.Exception.Data.Contains('DuoForgeCode')) { [string]$_.Exception.Data['DuoForgeCode'] } else { 'DF-STAGE-UNEXPECTED' }
                    $failureCategory = if ($_.Exception.Data.Contains('DuoForgeFailureCategory')) { [string]$_.Exception.Data['DuoForgeFailureCategory'] } else { 'provider-error' }
                    $targetStatus = if ($_.Exception.Data.Contains('DuoForgeFailureStatus')) { [string]$_.Exception.Data['DuoForgeFailureStatus'] } else { 'RESUMABLE_ERROR' }
                    $retryable = if ($_.Exception.Data.Contains('DuoForgeRetryable')) {
                        [bool]$_.Exception.Data['DuoForgeRetryable']
                    }
                    else {
                        $errorCode -in @('DF-STAGE-SCHEMA', 'DF-PROVIDER-JSON', 'DF-CLAUDE-ENVELOPE', 'DF-CLAUDE-RESULT', 'DF-CLAUDE-STRUCTURED-OUTPUT', 'DF-CODEX-LAST-MESSAGE')
                    }
                    $formatRecovery = Test-DuoForgeFormatRecoveryErrorInternal -Code $errorCode
                    $step.lastError = [ordered]@{
                        category = $failureCategory
                        code = $errorCode
                        exceptionType = $_.Exception.GetType().Name
                        commandName = [string]$_.CategoryInfo.TargetName
                        retryable = $retryable
                        attempt = [int]$step.attemptCount
                        at = Get-DuoForgeUtcNow
                        validationErrors = if ($_.Exception.Data.Contains('DuoForgeValidationErrors')) { @($_.Exception.Data['DuoForgeValidationErrors']) } else { @() }
                    }
                    Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph
                    if ($retryable -and [int]$step.attemptCount -lt 2) {
                        $step.retryMode = if ($formatRecovery) { 'FORMAT_REPAIR' } else { 'STANDARD_RETRY' }
                        Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph
                        Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'STAGE_RETRY_SCHEDULED' -Status 'RUNNING' -Data ([ordered]@{ stepKey = $step.stepKey; provider = $step.provider; failedAttempt = $step.attemptCount; code = $errorCode; category = $failureCategory; retryMode = $step.retryMode })
                        continue
                    }
                    $state = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status $targetStatus -Round ([int]$step.round)
                    Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'STAGE_FAILED' -Status $targetStatus -Data ([ordered]@{ stepKey = $step.stepKey; provider = $step.provider; attempt = $step.attemptCount; code = $errorCode; category = $failureCategory; retryable = $retryable })
                    return [ordered]@{ status = $state.status; invoked = $invoked; failedStep = $step.stepKey; code = $errorCode; category = $failureCategory; retryable = $retryable }
                }
            }
        }

        $remaining = @($graph.steps | Where-Object { $_.status -ne 'COMMITTED' })
        if ($remaining.Count -gt 0) {
            $state = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status 'RESUMABLE_ERROR'
            return [ordered]@{ status = $state.status; invoked = $invoked; remaining = $remaining.Count }
        }

        try {
            $rendered = Render-DuoForgeFinalArtifacts -RunDirectory $RunDirectory -Graph $graph
            Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'FINAL_ARTIFACTS_RENDERED' -Status 'RUNNING' -Data ([ordered]@{ files = @($rendered.files | ForEach-Object { [System.IO.Path]::GetFileName($_) }) })
        }
        catch {
            $rendererCode = if ($_.Exception.Data.Contains('DuoForgeCode')) { [string]$_.Exception.Data['DuoForgeCode'] } else { 'DF-FINAL-RENDERER' }
            $state = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status 'RESUMABLE_ERROR'
            Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'FINAL_ARTIFACTS_FAILED' -Status 'RESUMABLE_ERROR' -Data ([ordered]@{ category = 'renderer-error'; code = $rendererCode; exceptionType = $_.Exception.GetType().Name })
            return [ordered]@{ status = $state.status; invoked = $invoked; failedStep = 'final-renderer'; code = $rendererCode }
        }

        $ledger = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'issues.json')
        $completion = Test-DuoForgeCompletionAllowedInternal -Issues @($ledger.issues)
        if (-not $completion.allowed) {
            $awaitingEvidence = @($ledger.issues | Where-Object {
                [bool]$_.blocking -and [string]$_.resolutionStatus -eq 'AWAITING_EVIDENCE'
            }).Count -gt 0
            $waitingStatus = if ($awaitingEvidence) { 'AWAITING_EVIDENCE' } else { 'AWAITING_USER' }
            $state = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status $waitingStatus -LastCompletedStage $state.lastCompletedStage
        }
        else {
            $contextPlanPath = Join-Path $RunDirectory 'inputs\context-plan.json'
            $contextStatus = if (Test-Path -LiteralPath $contextPlanPath -PathType Leaf) { [string](Read-DuoForgeJson -Path $contextPlanPath).completionStatus } else { 'COMPLETED' }
            $finalStatus = if ($contextStatus -eq 'COMPLETED_PARTIAL') { 'COMPLETED_PARTIAL' } else { [string]$completion.status }
            $state = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status $finalStatus -LastCompletedStage $state.lastCompletedStage
        }
        return [ordered]@{ status = $state.status; invoked = $invoked; totalSteps = @($graph.steps).Count }
    }
}
