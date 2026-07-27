function Get-DuoForgeRuntimeBudgetInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $state = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json')
    $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
    $maximumMinutes = [int](Get-DuoForgeObjectValue -Object $manifest -Name 'maxWallClockMinutes' -Default 90)
    $usedSeconds = [double](Get-DuoForgeObjectValue -Object $state -Name 'runtimeSeconds' -Default 0.0)
    $maximumSeconds = [double]$maximumMinutes * 60.0
    return [ordered]@{
        maximumMinutes = $maximumMinutes
        maximumSeconds = $maximumSeconds
        usedSeconds = [Math]::Round($usedSeconds, 3)
        remainingSeconds = [Math]::Max(0.0, [Math]::Round($maximumSeconds - $usedSeconds, 3))
        exhausted = $usedSeconds -ge $maximumSeconds
    }
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

    $exception = New-DuoForgeException -Code 'DF-RUN-TIME-LIMIT' -Message "누적 모델 실행 시간이 $($Budget.maximumMinutes)분 상한에 도달했습니다. 입력 범위를 줄인 새 실행을 만들거나 현재 결과를 부분 완료로 검토해 주세요."
    $exception.Data['DuoForgeFailureCategory'] = 'run-time-limit'
    $exception.Data['DuoForgeFailureStatus'] = 'RESUMABLE_ERROR'
    $exception.Data['DuoForgeRetryable'] = $false
    return $exception
}
