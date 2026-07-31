function Resolve-DuoForgeRecoveryPathInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$StoredPath
    )

    $marker = "\$RunId\"
    $index = $StoredPath.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase)
    if ($index -lt 0) { throw (New-DuoForgeException -Code 'DF-RECOVERY-PATH' -Message '복구 이력 경로가 대상 실행을 가리키지 않습니다.') }
    $relative = $StoredPath.Substring($index + $marker.Length)
    return Join-Path $RunDirectory $relative
}

function Get-DuoForgeRecoveryArtifactHistoryInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Step)

    $records = @($Step.history | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $_ -Name 'previousArtifactHash' -Default ''))
    })
    $userDecision = @($records | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'reason' -Default '') -eq 'USER_DECISION_CHANGED' } | Select-Object -First 1)
    if ($userDecision.Count -eq 1) { return [ordered]@{ action = 'RERUN'; record = $userDecision[0] } }
    $restorable = @($records | Where-Object {
        [string](Get-DuoForgeObjectValue -Object $_ -Name 'previousStatus' -Default '') -eq 'COMMITTED' -and
        [string](Get-DuoForgeObjectValue -Object $_ -Name 'reason' -Default '') -in @(
            'CORRUPTED_OR_MISSING', 'ARTIFACT_MISSING', 'ARTIFACT_HASH_MISMATCH', 'ARTIFACT_SCHEMA_INVALID', 'DEPENDS_ON_INVALID_ARTIFACT'
        )
    } | Select-Object -First 1)
    if ($restorable.Count -eq 1) { return [ordered]@{ action = 'RESTORE'; record = $restorable[0] } }
    throw (New-DuoForgeException -Code 'DF-RECOVERY-CLASSIFICATION' -Message '단계 복구 분류를 안전하게 결정할 수 없습니다.')
}

