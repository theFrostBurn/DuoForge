function Get-DuoForgePauseRequestPathInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    return Join-Path $RunDirectory 'control\pause-request.json'
}

function Get-DuoForgePauseRoundStatePathInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    return Join-Path $RunDirectory 'control\pause-rounds.json'
}

function Get-DuoForgePendingPauseRequestInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $path = Get-DuoForgePauseRequestPathInternal -RunDirectory $RunDirectory
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $request = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $path)
    if ([string]$request.status -cne 'REQUESTED') { return $null }
    return $request
}

function Request-DuoForgePauseInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $terminal = @('COMPLETED', 'COMPLETED_PARTIAL', 'QUESTION_LIMIT_REACHED', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')
    if ([string]$run.state.status -in $terminal) {
        throw (New-DuoForgeException -Code 'DF-PAUSE-TERMINAL' -Message '종료된 실행에는 일시정지를 요청할 수 없습니다.')
    }
    if ([string]$run.state.status -eq 'PAUSED_USER') {
        return [ordered]@{ runId = $RunId; status = 'PAUSED_USER'; requested = $false; alreadyPaused = $true }
    }
    $existing = Get-DuoForgePendingPauseRequestInternal -RunDirectory ([string]$run.runDirectory)
    if ($null -ne $existing) {
        return [ordered]@{ runId = $RunId; status = [string]$run.state.status; requested = $true; requestId = [string]$existing.requestId; alreadyRequested = $true }
    }

    $request = [ordered]@{
        schemaVersion = 1
        requestId = 'pause-' + [Guid]::NewGuid().ToString('N')
        runId = $RunId
        status = 'REQUESTED'
        requestedAt = Get-DuoForgeUtcNow
        requestedState = [string]$run.state.status
        acknowledgedAt = $null
        checkpoint = $null
    }
    Write-DuoForgeJsonAtomic -Path (Get-DuoForgePauseRequestPathInternal -RunDirectory ([string]$run.runDirectory)) -Value $request
    return [ordered]@{ runId = $RunId; status = [string]$run.state.status; requested = $true; requestId = [string]$request.requestId; alreadyRequested = $false }
}

function Get-DuoForgeAcknowledgedPauseRoundsInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $path = Get-DuoForgePauseRoundStatePathInternal -RunDirectory $RunDirectory
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $state = Read-DuoForgeJson -Path $path
    return @($state.acknowledgedRounds | ForEach-Object { [int]$_ })
}

function Test-DuoForgePauseAfterRoundBoundaryInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Graph,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Step
    )

    $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
    if (-not [bool](Get-DuoForgeObjectValue -Object $manifest -Name 'pauseAfterRound' -Default $false)) { return $false }
    $round = [int]$Step.round
    if ($round -in @(Get-DuoForgeAcknowledgedPauseRoundsInternal -RunDirectory $RunDirectory)) { return $false }
    if ([string]$Graph.mode -in @('shared-document', 'document-merge')) {
        return [string]$Step.stage -eq 'synthesis'
    }
    $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
    $revisionStage = if ($workflowVersion -eq 'workflow-v2') { 'document-revision' } else { 'owned-document-revision' }
    if ([string]$Step.stage -ne $revisionStage) { return $false }
    $roundRevisions = @($Graph.steps | Where-Object { [int]$_.round -eq $round -and [string]$_.stage -eq $revisionStage })
    return $roundRevisions.Count -gt 0 -and @($roundRevisions | Where-Object { [string]$_.status -ne 'COMMITTED' }).Count -eq 0
}

function Set-DuoForgePauseCheckpointInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][ValidateSet('user-request', 'pause-after-round')][string]$Reason,
        [string]$Checkpoint,
        [int]$Round = 0,
        $PauseRequest
    )

    if ($Reason -eq 'user-request' -and $null -ne $PauseRequest) {
        $PauseRequest.status = 'ACKNOWLEDGED'
        $PauseRequest.acknowledgedAt = Get-DuoForgeUtcNow
        $PauseRequest.checkpoint = $Checkpoint
        Write-DuoForgeJsonAtomic -Path (Get-DuoForgePauseRequestPathInternal -RunDirectory $RunDirectory) -Value $PauseRequest
    }
    if ($Reason -eq 'pause-after-round') {
        $roundStatePath = Get-DuoForgePauseRoundStatePathInternal -RunDirectory $RunDirectory
        $acknowledged = @(Get-DuoForgeAcknowledgedPauseRoundsInternal -RunDirectory $RunDirectory)
        if ($Round -notin $acknowledged) { $acknowledged += $Round }
        Write-DuoForgeJsonAtomic -Path $roundStatePath -Value ([ordered]@{ schemaVersion = 1; acknowledgedRounds = @($acknowledged | Sort-Object -Unique); updatedAt = Get-DuoForgeUtcNow })
    }
    Add-DuoForgeJsonLine -Path (Join-Path $RunDirectory 'control\pause-history.jsonl') -Value ([ordered]@{
        schemaVersion = 1
        reason = $Reason
        requestId = if ($null -eq $PauseRequest) { $null } else { [string]$PauseRequest.requestId }
        checkpoint = $Checkpoint
        round = $Round
        pausedAt = Get-DuoForgeUtcNow
    })
    $state = Set-DuoForgeRunStateInternal -RunDirectory $RunDirectory -Status 'PAUSED_USER' -LastCompletedStage $Checkpoint -Round $Round
    Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'RUN_PAUSED' -Status 'PAUSED_USER' -Data ([ordered]@{ reason = $Reason; checkpoint = $Checkpoint; round = $Round; requestId = if ($null -eq $PauseRequest) { $null } else { [string]$PauseRequest.requestId } })
    return $state
}
