function New-DuoForgeRunId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResultsRoot
    )

    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $suffix = [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(3)).ToLowerInvariant()
        $runId = 'run-{0}-{1}' -f [DateTime]::Now.ToString('yyyyMMdd-HHmmss'), $suffix
        if (-not (Test-Path -LiteralPath (Join-Path $ResultsRoot $runId))) {
            return $runId
        }
    }
    throw (New-DuoForgeException -Code 'DF-RUN-ID' -Message '고유 실행 ID를 만들 수 없습니다.')
}

function Invoke-WithDuoForgeRunLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RunDirectory,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $lockPath = Join-Path $RunDirectory 'run.lock'
    try {
        $lockStream = [System.IO.FileStream]::new(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None,
            1,
            [System.IO.FileOptions]::DeleteOnClose
        )
    }
    catch {
        throw (New-DuoForgeException -Code 'DF-RUN-LOCKED' -Message "다른 DuoForge 프로세스가 이 실행을 갱신 중입니다: $RunDirectory")
    }

    try {
        $null = Repair-DuoForgePreparedTransactionsInternal -RunDirectory $RunDirectory
        return & $ScriptBlock
    }
    finally {
        $lockStream.Dispose()
    }
}

function Test-DuoForgeByteArraysEqualInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][byte[]]$Left,
        [AllowEmptyCollection()][byte[]]$Right
    )

    if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Write-DuoForgeBytesAtomicInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][Parameter(Mandatory)][byte[]]$Bytes
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($fullPath)) | Out-Null
    $temporaryPath = "$fullPath.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllBytes($temporaryPath, $Bytes)
        [System.IO.File]::Move($temporaryPath, $fullPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-DuoForgeTransactionDirectoryInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TransactionDirectory)

    if (-not (Test-Path -LiteralPath $TransactionDirectory -PathType Container)) { return }
    foreach ($item in @(Get-ChildItem -LiteralPath $TransactionDirectory -File -Force | Where-Object { $_.Name -ne 'transaction.json' })) {
        Remove-Item -LiteralPath $item.FullName -Force
    }
    $metadataPath = Join-Path $TransactionDirectory 'transaction.json'
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) { Remove-Item -LiteralPath $metadataPath -Force }
    if (@(Get-ChildItem -LiteralPath $TransactionDirectory -Force).Count -eq 0) { Remove-Item -LiteralPath $TransactionDirectory -Force }
}

function Remove-DuoForgeAtomicTemporaryFilesForTargetInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetPath)

    $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($TargetPath))
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return }
    $targetName = [System.IO.Path]::GetFileName($TargetPath)
    $pattern = '^{0}\.[0-9a-fA-F]{{32}}\.tmp$' -f [regex]::Escape($targetName)
    foreach ($item in @(Get-ChildItem -LiteralPath $directory -File -Force | Where-Object { $_.Name -match $pattern })) {
        Remove-Item -LiteralPath $item.FullName -Force
    }
}

function Remove-DuoForgeAtomicTemporaryFilesInDirectoryInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    foreach ($item in @(Get-ChildItem -LiteralPath $Directory -File -Force | Where-Object { $_.Name -match '^.+\.[0-9a-fA-F]{32}\.tmp$' })) {
        Remove-Item -LiteralPath $item.FullName -Force
    }
}

function Repair-DuoForgePreparedTransactionsInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $transactionRoot = Join-Path $RunDirectory 'control\transactions'
    if (-not (Test-Path -LiteralPath $transactionRoot -PathType Container)) { return 0 }
    $runRoot = [System.IO.Path]::GetFullPath($RunDirectory).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $resolvePath = {
        param([string]$RelativePath)
        if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath)) {
            throw (New-DuoForgeException -Code 'DF-RUN-TRANSACTION-RECOVERY' -Message '복구 트랜잭션에 잘못된 상대 경로가 있습니다.')
        }
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $RunDirectory $RelativePath))
        if (-not $fullPath.StartsWith($runRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw (New-DuoForgeException -Code 'DF-RUN-TRANSACTION-RECOVERY' -Message '복구 트랜잭션 경로가 실행 폴더를 벗어났습니다.')
        }
        return $fullPath
    }.GetNewClosure()

    $recovered = 0
    foreach ($transactionDirectory in @(Get-ChildItem -LiteralPath $transactionRoot -Directory -Force)) {
        $metadataPath = Join-Path $transactionDirectory.FullName 'transaction.json'
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
            Remove-DuoForgeTransactionDirectoryInternal -TransactionDirectory $transactionDirectory.FullName
            continue
        }
        $metadata = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $metadataPath)
        if ([string]$metadata.status -eq 'COMMITTED') {
            foreach ($record in @($metadata.files)) {
                $fullPath = & $resolvePath ([string]$record.relativePath)
                Remove-DuoForgeAtomicTemporaryFilesForTargetInternal -TargetPath $fullPath
            }
            foreach ($directoryRecord in @($metadata.directories)) {
                $fullDirectory = & $resolvePath ([string]$directoryRecord.relativePath)
                Remove-DuoForgeAtomicTemporaryFilesInDirectoryInternal -Directory $fullDirectory
            }
            Remove-DuoForgeTransactionDirectoryInternal -TransactionDirectory $transactionDirectory.FullName
            continue
        }
        if ([string]$metadata.status -ne 'PREPARED') {
            throw (New-DuoForgeException -Code 'DF-RUN-TRANSACTION-RECOVERY' -Message '지원하지 않는 실행 트랜잭션 상태가 남아 있습니다.')
        }
        foreach ($record in @($metadata.files)) {
            $fullPath = & $resolvePath ([string]$record.relativePath)
            if ([bool]$record.existed) {
                $backupPath = Join-Path $transactionDirectory.FullName ([string]$record.backupName)
                if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw (New-DuoForgeException -Code 'DF-RUN-TRANSACTION-RECOVERY' -Message '복구할 파일 백업이 없습니다.') }
                Write-DuoForgeBytesAtomicInternal -Path $fullPath -Bytes ([System.IO.File]::ReadAllBytes($backupPath))
            }
            elseif (Test-Path -LiteralPath $fullPath -PathType Leaf) { Remove-Item -LiteralPath $fullPath -Force }
            Remove-DuoForgeAtomicTemporaryFilesForTargetInternal -TargetPath $fullPath
        }
        foreach ($directoryRecord in @($metadata.directories)) {
            $fullDirectory = & $resolvePath ([string]$directoryRecord.relativePath)
            $originalNames = @($directoryRecord.files | ForEach-Object { [string]$_.name })
            if (Test-Path -LiteralPath $fullDirectory -PathType Container) {
                foreach ($item in @(Get-ChildItem -LiteralPath $fullDirectory -File -Force)) {
                    if ($item.Name -notin $originalNames) { Remove-Item -LiteralPath $item.FullName -Force }
                }
            }
            foreach ($fileRecord in @($directoryRecord.files)) {
                $backupPath = Join-Path $transactionDirectory.FullName ([string]$fileRecord.backupName)
                if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw (New-DuoForgeException -Code 'DF-RUN-TRANSACTION-RECOVERY' -Message '복구할 디렉터리 파일 백업이 없습니다.') }
                Write-DuoForgeBytesAtomicInternal -Path (Join-Path $fullDirectory ([string]$fileRecord.name)) -Bytes ([System.IO.File]::ReadAllBytes($backupPath))
            }
            Remove-DuoForgeAtomicTemporaryFilesInDirectoryInternal -Directory $fullDirectory
            if (-not [bool]$directoryRecord.existed -and (Test-Path -LiteralPath $fullDirectory -PathType Container) -and @(Get-ChildItem -LiteralPath $fullDirectory -Force).Count -eq 0) { Remove-Item -LiteralPath $fullDirectory -Force }
        }
        Remove-DuoForgeTransactionDirectoryInternal -TransactionDirectory $transactionDirectory.FullName
        $recovered++
    }
    return $recovered
}

