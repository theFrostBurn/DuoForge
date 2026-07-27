function Get-DuoForgeCommittedStageResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Graph
    )

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($step in @($Graph.steps)) {
        if ([string]$step.status -ne 'COMMITTED') { continue }
        $wrapper = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path ([string]$step.artifactPath))
        $records.Add([ordered]@{
            stepKey = [string]$step.stepKey
            provider = [string]$step.provider
            stage = [string]$step.stage
            round = [int]$step.round
            result = $wrapper.result
        })
    }
    return @($records)
}

function Get-DuoForgeIssueFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Claim
    )

    $normalized = (($Target + '|' + $Category + '|' + $Claim).ToLowerInvariant() -replace '\s+', ' ').Trim()
    return Get-DuoForgeSha256 -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($normalized))
}

function Apply-DuoForgeUserEvidenceRecordsInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Issues,
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$EvidenceRecords
    )

    foreach ($record in $EvidenceRecords) {
        $issue = @($Issues | Where-Object {
            (-not [string]::IsNullOrWhiteSpace([string]$record.issueFingerprint) -and [string]$_.fingerprint -eq [string]$record.issueFingerprint) -or
            [string]$_.issueId -eq [string]$record.issueId
        } | Select-Object -First 1)
        if ($issue.Count -ne 1) { continue }
        $issue = $issue[0]
        $evidenceId = [string]$record.evidenceId
        if ($evidenceId -notin @($issue.evidence | ForEach-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'evidenceId' -Default '') })) {
            $issue.evidence = @($issue.evidence) + @([ordered]@{
                source = [string]$record.snapshotName
                location = 'entire-document'
                excerptHash = [string]$record.snapshotHash
                addedBy = 'user'
                evidenceId = $evidenceId
            })
        }
        if ($evidenceId -notin @($issue.history | ForEach-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'evidenceId' -Default '') })) {
            $issue.history = @($issue.history) + @([ordered]@{
                at = [string]$record.addedAt
                event = 'USER_EVIDENCE_ADDED'
                actor = 'user'
                status = 'OPEN'
                evidenceId = $evidenceId
                snapshotName = [string]$record.snapshotName
            })
        }
        if ([string]$issue.resolutionStatus -eq 'AWAITING_EVIDENCE') {
            $issue.resolutionStatus = 'OPEN'
        }
    }
    return @($Issues)
}

function Apply-DuoForgeUserDecisionRecordsInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Issues,
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$DecisionRecords
    )

    $effective = @(Get-DuoForgeEffectiveUserDecisionsInternal -Records $DecisionRecords)
    foreach ($decision in @($effective | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'action' -Default '') -eq 'ANSWER' })) {
        $issueId = [string](Get-DuoForgeObjectValue -Object $decision -Name 'issueId' -Default '')
        $issue = @($Issues | Where-Object { [string]$_.issueId -eq $issueId } | Select-Object -First 1)
        if ($issue.Count -ne 1) { continue }
        $issue = $issue[0]
        $decisionId = [string](Get-DuoForgeObjectValue -Object $decision -Name 'decisionId' -Default '')
        if (-not $issue.Contains('responses') -or $null -eq $issue.responses) { $issue.responses = [ordered]@{} }
        $userResponses = [System.Collections.Generic.List[object]]::new()
        if ($issue.responses.Contains('user')) { foreach ($response in @($issue.responses.user)) { $userResponses.Add($response) } }
        if ([string]::IsNullOrWhiteSpace($decisionId) -or $decisionId -notin @($userResponses | ForEach-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'decisionId' -Default '') })) {
            $userResponses.Add($decision)
        }
        $issue.responses.user = @($userResponses)
        $issue.resolutionStatus = 'RESOLVED'
        $issue.requiresUser = $false
        $issue.blocking = $false

        $history = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in @($issue.history)) { $history.Add($entry) }
        if ([string]::IsNullOrWhiteSpace($decisionId) -or $decisionId -notin @($history | ForEach-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'decisionId' -Default '') })) {
            $history.Add([ordered]@{
                at = [string](Get-DuoForgeObjectValue -Object $decision -Name 'recordedAt' -Default (Get-DuoForgeUtcNow))
                event = 'USER_DECISION_APPLIED'
                actor = 'user'
                status = 'RESOLVED'
                decisionId = $decisionId
                revision = [int](Get-DuoForgeObjectValue -Object $decision -Name 'revision' -Default 1)
            })
        }
        $issue.history = @($history)
    }
    return @($Issues)
}

