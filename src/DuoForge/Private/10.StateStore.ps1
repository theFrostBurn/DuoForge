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
        return & $ScriptBlock
    }
    finally {
        $lockStream.Dispose()
    }
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
    elseif ($ValidationResult.request.mode -eq 'dual-document') {
        foreach ($side in @('codex', 'claude')) {
            $primary = $ValidationResult.inputs[$side].primary
            $filesByPath[[string]$primary.path] = $primary
            foreach ($contextFile in @($ValidationResult.inputs[$side].context.files | Where-Object { $_.included })) {
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

    $roles = [ordered]@{}
    foreach ($side in @('codex', 'claude')) {
        $primaryPath = [string]$ValidationResult.inputs[$side].primary.path
        $contextNames = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @($ValidationResult.inputs[$side].context.files | Where-Object { $_.included })) {
            $path = [string]$item.path
            if ($path -ne $primaryPath -and $bySource.ContainsKey($path)) {
                $contextNames.Add($bySource[$path])
            }
        }
        $roles[$side] = [ordered]@{ primary = $bySource[$primaryPath]; context = @($contextNames) }
    }
    return $roles
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
            'inputs\snapshots', 'inputs\context-packs', 'rounds', 'decisions', 'logs', 'final'
        )) {
            [System.IO.Directory]::CreateDirectory((Join-Path $runDirectory $relativeDirectory)) | Out-Null
        }

        $now = Get-DuoForgeUtcNow
        $request = $ValidationResult.request
        $state = [ordered]@{
            schemaVersion = 1
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
            createdAt = $now
            updatedAt = $now
        }
        Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'state.json') -Value $state
        Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'issues.json') -Value ([ordered]@{ schemaVersion = 1; issues = @() })
        Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'decisions\pending.json') -Value ([ordered]@{ schemaVersion = 1; questions = @() })
        Add-DuoForgeRunEvent -RunDirectory $runDirectory -Type 'RUN_CREATED' -Status 'CREATED' -Data ([ordered]@{ mode = $request.mode })

        $state = Set-DuoForgeRunStateInternal -RunDirectory $runDirectory -Status 'PREFLIGHT'
        $sourceFiles = @(Get-DuoForgeSnapshotFilesFromValidation -ValidationResult $ValidationResult)
        $snapshotRecords = @(New-DuoForgeFileSnapshots -DestinationDirectory (Join-Path $runDirectory 'inputs\snapshots') -Files $sourceFiles)
        $inventory = [ordered]@{
            schemaVersion = 1
            generatedAt = Get-DuoForgeUtcNow
            mode = $request.mode
            sourceFiles = $sourceFiles
            snapshots = $snapshotRecords
            roles = New-DuoForgeSnapshotRoles -ValidationResult $ValidationResult -SnapshotRecords $snapshotRecords
        }
        Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'inputs\inventory.json') -Value $inventory

        $manifest = [ordered]@{
            schemaVersion = 2
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
            subscriptionOnly = $true
            promptTemplateVersion = 'duoforge-stage-v1'
            providers = [ordered]@{
                codex = [ordered]@{ version = $ValidationResult.doctor.providers.codex.version; authType = $ValidationResult.doctor.providers.codex.authType }
                claude = [ordered]@{ version = $ValidationResult.doctor.providers.claude.version; authType = $ValidationResult.doctor.providers.claude.authType }
            }
            providerSelections = ConvertTo-DuoForgeHashtable -InputObject $requestSelections
            executionPlan = $ValidationResult.executionPlan
            inputSnapshotHashes = @($snapshotRecords | ForEach-Object { $_.snapshotHash })
        }
        Write-DuoForgeJsonAtomic -Path (Join-Path $runDirectory 'manifest.json') -Value $manifest
        $state = Set-DuoForgeRunStateInternal -RunDirectory $runDirectory -Status 'SNAPSHOTTED' -LastCompletedStage 'input-snapshot'

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