function Invoke-DuoForgeCompositeRunRecoveryInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [switch]$Apply
    )

    $directory = [IO.Path]::GetFullPath($RunDirectory)
    $directoryName = Split-Path -Leaf $directory
    if ($directoryName -ne $ExpectedRunId -and -not $directoryName.StartsWith("$ExpectedRunId-", [StringComparison]::Ordinal)) { throw (New-DuoForgeException -Code 'DF-RECOVERY-RUN-ID' -Message '복구 대상 실행 ID가 예상값과 다릅니다.') }
    $manifest = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $directory 'manifest.json'))
    if ([string](Get-DuoForgeObjectValue -Object $manifest -Name 'runId' -Default '') -ne $ExpectedRunId) { throw (New-DuoForgeException -Code 'DF-RECOVERY-RUN-ID' -Message '매니페스트 실행 ID가 예상값과 다릅니다.') }
    if ((Get-DuoForgeWorkflowVersionInternal -Manifest $manifest) -ne 'workflow-v2') { throw (New-DuoForgeException -Code 'DF-RECOVERY-WORKFLOW' -Message '이 복구는 workflow-v2 실행에만 적용할 수 있습니다.') }

    $stepsPath = Join-Path $directory 'steps.json'
    $statePath = Join-Path $directory 'state.json'
    $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $stepsPath)
    $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
    if (@($graph.steps).Count -ne 14) { throw (New-DuoForgeException -Code 'DF-RECOVERY-SHAPE' -Message '복구 대상 단계 수가 예상값과 다릅니다.') }

    $restore = [System.Collections.Generic.List[object]]::new()
    $rerun = [System.Collections.Generic.List[object]]::new()
    $adsMigrations = [System.Collections.Generic.List[object]]::new()
    foreach ($step in @($graph.steps)) {
        if (-not $step.Contains('totalAttemptCount')) { $step.totalAttemptCount = [int](Get-DuoForgeObjectValue -Object $step -Name 'attemptCount' -Default 0) }
        if (-not $step.Contains('inputGeneration')) { $step.inputGeneration = 1 }
        $classification = Get-DuoForgeRecoveryArtifactHistoryInternal -Step $step
        $record = $classification.record
        $expectedHash = [string]$record.previousArtifactHash
        $canonicalPath = Join-Path $directory ("rounds\round-{0:D2}\raw-redacted\{1}.json" -f [int]$step.round, [string]$step.stepKey)
        if (-not (Test-Path -LiteralPath $canonicalPath -PathType Leaf) -or (Get-DuoForgeSha256 -Path $canonicalPath) -ne $expectedHash) {
            throw (New-DuoForgeException -Code 'DF-RECOVERY-CANONICAL-HASH' -Message '정규 단계 산출물의 복구 해시가 일치하지 않습니다.')
        }

        $storedPreservedPath = [string]$record.preservedPath
        $preservedPath = Resolve-DuoForgeRecoveryPathInternal -RunDirectory $directory -RunId $ExpectedRunId -StoredPath $storedPreservedPath
        $isAds = $false
        $match = [regex]::Match($preservedPath, '^(?<base>[A-Za-z]:.*):(?<stream>[^\\/:]+)$')
        if ($match.Success -and (Test-Path -LiteralPath $match.Groups['base'].Value -PathType Leaf)) {
            $preservedPath = '{0}:{1}' -f $match.Groups['base'].Value, $match.Groups['stream'].Value
            $isAds = $true
        }
        elseif (-not (Test-Path -LiteralPath $preservedPath -PathType Leaf)) {
            if (-not $match.Success) {
                throw (New-DuoForgeException -Code 'DF-RECOVERY-PRESERVED-PATH' -Message '보존된 단계 산출물을 찾을 수 없습니다.')
            }
            throw (New-DuoForgeException -Code 'DF-RECOVERY-PRESERVED-PATH' -Message '보존된 단계 산출물의 base 파일을 찾을 수 없습니다.')
        }
        if ((Get-DuoForgeSha256 -Path $preservedPath) -ne $expectedHash) { throw (New-DuoForgeException -Code 'DF-RECOVERY-PRESERVED-HASH' -Message '보존된 단계 산출물의 복구 해시가 일치하지 않습니다.') }
        try { $null = Read-DuoForgeJson -Path $preservedPath } catch { throw (New-DuoForgeException -Code 'DF-RECOVERY-PRESERVED-JSON' -Message '보존된 단계 산출물 JSON을 검증할 수 없습니다.') }

        if ([string]$classification.action -eq 'RESTORE') {
            $step.status = 'COMMITTED'
            $step.attemptCount = 1
            $step.artifactPath = $canonicalPath
            $step.artifactHash = $expectedHash
            $step.inputHash = $null
            $step.lastError = $null
            $step.retryMode = $null
            $step.lastPromptKind = $null
            $restore.Add($step)
        }
        else {
            $step.status = 'PENDING'
            $step.attemptCount = 0
            $step.inputGeneration = [Math]::Max(2, [int]$step.inputGeneration)
            $step.inputHash = $null
            $step.artifactPath = $null
            $step.artifactHash = $null
            $step.lastError = $null
            $step.retryMode = $null
            $step.lastPromptKind = $null
            $rerun.Add($step)
            if ($isAds) {
                $regularPath = Join-Path (Join-Path $directory 'history\decisions') ("{0}-{1}.json" -f [string]$step.stepKey, (Get-DuoForgeArtifactHistorySuffixInternal -ArtifactHash $expectedHash))
                $adsMigrations.Add([ordered]@{ source = $preservedPath; destination = $regularPath; hash = $expectedHash; record = $record })
            }
        }
    }

    if ($restore.Count -ne 10 -or $rerun.Count -ne 4 -or $adsMigrations.Count -ne 4) { throw (New-DuoForgeException -Code 'DF-RECOVERY-SHAPE' -Message '복구 분류 결과가 예상된 10개 복원·4개 재실행과 다릅니다.') }
    $ledger = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $directory 'issues.json'))
    $null = Assert-DuoForgeIssueLedgerV2Internal -Issues @($ledger.issues)
    foreach ($step in @($restore)) {
        $wrapper = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path ([string]$step.artifactPath))
        $maps = Get-DuoForgeIssueTargetMapsInternal -RunDirectory $directory -Graph $graph -ExcludeStepKey ([string]$step.stepKey)
        $null = Test-DuoForgeStageResultInternal -Result $wrapper.result -ExpectedStage ([string]$step.stage) -ExpectedProvider ([string]$step.provider) -WorkflowVersion workflow-v2 -ExpectedTargetDocumentId (Get-DuoForgeObjectValue -Object $step -Name 'targetDocumentId') -ExpectedSourceDocumentIds @(Get-DuoForgeObjectValue -Object $step -Name 'sourceDocumentIds' -Default @()) -DefinitionIssueTargets $maps.definitionTargets -ReferenceIssueTargets $maps.referenceTargets -ReservedIssueFingerprints $maps.reservedFingerprints -ThrowOnIssueReferenceIntegrityError -ThrowOnError
    }
    $pendingPath = Join-Path $directory 'decisions\pending.json'
    $pendingCount = if (Test-Path -LiteralPath $pendingPath -PathType Leaf) { @((Read-DuoForgeJson -Path $pendingPath).questions).Count } else { 0 }
    if ($pendingCount -ne 0) { throw (New-DuoForgeException -Code 'DF-RECOVERY-PENDING-GATE' -Message '복구 대상에 답하지 않은 질문이 남아 있습니다.') }

    if ($Apply) {
        foreach ($migration in @($adsMigrations)) {
            $bytes = [IO.File]::ReadAllBytes([string]$migration.source)
            if ((Get-DuoForgeSha256 -Bytes $bytes) -ne [string]$migration.hash) { throw (New-DuoForgeException -Code 'DF-RECOVERY-ADS-HASH' -Message 'ADS 추출 해시가 일치하지 않습니다.') }
            [IO.File]::WriteAllBytes([string]$migration.destination, $bytes)
            if ((Get-DuoForgeSha256 -Path ([string]$migration.destination)) -ne [string]$migration.hash) { throw (New-DuoForgeException -Code 'DF-RECOVERY-ADS-HASH' -Message 'regular history 파일 해시가 일치하지 않습니다.') }
            $migration.record.preservedPath = [string]$migration.destination
        }
        $state.status = 'PAUSED_USER'
        $state.round = 2
        $state.lastCompletedStage = 'r02-claude-review-response'
        $state.updatedAt = Get-DuoForgeUtcNow
        Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph
        Write-DuoForgeJsonAtomic -Path $statePath -Value $state
        Add-DuoForgeRunEvent -RunDirectory $directory -Type 'COMPOSITE_RUN_RECOVERY_APPLIED' -Status 'PAUSED_USER' -Data ([ordered]@{ restored = 10; rerun = 4; adsMigrated = 4; providerCalls = 0 })
    }
    return [ordered]@{
        applied = [bool]$Apply
        status = if ($Apply) { 'PAUSED_USER' } else { [string]$state.status }
        restoredSteps = @($restore | ForEach-Object { [string]$_.stepKey })
        rerunSteps = @($rerun | ForEach-Object { [string]$_.stepKey })
        adsMigrated = $adsMigrations.Count
        pendingQuestions = $pendingCount
        providerCalls = 0
        totalAttemptCount = [int](@($graph.steps | ForEach-Object { [int]$_.totalAttemptCount } | Measure-Object -Sum).Sum)
    }
}
