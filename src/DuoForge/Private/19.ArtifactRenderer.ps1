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
            performedBy = [string](Get-DuoForgeObjectValue -Object $step -Name 'performedBy' -Default ([string]$step.provider))
            targetDocumentId = Get-DuoForgeObjectValue -Object $step -Name 'targetDocumentId'
            sourceDocumentIds = @(Get-DuoForgeObjectValue -Object $step -Name 'sourceDocumentIds' -Default @())
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

    return Get-DuoForgeIssueFingerprintInternal -Target $Target -Category $Category -Claim $Claim
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
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$DecisionRecords,
        [AllowEmptyCollection()][object[]]$Questions = @()
    )

    $effective = @(Get-DuoForgeEffectiveUserDecisionsInternal -Records $DecisionRecords)
    foreach ($decision in @($effective | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'action' -Default '') -eq 'ANSWER' })) {
        $issueId = [string](Get-DuoForgeObjectValue -Object $decision -Name 'issueId' -Default '')
        $issue = @($Issues | Where-Object { [string]$_.issueId -eq $issueId } | Select-Object -First 1)
        if ($issue.Count -ne 1) { continue }
        $issue = $issue[0]
        $decisionFingerprint = [string](Get-DuoForgeObjectValue -Object $decision -Name 'issueFingerprint' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($decisionFingerprint) -and $decisionFingerprint -cne [string]$issue.fingerprint) { continue }
        $currentQuestion = @($Questions | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'issueKey' -Default '') -eq $issueId } | Select-Object -Last 1)
        if ($currentQuestion.Count -eq 1) {
            $recordedQuestionText = ([string](Get-DuoForgeObjectValue -Object $decision -Name 'questionText' -Default '') -replace '\s+', ' ').Trim()
            $currentQuestionText = ([string](Get-DuoForgeObjectValue -Object $currentQuestion[0] -Name 'question' -Default '') -replace '\s+', ' ').Trim()
            $recordedOptions = @((Get-DuoForgeObjectValue -Object $decision -Name 'questionOptions' -Default @()) | ForEach-Object { ([string]$_ -replace '\s+', ' ').Trim() })
            $currentOptions = @((Get-DuoForgeObjectValue -Object $currentQuestion[0] -Name 'options' -Default @()) | ForEach-Object { ([string]$_ -replace '\s+', ' ').Trim() })
            if ((-not [string]::IsNullOrWhiteSpace($recordedQuestionText) -and $recordedQuestionText -cne $currentQuestionText) -or
                ($recordedOptions.Count -gt 0 -and ($recordedOptions -join "`n") -cne ($currentOptions -join "`n"))) {
                continue
            }
        }
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
        $appliedDecisionIds = @($history | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'event' -Default '') -eq 'USER_DECISION_APPLIED' } | ForEach-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'decisionId' -Default '') })
        if ([string]::IsNullOrWhiteSpace($decisionId) -or $decisionId -notin $appliedDecisionIds) {
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
        [AllowEmptyCollection()][object[]]$PreservedIssues = @(),
        [ValidateSet('workflow-v1', 'workflow-v2', 'workflow-v3')][string]$WorkflowVersion = 'workflow-v1'
    )

    $issues = [System.Collections.Generic.List[object]]::new()
    $byFingerprint = @{}
    $byExternalKey = @{}
    $definedExternalKeys = @{}
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
            $target = if ($WorkflowVersion -in @('workflow-v2', 'workflow-v3')) {
                [string](Get-DuoForgeObjectValue -Object $modelIssue -Name 'targetDocumentId' -Default '')
            }
            else {
                [string](Get-DuoForgeObjectValue -Object $modelIssue -Name 'target' -Default '')
            }
            $category = [string]$modelIssue.category
            $claim = [string]$modelIssue.claim
            $fingerprint = Get-DuoForgeIssueFingerprint -Target $target -Category $category -Claim $claim
            $externalKey = [string]$modelIssue.issueKey
            if ($WorkflowVersion -in @('workflow-v2', 'workflow-v3')) {
                if ($definedExternalKeys.ContainsKey($externalKey)) {
                    throw (New-DuoForgeIssueReferenceIntegrityExceptionInternal -FailureCode 'DF-INTEGRITY-DUPLICATE-KEY' -Path 'issues[].issueKey')
                }
                $definedExternalKeys[$externalKey] = $fingerprint
            }
            if ($byExternalKey.ContainsKey($externalKey) -and [string]$byExternalKey[$externalKey].fingerprint -cne $fingerprint) {
                throw (New-DuoForgeIssueReferenceIntegrityExceptionInternal -FailureCode 'DF-INTEGRITY-KEY-FINGERPRINT' -Path 'issues[].issueKey')
            }
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
                    -Round ([Math]::Max(1, [int]$stageRecord.round)) `
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
                if ($WorkflowVersion -in @('workflow-v2', 'workflow-v3')) {
                    $issue.targetDocumentId = $target
                    $issue.Remove('target')
                    $issue.editorialDecisions = @()
                    $issue.reviewerVerdicts = @()
                    $issue.Remove('ownerDecisions')
                }
                if ([string]$issue.severity -eq 'critical') { $issue.resolutionStatus = 'AWAITING_USER' }
                $issues.Add($issue)
                $byFingerprint[$fingerprint] = $issue
            }
            if (-not $byExternalKey.ContainsKey($externalKey)) { $byExternalKey[$externalKey] = $issue }
            $byExternalKey[([string]$stageRecord.provider + ':' + $externalKey)] = $issue
        }

        if ([string]$stageRecord.stage -in @('final-validation', 'document-validation') -and -not [bool]$stageResult.finalApproved -and @($stageResult.issues).Count -eq 0) {
            $validationTarget = if ($WorkflowVersion -in @('workflow-v2', 'workflow-v3')) {
                [string](Get-DuoForgeObjectValue -Object $stageRecord -Name 'targetDocumentId' -Default 'merged')
            }
            else {
                'shared-final-document'
            }
            $validationClaim = if ([string]$stageRecord.stage -eq 'document-validation') {
                "최종 검증 공급자가 문서 $validationTarget 개정본을 승인하지 않았습니다."
            }
            else {
                '최종 검증 공급자가 공동 문서를 승인하지 않았습니다.'
            }
            $fingerprint = Get-DuoForgeIssueFingerprint -Target $validationTarget -Category 'final-validation' -Claim $validationClaim
            if (-not $byFingerprint.ContainsKey($fingerprint)) {
                $issue = New-DuoForgeIssueInternal -ExistingIssues @($issues) -Round ([int]$stageRecord.round) -RaisedBy orchestrator -Target $validationTarget -Category 'final-validation' -Severity critical -Claim $validationClaim -Proposal '최종 검증 쟁점을 해결한 뒤 다시 검증하세요.' -RequiresUser $true -BlockingProposal $true
                if ($WorkflowVersion -in @('workflow-v2', 'workflow-v3')) {
                    $issue.targetDocumentId = $validationTarget
                    $issue.Remove('target')
                    $issue.editorialDecisions = @()
                    $issue.reviewerVerdicts = @()
                    $issue.Remove('ownerDecisions')
                }
                $issue.fingerprint = $fingerprint
                $externalKey = 'ORCHESTRATOR-FINAL-VALIDATION-' + $validationTarget
                $issue.externalKeys = @($externalKey)
                $issue.sourceSteps = @([string]$stageRecord.stepKey)
                $issues.Add($issue)
                $byFingerprint[$fingerprint] = $issue
                $byExternalKey[$externalKey] = $issue
            }
        }
    }

    foreach ($stageRecord in $StageResults) {
        foreach ($response in @($stageRecord.result.issueResponses)) {
            $key = [string]$response.issueKey
            $issue = if ($byExternalKey.ContainsKey($key)) { $byExternalKey[$key] } else { $null }
            if ($null -eq $issue) {
                if ($WorkflowVersion -in @('workflow-v2', 'workflow-v3')) {
                    throw (New-DuoForgeIssueReferenceIntegrityExceptionInternal -FailureCode 'DF-INTEGRITY-DANGLING' -Path 'issueResponses[].issueKey')
                }
                continue
            }
            if ($WorkflowVersion -in @('workflow-v2', 'workflow-v3') -and [string]$stageRecord.stage -in @('author-response', 'review-response', 'final-validation', 'document-validation')) {
                $verdict = switch ([string]$response.disposition) {
                    'ACCEPTED' { 'AGREES' }
                    'PARTIALLY_ACCEPTED' { 'PARTIALLY_AGREES' }
                    'REJECTED' { 'DISAGREES' }
                    default { 'UNVERIFIABLE' }
                }
                $verdictRecord = [ordered]@{
                    at = Get-DuoForgeUtcNow
                    reviewer = [string](Get-DuoForgeObjectValue -Object $stageRecord -Name 'performedBy' -Default ([string]$stageRecord.provider))
                    sourceStep = [string]$stageRecord.stepKey
                    round = [int]$stageRecord.round
                    targetDocumentId = [string](Get-DuoForgeObjectValue -Object $issue -Name 'targetDocumentId' -Default '')
                    verdict = $verdict
                    rationale = [string]$response.rationale
                }
                $issue.reviewerVerdicts = @($issue.reviewerVerdicts) + @($verdictRecord)
                switch ([string]$response.disposition) {
                    'NEEDS_EVIDENCE' { $issue.resolutionStatus = 'AWAITING_EVIDENCE' }
                    'ASK_USER' { $issue.resolutionStatus = 'AWAITING_USER' }
                    'DEFERRED' { $issue.resolutionStatus = 'AWAITING_USER' }
                }
                continue
            }

            $decision = [ordered]@{
                at = Get-DuoForgeUtcNow
                actor = [string]$stageRecord.provider
                sourceStep = [string]$stageRecord.stepKey
                disposition = [string]$response.disposition
                rationale = [string]$response.rationale
                locations = @($response.locations)
            }
            if ($WorkflowVersion -in @('workflow-v2', 'workflow-v3')) {
                $decision.performedBy = [string](Get-DuoForgeObjectValue -Object $stageRecord -Name 'performedBy' -Default ([string]$stageRecord.provider))
                $decision.targetDocumentId = [string](Get-DuoForgeObjectValue -Object $issue -Name 'targetDocumentId' -Default '')
                $decision.round = [int]$stageRecord.round
                $issue.editorialDecisions = @($issue.editorialDecisions) + @($decision)
            }
            else {
                $issue.ownerDecisions = @($issue.ownerDecisions) + @($decision)
            }
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

        if ($WorkflowVersion -in @('workflow-v2', 'workflow-v3') -and @($stageRecord.result.adoptions).Count -gt 0 -and [string]$stageRecord.stage -notin @('synthesis', 'document-revision')) {
            throw (New-DuoForgeIssueReferenceIntegrityExceptionInternal -FailureCode 'DF-INTEGRITY-STAGE-CONTRACT' -Path 'adoptions')
        }
        foreach ($adoption in @($stageRecord.result.adoptions)) {
            $key = [string]$adoption.issueKey
            if ($byExternalKey.ContainsKey($key)) {
                $issue = $byExternalKey[$key]
                if ($WorkflowVersion -in @('workflow-v2', 'workflow-v3') -and [string](Get-DuoForgeObjectValue -Object $adoption -Name 'targetDocumentId' -Default '') -cne [string](Get-DuoForgeObjectValue -Object $issue -Name 'targetDocumentId' -Default '')) {
                    throw (New-DuoForgeIssueReferenceIntegrityExceptionInternal -FailureCode 'DF-INTEGRITY-TARGET-MISMATCH' -Path 'adoptions[].targetDocumentId')
                }
                $adoptionRecord = [ordered]@{
                    at = Get-DuoForgeUtcNow
                    actor = [string]$stageRecord.provider
                    sourceStep = [string]$stageRecord.stepKey
                    round = [int]$stageRecord.round
                    disposition = [string]$adoption.disposition
                    rationale = [string]$adoption.rationale
                    locations = @($adoption.locations)
                }
                if ($WorkflowVersion -in @('workflow-v2', 'workflow-v3')) {
                    $adoptionRecord.sourceDocumentId = [string](Get-DuoForgeObjectValue -Object $adoption -Name 'sourceDocumentId' -Default '')
                    $adoptionRecord.proposedByProvider = [string](Get-DuoForgeObjectValue -Object $adoption -Name 'proposedByProvider' -Default ([string]$stageRecord.provider))
                    $adoptionRecord.targetDocumentId = [string](Get-DuoForgeObjectValue -Object $adoption -Name 'targetDocumentId' -Default '')
                    $adoptionRecord.performedBy = [string](Get-DuoForgeObjectValue -Object $stageRecord -Name 'performedBy' -Default ([string]$stageRecord.provider))
                }
                else {
                    $adoptionRecord.sourceProvider = [string]$adoption.sourceProvider
                    $adoptionRecord.target = [string]$adoption.target
                }
                $issue.adoptions = @($issue.adoptions) + @($adoptionRecord)
                if ($WorkflowVersion -in @('workflow-v2', 'workflow-v3') -and [string]$stageRecord.stage -in @('document-revision', 'synthesis', 'integration', 'final-revision')) {
                    $issue.editorialDecisions = @($issue.editorialDecisions) + @([ordered]@{
                        at = [string]$adoptionRecord.at
                        sourceStep = [string]$adoptionRecord.sourceStep
                        round = [int]$adoptionRecord.round
                        targetDocumentId = [string]$adoptionRecord.targetDocumentId
                        performedBy = [string]$adoptionRecord.performedBy
                        disposition = [string]$adoptionRecord.disposition
                        rationale = [string]$adoptionRecord.rationale
                        locations = @($adoptionRecord.locations)
                    })
                }
                if ([string]$issue.severity -eq 'critical') {
                    $issue.resolutionStatus = 'AWAITING_USER'
                }
                else {
                    switch ([string]$adoption.disposition) {
                        'ACCEPTED' { $issue.resolutionStatus = if (@($adoption.locations).Count -gt 0) { 'RESOLVED' } else { 'OPEN' } }
                        'PARTIALLY_ACCEPTED' { $issue.resolutionStatus = if (@($adoption.locations).Count -gt 0) { 'RESOLVED' } else { 'OPEN' } }
                        'REJECTED' { $issue.resolutionStatus = 'RESOLVED' }
                        'DEFERRED' { $issue.resolutionStatus = 'AWAITING_USER' }
                    }
                }
            }
            elseif ($WorkflowVersion -in @('workflow-v2', 'workflow-v3')) {
                throw (New-DuoForgeIssueReferenceIntegrityExceptionInternal -FailureCode 'DF-INTEGRITY-DANGLING' -Path 'adoptions[].issueKey')
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
            elseif ($WorkflowVersion -in @('workflow-v2', 'workflow-v3')) {
                throw (New-DuoForgeIssueReferenceIntegrityExceptionInternal -FailureCode 'DF-INTEGRITY-DANGLING' -Path 'openQuestions[].issueKey')
            }
        }
    }

    if ($null -ne $UserEvidenceRecords -and @($UserEvidenceRecords | Where-Object { $null -ne $_ }).Count -gt 0) {
        $issues = [System.Collections.Generic.List[object]]::new(@(Apply-DuoForgeUserEvidenceRecordsInternal -Issues @($issues) -EvidenceRecords @($UserEvidenceRecords)))
    }
    if ($null -ne $UserDecisionRecords -and @($UserDecisionRecords | Where-Object { $null -ne $_ }).Count -gt 0) {
        $issues = [System.Collections.Generic.List[object]]::new(@(Apply-DuoForgeUserDecisionRecordsInternal -Issues @($issues) -DecisionRecords @($UserDecisionRecords) -Questions @($questions)))
    }

    foreach ($issue in @($issues | Where-Object { [string]$_.resolutionStatus -notin @('RESOLVED', 'SUPERSEDED') })) {
        $blockingProposals = Get-DuoForgeObjectValue -Object $issue -Name 'blockingProposals' -Default ([ordered]@{})
        $proposalValues = if ($blockingProposals -is [System.Collections.IDictionary]) {
            @($blockingProposals.Values)
        }
        else {
            @($blockingProposals.PSObject.Properties.Value)
        }
        $blockingProposal = @($proposalValues | Where-Object { [bool]$_ }).Count -gt 0
        $issue.blocking = Get-DuoForgeIssueBlockingValue `
            -Severity ([string]$issue.severity) `
            -Category ([string]$issue.category) `
            -RequiresUser ([bool]$issue.requiresUser) `
            -BlockingProposal $blockingProposal
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
        $decisionItems = if ($issue.Contains('editorialDecisions')) { @($issue.editorialDecisions) } else { @($issue.ownerDecisions) }
        foreach ($decision in $decisionItems) {
            $decisionActor = [string](Get-DuoForgeObjectValue -Object $decision -Name 'performedBy' -Default (Get-DuoForgeObjectValue -Object $decision -Name 'actor' -Default 'unknown'))
            $decisionDisposition = [string](Get-DuoForgeObjectValue -Object $decision -Name 'disposition' -Default 'UNKNOWN')
            $decisionRationale = [string](Get-DuoForgeObjectValue -Object $decision -Name 'rationale' -Default '')
            $lines.Add("- 편집 판단 / ${decisionActor}: $decisionDisposition — $decisionRationale")
        }
        foreach ($verdict in @(Get-DuoForgeObjectValue -Object $issue -Name 'reviewerVerdicts' -Default @())) {
            $reviewer = [string](Get-DuoForgeObjectValue -Object $verdict -Name 'reviewer' -Default 'unknown')
            $verdictValue = [string](Get-DuoForgeObjectValue -Object $verdict -Name 'verdict' -Default 'UNVERIFIABLE')
            $verdictRationale = [string](Get-DuoForgeObjectValue -Object $verdict -Name 'rationale' -Default '')
            $lines.Add("- 검토자 평가 / ${reviewer}: $verdictValue — $verdictRationale")
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
        $matchingIssue = @($Issues | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'issueId') -eq [string](Get-DuoForgeObjectValue -Object $question -Name 'issueKey') } | Select-Object -First 1)
        $presentation = Get-DuoForgeInteractiveQuestionPresentationInternal -Question $question -Issue $(if ($matchingIssue.Count -gt 0) { $matchingIssue[0] } else { $null })
        $lines.Add("## $($question.issueKey) · $($presentation.targetLabel) · $($presentation.subjectLabel)")
        $lines.Add('')
        $lines.Add("**$($presentation.requestKind)**")
        $lines.Add('')
        $lines.Add('### 현재 상태')
        $lines.Add('')
        $lines.Add($presentation.currentState)
        $lines.Add('')
        $lines.Add('### 핵심 쟁점')
        $lines.Add('')
        $lines.Add($presentation.coreIssue)
        $lines.Add('')
        $lines.Add('### AI 검토와 문서 처리')
        $lines.Add('')
        $lines.Add("- 최초 제기: $($presentation.originSummary)")
        $lines.Add("- 합의 상태: $($presentation.aiConsensus)")
        $lines.Add("- Codex: $($presentation.codexOpinion)")
        $lines.Add("- Claude: $($presentation.claudeOpinion)")
        $lines.Add("- 문서 처리: $($presentation.documentAction)")
        $lines.Add("- 제안 방향: $($presentation.proposalSummary)")
        $lines.Add('')
        $lines.Add('### 사용자에게 요청하는 것')
        $lines.Add('')
        $lines.Add("- 요청 종류: $($presentation.requestKind)")
        $lines.Add("- 요청 내용: $($presentation.requestPrompt)")
        $lines.Add("- 묻는 목적: $($presentation.requestPurpose)")
        $estimatedCost = [string](Get-DuoForgeObjectValue -Object $question -Name 'estimatedCost' -Default '입력 근거만으로 정확한 비용을 산정할 수 없습니다.')
        $lines.Add("- 예상 비용: $estimatedCost")
        $lines.Add("- 되돌리기: $($presentation.reversibility)")
        $lines.Add("- 권고 신뢰도: $($presentation.confidence)")
        $lines.Add("- 보류 영향: $($presentation.impactIfDeferred)")
        $lines.Add('')
        $lines.Add('### 선택지')
        $lines.Add('')
        foreach ($option in @($presentation.options)) {
            $lines.Add("- $($option.displayOrdinal)안: $($option.label)")
            $lines.Add("  - 결과: $($option.outcome)")
        }
        $lines.Add("- 권장 처리: $($presentation.recommendedLabel)")
        $lines.Add('')
        $lines.Add($presentation.choiceNotice)
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

function Render-DuoForgeThinFinalArtifactsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Graph,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$StageResults
    )

    $selected = @($StageResults | Where-Object { [string]$_.stage -eq 'final-revision' } | Select-Object -Last 1)
    if ($selected.Count -eq 0) { $selected = @($StageResults | Where-Object { [string]$_.stage -eq 'integration' } | Select-Object -Last 1) }
    if ($selected.Count -ne 1) { throw (New-DuoForgeException -Code 'DF-FINAL-DOCUMENT' -Message '얇은 자동 코어의 최종 문서 산출물을 찾을 수 없습니다.') }
    $documentOutputs = @($selected[0].result.documentOutputs)
    [string[]]$expectedIds = if ([string]$Manifest.mode -eq 'dual-document') { @('A', 'B') } else { @('merged') }
    if ($documentOutputs.Count -ne $expectedIds.Count) { throw (New-DuoForgeException -Code 'DF-FINAL-DOCUMENT' -Message '얇은 자동 코어의 최종 문서 수가 저장 계약과 다릅니다.') }

    $finalDirectory = Join-Path $RunDirectory 'final'
    $files = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $expectedIds.Count; $index++) {
        $output = $documentOutputs[$index]
        if ([string](Get-DuoForgeObjectValue -Object $output -Name 'documentId' -Default '') -ne $expectedIds[$index] -or [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $output -Name 'content' -Default ''))) {
            throw (New-DuoForgeException -Code 'DF-FINAL-DOCUMENT' -Message '얇은 자동 코어의 최종 문서 슬롯이 올바르지 않습니다.')
        }
        $name = if ($expectedIds[$index] -eq 'merged') { Get-DuoForgeFinalDocumentName -DocumentType ([string]$Manifest.documentType) } else { "document-$($expectedIds[$index])-final.md" }
        $path = Join-Path $finalDirectory $name
        Write-DuoForgeTextAtomic -Path $path -Text ([string]$output.content)
        $files.Add($path)
    }

    $issueStageResults = if ([string]$selected[0].stage -eq 'final-revision') { @($StageResults | Where-Object { [string]$_.stage -ne 'final-validation' }) } else { @($StageResults) }
    $userDecisionRecords = @(Read-DuoForgeJsonLines -Path (Join-Path $RunDirectory 'decisions\user-answers.jsonl') -AllowMissing)
    $existingLedgerPath = Join-Path $RunDirectory 'issues.json'
    $existingLedger = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $existingLedgerPath)
    $decisionIssueIds = @($userDecisionRecords | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'action' -Default '') -eq 'ANSWER' } | ForEach-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'issueId' -Default '') })
    $preservedIssues = @($existingLedger.issues | Where-Object { [string]$_.issueId -in $decisionIssueIds })
    $merged = Merge-DuoForgeStageIssues -StageResults $issueStageResults -UserDecisionRecords $userDecisionRecords -PreservedIssues $preservedIssues -WorkflowVersion workflow-v3
    $ledger = [ordered]@{ schemaVersion = 2; workflowVersion = 'workflow-v3'; issueSchemaVersion = 2; issues = @($merged.issues) }
    $null = Assert-DuoForgeIssueLedgerV2Internal -Issues @($merged.issues)
    Write-DuoForgeJsonAtomic -Path (Join-Path $RunDirectory 'issues.json') -Value $ledger
    Write-DuoForgeJsonAtomic -Path (Join-Path $RunDirectory 'decisions\pending.json') -Value ([ordered]@{ schemaVersion = 1; questions = @($merged.questions) })
    $questionsPath = Join-Path $finalDirectory 'OPEN_QUESTIONS.md'
    Write-DuoForgeTextAtomic -Path $questionsPath -Text (New-DuoForgeOpenQuestionsMarkdown -Questions @($merged.questions) -Issues @($merged.issues))
    $files.Add($questionsPath)

    $statePath = Join-Path $RunDirectory 'state.json'
    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
    $state.openIssues = @($merged.issues | Where-Object { $_.resolutionStatus -notin @('RESOLVED', 'SUPERSEDED') } | ForEach-Object issueId)
    $state.blockingIssues = @($merged.issues | Where-Object { $_.blocking -and $_.resolutionStatus -notin @('RESOLVED', 'SUPERSEDED') } | ForEach-Object issueId)
    $state.answeredIssues = @($merged.issues | Where-Object { $_.resolutionStatus -in @('RESOLVED', 'SUPERSEDED') } | ForEach-Object issueId)
    $state.updatedAt = Get-DuoForgeUtcNow
    Write-DuoForgeJsonAtomic -Path $statePath -Value $state
    $artifactIndex = [ordered]@{ schemaVersion = 1; generatedAt = Get-DuoForgeUtcNow; files = @($files | ForEach-Object { [ordered]@{ name = [System.IO.Path]::GetFileName($_); sha256 = Get-DuoForgeSha256 -Path $_ } }) }
    Write-DuoForgeJsonAtomic -Path (Join-Path $finalDirectory 'artifacts.json') -Value $artifactIndex
    return [ordered]@{ files = @($files); issues = @($merged.issues); questions = @($merged.questions) }
}

function Render-DuoForgeFinalArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Graph
    )

    $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
    $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
    $stageResults = @(Get-DuoForgeCommittedStageResults -RunDirectory $RunDirectory -Graph $Graph)
    if ($workflowVersion -eq 'workflow-v3') {
        return Render-DuoForgeThinFinalArtifactsInternal -RunDirectory $RunDirectory -Graph $Graph -Manifest (ConvertTo-DuoForgeHashtable -InputObject $manifest) -StageResults $stageResults
    }
    $userEvidencePath = Join-Path $RunDirectory 'decisions\user-evidence.jsonl'
    $userEvidence = @(Read-DuoForgeJsonLines -Path $userEvidencePath -AllowMissing)
    $userDecisionRecords = @(Read-DuoForgeJsonLines -Path (Join-Path $RunDirectory 'decisions\user-answers.jsonl') -AllowMissing)
    $existingLedgerPath = Join-Path $RunDirectory 'issues.json'
    $existingLedger = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $existingLedgerPath)
    $evidenceIssueIds = @($userEvidence | ForEach-Object { [string]$_.issueId })
    $decisionIssueIds = @($userDecisionRecords | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'action' -Default '') -eq 'ANSWER' } | ForEach-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'issueId' -Default '') })
    $preservedIssues = @($existingLedger.issues | Where-Object { [string]$_.issueId -in $evidenceIssueIds -or [string]$_.issueId -in $decisionIssueIds })
    $merged = Merge-DuoForgeStageIssues -StageResults $stageResults -UserEvidenceRecords $userEvidence -UserDecisionRecords $userDecisionRecords -PreservedIssues $preservedIssues -WorkflowVersion $workflowVersion
    $ledger = if ($workflowVersion -eq 'workflow-v2' -and [int]$manifest.schemaVersion -ge 4) {
        [ordered]@{ schemaVersion = 2; workflowVersion = 'workflow-v2'; issueSchemaVersion = 2; issues = @($merged.issues) }
    }
    else {
        [ordered]@{ schemaVersion = 1; issues = @($merged.issues) }
    }
    if ($workflowVersion -eq 'workflow-v2' -and [int]$manifest.schemaVersion -ge 4) {
        $null = Assert-DuoForgeIssueLedgerV2Internal -Issues @($merged.issues)
    }
    Write-DuoForgeJsonAtomic -Path (Join-Path $RunDirectory 'issues.json') -Value $ledger
    Write-DuoForgeJsonAtomic -Path (Join-Path $RunDirectory 'decisions\pending.json') -Value ([ordered]@{ schemaVersion = 1; questions = @($merged.questions) })

    $finalDirectory = Join-Path $RunDirectory 'final'
    $files = [System.Collections.Generic.List[string]]::new()
    if ([string]$manifest.mode -eq 'shared-document') {
        $latest = @($stageResults | Where-Object { $_.stage -eq 'synthesis' } | Sort-Object @{ Expression = { [int](Get-DuoForgeObjectValue -Object $_ -Name 'round' -Default 0) }; Descending = $true } | Select-Object -First 1)
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
    elseif ([string]$manifest.mode -eq 'document-merge') {
        $latest = @($stageResults | Where-Object { $_.stage -eq 'synthesis' } | Sort-Object @{ Expression = { [int](Get-DuoForgeObjectValue -Object $_ -Name 'round' -Default 0) }; Descending = $true } | Select-Object -First 1)
        if ($latest.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$latest[0].result.document)) {
            throw (New-DuoForgeException -Code 'DF-FINAL-DOCUMENT' -Message '완료된 병합 문서 산출물을 찾을 수 없습니다.')
        }
        $documentPath = Join-Path $finalDirectory (Get-DuoForgeFinalDocumentName -DocumentType ([string]$manifest.documentType))
        Write-DuoForgeTextAtomic -Path $documentPath -Text ([string]$latest[0].result.document)
        $files.Add($documentPath)
        $traceLines = @(
            '# 문서 A/B 출처 추적', '',
            '| 쟁점 | 원천 문서 | 제안 작업자 | 대상 문서 | 채택 상태 | 이유 | 반영 위치 | 라운드 |',
            '|---|---|---|---|---|---|---|---:|'
        )
        foreach ($issue in @($merged.issues)) {
            $adoptions = @($issue.adoptions)
            if ($adoptions.Count -eq 0) {
                $traceLines += "| $($issue.issueId) | - | - | $(ConvertTo-DuoForgeMarkdownCell -Text (Get-DuoForgeIssueTargetInternal -Issue $issue)) | $($issue.resolutionStatus) | - | - | - |"
                continue
            }
            foreach ($adoption in $adoptions) {
                $rationale = ConvertTo-DuoForgeMarkdownCell -Text ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'rationale' -Default ''))
                $locations = ConvertTo-DuoForgeMarkdownCell -Text (@($adoption.locations) -join ', ')
                $traceLines += '| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f `
                    $issue.issueId,
                    (Get-DuoForgeObjectValue -Object $adoption -Name 'sourceDocumentId' -Default '-'),
                    (Get-DuoForgeObjectValue -Object $adoption -Name 'proposedByProvider' -Default '-'),
                    (Get-DuoForgeObjectValue -Object $adoption -Name 'targetDocumentId' -Default (Get-DuoForgeIssueTargetInternal -Issue $issue)),
                    (Get-DuoForgeObjectValue -Object $adoption -Name 'disposition' -Default 'UNKNOWN'),
                    $rationale,
                    $locations,
                    (Get-DuoForgeObjectValue -Object $adoption -Name 'round' -Default '-')
            }
        }
        if ($merged.issues.Count -eq 0) { $traceLines += '| - | A/B | - | merged | 기록된 쟁점 없음 | - | - | - |' }
        foreach ($artifact in @(
            @{ name = 'source-trace.md'; text = (($traceLines -join [Environment]::NewLine) + [Environment]::NewLine) },
            @{ name = 'DEBATE_SUMMARY.md'; text = New-DuoForgeDebateSummaryMarkdown -StageResults $stageResults },
            @{ name = 'DECISIONS.md'; text = New-DuoForgeDecisionsMarkdown -Issues @($merged.issues) },
            @{ name = 'OPEN_QUESTIONS.md'; text = New-DuoForgeOpenQuestionsMarkdown -Questions @($merged.questions) -Issues @($merged.issues) }
        )) {
            $path = Join-Path $finalDirectory $artifact.name
            Write-DuoForgeTextAtomic -Path $path -Text ([string]$artifact.text)
            $files.Add($path)
        }
    }
    elseif ($workflowVersion -eq 'workflow-v2') {
        foreach ($documentId in @('A', 'B')) {
            $latest = @($stageResults | Where-Object { [string]$_.targetDocumentId -eq $documentId -and $_.stage -eq 'document-revision' } | Sort-Object @{ Expression = { [int](Get-DuoForgeObjectValue -Object $_ -Name 'round' -Default 0) }; Descending = $true } | Select-Object -First 1)
            if ($latest.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$latest[0].result.document)) {
                throw (New-DuoForgeException -Code 'DF-FINAL-DOCUMENT' -Message "문서 $documentId 최종 개정 산출물을 찾을 수 없습니다.")
            }
            $path = Join-Path $finalDirectory "document-$documentId-final.md"
            Write-DuoForgeTextAtomic -Path $path -Text ([string]$latest[0].result.document)
            $files.Add($path)
        }
        $comparisonPath = Join-Path $finalDirectory 'comparison.md'
        Write-DuoForgeTextAtomic -Path $comparisonPath -Text (New-DuoForgeDebateSummaryMarkdown -StageResults $stageResults)
        $files.Add($comparisonPath)
        $adoptionLines = @(
            '# 문서별 채택 기록', '',
            '| 쟁점 | 원천 문서 | 제안 작업자 | 편집 작업자 | 대상 문서 | 채택 상태 | 이유 | 반영 위치 | 라운드 |',
            '|---|---|---|---|---|---|---|---|---:|'
        )
        $adoptionCount = 0
        foreach ($issue in @($merged.issues)) {
            foreach ($adoption in @($issue.adoptions)) {
                $adoptionCount++
                $rationale = ConvertTo-DuoForgeMarkdownCell -Text ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'rationale' -Default ''))
                $locations = ConvertTo-DuoForgeMarkdownCell -Text (@($adoption.locations) -join ', ')
                $adoptionLines += '| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f `
                    $issue.issueId,
                    (Get-DuoForgeObjectValue -Object $adoption -Name 'sourceDocumentId' -Default '-'),
                    (Get-DuoForgeObjectValue -Object $adoption -Name 'proposedByProvider' -Default '-'),
                    (Get-DuoForgeObjectValue -Object $adoption -Name 'actor' -Default '-'),
                    (Get-DuoForgeObjectValue -Object $adoption -Name 'targetDocumentId' -Default (Get-DuoForgeIssueTargetInternal -Issue $issue)),
                    (Get-DuoForgeObjectValue -Object $adoption -Name 'disposition' -Default 'UNKNOWN'),
                    $rationale,
                    $locations,
                    (Get-DuoForgeObjectValue -Object $adoption -Name 'round' -Default '-')
            }
        }
        if ($adoptionCount -eq 0) { $adoptionLines += '| - | - | - | - | A/B | 기록된 채택 항목 없음 | - | - | - |' }
        $adoptionPath = Join-Path $finalDirectory 'adoption-log.md'
        Write-DuoForgeTextAtomic -Path $adoptionPath -Text (($adoptionLines -join [Environment]::NewLine) + [Environment]::NewLine)
        $files.Add($adoptionPath)
        $questionsPath = Join-Path $finalDirectory 'OPEN_QUESTIONS.md'
        Write-DuoForgeTextAtomic -Path $questionsPath -Text (New-DuoForgeOpenQuestionsMarkdown -Questions @($merged.questions) -Issues @($merged.issues))
        $files.Add($questionsPath)
    }
    else {
        foreach ($provider in @('codex', 'claude')) {
            $latest = @($stageResults | Where-Object { $_.provider -eq $provider -and $_.stage -eq 'owned-document-revision' } | Sort-Object @{ Expression = { [int](Get-DuoForgeObjectValue -Object $_ -Name 'round' -Default 0) }; Descending = $true } | Select-Object -First 1)
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