function Invoke-WithDuoForgeRunMutationTransactionInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [AllowEmptyCollection()][string[]]$RelativePaths = @(),
        [AllowEmptyCollection()][string[]]$RelativeDirectories = @(),
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    $runRoot = [System.IO.Path]::GetFullPath($RunDirectory).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $transactionRoot = Join-Path $RunDirectory 'control\transactions'
    [System.IO.Directory]::CreateDirectory($transactionRoot) | Out-Null
    $transactionDirectory = Join-Path $transactionRoot ([Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($transactionDirectory) | Out-Null
    $fileRecords = [System.Collections.Generic.List[object]]::new()
    $directoryRecords = [System.Collections.Generic.List[object]]::new()

    $resolveTrackedPath = {
        param([string]$RelativePath)
        if ([System.IO.Path]::IsPathRooted($RelativePath)) {
            throw (New-DuoForgeException -Code 'DF-RUN-TRANSACTION-PATH' -Message '실행 변경 트랜잭션은 실행 폴더의 상대 경로만 추적할 수 있습니다.')
        }
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $RunDirectory $RelativePath))
        if (-not $fullPath.StartsWith($runRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw (New-DuoForgeException -Code 'DF-RUN-TRANSACTION-PATH' -Message '실행 변경 트랜잭션 경로가 실행 폴더를 벗어났습니다.')
        }
        return $fullPath
    }.GetNewClosure()

    try {
        $recordIndex = 0
        foreach ($relativePath in @($RelativePaths | Sort-Object -Unique)) {
            $fullPath = & $resolveTrackedPath $relativePath
            $existed = Test-Path -LiteralPath $fullPath -PathType Leaf
            $backupPath = Join-Path $transactionDirectory ('file-{0:D4}.bin' -f $recordIndex)
            if ($existed) { [System.IO.File]::Copy($fullPath, $backupPath, $false) }
            $fileRecords.Add([ordered]@{ relativePath = $relativePath; fullPath = $fullPath; existed = $existed; backupPath = $backupPath })
            $recordIndex++
        }

        foreach ($relativeDirectory in @($RelativeDirectories | Sort-Object -Unique)) {
            $fullDirectory = & $resolveTrackedPath $relativeDirectory
            $existed = Test-Path -LiteralPath $fullDirectory -PathType Container
            $files = [System.Collections.Generic.List[object]]::new()
            if ($existed) {
                foreach ($item in @(Get-ChildItem -LiteralPath $fullDirectory -File -Force)) {
                    $backupPath = Join-Path $transactionDirectory ('directory-file-{0:D4}.bin' -f $recordIndex)
                    [System.IO.File]::Copy($item.FullName, $backupPath, $false)
                    $files.Add([ordered]@{ name = $item.Name; fullPath = $item.FullName; backupPath = $backupPath })
                    $recordIndex++
                }
            }
            $directoryRecords.Add([ordered]@{ relativePath = $relativeDirectory; fullPath = $fullDirectory; existed = $existed; files = @($files) })
        }

        $transactionMetadata = [ordered]@{
            schemaVersion = 1
            status = 'PREPARED'
            createdAt = Get-DuoForgeUtcNow
            files = @($fileRecords | ForEach-Object { [ordered]@{ relativePath = $_.relativePath; existed = $_.existed; backupName = if ($_.existed) { [System.IO.Path]::GetFileName([string]$_.backupPath) } else { $null } } })
            directories = @($directoryRecords | ForEach-Object {
                [ordered]@{
                    relativePath = $_.relativePath
                    existed = $_.existed
                    files = @($_.files | ForEach-Object { [ordered]@{ name = [string]$_.name; backupName = [System.IO.Path]::GetFileName([string]$_.backupPath) } })
                }
            })
        }
        Write-DuoForgeJsonAtomic -Path (Join-Path $transactionDirectory 'transaction.json') -Value $transactionMetadata

        $result = & $ScriptBlock
        $transactionMetadata.status = 'COMMITTED'
        $transactionMetadata.committedAt = Get-DuoForgeUtcNow
        Write-DuoForgeJsonAtomic -Path (Join-Path $transactionDirectory 'transaction.json') -Value $transactionMetadata
    }
    catch {
        $originalException = $_.Exception
        try {
            foreach ($record in @($fileRecords)) {
                if ([bool]$record.existed) {
                    $backupBytes = [System.IO.File]::ReadAllBytes([string]$record.backupPath)
                    $currentBytes = if (Test-Path -LiteralPath ([string]$record.fullPath) -PathType Leaf) { [System.IO.File]::ReadAllBytes([string]$record.fullPath) } else { $null }
                    if (-not (Test-DuoForgeByteArraysEqualInternal -Left $backupBytes -Right $currentBytes)) {
                        Write-DuoForgeBytesAtomicInternal -Path ([string]$record.fullPath) -Bytes $backupBytes
                    }
                }
                elseif (Test-Path -LiteralPath ([string]$record.fullPath) -PathType Leaf) {
                    Remove-Item -LiteralPath ([string]$record.fullPath) -Force
                }
            }
            foreach ($directoryRecord in @($directoryRecords)) {
                $originalNames = @($directoryRecord.files | ForEach-Object { [string]$_.name })
                if (Test-Path -LiteralPath ([string]$directoryRecord.fullPath) -PathType Container) {
                    foreach ($item in @(Get-ChildItem -LiteralPath ([string]$directoryRecord.fullPath) -File -Force)) {
                        if ($item.Name -notin $originalNames) { Remove-Item -LiteralPath $item.FullName -Force }
                    }
                }
                foreach ($fileRecord in @($directoryRecord.files)) {
                    $backupBytes = [System.IO.File]::ReadAllBytes([string]$fileRecord.backupPath)
                    $currentBytes = if (Test-Path -LiteralPath ([string]$fileRecord.fullPath) -PathType Leaf) { [System.IO.File]::ReadAllBytes([string]$fileRecord.fullPath) } else { $null }
                    if (-not (Test-DuoForgeByteArraysEqualInternal -Left $backupBytes -Right $currentBytes)) {
                        Write-DuoForgeBytesAtomicInternal -Path ([string]$fileRecord.fullPath) -Bytes $backupBytes
                    }
                }
                if (-not [bool]$directoryRecord.existed -and (Test-Path -LiteralPath ([string]$directoryRecord.fullPath) -PathType Container) -and @(Get-ChildItem -LiteralPath ([string]$directoryRecord.fullPath) -Force).Count -eq 0) {
                    Remove-Item -LiteralPath ([string]$directoryRecord.fullPath) -Force
                }
            }
            foreach ($item in @(Get-ChildItem -LiteralPath $transactionDirectory -File -Force)) { Remove-Item -LiteralPath $item.FullName -Force }
            Remove-Item -LiteralPath $transactionDirectory -Force
        }
        catch {
            $rollbackException = New-DuoForgeException -Code 'DF-RUN-ROLLBACK-FAILED' -Message '실행 메타데이터 변경 실패 뒤 원래 상태를 복구하지 못했습니다. 트랜잭션 백업을 보존했습니다.'
            $rollbackException.Data['DuoForgeOriginalCode'] = Get-DuoForgeExceptionCode -Exception $originalException
            throw $rollbackException
        }
        throw $originalException
    }
    try { Remove-DuoForgeTransactionDirectoryInternal -TransactionDirectory $transactionDirectory }
    catch { Write-Verbose '커밋된 DuoForge 트랜잭션 정리를 다음 실행으로 미룹니다.' }
    return $result
}

function Add-DuoForgeRunEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Status,
        [System.Collections.IDictionary]$Data = [ordered]@{}
    )

    Add-DuoForgeJsonLine -Path (Join-Path $RunDirectory 'events.jsonl') -Value ([ordered]@{
        at = Get-DuoForgeUtcNow
        type = $Type
        status = $Status
        data = $Data
    })
}

function Set-DuoForgeRunStateInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$Status,
        [string]$LastCompletedStage,
        [int]$Round = 0
    )

    $statePath = Join-Path $RunDirectory 'state.json'
    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
    $terminal = @('COMPLETED', 'COMPLETED_PARTIAL', 'QUESTION_LIMIT_REACHED', 'SOURCE_DRIFT', 'FAILED_STAGE', 'CANCELLED')
    if ([string]$state.status -in $terminal) {
        throw (New-DuoForgeException -Code 'DF-STATE-TERMINAL' -Message "종료 상태 $($state.status)에서는 상태를 변경할 수 없습니다.")
    }

    $state.status = $Status
    $state.updatedAt = Get-DuoForgeUtcNow
    if (-not [string]::IsNullOrWhiteSpace($LastCompletedStage)) { $state.lastCompletedStage = $LastCompletedStage }
    if ($Round -gt 0) { $state.round = $Round }
    Write-DuoForgeJsonAtomic -Path $statePath -Value $state
    Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'STATE_CHANGED' -Status $Status -Data ([ordered]@{ lastCompletedStage = $state.lastCompletedStage; round = $state.round })
    return $state
}

function Get-DuoForgeSnapshotFilesFromValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$ValidationResult
    )

    $filesByPath = [ordered]@{}
    if ($ValidationResult.request.mode -eq 'shared-document') {
        $file = $ValidationResult.inputs.primary
        $filesByPath[[string]$file.path] = $file
    }
    elseif ($ValidationResult.request.mode -in @('document-merge', 'dual-document')) {
        foreach ($documentId in @('A', 'B')) {
            $primary = $ValidationResult.inputs.documents[$documentId].primary
            $filesByPath[[string]$primary.path] = $primary
            foreach ($contextFile in @($ValidationResult.inputs.documents[$documentId].context.files | Where-Object { $_.included })) {
                $record = ConvertTo-DuoForgeHashtable -InputObject $contextFile
                $filesByPath[[string]$record.path] = $record
            }
        }
    }
    return @($filesByPath.Values)
}

function New-DuoForgeSnapshotRoles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ValidationResult,
        [Parameter(Mandatory)][object[]]$SnapshotRecords
    )

    $bySource = @{}
    foreach ($record in $SnapshotRecords) {
        $bySource[[string]$record.sourcePath] = [string]$record.snapshotName
    }

    if ([string]$ValidationResult.request.mode -eq 'shared-document') {
        $primaryPath = [string]$ValidationResult.inputs.primary.path
        return [ordered]@{ shared = [ordered]@{ primary = $bySource[$primaryPath]; context = @() } }
    }

    $documentRoles = [ordered]@{}
    foreach ($documentId in @('A', 'B')) {
        $primaryPath = [string]$ValidationResult.inputs.documents[$documentId].primary.path
        $contextNames = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @($ValidationResult.inputs.documents[$documentId].context.files | Where-Object { $_.included })) {
            $path = [string]$item.path
            if ($path -ne $primaryPath -and $bySource.ContainsKey($path)) {
                $contextNames.Add($bySource[$path])
            }
        }
        $documentRoles[$documentId] = [ordered]@{ primary = $bySource[$primaryPath]; context = @($contextNames) }
    }
    return [ordered]@{ documents = $documentRoles }
}

function New-DuoForgeManifestInputReferencesInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Roles,
        [Parameter(Mandatory)][object[]]$SnapshotRecords
    )

    $byName = @{}
    foreach ($record in $SnapshotRecords) { $byName[[string]$record.snapshotName] = $record }
    $newReference = {
        param([string]$SnapshotName)
        if ([string]::IsNullOrWhiteSpace($SnapshotName) -or -not $byName.ContainsKey($SnapshotName)) {
            throw (New-DuoForgeException -Code 'DF-RUN-STORAGE-CONTRACT' -Message "입력 역할이 존재하지 않는 스냅샷을 참조합니다: $SnapshotName")
        }
        $record = $byName[$SnapshotName]
        return [ordered]@{ snapshotName = $SnapshotName; sha256 = [string]$record.snapshotHash }
    }.GetNewClosure()

    if ($Mode -eq 'shared-document') {
        return [ordered]@{ shared = & $newReference ([string]$Roles.shared.primary) }
    }
    return [ordered]@{
        documentA = & $newReference ([string]$Roles.documents.A.primary)
        documentB = & $newReference ([string]$Roles.documents.B.primary)
    }
}

