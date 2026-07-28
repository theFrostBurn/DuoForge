function Get-DuoForgeStageSchemaPath {
    [CmdletBinding()]
    param([ValidateSet('workflow-v1', 'workflow-v2')][string]$WorkflowVersion = 'workflow-v1')

    $fileName = if ($WorkflowVersion -eq 'workflow-v2') { 'stage-result-v2.schema.json' } else { 'stage-result.schema.json' }
    return Join-Path $script:ProjectRoot "schemas\$fileName"
}

function Get-DuoForgeObjectValue {
    [CmdletBinding()]
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-DuoForgeStageLineagePolicyInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Stage,
        [AllowNull()][string]$TargetDocumentId,
        [AllowEmptyCollection()][string[]]$SourceDocumentIds = @()
    )

    $sources = @($SourceDocumentIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    if (-not [string]::IsNullOrWhiteSpace($TargetDocumentId)) {
        $issueTargets = @($TargetDocumentId)
    }
    elseif ($Stage -in @('document-review', 'review-response')) {
        $issueTargets = @('A', 'B')
    }
    elseif ('brief' -in $sources -and @($sources | Where-Object { $_ -in @('A', 'B') }).Count -eq 0) {
        $issueTargets = @('merged')
    }
    else {
        $issueTargets = @($sources | Where-Object { $_ -in @('A', 'B') })
    }
    return [ordered]@{
        issueTargetDocumentIds = @($issueTargets | Sort-Object -Unique)
        evidenceSourceDocumentIds = @($sources)
        adoptionTargetDocumentIds = @($issueTargets | Sort-Object -Unique)
        adoptionSourceDocumentIds = @($sources)
        adoptionsAllowed = $Stage -in @('synthesis', 'document-revision')
    }
}

