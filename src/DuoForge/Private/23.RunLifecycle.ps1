function Abandon-DuoForgeRunInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $runDirectory = [string]$run.runDirectory
    return Invoke-WithDuoForgeRunLock -RunDirectory $runDirectory -ScriptBlock {
        $current = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
        $state = ConvertTo-DuoForgeHashtable -InputObject $current.state
        if ([string]$state.status -eq 'CANCELLED') {
            return [ordered]@{
                runId = $RunId
                name = [string]$current.manifest.name
                status = 'CANCELLED'
                abandoned = $false
                alreadyAbandoned = $true
                runDirectory = $runDirectory
            }
        }

        $otherTerminalStates = @('COMPLETED', 'COMPLETED_PARTIAL', 'QUESTION_LIMIT_REACHED', 'FAILED_STAGE', 'SOURCE_DRIFT')
        if ([string]$state.status -in $otherTerminalStates) {
            throw (New-DuoForgeException -Code 'DF-RUN-ABANDON-TERMINAL' -Message '이미 종료된 작업은 포기 상태로 바꿀 수 없습니다.')
        }

        $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
        $previousStatus = [string]$state.status
        return Invoke-WithDuoForgeRunMutationTransactionInternal -RunDirectory $runDirectory -RelativePaths @('state.json', 'events.jsonl') -ScriptBlock {
            $abandonedAt = Get-DuoForgeUtcNow
            $state.status = 'CANCELLED'
            $state.updatedAt = $abandonedAt
            $state.abandonedAt = $abandonedAt
            $state.abandonedFromStatus = $previousStatus
            Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'state.json') -Value $state
            Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'STATE_CHANGED' -Status 'CANCELLED' -Data ([ordered]@{ lastCompletedStage = $state.lastCompletedStage; round = $state.round })
            Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'RUN_ABANDONED' -Status 'CANCELLED' -Data ([ordered]@{ previousStatus = $previousStatus })
            $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
            return [ordered]@{
                runId = $RunId
                name = [string]$current.manifest.name
                status = 'CANCELLED'
                abandoned = $true
                alreadyAbandoned = $false
                previousStatus = $previousStatus
                abandonedAt = $abandonedAt
                runDirectory = $runDirectory
            }
        }
    }
}

function Restore-DuoForgeRunInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $runDirectory = [string]$run.runDirectory
    return Invoke-WithDuoForgeRunLock -RunDirectory $runDirectory -ScriptBlock {
        $current = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
        $state = ConvertTo-DuoForgeHashtable -InputObject $current.state
        if ([string]$state.status -ne 'CANCELLED') {
            throw (New-DuoForgeException -Code 'DF-RUN-RESTORE-STATE' -Message '복원은 포기한 작업에만 사용할 수 있습니다.')
        }

        $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
        return Invoke-WithDuoForgeRunMutationTransactionInternal -RunDirectory $runDirectory -RelativePaths @('state.json', 'events.jsonl') -ScriptBlock {
            $restoredAt = Get-DuoForgeUtcNow
            $state.status = 'PAUSED_USER'
            $state.updatedAt = $restoredAt
            $state.restoredAt = $restoredAt
            Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'state.json') -Value $state
            Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'STATE_CHANGED' -Status 'PAUSED_USER' -Data ([ordered]@{ lastCompletedStage = $state.lastCompletedStage; round = $state.round })
            Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'RUN_RESTORED' -Status 'PAUSED_USER' -Data ([ordered]@{ previousStatus = 'CANCELLED' })
            $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
            return [ordered]@{
                runId = $RunId
                name = [string]$current.manifest.name
                status = 'PAUSED_USER'
                restored = $true
                previousStatus = 'CANCELLED'
                restoredAt = $restoredAt
                runDirectory = $runDirectory
            }
        }
    }
}