function Assert-DuoForgeStoredContextPlanContractInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [Parameter(Mandatory)][ValidateSet('workflow-v1', 'workflow-v2')][string]$WorkflowVersion
    )

    $fail = {
        param([string]$Detail)
        throw (New-DuoForgeException -Code 'DF-RUN-STORAGE-CONTRACT' -Message "저장 실행의 문맥 계획 계약이 일치하지 않습니다: $Detail")
    }
    $planPath = Join-Path $RunDirectory 'inputs\context-plan.json'
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        $manifestPlan = Get-DuoForgeObjectValue -Object $Manifest -Name 'contextPlan'
        if ($manifestPlan -is [System.Collections.IDictionary]) { & $fail 'manifest에 문맥 계획이 있지만 context-plan.json이 없습니다.' }
        $plannedCount = [int](Get-DuoForgeObjectValue -Object (Get-DuoForgeObjectValue -Object $Manifest -Name 'executionPlan' -Default ([ordered]@{})) -Name 'contextBatchCount' -Default 0)
        if ($plannedCount -ne 0) { & $fail '문맥 계획 파일 없이 문맥 배치 호출이 선언되었습니다.' }
        return [ordered]@{ schemaVersion = 0; batchCount = 0; plan = $null }
    }

    $plan = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $planPath)
    $schemaVersion = [int](Get-DuoForgeObjectValue -Object $plan -Name 'schemaVersion' -Default 0)
    if ($schemaVersion -eq 1) {
        $batches = @((Get-DuoForgeObjectValue -Object $plan -Name 'batches' -Default @()))
        $seen = @{}
        $contextPackRoot = [System.IO.Path]::GetFullPath((Join-Path $RunDirectory 'inputs\context-packs')).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        for ($index = 0; $index -lt $batches.Count; $index++) {
            $batch = $batches[$index]
            $batchId = [string](Get-DuoForgeObjectValue -Object $batch -Name 'batchId' -Default '')
            if ([string]::IsNullOrWhiteSpace($batchId) -or $seen.ContainsKey($batchId)) { & $fail 'schema 1 문맥 계획에 비어 있거나 중복된 배치 ID가 있습니다.' }
            $seen[$batchId] = $true
            $batchPath = [string](Get-DuoForgeObjectValue -Object $batch -Name 'path' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($batchPath)) {
                $resolvedBatchPath = [System.IO.Path]::GetFullPath($batchPath)
                if (-not $resolvedBatchPath.StartsWith($contextPackRoot, [StringComparison]::OrdinalIgnoreCase) -or [System.IO.Path]::GetFileName($resolvedBatchPath) -cne "$batchId.md") { & $fail "schema 1 문맥 배치가 실행 내부의 고정 경로를 벗어났습니다: $batchId" }
                if (-not (Test-Path -LiteralPath $resolvedBatchPath -PathType Leaf)) { & $fail "schema 1 문맥 배치 파일이 없습니다: $batchId" }
                $recordedHash = [string](Get-DuoForgeObjectValue -Object $batch -Name 'sha256' -Default '')
                if ([string]::IsNullOrWhiteSpace($recordedHash) -or (Get-DuoForgeSha256 -Path $resolvedBatchPath) -ne $recordedHash) { & $fail "schema 1 문맥 배치 해시가 다릅니다: $batchId" }
                $recordedBytes = [long](Get-DuoForgeObjectValue -Object $batch -Name 'bytes' -Default ([long](Get-Item -LiteralPath $resolvedBatchPath).Length))
                if ([long](Get-Item -LiteralPath $resolvedBatchPath).Length -ne $recordedBytes) { & $fail "schema 1 문맥 배치 크기가 다릅니다: $batchId" }
            }
        }
        return [ordered]@{ schemaVersion = 1; batchCount = $batches.Count; plan = $plan }
    }
    if ($schemaVersion -ne 2) { & $fail "지원하지 않는 context-plan schemaVersion입니다: $schemaVersion" }
    if ($WorkflowVersion -ne 'workflow-v2') { & $fail 'context-plan schema 2는 workflow-v2에서만 사용할 수 있습니다.' }
    if ([string](Get-DuoForgeObjectValue -Object $plan -Name 'segmentationPolicy' -Default '') -ne 'semantic-markdown-v1' -or
        [string](Get-DuoForgeObjectValue -Object $plan -Name 'envelopePolicy' -Default '') -ne 'document-map-extractive-bridge-v1') { & $fail 'schema 2 분할 또는 봉투 정책이 다릅니다.' }

    $manifestPlan = Get-DuoForgeObjectValue -Object $Manifest -Name 'contextPlan'
    if ($manifestPlan -isnot [System.Collections.IDictionary]) { & $fail 'manifest에 contextPlan 복사본이 없습니다.' }
    if ((ConvertTo-Json $manifestPlan -Depth 100 -Compress) -cne (ConvertTo-Json $plan -Depth 100 -Compress)) { & $fail 'manifest와 context-plan.json의 계획이 다릅니다.' }
    $executionPlan = Get-DuoForgeObjectValue -Object $Manifest -Name 'executionPlan' -Default ([ordered]@{})
    $selectedBatchCount = [int](Get-DuoForgeObjectValue -Object $plan -Name 'selectedBatchCount' -Default -1)
    $batches = @((Get-DuoForgeObjectValue -Object $plan -Name 'batches' -Default @()))
    if ($selectedBatchCount -ne $batches.Count -or [int](Get-DuoForgeObjectValue -Object $executionPlan -Name 'contextBatchCount' -Default -1) -ne $batches.Count) { & $fail '계획·실행 계획·실제 문맥 배치 수가 다릅니다.' }
    $recordedMaximum = [long](Get-DuoForgeObjectValue -Object $plan -Name 'maxInputBytesPerCall' -Default 0)
    $expectedTargetCore = [long][Math]::Max(4096, [Math]::Floor($recordedMaximum * 0.20))
    $expectedMaximumPack = [long][Math]::Max(16384, [Math]::Floor($recordedMaximum * 0.62))
    $expectedBridge = [long][Math]::Max(512, [Math]::Min(2048, [Math]::Floor($recordedMaximum * 0.02)))
    $expectedMap = [long][Math]::Max(2048, [Math]::Min(8192, [Math]::Floor($recordedMaximum * 0.08)))
    if ($recordedMaximum -le 0 -or [long](Get-DuoForgeObjectValue -Object $plan -Name 'targetCoreBytes' -Default -1) -ne $expectedTargetCore -or
        [long](Get-DuoForgeObjectValue -Object $plan -Name 'targetBatchBytes' -Default -1) -ne $expectedTargetCore -or
        [long](Get-DuoForgeObjectValue -Object $plan -Name 'maximumPackBytes' -Default -1) -ne $expectedMaximumPack -or
        [long](Get-DuoForgeObjectValue -Object $plan -Name 'bridgeBytesPerSide' -Default -1) -ne $expectedBridge -or
        [long](Get-DuoForgeObjectValue -Object $plan -Name 'documentMapBytes' -Default -1) -ne $expectedMap -or $expectedMaximumPack -ge $recordedMaximum) {
        & $fail 'schema 2 문맥 계획의 호출·CORE·팩·브리지·지도 상한이 고정 정책과 다릅니다.'
    }
    $maximumEscapedCoreBytes = [long][Math]::Max(1024, $expectedMaximumPack - [Math]::Max(16384, $expectedMap + 8192))
    if (-not [bool](Get-DuoForgeObjectValue -Object $plan -Name 'enabled' -Default $false)) {
        if ($batches.Count -ne 0 -or $selectedBatchCount -ne 0) { & $fail '비활성 문맥 계획에 배치가 저장되었습니다.' }
        $originalSnapshots = @($Inventory.snapshots | Where-Object { [string]$_.snapshotName -match '^S\d{6}\.md$' })
        $originalBytes = 0L
        foreach ($snapshot in $originalSnapshots) { $originalBytes += [long]$snapshot.bytes }
        $shouldBeEnabled = $recordedMaximum -gt 0 -and $originalBytes -gt [long][Math]::Floor($recordedMaximum * 0.55)
        if ($shouldBeEnabled -or $recordedMaximum -le 0 -or
            [int]$plan.totalFiles -ne $originalSnapshots.Count -or [long]$plan.totalBytes -ne $originalBytes -or
            [int]$plan.requiredBatchCount -ne 0 -or [long]$plan.selectedBytes -ne $originalBytes -or [long]$plan.coreBytes -ne $originalBytes -or
            [long]$plan.overlapBytes -ne 0 -or [long]$plan.transmittedBytes -ne 0 -or [bool]$plan.requiresPartialConsent -or
            [string]$plan.completionStatus -ne 'COMPLETED' -or [double]$plan.actualFileCoveragePercent -ne 100.0 -or [double]$plan.actualByteCoveragePercent -ne 100.0 -or
            @((Get-DuoForgeObjectValue -Object $plan -Name 'sourceBlueprints' -Default @())).Count -ne 0 -or
            @((Get-DuoForgeObjectValue -Object $plan -Name 'candidateBlueprints' -Default @())).Count -ne 0 -or
            @((Get-DuoForgeObjectValue -Object $plan -Name 'selectedCandidateIds' -Default @())).Count -ne 0 -or
            @((Get-DuoForgeObjectValue -Object $plan -Name 'sources' -Default @())).Count -ne 0 -or
            @((Get-DuoForgeObjectValue -Object $plan -Name 'sourceCoverage' -Default @())).Count -ne 0 -or
            @((Get-DuoForgeObjectValue -Object $plan -Name 'documentCoverage' -Default @())).Count -ne 0 -or
            @((Get-DuoForgeObjectValue -Object $plan -Name 'omittedSectionIds' -Default @())).Count -ne 0 -or
            [long](Get-DuoForgeObjectValue -Object $plan -Name 'omittedBytes' -Default -1) -ne 0) {
            & $fail '비활성 schema 2 문맥 계획이 원본 스냅샷과 직접 경로 계약에 맞지 않습니다.'
        }
        return [ordered]@{ schemaVersion = 2; batchCount = 0; plan = $plan }
    }
    if ($batches.Count -lt 1) { & $fail '활성 문맥 계획에 실행 배치가 없습니다.' }

    $inventoryByName = @{}
    foreach ($record in @($Inventory.snapshots)) { $inventoryByName[[string]$record.snapshotName] = $record }
    $sources = @((Get-DuoForgeObjectValue -Object $plan -Name 'sources' -Default @()) | Sort-Object { [int]$_.sourceOrdinal })
    if ($sources.Count -ne [int](Get-DuoForgeObjectValue -Object $plan -Name 'totalFiles' -Default -1)) { & $fail '문맥 소스 수가 totalFiles와 다릅니다.' }
    $sourceBlueprints = @((Get-DuoForgeObjectValue -Object $plan -Name 'sourceBlueprints' -Default @()) | Sort-Object { [int]$_.sourceOrdinal })
    $expectedDocuments = @(Get-DuoForgePromptDocuments -RunDirectory $RunDirectory -Inventory $Inventory)
    if ($sources.Count -ne $expectedDocuments.Count -or $sourceBlueprints.Count -ne $expectedDocuments.Count) { & $fail '문맥 소스 집합이 inventory 역할의 원본 스냅샷 집합과 다릅니다.' }
    $actualSourceBytes = 0L
    for ($sourceIndex = 0; $sourceIndex -lt $expectedDocuments.Count; $sourceIndex++) {
        $expectedDocument = $expectedDocuments[$sourceIndex]
        $expectedRecord = $inventoryByName[[string]$expectedDocument.snapshotName]
        $expectedRole = [string]$expectedDocument.role
        $expectedDocumentId = if ($expectedRole -like 'shared-*') { 'brief' } elseif ($expectedRole -match '^document-([ab])-') { $Matches[1].ToUpperInvariant() } else { '' }
        $expectedSourceId = 'source-{0:D3}' -f ($sourceIndex + 1)
        $source = $sources[$sourceIndex]
        $blueprint = $sourceBlueprints[$sourceIndex]
        foreach ($candidateSource in @($source, $blueprint)) {
            if ([int]$candidateSource.sourceOrdinal -ne ($sourceIndex + 1) -or [string]$candidateSource.sourceId -cne $expectedSourceId -or
                [string]$candidateSource.sourceSha256 -cne [string]$expectedRecord.snapshotHash -or [long]$candidateSource.bytes -ne [long]$expectedRecord.bytes -or
                [string]$candidateSource.role -cne $expectedRole -or [string]$candidateSource.documentId -cne $expectedDocumentId) {
                & $fail "문맥 소스의 순서·해시·역할·문서 계보가 inventory와 다릅니다: $expectedSourceId"
            }
        }
        if ([string]$source.snapshotName -cne [string]$expectedDocument.snapshotName) { & $fail "문맥 소스의 스냅샷 계보가 inventory와 다릅니다: $expectedSourceId" }
        $actualSourceBytes += [long]$source.bytes
    }
    if ($actualSourceBytes -ne [long](Get-DuoForgeObjectValue -Object $plan -Name 'totalBytes' -Default -1)) { & $fail 'totalBytes가 inventory 원본 스냅샷 바이트 합계와 다릅니다.' }
    $sourceById = @{}
    $sectionById = @{}
    $sectionsBySource = @{}
    foreach ($source in $sources) {
        $sourceId = [string](Get-DuoForgeObjectValue -Object $source -Name 'sourceId' -Default '')
        $snapshotName = [string](Get-DuoForgeObjectValue -Object $source -Name 'snapshotName' -Default '')
        if ([string]::IsNullOrWhiteSpace($sourceId) -or $sourceById.ContainsKey($sourceId)) { & $fail '비어 있거나 중복된 sourceId가 있습니다.' }
        if (-not $inventoryByName.ContainsKey($snapshotName)) { & $fail "inventory에 없는 문맥 스냅샷입니다: $sourceId" }
        $inventoryRecord = $inventoryByName[$snapshotName]
        $snapshotPath = Join-Path $RunDirectory ("inputs\snapshots\{0}" -f $snapshotName)
        if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) { & $fail "문맥 스냅샷 파일이 없습니다: $sourceId" }
        $snapshotBytes = [System.IO.File]::ReadAllBytes($snapshotPath)
        if ($snapshotBytes.Length -ne [long]$source.bytes -or [long]$inventoryRecord.bytes -ne [long]$source.bytes -or
            [string]$inventoryRecord.snapshotHash -ne [string]$source.sourceSha256 -or
            (Get-DuoForgeSha256 -Bytes $snapshotBytes) -ne [string]$source.sourceSha256) { & $fail "문맥 소스 크기 또는 해시가 다릅니다: $sourceId" }

        $sourceSections = @((Get-DuoForgeObjectValue -Object $source -Name 'sections' -Default @()))
        $previousEnd = 0L
        for ($sectionIndex = 0; $sectionIndex -lt $sourceSections.Count; $sectionIndex++) {
            $section = $sourceSections[$sectionIndex]
            $sectionId = [string](Get-DuoForgeObjectValue -Object $section -Name 'sectionId' -Default '')
            $start = [long](Get-DuoForgeObjectValue -Object $section -Name 'byteStart' -Default -1)
            $end = [long](Get-DuoForgeObjectValue -Object $section -Name 'byteEnd' -Default -1)
            if ([string]::IsNullOrWhiteSpace($sectionId) -or $sectionById.ContainsKey($sectionId)) { & $fail '비어 있거나 중복된 sectionId가 있습니다.' }
            if ([int](Get-DuoForgeObjectValue -Object $section -Name 'order' -Default 0) -ne ($sectionIndex + 1)) { & $fail "섹션 순서가 연속적이지 않습니다: $sectionId" }
            if ($start -ne $previousEnd -or $end -le $start -or $end -gt $snapshotBytes.Length) { & $fail "섹션 바이트 범위에 gap, overlap 또는 범위 이탈이 있습니다: $sectionId" }
            if ([long](Get-DuoForgeObjectValue -Object $section -Name 'bytes' -Default -1) -ne ($end - $start)) { & $fail "섹션 바이트 합계가 다릅니다: $sectionId" }
            if ([int](Get-DuoForgeObjectValue -Object $section -Name 'lineStart' -Default 0) -lt 1 -or [int](Get-DuoForgeObjectValue -Object $section -Name 'lineEnd' -Default 0) -lt [int]$section.lineStart) { & $fail "섹션 줄 범위가 올바르지 않습니다: $sectionId" }
            $slice = Get-DuoForgeByteSliceInternal -Bytes $snapshotBytes -Start ([int]$start) -End ([int]$end)
            if ((Get-DuoForgeSha256 -Bytes $slice) -ne [string]$section.sha256) { & $fail "섹션 원본 범위 해시가 다릅니다: $sectionId" }
            $sectionById[$sectionId] = [ordered]@{ section = $section; sourceId = $sourceId; snapshotBytes = $snapshotBytes }
            $previousEnd = $end
        }
        if ($previousEnd -ne $snapshotBytes.Length) { & $fail "섹션이 문맥 소스 전체를 덮지 않습니다: $sourceId" }
        $structureMap = New-DuoForgeMarkdownStructureMapInternal `
            -Bytes $snapshotBytes `
            -SourceSha256 ([string]$source.sourceSha256) `
            -SourceId $sourceId `
            -MaximumSectionBytes ([int](Get-DuoForgeObjectValue -Object $plan -Name 'targetCoreBytes' -Default 0)) `
            -MaximumEscapedSectionBytes $maximumEscapedCoreBytes
        $sourceById[$sourceId] = [ordered]@{ source = $source; snapshotBytes = $snapshotBytes; snapshotName = $snapshotName; structureMap = $structureMap }
        $sectionsBySource[$sourceId] = $sourceSections
    }

    $candidateById = @{}
    $lastCandidateEndBySource = @{}
    foreach ($candidate in @((Get-DuoForgeObjectValue -Object $plan -Name 'candidateBlueprints' -Default @()))) {
        $candidateId = [string](Get-DuoForgeObjectValue -Object $candidate -Name 'candidateId' -Default '')
        $sourceId = [string](Get-DuoForgeObjectValue -Object $candidate -Name 'sourceId' -Default '')
        if ([string]::IsNullOrWhiteSpace($candidateId) -or $candidateById.ContainsKey($candidateId) -or -not $sourceById.ContainsKey($sourceId)) { & $fail '문맥 배치 청사진 ID 또는 소스 참조가 올바르지 않습니다.' }
        $candidateSections = @((Get-DuoForgeObjectValue -Object $candidate -Name 'sectionIds' -Default @()))
        if ($candidateSections.Count -lt 1) { & $fail "문맥 배치 청사진에 CORE 섹션이 없습니다: $candidateId" }
        $expectedStart = $null
        $expectedEnd = $null
        $previousSectionOrder = $null
        foreach ($sectionIdValue in $candidateSections) {
            $sectionId = [string]$sectionIdValue
            if (-not $sectionById.ContainsKey($sectionId) -or [string]$sectionById[$sectionId].sourceId -ne $sourceId) { & $fail "문맥 배치 청사진의 섹션 참조가 올바르지 않습니다: $candidateId" }
            $section = $sectionById[$sectionId].section
            if ($null -ne $previousSectionOrder -and [int]$section.order -ne ([int]$previousSectionOrder + 1)) { & $fail "문맥 배치 청사진의 CORE 섹션이 인접하지 않습니다: $candidateId" }
            if ($null -eq $expectedStart) { $expectedStart = [long]$section.byteStart }
            $expectedEnd = [long]$section.byteEnd
            $previousSectionOrder = [int]$section.order
        }
        if ([long]$candidate.byteStart -ne $expectedStart -or [long]$candidate.byteEnd -ne $expectedEnd -or [long]$candidate.coreBytes -ne ($expectedEnd - $expectedStart)) { & $fail "문맥 배치 청사진의 CORE 범위가 다릅니다: $candidateId" }
        $previousCandidateEnd = if ($lastCandidateEndBySource.ContainsKey($sourceId)) { [long]$lastCandidateEndBySource[$sourceId] } else { 0L }
        if ([long]$candidate.byteStart -ne $previousCandidateEnd) { & $fail "문맥 배치 청사진 사이에 gap 또는 overlap이 있습니다: $candidateId" }
        $lastCandidateEndBySource[$sourceId] = [long]$candidate.byteEnd
        $candidateById[$candidateId] = $candidate
    }
    foreach ($sourceId in $sourceById.Keys) {
        if (-not $lastCandidateEndBySource.ContainsKey($sourceId) -or [long]$lastCandidateEndBySource[$sourceId] -ne [long]$sourceById[$sourceId].source.bytes) { & $fail "문맥 배치 청사진이 소스 전체를 덮지 않습니다: $sourceId" }
    }
    if ($candidateById.Count -ne [int](Get-DuoForgeObjectValue -Object $plan -Name 'requiredBatchCount' -Default -1)) { & $fail 'requiredBatchCount가 배치 청사진 수와 다릅니다.' }

    $selectedCandidateIds = @((Get-DuoForgeObjectValue -Object $plan -Name 'selectedCandidateIds' -Default @()) | ForEach-Object { [string]$_ })
    if ($selectedCandidateIds.Count -ne $batches.Count -or @($selectedCandidateIds | Sort-Object -Unique).Count -ne $selectedCandidateIds.Count) { & $fail '선택된 배치 청사진 ID 수 또는 고유성이 올바르지 않습니다.' }
    $expectedSelectedCandidateIds = @(Select-DuoForgeBalancedBatchBlueprintsInternal -Blueprints @((Get-DuoForgeObjectValue -Object $plan -Name 'candidateBlueprints' -Default @())) -Capacity $selectedCandidateIds.Count | ForEach-Object { [string]$_.candidateId })
    if (($selectedCandidateIds -join "`n") -cne ($expectedSelectedCandidateIds -join "`n")) { & $fail '선택된 배치 청사진이 문서별 결정론적 균형 선택 정책과 다릅니다.' }
    $contextPackRoot = [System.IO.Path]::GetFullPath((Join-Path $RunDirectory 'inputs\context-packs')).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $batchCoreRangesBySource = @{}
    $coreTotal = 0L
    $overlapTotal = 0L
    $transmittedTotal = 0L
    $selectedSectionIds = @{}
    for ($batchIndex = 0; $batchIndex -lt $batches.Count; $batchIndex++) {
        $batch = $batches[$batchIndex]
        $expectedBatchId = 'batch-{0:D3}' -f ($batchIndex + 1)
        if ([string]$batch.batchId -cne $expectedBatchId) { & $fail "배치 ID가 연속적이지 않습니다: $expectedBatchId" }
        $candidateId = [string](Get-DuoForgeObjectValue -Object $batch -Name 'candidateId' -Default '')
        if ($candidateId -cne $selectedCandidateIds[$batchIndex] -or -not $candidateById.ContainsKey($candidateId)) { & $fail "배치 청사진 참조가 다릅니다: $expectedBatchId" }
        $candidate = $candidateById[$candidateId]
        $sourceId = [string](Get-DuoForgeObjectValue -Object $batch -Name 'sourceId' -Default '')
        if (-not $sourceById.ContainsKey($sourceId) -or [string]$candidate.sourceId -ne $sourceId) { & $fail "배치 소스 참조가 다릅니다: $expectedBatchId" }
        $relativePath = [string](Get-DuoForgeObjectValue -Object $batch -Name 'relativePath' -Default '')
        $normalizedRelativePath = $relativePath.Replace('/', '\')
        $expectedRelativePath = "inputs\context-packs\$expectedBatchId.md"
        if ([System.IO.Path]::IsPathRooted($relativePath) -or $normalizedRelativePath -cne $expectedRelativePath) { & $fail "배치 내부 경로가 올바르지 않습니다: $expectedBatchId" }
        $packPath = [System.IO.Path]::GetFullPath((Join-Path $RunDirectory $relativePath))
        if (-not $packPath.StartsWith($contextPackRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $packPath -PathType Leaf)) { & $fail "배치가 실행 내부에 없거나 파일이 없습니다: $expectedBatchId" }
        $packBytes = [System.IO.File]::ReadAllBytes($packPath)
        if ($packBytes.Length -ne [long]$batch.bytes -or $packBytes.Length -ne [long]$batch.transmittedBytes -or (Get-DuoForgeSha256 -Bytes $packBytes) -ne [string]$batch.sha256) { & $fail "배치 크기 또는 해시가 다릅니다: $expectedBatchId" }
        if ($packBytes.Length -gt [long](Get-DuoForgeObjectValue -Object $plan -Name 'maximumPackBytes' -Default 0)) { & $fail "배치가 계획된 팩 상한을 넘습니다: $expectedBatchId" }
        if ([string]$batch.snapshotName -ne [string]$sourceById[$sourceId].snapshotName -or [string]$batch.sourceSha256 -ne [string]$sourceById[$sourceId].source.sourceSha256) { & $fail "배치 스냅샷 계보가 다릅니다: $expectedBatchId" }
        if ((@($batch.sectionIds) -join "`n") -cne (@($candidate.sectionIds) -join "`n") -or [long]$batch.coreBytes -ne [long]$candidate.coreBytes) { & $fail "배치 CORE 섹션 또는 바이트 합계가 다릅니다: $expectedBatchId" }
        foreach ($sectionId in @($batch.sectionIds)) {
            if ($selectedSectionIds.ContainsKey([string]$sectionId)) { & $fail "CORE 섹션이 여러 배치에 중복되었습니다: $sectionId" }
            $selectedSectionIds[[string]$sectionId] = $true
        }

        $regions = Get-DuoForgeObjectValue -Object $batch -Name 'regions'
        if ($regions -isnot [System.Collections.IDictionary]) { & $fail "배치 영역 메타데이터가 없습니다: $expectedBatchId" }
        $runtimeSource = [ordered]@{
            sourceId = $sourceId
            snapshotName = [string]$sourceById[$sourceId].snapshotName
            role = [string]$sourceById[$sourceId].source.role
            documentId = [string]$sourceById[$sourceId].source.documentId
        }
        $batchBridgeBytes = [int](Get-DuoForgeObjectValue -Object $batch -Name 'bridgeBytesPerSide' -Default -1)
        $batchDocumentMapBytes = [int](Get-DuoForgeObjectValue -Object $batch -Name 'documentMapBytes' -Default -1)
        if ($batchBridgeBytes -lt 0 -or $batchBridgeBytes -gt [int]$plan.bridgeBytesPerSide -or
            $batchDocumentMapBytes -lt 256 -or $batchDocumentMapBytes -gt [int]$plan.documentMapBytes) {
            & $fail "배치별 브리지 또는 문서 지도 상한이 계획 범위를 벗어났습니다: $expectedBatchId"
        }
        $expectedEnvelope = New-DuoForgeContextPackEnvelopeInternal `
            -BatchId $expectedBatchId `
            -Source $runtimeSource `
            -StructureMap $sourceById[$sourceId].structureMap `
            -Candidate $candidate `
            -SourceBytes ([byte[]]$sourceById[$sourceId].snapshotBytes) `
            -BridgeBytesPerSide $batchBridgeBytes `
            -DocumentMapBytes $batchDocumentMapBytes
        if ([string]$expectedEnvelope.sha256 -ne [string]$batch.sha256 -or
            [long]$expectedEnvelope.bytes -ne [long]$batch.transmittedBytes -or
            [long]$expectedEnvelope.coreBytes -ne [long]$batch.coreBytes -or
            [long]$expectedEnvelope.overlapBytes -ne [long]$batch.overlapBytes -or
            [int]$expectedEnvelope.documentMapOmittedSectionCount -ne [int]$batch.documentMapOmittedSectionCount -or
            (ConvertTo-Json $expectedEnvelope.evidenceContract -Depth 10 -Compress) -cne (ConvertTo-Json (Get-DuoForgeObjectValue -Object $batch -Name 'evidenceContract') -Depth 10 -Compress) -or
            (ConvertTo-Json $expectedEnvelope.regions -Depth 30 -Compress) -cne (ConvertTo-Json $regions -Depth 30 -Compress)) {
            & $fail "배치가 스냅샷에서 결정론적으로 재구성한 문맥 봉투와 다릅니다: $expectedBatchId"
        }
        $regionNames = @('documentMap', 'before', 'core', 'after')
        if ((@($regions.Keys | ForEach-Object { [string]$_ } | Sort-Object) -join ',') -cne (@($regionNames | Sort-Object) -join ',')) { & $fail "배치 영역 집합이 다릅니다: $expectedBatchId" }
        $previousPackEnd = 0L
        $batchOverlap = 0L
        foreach ($regionName in $regionNames) {
            $region = $regions[$regionName]
            $packStart = [long]$region.packStartByte
            $packEnd = [long]$region.packEndByte
            if ($packStart -lt $previousPackEnd -or $packEnd -le $packStart -or $packEnd -gt $packBytes.Length -or [long]$region.packBytes -ne ($packEnd - $packStart)) { & $fail "배치 영역의 팩 범위가 올바르지 않습니다: $expectedBatchId/$regionName" }
            $regionBytes = Get-DuoForgeByteSliceInternal -Bytes $packBytes -Start ([int]$packStart) -End ([int]$packEnd)
            if ((Get-DuoForgeSha256 -Bytes $regionBytes) -ne [string]$region.sha256) { & $fail "배치 영역 해시가 다릅니다: $expectedBatchId/$regionName" }
            $expectedContextOnly = $regionName -ne 'core'
            if ([bool]$region.contextOnly -ne $expectedContextOnly -or [bool]$region.evidenceEligible -ne (-not $expectedContextOnly)) { & $fail "배치 영역의 근거 허용 경계가 다릅니다: $expectedBatchId/$regionName" }
            $sourceRanges = @((Get-DuoForgeObjectValue -Object $region -Name 'sourceRanges' -Default @()) | Where-Object { $null -ne $_ })
            if ($regionName -eq 'documentMap' -and $sourceRanges.Count -ne 0) { & $fail "DOCUMENT_MAP에 원본 근거 범위가 있습니다: $expectedBatchId" }
            if ($regionName -eq 'core' -and $sourceRanges.Count -ne 1) { & $fail "CORE 원본 범위가 하나가 아닙니다: $expectedBatchId" }
            $regionSourceBytes = 0L
            foreach ($range in $sourceRanges) {
                if ([string]$range.sourceId -ne $sourceId -or [string]$range.snapshotName -ne [string]$sourceById[$sourceId].snapshotName) { & $fail "영역이 다른 문맥 소스를 참조합니다: $expectedBatchId/$regionName" }
                $rangeStart = [long]$range.byteStart
                $rangeEnd = [long]$range.byteEnd
                if ($rangeStart -lt 0 -or $rangeEnd -le $rangeStart -or $rangeEnd -gt [long]$sourceById[$sourceId].source.bytes) { & $fail "영역 원본 범위가 올바르지 않습니다: $expectedBatchId/$regionName" }
                $sourceSlice = Get-DuoForgeByteSliceInternal -Bytes ([byte[]]$sourceById[$sourceId].snapshotBytes) -Start ([int]$rangeStart) -End ([int]$rangeEnd)
                if ((Get-DuoForgeSha256 -Bytes $sourceSlice) -ne [string]$range.sha256) { & $fail "영역 원본 범위 해시가 다릅니다: $expectedBatchId/$regionName" }
                $regionSourceBytes += $rangeEnd - $rangeStart
                if ($regionName -eq 'core' -and ($rangeStart -ne [long]$candidate.byteStart -or $rangeEnd -ne [long]$candidate.byteEnd)) { & $fail "CORE 원본 범위가 청사진과 다릅니다: $expectedBatchId" }
                if ($regionName -eq 'before' -and $rangeEnd -gt [long]$candidate.byteStart) { & $fail "BEFORE가 CORE와 겹칩니다: $expectedBatchId" }
                if ($regionName -eq 'after' -and $rangeStart -lt [long]$candidate.byteEnd) { & $fail "AFTER가 CORE와 겹칩니다: $expectedBatchId" }
            }
            if ([long]$region.bytes -ne $regionSourceBytes) { & $fail "영역 원본 바이트 합계가 다릅니다: $expectedBatchId/$regionName" }
            if ($regionName -in @('before', 'after')) { $batchOverlap += $regionSourceBytes }
            $previousPackEnd = $packEnd
        }
        if ([long]$batch.overlapBytes -ne $batchOverlap) { & $fail "배치 context-only 중복 바이트 합계가 다릅니다: $expectedBatchId" }
        if (-not $batchCoreRangesBySource.ContainsKey($sourceId)) { $batchCoreRangesBySource[$sourceId] = [System.Collections.Generic.List[object]]::new() }
        $batchCoreRangesBySource[$sourceId].Add([ordered]@{ start = [long]$candidate.byteStart; end = [long]$candidate.byteEnd })
        $coreTotal += [long]$batch.coreBytes
        $overlapTotal += [long]$batch.overlapBytes
        $transmittedTotal += [long]$batch.transmittedBytes
    }
    foreach ($sourceId in $batchCoreRangesBySource.Keys) {
        $previousEnd = -1L
        foreach ($range in @($batchCoreRangesBySource[$sourceId] | Sort-Object start)) {
            if ($previousEnd -gt [long]$range.start) { & $fail "배치 CORE 범위가 서로 겹칩니다: $sourceId" }
            $previousEnd = [long]$range.end
        }
    }
    if ($coreTotal -ne [long](Get-DuoForgeObjectValue -Object $plan -Name 'coreBytes' -Default -1) -or
        $coreTotal -ne [long](Get-DuoForgeObjectValue -Object $plan -Name 'selectedBytes' -Default -1) -or
        $overlapTotal -ne [long](Get-DuoForgeObjectValue -Object $plan -Name 'overlapBytes' -Default -1) -or
        $transmittedTotal -ne [long](Get-DuoForgeObjectValue -Object $plan -Name 'transmittedBytes' -Default -1)) { & $fail '계획의 CORE/context-only/전송 바이트 합계가 실제 배치와 다릅니다.' }

    $sourceCoverageRecords = @((Get-DuoForgeObjectValue -Object $plan -Name 'sourceCoverage' -Default @()))
    if ($sourceCoverageRecords.Count -ne $sourceById.Count) { & $fail '소스별 커버리지 행 수가 문맥 소스 수와 다릅니다.' }
    $sourceCoverageById = @{}
    $fullyCoveredSourceCount = 0
    foreach ($record in $sourceCoverageRecords) {
        $sourceId = [string](Get-DuoForgeObjectValue -Object $record -Name 'sourceId' -Default '')
        if ([string]::IsNullOrWhiteSpace($sourceId) -or $sourceCoverageById.ContainsKey($sourceId) -or -not $sourceById.ContainsKey($sourceId)) { & $fail '소스별 커버리지의 ID가 비어 있거나 중복되었거나 알려지지 않았습니다.' }
        $sourceCoverageById[$sourceId] = $record
    }
    $documentTotals = @{}
    foreach ($source in @($sources | Sort-Object { [int]$_.sourceOrdinal })) {
        $sourceId = [string]$source.sourceId
        $sourceCore = 0L
        foreach ($range in @((Get-DuoForgeObjectValue -Object $batchCoreRangesBySource -Name $sourceId -Default @()))) { $sourceCore += [long]$range.end - [long]$range.start }
        $sourceSections = @($sectionsBySource[$sourceId])
        $sourceSelectedIds = @($sourceSections | Where-Object { $selectedSectionIds.ContainsKey([string]$_.sectionId) } | ForEach-Object { [string]$_.sectionId })
        $sourceOmitted = @($sourceSections | Where-Object { -not $selectedSectionIds.ContainsKey([string]$_.sectionId) })
        $sourceOmittedBytes = 0L
        foreach ($section in $sourceOmitted) { $sourceOmittedBytes += [long]$section.bytes }
        $expectedCoverage = if ([long]$source.bytes -eq 0) { 100.0 } else { [Math]::Round(($sourceCore / [double][long]$source.bytes) * 100, 2) }
        if ($sourceCore -eq [long]$source.bytes) { $fullyCoveredSourceCount++ }
        $record = $sourceCoverageById[$sourceId]
        if ([string]$record.snapshotName -ne [string]$source.snapshotName -or [string]$record.documentId -ne [string]$source.documentId -or [string]$record.role -ne [string]$source.role -or
            [long]$record.totalBytes -ne [long]$source.bytes -or [long]$record.coreBytes -ne $sourceCore -or [Math]::Abs([double]$record.coveragePercent - $expectedCoverage) -gt 0.001 -or
            [int]$record.totalSections -ne $sourceSections.Count -or (@($record.selectedSectionIds) -join "`n") -cne ($sourceSelectedIds -join "`n") -or
            (@($record.omittedSectionIds) -join "`n") -cne (@($sourceOmitted | ForEach-Object { [string]$_.sectionId }) -join "`n") -or [long]$record.omittedBytes -ne $sourceOmittedBytes) {
            & $fail "소스별 CORE 커버리지가 실제 선택 범위와 다릅니다: $sourceId"
        }
        $documentId = [string]$source.documentId
        if (-not $documentTotals.ContainsKey($documentId)) { $documentTotals[$documentId] = [ordered]@{ total = 0L; core = 0L; sourceIds = [System.Collections.Generic.List[string]]::new() } }
        $documentTotals[$documentId].total += [long]$source.bytes
        $documentTotals[$documentId].core += $sourceCore
        $documentTotals[$documentId].sourceIds.Add($sourceId)
    }
    $documentCoverageRecords = @((Get-DuoForgeObjectValue -Object $plan -Name 'documentCoverage' -Default @()))
    if ($documentCoverageRecords.Count -ne $documentTotals.Count) { & $fail '문서별 커버리지 행 수가 문서 수와 다릅니다.' }
    $seenDocuments = @{}
    foreach ($record in $documentCoverageRecords) {
        $documentId = [string](Get-DuoForgeObjectValue -Object $record -Name 'documentId' -Default '')
        if ([string]::IsNullOrWhiteSpace($documentId) -or $seenDocuments.ContainsKey($documentId) -or -not $documentTotals.ContainsKey($documentId)) { & $fail '문서별 커버리지의 ID가 비어 있거나 중복되었거나 알려지지 않았습니다.' }
        $seenDocuments[$documentId] = $true
        $expected = $documentTotals[$documentId]
        $expectedCoverage = if ([long]$expected.total -eq 0) { 100.0 } else { [Math]::Round(([long]$expected.core / [double][long]$expected.total) * 100, 2) }
        if ([long]$record.totalBytes -ne [long]$expected.total -or [long]$record.coreBytes -ne [long]$expected.core -or
            [Math]::Abs([double]$record.coveragePercent - $expectedCoverage) -gt 0.001 -or
            (@($record.sourceIds) -join "`n") -cne (@($expected.sourceIds) -join "`n")) { & $fail "문서별 CORE 커버리지가 실제 선택 범위와 다릅니다: $documentId" }
    }

    $allSectionIds = @($sectionById.Keys | Sort-Object)
    $expectedOmitted = @($allSectionIds | Where-Object { -not $selectedSectionIds.ContainsKey($_) } | Sort-Object)
    $actualOmitted = @((Get-DuoForgeObjectValue -Object $plan -Name 'omittedSectionIds' -Default @()) | ForEach-Object { [string]$_ } | Sort-Object)
    $sourceOmittedTotal = 0L
    foreach ($record in $sourceCoverageRecords) { $sourceOmittedTotal += [long]$record.omittedBytes }
    if (($expectedOmitted -join "`n") -cne ($actualOmitted -join "`n") -or [long](Get-DuoForgeObjectValue -Object $plan -Name 'omittedBytes' -Default -1) -ne ([long]$plan.totalBytes - $coreTotal) -or $sourceOmittedTotal -ne ([long]$plan.totalBytes - $coreTotal)) { & $fail '누락 섹션 또는 누락 바이트가 CORE 차집합과 다릅니다.' }
    $expectedByteCoverage = if ([long]$plan.totalBytes -eq 0) { 100.0 } else { [Math]::Round(($coreTotal / [double][long]$plan.totalBytes) * 100, 2) }
    if ([Math]::Abs([double]$plan.actualByteCoveragePercent - $expectedByteCoverage) -gt 0.001) { & $fail '실제 바이트 커버리지가 CORE 합계와 다릅니다.' }
    $expectedFileCoverage = if ($sourceById.Count -eq 0) { 100.0 } else { [Math]::Round(($fullyCoveredSourceCount / [double]$sourceById.Count) * 100, 2) }
    if ([Math]::Abs([double]$plan.actualFileCoveragePercent - $expectedFileCoverage) -gt 0.001 -or
        [Math]::Abs([double]$plan.predictedFileCoveragePercent - $expectedFileCoverage) -gt 0.001 -or
        [Math]::Abs([double]$plan.predictedByteCoveragePercent - $expectedByteCoverage) -gt 0.001) { & $fail '예상·실제 파일 또는 바이트 커버리지가 CORE 선택과 다릅니다.' }
    $completionStatus = if ($coreTotal -eq [long]$plan.totalBytes) { 'COMPLETED' } else { 'COMPLETED_PARTIAL' }
    if ([string]$plan.completionStatus -ne $completionStatus) { & $fail '문맥 완료 상태가 CORE 커버리지와 다릅니다.' }
    if ([bool]$plan.requiresPartialConsent -ne ($completionStatus -eq 'COMPLETED_PARTIAL')) { & $fail '부분 분석 동의 필요 표지가 CORE 커버리지와 다릅니다.' }
    if ($completionStatus -eq 'COMPLETED_PARTIAL' -and -not [bool](Get-DuoForgeObjectValue -Object $Manifest -Name 'allowPartial' -Default $false)) { & $fail '부분 문맥 계획에 명시적 부분 분석 동의가 없습니다.' }
    return [ordered]@{ schemaVersion = 2; batchCount = $batches.Count; plan = $plan }
}

