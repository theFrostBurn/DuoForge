function Get-DuoForgeProviderSelectionOptionsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('codex', 'claude')]
        [string]$Provider
    )

    if ($Provider -eq 'codex') {
        return [ordered]@{
            provider = 'codex'
            displayName = 'Codex'
            suggestedModels = @(
                [ordered]@{ value = 'gpt-5.6'; description = '범용 최신 계열 별칭' }
                [ordered]@{ value = 'gpt-5.6-terra'; description = '빠른 반복과 읽기 중심 작업' }
            )
            reasoningEfforts = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')
        }
    }

    return [ordered]@{
        provider = 'claude'
        displayName = 'Claude'
        suggestedModels = @(
            [ordered]@{ value = 'sonnet'; description = 'CLI 모델 별칭' }
            [ordered]@{ value = 'opus'; description = 'CLI 모델 별칭' }
            [ordered]@{ value = 'fable'; description = 'CLI 모델 별칭' }
        )
        reasoningEfforts = @('low', 'medium', 'high', 'xhigh', 'max')
    }
}

function Test-DuoForgeModelIdentifierInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Model)

    if ([string]::IsNullOrWhiteSpace($Model)) { return $false }
    return $Model.Trim() -cmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$'
}

function Test-DuoForgeProviderSelectionsInternal {
    [CmdletBinding()]
    param($Selections)

    $errors = [System.Collections.Generic.List[object]]::new()
    foreach ($provider in @('codex', 'claude')) {
        $options = Get-DuoForgeProviderSelectionOptionsInternal -Provider $provider
        $selection = Get-DuoForgeObjectValue -Object $Selections -Name $provider
        $model = [string](Get-DuoForgeObjectValue -Object $selection -Name 'model')
        $effort = [string](Get-DuoForgeObjectValue -Object $selection -Name 'reasoningEffort')

        if ([string]::IsNullOrWhiteSpace($model)) {
            $errors.Add([ordered]@{
                code = 'DF-PROVIDER-SELECTION-REQUIRED'
                message = "$($options.displayName) 모델을 반드시 선택해야 합니다."
            })
        }
        elseif (-not (Test-DuoForgeModelIdentifierInternal -Model $model)) {
            $errors.Add([ordered]@{
                code = 'DF-PROVIDER-MODEL'
                message = "$($options.displayName) 모델 식별자 형식이 올바르지 않습니다: $model"
            })
        }

        if ([string]::IsNullOrWhiteSpace($effort)) {
            $errors.Add([ordered]@{
                code = 'DF-PROVIDER-SELECTION-REQUIRED'
                message = "$($options.displayName) 추론 정도를 반드시 선택해야 합니다."
            })
        }
        elseif ($effort -cnotin @($options.reasoningEfforts)) {
            $errors.Add([ordered]@{
                code = 'DF-PROVIDER-EFFORT'
                message = "$($options.displayName) 추론 정도 '$effort'는 지원 목록에 없습니다: $($options.reasoningEfforts -join ', ')"
            })
        }
    }

    return [ordered]@{
        valid = $errors.Count -eq 0
        errors = @($errors)
    }
}

function Assert-DuoForgeProviderSelectionsInternal {
    [CmdletBinding()]
    param($Selections)

    $validation = Test-DuoForgeProviderSelectionsInternal -Selections $Selections
    if (-not [bool]$validation.valid) {
        $first = $validation.errors[0]
        throw (New-DuoForgeException -Code ([string]$first.code) -Message (@($validation.errors.message) -join ' '))
    }
    return $Selections
}

function Get-DuoForgeRunProviderSelectionsInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
    $selections = Get-DuoForgeObjectValue -Object $manifest -Name 'providerSelections'
    return Assert-DuoForgeProviderSelectionsInternal -Selections $selections
}

function Read-DuoForgeModelChoiceInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('codex', 'claude')]
        [string]$Provider
    )

    $options = Get-DuoForgeProviderSelectionOptionsInternal -Provider $Provider
    while ($true) {
        Write-Host ''
        Write-Host ("{0} 모델을 선택해 주세요." -f $options.displayName)
        for ($index = 0; $index -lt @($options.suggestedModels).Count; $index++) {
            $item = $options.suggestedModels[$index]
            Write-Host ("[{0}] {1} - {2}" -f ($index + 1), $item.value, $item.description)
        }
        $customNumber = @($options.suggestedModels).Count + 1
        Write-Host ("[{0}] 모델명 직접 입력" -f $customNumber)
        Write-Host '[B] 이전으로'
        $choice = (Read-Host '선택').Trim()
        if ($choice -ieq 'B') { return $null }

        $number = 0
        if (-not [int]::TryParse($choice, [ref]$number)) {
            Write-Host '올바른 모델 항목을 선택해 주세요.' -ForegroundColor Yellow
            continue
        }
        if ($number -ge 1 -and $number -le @($options.suggestedModels).Count) {
            return [string]$options.suggestedModels[$number - 1].value
        }
        if ($number -eq $customNumber) {
            $model = (Read-Host 'CLI에 전달할 정확한 모델명').Trim()
            if (Test-DuoForgeModelIdentifierInternal -Model $model) { return $model }
            Write-Host '모델명은 영문자나 숫자로 시작하고 영문자, 숫자, 점, 밑줄, 콜론, 슬래시, 하이픈만 사용할 수 있습니다.' -ForegroundColor Yellow
            continue
        }
        Write-Host '올바른 모델 항목을 선택해 주세요.' -ForegroundColor Yellow
    }
}

function Read-DuoForgeReasoningEffortChoiceInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('codex', 'claude')]
        [string]$Provider
    )

    $options = Get-DuoForgeProviderSelectionOptionsInternal -Provider $Provider
    while ($true) {
        Write-Host ''
        Write-Host ("{0} 추론 정도를 선택해 주세요." -f $options.displayName)
        for ($index = 0; $index -lt @($options.reasoningEfforts).Count; $index++) {
            Write-Host ("[{0}] {1}" -f ($index + 1), $options.reasoningEfforts[$index])
        }
        Write-Host '[B] 이전으로'
        $choice = (Read-Host '선택').Trim()
        if ($choice -ieq 'B') { return $null }

        $number = 0
        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le @($options.reasoningEfforts).Count) {
            return [string]$options.reasoningEfforts[$number - 1]
        }
        Write-Host '올바른 추론 정도를 선택해 주세요.' -ForegroundColor Yellow
    }
}

function Complete-DuoForgeInteractiveProviderSelectionsInternal {
    [CmdletBinding()]
    param($InitialSelections)

    $result = [ordered]@{}
    foreach ($provider in @('codex', 'claude')) {
        $existing = Get-DuoForgeObjectValue -Object $InitialSelections -Name $provider
        $model = [string](Get-DuoForgeObjectValue -Object $existing -Name 'model')
        $effort = [string](Get-DuoForgeObjectValue -Object $existing -Name 'reasoningEffort')
        $options = Get-DuoForgeProviderSelectionOptionsInternal -Provider $provider

        if (-not (Test-DuoForgeModelIdentifierInternal -Model $model)) {
            $model = Read-DuoForgeModelChoiceInternal -Provider $provider
            if ($null -eq $model) { return $null }
        }
        else {
            Write-Host ("{0} 모델: {1}" -f $options.displayName, $model)
        }

        if ($effort -cnotin @($options.reasoningEfforts)) {
            $effort = Read-DuoForgeReasoningEffortChoiceInternal -Provider $provider
            if ($null -eq $effort) { return $null }
        }
        else {
            Write-Host ("{0} 추론 정도: {1}" -f $options.displayName, $effort)
        }

        $result[$provider] = [ordered]@{
            model = $model
            reasoningEffort = $effort
        }
    }
    return $result
}
