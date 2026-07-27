function Get-DuoForgeStageSchemaPath {
    [CmdletBinding()]
    param()

    return Join-Path $script:ProjectRoot 'schemas\stage-result.schema.json'
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

    if ([int](Get-DuoForgeObjectValue -Object $Result -Name 'schemaVersion' -Default 0) -ne 1) {
        $errors.Add('schemaVersion은 1이어야 합니다.')
    }
    if ([string](Get-DuoForgeObjectValue -Object $Result -Name 'stage') -cne $ExpectedStage) {
        $errors.Add("stage가 예상값과 다릅니다: $ExpectedStage")
    }
    if ([string](Get-DuoForgeObjectValue -Object $Result -Name 'provider') -cne $ExpectedProvider) {
        $errors.Add("provider가 예상값과 다릅니다: $ExpectedProvider")
    }

    $documentStages = @('independent-draft', 'synthesis', 'owned-document-revision')
    if ($ExpectedStage -in $documentStages -and [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $Result -Name 'document'))) {
        $errors.Add("$ExpectedStage 단계에는 비어 있지 않은 document가 필요합니다.")
    }
    if ($ExpectedStage -eq 'final-validation' -and (Get-DuoForgeObjectValue -Object $Result -Name 'finalApproved') -isnot [bool]) {
        $errors.Add('final-validation 단계에는 boolean finalApproved가 필요합니다.')
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
        foreach ($name in @('issueKey', 'target', 'category', 'claim')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $issue -Name $name))) {
                $errors.Add("issue.$name 값이 비어 있습니다.")
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

    $validation = [ordered]@{ valid = $errors.Count -eq 0; errors = @($errors) }
    if ($ThrowOnError -and -not $validation.valid) {
        throw (New-DuoForgeException -Code 'DF-STAGE-SCHEMA' -Message ($validation.errors -join ' '))
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
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$ExpectedProvider
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
    $null = Test-DuoForgeStageResultInternal -Result $protected -ExpectedStage $ExpectedStage -ExpectedProvider $ExpectedProvider -ThrowOnError
    return [ordered]@{
        rawHash = $rawHash
        redactionCount = $redactions
        result = $protected
    }
}