function Assert-DuoForgeGeneratedContextPromptContractInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ContextPlan
    )

    if ([int](Get-DuoForgeObjectValue -Object $ContextPlan -Name 'schemaVersion' -Default 1) -ne 2 -or
        -not [bool](Get-DuoForgeObjectValue -Object $ContextPlan -Name 'enabled' -Default $false)) {
        return [ordered]@{ promptCount = 0; maximumPromptBytes = 0L }
    }
    $batchCount = @($ContextPlan.batches).Count
    $contextBatchDocumentIds = @($ContextPlan.batches | ForEach-Object { [string]$_.documentId })
    $graph = New-DuoForgeStageGraph `
        -Mode ([string]$Manifest.mode) `
        -MaxRounds ([int]$Manifest.maxRounds) `
        -FirstSynthesizer ([string]$Manifest.firstSynthesizer) `
        -ContextBatchCount $batchCount `
        -ContextBatchDocumentIds $contextBatchDocumentIds `
        -WorkflowVersion workflow-v2
    $contextSteps = @($graph.steps | Where-Object { [string]$_.stage -eq 'context-batch-analysis' })
    if ($contextSteps.Count -ne ($batchCount * 2)) {
        throw (New-DuoForgeException -Code 'DF-CONTEXT-PROMPT-PLAN' -Message '문맥 배치 프롬프트 수가 실행 계획과 다릅니다.')
    }
    $maximumBytes = 0L
    foreach ($step in $contextSteps) {
        $prompt = New-DuoForgeStagePrompt -RunDirectory $RunDirectory -Graph $graph -Step $step
        $maximumBytes = [Math]::Max($maximumBytes, [long]$prompt.bytes)
    }
    return [ordered]@{ promptCount = $contextSteps.Count; maximumPromptBytes = $maximumBytes }
}

function Test-DuoForgeStoredStageGraphContractInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Steps,
        [Parameter(Mandatory)][ValidateSet('workflow-v1', 'workflow-v2')][string]$WorkflowVersion
    )

    $mode = [string](Get-DuoForgeObjectValue -Object $Manifest -Name 'mode' -Default '')
    $maxRounds = [int](Get-DuoForgeObjectValue -Object $Manifest -Name 'maxRounds' -Default 0)
    $firstSynthesizer = [string](Get-DuoForgeObjectValue -Object $Manifest -Name 'firstSynthesizer' -Default 'alternate')
    if ([string]::IsNullOrWhiteSpace($firstSynthesizer)) { $firstSynthesizer = 'alternate' }
    $contextPlanPath = Join-Path $RunDirectory 'inputs\context-plan.json'
    $contextBatchCount = if (Test-Path -LiteralPath $contextPlanPath -PathType Leaf) { @((Read-DuoForgeJson -Path $contextPlanPath).batches).Count } else { 0 }
    $contextBatchDocumentIds = @(Get-DuoForgeContextBatchDocumentIdsInternal -RunDirectory $RunDirectory)
    try {
        $expected = New-DuoForgeStageGraph -Mode $mode -MaxRounds $maxRounds -FirstSynthesizer $firstSynthesizer -ContextBatchCount $contextBatchCount -ContextBatchDocumentIds $contextBatchDocumentIds -WorkflowVersion $WorkflowVersion
    }
    catch {
        return [ordered]@{ valid = $false; detail = "manifest로 예상 단계 그래프를 만들 수 없습니다: $($_.Exception.Message)" }
    }

    if ([string](Get-DuoForgeObjectValue -Object $Steps -Name 'mode' -Default '') -ne $mode -or
        [int](Get-DuoForgeObjectValue -Object $Steps -Name 'maxRounds' -Default 0) -ne $maxRounds) {
        return [ordered]@{ valid = $false; detail = 'steps의 mode/maxRounds가 manifest와 다릅니다.' }
    }
    $actualSteps = @(Get-DuoForgeObjectValue -Object $Steps -Name 'steps' -Default @())
    if ($actualSteps.Count -ne @($expected.steps).Count) {
        return [ordered]@{ valid = $false; detail = "steps 단계 수가 예상 그래프와 다릅니다: expected=$(@($expected.steps).Count), actual=$($actualSteps.Count)" }
    }
    $actualByKey = @{}
    foreach ($step in $actualSteps) {
        $key = [string](Get-DuoForgeObjectValue -Object $step -Name 'stepKey' -Default '')
        if ([string]::IsNullOrWhiteSpace($key) -or $actualByKey.ContainsKey($key)) {
            return [ordered]@{ valid = $false; detail = "steps에 비어 있거나 중복된 stepKey가 있습니다: $key" }
        }
        $actualByKey[$key] = $step
    }
    foreach ($expectedStep in @($expected.steps)) {
        $key = [string]$expectedStep.stepKey
        if (-not $actualByKey.ContainsKey($key)) { return [ordered]@{ valid = $false; detail = "필수 단계가 없습니다: $key" } }
        $actual = $actualByKey[$key]
        if ([string]$actual.provider -ne [string]$expectedStep.provider -or [int]$actual.round -ne [int]$expectedStep.round -or [string]$actual.stage -ne [string]$expectedStep.stage) {
            return [ordered]@{ valid = $false; detail = "단계 정체성이 예상 그래프와 다릅니다: $key" }
        }
        $actualDependencies = @($actual.dependsOn | ForEach-Object { [string]$_ } | Sort-Object)
        $expectedDependencies = @($expectedStep.dependsOn | ForEach-Object { [string]$_ } | Sort-Object)
        if (($actualDependencies -join "`n") -cne ($expectedDependencies -join "`n")) {
            return [ordered]@{ valid = $false; detail = "단계 의존성이 예상 그래프와 다릅니다: $key" }
        }
        $actualContextBatchId = [string](Get-DuoForgeObjectValue -Object $actual -Name 'contextBatchId' -Default '')
        $expectedContextBatchId = [string](Get-DuoForgeObjectValue -Object $expectedStep -Name 'contextBatchId' -Default '')
        if ($actualContextBatchId -cne $expectedContextBatchId) {
            return [ordered]@{ valid = $false; detail = "단계 contextBatchId가 예상 그래프와 다릅니다: $key" }
        }
        if ($WorkflowVersion -eq 'workflow-v2') {
            if ([string](Get-DuoForgeObjectValue -Object $actual -Name 'performedBy' -Default '') -cne [string]$expectedStep.performedBy -or
                [string](Get-DuoForgeObjectValue -Object $actual -Name 'targetDocumentId' -Default '') -cne [string]$expectedStep.targetDocumentId) {
                return [ordered]@{ valid = $false; detail = "단계 작업자 또는 대상 계보가 예상 그래프와 다릅니다: $key" }
            }
            $actualSourcesValue = $null
            if ($actual.Contains('sourceDocumentIds')) { $actualSourcesValue = $actual['sourceDocumentIds'] }
            if ($null -eq $actualSourcesValue -or $actualSourcesValue -is [string] -or $actualSourcesValue -is [System.Collections.IDictionary] -or $actualSourcesValue -isnot [System.Collections.IEnumerable]) {
                return [ordered]@{ valid = $false; detail = "단계 sourceDocumentIds가 배열이 아닙니다: $key" }
            }
            $actualSources = @($actualSourcesValue | ForEach-Object { [string]$_ } | Sort-Object)
            $expectedSources = @($expectedStep.sourceDocumentIds | ForEach-Object { [string]$_ } | Sort-Object)
            if (($actualSources -join "`n") -cne ($expectedSources -join "`n")) {
                return [ordered]@{ valid = $false; detail = "단계 출처 계보가 예상 그래프와 다릅니다: $key" }
            }
        }
    }
    return [ordered]@{ valid = $true; detail = $null }
}

function Assert-DuoForgeRunStorageContractInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $fail = {
        param([string]$Detail)
        throw (New-DuoForgeException -Code 'DF-RUN-STORAGE-CONTRACT' -Message "저장 실행의 버전 계약이 일치하지 않습니다: $Detail")
    }
    $manifest = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json'))
    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'state.json'))
    $inventory = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'inputs\inventory.json'))
    $ledger = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $RunDirectory 'issues.json'))
    $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
    $manifestSchema = [int](Get-DuoForgeObjectValue -Object $manifest -Name 'schemaVersion' -Default 0)
    $stateSchema = [int](Get-DuoForgeObjectValue -Object $state -Name 'schemaVersion' -Default 0)
    $inventorySchema = [int](Get-DuoForgeObjectValue -Object $inventory -Name 'schemaVersion' -Default 0)
    $ledgerSchema = [int](Get-DuoForgeObjectValue -Object $ledger -Name 'schemaVersion' -Default 0)
    $contextContract = Assert-DuoForgeStoredContextPlanContractInternal -RunDirectory $RunDirectory -Manifest $manifest -Inventory $inventory -WorkflowVersion $workflowVersion
    if ([int]$contextContract.schemaVersion -eq 2) {
        $stateCoverage = Get-DuoForgeObjectValue -Object $state -Name 'coverage'
        if ($stateCoverage -isnot [System.Collections.IDictionary] -or
            [Math]::Abs([double]$stateCoverage.filePercent - [double]$contextContract.plan.actualFileCoveragePercent) -gt 0.001 -or
            [Math]::Abs([double]$stateCoverage.bytePercent - [double]$contextContract.plan.actualByteCoveragePercent) -gt 0.001 -or
            [string]$stateCoverage.completionStatus -ne [string]$contextContract.plan.completionStatus) {
            & $fail 'state.coverage가 context-plan의 실제 커버리지와 다릅니다.'
        }
    }
    $stepsPath = Join-Path $RunDirectory 'steps.json'
    $steps = if (Test-Path -LiteralPath $stepsPath -PathType Leaf) { ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $stepsPath) } else { $null }
    if ($null -ne $steps) {
        $graphContract = Test-DuoForgeStoredStageGraphContractInternal -RunDirectory $RunDirectory -Manifest $manifest -Steps $steps -WorkflowVersion $workflowVersion
        if (-not [bool]$graphContract.valid) { & $fail ([string]$graphContract.detail) }
    }

    if ($workflowVersion -eq 'workflow-v1') {
        if ($manifestSchema -notin @(1, 2)) { & $fail 'workflow-v1 manifest schemaVersion은 확인된 레거시 1 또는 2여야 합니다.' }
        if ($stateSchema -ne 1 -or $inventorySchema -ne 1 -or $ledgerSchema -ne 1) { & $fail 'workflow-v1은 state/inventory/ledger schemaVersion 1이어야 합니다.' }
        foreach ($component in @($state, $inventory, $ledger)) {
            $componentWorkflow = [string](Get-DuoForgeObjectValue -Object $component -Name 'workflowVersion' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($componentWorkflow) -and $componentWorkflow -ne 'workflow-v1') { & $fail 'workflow-v1 구성요소가 다른 workflowVersion을 선언합니다.' }
        }
        if ($null -ne $steps) {
            $stepsWorkflow = [string](Get-DuoForgeObjectValue -Object $steps -Name 'workflowVersion' -Default '')
            if ([int](Get-DuoForgeObjectValue -Object $steps -Name 'schemaVersion' -Default 0) -ne 1 -or (-not [string]::IsNullOrWhiteSpace($stepsWorkflow) -and $stepsWorkflow -ne 'workflow-v1')) { & $fail 'workflow-v1 steps 계약이 일치하지 않습니다.' }
        }
        return $true
    }

    if ($manifestSchema -eq 3) {
        if ($stateSchema -ne 1 -or $inventorySchema -ne 1 -or $ledgerSchema -ne 1) { & $fail '초기 workflow-v2 저장 세대는 state/inventory/ledger schemaVersion 1이어야 합니다.' }
        foreach ($component in @($state, $inventory, $ledger)) {
            $componentWorkflow = [string](Get-DuoForgeObjectValue -Object $component -Name 'workflowVersion' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($componentWorkflow) -and $componentWorkflow -ne 'workflow-v2') { & $fail '초기 workflow-v2 구성요소가 다른 workflowVersion을 선언합니다.' }
        }
        if ($null -ne $steps -and ([int]$steps.schemaVersion -ne 2 -or [string]$steps.workflowVersion -ne 'workflow-v2')) { & $fail '초기 workflow-v2 steps 계약이 일치하지 않습니다.' }
        return $true
    }

    if ($manifestSchema -ne 4 -or [string](Get-DuoForgeObjectValue -Object $manifest -Name 'storageContractVersion' -Default '') -ne 'duoforge-run-v2') { & $fail '신규 workflow-v2 manifest는 schemaVersion 4와 duoforge-run-v2 계약을 선언해야 합니다.' }
    $manifestPromptContract = [string](Get-DuoForgeObjectValue -Object $manifest -Name 'promptTemplateVersion' -Default '')
    $statePromptContract = [string](Get-DuoForgeObjectValue -Object $state -Name 'promptContractVersion' -Default '')
    if ($stateSchema -ne 2 -or
        [string](Get-DuoForgeObjectValue -Object $state -Name 'workflowVersion' -Default '') -ne 'workflow-v2' -or
        $manifestPromptContract -notin @('duoforge-stage-v3', 'duoforge-stage-v4') -or
        $statePromptContract -cne $manifestPromptContract) {
        & $fail 'state와 manifest의 workflow-v2 프롬프트 계약 세대가 일치하지 않습니다.'
    }
    if ($inventorySchema -ne 2 -or [string](Get-DuoForgeObjectValue -Object $inventory -Name 'workflowVersion' -Default '') -ne 'workflow-v2') { & $fail 'inventory 계약이 workflow-v2/schemaVersion 2가 아닙니다.' }
    if ($ledgerSchema -ne 2 -or [string](Get-DuoForgeObjectValue -Object $ledger -Name 'workflowVersion' -Default '') -ne 'workflow-v2' -or [int](Get-DuoForgeObjectValue -Object $ledger -Name 'issueSchemaVersion' -Default 0) -ne 2) { & $fail 'ledger 계약이 workflow-v2/schemaVersion 2/issueSchemaVersion 2가 아닙니다.' }
    try { $null = Assert-DuoForgeIssueLedgerV2Internal -Issues @($ledger.issues) }
    catch { & $fail $_.Exception.Message }
    if ([int](Get-DuoForgeObjectValue -Object $manifest -Name 'stateSchemaVersion' -Default 0) -ne 2 -or
        [int](Get-DuoForgeObjectValue -Object $manifest -Name 'inventorySchemaVersion' -Default 0) -ne 2 -or
        [int](Get-DuoForgeObjectValue -Object $manifest -Name 'issueLedgerSchemaVersion' -Default 0) -ne 2 -or
        [int](Get-DuoForgeObjectValue -Object $manifest -Name 'stageGraphSchemaVersion' -Default 0) -ne 2 -or
        [int](Get-DuoForgeObjectValue -Object $manifest -Name 'stageResultSchemaVersion' -Default 0) -ne 2) { & $fail 'manifest의 구성요소 버전 선언이 실제 저장 계약과 다릅니다.' }
    if ($null -ne $steps -and ([int]$steps.schemaVersion -ne 2 -or [string]$steps.workflowVersion -ne 'workflow-v2')) { & $fail 'workflow-v2 steps 계약이 일치하지 않습니다.' }

    $manifestRoles = Get-DuoForgeObjectValue -Object $manifest -Name 'roles'
    $inventoryRoles = Get-DuoForgeObjectValue -Object $inventory -Name 'roles'
    if ($null -eq $manifestRoles -or $null -eq $inventoryRoles -or (ConvertTo-Json $manifestRoles -Depth 30 -Compress) -cne (ConvertTo-Json $inventoryRoles -Depth 30 -Compress)) { & $fail 'manifest.roles와 inventory.roles가 다릅니다.' }
    $inputs = Get-DuoForgeObjectValue -Object $manifest -Name 'inputs'
    $expectedInputs = New-DuoForgeManifestInputReferencesInternal -Mode ([string]$manifest.mode) -Roles $inventoryRoles -SnapshotRecords @($inventory.snapshots)
    if ($null -eq $inputs -or (ConvertTo-Json $inputs -Depth 20 -Compress) -cne (ConvertTo-Json $expectedInputs -Depth 20 -Compress)) { & $fail 'manifest.inputs가 inventory의 주 입력 스냅샷과 다릅니다.' }
    return $true
}