function Resolve-DuoForgeRunDeletionTargetInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    if ([string]::IsNullOrWhiteSpace($RunId) -or
        [System.IO.Path]::GetFileName($RunId) -cne $RunId -or
        $RunId -notmatch '^run-[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw (New-DuoForgeException -Code 'DF-RUN-DELETE-TARGET' -Message '영구 삭제 대상 작업 ID가 안전한 단일 폴더 이름이 아닙니다.')
    }

    if ([string]::IsNullOrWhiteSpace($ResultsRoot)) { $ResultsRoot = (Get-DuoForgeConfig).resultsRoot }
    $resolvedRoot = [System.IO.Path]::GetFullPath((Resolve-DuoForgePathInternal -Path $ResultsRoot -ExpectedType Directory))
    $target = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $RunId))
    $targetParent = [System.IO.Path]::GetDirectoryName($target)
    if (-not [string]::Equals($targetParent.TrimEnd('\', '/'), $resolvedRoot.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-DuoForgeException -Code 'DF-RUN-DELETE-TARGET' -Message '영구 삭제 대상이 실행 결과 폴더의 직계 작업 폴더가 아닙니다.')
    }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        throw (New-DuoForgeException -Code 'DF-RUN-NOT-FOUND' -Message "실행을 찾을 수 없습니다: $RunId")
    }

    $targetItem = Get-Item -LiteralPath $target -Force
    if (($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw (New-DuoForgeException -Code 'DF-RUN-DELETE-REPARSE' -Message '연결 지점인 작업 폴더는 영구 삭제할 수 없습니다.')
    }
    $reparseDescendants = @(Get-ChildItem -LiteralPath $target -Recurse -Force -ErrorAction Stop | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparseDescendants.Count -gt 0) {
        throw (New-DuoForgeException -Code 'DF-RUN-DELETE-REPARSE' -Message '작업 폴더 안에 연결 지점이 있어 영구 삭제를 중단했습니다.')
    }

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $resolvedRoot
    if ([string]$run.state.runId -cne $RunId) {
        throw (New-DuoForgeException -Code 'DF-RUN-DELETE-TARGET' -Message '작업 폴더 이름과 저장된 작업 ID가 일치하지 않습니다.')
    }
    return [ordered]@{
        runId = $RunId
        name = [string]$run.manifest.name
        status = [string]$run.state.status
        resultsRoot = $resolvedRoot
        runDirectory = $target
    }
}

function Remove-DuoForgeRunInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    $target = Resolve-DuoForgeRunDeletionTargetInternal -RunId $RunId -ResultsRoot $ResultsRoot
    if ([string]$target.status -ne 'CANCELLED') {
        throw (New-DuoForgeException -Code 'DF-RUN-DELETE-STATE' -Message '영구 삭제는 먼저 포기한 작업에만 사용할 수 있습니다.')
    }

    $null = Invoke-WithDuoForgeRunLock -RunDirectory ([string]$target.runDirectory) -ScriptBlock {
        $lockedTarget = Resolve-DuoForgeRunDeletionTargetInternal -RunId $RunId -ResultsRoot ([string]$target.resultsRoot)
        if ([string]$lockedTarget.status -ne 'CANCELLED') {
            throw (New-DuoForgeException -Code 'DF-RUN-DELETE-STATE' -Message '영구 삭제 직전에 작업 상태가 달라졌습니다.')
        }
        $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory ([string]$lockedTarget.runDirectory)
        return $true
    }

    $deletingRoot = Join-Path ([string]$target.resultsRoot) '.deleting'
    [System.IO.Directory]::CreateDirectory($deletingRoot) | Out-Null
    $quarantinePath = Join-Path $deletingRoot ('{0}-{1}' -f $RunId, [Guid]::NewGuid().ToString('N'))
    $moved = $false
    try {
        [System.IO.Directory]::Move([string]$target.runDirectory, $quarantinePath)
        $moved = $true
        $quarantineReparsePoints = @(Get-ChildItem -LiteralPath $quarantinePath -Recurse -Force -ErrorAction Stop | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 })
        if ($quarantineReparsePoints.Count -gt 0) {
            throw (New-DuoForgeException -Code 'DF-RUN-DELETE-REPARSE' -Message '삭제 직전 작업 폴더에서 연결 지점이 발견되었습니다.')
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $quarantinePath -File -Recurse -Force -ErrorAction Stop)) {
            if (($file.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) { $file.Attributes = [System.IO.FileAttributes]::Normal }
        }
        [System.IO.Directory]::Delete($quarantinePath, $true)
        if ((Test-Path -LiteralPath $deletingRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $deletingRoot -Force).Count -eq 0) {
            [System.IO.Directory]::Delete($deletingRoot, $false)
        }
    }
    catch {
        $deleteError = $_
        if ($moved -and (Test-Path -LiteralPath $quarantinePath -PathType Container) -and -not (Test-Path -LiteralPath ([string]$target.runDirectory))) {
            try { [System.IO.Directory]::Move($quarantinePath, [string]$target.runDirectory) } catch { }
        }
        if ((Test-Path -LiteralPath $deletingRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $deletingRoot -Force).Count -eq 0) {
            try { [System.IO.Directory]::Delete($deletingRoot, $false) } catch { }
        }
        if ([string]$deleteError.Exception.Data['DuoForgeCode'] -eq 'DF-RUN-DELETE-REPARSE') { throw $deleteError.Exception }
        throw (New-DuoForgeException -Code 'DF-RUN-DELETE-FAILED' -Message '작업 폴더를 영구 삭제하지 못했습니다. 남은 작업 폴더를 확인해 주세요.')
    }

    return [ordered]@{
        runId = $RunId
        name = [string]$target.name
        status = 'DELETED'
        deleted = $true
    }
}
