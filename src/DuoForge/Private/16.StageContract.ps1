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

function Get-DuoForgeThinStageContractDefinitionInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('independent-result', 'integration', 'final-validation', 'final-revision')][string]$Stage,
        [ValidateRange(0, 2)][int]$OutputDocumentCount
    )

    $isValidation = $Stage -eq 'final-validation'
    if ($isValidation -and $OutputDocumentCount -ne 0) {
        throw (New-DuoForgeException -Code 'DF-THIN-CONTRACT' -Message '최종 검증 단계는 문서 출력을 요구할 수 없습니다.')
    }
    if (-not $isValidation -and $OutputDocumentCount -lt 1) {
        throw (New-DuoForgeException -Code 'DF-THIN-CONTRACT' -Message '문서 생성 단계에는 하나 이상의 출력 문서가 필요합니다.')
    }
    return [ordered]@{
        contractId = 'duoforge-thin-stage-v1'
        stage = $Stage
        primary = [ordered]@{
            kind = if ($isValidation) { 'validation' } else { 'documents' }
            outputDocumentCount = $OutputDocumentCount
            failurePolicy = 'reject-stage'
        }
        metadata = [ordered]@{
            failurePolicy = 'quarantine-item'
            fields = [ordered]@{
                summary = [ordered]@{ kind = 'nullable-string' }
                findings = [ordered]@{
                    kind = 'array'
                    item = [ordered]@{
                        required = @('severity', 'category', 'claim', 'proposal', 'requiresUser', 'blockingProposal', 'documentIndex')
                        severity = @('critical', 'major', 'minor')
                    }
                }
                openQuestions = [ordered]@{
                    kind = 'array'
                    item = [ordered]@{
                        required = @('findingIndex', 'title', 'question', 'options', 'recommendedOption')
                        minimumOptions = 2
                        maximumOptions = 3
                    }
                }
            }
        }
        appOwnedFields = @(
            'schemaVersion', 'stage', 'provider', 'performedBy', 'targetDocumentId',
            'sourceDocumentIds', 'documentId', 'issueKey', 'proposedByProvider'
        )
    }
}

function New-DuoForgeThinProviderSchemaInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Definition)

    $primaryProperties = [ordered]@{}
    $primaryRequired = [System.Collections.Generic.List[string]]::new()
    if ([string]$Definition.primary.kind -eq 'validation') {
        $primaryProperties.approved = [ordered]@{ type = 'boolean' }
        $primaryRequired.Add('approved')
    }
    else {
        $primaryProperties.documents = [ordered]@{
            type = 'array'
            items = [ordered]@{ type = 'string' }
        }
        $primaryRequired.Add('documents')
    }
    $findingContract = $Definition.metadata.fields.findings.item
    $questionContract = $Definition.metadata.fields.openQuestions.item
    $metadataProperties = [ordered]@{
        summary = [ordered]@{ type = @('string', 'null') }
        findings = [ordered]@{
            type = 'array'
            items = [ordered]@{
                type = 'object'
                additionalProperties = $false
                required = @($findingContract.required)
                properties = [ordered]@{
                    severity = [ordered]@{ type = 'string'; enum = @($findingContract.severity) }
                    category = [ordered]@{ type = 'string' }
                    claim = [ordered]@{ type = 'string' }
                    proposal = [ordered]@{ type = 'string' }
                    requiresUser = [ordered]@{ type = 'boolean' }
                    blockingProposal = [ordered]@{ type = 'boolean' }
                    documentIndex = [ordered]@{ type = 'integer' }
                }
            }
        }
        openQuestions = [ordered]@{
            type = 'array'
            items = [ordered]@{
                type = 'object'
                additionalProperties = $false
                required = @($questionContract.required)
                properties = [ordered]@{
                    findingIndex = [ordered]@{ type = 'integer' }
                    title = [ordered]@{ type = 'string' }
                    question = [ordered]@{ type = 'string' }
                    options = [ordered]@{
                        type = 'array'
                        items = [ordered]@{ type = 'string' }
                    }
                    recommendedOption = [ordered]@{ type = 'string' }
                }
            }
        }
    }
    return [ordered]@{
        type = 'object'
        additionalProperties = $false
        required = @('primary', 'metadata')
        properties = [ordered]@{
            primary = [ordered]@{
                type = 'object'
                additionalProperties = $false
                required = @($primaryRequired)
                properties = $primaryProperties
            }
            metadata = [ordered]@{
                type = 'object'
                additionalProperties = $false
                required = @($Definition.metadata.fields.Keys)
                properties = $metadataProperties
            }
        }
    }
}

function Assert-DuoForgeProviderSchemaStrictSubsetInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Schema)

    $allowedKeywords = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($keyword in @(
        '$ref', '$defs', 'description', 'type', 'enum', 'const', 'anyOf',
        'properties', 'required', 'additionalProperties', 'items',
        'exclusiveMinimum', 'exclusiveMaximum', 'multipleOf'
    )) { $null = $allowedKeywords.Add($keyword) }
    $allowedTypes = @('string', 'number', 'boolean', 'integer', 'object', 'array', 'null')
    $propertyCount = 0
    $failure = $null

    function Test-Node {
        param(
            [Parameter(Mandatory)][System.Collections.IDictionary]$Node,
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][int]$Depth,
            [switch]$Root
        )
        if ($null -ne $script:__duoForgeStrictSchemaFailure) { return }
        if ($Depth -gt 10) { $script:__duoForgeStrictSchemaFailure = "$Path.depth"; return }
        foreach ($key in @($Node.Keys)) {
            if (-not $allowedKeywords.Contains([string]$key)) { $script:__duoForgeStrictSchemaFailure = "$Path.keyword"; return }
        }
        $types = @()
        if ($Node.Contains('type')) {
            $typeValue = $Node['type']
            $types = @($typeValue | ForEach-Object { [string]$_ })
            if ($types.Count -eq 0 -or @($types | Where-Object { $_ -notin $allowedTypes }).Count -gt 0) {
                $script:__duoForgeStrictSchemaFailure = "$Path.type"
                return
            }
        }
        if ($Root -and ($types -notcontains 'object' -or $Node.Contains('anyOf'))) {
            $script:__duoForgeStrictSchemaFailure = "$Path.root"
            return
        }
        $isObject = $types -contains 'object' -or $Node.Contains('properties')
        if ($isObject) {
            $properties = if ($Node.Contains('properties')) { $Node['properties'] } else { $null }
            if ($properties -isnot [System.Collections.IDictionary] -or -not $Node.Contains('additionalProperties') -or [bool]$Node['additionalProperties']) {
                $script:__duoForgeStrictSchemaFailure = "$Path.object"
                return
            }
            $propertyNames = @($properties.Keys | ForEach-Object { [string]$_ })
            $requiredNames = if ($Node.Contains('required')) { @($Node['required'] | ForEach-Object { [string]$_ }) } else { @() }
            if ((($propertyNames | Sort-Object) -join "`n") -cne (($requiredNames | Sort-Object) -join "`n")) {
                $script:__duoForgeStrictSchemaFailure = "$Path.required"
                return
            }
            $script:__duoForgeStrictSchemaPropertyCount += $propertyNames.Count
            if ($script:__duoForgeStrictSchemaPropertyCount -gt 5000) { $script:__duoForgeStrictSchemaFailure = "$Path.size"; return }
            foreach ($propertyName in $propertyNames) {
                $child = $properties[$propertyName]
                if ($child -isnot [System.Collections.IDictionary]) { $script:__duoForgeStrictSchemaFailure = "$Path.properties"; return }
                Test-Node -Node $child -Path "$Path.properties.$propertyName" -Depth ($Depth + 1)
            }
        }
        if ($Node.Contains('items')) {
            $items = $Node['items']
            if ($items -isnot [System.Collections.IDictionary]) { $script:__duoForgeStrictSchemaFailure = "$Path.items"; return }
            Test-Node -Node $items -Path "$Path.items" -Depth ($Depth + 1)
        }
        if ($Node.Contains('anyOf')) {
            $branches = @($Node['anyOf'])
            if ($branches.Count -eq 0) { $script:__duoForgeStrictSchemaFailure = "$Path.anyOf"; return }
            for ($index = 0; $index -lt $branches.Count; $index++) {
                if ($branches[$index] -isnot [System.Collections.IDictionary]) { $script:__duoForgeStrictSchemaFailure = "$Path.anyOf"; return }
                Test-Node -Node $branches[$index] -Path "$Path.anyOf[$index]" -Depth ($Depth + 1)
            }
        }
        if ($Node.Contains('$defs')) {
            $definitions = $Node['$defs']
            if ($definitions -isnot [System.Collections.IDictionary]) { $script:__duoForgeStrictSchemaFailure = "$Path.defs"; return }
            foreach ($definitionName in @($definitions.Keys)) {
                if ($definitions[$definitionName] -isnot [System.Collections.IDictionary]) { $script:__duoForgeStrictSchemaFailure = "$Path.defs"; return }
                Test-Node -Node $definitions[$definitionName] -Path "$Path.defs.$definitionName" -Depth ($Depth + 1)
            }
        }
    }

    $script:__duoForgeStrictSchemaFailure = $null
    $script:__duoForgeStrictSchemaPropertyCount = 0
    try {
        Test-Node -Node $Schema -Path '$' -Depth 1 -Root
        $failure = $script:__duoForgeStrictSchemaFailure
    }
    finally {
        Remove-Variable -Name __duoForgeStrictSchemaFailure -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name __duoForgeStrictSchemaPropertyCount -Scope Script -ErrorAction SilentlyContinue
    }
    if ($null -ne $failure) {
        $exception = New-DuoForgeException -Code 'DF-PROVIDER-SCHEMA-STRICT' -Message '공급자 구조화 출력 스키마가 엄격 호환 계약을 충족하지 않습니다.'
        $exception.Data['DuoForgeValidationPath'] = [string]$failure
        throw $exception
    }
    return $true
}