function Test-DuoForgeStageResultInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$ExpectedStage,
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$ExpectedProvider,
        [ValidateSet('workflow-v1', 'workflow-v2')][string]$WorkflowVersion = 'workflow-v1',
        [AllowNull()][string]$ExpectedTargetDocumentId,
        [AllowEmptyCollection()][string[]]$ExpectedSourceDocumentIds = @(),
        [AllowNull()][System.Collections.IDictionary]$KnownIssueTargets,
        [switch]$ThrowOnError
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $requiredProperties = @(
        'schemaVersion', 'stage', 'provider', 'summary', 'document', 'issues',
        'issueResponses', 'adoptions', 'openQuestions', 'finalApproved'
    )
    foreach ($name in $requiredProperties) {
        if ($Result -isnot [System.Collections.IDictionary] -or -not $Result.Contains($name)) {
            $errors.Add("필수 속성이 없습니다: $name")
        }
    }

    if ($WorkflowVersion -eq 'workflow-v2') {
        foreach ($name in @('performedBy', 'targetDocumentId', 'sourceDocumentIds')) {
            if ($Result -isnot [System.Collections.IDictionary] -or -not $Result.Contains($name)) {
                $errors.Add("필수 속성이 없습니다: $name")
            }
        }
    }

    $lineagePolicy = if ($WorkflowVersion -eq 'workflow-v2') {
        Get-DuoForgeStageLineagePolicyInternal -Stage $ExpectedStage -TargetDocumentId $ExpectedTargetDocumentId -SourceDocumentIds $ExpectedSourceDocumentIds
    }
    else { $null }

    $expectedSchemaVersion = if ($WorkflowVersion -eq 'workflow-v2') { 2 } else { 1 }
    if ([int](Get-DuoForgeObjectValue -Object $Result -Name 'schemaVersion' -Default 0) -ne $expectedSchemaVersion) {
        $errors.Add("schemaVersion은 $expectedSchemaVersion 이어야 합니다.")
    }
    if ([string](Get-DuoForgeObjectValue -Object $Result -Name 'stage') -cne $ExpectedStage) {
        $errors.Add("stage가 예상값과 다릅니다: $ExpectedStage")
    }
    if ([string](Get-DuoForgeObjectValue -Object $Result -Name 'provider') -cne $ExpectedProvider) {
        $errors.Add("provider가 예상값과 다릅니다: $ExpectedProvider")
    }
    if ($WorkflowVersion -eq 'workflow-v2') {
        if ([string](Get-DuoForgeObjectValue -Object $Result -Name 'performedBy') -cne $ExpectedProvider) {
            $errors.Add("performedBy가 예상값과 다릅니다: $ExpectedProvider")
        }
        $actualTarget = Get-DuoForgeObjectValue -Object $Result -Name 'targetDocumentId'
        $expectedTarget = if ([string]::IsNullOrWhiteSpace($ExpectedTargetDocumentId)) { $null } else { $ExpectedTargetDocumentId }
        if (($null -eq $expectedTarget -and $null -ne $actualTarget) -or ($null -ne $expectedTarget -and [string]$actualTarget -cne [string]$expectedTarget)) {
            $errors.Add("targetDocumentId가 예상값과 다릅니다: $expectedTarget")
        }
        $sourceIds = $null
        if ($Result -is [System.Collections.IDictionary] -and $Result.Contains('sourceDocumentIds')) {
            $sourceIds = $Result['sourceDocumentIds']
        }
        elseif ($null -ne $Result.PSObject.Properties['sourceDocumentIds']) {
            $sourceIds = $Result.PSObject.Properties['sourceDocumentIds'].Value
        }
        if ($null -eq $sourceIds -or $sourceIds -is [string] -or $sourceIds -isnot [System.Collections.IEnumerable]) {
            $errors.Add('sourceDocumentIds 속성은 배열이어야 합니다.')
        }
        else {
            $actualSources = @($sourceIds | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            $expectedSources = @($ExpectedSourceDocumentIds | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            if (($actualSources -join ',') -cne ($expectedSources -join ',')) {
                $errors.Add("sourceDocumentIds가 예상값과 다릅니다: $($expectedSources -join ',')")
            }
        }
    }

    $documentStages = @('independent-draft', 'independent-merge-draft', 'synthesis', 'owned-document-revision', 'document-revision')
    if ($ExpectedStage -in $documentStages -and [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $Result -Name 'document'))) {
        $errors.Add("$ExpectedStage 단계에는 비어 있지 않은 document가 필요합니다.")
    }
    if ($ExpectedStage -in @('final-validation', 'document-validation') -and (Get-DuoForgeObjectValue -Object $Result -Name 'finalApproved') -isnot [bool]) {
        $errors.Add("$ExpectedStage 단계에는 boolean finalApproved가 필요합니다.")
    }

    foreach ($collectionName in @('issues', 'issueResponses', 'adoptions', 'openQuestions')) {
        if ($Result -isnot [System.Collections.IDictionary] -or -not $Result.Contains($collectionName)) {
            $errors.Add("$collectionName 속성은 배열이어야 합니다.")
            continue
        }
        $value = $Result[$collectionName]
        if ($null -eq $value -or $value -is [string] -or $value -isnot [System.Collections.IEnumerable]) {
            $errors.Add("$collectionName 속성은 배열이어야 합니다.")
        }
    }

    $issueItems = if ($Result -is [System.Collections.IDictionary] -and $Result.Contains('issues')) { $Result['issues'] } else { @() }
    $resultIssueTargets = [ordered]@{}
    foreach ($issue in @($issueItems)) {
        $issueKey = [string](Get-DuoForgeObjectValue -Object $issue -Name 'issueKey')
        $issueTargetValue = [string](Get-DuoForgeObjectValue -Object $issue -Name 'targetDocumentId')
        if (-not [string]::IsNullOrWhiteSpace($issueKey)) {
            if ($resultIssueTargets.Contains($issueKey)) {
                $errors.Add("issues.issueKey가 결과 안에서 중복되었습니다: $issueKey")
            }
            else {
                $resultIssueTargets[$issueKey] = $issueTargetValue
            }
            if ($WorkflowVersion -eq 'workflow-v2' -and $null -ne $KnownIssueTargets -and $KnownIssueTargets.Contains($issueKey)) {
                $errors.Add("issues.issueKey가 이전 단계에서 이미 정의되었습니다: $issueKey")
            }
        }
        $severity = [string](Get-DuoForgeObjectValue -Object $issue -Name 'severity')
        if ($severity -notin @('critical', 'major', 'minor')) { $errors.Add('issue.severity 값이 잘못되었습니다.') }
        $issueTargetName = if ($WorkflowVersion -eq 'workflow-v2') { 'targetDocumentId' } else { 'target' }
        foreach ($name in @('issueKey', $issueTargetName, 'category', 'claim')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $issue -Name $name))) {
                $errors.Add("issue.$name 값이 비어 있습니다.")
            }
        }
        if ($WorkflowVersion -eq 'workflow-v2') {
            $issueTarget = [string](Get-DuoForgeObjectValue -Object $issue -Name 'targetDocumentId')
            if ($issueTarget -notin @('A', 'B', 'merged')) { $errors.Add('issue.targetDocumentId 값이 잘못되었습니다.') }
            elseif ($issueTarget -notin @($lineagePolicy.issueTargetDocumentIds)) {
                $errors.Add("issue.targetDocumentId가 $ExpectedStage 단계의 허용 대상과 다릅니다: $issueTarget")
            }
            foreach ($evidence in @(Get-DuoForgeObjectValue -Object $issue -Name 'evidence' -Default @())) {
                foreach ($name in @('sourceDocumentId', 'proposedByProvider', 'path', 'location', 'excerptHash')) {
                    if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $evidence -Name $name))) {
                        $errors.Add("issue.evidence.$name 값이 비어 있습니다.")
                    }
                }
                if ([string](Get-DuoForgeObjectValue -Object $evidence -Name 'sourceDocumentId') -notin @('brief', 'A', 'B', 'merged')) {
                    $errors.Add('issue.evidence.sourceDocumentId 값이 잘못되었습니다.')
                }
                elseif ([string](Get-DuoForgeObjectValue -Object $evidence -Name 'sourceDocumentId') -notin @($lineagePolicy.evidenceSourceDocumentIds)) {
                    $errors.Add("issue.evidence.sourceDocumentId가 $ExpectedStage 단계의 허용 출처와 다릅니다.")
                }
                if ([string](Get-DuoForgeObjectValue -Object $evidence -Name 'proposedByProvider') -notin @('codex', 'claude')) {
                    $errors.Add('issue.evidence.proposedByProvider 값이 잘못되었습니다.')
                }
            }
        }
        foreach ($name in @('requiresUser', 'blockingProposal')) {
            if ((Get-DuoForgeObjectValue -Object $issue -Name $name) -isnot [bool]) {
                $errors.Add("issue.$name 값은 boolean이어야 합니다.")
            }
        }
    }

    $responseItems = if ($Result -is [System.Collections.IDictionary] -and $Result.Contains('issueResponses')) { $Result['issueResponses'] } else { @() }
    $responseStages = @('author-response', 'review-response', 'owner-response', 'final-validation', 'document-validation')
    if ($WorkflowVersion -eq 'workflow-v2' -and $ExpectedStage -notin $responseStages -and @($responseItems).Count -gt 0) {
        $errors.Add("$ExpectedStage 단계에는 issueResponses를 기록할 수 없습니다.")
    }
    if ($ExpectedStage -in $responseStages) {
        foreach ($response in @($responseItems)) {
            $disposition = [string](Get-DuoForgeObjectValue -Object $response -Name 'disposition')
            if ($disposition -notin @('ACCEPTED', 'PARTIALLY_ACCEPTED', 'REJECTED', 'DEFERRED', 'NEEDS_EVIDENCE', 'ASK_USER')) {
                $errors.Add('issueResponses.disposition 값이 잘못되었습니다.')
            }
            if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $response -Name 'issueKey'))) {
                $errors.Add('issueResponses.issueKey 값이 비어 있습니다.')
            }
        }
    }
    if ($WorkflowVersion -eq 'workflow-v2' -and $null -ne $KnownIssueTargets) {
        foreach ($response in @($responseItems)) {
            $referenceKey = [string](Get-DuoForgeObjectValue -Object $response -Name 'issueKey')
            $referenceTarget = if ($resultIssueTargets.Contains($referenceKey)) { [string]$resultIssueTargets[$referenceKey] } elseif ($KnownIssueTargets.Contains($referenceKey)) { [string]$KnownIssueTargets[$referenceKey] } else { '' }
            if ([string]::IsNullOrWhiteSpace($referenceTarget)) {
                $errors.Add("issueResponses.issueKey가 정의된 쟁점을 참조하지 않습니다: $referenceKey")
            }
            elseif ($referenceTarget -notin @($lineagePolicy.issueTargetDocumentIds)) {
                $errors.Add("issueResponses.issueKey가 $ExpectedStage 단계의 허용 대상 쟁점과 다릅니다: $referenceKey")
            }
        }
    }

    $adoptionItems = if ($Result -is [System.Collections.IDictionary] -and $Result.Contains('adoptions')) { $Result['adoptions'] } else { @() }
    if ($WorkflowVersion -eq 'workflow-v2' -and -not [bool]$lineagePolicy.adoptionsAllowed -and @($adoptionItems).Count -gt 0) {
        $errors.Add("$ExpectedStage 단계에는 adoptions를 기록할 수 없습니다.")
    }
    foreach ($adoption in @($adoptionItems)) {
        foreach ($name in @('issueKey', 'rationale')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $adoption -Name $name))) {
                $errors.Add("adoptions.$name 값이 비어 있습니다.")
            }
        }
        if ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'disposition') -notin @('ACCEPTED', 'PARTIALLY_ACCEPTED', 'REJECTED', 'DEFERRED')) {
            $errors.Add('adoptions.disposition 값이 잘못되었습니다.')
        }
        $locations = $null
        if ($adoption -is [System.Collections.IDictionary] -and $adoption.Contains('locations')) { $locations = $adoption['locations'] }
        elseif ($null -ne $adoption.PSObject.Properties['locations']) { $locations = $adoption.PSObject.Properties['locations'].Value }
        if ($null -eq $locations -or $locations -is [string] -or $locations -isnot [System.Collections.IEnumerable]) {
            $errors.Add('adoptions.locations 속성은 배열이어야 합니다.')
        }
        elseif ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'disposition') -in @('ACCEPTED', 'PARTIALLY_ACCEPTED') -and @($locations).Count -eq 0) {
            $errors.Add('ACCEPTED 또는 PARTIALLY_ACCEPTED adoption에는 실제 반영 위치가 필요합니다.')
        }
        if ($WorkflowVersion -eq 'workflow-v2') {
            foreach ($name in @('sourceDocumentId', 'proposedByProvider', 'targetDocumentId')) {
                if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $adoption -Name $name))) {
                    $errors.Add("adoptions.$name 값이 비어 있습니다.")
                }
            }
            if ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'sourceDocumentId') -notin @('brief', 'A', 'B', 'merged')) {
                $errors.Add('adoptions.sourceDocumentId 값이 잘못되었습니다.')
            }
            elseif ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'sourceDocumentId') -notin @($lineagePolicy.adoptionSourceDocumentIds)) {
                $errors.Add("adoptions.sourceDocumentId가 $ExpectedStage 단계의 허용 출처와 다릅니다.")
            }
            if ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'proposedByProvider') -notin @('codex', 'claude')) {
                $errors.Add('adoptions.proposedByProvider 값이 잘못되었습니다.')
            }
            if ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'targetDocumentId') -notin @('A', 'B', 'merged')) {
                $errors.Add('adoptions.targetDocumentId 값이 잘못되었습니다.')
            }
            elseif ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'targetDocumentId') -notin @($lineagePolicy.adoptionTargetDocumentIds)) {
                $errors.Add("adoptions.targetDocumentId가 $ExpectedStage 단계의 허용 대상과 다릅니다.")
            }
            if ($null -ne $KnownIssueTargets) {
                $referenceKey = [string](Get-DuoForgeObjectValue -Object $adoption -Name 'issueKey')
                $referenceTarget = if ($resultIssueTargets.Contains($referenceKey)) { [string]$resultIssueTargets[$referenceKey] } elseif ($KnownIssueTargets.Contains($referenceKey)) { [string]$KnownIssueTargets[$referenceKey] } else { '' }
                if ([string]::IsNullOrWhiteSpace($referenceTarget)) {
                    $errors.Add("adoptions.issueKey가 정의된 쟁점을 참조하지 않습니다: $referenceKey")
                }
                elseif ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'targetDocumentId') -cne $referenceTarget) {
                    $errors.Add("adoptions.targetDocumentId가 참조 쟁점의 대상과 다릅니다: $referenceKey")
                }
            }
        }
    }

    $questionItems = if ($Result -is [System.Collections.IDictionary] -and $Result.Contains('openQuestions')) { $Result['openQuestions'] } else { @() }
    foreach ($question in @($questionItems)) {
        foreach ($name in @('issueKey', 'title', 'question', 'recommendedOption', 'reasonNow', 'plainExplanation', 'codexOpinion', 'claudeOpinion', 'impactIfDeferred', 'estimatedCost', 'safeDefault')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $question -Name $name))) { $errors.Add("openQuestions.$name 값이 비어 있습니다.") }
        }
        $options = @(Get-DuoForgeObjectValue -Object $question -Name 'options' -Default @())
        if ($options.Count -lt 2) { $errors.Add('openQuestions.options에는 두 개 이상의 선택지가 필요합니다.') }
        $reversibility = [string](Get-DuoForgeObjectValue -Object $question -Name 'reversibility' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($reversibility) -and $reversibility -notin @('easy', 'moderate', 'hard', 'unknown')) { $errors.Add('openQuestions.reversibility 값이 잘못되었습니다.') }
        $confidence = [string](Get-DuoForgeObjectValue -Object $question -Name 'confidence' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($confidence) -and $confidence -notin @('low', 'medium', 'high')) { $errors.Add('openQuestions.confidence 값이 잘못되었습니다.') }
        if ((Get-DuoForgeObjectValue -Object $question -Name 'experimentPossible') -isnot [bool]) { $errors.Add('openQuestions.experimentPossible 값은 boolean이어야 합니다.') }
        if ($WorkflowVersion -eq 'workflow-v2' -and $null -ne $KnownIssueTargets) {
            $referenceKey = [string](Get-DuoForgeObjectValue -Object $question -Name 'issueKey')
            $referenceTarget = if ($resultIssueTargets.Contains($referenceKey)) { [string]$resultIssueTargets[$referenceKey] } elseif ($KnownIssueTargets.Contains($referenceKey)) { [string]$KnownIssueTargets[$referenceKey] } else { '' }
            if ([string]::IsNullOrWhiteSpace($referenceTarget)) {
                $errors.Add("openQuestions.issueKey가 정의된 쟁점을 참조하지 않습니다: $referenceKey")
            }
            elseif ($referenceTarget -notin @($lineagePolicy.issueTargetDocumentIds)) {
                $errors.Add("openQuestions.issueKey가 $ExpectedStage 단계의 허용 대상 쟁점과 다릅니다: $referenceKey")
            }
        }
    }

    $validation = [ordered]@{ valid = $errors.Count -eq 0; errors = @($errors) }
    if ($ThrowOnError -and -not $validation.valid) {
        $exception = New-DuoForgeException -Code 'DF-STAGE-SCHEMA' -Message ($validation.errors -join ' ')
        $exception.Data['DuoForgeValidationErrors'] = @($validation.errors)
        throw $exception
    }
    return $validation
}

function Get-DuoForgeKnownIssueTargetsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Graph,
        [string]$ExcludeStepKey
    )

    $targets = [ordered]@{}
    $definitionKeys = @{}
    foreach ($step in @($Graph.steps | Where-Object { [string]$_.status -eq 'COMMITTED' -and [string]$_.stepKey -ne $ExcludeStepKey })) {
        $artifactPath = [string](Get-DuoForgeObjectValue -Object $step -Name 'artifactPath' -Default '')
        if ([string]::IsNullOrWhiteSpace($artifactPath) -or -not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { continue }
        try {
            if (-not [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $step -Name 'artifactHash' -Default '')) -and (Get-DuoForgeSha256 -Path $artifactPath) -ne [string]$step.artifactHash) { continue }
            $wrapper = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $artifactPath)
        }
        catch { continue }
        foreach ($issue in @(Get-DuoForgeObjectValue -Object $wrapper.result -Name 'issues' -Default @())) {
            $key = [string](Get-DuoForgeObjectValue -Object $issue -Name 'issueKey' -Default '')
            $target = [string](Get-DuoForgeObjectValue -Object $issue -Name 'targetDocumentId' -Default '')
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            if ($definitionKeys.ContainsKey($key)) {
                throw (New-DuoForgeException -Code 'DF-ISSUE-REFERENCE-INTEGRITY' -Message "단계 산출물에 중복 issueKey 정의가 있습니다: $key")
            }
            $definitionKeys[$key] = $true
            $targets[$key] = $target
        }
    }

    $ledgerPath = Join-Path $RunDirectory 'issues.json'
    if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
        $ledger = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $ledgerPath)
        foreach ($issue in @(Get-DuoForgeObjectValue -Object $ledger -Name 'issues' -Default @())) {
            $target = Get-DuoForgeIssueTargetInternal -Issue $issue
            $keys = @([string](Get-DuoForgeObjectValue -Object $issue -Name 'issueId' -Default '')) + @(Get-DuoForgeObjectValue -Object $issue -Name 'externalKeys' -Default @())
            foreach ($keyValue in $keys) {
                $key = [string]$keyValue
                if ([string]::IsNullOrWhiteSpace($key)) { continue }
                if ($targets.Contains($key) -and [string]$targets[$key] -cne [string]$target) {
                    throw (New-DuoForgeException -Code 'DF-ISSUE-REFERENCE-INTEGRITY' -Message "쟁점 원장의 issueKey 대상이 단계 산출물과 충돌합니다: $key")
                }
                $targets[$key] = [string]$target
            }
        }
    }
    return $targets
}

