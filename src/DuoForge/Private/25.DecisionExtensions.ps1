function Get-DuoForgeEffectiveUserDecisionsInternal {
    [CmdletBinding()]
    param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Records)

    $effective = [System.Collections.Generic.List[object]]::new()
    $latestAnswers = [ordered]@{}
    foreach ($record in @($Records | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'action' -Default '') -eq 'ANSWER' })) {
        $issueId = [string](Get-DuoForgeObjectValue -Object $record -Name 'issueId' -Default '')
        if ([string]::IsNullOrWhiteSpace($issueId)) { continue }
        $revision = [int](Get-DuoForgeObjectValue -Object $record -Name 'revision' -Default 1)
        if (-not $latestAnswers.Contains($issueId)) {
            $latestAnswers[$issueId] = $record
            continue
        }
        $currentRevision = [int](Get-DuoForgeObjectValue -Object $latestAnswers[$issueId] -Name 'revision' -Default 1)
        if ($revision -ge $currentRevision) { $latestAnswers[$issueId] = $record }
    }
    foreach ($record in @($latestAnswers.Values)) { $effective.Add($record) }
    foreach ($constraint in @($Records | Where-Object { [string]$_.action -eq 'CONSTRAINT' })) { $effective.Add($constraint) }
    return @($effective | Sort-Object @{ Expression = { [string](Get-DuoForgeObjectValue -Object $_ -Name 'recordedAt' -Default '') } })
}

function New-DuoForgeDecisionConstraintPreviewInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$IssueId,
        [Parameter(Mandatory)][string]$Text,
        [string]$ResultsRoot
    )

    $normalized = ($Text -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) { throw (New-DuoForgeException -Code 'DF-CONSTRAINT-EMPTY' -Message '자유 입력 제약 조건이 비어 있습니다.') }
    if ($normalized.Length -gt 2000) { throw (New-DuoForgeException -Code 'DF-CONSTRAINT-LENGTH' -Message '자유 입력 제약 조건은 2,000자 이하여야 합니다.') }
    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $issue = @($run.issues.issues | Where-Object { [string]$_.issueId -eq $IssueId } | Select-Object -First 1)
    if ($issue.Count -ne 1) { throw (New-DuoForgeException -Code 'DF-ISSUE-NOT-FOUND' -Message "쟁점을 찾을 수 없습니다: $IssueId") }
    return [ordered]@{
        schemaVersion = 1
        runId = $RunId
        issueId = $IssueId
        originalText = $Text
        normalizedConstraint = $normalized
        affectedTarget = Get-DuoForgeIssueTargetInternal -Issue $issue[0]
        appliesToProviders = @('codex', 'claude')
        application = '구속력 있는 공통 제약으로 마지막 문서 생성과 검증 단계에 주입'
        requiresConfirmation = $true
    }
}

function Set-DuoForgeUserConstraintInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$IssueId,
        [Parameter(Mandatory)][string]$Text,
        [string]$ResultsRoot,
        [Parameter(Mandatory)][switch]$Confirm
    )

    $preview = New-DuoForgeDecisionConstraintPreviewInternal -RunId $RunId -IssueId $IssueId -Text $Text -ResultsRoot $ResultsRoot
    if (-not $Confirm) { return $preview }
    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $null = Assert-DuoForgeStagePromptPolicyInternal -Manifest $run.manifest
    return Invoke-WithDuoForgeRunLock -RunDirectory ([string]$run.runDirectory) -ScriptBlock {
        $directory = [string]$run.runDirectory
        $record = [ordered]@{
            schemaVersion = 1
            decisionId = 'constraint-' + [Guid]::NewGuid().ToString('N')
            runId = $RunId
            issueId = $IssueId
            action = 'CONSTRAINT'
            rawText = $Text
            normalizedConstraint = [string]$preview.normalizedConstraint
            affectedTarget = [string]$preview.affectedTarget
            appliesToProviders = @('codex', 'claude')
            recordedAt = Get-DuoForgeUtcNow
        }
        Add-DuoForgeJsonLine -Path (Join-Path $directory 'decisions\user-answers.jsonl') -Value $record
        $reset = Reset-DuoForgeDecisionAffectedSteps -RunDirectory $directory -Mode ([string]$run.state.mode)
        $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $directory 'state.json'))
        $state.status = 'PAUSED_USER'
        $state.lastCompletedStage = [string]$reset.lastCommittedStep
        $state.updatedAt = Get-DuoForgeUtcNow
        Write-DuoForgeJsonAtomic -Path (Join-Path $directory 'state.json') -Value $state
        Add-DuoForgeRunEvent -RunDirectory $directory -Type 'USER_CONSTRAINT_RECORDED' -Status 'PAUSED_USER' -Data ([ordered]@{ issueId = $IssueId; decisionId = $record.decisionId; resetSteps = $reset.resetSteps })
        return [ordered]@{ status = 'PAUSED_USER'; decisionId = $record.decisionId; preview = $preview; resetSteps = $reset.resetSteps }
    }
}

