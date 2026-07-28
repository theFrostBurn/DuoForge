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
    catch { Write-Verbose ("커밋된 DuoForge 트랜잭션 정리를 다음 실행으로 미룹니다: {0}" -f $_.Exception.Message) }
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
    $terminal = @('COMPLETED', 'COMPLETED_PARTIAL', 'SOURCE_DRIFT', 'FAILED_STAGE', 'CANCELLED')
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
    try {
        $expected = New-DuoForgeStageGraph -Mode $mode -MaxRounds $maxRounds -FirstSynthesizer $firstSynthesizer -ContextBatchCount $contextBatchCount -WorkflowVersion $WorkflowVersion
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
    if ($stateSchema -ne 2 -or [string](Get-DuoForgeObjectValue -Object $state -Name 'workflowVersion' -Default '') -ne 'workflow-v2' -or [string](Get-DuoForgeObjectValue -Object $state -Name 'promptContractVersion' -Default '') -ne 'duoforge-stage-v3') { & $fail 'state 계약이 workflow-v2/schemaVersion 2/duoforge-stage-v3가 아닙니다.' }
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
            'inputs\snapshots', 'inputs\context-packs', 'rounds', 'decisions', 'control', 'logs', 'final'
        )) {
            [System.IO.Directory]::CreateDirectory((Join-Path $runDirectory $relativeDirectory)) | Out-Null
        }

        $now = Get-DuoForgeUtcNow
        $request = $ValidationResult.request
        $state = [ordered]@{
            schemaVersion = 2
            workflowVersion = 'workflow-v2'
            promptContractVersion = 'duoforge-stage-v3'
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
            coverage = $null
            runtimeSeconds = 0.0
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
            promptTemplateVersion = 'duoforge-stage-v3'
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

        return [ordered]@{
            runId = $runId
            runDirectory = $runDirectory
            status = $state.status
            manifest = $manifest
        }
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