function Test-DuoForgeIssueLedgerNonEmptyStringInternal {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
}

function Test-DuoForgeIssueLedgerRoundInternal {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value -or $Value.GetType().FullName -notin @(
            'System.Byte', 'System.SByte', 'System.Int16', 'System.UInt16',
            'System.Int32', 'System.UInt32', 'System.Int64', 'System.UInt64'
        )) {
        return $false
    }
    return ([decimal]$Value -ge 1 -and [decimal]$Value -le 3)
}

function Test-DuoForgeIssueLedgerStringArrayInternal {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()]$Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [System.Collections.IDictionary] -or $Value -isnot [System.Collections.IEnumerable]) {
        return $false
    }
    foreach ($item in @($Value)) {
        if (-not (Test-DuoForgeIssueLedgerNonEmptyStringInternal -Value $item)) { return $false }
    }
    return $true
}

function Assert-DuoForgeIssueLedgerV2Internal {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Issues = @())

    $errors = [System.Collections.Generic.List[string]]::new()
    $issueIds = @{}
    $externalKeys = @{}
    foreach ($issue in @($Issues)) {
        if ($issue -isnot [System.Collections.IDictionary]) {
            $errors.Add('쟁점 원장 항목은 객체여야 합니다.')
            continue
        }
        $issueId = [string](Get-DuoForgeObjectValue -Object $issue -Name 'issueId' -Default '')
        $target = [string](Get-DuoForgeObjectValue -Object $issue -Name 'targetDocumentId' -Default '')
        if ($issueId -notmatch '^D-\d{3,}$') { $errors.Add("issueId 형식이 잘못되었습니다: $issueId") }
        elseif ($issueIds.ContainsKey($issueId)) { $errors.Add("issueId가 중복되었습니다: $issueId") }
        else { $issueIds[$issueId] = $true }
        if ($target -notin @('A', 'B', 'merged')) { $errors.Add("targetDocumentId가 잘못되었습니다: $issueId") }
        if (-not (Test-DuoForgeIssueLedgerRoundInternal -Value (Get-DuoForgeObjectValue -Object $issue -Name 'round' -Default $null)) -or
            [string](Get-DuoForgeObjectValue -Object $issue -Name 'raisedBy' -Default '') -notin @('codex', 'claude', 'orchestrator', 'user') -or
            -not (Test-DuoForgeIssueLedgerNonEmptyStringInternal -Value (Get-DuoForgeObjectValue -Object $issue -Name 'category' -Default $null)) -or
            [string](Get-DuoForgeObjectValue -Object $issue -Name 'severity' -Default '') -notin @('critical', 'major', 'minor') -or
            -not (Test-DuoForgeIssueLedgerNonEmptyStringInternal -Value (Get-DuoForgeObjectValue -Object $issue -Name 'claim' -Default $null)) -or
            (Get-DuoForgeObjectValue -Object $issue -Name 'blocking') -isnot [bool] -or
            [string](Get-DuoForgeObjectValue -Object $issue -Name 'resolutionStatus' -Default '') -notin @('OPEN', 'AWAITING_EVIDENCE', 'AWAITING_USER', 'DEFERRED', 'RESOLVED', 'SUPERSEDED')) {
            $errors.Add("workflow-v2 쟁점 필수 필드가 잘못되었습니다: $issueId")
        }
        $history = $null
        if ($issue.Contains('history')) { $history = $issue.history }
        if ($null -eq $history -or $history -is [string] -or $history -is [System.Collections.IDictionary] -or $history -isnot [System.Collections.IEnumerable] -or @($history).Count -eq 0) {
            $errors.Add("history 속성은 비어 있지 않은 배열이어야 합니다: $issueId")
        }
        if ($issue.Contains('target') -or $issue.Contains('ownerDecisions')) { $errors.Add("workflow-v2 쟁점에 레거시 대상 또는 ownerDecisions가 섞였습니다: $issueId") }

        foreach ($name in @('reviewerVerdicts', 'editorialDecisions', 'adoptions')) {
            $items = $null
            if ($issue.Contains($name)) { $items = $issue[$name] }
            if ($null -eq $items -or $items -is [string] -or $items -is [System.Collections.IDictionary] -or $items -isnot [System.Collections.IEnumerable]) {
                $errors.Add("$name 속성은 배열이어야 합니다: $issueId")
            }
        }
        $issueExternalKeys = $null
        if ($issue.Contains('externalKeys')) { $issueExternalKeys = $issue.externalKeys }
        if (-not (Test-DuoForgeIssueLedgerStringArrayInternal -Value $issueExternalKeys)) {
            $errors.Add("externalKeys 속성은 배열이어야 합니다: $issueId")
            $issueExternalKeys = @()
        }
        $localExternalKeys = @{}
        foreach ($keyValue in @($issueExternalKeys)) {
            $key = [string]$keyValue
            if ([string]::IsNullOrWhiteSpace($key)) { $errors.Add("빈 external issueKey가 있습니다: $issueId"); continue }
            if ($localExternalKeys.ContainsKey($key)) { $errors.Add("쟁점 안에서 external issueKey가 중복되었습니다: $key"); continue }
            $localExternalKeys[$key] = $true
            if ($externalKeys.ContainsKey($key) -and [string]$externalKeys[$key] -ne $issueId) { $errors.Add("external issueKey가 여러 쟁점에 연결됩니다: $key") }
            else { $externalKeys[$key] = $issueId }
        }

        foreach ($verdict in @(Get-DuoForgeObjectValue -Object $issue -Name 'reviewerVerdicts' -Default @())) {
            if ($verdict -isnot [System.Collections.IDictionary] -or
                [string](Get-DuoForgeObjectValue -Object $verdict -Name 'reviewer' -Default '') -notin @('codex', 'claude') -or
                -not (Test-DuoForgeIssueLedgerNonEmptyStringInternal -Value (Get-DuoForgeObjectValue -Object $verdict -Name 'sourceStep' -Default $null)) -or
                -not (Test-DuoForgeIssueLedgerRoundInternal -Value (Get-DuoForgeObjectValue -Object $verdict -Name 'round' -Default $null)) -or
                [string](Get-DuoForgeObjectValue -Object $verdict -Name 'targetDocumentId' -Default '') -ne $target -or
                [string](Get-DuoForgeObjectValue -Object $verdict -Name 'verdict' -Default '') -notin @('AGREES', 'PARTIALLY_AGREES', 'DISAGREES', 'UNVERIFIABLE') -or
                -not (Test-DuoForgeIssueLedgerNonEmptyStringInternal -Value (Get-DuoForgeObjectValue -Object $verdict -Name 'rationale' -Default $null))) {
                $errors.Add("reviewerVerdicts 계약이 잘못되었습니다: $issueId")
            }
        }

        $actualDecisions = [System.Collections.Generic.List[object]]::new()
        foreach ($decision in @(Get-DuoForgeObjectValue -Object $issue -Name 'editorialDecisions' -Default @())) {
            $locationsValue = $null
            if ($decision -is [System.Collections.IDictionary] -and $decision.Contains('locations')) { $locationsValue = $decision['locations'] }
            $locations = @($locationsValue)
            $disposition = [string](Get-DuoForgeObjectValue -Object $decision -Name 'disposition' -Default '')
            if ($decision -isnot [System.Collections.IDictionary] -or
                [string](Get-DuoForgeObjectValue -Object $decision -Name 'performedBy' -Default '') -notin @('codex', 'claude') -or
                -not (Test-DuoForgeIssueLedgerNonEmptyStringInternal -Value (Get-DuoForgeObjectValue -Object $decision -Name 'sourceStep' -Default $null)) -or
                -not (Test-DuoForgeIssueLedgerRoundInternal -Value (Get-DuoForgeObjectValue -Object $decision -Name 'round' -Default $null)) -or
                [string](Get-DuoForgeObjectValue -Object $decision -Name 'targetDocumentId' -Default '') -ne $target -or
                $disposition -notin @('ACCEPTED', 'PARTIALLY_ACCEPTED', 'REJECTED', 'DEFERRED') -or
                -not (Test-DuoForgeIssueLedgerNonEmptyStringInternal -Value (Get-DuoForgeObjectValue -Object $decision -Name 'rationale' -Default $null)) -or
                -not (Test-DuoForgeIssueLedgerStringArrayInternal -Value $locationsValue) -or
                ($disposition -in @('ACCEPTED', 'PARTIALLY_ACCEPTED') -and $locations.Count -eq 0)) {
                $errors.Add("editorialDecisions 계약이 잘못되었습니다: $issueId")
            }
            if ($disposition -in @('ACCEPTED', 'PARTIALLY_ACCEPTED', 'REJECTED')) { $actualDecisions.Add($decision) }
        }
        foreach ($adoption in @(Get-DuoForgeObjectValue -Object $issue -Name 'adoptions' -Default @())) {
            $locationsValue = $null
            if ($adoption -is [System.Collections.IDictionary] -and $adoption.Contains('locations')) { $locationsValue = $adoption['locations'] }
            $locations = @($locationsValue)
            $disposition = [string](Get-DuoForgeObjectValue -Object $adoption -Name 'disposition' -Default '')
            if ($adoption -isnot [System.Collections.IDictionary] -or
                [string](Get-DuoForgeObjectValue -Object $adoption -Name 'performedBy' -Default '') -notin @('codex', 'claude') -or
                -not (Test-DuoForgeIssueLedgerNonEmptyStringInternal -Value (Get-DuoForgeObjectValue -Object $adoption -Name 'sourceStep' -Default $null)) -or
                -not (Test-DuoForgeIssueLedgerRoundInternal -Value (Get-DuoForgeObjectValue -Object $adoption -Name 'round' -Default $null)) -or
                [string](Get-DuoForgeObjectValue -Object $adoption -Name 'proposedByProvider' -Default '') -notin @('codex', 'claude') -or
                [string](Get-DuoForgeObjectValue -Object $adoption -Name 'sourceDocumentId' -Default '') -notin @('brief', 'A', 'B', 'merged') -or
                [string](Get-DuoForgeObjectValue -Object $adoption -Name 'targetDocumentId' -Default '') -ne $target -or
                $disposition -notin @('ACCEPTED', 'PARTIALLY_ACCEPTED', 'REJECTED', 'DEFERRED') -or
                -not (Test-DuoForgeIssueLedgerNonEmptyStringInternal -Value (Get-DuoForgeObjectValue -Object $adoption -Name 'rationale' -Default $null)) -or
                -not (Test-DuoForgeIssueLedgerStringArrayInternal -Value $locationsValue) -or
                ($disposition -in @('ACCEPTED', 'PARTIALLY_ACCEPTED') -and $locations.Count -eq 0)) {
                $errors.Add("adoptions 계약이 잘못되었습니다: $issueId")
            }
        }
        $resolvedByUser = @((Get-DuoForgeObjectValue -Object $issue -Name 'history' -Default @()) | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'event' -Default '') -eq 'USER_DECISION_APPLIED' }).Count -gt 0
        if ([string](Get-DuoForgeObjectValue -Object $issue -Name 'resolutionStatus' -Default '') -eq 'RESOLVED' -and $actualDecisions.Count -eq 0 -and -not $resolvedByUser) {
            $errors.Add("실제 편집 판단 없이 RESOLVED인 쟁점이 있습니다: $issueId")
        }
    }
    if ($errors.Count -gt 0) {
        throw (New-DuoForgeException -Code 'DF-ISSUE-LEDGER-CONTRACT' -Message ($errors -join ' '))
    }
    return $true
}

