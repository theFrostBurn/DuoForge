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

function Test-DuoForgeStageResultInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$ExpectedStage,
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$ExpectedProvider,
        [ValidateSet('workflow-v1', 'workflow-v2')][string]$WorkflowVersion = 'workflow-v1',
        [AllowNull()][string]$ExpectedTargetDocumentId,
        [AllowEmptyCollection()][string[]]$ExpectedSourceDocumentIds = @(),
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
    foreach ($issue in @($issueItems)) {
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
            foreach ($evidence in @(Get-DuoForgeObjectValue -Object $issue -Name 'evidence' -Default @())) {
                foreach ($name in @('sourceDocumentId', 'proposedByProvider', 'path', 'location', 'excerptHash')) {
                    if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $evidence -Name $name))) {
                        $errors.Add("issue.evidence.$name 값이 비어 있습니다.")
                    }
                }
                if ([string](Get-DuoForgeObjectValue -Object $evidence -Name 'sourceDocumentId') -notin @('brief', 'A', 'B', 'merged')) {
                    $errors.Add('issue.evidence.sourceDocumentId 값이 잘못되었습니다.')
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

    $responseStages = @('author-response', 'review-response', 'owner-response')
    if ($ExpectedStage -in $responseStages) {
        $responseItems = if ($Result -is [System.Collections.IDictionary] -and $Result.Contains('issueResponses')) { $Result['issueResponses'] } else { @() }
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

    $adoptionItems = if ($Result -is [System.Collections.IDictionary] -and $Result.Contains('adoptions')) { $Result['adoptions'] } else { @() }
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
        if ($WorkflowVersion -eq 'workflow-v2') {
            foreach ($name in @('sourceDocumentId', 'proposedByProvider', 'targetDocumentId')) {
                if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $adoption -Name $name))) {
                    $errors.Add("adoptions.$name 값이 비어 있습니다.")
                }
            }
            if ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'sourceDocumentId') -notin @('brief', 'A', 'B', 'merged')) {
                $errors.Add('adoptions.sourceDocumentId 값이 잘못되었습니다.')
            }
            if ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'proposedByProvider') -notin @('codex', 'claude')) {
                $errors.Add('adoptions.proposedByProvider 값이 잘못되었습니다.')
            }
            if ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'targetDocumentId') -notin @('A', 'B', 'merged')) {
                $errors.Add('adoptions.targetDocumentId 값이 잘못되었습니다.')
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
    }

    $validation = [ordered]@{ valid = $errors.Count -eq 0; errors = @($errors) }
    if ($ThrowOnError -and -not $validation.valid) {
        $exception = New-DuoForgeException -Code 'DF-STAGE-SCHEMA' -Message ($validation.errors -join ' ')
        $exception.Data['DuoForgeValidationErrors'] = @($validation.errors)
        throw $exception
    }
    return $validation
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
