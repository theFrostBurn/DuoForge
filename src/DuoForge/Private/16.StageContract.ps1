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

function Test-DuoForgeQuestionOptionMetadataInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Option)

    $text = $Option.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    return $text -match '(?i)\bplaceholder\b|자리\s*표시|옵션\s*나열용|실제\s*선택지는|recommendedOption\s*(?:없음|null|none|n/?a)'
}

function Get-DuoForgeQuestionOptionsForInteractionInternal {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Options = @())

    return @($Options | ForEach-Object { ([string]$_).Trim() } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and -not (Test-DuoForgeQuestionOptionMetadataInternal -Option $_)
    })
}

function Test-DuoForgeQuestionRecommendationInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$RecommendedOption,
        [AllowEmptyCollection()][object[]]$Options = @()
    )

    $recommended = $RecommendedOption.Trim()
    if ([string]::IsNullOrWhiteSpace($recommended)) { return $false }
    for ($index = 0; $index -lt $Options.Count; $index++) {
        $letter = [string][char]([int][char]'A' + $index)
        $option = ([string]$Options[$index]).Trim()
        $prefixPattern = '^\s*' + [regex]::Escape($letter) + '\s*[:：.)-]\s*'
        $optionWithoutPrefix = [regex]::Replace($option, $prefixPattern, '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Trim()
        $recommendedWithoutPrefix = [regex]::Replace($recommended, $prefixPattern, '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Trim()
        if (
            [string]::Equals($recommended, $letter, [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($recommended, $option, [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($recommendedWithoutPrefix, $optionWithoutPrefix, [StringComparison]::OrdinalIgnoreCase)
        ) { return $true }
    }
    return $false
}

function Get-DuoForgeIssueFingerprintInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Claim
    )

    $normalized = (($Target + '|' + $Category + '|' + $Claim).ToLowerInvariant() -replace '\s+', ' ').Trim()
    return Get-DuoForgeSha256 -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($normalized))
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

function New-DuoForgeSafeValidationFailureInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Path,
        [int]$Count = 1,
        [AllowEmptyCollection()][string[]]$Expected = @()
    )

    return [ordered]@{
        code = $Code
        path = $Path
        count = [Math]::Max(1, $Count)
        expected = @($Expected | Where-Object { [string]$_ -in @('A', 'B', 'merged', 'brief', 'codex', 'claude') } | Sort-Object -Unique)
    }
}

function New-DuoForgeIssueReferenceIntegrityExceptionInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FailureCode
    )

    $exception = New-DuoForgeException -Code 'DF-ISSUE-REFERENCE-INTEGRITY' -Message '저장된 단계 산출물과 쟁점 원장의 참조 무결성이 일치하지 않습니다.'
    $exception.Data['DuoForgeValidationFailures'] = @(
        New-DuoForgeSafeValidationFailureInternal -Code $FailureCode -Path $Path
    )
    $exception.Data['DuoForgeFailureCategory'] = 'issue-reference-integrity'
    $exception.Data['DuoForgeFailureStatus'] = 'FAILED_STAGE'
    $exception.Data['DuoForgeRetryable'] = $false
    return $exception
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
        [AllowNull()][System.Collections.IDictionary]$DefinitionIssueTargets,
        [AllowNull()][System.Collections.IDictionary]$ReferenceIssueTargets,
        [AllowNull()][System.Collections.IDictionary]$ReservedIssueFingerprints,
        [AllowNull()][System.Collections.IDictionary]$AdoptableIssueTargets,
        [AllowNull()][System.Collections.IDictionary]$AdoptableIssueProviders,
        [AllowNull()][System.Collections.IDictionary]$ContextEvidenceContract,
        [switch]$ThrowOnIssueReferenceIntegrityError,
        [switch]$ThrowOnError
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $referenceFailures = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $DefinitionIssueTargets) { $DefinitionIssueTargets = $KnownIssueTargets }
    if ($null -eq $ReferenceIssueTargets) { $ReferenceIssueTargets = $KnownIssueTargets }
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
    $issueArray = @($issueItems)
    for ($issueIndex = 0; $issueIndex -lt $issueArray.Count; $issueIndex++) {
        $issue = $issueArray[$issueIndex]
        $issueKey = [string](Get-DuoForgeObjectValue -Object $issue -Name 'issueKey')
        $issueTargetValue = [string](Get-DuoForgeObjectValue -Object $issue -Name 'targetDocumentId')
        $issueCategoryValue = [string](Get-DuoForgeObjectValue -Object $issue -Name 'category')
        $issueClaimValue = [string](Get-DuoForgeObjectValue -Object $issue -Name 'claim')
        if (-not [string]::IsNullOrWhiteSpace($issueKey)) {
            if ($resultIssueTargets.Contains($issueKey)) {
                $errors.Add('issues.issueKey가 결과 안에서 중복되었습니다.')
                $referenceFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-REF-DUPLICATE' -Path "issues[$issueIndex].issueKey"))
            }
            else {
                $resultIssueTargets[$issueKey] = $issueTargetValue
            }
            if ($WorkflowVersion -eq 'workflow-v2' -and $null -ne $DefinitionIssueTargets -and $DefinitionIssueTargets.Contains($issueKey)) {
                $errors.Add('issues.issueKey가 이전 단계에서 이미 정의되었습니다.')
                $referenceFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-REF-KEY-REUSED' -Path "issues[$issueIndex].issueKey"))
            }
            if (
                $WorkflowVersion -eq 'workflow-v2' -and
                $null -ne $ReservedIssueFingerprints -and
                $ReservedIssueFingerprints.Contains($issueKey) -and
                -not [string]::IsNullOrWhiteSpace($issueTargetValue) -and
                -not [string]::IsNullOrWhiteSpace($issueCategoryValue) -and
                -not [string]::IsNullOrWhiteSpace($issueClaimValue)
            ) {
                $issueFingerprint = Get-DuoForgeIssueFingerprintInternal -Target $issueTargetValue -Category $issueCategoryValue -Claim $issueClaimValue
                if ([string]$ReservedIssueFingerprints[$issueKey] -cne $issueFingerprint) {
                    if ($ThrowOnIssueReferenceIntegrityError) {
                        throw (New-DuoForgeIssueReferenceIntegrityExceptionInternal -FailureCode 'DF-INTEGRITY-KEY-FINGERPRINT' -Path "issues[$issueIndex].issueKey")
                    }
                    else {
                        $errors.Add('issues.issueKey가 보존된 다른 쟁점에서 이미 사용되었습니다.')
                        $referenceFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-REF-KEY-REUSED' -Path "issues[$issueIndex].issueKey"))
                    }
                }
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
            if ($issueTarget -cnotin @('A', 'B', 'merged')) { $errors.Add('issue.targetDocumentId 값이 잘못되었습니다.') }
            elseif ($issueTarget -cnotin @($lineagePolicy.issueTargetDocumentIds)) {
                $errors.Add('issue.targetDocumentId가 현재 단계의 허용 대상과 다릅니다.')
                $referenceFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-REF-TARGET-MISMATCH' -Path "issues[$issueIndex].targetDocumentId" -Expected @($lineagePolicy.issueTargetDocumentIds)))
            }
            $evidenceItems = @(Get-DuoForgeObjectValue -Object $issue -Name 'evidence' -Default @())
            if ($ExpectedStage -eq 'context-batch-analysis' -and $null -ne $ContextEvidenceContract -and $evidenceItems.Count -lt 1) { $errors.Add('schema 2 context-batch-analysis issue에는 CORE 근거가 하나 이상 필요합니다.') }
            foreach ($evidence in $evidenceItems) {
                foreach ($name in @('sourceDocumentId', 'proposedByProvider', 'path', 'location', 'excerptHash')) {
                    if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $evidence -Name $name))) {
                        $errors.Add("issue.evidence.$name 값이 비어 있습니다.")
                    }
                }
                if ([string](Get-DuoForgeObjectValue -Object $evidence -Name 'sourceDocumentId') -cnotin @('brief', 'A', 'B', 'merged')) {
                    $errors.Add('issue.evidence.sourceDocumentId 값이 잘못되었습니다.')
                }
                elseif ([string](Get-DuoForgeObjectValue -Object $evidence -Name 'sourceDocumentId') -cnotin @($lineagePolicy.evidenceSourceDocumentIds)) {
                    $errors.Add("issue.evidence.sourceDocumentId가 $ExpectedStage 단계의 허용 출처와 다릅니다.")
                }
                if ([string](Get-DuoForgeObjectValue -Object $evidence -Name 'proposedByProvider') -notin @('codex', 'claude')) {
                    $errors.Add('issue.evidence.proposedByProvider 값이 잘못되었습니다.')
                }
                elseif ($ExpectedStage -eq 'context-batch-analysis' -and $null -ne $ContextEvidenceContract -and [string](Get-DuoForgeObjectValue -Object $evidence -Name 'proposedByProvider') -cne $ExpectedProvider) {
                    $errors.Add('context-batch-analysis evidence.proposedByProvider가 실행 공급자와 다릅니다.')
                }
                if ($ExpectedStage -eq 'context-batch-analysis' -and $null -ne $ContextEvidenceContract) {
                    foreach ($name in @('sourceDocumentId', 'path', 'location', 'excerptHash')) {
                        $actualEvidenceValue = [string](Get-DuoForgeObjectValue -Object $evidence -Name $name -Default '')
                        $expectedEvidenceValue = [string](Get-DuoForgeObjectValue -Object $ContextEvidenceContract -Name $name -Default '')
                        if ($actualEvidenceValue -cne $expectedEvidenceValue) {
                            $errors.Add("context-batch-analysis evidence.$name 값이 CORE 근거 계약과 다릅니다.")
                        }
                    }
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
    if ($WorkflowVersion -eq 'workflow-v2' -and $null -ne $ReferenceIssueTargets) {
        $responseArray = @($responseItems)
        for ($responseIndex = 0; $responseIndex -lt $responseArray.Count; $responseIndex++) {
            $response = $responseArray[$responseIndex]
            $referenceKey = [string](Get-DuoForgeObjectValue -Object $response -Name 'issueKey')
            $referenceTarget = if ($resultIssueTargets.Contains($referenceKey)) { [string]$resultIssueTargets[$referenceKey] } elseif ($ReferenceIssueTargets.Contains($referenceKey)) { [string]$ReferenceIssueTargets[$referenceKey] } else { '' }
            if ([string]::IsNullOrWhiteSpace($referenceTarget)) {
                $errors.Add('issueResponses.issueKey가 정의된 쟁점을 참조하지 않습니다.')
                $referenceFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-REF-DANGLING' -Path "issueResponses[$responseIndex].issueKey"))
            }
            elseif ($referenceTarget -notin @($lineagePolicy.issueTargetDocumentIds)) {
                $errors.Add('issueResponses.issueKey가 현재 단계의 허용 대상 쟁점과 다릅니다.')
                $referenceFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-REF-TARGET-MISMATCH' -Path "issueResponses[$responseIndex].issueKey" -Expected @($lineagePolicy.issueTargetDocumentIds)))
            }
        }
    }

    $adoptionItems = if ($Result -is [System.Collections.IDictionary] -and $Result.Contains('adoptions')) { $Result['adoptions'] } else { @() }
    if ($WorkflowVersion -eq 'workflow-v2' -and -not [bool]$lineagePolicy.adoptionsAllowed -and @($adoptionItems).Count -gt 0) {
        $errors.Add("$ExpectedStage 단계에는 adoptions를 기록할 수 없습니다.")
    }
    $adoptionArray = @($adoptionItems)
    for ($adoptionIndex = 0; $adoptionIndex -lt $adoptionArray.Count; $adoptionIndex++) {
        $adoption = $adoptionArray[$adoptionIndex]
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
            if ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'sourceDocumentId') -cnotin @('brief', 'A', 'B', 'merged')) {
                $errors.Add('adoptions.sourceDocumentId 값이 잘못되었습니다.')
            }
            elseif ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'sourceDocumentId') -cnotin @($lineagePolicy.adoptionSourceDocumentIds)) {
                $errors.Add("adoptions.sourceDocumentId가 $ExpectedStage 단계의 허용 출처와 다릅니다.")
            }
            if ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'proposedByProvider') -notin @('codex', 'claude')) {
                $errors.Add('adoptions.proposedByProvider 값이 잘못되었습니다.')
            }
            if ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'targetDocumentId') -cnotin @('A', 'B', 'merged')) {
                $errors.Add('adoptions.targetDocumentId 값이 잘못되었습니다.')
            }
            elseif ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'targetDocumentId') -cnotin @($lineagePolicy.adoptionTargetDocumentIds)) {
                $errors.Add('adoptions.targetDocumentId가 현재 단계의 허용 대상과 다릅니다.')
                $referenceFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-REF-TARGET-MISMATCH' -Path "adoptions[$adoptionIndex].targetDocumentId" -Expected @($lineagePolicy.adoptionTargetDocumentIds)))
            }
            if ($null -ne $ReferenceIssueTargets -or $null -ne $AdoptableIssueTargets) {
                $referenceKey = [string](Get-DuoForgeObjectValue -Object $adoption -Name 'issueKey')
                $referenceTarget = if ($null -ne $AdoptableIssueTargets) {
                    if ($AdoptableIssueTargets.Contains($referenceKey)) { [string]$AdoptableIssueTargets[$referenceKey] } else { '' }
                }
                elseif ($resultIssueTargets.Contains($referenceKey)) { [string]$resultIssueTargets[$referenceKey] }
                elseif ($ReferenceIssueTargets.Contains($referenceKey)) { [string]$ReferenceIssueTargets[$referenceKey] }
                else { '' }
                if ([string]::IsNullOrWhiteSpace($referenceTarget)) {
                    $errors.Add('adoptions.issueKey가 정의된 쟁점을 참조하지 않습니다.')
                    $referenceFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-REF-DANGLING' -Path "adoptions[$adoptionIndex].issueKey"))
                }
                elseif ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'targetDocumentId') -cne $referenceTarget) {
                    $errors.Add('adoptions.targetDocumentId가 참조 쟁점의 대상과 다릅니다.')
                    $referenceFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-REF-TARGET-MISMATCH' -Path "adoptions[$adoptionIndex].targetDocumentId" -Expected @($referenceTarget)))
                }
                if ($null -ne $AdoptableIssueProviders -and $AdoptableIssueProviders.Contains($referenceKey)) {
                    $referenceProvider = [string]$AdoptableIssueProviders[$referenceKey]
                    if ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'proposedByProvider') -cne $referenceProvider) {
                        $errors.Add('adoptions.proposedByProvider가 참조 카탈로그의 공급자와 다릅니다.')
                        $referenceFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-REF-PROVIDER-MISMATCH' -Path "adoptions[$adoptionIndex].proposedByProvider" -Expected @($referenceProvider)))
                    }
                }
            }
        }
    }

    $questionItems = if ($Result -is [System.Collections.IDictionary] -and $Result.Contains('openQuestions')) { $Result['openQuestions'] } else { @() }
    $questionArray = @($questionItems)
    for ($questionIndex = 0; $questionIndex -lt $questionArray.Count; $questionIndex++) {
        $question = $questionArray[$questionIndex]
        foreach ($name in @('issueKey', 'title', 'question', 'recommendedOption', 'reasonNow', 'plainExplanation', 'codexOpinion', 'claudeOpinion', 'impactIfDeferred', 'estimatedCost', 'safeDefault')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $question -Name $name))) { $errors.Add("openQuestions.$name 값이 비어 있습니다.") }
        }
        $options = @(Get-DuoForgeObjectValue -Object $question -Name 'options' -Default @())
        if ($options.Count -lt 2 -or $options.Count -gt 3) { $errors.Add('openQuestions.options에는 실제 선택지 두 개 또는 세 개가 필요합니다.') }
        $normalizedOptions = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        for ($optionIndex = 0; $optionIndex -lt $options.Count; $optionIndex++) {
            if ($options[$optionIndex] -isnot [string]) {
                $errors.Add('openQuestions.options의 각 선택지는 문자열이어야 합니다.')
                continue
            }
            $optionText = ([string]$options[$optionIndex]).Trim()
            if ([string]::IsNullOrWhiteSpace($optionText)) {
                $errors.Add('openQuestions.options에는 비어 있지 않은 선택지만 사용할 수 있습니다.')
                continue
            }
            if (Test-DuoForgeQuestionOptionMetadataInternal -Option $optionText) {
                $errors.Add('openQuestions.options에는 스키마 설명이나 자리 표시 문구를 사용할 수 없습니다.')
            }
            $letter = [string][char]([int][char]'A' + $optionIndex)
            $prefixPattern = '^\s*' + [regex]::Escape($letter) + '\s*[:：.)-]\s*'
            $normalizedOption = ([regex]::Replace($optionText, $prefixPattern, '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) -replace '\s+', ' ').Trim()
            if (-not $normalizedOptions.Add($normalizedOption)) {
                $errors.Add('openQuestions.options에는 서로 다른 선택지만 사용할 수 있습니다.')
            }
        }
        $recommendedOption = [string](Get-DuoForgeObjectValue -Object $question -Name 'recommendedOption' -Default '')
        if (-not (Test-DuoForgeQuestionRecommendationInternal -RecommendedOption $recommendedOption -Options $options)) {
            $errors.Add('openQuestions.recommendedOption은 options의 실제 선택지 또는 해당 A/B/C 코드와 일치해야 합니다.')
        }
        $reversibility = [string](Get-DuoForgeObjectValue -Object $question -Name 'reversibility' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($reversibility) -and $reversibility -notin @('easy', 'moderate', 'hard', 'unknown')) { $errors.Add('openQuestions.reversibility 값이 잘못되었습니다.') }
        $confidence = [string](Get-DuoForgeObjectValue -Object $question -Name 'confidence' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($confidence) -and $confidence -notin @('low', 'medium', 'high')) { $errors.Add('openQuestions.confidence 값이 잘못되었습니다.') }
        if ((Get-DuoForgeObjectValue -Object $question -Name 'experimentPossible') -isnot [bool]) { $errors.Add('openQuestions.experimentPossible 값은 boolean이어야 합니다.') }
        if ($WorkflowVersion -eq 'workflow-v2' -and $null -ne $ReferenceIssueTargets) {
            $referenceKey = [string](Get-DuoForgeObjectValue -Object $question -Name 'issueKey')
            $referenceTarget = if ($resultIssueTargets.Contains($referenceKey)) { [string]$resultIssueTargets[$referenceKey] } elseif ($ReferenceIssueTargets.Contains($referenceKey)) { [string]$ReferenceIssueTargets[$referenceKey] } else { '' }
            if ([string]::IsNullOrWhiteSpace($referenceTarget)) {
                $errors.Add('openQuestions.issueKey가 정의된 쟁점을 참조하지 않습니다.')
                $referenceFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-REF-DANGLING' -Path "openQuestions[$questionIndex].issueKey"))
            }
            elseif ($referenceTarget -notin @($lineagePolicy.issueTargetDocumentIds)) {
                $errors.Add('openQuestions.issueKey가 현재 단계의 허용 대상 쟁점과 다릅니다.')
                $referenceFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-REF-TARGET-MISMATCH' -Path "openQuestions[$questionIndex].issueKey" -Expected @($lineagePolicy.issueTargetDocumentIds)))
            }
        }
    }

    $structuralErrorCount = [Math]::Max(0, $errors.Count - $referenceFailures.Count)
    $validationFailures = [System.Collections.Generic.List[object]]::new()
    if ($structuralErrorCount -gt 0) {
        $validationFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-VAL-STRUCTURE' -Path '$' -Count $structuralErrorCount))
    }
    foreach ($failure in @($referenceFailures)) { $validationFailures.Add($failure) }
    $validation = [ordered]@{ valid = $errors.Count -eq 0; errors = @($errors); validationFailures = @($validationFailures) }
    if ($ThrowOnError -and -not $validation.valid) {
        $errorCode = if ($structuralErrorCount -gt 0) { 'DF-STAGE-SCHEMA' } else { 'DF-STAGE-REFERENCE' }
        $message = if ($errorCode -eq 'DF-STAGE-REFERENCE') { '단계 결과의 쟁점 참조 검증에 실패했습니다.' } else { '단계 결과의 구조 검증에 실패했습니다.' }
        $exception = New-DuoForgeException -Code $errorCode -Message $message
        $exception.Data['DuoForgeValidationErrors'] = @($validation.errors)
        $exception.Data['DuoForgeValidationFailures'] = @($validation.validationFailures)
        if ($errorCode -eq 'DF-STAGE-REFERENCE') {
            $exception.Data['DuoForgeFailureCategory'] = 'stage-reference'
            $exception.Data['DuoForgeFailureStatus'] = 'FAILED_STAGE'
            $exception.Data['DuoForgeRetryable'] = $false
        }
        throw $exception
    }
    return $validation
}

function Get-DuoForgeIssueTargetMapsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Graph,
        [string]$ExcludeStepKey
    )

    $definitionTargets = [ordered]@{}
    $referenceTargets = [ordered]@{}
    $reservedFingerprints = [ordered]@{}
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
                throw (New-DuoForgeIssueReferenceIntegrityExceptionInternal -FailureCode 'DF-INTEGRITY-DUPLICATE-KEY' -Path 'issues[].issueKey')
            }
            $definitionKeys[$key] = $true
            $definitionTargets[$key] = $target
            $referenceTargets[$key] = $target
        }
    }

    $ledgerPath = Join-Path $RunDirectory 'issues.json'
    if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
        $ledger = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $ledgerPath)
        foreach ($issue in @(Get-DuoForgeObjectValue -Object $ledger -Name 'issues' -Default @())) {
            $target = Get-DuoForgeIssueTargetInternal -Issue $issue
            $category = [string](Get-DuoForgeObjectValue -Object $issue -Name 'category' -Default '')
            $claim = [string](Get-DuoForgeObjectValue -Object $issue -Name 'claim' -Default '')
            $storedFingerprint = [string](Get-DuoForgeObjectValue -Object $issue -Name 'fingerprint' -Default '')
            $fingerprint = if (-not [string]::IsNullOrWhiteSpace([string]$target) -and -not [string]::IsNullOrWhiteSpace($category) -and -not [string]::IsNullOrWhiteSpace($claim)) {
                Get-DuoForgeIssueFingerprintInternal -Target ([string]$target) -Category $category -Claim $claim
            }
            else { '' }
            if (-not [string]::IsNullOrWhiteSpace($storedFingerprint) -and $storedFingerprint -cne $fingerprint) {
                throw (New-DuoForgeIssueReferenceIntegrityExceptionInternal -FailureCode 'DF-INTEGRITY-LEDGER-FINGERPRINT' -Path 'issues[].fingerprint')
            }
            $keys = @([string](Get-DuoForgeObjectValue -Object $issue -Name 'issueId' -Default '')) + @(Get-DuoForgeObjectValue -Object $issue -Name 'externalKeys' -Default @())
            foreach ($keyValue in $keys) {
                $key = [string]$keyValue
                if ([string]::IsNullOrWhiteSpace($key)) { continue }
                if ($referenceTargets.Contains($key) -and [string]$referenceTargets[$key] -cne [string]$target) {
                    throw (New-DuoForgeIssueReferenceIntegrityExceptionInternal -FailureCode 'DF-INTEGRITY-TARGET-MISMATCH' -Path 'issues[].externalKeys')
                }
                $referenceTargets[$key] = [string]$target
                if (-not [string]::IsNullOrWhiteSpace($fingerprint)) {
                    if ($reservedFingerprints.Contains($key) -and [string]$reservedFingerprints[$key] -cne $fingerprint) {
                        throw (New-DuoForgeIssueReferenceIntegrityExceptionInternal -FailureCode 'DF-INTEGRITY-KEY-FINGERPRINT' -Path 'issues[].externalKeys')
                    }
                    $reservedFingerprints[$key] = $fingerprint
                }
            }
        }
    }
    return [ordered]@{
        definitionTargets = $definitionTargets
        referenceTargets = $referenceTargets
        reservedFingerprints = $reservedFingerprints
    }
}

function Get-DuoForgeKnownIssueTargetsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Graph,
        [string]$ExcludeStepKey
    )

    return (Get-DuoForgeIssueTargetMapsInternal -RunDirectory $RunDirectory -Graph $Graph -ExcludeStepKey $ExcludeStepKey).referenceTargets
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
        $storedFingerprint = [string](Get-DuoForgeObjectValue -Object $issue -Name 'fingerprint' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($target) -and
            -not [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $issue -Name 'category' -Default '')) -and
            -not [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $issue -Name 'claim' -Default ''))) {
            $expectedFingerprint = Get-DuoForgeIssueFingerprintInternal -Target $target -Category ([string]$issue.category) -Claim ([string]$issue.claim)
            if ([string]::IsNullOrWhiteSpace($storedFingerprint) -or $storedFingerprint -cne $expectedFingerprint) {
                $errors.Add("fingerprint가 쟁점 내용과 일치하지 않습니다: $issueId")
            }
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