function Protect-DuoForgeObjectInternal {
    [CmdletBinding()]
    param(
        $Value,
        [Parameter(Mandatory)][ref]$RedactionCount
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $protected = [string]$Value
        $patterns = @(
            '(?i)\b(sk-(?:proj-)?[A-Za-z0-9_-]{12,})\b',
            '(?i)\b(anthropic[_-]?api[_-]?key\s*[:=]\s*)[^\s,;]+',
            '(?i)\b(openai[_-]?api[_-]?key\s*[:=]\s*)[^\s,;]+',
            '(?i)\b(bearer\s+)[A-Za-z0-9._~+\/-]{12,}=*'
        )
        foreach ($pattern in $patterns) {
            $matches = [regex]::Matches($protected, $pattern)
            if ($matches.Count -gt 0) {
                $RedactionCount.Value += $matches.Count
                $protected = [regex]::Replace($protected, $pattern, '[REDACTED_SECRET]')
            }
        }
        return $protected
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $name = [string]$key
            if ($name -match '(?i)(api.?key|access.?token|refresh.?token|authorization|secret|password)') {
                $result[$name] = '[REDACTED_SECRET]'
                $RedactionCount.Value++
            }
            else {
                $result[$name] = Protect-DuoForgeObjectInternal -Value $Value[$key] -RedactionCount $RedactionCount
            }
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @($Value | ForEach-Object { Protect-DuoForgeObjectInternal -Value $_ -RedactionCount $RedactionCount })
        Write-Output -NoEnumerate $items
        return
    }
    return $Value
}