function Merge-DuoForgeStageIssues {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$StageResults,
        [AllowEmptyCollection()][object[]]$UserEvidenceRecords = @(),
        [AllowEmptyCollection()][object[]]$UserDecisionRecords = @(),
        [AllowEmptyCollection()][object[]]$PreservedIssues = @()
    )

    $issues = [System.Collections.Generic.List[object]]::new()
    $byFingerprint = @{}
    $byExternalKey = @{}
    $questions = [System.Collections.Generic.List[object]]::new()

    foreach ($preserved in @($PreservedIssues | Where-Object { $null -ne $_ })) {
        $issue = ConvertTo-DuoForgeHashtable -InputObject $preserved
        $fingerprint = [string]$issue.fingerprint
        if ([string]::IsNullOrWhiteSpace($fingerprint) -or $byFingerprint.ContainsKey($fingerprint)) { continue }
        $issues.Add($issue)
        $byFingerprint[$fingerprint] = $issue
        $byExternalKey[[string]$issue.issueId] = $issue
        foreach ($externalKey in @($issue.externalKeys)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$externalKey)) { $byExternalKey[[string]$externalKey] = $issue }
        }
    }

    foreach ($stageRecord in $StageResults) {
        $stageResult = $stageRecord.result
        foreach ($modelIssue in @($stageResult.issues)) {
            $target = [string]$modelIssue.target
            $category = [string]$modelIssue.category
            $claim = [string]$modelIssue.claim
            $fingerprint = Get-DuoForgeIssueFingerprint -Target $target -Category $category -Claim $claim
            $externalKey = [string]$modelIssue.issueKey
            if ($byFingerprint.ContainsKey($fingerprint)) {
                $issue = $byFingerprint[$fingerprint]
                if ($externalKey -notin @($issue.externalKeys)) { $issue.externalKeys = @($issue.externalKeys) + @($externalKey) }
                $issue.history = @($issue.history) + @([ordered]@{
                    at = Get-DuoForgeUtcNow
                    event = 'CORROBORATED'
                    actor = [string]$stageRecord.provider
                    sourceStep = [string]$stageRecord.stepKey
                })
            }
            else {
                $issue = New-DuoForgeIssueInternal `
                    -ExistingIssues @($issues) `
                    -Round ([int]$stageRecord.round) `
                    -RaisedBy ([string]$stageRecord.provider) `
                    -Target $target `
                    -Category $category `
                    -Severity ([string]$modelIssue.severity) `
                    -Claim $claim `
                    -Proposal ([string]$modelIssue.proposal) `
                    -RequiresUser ([bool]$modelIssue.requiresUser) `
                    -BlockingProposal ([bool]$modelIssue.blockingProposal)
                $issue.fingerprint = $fingerprint
                $issue.externalKeys = @($externalKey)
                $issue.sourceSteps = @([string]$stageRecord.stepKey)
                $issue.evidence = @($modelIssue.evidence)
                if ([string]$issue.severity -eq 'critical') { $issue.resolutionStatus = 'AWAITING_USER' }
                $issues.Add($issue)
                $byFingerprint[$fingerprint] = $issue
            }
            if (-not $byExternalKey.ContainsKey($externalKey)) { $byExternalKey[$externalKey] = $issue }
            $byExternalKey[([string]$stageRecord.provider + ':' + $externalKey)] = $issue
        }

        if ([string]$stageRecord.stage -eq 'final-validation' -and -not [bool]$stageResult.finalApproved -and @($stageResult.issues).Count -eq 0) {
            $fingerprint = Get-DuoForgeIssueFingerprint -Target 'shared-final-document' -Category 'final-validation' -Claim '최종 검증 공급자가 문서를 승인하지 않았습니다.'
            if (-not $byFingerprint.ContainsKey($fingerprint)) {
                $issue = New-DuoForgeIssueInternal -ExistingIssues @($issues) -Round ([int]$stageRecord.round) -RaisedBy orchestrator -Target 'shared-final-document' -Category 'final-validation' -Severity critical -Claim '최종 검증 공급자가 문서를 승인하지 않았습니다.' -Proposal '최종 검증 쟁점을 해결한 뒤 다시 검증하세요.' -RequiresUser $true -BlockingProposal $true
                $issue.fingerprint = $fingerprint
                $issue.externalKeys = @('ORCHESTRATOR-FINAL-VALIDATION')
                $issue.sourceSteps = @([string]$stageRecord.stepKey)
                $issues.Add($issue)
                $byFingerprint[$fingerprint] = $issue
                $byExternalKey['ORCHESTRATOR-FINAL-VALIDATION'] = $issue
            }
        }
    }

    foreach ($stageRecord in $StageResults) {
        foreach ($response in @($stageRecord.result.issueResponses)) {
            $key = [string]$response.issueKey
            $issue = if ($byExternalKey.ContainsKey($key)) { $byExternalKey[$key] } else { $null }
            if ($null -eq $issue) { continue }
            $decision = [ordered]@{
                at = Get-DuoForgeUtcNow
                actor = [string]$stageRecord.provider
                sourceStep = [string]$stageRecord.stepKey
                disposition = [string]$response.disposition
                rationale = [string]$response.rationale
                locations = @($response.locations)
            }
            $issue.ownerDecisions = @($issue.ownerDecisions) + @($decision)
            if ([string]$issue.severity -eq 'critical') {
                $issue.resolutionStatus = if ([string]$response.disposition -eq 'NEEDS_EVIDENCE') { 'AWAITING_EVIDENCE' } else { 'AWAITING_USER' }
            }
            else {
                switch ([string]$response.disposition) {
                    'ACCEPTED' { $issue.resolutionStatus = if (@($response.locations).Count -gt 0) { 'RESOLVED' } else { 'OPEN' } }
                    'PARTIALLY_ACCEPTED' { $issue.resolutionStatus = if (@($response.locations).Count -gt 0) { 'RESOLVED' } else { 'OPEN' } }
                    'REJECTED' { $issue.resolutionStatus = 'RESOLVED' }
                    'DEFERRED' { $issue.resolutionStatus = 'AWAITING_USER' }
                    'NEEDS_EVIDENCE' { $issue.resolutionStatus = 'AWAITING_EVIDENCE' }
                    'ASK_USER' { $issue.resolutionStatus = 'AWAITING_USER' }
                }
            }
        }

        foreach ($adoption in @($stageRecord.result.adoptions)) {
            $key = [string]$adoption.issueKey
            if ($byExternalKey.ContainsKey($key)) {
                $issue = $byExternalKey[$key]
                $issue.adoptions = @($issue.adoptions) + @([ordered]@{
                    at = Get-DuoForgeUtcNow
                    actor = [string]$stageRecord.provider
                    sourceStep = [string]$stageRecord.stepKey
                    sourceProvider = [string]$adoption.sourceProvider
                    target = [string]$adoption.target
                    disposition = [string]$adoption.disposition
                    rationale = [string]$adoption.rationale
                    locations = @($adoption.locations)
                })
            }
        }

        foreach ($question in @($stageRecord.result.openQuestions)) {
            $key = [string]$question.issueKey
            if ($byExternalKey.ContainsKey($key)) {
                $issue = $byExternalKey[$key]
                if ([string]$issue.resolutionStatus -in @('RESOLVED', 'SUPERSEDED', 'AWAITING_EVIDENCE')) { continue }
                $questions.Add([ordered]@{
                    sourceStep = [string]$stageRecord.stepKey
                    provider = [string]$stageRecord.provider
                    issueKey = [string]$issue.issueId
                    title = [string]$question.title
                    question = [string]$question.question
                    options = @($question.options)
                    recommendedOption = [string]$question.recommendedOption
                    reasonNow = [string](Get-DuoForgeObjectValue -Object $question -Name 'reasonNow' -Default '이 쟁점은 사용자 선호에 따라 최종 결과가 달라져 지금 확인이 필요합니다.')
                    plainExplanation = [string](Get-DuoForgeObjectValue -Object $question -Name 'plainExplanation' -Default $issue.claim)
                    codexOpinion = [string](Get-DuoForgeObjectValue -Object $question -Name 'codexOpinion' -Default '기록된 Codex 의견은 상세 설명에서 확인할 수 있습니다.')
                    claudeOpinion = [string](Get-DuoForgeObjectValue -Object $question -Name 'claudeOpinion' -Default '기록된 Claude 의견은 상세 설명에서 확인할 수 있습니다.')
                    impactIfDeferred = [string](Get-DuoForgeObjectValue -Object $question -Name 'impactIfDeferred' -Default '결정 전에는 관련 최종화를 진행할 수 없습니다.')
                    estimatedCost = [string](Get-DuoForgeObjectValue -Object $question -Name 'estimatedCost' -Default '입력 근거만으로 정확한 비용을 산정할 수 없습니다.')
                    reversibility = [string](Get-DuoForgeObjectValue -Object $question -Name 'reversibility' -Default 'unknown')
                    confidence = [string](Get-DuoForgeObjectValue -Object $question -Name 'confidence' -Default 'medium')
                    safeDefault = [string](Get-DuoForgeObjectValue -Object $question -Name 'safeDefault' -Default ([string]$question.recommendedOption))
                    experimentPossible = [bool](Get-DuoForgeObjectValue -Object $question -Name 'experimentPossible' -Default $false)
                    priority = if ([string]$issue.severity -eq 'critical') { 1 } elseif ([string]$issue.severity -eq 'major') { 2 } else { 3 }
                })
                $issue.requiresUser = $true
                $issue.blocking = $true
                $issue.resolutionStatus = 'AWAITING_USER'
            }
        }
    }

    if ($null -ne $UserEvidenceRecords -and @($UserEvidenceRecords | Where-Object { $null -ne $_ }).Count -gt 0) {
        $issues = [System.Collections.Generic.List[object]]::new(@(Apply-DuoForgeUserEvidenceRecordsInternal -Issues @($issues) -EvidenceRecords @($UserEvidenceRecords)))
    }
    if ($null -ne $UserDecisionRecords -and @($UserDecisionRecords | Where-Object { $null -ne $_ }).Count -gt 0) {
        $issues = [System.Collections.Generic.List[object]]::new(@(Apply-DuoForgeUserDecisionRecordsInternal -Issues @($issues) -DecisionRecords @($UserDecisionRecords)))
    }
    $activeIssueIds = @($issues | Where-Object { $_.resolutionStatus -notin @('RESOLVED', 'SUPERSEDED', 'AWAITING_EVIDENCE') } | ForEach-Object { [string]$_.issueId })
    $questions = [System.Collections.Generic.List[object]]::new(@($questions | Where-Object { [string]$_.issueKey -in $activeIssueIds }))

    foreach ($issue in @($issues | Where-Object { $_.blocking -and $_.resolutionStatus -notin @('RESOLVED', 'SUPERSEDED') })) {
        if ([string]$issue.resolutionStatus -eq 'AWAITING_EVIDENCE') {
            $issue.requiresUser = $true
            continue
        }
        if (@($questions | Where-Object { $_.issueKey -eq $issue.issueId }).Count -gt 0) { continue }
        $questions.Add([ordered]@{
            sourceStep = @($issue.sourceSteps | Select-Object -Last 1)[0]
            provider = 'orchestrator'
            issueKey = [string]$issue.issueId
            title = [string]$issue.claim
            question = '이 차단 쟁점을 어떻게 처리할까요?'
            options = @(
                'A: 제안 내용을 반영하고 마지막 문서 단계부터 다시 검증',
                'B: 현재 요구를 유지하고 반대 근거를 고려해 다시 검증'
            )
            recommendedOption = 'A'
            reasonNow = '이 차단 쟁점을 해결하지 않으면 완료 상태로 진행할 수 없습니다.'
            plainExplanation = [string]$issue.claim
            codexOpinion = 'Codex의 관련 판단은 쟁점 이력과 상세 설명에서 확인할 수 있습니다.'
            claudeOpinion = 'Claude의 관련 판단은 쟁점 이력과 상세 설명에서 확인할 수 있습니다.'
            impactIfDeferred = 'Major 쟁점은 부분 완료로만 종료할 수 있고 Critical 쟁점은 보류할 수 없습니다.'
            estimatedCost = '선택에 따라 마지막 문서 단계와 검증 단계가 다시 실행됩니다.'
            reversibility = 'moderate'
            confidence = 'medium'
            safeDefault = 'A'
            experimentPossible = $false
            priority = if ([string]$issue.severity -eq 'critical') { 1 } elseif ([string]$issue.severity -eq 'major') { 2 } else { 3 }
        })
        $issue.requiresUser = $true
        $issue.resolutionStatus = 'AWAITING_USER'
    }

    $latestQuestionByIssue = [ordered]@{}
    foreach ($question in @($questions)) { $latestQuestionByIssue[[string]$question.issueKey] = $question }
    $deduplicatedQuestions = @($latestQuestionByIssue.Values)
    $orderedQuestions = @($deduplicatedQuestions | Sort-Object @{ Expression = { [int](Get-DuoForgeObjectValue -Object $_ -Name 'priority' -Default 99) } }, @{ Expression = { [string]$_.issueKey } })
    return [ordered]@{ issues = @($issues); questions = $orderedQuestions }
}

function Get-DuoForgePendingQuestionBatchInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Questions,
        [ValidateRange(1, 3)][int]$Maximum = 3
    )

    $all = @($Questions)
    $batch = @($all | Select-Object -First $Maximum)
    return [ordered]@{
        total = $all.Count
        batchSize = $batch.Count
        remainingAfterBatch = [Math]::Max(0, $all.Count - $batch.Count)
        questions = $batch
    }
}

function ConvertTo-DuoForgeMarkdownCell {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    return (($Text -replace '\|', '\|') -replace "`r?`n", '<br>')
}

function Get-DuoForgeFinalDocumentName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DocumentType)

    switch ($DocumentType) {
        'prd' { return 'PRD.md' }
        'architecture' { return 'ARCHITECTURE.md' }
        'implementation-plan' { return 'IMPLEMENTATION_PLAN.md' }
        'adr' { return 'ADR.md' }
        default { return 'FINAL.md' }
    }
}

function New-DuoForgeDebateSummaryMarkdown {
    [CmdletBinding()]
    param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$StageResults)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# DuoForge 토론 요약')
    $lines.Add('')
    $lines.Add('| 라운드 | 공급자 | 단계 | 요약 |')
    $lines.Add('|---:|---|---|---|')
    foreach ($record in $StageResults) {
        $summary = ConvertTo-DuoForgeMarkdownCell -Text ([string]$record.result.summary)
        $lines.Add("| $($record.round) | $($record.provider) | $($record.stage) | $summary |")
    }
    $lines.Add('')
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function New-DuoForgeDecisionsMarkdown {
    [CmdletBinding()]
    param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Issues)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# 결정 기록')
    $lines.Add('')
    if ($Issues.Count -eq 0) { $lines.Add('기록된 쟁점이 없습니다.') }
    foreach ($issue in $Issues) {
        $lines.Add("## $($issue.issueId) — $($issue.claim)")
        $lines.Add('')
        $lines.Add("- 심각도: $($issue.severity)")
        $lines.Add("- 상태: $($issue.resolutionStatus)")
        foreach ($decision in @($issue.ownerDecisions)) {
            $decisionActor = [string](Get-DuoForgeObjectValue -Object $decision -Name 'actor' -Default 'unknown')
            $decisionDisposition = [string](Get-DuoForgeObjectValue -Object $decision -Name 'disposition' -Default 'UNKNOWN')
            $decisionRationale = [string](Get-DuoForgeObjectValue -Object $decision -Name 'rationale' -Default '')
            $lines.Add("- ${decisionActor}: $decisionDisposition — $decisionRationale")
        }
        $lines.Add('')
    }
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function New-DuoForgeOpenQuestionsMarkdown {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Questions,
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Issues
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# 사용자 확인 필요 사항')
    $lines.Add('')
    foreach ($question in $Questions) {
        $lines.Add("## $($question.title)")
        $lines.Add('')
        $lines.Add("- 지금 결정하는 이유: $($question.reasonNow)")
        $lines.Add("- 쉬운 설명: $($question.plainExplanation)")
        $lines.Add("- Codex 의견: $($question.codexOpinion)")
        $lines.Add("- Claude 의견: $($question.claudeOpinion)")
        $lines.Add("- 예상 비용: $($question.estimatedCost)")
        $lines.Add("- 되돌리기: $($question.reversibility)")
        $lines.Add("- 권고 신뢰도: $($question.confidence)")
        $lines.Add("- 안전한 기본값: $($question.safeDefault)")
        $lines.Add("- 보류 영향: $($question.impactIfDeferred)")
        $lines.Add('')
        $lines.Add([string]$question.question)
        $lines.Add('')
        foreach ($option in @($question.options)) { $lines.Add("- $option") }
        $lines.Add("- 권장안: $($question.recommendedOption)")
        $lines.Add('')
    }
    foreach ($issue in @($Issues | Where-Object { $_.blocking -and $_.resolutionStatus -notin @('RESOLVED', 'SUPERSEDED') })) {
        if ([string]$issue.issueId -in @($Questions | ForEach-Object { $_.issueKey })) { continue }
        $lines.Add("## $($issue.issueId) — $($issue.claim)")
        $lines.Add('')
        $lines.Add("- 심각도: $($issue.severity)")
        $lines.Add("- 제안: $($issue.proposal)")
        $lines.Add('')
    }
    if ($lines.Count -eq 2) { $lines.Add('사용자 확인이 필요한 항목이 없습니다.') }
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Render-DuoForgeFinalArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Graph
    )

    $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
    $stageResults = @(Get-DuoForgeCommittedStageResults -RunDirectory $RunDirectory -Graph $Graph)
    $userEvidencePath = Join-Path $RunDirectory 'decisions\user-evidence.jsonl'
    $userEvidence = @(Read-DuoForgeJsonLines -Path $userEvidencePath -AllowMissing)
    $userDecisionRecords = @(Read-DuoForgeJsonLines -Path (Join-Path $RunDirectory 'decisions\user-answers.jsonl') -AllowMissing)
    $existingLedgerPath = Join-Path $RunDirectory 'issues.json'
    $existingLedger = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $existingLedgerPath)
    $evidenceIssueIds = @($userEvidence | ForEach-Object { [string]$_.issueId })
    $decisionIssueIds = @($userDecisionRecords | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'action' -Default '') -eq 'ANSWER' } | ForEach-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'issueId' -Default '') })
    $preservedIssues = @($existingLedger.issues | Where-Object { [string]$_.issueId -in $evidenceIssueIds -or [string]$_.issueId -in $decisionIssueIds })
    $merged = Merge-DuoForgeStageIssues -StageResults $stageResults -UserEvidenceRecords $userEvidence -UserDecisionRecords $userDecisionRecords -PreservedIssues $preservedIssues
    Write-DuoForgeJsonAtomic -Path (Join-Path $RunDirectory 'issues.json') -Value ([ordered]@{ schemaVersion = 1; issues = @($merged.issues) })
    Write-DuoForgeJsonAtomic -Path (Join-Path $RunDirectory 'decisions\pending.json') -Value ([ordered]@{ schemaVersion = 1; questions = @($merged.questions) })

    $finalDirectory = Join-Path $RunDirectory 'final'
    $files = [System.Collections.Generic.List[string]]::new()
    if ([string]$manifest.mode -eq 'shared-document') {
        $latest = @($stageResults | Where-Object { $_.stage -eq 'synthesis' } | Sort-Object round -Descending | Select-Object -First 1)
        if ($latest.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$latest[0].result.document)) {
            throw (New-DuoForgeException -Code 'DF-FINAL-DOCUMENT' -Message '완료된 공동 문서 산출물을 찾을 수 없습니다.')
        }
        $documentPath = Join-Path $finalDirectory (Get-DuoForgeFinalDocumentName -DocumentType ([string]$manifest.documentType))
        Write-DuoForgeTextAtomic -Path $documentPath -Text ([string]$latest[0].result.document)
        $files.Add($documentPath)
        foreach ($artifact in @(
            @{ name = 'DEBATE_SUMMARY.md'; text = New-DuoForgeDebateSummaryMarkdown -StageResults $stageResults },
            @{ name = 'DECISIONS.md'; text = New-DuoForgeDecisionsMarkdown -Issues @($merged.issues) },
            @{ name = 'OPEN_QUESTIONS.md'; text = New-DuoForgeOpenQuestionsMarkdown -Questions @($merged.questions) -Issues @($merged.issues) }
        )) {
            $path = Join-Path $finalDirectory $artifact.name
            Write-DuoForgeTextAtomic -Path $path -Text ([string]$artifact.text)
            $files.Add($path)
        }
    }
    else {
        foreach ($provider in @('codex', 'claude')) {
            $latest = @($stageResults | Where-Object { $_.provider -eq $provider -and $_.stage -eq 'owned-document-revision' } | Sort-Object round -Descending | Select-Object -First 1)
            if ($latest.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$latest[0].result.document)) {
                throw (New-DuoForgeException -Code 'DF-FINAL-DOCUMENT' -Message "$provider 최종 문서 산출물을 찾을 수 없습니다.")
            }
            $path = Join-Path $finalDirectory "$provider-final.md"
            Write-DuoForgeTextAtomic -Path $path -Text ([string]$latest[0].result.document)
            $files.Add($path)
        }
        $comparisonPath = Join-Path $finalDirectory 'comparison.md'
        Write-DuoForgeTextAtomic -Path $comparisonPath -Text (New-DuoForgeDebateSummaryMarkdown -StageResults $stageResults)
        $files.Add($comparisonPath)
        $adoptionLines = @('# 채택 기록', '') + @($merged.issues | ForEach-Object {
            $issue = $_
            @($issue.adoptions | ForEach-Object {
                $adoptionActor = [string](Get-DuoForgeObjectValue -Object $_ -Name 'actor' -Default 'unknown')
                $adoptionDisposition = [string](Get-DuoForgeObjectValue -Object $_ -Name 'disposition' -Default 'UNKNOWN')
                $adoptionRationale = [string](Get-DuoForgeObjectValue -Object $_ -Name 'rationale' -Default '')
                "- $($issue.issueId) / ${adoptionActor}: $adoptionDisposition — $adoptionRationale"
            })
        })
        if ($adoptionLines.Count -eq 2) { $adoptionLines += '기록된 채택 항목이 없습니다.' }
        $adoptionPath = Join-Path $finalDirectory 'adoption-log.md'
        Write-DuoForgeTextAtomic -Path $adoptionPath -Text (($adoptionLines -join [Environment]::NewLine) + [Environment]::NewLine)
        $files.Add($adoptionPath)
        $questionsPath = Join-Path $finalDirectory 'OPEN_QUESTIONS.md'
        Write-DuoForgeTextAtomic -Path $questionsPath -Text (New-DuoForgeOpenQuestionsMarkdown -Questions @($merged.questions) -Issues @($merged.issues))
        $files.Add($questionsPath)
    }

    $statePath = Join-Path $RunDirectory 'state.json'
    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
    $state.openIssues = @($merged.issues | Where-Object { $_.resolutionStatus -notin @('RESOLVED', 'SUPERSEDED') } | ForEach-Object { $_.issueId })
    $state.blockingIssues = @($merged.issues | Where-Object { $_.blocking -and $_.resolutionStatus -notin @('RESOLVED', 'SUPERSEDED') } | ForEach-Object { $_.issueId })
    $state.answeredIssues = @($merged.issues | Where-Object { $_.resolutionStatus -in @('RESOLVED', 'SUPERSEDED') } | ForEach-Object { $_.issueId })
    $state.updatedAt = Get-DuoForgeUtcNow
    Write-DuoForgeJsonAtomic -Path $statePath -Value $state

    $contextPlanPath = Join-Path $RunDirectory 'inputs\context-plan.json'
    if (Test-Path -LiteralPath $contextPlanPath -PathType Leaf) {
        $contextPlan = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $contextPlanPath)
        if ([bool]$contextPlan.enabled) {
            $coveragePath = Join-Path $finalDirectory 'COVERAGE.md'
            Write-DuoForgeTextAtomic -Path $coveragePath -Text (New-DuoForgeCoverageMarkdownInternal -ContextPlan $contextPlan)
            $files.Add($coveragePath)
        }
    }
    $artifactIndex = [ordered]@{ schemaVersion = 1; generatedAt = Get-DuoForgeUtcNow; files = @($files | ForEach-Object { [ordered]@{ name = [System.IO.Path]::GetFileName($_); sha256 = Get-DuoForgeSha256 -Path $_ } }) }
    Write-DuoForgeJsonAtomic -Path (Join-Path $finalDirectory 'artifacts.json') -Value $artifactIndex
    return [ordered]@{ files = @($files); issues = @($merged.issues); questions = @($merged.questions) }
}