function Add-DuoForgeRoundInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $null = Assert-DuoForgeStagePromptPolicyInternal -Manifest $run.manifest
    return Invoke-WithDuoForgeRunLock -RunDirectory ([string]$run.runDirectory) -ScriptBlock {
        $directory = [string]$run.runDirectory
        $manifest = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $directory 'manifest.json'))
        if ([int]$manifest.maxRounds -ge 3) { throw (New-DuoForgeException -Code 'DF-ROUND-MAX' -Message '이미 최대 3라운드로 설정되어 있습니다.') }
        if ([string]$manifest.mode -notin @('shared-document', 'document-merge', 'dual-document')) { throw (New-DuoForgeException -Code 'DF-ROUND-MODE' -Message '이 모드에서는 추가 라운드를 지원하지 않습니다.') }

        $contextBatchCount = @((Read-DuoForgeJson -Path (Join-Path $directory 'inputs\context-plan.json')).batches).Count
        $config = Get-DuoForgeConfig
        $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
        $nextPlan = Get-DuoForgeExecutionPlanInternal -Mode ([string]$manifest.mode) -MaxRounds 3 -FirstSynthesizer ([string]$manifest.firstSynthesizer) -MaxCallsPerProvider ([int]$config.limits.maxCallsPerProviderPerRun) -ContextBatchCount $contextBatchCount -WorkflowVersion $workflowVersion
        if (-not [bool]$nextPlan.withinLimits) { throw (New-DuoForgeException -Code 'DF-PLAN-CALL-LIMIT' -Message '추가 라운드의 최악 호출 계획이 강제 상한을 초과합니다. 입력 범위를 줄인 새 실행이 필요합니다.') }

        $oldGraph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $directory 'steps.json'))
        $historyDirectory = Join-Path $directory 'history\graphs'
        [System.IO.Directory]::CreateDirectory($historyDirectory) | Out-Null
        Write-DuoForgeJsonAtomic -Path (Join-Path $historyDirectory ("steps-before-round-3-{0}.json" -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))) -Value $oldGraph

        $newGraph = New-DuoForgeStageGraph -Mode ([string]$manifest.mode) -MaxRounds 3 -FirstSynthesizer ([string]$manifest.firstSynthesizer) -ContextBatchCount $contextBatchCount -WorkflowVersion $workflowVersion
        $oldByKey = @{}
        foreach ($step in @($oldGraph.steps)) { $oldByKey[[string]$step.stepKey] = $step }
        for ($index = 0; $index -lt @($newGraph.steps).Count; $index++) {
            $key = [string]$newGraph.steps[$index].stepKey
            if ($oldByKey.ContainsKey($key)) { $newGraph.steps[$index] = $oldByKey[$key] }
        }
        Write-DuoForgeJsonAtomic -Path (Join-Path $directory 'steps.json') -Value $newGraph

        $manifest.maxRounds = 3
        $manifest.updatedAt = Get-DuoForgeUtcNow
        $manifest.executionPlan = $nextPlan
        Write-DuoForgeJsonAtomic -Path (Join-Path $directory 'manifest.json') -Value $manifest

        $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $directory 'state.json'))
        $state.maxRounds = 3
        $state.status = 'PAUSED_USER'
        $state.updatedAt = Get-DuoForgeUtcNow
        Write-DuoForgeJsonAtomic -Path (Join-Path $directory 'state.json') -Value $state
        Write-DuoForgeJsonAtomic -Path (Join-Path $directory 'decisions\pending.json') -Value ([ordered]@{ schemaVersion = 1; questions = @() })
        Add-DuoForgeRunEvent -RunDirectory $directory -Type 'ROUND_ADDED' -Status 'PAUSED_USER' -Data ([ordered]@{ previousMaxRounds = 2; maxRounds = 3 })
        return [ordered]@{ status = 'PAUSED_USER'; previousMaxRounds = 2; maxRounds = 3; addedSteps = @($newGraph.steps | Where-Object { [int]$_.round -eq 3 }).Count }
    }
}