function ConvertFrom-DuoForgeProviderResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RawJson,
        [Parameter(Mandatory)][string]$ExpectedStage,
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$ExpectedProvider,
        [ValidateSet('workflow-v1', 'workflow-v2')][string]$WorkflowVersion = 'workflow-v1',
        [AllowNull()][string]$ExpectedTargetDocumentId,
        [AllowEmptyCollection()][string[]]$ExpectedSourceDocumentIds = @()
    )

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($RawJson)
    $rawHash = Get-DuoForgeSha256 -Bytes $bytes
    try {
        $parsed = ConvertTo-DuoForgeHashtable -InputObject ($RawJson | ConvertFrom-Json -Depth 100)
    }
    catch {
        throw (New-DuoForgeException -Code 'DF-PROVIDER-JSON' -Message "공급자 결과가 유효한 JSON이 아닙니다. 원문 해시: $rawHash")
    }

    $redactions = 0
    $protected = Protect-DuoForgeObjectInternal -Value $parsed -RedactionCount ([ref]$redactions)
    $null = Test-DuoForgeStageResultInternal -Result $protected -ExpectedStage $ExpectedStage -ExpectedProvider $ExpectedProvider -WorkflowVersion $WorkflowVersion -ExpectedTargetDocumentId $ExpectedTargetDocumentId -ExpectedSourceDocumentIds $ExpectedSourceDocumentIds -ThrowOnError
    return [ordered]@{
        rawHash = $rawHash
        redactionCount = $redactions
        result = $protected
    }
}
