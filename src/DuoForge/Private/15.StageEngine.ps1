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
    }
}

function New-DuoForgeStageGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('shared-document', 'dual-document')][string]$Mode,
        [ValidateRange(2, 3)][int]$MaxRounds = 2,
        [ValidateSet('alternate', 'codex', 'claude')][string]$FirstSynthesizer = 'alternate'
    )

    $steps = [System.Collections.Generic.List[object]]::new()
    $previousBarrier = @()
    if ($Mode -eq 'shared-document') {
        $first = if ($FirstSynthesizer -eq 'claude') { 'claude' } else { 'codex' }
        for ($round = 1; $round -le $MaxRounds; $round++) {
            if ($round -eq 1) {
                $drafts = @('codex', 'claude') | ForEach-Object { "r$('{0:D2}' -f $round)-$_-independent-draft" }
                foreach ($provider in @('codex', 'claude')) {
                    $steps.Add((New-DuoForgeStageRecord -StepKey "r$('{0:D2}' -f $round)-$provider-independent-draft" -Provider $provider -Round $round -Stage 'independent-draft'))
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
    $graph = New-DuoForgeStageGraph -Mode ([string]$manifest.mode) -MaxRounds ([int]$manifest.maxRounds) -FirstSynthesizer $firstSynthesizer
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
        $isReady = [string]$_.status -in @('PENDING', 'FAILED')
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

function Invoke-DuoForgeStageEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][scriptblock]$ProviderInvoker
    )

    return Invoke-WithDuoForgeRunLock -RunDirectory $RunDirectory -ScriptBlock {
        $state = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json')
        if ([string]$state.status -in @('COMPLETED', 'COMPLETED_PARTIAL')) {
            $existing = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'steps.json')
            return [ordered]@{ status = $state.status; invoked = 0; skipped = @($existing.steps | Where-Object { $_.status -eq 'COMMITTED' }).Count }
        }

        $graph = Initialize-DuoForgeStageGraph -RunDirectory $RunDirectory
        $stepsPath = Join-Path $RunDirectory 'steps.json'
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
                $step.lastError = $null
                Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph
                Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'STAGE_STARTED' -Status 'RUNNING' -Data ([ordered]@{ stepKey = $step.stepKey; provider = $step.provider; attempt = $step.attemptCount })

                try {
                    $prompt = New-DuoForgeStagePrompt -RunDirectory $RunDirectory -Graph $graph -Step $step
                    $step.inputHash = [string]$prompt.sha256
                    $result = ConvertTo-DuoForgeHashtable -InputObject (& $ProviderInvoker $step $prompt $graph)
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
                        Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'STAGE_RETRY_SCHEDULED' -Status 'RUNNING' -Data ([ordered]@{ stepKey = $step.stepKey; provider = $step.provider; failedAttempt = $step.attemptCount; code = $errorCode; category = $failureCategory })
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
            $state = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status $completion.status -LastCompletedStage $state.lastCompletedStage
        }
        return [ordered]@{ status = $state.status; invoked = $invoked; totalSteps = @($graph.steps).Count }
    }
}
