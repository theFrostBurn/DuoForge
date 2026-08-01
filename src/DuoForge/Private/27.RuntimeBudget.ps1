function Get-DuoForgeRuntimeBudgetInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $state = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json')
    $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
    $baseMaximumMinutes = [int](Get-DuoForgeObjectValue -Object $manifest -Name 'maxWallClockMinutes' -Default 90)
    $extensionMinutes = [int](Get-DuoForgeObjectValue -Object $state -Name 'runtimeExtensionMinutes' -Default 0)
    $extensionGrantCount = [int](Get-DuoForgeObjectValue -Object $state -Name 'runtimeExtensionGrantCount' -Default 0)
    $usedSeconds = [double](Get-DuoForgeObjectValue -Object $state -Name 'runtimeSeconds' -Default 0.0)
    if ($baseMaximumMinutes -lt 1 -or
        $extensionMinutes -notin @(0, 60) -or
        $extensionGrantCount -notin @(0, 1) -or
        (($extensionGrantCount -eq 0) -ne ($extensionMinutes -eq 0)) -or
        [double]::IsNaN($usedSeconds) -or [double]::IsInfinity($usedSeconds) -or $usedSeconds -lt 0.0) {
        throw (New-DuoForgeException -Code 'DF-RUN-TIME-BUDGET' -Message '저장된 총 실행시간 한도 정보가 안전한 범위를 벗어났습니다.')
    }
    $effectiveMaximumMinutes = $baseMaximumMinutes + $extensionMinutes
    $effectiveMaximumSeconds = [double]$effectiveMaximumMinutes * 60.0
    return [ordered]@{
        baseMaximumMinutes = $baseMaximumMinutes
        extensionMinutes = $extensionMinutes
        extensionGrantCount = $extensionGrantCount
        effectiveMaximumMinutes = $effectiveMaximumMinutes
        effectiveMaximumSeconds = $effectiveMaximumSeconds
        maximumMinutes = $effectiveMaximumMinutes
        maximumSeconds = $effectiveMaximumSeconds
        usedSeconds = [Math]::Round($usedSeconds, 3)
        remainingSeconds = [Math]::Max(0.0, [Math]::Round($effectiveMaximumSeconds - $usedSeconds, 3))
        exhausted = $usedSeconds -ge $effectiveMaximumSeconds
    }
}

function Test-DuoForgeRuntimeLimitFailureInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json'))
    if ([string]$state.status -ne 'RESUMABLE_ERROR') { return $false }
    $stepsPath = Join-Path $RunDirectory 'steps.json'
    if (-not (Test-Path -LiteralPath $stepsPath -PathType Leaf)) { return $false }
    $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $stepsPath)
    $failedSteps = @($graph.steps | Where-Object { [string]$_.status -eq 'FAILED' })
    if ($failedSteps.Count -ne 1) { return $false }
    $lastError = Get-DuoForgeObjectValue -Object $failedSteps[0] -Name 'lastError'
    return $null -ne $lastError -and [string](Get-DuoForgeObjectValue -Object $lastError -Name 'code' -Default '') -ceq 'DF-RUN-TIME-LIMIT'
}

function Add-DuoForgeRuntimeSecondsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][ValidateRange(0.0, 86400.0)][double]$Seconds
    )

    $statePath = Join-Path $RunDirectory 'state.json'
    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
    $state.runtimeSeconds = [Math]::Round(([double](Get-DuoForgeObjectValue -Object $state -Name 'runtimeSeconds' -Default 0.0) + $Seconds), 3)
    $state.updatedAt = Get-DuoForgeUtcNow
    Write-DuoForgeJsonAtomic -Path $statePath -Value $state
    return [double]$state.runtimeSeconds
}

function New-DuoForgeRuntimeLimitExceptionInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Budget)

    $exception = New-DuoForgeException -Code 'DF-RUN-TIME-LIMIT' -Message "누적 모델 실행 시간이 $($Budget.effectiveMaximumMinutes)분 상한에 도달했습니다. 총 실행시간을 한 번 연장하거나 현재 결과를 검토해 주세요."
    $exception.Data['DuoForgeFailureCategory'] = 'run-time-limit'
    $exception.Data['DuoForgeFailureStatus'] = 'RESUMABLE_ERROR'
    $exception.Data['DuoForgeRetryable'] = $false
    return $exception
}