function Assert-DuoForgeThinContractEquivalenceInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Definition)

    $schema = New-DuoForgeThinProviderSchemaInternal -Definition $Definition
    $kind = [string]$Definition.primary.kind
    $valid = [string]$schema.type -eq 'object' -and [bool]$schema.properties.primary.additionalProperties -eq $false
    $valid = $valid -and [bool](Assert-DuoForgeProviderSchemaStrictSubsetInternal -Schema $schema)
    $valid = $valid -and 'metadata' -in @($schema.required)
    $valid = $valid -and [bool]$schema.properties.metadata.additionalProperties -eq $false
    $valid = $valid -and ((@($Definition.metadata.fields.Keys | Sort-Object) -join ',') -ceq (@($schema.properties.metadata.required | Sort-Object) -join ','))
    if ($kind -eq 'validation') {
        $valid = $valid -and 'approved' -in @($schema.properties.primary.required) -and [string]$schema.properties.primary.properties.approved.type -eq 'boolean'
    }
    else {
        $count = [int]$Definition.primary.outputDocumentCount
        $documents = $schema.properties.primary.properties.documents
        $valid = $valid -and 'documents' -in @($schema.properties.primary.required) -and [string]$documents.type -eq 'array' -and [string]$documents.items.type -eq 'string'
    }
    if (-not $valid) { throw (New-DuoForgeException -Code 'DF-PROJECT-CONTRACT' -Message '얇은 단계의 공급자 스키마와 런타임 계약이 동등하지 않습니다.') }
    return $true
}

function New-DuoForgeThinValidationFailureInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Path
    )

    return [ordered]@{ code = $Code; path = $Path; count = 1; expected = @() }
}