function Add-DuoForgeEvidenceSnapshotRoleInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [Parameter(Mandatory)][ValidateSet('workflow-v1', 'workflow-v2')][string]$WorkflowVersion,
        [Parameter(Mandatory)][string]$SnapshotName
    )

    $roles = Get-DuoForgeObjectValue -Object $Inventory -Name 'roles'
    if ($roles -isnot [System.Collections.IDictionary]) {
        throw (New-DuoForgeException -Code 'DF-EVIDENCE-ROLE-CONTRACT' -Message '입력 인벤토리의 역할 계약이 올바르지 않습니다.')
    }
    if ([string]$Inventory.mode -eq 'shared-document') {
        $shared = Get-DuoForgeObjectValue -Object $roles -Name 'shared'
        if ($shared -isnot [System.Collections.IDictionary]) {
            throw (New-DuoForgeException -Code 'DF-EVIDENCE-ROLE-CONTRACT' -Message '공동 문서 역할을 찾을 수 없습니다.')
        }
        $shared.context = @($shared.context | Where-Object { [string]$_ -ne $SnapshotName }) + @($SnapshotName)
        return
    }
    if ($WorkflowVersion -eq 'workflow-v2') {
        $documents = Get-DuoForgeObjectValue -Object $roles -Name 'documents'
        if ($documents -isnot [System.Collections.IDictionary]) {
            throw (New-DuoForgeException -Code 'DF-EVIDENCE-ROLE-CONTRACT' -Message 'workflow-v2 문서 A/B 역할을 찾을 수 없습니다.')
        }
        foreach ($documentId in @('A', 'B')) {
            $documentRole = Get-DuoForgeObjectValue -Object $documents -Name $documentId
            if ($documentRole -isnot [System.Collections.IDictionary]) {
                throw (New-DuoForgeException -Code 'DF-EVIDENCE-ROLE-CONTRACT' -Message "workflow-v2 문서 $documentId 역할을 찾을 수 없습니다.")
            }
            $documentRole.context = @($documentRole.context | Where-Object { [string]$_ -ne $SnapshotName }) + @($SnapshotName)
        }
        return
    }
    foreach ($provider in @('codex', 'claude')) {
        $providerRole = Get-DuoForgeObjectValue -Object $roles -Name $provider
        if ($providerRole -isnot [System.Collections.IDictionary]) {
            throw (New-DuoForgeException -Code 'DF-EVIDENCE-ROLE-CONTRACT' -Message "workflow-v1 $provider 역할을 찾을 수 없습니다.")
        }
        $providerRole.context = @($providerRole.context | Where-Object { [string]$_ -ne $SnapshotName }) + @($SnapshotName)
    }
}

function New-DuoForgeRunInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$ValidationResult
    )

    $runId = ''
    $runDirectory = ''
    try {
        if (-not [bool]$ValidationResult.valid) {
            throw (New-DuoForgeException -Code 'DF-RUN-INVALID' -Message '검증에 실패한 요청으로 실행을 만들 수 없습니다.')
        }

    $requestSelections = Get-DuoForgeObjectValue -Object $ValidationResult.request -Name 'providerSelections'
    $null = Assert-DuoForgeProviderSelectionsInternal -Selections $requestSelections

    $resultsRoot = [string]$ValidationResult.resultsRoot
    [System.IO.Directory]::CreateDirectory($resultsRoot) | Out-Null
    $runId = New-DuoForgeRunId -ResultsRoot $resultsRoot
    $runDirectory = Join-Path $resultsRoot $runId
    [System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null

    return Invoke-WithDuoForgeRunLock -RunDirectory $runDirectory -ScriptBlock {
        foreach ($relativeDirectory in @(
            'inputs\snapshots', 'inputs\context-packs', 'rounds', 'decisions', 'control', 'final'
        )) {
            [System.IO.Directory]::CreateDirectory((Join-Path $runDirectory $relativeDirectory)) | Out-Null
        }

        $now = Get-DuoForgeUtcNow
        $request = $ValidationResult.request
        if ([int](Get-DuoForgeObjectValue -Object $ValidationResult.contextPlan -Name 'schemaVersion' -Default 0) -ne 2) {
            throw (New-DuoForgeException -Code 'DF-CONTEXT-PLAN-SCHEMA' -Message '신규 실행은 context-plan schemaVersion 2로만 만들 수 있습니다.')
        }
        $state = [ordered]@{
            schemaVersion = 2
            workflowVersion = 'workflow-v2'
            promptContractVersion = 'duoforge-stage-v4'
            runId = $runId
            mode = $request.mode
            documentType = $request.documentType
            round = 0
            maxRounds = $request.maxRounds
            status = 'CREATED'
            lastCompletedStage = $null
            openIssues = @()
            blockingIssues = @()
            answeredIssues = @()
            decisionReviewCycle = 0
            maxDecisionReviewCycles = 3
            decisionReviewLimitReached = $false
            coverage = $null
            runtimeSeconds = 0.0
            runtimeExtensionMinutes = 0
            runtimeExtensionGrantCount = 0
            schemaRepairGrantCount = 0
            schemaRepairPreparedAt = $null
            createdAt = $now
            updatedAt = $now
        }
        Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'state.json') -Value $state
        Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'issues.json') -Value ([ordered]@{ schemaVersion = 2; workflowVersion = 'workflow-v2'; issueSchemaVersion = 2; issues = @() })
        Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'decisions\pending.json') -Value ([ordered]@{ schemaVersion = 1; questions = @() })
        Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'RUN_CREATED' -Status 'CREATED' -Data ([ordered]@{ mode = $request.mode })

        $state = Set-DuoForgeRunStateInternal -RunDirectory $runDirectory -Status 'PREFLIGHT'
        $sourceFiles = @(Get-DuoForgeSnapshotFilesFromValidation -ValidationResult $ValidationResult)
        $snapshotRecords = @(New-DuoForgeFileSnapshots -DestinationDirectory (Join-Path $runDirectory 'inputs\snapshots') -Files $sourceFiles)
        $inventory = [ordered]@{
            schemaVersion = 2
            workflowVersion = 'workflow-v2'
            generatedAt = Get-DuoForgeUtcNow
            mode = $request.mode
            sourceFiles = $sourceFiles
            snapshots = $snapshotRecords
            roles = New-DuoForgeSnapshotRoles -ValidationResult $ValidationResult -SnapshotRecords $snapshotRecords
        }
        Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'inputs\inventory.json') -Value $inventory
        $contextPlan = New-DuoForgeContextBatchFilesInternal -RunDirectory $runDirectory -Inventory $inventory -Plan $ValidationResult.contextPlan
        Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'inputs\context-plan.json') -Value $contextPlan
        $state.coverage = [ordered]@{
            filePercent = [double]$contextPlan.actualFileCoveragePercent
            bytePercent = [double]$contextPlan.actualByteCoveragePercent
            completionStatus = [string]$contextPlan.completionStatus
        }
        Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'state.json') -Value $state

        $manifestInputs = New-DuoForgeManifestInputReferencesInternal -Mode ([string]$request.mode) -Roles $inventory.roles -SnapshotRecords $snapshotRecords
        $manifest = [ordered]@{
            schemaVersion = 4
            workflowVersion = 'workflow-v2'
            storageContractVersion = 'duoforge-run-v2'
            stateSchemaVersion = 2
            inventorySchemaVersion = 2
            issueLedgerSchemaVersion = 2
            stageGraphSchemaVersion = 2
            stageResultSchemaVersion = 2
            runId = $runId
            name = if ([string]::IsNullOrWhiteSpace([string]$request.name)) { [System.IO.Path]::GetFileNameWithoutExtension([string]$sourceFiles[0].path) } else { $request.name }
            mode = $request.mode
            createdAt = $now
            updatedAt = Get-DuoForgeUtcNow
            resultsRoot = $resultsRoot
            runDirectory = $runDirectory
            documentType = $request.documentType
            maxRounds = $request.maxRounds
            firstSynthesizer = $request.firstSynthesizer
            pauseAfterRound = [bool](Get-DuoForgeObjectValue -Object $request -Name 'pauseAfterRound' -Default $false)
            allowPartial = [bool](Get-DuoForgeObjectValue -Object $request -Name 'allowPartial' -Default $false)
            subscriptionOnly = $true
            promptTemplateVersion = 'duoforge-stage-v4'
            artifactVisibilityPolicy = 'transitive-dependencies-v1'
            providers = [ordered]@{
                codex = [ordered]@{ version = $ValidationResult.doctor.providers.codex.version; authType = $ValidationResult.doctor.providers.codex.authType }
                claude = [ordered]@{ version = $ValidationResult.doctor.providers.claude.version; authType = $ValidationResult.doctor.providers.claude.authType }
            }
            providerSelections = ConvertTo-DuoForgeHashtable -InputObject $requestSelections
            executionPlan = $ValidationResult.executionPlan
            contextPlan = $contextPlan
            inputs = $manifestInputs
            roles = ConvertTo-DuoForgeHashtable -InputObject $inventory.roles
            maxWallClockMinutes = [int](Get-DuoForgeConfig).limits.maxWallClockMinutes
            inputSnapshotHashes = @($snapshotRecords | ForEach-Object { $_.snapshotHash })
        }
        Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'manifest.json') -Value $manifest
        $state = Set-DuoForgeRunStateInternal -RunDirectory $runDirectory -Status 'SNAPSHOTTED' -LastCompletedStage 'input-snapshot'
        $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $runDirectory
        $null = Assert-DuoForgeGeneratedContextPromptContractInternal -RunDirectory $runDirectory -Manifest $manifest -ContextPlan $contextPlan

        return [ordered]@{
            runId = $runId
            runDirectory = $runDirectory
            status = $state.status
            manifest = $manifest
        }
        }
    }
    catch {
        if (-not $_.Exception.Data.Contains('DuoForgeDiagnosticId')) {
            $code = if ($_.Exception.Data.Contains('DuoForgeCode')) { [string]$_.Exception.Data['DuoForgeCode'] } else { 'DF-RUN-CREATE' }
            $runContext = [ordered]@{ runId = $runId; workflowVersion = 'workflow-v2'; status = 'CREATED'; lastCompletedStage = '' }
            $doctor = Get-DuoForgeObjectValue -Object $ValidationResult -Name 'doctor'
            $providers = Get-DuoForgeObjectValue -Object $doctor -Name 'providers'
            $codexProvider = Get-DuoForgeObjectValue -Object $providers -Name 'codex'
            $claudeProvider = Get-DuoForgeObjectValue -Object $providers -Name 'claude'
            $providerVersions = [ordered]@{
                codex = [string](Get-DuoForgeObjectValue -Object $codexProvider -Name 'version')
                claude = [string](Get-DuoForgeObjectValue -Object $claudeProvider -Name 'version')
            }
            $diagnostic = Write-DuoForgeDiagnosticInternal -RunDirectory $runDirectory -Code $code -Category 'run-create' -Phase 'run-create' -Scope 'run' -Run $runContext -ProviderVersions $providerVersions -ErrorRecord $_
            Add-DuoForgeDiagnosticMetadataToExceptionInternal -Exception $_.Exception -Diagnostic $diagnostic
        }
        throw
    }
}

function Get-DuoForgeRunInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    if ([string]::IsNullOrWhiteSpace($ResultsRoot)) { $ResultsRoot = (Get-DuoForgeConfig).resultsRoot }
    $runDirectory = Join-Path (Resolve-DuoForgePathInternal -Path $ResultsRoot -ExpectedType Directory) $RunId
    if (-not (Test-Path -LiteralPath $runDirectory -PathType Container)) {
        throw (New-DuoForgeException -Code 'DF-RUN-NOT-FOUND' -Message "실행을 찾을 수 없습니다: $RunId")
    }
    return [ordered]@{
        runDirectory = $runDirectory
        state = Read-DuoForgeJson -Path (Join-Path $runDirectory 'state.json')
        manifest = Read-DuoForgeJson -Path (Join-Path $runDirectory 'manifest.json')
        issues = Read-DuoForgeJson -Path (Join-Path $runDirectory 'issues.json')
    }
}

function Get-DuoForgeRunsInternal {
    [CmdletBinding()]
    param([string]$ResultsRoot)

    if ([string]::IsNullOrWhiteSpace($ResultsRoot)) { $ResultsRoot = (Get-DuoForgeConfig).resultsRoot }
    $fullRoot = Resolve-DuoForgePathInternal -Path $ResultsRoot -ExpectedType Directory -AllowMissing
    if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) { return @() }

    $runs = foreach ($directory in Get-ChildItem -LiteralPath $fullRoot -Directory -Filter 'run-*' -Force) {
        $statePath = Join-Path $directory.FullName 'state.json'
        $manifestPath = Join-Path $directory.FullName 'manifest.json'
        if ((Test-Path -LiteralPath $statePath -PathType Leaf) -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            try {
                $state = Read-DuoForgeJson -Path $statePath
                $manifest = Read-DuoForgeJson -Path $manifestPath
                [ordered]@{
                    runId = $state.runId
                    name = $manifest.name
                    mode = $state.mode
                    status = $state.status
                    updatedAt = $state.updatedAt
                    runDirectory = $directory.FullName
                }
            }
            catch { }
        }
    }
    return @($runs | Sort-Object updatedAt -Descending)
}