function Test-DuoForgeJsonIntegerInternal {
    [CmdletBinding()]
    param($Value)

    return $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or `
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]
}

function Test-DuoForgeThinProviderPayloadInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Payload,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Definition
    )

    $primaryFailures = [System.Collections.Generic.List[object]]::new()
    $quarantined = [System.Collections.Generic.List[object]]::new()
    $sanitizedFindings = [System.Collections.Generic.List[object]]::new()
    $sanitizedQuestions = [System.Collections.Generic.List[object]]::new()
    $summary = ''

    $primary = Get-DuoForgeObjectValue -Object $Payload -Name 'primary'
    if ($Payload -isnot [System.Collections.IDictionary] -or $primary -isnot [System.Collections.IDictionary]) {
        $primaryFailures.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-REQUIRED' -Path 'primary'))
    }
    elseif ([string]$Definition.primary.kind -eq 'validation') {
        if ((@($primary.Keys | ForEach-Object { [string]$_ } | Sort-Object) -join ',') -cne 'approved') {
            $primaryFailures.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-CONTRACT-MISMATCH' -Path 'primary'))
        }
        elseif ((Get-DuoForgeObjectValue -Object $primary -Name 'approved') -isnot [bool]) {
            $primaryFailures.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-TYPE' -Path 'primary.approved'))
        }
    }
    else {
        $documents = $null
        if ((@($primary.Keys | ForEach-Object { [string]$_ } | Sort-Object) -join ',') -cne 'documents') {
            $primaryFailures.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-CONTRACT-MISMATCH' -Path 'primary'))
        }
        elseif ($primary.Contains('documents')) { $documents = $primary['documents'] }
        if ($primaryFailures.Count -eq 0 -and ($null -eq $documents -or $documents -is [string] -or $documents -isnot [System.Collections.IEnumerable])) {
            $primaryFailures.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-TYPE' -Path 'primary.documents'))
        }
        elseif ($primaryFailures.Count -eq 0) {
            $documentArray = @($documents)
            if ($documentArray.Count -ne [int]$Definition.primary.outputDocumentCount) {
                $primaryFailures.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-COUNT' -Path 'primary.documents'))
            }
            for ($index = 0; $index -lt $documentArray.Count; $index++) {
                if ($documentArray[$index] -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$documentArray[$index])) {
                    $primaryFailures.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-NONEMPTY' -Path "primary.documents[$index]"))
                }
            }
        }
    }

    $metadata = Get-DuoForgeObjectValue -Object $Payload -Name 'metadata'
    if ($null -ne $metadata -and $metadata -isnot [System.Collections.IDictionary]) {
        $quarantined.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-TYPE' -Path 'metadata'))
        $metadata = $null
    }
    if ($metadata -is [System.Collections.IDictionary]) {
        $metadataFieldNames = @($Definition.metadata.fields.Keys | ForEach-Object { [string]$_ })
        foreach ($metadataName in @($metadata.Keys | ForEach-Object { [string]$_ })) {
            if ($metadataName -notin $metadataFieldNames) {
                $quarantined.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "metadata.$metadataName"))
            }
        }
        foreach ($metadataName in $metadataFieldNames) {
            if (-not $metadata.Contains($metadataName)) {
                $quarantined.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-REQUIRED' -Path "metadata.$metadataName"))
            }
        }
        $summaryValue = Get-DuoForgeObjectValue -Object $metadata -Name 'summary' -Default ''
        if ($summaryValue -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$summaryValue)) { $summary = [string]$summaryValue }
        elseif ($metadata.Contains('summary') -and $null -ne $summaryValue) { $quarantined.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-NONEMPTY' -Path 'metadata.summary')) }

        $findings = @(Get-DuoForgeObjectValue -Object $metadata -Name 'findings' -Default @())
        for ($index = 0; $index -lt $findings.Count; $index++) {
            $finding = $findings[$index]
            $valid = $finding -is [System.Collections.IDictionary]
            $severity = [string](Get-DuoForgeObjectValue -Object $finding -Name 'severity' -Default '')
            $category = [string](Get-DuoForgeObjectValue -Object $finding -Name 'category' -Default '')
            $claim = [string](Get-DuoForgeObjectValue -Object $finding -Name 'claim' -Default '')
            $proposal = [string](Get-DuoForgeObjectValue -Object $finding -Name 'proposal' -Default '')
            $requiresUser = Get-DuoForgeObjectValue -Object $finding -Name 'requiresUser'
            $blockingProposal = Get-DuoForgeObjectValue -Object $finding -Name 'blockingProposal'
            $documentIndexValue = Get-DuoForgeObjectValue -Object $finding -Name 'documentIndex'
            $findingKeys = if ($valid) { @($finding.Keys | ForEach-Object { [string]$_ } | Sort-Object) } else { @() }
            $requiredFindingKeys = @($Definition.metadata.fields.findings.item.required | Sort-Object)
            $valid = $valid -and (($findingKeys -join ',') -ceq ($requiredFindingKeys -join ','))
            $valid = $valid -and (Test-DuoForgeJsonIntegerInternal -Value $documentIndexValue)
            $documentIndex = if (Test-DuoForgeJsonIntegerInternal -Value $documentIndexValue) { [int64]$documentIndexValue } else { -1 }
            $maximumDocumentIndex = [Math]::Max(0, [int]$Definition.primary.outputDocumentCount - 1)
            if (-not $valid -or $documentIndex -lt 0 -or $documentIndex -gt $maximumDocumentIndex -or $severity -notin @($Definition.metadata.fields.findings.item.severity) -or [string]::IsNullOrWhiteSpace($category) -or [string]::IsNullOrWhiteSpace($claim) -or [string]::IsNullOrWhiteSpace($proposal) -or $requiresUser -isnot [bool] -or $blockingProposal -isnot [bool]) {
                $quarantined.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "metadata.findings[$index]"))
                continue
            }
            $sanitizedFindings.Add([ordered]@{ sourceIndex = $index; category = $category; severity = $severity; claim = $claim; proposal = $proposal; requiresUser = [bool]$requiresUser; blockingProposal = [bool]$blockingProposal; documentIndex = [int]$documentIndex })
        }

        $questions = @(Get-DuoForgeObjectValue -Object $metadata -Name 'openQuestions' -Default @())
        for ($questionIndex = 0; $questionIndex -lt $questions.Count; $questionIndex++) {
            $question = $questions[$questionIndex]
            $basePath = "metadata.openQuestions[$questionIndex]"
            if ($question -isnot [System.Collections.IDictionary]) {
                $quarantined.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-TYPE' -Path $basePath))
                continue
            }
            $questionKeys = @($question.Keys | ForEach-Object { [string]$_ } | Sort-Object)
            $requiredQuestionKeys = @($Definition.metadata.fields.openQuestions.item.required | Sort-Object)
            $title = [string](Get-DuoForgeObjectValue -Object $question -Name 'title' -Default '')
            $questionText = [string](Get-DuoForgeObjectValue -Object $question -Name 'question' -Default '')
            $options = @(Get-DuoForgeObjectValue -Object $question -Name 'options' -Default @())
            $recommended = [string](Get-DuoForgeObjectValue -Object $question -Name 'recommendedOption' -Default '')
            $failurePath = ''
            if (($questionKeys -join ',') -cne ($requiredQuestionKeys -join ',')) { $failurePath = $basePath }
            elseif ([string]::IsNullOrWhiteSpace($title)) { $failurePath = "$basePath.title" }
            elseif ([string]::IsNullOrWhiteSpace($questionText)) { $failurePath = "$basePath.question" }
            elseif ($options.Count -lt [int]$Definition.metadata.fields.openQuestions.item.minimumOptions -or $options.Count -gt [int]$Definition.metadata.fields.openQuestions.item.maximumOptions) { $failurePath = "$basePath.options" }
            else {
                $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                for ($optionIndex = 0; $optionIndex -lt $options.Count; $optionIndex++) {
                    $option = [string]$options[$optionIndex]
                    if ($options[$optionIndex] -isnot [string] -or [string]::IsNullOrWhiteSpace($option) -or (Test-DuoForgeQuestionOptionMetadataInternal -Option $option) -or -not $seen.Add($option.Trim())) {
                        $failurePath = "$basePath.options[$optionIndex]"
                        break
                    }
                }
            }
            if ([string]::IsNullOrWhiteSpace($failurePath) -and -not (Test-DuoForgeQuestionRecommendationInternal -RecommendedOption $recommended -Options $options)) {
                $failurePath = "$basePath.recommendedOption"
            }
            $findingIndexValue = Get-DuoForgeObjectValue -Object $question -Name 'findingIndex'
            $findingIndex = if (Test-DuoForgeJsonIntegerInternal -Value $findingIndexValue) { [int64]$findingIndexValue } else { -1 }
            if ([string]::IsNullOrWhiteSpace($failurePath) -and @($sanitizedFindings | Where-Object sourceIndex -eq $findingIndex).Count -ne 1) {
                $failurePath = "$basePath.findingIndex"
            }
            if (-not [string]::IsNullOrWhiteSpace($failurePath)) {
                $quarantined.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-CONTRACT-MISMATCH' -Path $failurePath))
                continue
            }
            $sanitizedQuestions.Add([ordered]@{ findingIndex = $findingIndex; title = $title; question = $questionText; options = @($options); recommendedOption = $recommended })
        }
    }

    return [ordered]@{
        valid = $primaryFailures.Count -eq 0
        primary = [ordered]@{ valid = $primaryFailures.Count -eq 0; failures = @($primaryFailures) }
        metadata = [ordered]@{
            valid = $quarantined.Count -eq 0
            summary = $summary
            findings = @($sanitizedFindings)
            openQuestions = @($sanitizedQuestions)
            quarantined = @($quarantined)
        }
        retryWholeCall = $primaryFailures.Count -gt 0
    }
}

function Complete-DuoForgeThinStageResultInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ProviderPayload,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Step,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Definition
    )

    $validation = Test-DuoForgeThinProviderPayloadInternal -Payload $ProviderPayload -Definition $Definition
    if (-not [bool]$validation.primary.valid) {
        $exception = New-DuoForgeException -Code 'DF-STAGE-SCHEMA' -Message '단계의 주 결과 계약 검증에 실패했습니다.'
        $exception.Data['DuoForgeValidationFailures'] = @($validation.primary.failures)
        throw $exception
    }
    $primary = Get-DuoForgeObjectValue -Object $ProviderPayload -Name 'primary'
    $outputIds = @(Get-DuoForgeObjectValue -Object $Step -Name 'outputDocumentIds' -Default @())
    $documents = @()
    if ($primary -is [System.Collections.IDictionary] -and $primary.Contains('documents')) { $documents = @($primary['documents']) }
    $documentOutputs = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $documents.Count; $index++) {
        $documentOutputs.Add([ordered]@{ documentId = [string]$outputIds[$index]; content = [string]$documents[$index] })
    }
    $provider = [string]$Step.provider
    $stage = [string]$Step.stage
    $round = [int]$Step.round
    $generation = [Math]::Max(1, [int](Get-DuoForgeObjectValue -Object $Step -Name 'inputGeneration' -Default 1))
    $issues = [System.Collections.Generic.List[object]]::new()
    $issueKeyBySourceIndex = @{}
    $ordinal = 0
    foreach ($finding in @($validation.metadata.findings)) {
        $ordinal++
        $issueKey = 'LOCAL-R{0:D2}-{1}-{2}-G{3:D2}-{4:D3}' -f $round, $provider.ToUpperInvariant(), $stage.ToUpperInvariant(), $generation, $ordinal
        $documentIndex = [int](Get-DuoForgeObjectValue -Object $finding -Name 'documentIndex' -Default 0)
        if ($documentIndex -lt 0 -or $documentIndex -ge $outputIds.Count) { $documentIndex = 0 }
        $targetDocumentId = if ($outputIds.Count -gt 0) { [string]$outputIds[$documentIndex] } else { 'merged' }
        $issues.Add([ordered]@{
            issueKey = $issueKey
            targetDocumentId = $targetDocumentId
            category = [string]$finding.category
            severity = [string]$finding.severity
            claim = [string]$finding.claim
            evidence = @()
            proposal = [string]$finding.proposal
            requiresUser = [bool]$finding.requiresUser
            blockingProposal = [bool]$finding.blockingProposal
        })
        $issueKeyBySourceIndex[[int]$finding.sourceIndex] = $issueKey
    }
    $openQuestions = [System.Collections.Generic.List[object]]::new()
    foreach ($question in @($validation.metadata.openQuestions)) {
        $findingIndex = [int]$question.findingIndex
        if (-not $issueKeyBySourceIndex.ContainsKey($findingIndex)) { continue }
        $openQuestions.Add([ordered]@{
            issueKey = [string]$issueKeyBySourceIndex[$findingIndex]
            title = [string]$question.title
            question = [string]$question.question
            options = @($question.options)
            recommendedOption = [string]$question.recommendedOption
        })
    }
    return [ordered]@{
        schemaVersion = 3
        stage = $stage
        provider = $provider
        performedBy = [string](Get-DuoForgeObjectValue -Object $Step -Name 'performedBy' -Default $provider)
        round = $round
        sourceDocumentIds = @(Get-DuoForgeObjectValue -Object $Step -Name 'sourceDocumentIds' -Default @())
        documentOutputs = @($documentOutputs)
        summary = if ([string]::IsNullOrWhiteSpace([string]$validation.metadata.summary)) { '부가 메타데이터 없음' } else { [string]$validation.metadata.summary }
        issues = @($issues)
        issueResponses = @()
        adoptions = @()
        openQuestions = @($openQuestions)
        finalApproved = if ([string]$Definition.primary.kind -eq 'validation') { [bool]$primary.approved } else { $null }
        metadataWarnings = @($validation.metadata.quarantined)
    }
}

function Test-DuoForgeThinFinalRevisionRequiredInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$StoredValidationResult)

    return @((Get-DuoForgeObjectValue -Object $StoredValidationResult -Name 'issues' -Default @()) | Where-Object {
        [string]$_.severity -eq 'critical' -or ([string]$_.severity -eq 'major' -and [bool]$_.blockingProposal)
    }).Count -gt 0
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

function Test-DuoForgeStoredStageArtifactWrapperInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Wrapper,
        [Parameter(Mandatory)]$Step,
        [switch]$ThrowOnError
    )

    $failures = [System.Collections.Generic.List[object]]::new()
    $stored = if ($Wrapper -is [System.Collections.IDictionary]) { $Wrapper } else { ConvertTo-DuoForgeHashtable -InputObject $Wrapper }
    if ($stored -isnot [System.Collections.IDictionary]) {
        $failures.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-TYPE' -Path '$'))
    }
    else {
        $expectedKeys = @('provider', 'result', 'round', 'schemaVersion', 'stage', 'stepKey')
        if ((@($stored.Keys | ForEach-Object { [string]$_ } | Sort-Object) -join ',') -cne ($expectedKeys -join ',')) {
            $failures.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-CONTRACT-MISMATCH' -Path '$'))
        }
        foreach ($field in @('stepKey', 'provider', 'stage')) {
            if ([string](Get-DuoForgeObjectValue -Object $stored -Name $field -Default '') -cne [string](Get-DuoForgeObjectValue -Object $Step -Name $field -Default '')) {
                $failures.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-CONTRACT-MISMATCH' -Path $field))
            }
        }
        $storedSchema = Get-DuoForgeObjectValue -Object $stored -Name 'schemaVersion'
        if (-not (Test-DuoForgeJsonIntegerInternal -Value $storedSchema) -or [int64]$storedSchema -ne 1) {
            $failures.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-CONTRACT-MISMATCH' -Path 'schemaVersion'))
        }
        $storedRound = Get-DuoForgeObjectValue -Object $stored -Name 'round'
        if (-not (Test-DuoForgeJsonIntegerInternal -Value $storedRound) -or [int64]$storedRound -ne [int64](Get-DuoForgeObjectValue -Object $Step -Name 'round' -Default 0)) {
            $failures.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-CONTRACT-MISMATCH' -Path 'round'))
        }
        if ((Get-DuoForgeObjectValue -Object $stored -Name 'result') -isnot [System.Collections.IDictionary]) {
            $failures.Add((New-DuoForgeThinValidationFailureInternal -Code 'DF-VAL-TYPE' -Path 'result'))
        }
    }

    $validation = [ordered]@{ valid = $failures.Count -eq 0; failures = @($failures) }
    if ($ThrowOnError -and -not [bool]$validation.valid) {
        $exception = New-DuoForgeException -Code 'DF-STAGE-SCHEMA' -Message '저장된 단계 산출물 포장 계약이 일치하지 않습니다.'
        $exception.Data['DuoForgeValidationFailures'] = @($failures)
        throw $exception
    }
    return $validation
}

function Test-DuoForgeThinStoredStageResultInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)]$Step,
        [switch]$ThrowOnError
    )

    $failures = [System.Collections.Generic.List[object]]::new()
    $stored = if ($Result -is [System.Collections.IDictionary]) { $Result } else { ConvertTo-DuoForgeHashtable -InputObject $Result }
    $stepContract = if ($Step -is [System.Collections.IDictionary]) { $Step } else { ConvertTo-DuoForgeHashtable -InputObject $Step }
    $addFailure = {
        param([string]$Code, [string]$Path)
        $failures.Add((New-DuoForgeThinValidationFailureInternal -Code $Code -Path $Path))
    }

    if ($stored -isnot [System.Collections.IDictionary]) {
        & $addFailure 'DF-VAL-TYPE' '$'
    }
    else {
        $expectedKeys = @(
            'adoptions', 'documentOutputs', 'finalApproved', 'issueResponses', 'issues', 'metadataWarnings',
            'openQuestions', 'performedBy', 'provider', 'round', 'schemaVersion', 'sourceDocumentIds', 'stage', 'summary'
        ) | Sort-Object
        if ((@($stored.Keys | ForEach-Object { [string]$_ } | Sort-Object) -join ',') -cne ($expectedKeys -join ',')) {
            & $addFailure 'DF-VAL-CONTRACT-MISMATCH' '$'
        }

        $schemaVersion = Get-DuoForgeObjectValue -Object $stored -Name 'schemaVersion'
        if (-not (Test-DuoForgeJsonIntegerInternal -Value $schemaVersion) -or [int64]$schemaVersion -ne 3) { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'schemaVersion' }
        foreach ($field in @('stage', 'provider')) {
            if ([string](Get-DuoForgeObjectValue -Object $stored -Name $field -Default '') -cne [string](Get-DuoForgeObjectValue -Object $stepContract -Name $field -Default '')) {
                & $addFailure 'DF-VAL-CONTRACT-MISMATCH' $field
            }
        }
        $expectedPerformedBy = [string](Get-DuoForgeObjectValue -Object $stepContract -Name 'performedBy' -Default (Get-DuoForgeObjectValue -Object $stepContract -Name 'provider' -Default ''))
        if ([string](Get-DuoForgeObjectValue -Object $stored -Name 'performedBy' -Default '') -cne $expectedPerformedBy) { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'performedBy' }
        $storedRound = Get-DuoForgeObjectValue -Object $stored -Name 'round'
        if (-not (Test-DuoForgeJsonIntegerInternal -Value $storedRound) -or [int64]$storedRound -ne [int64](Get-DuoForgeObjectValue -Object $stepContract -Name 'round' -Default 0)) { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'round' }
        $sourceDocumentIdsValid = $stored.Contains('sourceDocumentIds') -and
            $null -ne $stored['sourceDocumentIds'] -and $stored['sourceDocumentIds'] -isnot [string] -and $stored['sourceDocumentIds'] -is [System.Collections.IEnumerable] -and
            $stepContract -is [System.Collections.IDictionary] -and $stepContract.Contains('sourceDocumentIds') -and
            $null -ne $stepContract['sourceDocumentIds'] -and $stepContract['sourceDocumentIds'] -isnot [string] -and $stepContract['sourceDocumentIds'] -is [System.Collections.IEnumerable]
        if ($sourceDocumentIdsValid) {
            $actualSourceDocumentIds = @($stored['sourceDocumentIds'] | ForEach-Object { [string]$_ })
            $expectedSourceDocumentIds = @($stepContract['sourceDocumentIds'] | ForEach-Object { [string]$_ })
            $sourceDocumentIdsValid = $actualSourceDocumentIds.Count -eq $expectedSourceDocumentIds.Count
            for ($index = 0; $sourceDocumentIdsValid -and $index -lt $actualSourceDocumentIds.Count; $index++) {
                if ($actualSourceDocumentIds[$index] -cne $expectedSourceDocumentIds[$index]) { $sourceDocumentIdsValid = $false }
            }
        }
        if (-not $sourceDocumentIdsValid) { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'sourceDocumentIds' }

        $outputIds = @()
        if ($stepContract -is [System.Collections.IDictionary] -and $stepContract.Contains('outputDocumentIds')) {
            $outputIds = @($stepContract['outputDocumentIds'])
        }
        if (-not $stored.Contains('documentOutputs') -or $null -eq $stored['documentOutputs'] -or $stored['documentOutputs'] -is [string] -or $stored['documentOutputs'] -isnot [System.Collections.IEnumerable]) {
            & $addFailure 'DF-VAL-TYPE' 'documentOutputs'
        }
        else {
            $documentOutputs = @($stored['documentOutputs'])
            if ($documentOutputs.Count -ne $outputIds.Count) { & $addFailure 'DF-VAL-COUNT' 'documentOutputs' }
            for ($index = 0; $index -lt $documentOutputs.Count; $index++) {
                $document = $documentOutputs[$index]
                $path = "documentOutputs[$index]"
                if ($document -isnot [System.Collections.IDictionary]) { & $addFailure 'DF-VAL-TYPE' $path; continue }
                if ((@($document.Keys | ForEach-Object { [string]$_ } | Sort-Object) -join ',') -cne 'content,documentId') { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' $path }
                if ($index -ge $outputIds.Count -or [string](Get-DuoForgeObjectValue -Object $document -Name 'documentId' -Default '') -cne [string]$outputIds[$index]) { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' "$path.documentId" }
                $content = Get-DuoForgeObjectValue -Object $document -Name 'content'
                if ($content -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$content)) { & $addFailure 'DF-VAL-NONEMPTY' "$path.content" }
            }
        }

        $summary = Get-DuoForgeObjectValue -Object $stored -Name 'summary'
        if ($summary -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$summary)) { & $addFailure 'DF-VAL-NONEMPTY' 'summary' }
        foreach ($field in @('issues', 'issueResponses', 'adoptions', 'openQuestions', 'metadataWarnings')) {
            if (-not $stored.Contains($field) -or $null -eq $stored[$field] -or $stored[$field] -is [string] -or $stored[$field] -isnot [System.Collections.IEnumerable]) { & $addFailure 'DF-VAL-TYPE' $field }
        }
        if ($stored.Contains('issueResponses') -and @($stored['issueResponses']).Count -ne 0) { & $addFailure 'DF-VAL-COUNT' 'issueResponses' }
        if ($stored.Contains('adoptions') -and @($stored['adoptions']).Count -ne 0) { & $addFailure 'DF-VAL-COUNT' 'adoptions' }

        $issueKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $generation = [Math]::Max(1, [int](Get-DuoForgeObjectValue -Object $stepContract -Name 'inputGeneration' -Default 1))
        $issuePrefix = 'LOCAL-R{0:D2}-{1}-{2}-G{3:D2}-' -f [int](Get-DuoForgeObjectValue -Object $stepContract -Name 'round' -Default 0), ([string](Get-DuoForgeObjectValue -Object $stepContract -Name 'provider' -Default '')).ToUpperInvariant(), ([string](Get-DuoForgeObjectValue -Object $stepContract -Name 'stage' -Default '')).ToUpperInvariant(), $generation
        $allowedIssueTargets = if ($outputIds.Count -gt 0) { @($outputIds | ForEach-Object { [string]$_ }) } else { @('merged') }
        foreach ($issue in @(Get-DuoForgeObjectValue -Object $stored -Name 'issues' -Default @())) {
            if ($issue -isnot [System.Collections.IDictionary]) { & $addFailure 'DF-VAL-TYPE' 'issues'; continue }
            if ((@($issue.Keys | ForEach-Object { [string]$_ } | Sort-Object) -join ',') -cne 'blockingProposal,category,claim,evidence,issueKey,proposal,requiresUser,severity,targetDocumentId') { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'issues' }
            $issueKey = [string](Get-DuoForgeObjectValue -Object $issue -Name 'issueKey' -Default '')
            if ($issueKey -notmatch ('^' + [regex]::Escape($issuePrefix) + '\d{3,}$') -or -not $issueKeys.Add($issueKey)) { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'issues.issueKey' }
            if ([string](Get-DuoForgeObjectValue -Object $issue -Name 'severity' -Default '') -notin @('critical', 'major', 'minor')) { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'issues.severity' }
            foreach ($field in @('targetDocumentId', 'category', 'claim', 'proposal')) {
                $value = Get-DuoForgeObjectValue -Object $issue -Name $field
                if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value)) { & $addFailure 'DF-VAL-NONEMPTY' "issues.$field" }
            }
            if ([string](Get-DuoForgeObjectValue -Object $issue -Name 'targetDocumentId' -Default '') -notin $allowedIssueTargets) { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'issues.targetDocumentId' }
            foreach ($field in @('requiresUser', 'blockingProposal')) {
                if ((Get-DuoForgeObjectValue -Object $issue -Name $field) -isnot [bool]) { & $addFailure 'DF-VAL-TYPE' "issues.$field" }
            }
            if (-not $issue.Contains('evidence') -or $null -eq $issue['evidence'] -or $issue['evidence'] -is [string] -or $issue['evidence'] -isnot [System.Collections.IEnumerable] -or @($issue['evidence']).Count -ne 0) { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'issues.evidence' }
        }

        foreach ($question in @(Get-DuoForgeObjectValue -Object $stored -Name 'openQuestions' -Default @())) {
            if ($question -isnot [System.Collections.IDictionary]) { & $addFailure 'DF-VAL-TYPE' 'openQuestions'; continue }
            if ((@($question.Keys | ForEach-Object { [string]$_ } | Sort-Object) -join ',') -cne 'issueKey,options,question,recommendedOption,title') { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'openQuestions' }
            $issueKey = [string](Get-DuoForgeObjectValue -Object $question -Name 'issueKey' -Default '')
            $options = @(Get-DuoForgeObjectValue -Object $question -Name 'options' -Default @())
            if (-not $issueKeys.Contains($issueKey)) { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'openQuestions.issueKey' }
            foreach ($field in @('title', 'question')) {
                $value = Get-DuoForgeObjectValue -Object $question -Name $field
                if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value)) { & $addFailure 'DF-VAL-NONEMPTY' "openQuestions.$field" }
            }
            if ($options.Count -lt 2 -or $options.Count -gt 3 -or @(Get-DuoForgeQuestionOptionsForInteractionInternal -Options $options).Count -ne $options.Count) { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'openQuestions.options' }
            if (-not (Test-DuoForgeQuestionRecommendationInternal -RecommendedOption ([string](Get-DuoForgeObjectValue -Object $question -Name 'recommendedOption' -Default '')) -Options $options)) { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'openQuestions.recommendedOption' }
        }

        $finalApproved = Get-DuoForgeObjectValue -Object $stored -Name 'finalApproved'
        if ([string](Get-DuoForgeObjectValue -Object $stepContract -Name 'stage' -Default '') -eq 'final-validation') {
            if ($finalApproved -isnot [bool]) { & $addFailure 'DF-VAL-TYPE' 'finalApproved' }
        }
        elseif ($null -ne $finalApproved) { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'finalApproved' }

        foreach ($warning in @(Get-DuoForgeObjectValue -Object $stored -Name 'metadataWarnings' -Default @())) {
            if ($warning -isnot [System.Collections.IDictionary]) { & $addFailure 'DF-VAL-TYPE' 'metadataWarnings'; continue }
            if ((@($warning.Keys | ForEach-Object { [string]$_ } | Sort-Object) -join ',') -cne 'code,count,expected,path') { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'metadataWarnings' }
            foreach ($field in @('code', 'path')) {
                if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $warning -Name $field -Default ''))) { & $addFailure 'DF-VAL-NONEMPTY' "metadataWarnings.$field" }
            }
            $count = Get-DuoForgeObjectValue -Object $warning -Name 'count'
            if (-not (Test-DuoForgeJsonIntegerInternal -Value $count) -or [int64]$count -lt 1) { & $addFailure 'DF-VAL-CONTRACT-MISMATCH' 'metadataWarnings.count' }
            if (-not $warning.Contains('expected') -or $null -eq $warning['expected'] -or $warning['expected'] -is [string] -or $warning['expected'] -isnot [System.Collections.IEnumerable]) { & $addFailure 'DF-VAL-TYPE' 'metadataWarnings.expected' }
        }
    }

    $validation = [ordered]@{ valid = $failures.Count -eq 0; failures = @($failures) }
    if ($ThrowOnError -and -not [bool]$validation.valid) {
        $exception = New-DuoForgeException -Code 'DF-STAGE-SCHEMA' -Message '저장된 얇은 단계 결과 계약이 일치하지 않습니다.'
        $exception.Data['DuoForgeValidationFailures'] = @($failures)
        throw $exception
    }
    return $validation
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
        issueResponsesAllowed = $Stage -in @('author-response', 'review-response', 'owner-response', 'final-validation', 'document-validation')
        adoptionsAllowed = $Stage -in @('synthesis', 'document-revision')
    }
}

function Get-DuoForgeStageResultContractProfileInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Stage,
        [AllowNull()][string]$TargetDocumentId,
        [AllowEmptyCollection()][string[]]$SourceDocumentIds = @()
    )

    $documentStages = @('independent-draft', 'independent-merge-draft', 'synthesis', 'owned-document-revision', 'document-revision')
    $validationStages = @('final-validation', 'document-validation')
    $profileName = if ($Stage -eq 'context-batch-analysis') { 'context-batch' }
        elseif ($Stage -in @('independent-draft', 'independent-merge-draft')) { 'draft' }
        elseif ($Stage -in @('cross-review', 'joint-document-review', 'document-review')) { 'review' }
        elseif ($Stage -in @('author-response', 'review-response', 'owner-response')) { 'response' }
        elseif ($Stage -in @('synthesis', 'owned-document-revision', 'document-revision')) { 'synthesis-revision' }
        elseif ($Stage -in $validationStages) { 'validation' }
        else { 'unknown' }
    return [ordered]@{
        profileName = $profileName
        documentRequired = $Stage -in $documentStages
        finalApprovedRequired = $Stage -in $validationStages
        contextEvidenceRequired = $Stage -eq 'context-batch-analysis'
        lineage = Get-DuoForgeStageLineagePolicyInternal -Stage $Stage -TargetDocumentId $TargetDocumentId -SourceDocumentIds $SourceDocumentIds
    }
}

function Get-DuoForgeStageIssueTargetTokenInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Step)

    $target = [string](Get-DuoForgeObjectValue -Object $Step -Name 'targetDocumentId' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($target)) { return $target.ToUpperInvariant() }
    $sources = @(Get-DuoForgeObjectValue -Object $Step -Name 'sourceDocumentIds' -Default @())
    if ('A' -in $sources -and 'B' -in $sources) { return 'AB' }
    if ('A' -in $sources) { return 'A' }
    if ('B' -in $sources) { return 'B' }
    if ('brief' -in $sources) { return 'MERGED' }
    return 'NONE'
}

function Get-DuoForgeExpectedNewIssueKeyPrefixForStepInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Step)

    $contextBatchId = [string](Get-DuoForgeObjectValue -Object $Step -Name 'contextBatchId' -Default '')
    $batchToken = if ([string]::IsNullOrWhiteSpace($contextBatchId)) { '' } else { '-' + (($contextBatchId.ToUpperInvariant() -replace '[^A-Z0-9]+', '-').Trim('-')) }
    $inputGeneration = [Math]::Max(1, [int](Get-DuoForgeObjectValue -Object $Step -Name 'inputGeneration' -Default 1))
    $targetToken = Get-DuoForgeStageIssueTargetTokenInternal -Step $Step
    return '{0}-R{1:D2}-{2}-{3}{4}-G{5:D2}-' -f $Step.provider.ToUpperInvariant(), [int]$Step.round, $Step.stage.ToUpperInvariant(), $targetToken, $batchToken, $inputGeneration
}

function Test-DuoForgeStageIssueKeyPrefixContractInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Step
    )

    if ((Get-DuoForgeWorkflowVersionInternal -Manifest $Manifest) -ne 'workflow-v2') { return $false }
    if ([string](Get-DuoForgeObjectValue -Object $Manifest -Name 'promptTemplateVersion' -Default '') -notin @('duoforge-stage-v4', 'duoforge-stage-v5')) { return $false }
    if ([string]$Step.stage -eq 'context-batch-analysis') {
        $storedContextPlan = Get-DuoForgeObjectValue -Object $Manifest -Name 'contextPlan'
        if ($null -ne $storedContextPlan -and [int](Get-DuoForgeObjectValue -Object $storedContextPlan -Name 'schemaVersion' -Default 1) -lt 2) { return $false }
    }
    return $true
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

function Add-DuoForgeStageStructuralFailureInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][System.Collections.Generic.List[string]]$Errors,
        [AllowEmptyCollection()][Parameter(Mandatory)][System.Collections.Generic.List[object]]$Failures,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Path,
        [int]$Count = 1,
        [AllowEmptyCollection()][string[]]$Expected = @()
    )

    $Errors.Add($Message)
    $Failures.Add((New-DuoForgeSafeValidationFailureInternal -Code $Code -Path $Path -Count $Count -Expected $Expected))
}

function Test-DuoForgeSafeStageValidationPathInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Path)

    if ($Path -in @('$', 'schemaVersion', 'stage', 'provider', 'performedBy', 'targetDocumentId', 'sourceDocumentIds', 'summary', 'document', 'issues', 'issueResponses', 'adoptions', 'openQuestions', 'finalApproved')) { return $true }
    $patterns = @(
        '^issues\[\d+\]\.(?:issueKey|targetDocumentId|category|severity|claim|evidence|proposal|requiresUser|blockingProposal)$',
        '^issues\[\d+\]\.evidence\[\d+\]\.(?:sourceDocumentId|proposedByProvider|path|location|excerptHash)$',
        '^issueResponses\[\d+\]\.(?:issueKey|disposition|rationale|locations)$',
        '^issueResponses\[\d+\]\.locations\[\d+\]$',
        '^adoptions\[\d+\]\.(?:issueKey|sourceDocumentId|proposedByProvider|targetDocumentId|disposition|rationale|locations)$',
        '^adoptions\[\d+\]\.locations\[\d+\]$',
        '^openQuestions\[\d+\]\.(?:issueKey|title|question|options|recommendedOption|reasonNow|plainExplanation|codexOpinion|claudeOpinion|impactIfDeferred|estimatedCost|reversibility|confidence|safeDefault|experimentPossible)$',
        '^openQuestions\[\d+\]\.options\[\d+\]$'
    )
    return @($patterns | Where-Object { $Path -match $_ }).Count -gt 0
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
        [AllowEmptyString()][string]$ExpectedIssueKeyPrefix = '',
        [AllowEmptyString()][string]$ExpectedPerformedBy = '',
        [switch]$ThrowOnIssueReferenceIntegrityError,
        [switch]$ThrowOnError
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $referenceFailures = [System.Collections.Generic.List[object]]::new()
    $structuralFailures = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $DefinitionIssueTargets) { $DefinitionIssueTargets = $KnownIssueTargets }
    if ($null -eq $ReferenceIssueTargets) { $ReferenceIssueTargets = $KnownIssueTargets }
    $requiredProperties = @(
        'schemaVersion', 'stage', 'provider', 'summary', 'document', 'issues',
        'issueResponses', 'adoptions', 'openQuestions', 'finalApproved'
    )
    foreach ($name in $requiredProperties) {
        if ($Result -isnot [System.Collections.IDictionary] -or -not $Result.Contains($name)) {
            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "필수 속성이 없습니다: $name" -Code 'DF-VAL-REQUIRED' -Path $name
        }
    }

    if ($WorkflowVersion -eq 'workflow-v2') {
        foreach ($name in @('performedBy', 'targetDocumentId', 'sourceDocumentIds')) {
            if ($Result -isnot [System.Collections.IDictionary] -or -not $Result.Contains($name)) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "필수 속성이 없습니다: $name" -Code 'DF-VAL-REQUIRED' -Path $name
            }
        }
    }

    $contractProfile = if ($WorkflowVersion -eq 'workflow-v2') {
        Get-DuoForgeStageResultContractProfileInternal -Stage $ExpectedStage -TargetDocumentId $ExpectedTargetDocumentId -SourceDocumentIds $ExpectedSourceDocumentIds
    }
    else { $null }
    $lineagePolicy = if ($null -ne $contractProfile) { $contractProfile.lineage } else { $null }

    $expectedSchemaVersion = if ($WorkflowVersion -eq 'workflow-v2') { 2 } else { 1 }
    if ([int](Get-DuoForgeObjectValue -Object $Result -Name 'schemaVersion' -Default 0) -ne $expectedSchemaVersion) {
        Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "schemaVersion은 $expectedSchemaVersion 이어야 합니다." -Code 'DF-VAL-CONTRACT-MISMATCH' -Path 'schemaVersion'
    }
    if ([string](Get-DuoForgeObjectValue -Object $Result -Name 'stage') -cne $ExpectedStage) {
        Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "stage가 예상값과 다릅니다: $ExpectedStage" -Code 'DF-VAL-CONTRACT-MISMATCH' -Path 'stage'
    }
    if ([string](Get-DuoForgeObjectValue -Object $Result -Name 'provider') -cne $ExpectedProvider) {
        Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "provider가 예상값과 다릅니다: $ExpectedProvider" -Code 'DF-VAL-CONTRACT-MISMATCH' -Path 'provider' -Expected @($ExpectedProvider)
    }
    if ($WorkflowVersion -eq 'workflow-v2') {
        if ([string]::IsNullOrWhiteSpace($ExpectedPerformedBy)) { $ExpectedPerformedBy = $ExpectedProvider }
        if ([string](Get-DuoForgeObjectValue -Object $Result -Name 'performedBy') -cne $ExpectedPerformedBy) {
            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "performedBy가 예상값과 다릅니다: $ExpectedPerformedBy" -Code 'DF-VAL-CONTRACT-MISMATCH' -Path 'performedBy' -Expected @($ExpectedPerformedBy)
        }
        $actualTarget = Get-DuoForgeObjectValue -Object $Result -Name 'targetDocumentId'
        $expectedTarget = if ([string]::IsNullOrWhiteSpace($ExpectedTargetDocumentId)) { $null } else { $ExpectedTargetDocumentId }
        if (($null -eq $expectedTarget -and $null -ne $actualTarget) -or ($null -ne $expectedTarget -and [string]$actualTarget -cne [string]$expectedTarget)) {
            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "targetDocumentId가 예상값과 다릅니다: $expectedTarget" -Code 'DF-VAL-CONTRACT-MISMATCH' -Path 'targetDocumentId' -Expected @($expectedTarget)
        }
        $sourceIds = $null
        if ($Result -is [System.Collections.IDictionary] -and $Result.Contains('sourceDocumentIds')) {
            $sourceIds = $Result['sourceDocumentIds']
        }
        elseif ($null -ne $Result.PSObject.Properties['sourceDocumentIds']) {
            $sourceIds = $Result.PSObject.Properties['sourceDocumentIds'].Value
        }
        if ($null -eq $sourceIds -or $sourceIds -is [string] -or $sourceIds -isnot [System.Collections.IEnumerable]) {
            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'sourceDocumentIds 속성은 배열이어야 합니다.' -Code 'DF-VAL-TYPE' -Path 'sourceDocumentIds'
        }
        else {
            $sourceArray = @($sourceIds | ForEach-Object { [string]$_ })
            $actualSources = @($sourceArray | Sort-Object -Unique)
            $expectedSources = @($ExpectedSourceDocumentIds | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            if ($sourceArray.Count -ne $actualSources.Count) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'sourceDocumentIds에는 중복된 출처를 사용할 수 없습니다.' -Code 'DF-VAL-UNIQUE' -Path 'sourceDocumentIds'
            }
            if (($actualSources -join ',') -cne ($expectedSources -join ',')) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "sourceDocumentIds가 예상값과 다릅니다: $($expectedSources -join ',')" -Code 'DF-VAL-CONTRACT-MISMATCH' -Path 'sourceDocumentIds' -Expected @($expectedSources)
            }
        }
    }

    $documentRequired = if ($WorkflowVersion -eq 'workflow-v2') { [bool]$contractProfile.documentRequired } else { $ExpectedStage -in @('independent-draft', 'synthesis', 'owned-document-revision') }
    $documentValue = Get-DuoForgeObjectValue -Object $Result -Name 'document'
    if ($documentRequired -and [string]::IsNullOrWhiteSpace([string]$documentValue)) {
        Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "$ExpectedStage 단계에는 비어 있지 않은 document가 필요합니다." -Code 'DF-VAL-NONEMPTY' -Path 'document'
    }
    elseif ($WorkflowVersion -eq 'workflow-v2' -and -not $documentRequired -and $null -ne $documentValue) {
        Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "$ExpectedStage 단계의 document는 null이어야 합니다." -Code 'DF-VAL-CONTRACT-MISMATCH' -Path 'document'
    }
    $finalApprovedRequired = if ($WorkflowVersion -eq 'workflow-v2') { [bool]$contractProfile.finalApprovedRequired } else { $ExpectedStage -in @('final-validation') }
    $finalApprovedValue = Get-DuoForgeObjectValue -Object $Result -Name 'finalApproved'
    if ($finalApprovedRequired -and $finalApprovedValue -isnot [bool]) {
        Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "$ExpectedStage 단계에는 boolean finalApproved가 필요합니다." -Code 'DF-VAL-TYPE' -Path 'finalApproved'
    }
    elseif ($WorkflowVersion -eq 'workflow-v2' -and -not $finalApprovedRequired -and $null -ne $finalApprovedValue) {
        Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "$ExpectedStage 단계의 finalApproved는 null이어야 합니다." -Code 'DF-VAL-CONTRACT-MISMATCH' -Path 'finalApproved'
    }

    foreach ($collectionName in @('issues', 'issueResponses', 'adoptions', 'openQuestions')) {
        if ($Result -isnot [System.Collections.IDictionary] -or -not $Result.Contains($collectionName)) {
            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "$collectionName 속성은 배열이어야 합니다." -Code 'DF-VAL-TYPE' -Path $collectionName
            continue
        }
        $value = $Result[$collectionName]
        if ($null -eq $value -or $value -is [string] -or $value -isnot [System.Collections.IEnumerable]) {
            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "$collectionName 속성은 배열이어야 합니다." -Code 'DF-VAL-TYPE' -Path $collectionName
        }
    }

    if ($WorkflowVersion -eq 'workflow-v2' -and [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $Result -Name 'summary'))) {
        Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'summary 값이 비어 있습니다.' -Code 'DF-VAL-NONEMPTY' -Path 'summary'
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
            if ($WorkflowVersion -eq 'workflow-v2' -and -not [string]::IsNullOrWhiteSpace($ExpectedIssueKeyPrefix) -and $issueKey -notmatch ('^' + [regex]::Escape($ExpectedIssueKeyPrefix) + '\d{3,}$')) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'issues.issueKey가 현재 단계의 새 쟁점 접두사와 다릅니다.' -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "issues[$issueIndex].issueKey"
            }
        }
        $severity = [string](Get-DuoForgeObjectValue -Object $issue -Name 'severity')
        if ($severity -notin @('critical', 'major', 'minor')) {
            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'issue.severity 값이 잘못되었습니다.' -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "issues[$issueIndex].severity"
        }
        $issueTargetName = if ($WorkflowVersion -eq 'workflow-v2') { 'targetDocumentId' } else { 'target' }
        $requiredIssueStrings = @('issueKey', $issueTargetName, 'category', 'claim')
        if ($WorkflowVersion -eq 'workflow-v2') { $requiredIssueStrings += 'proposal' }
        foreach ($name in $requiredIssueStrings) {
            if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $issue -Name $name))) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "issue.$name 값이 비어 있습니다." -Code 'DF-VAL-NONEMPTY' -Path "issues[$issueIndex].$name"
            }
        }
        if ($WorkflowVersion -eq 'workflow-v2') {
            $issueTarget = [string](Get-DuoForgeObjectValue -Object $issue -Name 'targetDocumentId')
            if ($issueTarget -cnotin @('A', 'B', 'merged')) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'issue.targetDocumentId 값이 잘못되었습니다.' -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "issues[$issueIndex].targetDocumentId"
            }
            elseif ($issueTarget -cnotin @($lineagePolicy.issueTargetDocumentIds)) {
                $errors.Add('issue.targetDocumentId가 현재 단계의 허용 대상과 다릅니다.')
                $referenceFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-REF-TARGET-MISMATCH' -Path "issues[$issueIndex].targetDocumentId" -Expected @($lineagePolicy.issueTargetDocumentIds)))
            }
            $evidenceItems = @(Get-DuoForgeObjectValue -Object $issue -Name 'evidence' -Default @())
            if ($ExpectedStage -eq 'context-batch-analysis' -and $null -ne $ContextEvidenceContract -and $evidenceItems.Count -lt 1) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'schema 2 context-batch-analysis issue에는 CORE 근거가 하나 이상 필요합니다.' -Code 'DF-VAL-COUNT' -Path "issues[$issueIndex].evidence"
            }
            for ($evidenceIndex = 0; $evidenceIndex -lt $evidenceItems.Count; $evidenceIndex++) {
                $evidence = $evidenceItems[$evidenceIndex]
                foreach ($name in @('sourceDocumentId', 'proposedByProvider', 'path', 'location', 'excerptHash')) {
                    if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $evidence -Name $name))) {
                        Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "issue.evidence.$name 값이 비어 있습니다." -Code 'DF-VAL-NONEMPTY' -Path "issues[$issueIndex].evidence[$evidenceIndex].$name"
                    }
                }
                if ([string](Get-DuoForgeObjectValue -Object $evidence -Name 'sourceDocumentId') -cnotin @('brief', 'A', 'B', 'merged')) {
                    Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'issue.evidence.sourceDocumentId 값이 잘못되었습니다.' -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "issues[$issueIndex].evidence[$evidenceIndex].sourceDocumentId"
                }
                elseif ([string](Get-DuoForgeObjectValue -Object $evidence -Name 'sourceDocumentId') -cnotin @($lineagePolicy.evidenceSourceDocumentIds)) {
                    Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "issue.evidence.sourceDocumentId가 $ExpectedStage 단계의 허용 출처와 다릅니다." -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "issues[$issueIndex].evidence[$evidenceIndex].sourceDocumentId" -Expected @($lineagePolicy.evidenceSourceDocumentIds)
                }
                if ([string](Get-DuoForgeObjectValue -Object $evidence -Name 'proposedByProvider') -notin @('codex', 'claude')) {
                    Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'issue.evidence.proposedByProvider 값이 잘못되었습니다.' -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "issues[$issueIndex].evidence[$evidenceIndex].proposedByProvider"
                }
                elseif ($ExpectedStage -eq 'context-batch-analysis' -and $null -ne $ContextEvidenceContract -and [string](Get-DuoForgeObjectValue -Object $evidence -Name 'proposedByProvider') -cne $ExpectedProvider) {
                    Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'context-batch-analysis evidence.proposedByProvider가 실행 공급자와 다릅니다.' -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "issues[$issueIndex].evidence[$evidenceIndex].proposedByProvider" -Expected @($ExpectedProvider)
                }
                if ($ExpectedStage -eq 'context-batch-analysis' -and $null -ne $ContextEvidenceContract) {
                    foreach ($name in @('sourceDocumentId', 'path', 'location', 'excerptHash')) {
                        $actualEvidenceValue = [string](Get-DuoForgeObjectValue -Object $evidence -Name $name -Default '')
                        $expectedEvidenceValue = [string](Get-DuoForgeObjectValue -Object $ContextEvidenceContract -Name $name -Default '')
                        if ($actualEvidenceValue -cne $expectedEvidenceValue) {
                            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "context-batch-analysis evidence.$name 값이 CORE 근거 계약과 다릅니다." -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "issues[$issueIndex].evidence[$evidenceIndex].$name" -Expected $(if ($name -eq 'sourceDocumentId') { @($expectedEvidenceValue) } else { @() })
                        }
                    }
                }
            }
        }
        foreach ($name in @('requiresUser', 'blockingProposal')) {
            if ((Get-DuoForgeObjectValue -Object $issue -Name $name) -isnot [bool]) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "issue.$name 값은 boolean이어야 합니다." -Code 'DF-VAL-TYPE' -Path "issues[$issueIndex].$name"
            }
        }
    }

    $responseItems = if ($Result -is [System.Collections.IDictionary] -and $Result.Contains('issueResponses')) { $Result['issueResponses'] } else { @() }
    $responseStages = @('author-response', 'review-response', 'owner-response', 'final-validation', 'document-validation')
    if ($WorkflowVersion -eq 'workflow-v2' -and $ExpectedStage -notin $responseStages -and @($responseItems).Count -gt 0) {
        $errors.Add("$ExpectedStage 단계에는 issueResponses를 기록할 수 없습니다.")
        $structuralFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-VAL-ARRAY-NOT-ALLOWED' -Path 'issueResponses'))
    }
    if ($ExpectedStage -in $responseStages) {
        $responseArray = @($responseItems)
        for ($responseIndex = 0; $responseIndex -lt $responseArray.Count; $responseIndex++) {
            $response = $responseArray[$responseIndex]
            $disposition = [string](Get-DuoForgeObjectValue -Object $response -Name 'disposition')
            if ($disposition -notin @('ACCEPTED', 'PARTIALLY_ACCEPTED', 'REJECTED', 'DEFERRED', 'NEEDS_EVIDENCE', 'ASK_USER')) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'issueResponses.disposition 값이 잘못되었습니다.' -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "issueResponses[$responseIndex].disposition"
            }
            if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $response -Name 'issueKey'))) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'issueResponses.issueKey 값이 비어 있습니다.' -Code 'DF-VAL-NONEMPTY' -Path "issueResponses[$responseIndex].issueKey"
            }
            if ($WorkflowVersion -eq 'workflow-v2' -and [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $response -Name 'rationale'))) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'issueResponses.rationale 값이 비어 있습니다.' -Code 'DF-VAL-NONEMPTY' -Path "issueResponses[$responseIndex].rationale"
            }
            $responseLocations = $null
            if ($response -is [System.Collections.IDictionary] -and $response.Contains('locations')) { $responseLocations = $response['locations'] }
            elseif ($null -ne $response.PSObject.Properties['locations']) { $responseLocations = $response.PSObject.Properties['locations'].Value }
            if ($null -eq $responseLocations -or $responseLocations -is [string] -or $responseLocations -isnot [System.Collections.IEnumerable]) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'issueResponses.locations 속성은 배열이어야 합니다.' -Code 'DF-VAL-TYPE' -Path "issueResponses[$responseIndex].locations"
            }
            else {
                $responseLocationArray = @($responseLocations)
                for ($locationIndex = 0; $locationIndex -lt $responseLocationArray.Count; $locationIndex++) {
                    if ($WorkflowVersion -eq 'workflow-v2' -and [string]::IsNullOrWhiteSpace([string]$responseLocationArray[$locationIndex])) {
                        Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'issueResponses.locations에는 비어 있지 않은 위치만 사용할 수 있습니다.' -Code 'DF-VAL-NONEMPTY' -Path "issueResponses[$responseIndex].locations[$locationIndex]"
                    }
                }
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
        $structuralFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-VAL-ARRAY-NOT-ALLOWED' -Path 'adoptions'))
    }
    $adoptionArray = @($adoptionItems)
    for ($adoptionIndex = 0; $adoptionIndex -lt $adoptionArray.Count; $adoptionIndex++) {
        $adoption = $adoptionArray[$adoptionIndex]
        foreach ($name in @('issueKey', 'rationale')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $adoption -Name $name))) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "adoptions.$name 값이 비어 있습니다." -Code 'DF-VAL-NONEMPTY' -Path "adoptions[$adoptionIndex].$name"
            }
        }
        if ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'disposition') -notin @('ACCEPTED', 'PARTIALLY_ACCEPTED', 'REJECTED', 'DEFERRED')) {
            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'adoptions.disposition 값이 잘못되었습니다.' -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "adoptions[$adoptionIndex].disposition"
        }
        $locations = $null
        if ($adoption -is [System.Collections.IDictionary] -and $adoption.Contains('locations')) { $locations = $adoption['locations'] }
        elseif ($null -ne $adoption.PSObject.Properties['locations']) { $locations = $adoption.PSObject.Properties['locations'].Value }
        if ($null -eq $locations -or $locations -is [string] -or $locations -isnot [System.Collections.IEnumerable]) {
            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'adoptions.locations 속성은 배열이어야 합니다.' -Code 'DF-VAL-TYPE' -Path "adoptions[$adoptionIndex].locations"
        }
        elseif ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'disposition') -in @('ACCEPTED', 'PARTIALLY_ACCEPTED') -and @($locations).Count -eq 0) {
            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'ACCEPTED 또는 PARTIALLY_ACCEPTED adoption에는 실제 반영 위치가 필요합니다.' -Code 'DF-VAL-COUNT' -Path "adoptions[$adoptionIndex].locations"
        }
        else {
            $locationArray = @($locations)
            for ($locationIndex = 0; $locationIndex -lt $locationArray.Count; $locationIndex++) {
                if ($WorkflowVersion -eq 'workflow-v2' -and [string]::IsNullOrWhiteSpace([string]$locationArray[$locationIndex])) {
                    Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'adoptions.locations에는 비어 있지 않은 위치만 사용할 수 있습니다.' -Code 'DF-VAL-NONEMPTY' -Path "adoptions[$adoptionIndex].locations[$locationIndex]"
                }
            }
        }
        if ($WorkflowVersion -eq 'workflow-v2') {
            foreach ($name in @('sourceDocumentId', 'proposedByProvider', 'targetDocumentId')) {
                if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $adoption -Name $name))) {
                    Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "adoptions.$name 값이 비어 있습니다." -Code 'DF-VAL-NONEMPTY' -Path "adoptions[$adoptionIndex].$name"
                }
            }
            if ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'sourceDocumentId') -cnotin @('brief', 'A', 'B', 'merged')) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'adoptions.sourceDocumentId 값이 잘못되었습니다.' -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "adoptions[$adoptionIndex].sourceDocumentId"
            }
            elseif ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'sourceDocumentId') -cnotin @($lineagePolicy.adoptionSourceDocumentIds)) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "adoptions.sourceDocumentId가 $ExpectedStage 단계의 허용 출처와 다릅니다." -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "adoptions[$adoptionIndex].sourceDocumentId" -Expected @($lineagePolicy.adoptionSourceDocumentIds)
            }
            if ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'proposedByProvider') -notin @('codex', 'claude')) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'adoptions.proposedByProvider 값이 잘못되었습니다.' -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "adoptions[$adoptionIndex].proposedByProvider"
            }
            if ([string](Get-DuoForgeObjectValue -Object $adoption -Name 'targetDocumentId') -cnotin @('A', 'B', 'merged')) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'adoptions.targetDocumentId 값이 잘못되었습니다.' -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "adoptions[$adoptionIndex].targetDocumentId"
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
            if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $question -Name $name))) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message "openQuestions.$name 값이 비어 있습니다." -Code 'DF-VAL-NONEMPTY' -Path "openQuestions[$questionIndex].$name"
            }
        }
        $options = @(Get-DuoForgeObjectValue -Object $question -Name 'options' -Default @())
        if ($options.Count -lt 2 -or $options.Count -gt 3) {
            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'openQuestions.options에는 실제 선택지 두 개 또는 세 개가 필요합니다.' -Code 'DF-VAL-COUNT' -Path "openQuestions[$questionIndex].options"
        }
        $normalizedOptions = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        for ($optionIndex = 0; $optionIndex -lt $options.Count; $optionIndex++) {
            if ($options[$optionIndex] -isnot [string]) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'openQuestions.options의 각 선택지는 문자열이어야 합니다.' -Code 'DF-VAL-TYPE' -Path "openQuestions[$questionIndex].options[$optionIndex]"
                continue
            }
            $optionText = ([string]$options[$optionIndex]).Trim()
            if ([string]::IsNullOrWhiteSpace($optionText)) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'openQuestions.options에는 비어 있지 않은 선택지만 사용할 수 있습니다.' -Code 'DF-VAL-NONEMPTY' -Path "openQuestions[$questionIndex].options[$optionIndex]"
                continue
            }
            if (Test-DuoForgeQuestionOptionMetadataInternal -Option $optionText) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'openQuestions.options에는 스키마 설명이나 자리 표시 문구를 사용할 수 없습니다.' -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "openQuestions[$questionIndex].options[$optionIndex]"
            }
            $letter = [string][char]([int][char]'A' + $optionIndex)
            $prefixPattern = '^\s*' + [regex]::Escape($letter) + '\s*[:：.)-]\s*'
            $normalizedOption = ([regex]::Replace($optionText, $prefixPattern, '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) -replace '\s+', ' ').Trim()
            if (-not $normalizedOptions.Add($normalizedOption)) {
                Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'openQuestions.options에는 서로 다른 선택지만 사용할 수 있습니다.' -Code 'DF-VAL-UNIQUE' -Path "openQuestions[$questionIndex].options[$optionIndex]"
            }
        }
        $recommendedOption = [string](Get-DuoForgeObjectValue -Object $question -Name 'recommendedOption' -Default '')
        if (-not (Test-DuoForgeQuestionRecommendationInternal -RecommendedOption $recommendedOption -Options $options)) {
            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'openQuestions.recommendedOption은 options의 실제 선택지 또는 해당 A/B/C 코드와 일치해야 합니다.' -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "openQuestions[$questionIndex].recommendedOption"
        }
        $reversibility = [string](Get-DuoForgeObjectValue -Object $question -Name 'reversibility' -Default '')
        if ($reversibility -notin @('easy', 'moderate', 'hard', 'unknown')) {
            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'openQuestions.reversibility 값이 잘못되었습니다.' -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "openQuestions[$questionIndex].reversibility"
        }
        $confidence = [string](Get-DuoForgeObjectValue -Object $question -Name 'confidence' -Default '')
        if ($confidence -notin @('low', 'medium', 'high')) {
            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'openQuestions.confidence 값이 잘못되었습니다.' -Code 'DF-VAL-CONTRACT-MISMATCH' -Path "openQuestions[$questionIndex].confidence"
        }
        if ((Get-DuoForgeObjectValue -Object $question -Name 'experimentPossible') -isnot [bool]) {
            Add-DuoForgeStageStructuralFailureInternal -Errors $errors -Failures $structuralFailures -Message 'openQuestions.experimentPossible 값은 boolean이어야 합니다.' -Code 'DF-VAL-TYPE' -Path "openQuestions[$questionIndex].experimentPossible"
        }
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
    foreach ($failure in @($structuralFailures)) { $validationFailures.Add($failure) }
    $genericStructuralErrorCount = [Math]::Max(0, $structuralErrorCount - $structuralFailures.Count)
    if ($genericStructuralErrorCount -gt 0) {
        $validationFailures.Add((New-DuoForgeSafeValidationFailureInternal -Code 'DF-VAL-STRUCTURE' -Path '$' -Count $genericStructuralErrorCount))
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
        [AllowEmptyCollection()][string[]]$ExpectedSourceDocumentIds = @(),
        [AllowEmptyString()][string]$ExpectedPerformedBy = '',
        [AllowEmptyString()][string]$ExpectedIssueKeyPrefix = ''
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
    $null = Test-DuoForgeStageResultInternal -Result $protected -ExpectedStage $ExpectedStage -ExpectedProvider $ExpectedProvider -WorkflowVersion $WorkflowVersion -ExpectedTargetDocumentId $ExpectedTargetDocumentId -ExpectedSourceDocumentIds $ExpectedSourceDocumentIds -ExpectedPerformedBy $ExpectedPerformedBy -ExpectedIssueKeyPrefix $ExpectedIssueKeyPrefix -ThrowOnError
    return [ordered]@{
        rawHash = $rawHash
        redactionCount = $redactions
        result = $protected
    }
}

function ConvertFrom-DuoForgeThinProviderResultInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RawJson,
        [Parameter(Mandatory)][ValidateSet('independent-result', 'integration', 'final-validation', 'final-revision')][string]$Stage
    )

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($RawJson)
    $rawHash = Get-DuoForgeSha256 -Bytes $bytes
    try { $parsed = ConvertTo-DuoForgeHashtable -InputObject ($RawJson | ConvertFrom-Json -Depth 100) }
    catch { throw (New-DuoForgeException -Code 'DF-PROVIDER-JSON' -Message "공급자 결과가 유효한 JSON이 아닙니다. 원문 해시: $rawHash") }
    $redactions = 0
    $protected = Protect-DuoForgeObjectInternal -Value $parsed -RedactionCount ([ref]$redactions)
    return [ordered]@{ rawHash = $rawHash; redactionCount = $redactions; result = $protected }
}
