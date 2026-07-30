function Add-DuoForgeIssueEvidenceInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$IssueId,
        [Parameter(Mandatory)][string]$File,
        [string]$ResultsRoot
    )

    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $directory = [string]$run.runDirectory
    $config = Get-DuoForgeConfig
    $source = Assert-DuoForgeMarkdownFile -Path $File -MaximumBytes ([long]$config.limits.documentBytes)
    $relationship = Get-DuoForgePathRelationshipInternal -PathA $directory -PathB ([string]$source.path)
    if ($relationship -ne 'Disjoint') {
        throw (New-DuoForgeException -Code 'DF-EVIDENCE-RUN-BOUNDARY' -Message '실행 결과 폴더 안의 파일은 새 근거로 추가할 수 없습니다.')
    }

    return Invoke-WithDuoForgeRunLock -RunDirectory $directory -ScriptBlock {
        $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
        $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $directory
        $null = Assert-DuoForgeStagePromptPolicyInternal -Manifest $run.manifest
        $statePath = Join-Path $directory 'state.json'
        $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
        if ([string]$state.status -in @('COMPLETED', 'COMPLETED_PARTIAL', 'QUESTION_LIMIT_REACHED', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')) {
            throw (New-DuoForgeException -Code 'DF-EVIDENCE-TERMINAL' -Message '종료된 실행에는 근거를 추가할 수 없습니다.')
        }

        $ledgerPath = Join-Path $directory 'issues.json'
        $ledger = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $ledgerPath)
        $matches = @($ledger.issues | Where-Object { [string]$_.issueId -eq $IssueId })
        if ($matches.Count -ne 1) { throw (New-DuoForgeException -Code 'DF-ISSUE-NOT-FOUND' -Message "쟁점을 찾을 수 없습니다: $IssueId") }
        $issue = $matches[0]
        if ([string]$issue.resolutionStatus -ne 'AWAITING_EVIDENCE') {
            throw (New-DuoForgeException -Code 'DF-EVIDENCE-NOT-REQUESTED' -Message '추가 근거를 기다리는 쟁점에만 파일을 연결할 수 있습니다.')
        }

        $inventoryPath = Join-Path $directory 'inputs\inventory.json'
        $inventory = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $inventoryPath)
        $existingEvidenceNames = @($inventory.snapshots | ForEach-Object { [string]$_.snapshotName } | Where-Object { $_ -match '^E\d{6}\.md$' })
        $snapshotDirectory = Join-Path $directory 'inputs\snapshots'
        $diskEvidenceNames = @(Get-ChildItem -LiteralPath $snapshotDirectory -File -Filter 'E*.md' | Where-Object { $_.Name -match '^E\d{6}\.md$' } | ForEach-Object { $_.Name })
        if ((@($existingEvidenceNames | Sort-Object -Unique) -join ',') -cne (@($diskEvidenceNames | Sort-Object -Unique) -join ',')) {
            throw (New-DuoForgeException -Code 'DF-EVIDENCE-INVENTORY-DRIFT' -Message '근거 스냅샷 파일과 입력 인벤토리가 일치하지 않습니다. 실행 저장 상태를 먼저 복구해 주세요.')
        }
        $maximumNumber = 0
        foreach ($name in $existingEvidenceNames) {
            if ($name -match '^E(\d{6})\.md$') { $maximumNumber = [Math]::Max($maximumNumber, [int]$Matches[1]) }
        }
        $snapshotName = 'E{0:D6}.md' -f ($maximumNumber + 1)
        $snapshotPath = Join-Path $directory ("inputs\snapshots\$snapshotName")
        if (Test-Path -LiteralPath $snapshotPath) { throw (New-DuoForgeException -Code 'DF-EVIDENCE-SNAPSHOT-EXISTS' -Message "근거 스냅샷 이름이 이미 존재합니다: $snapshotName") }
        $manifestPath = Join-Path $directory 'manifest.json'
        $manifest = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $manifestPath)
        $pendingPath = Join-Path $directory 'decisions\pending.json'
        $pending = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $pendingPath)
        $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
        return Invoke-WithDuoForgeRunMutationTransactionInternal -RunDirectory $directory -RelativePaths @(
            'state.json', 'manifest.json', 'issues.json', 'inputs\inventory.json', 'decisions\pending.json',
            'decisions\user-evidence.jsonl', 'steps.json', 'events.jsonl', "inputs\snapshots\$snapshotName"
        ) -RelativeDirectories @('history\decisions') -ScriptBlock {
            [System.IO.File]::Copy([string]$source.path, $snapshotPath, $false)
            $snapshotHash = Get-DuoForgeSha256 -Path $snapshotPath
            if ($snapshotHash -ne [string]$source.sha256) {
                throw (New-DuoForgeException -Code 'DF-SNAPSHOT-HASH' -Message '근거 스냅샷 해시가 원본과 다릅니다.')
            }

            $snapshotRecord = [ordered]@{
                sourcePath = [string]$source.path
                sourceHash = [string]$source.sha256
                snapshotName = $snapshotName
                snapshotPath = $snapshotPath
                snapshotHash = $snapshotHash
                bytes = [long]$source.bytes
                role = 'user-evidence'
                issueId = $IssueId
            }
            $inventory.sourceFiles = @($inventory.sourceFiles) + @($source)
            $inventory.snapshots = @($inventory.snapshots) + @($snapshotRecord)
            Add-DuoForgeEvidenceSnapshotRoleInternal -Inventory $inventory -WorkflowVersion $workflowVersion -SnapshotName $snapshotName
            $inventory.generatedAt = Get-DuoForgeUtcNow
            Write-DuoForgeJsonAtomic -Path $inventoryPath -Value $inventory

            $manifest.inputSnapshotHashes = @($manifest.inputSnapshotHashes) + @($snapshotHash)
            if ($workflowVersion -eq 'workflow-v2' -and [int]$manifest.schemaVersion -ge 4) {
                $manifest.roles = ConvertTo-DuoForgeHashtable -InputObject $inventory.roles
            }
            $manifest.updatedAt = Get-DuoForgeUtcNow
            Write-DuoForgeJsonAtomic -Path $manifestPath -Value $manifest

            $record = [ordered]@{
                schemaVersion = 1
                evidenceId = 'evidence-' + [Guid]::NewGuid().ToString('N')
                runId = $RunId
                issueId = $IssueId
                issueFingerprint = [string]$issue.fingerprint
                externalKeys = @($issue.externalKeys)
                snapshotName = $snapshotName
                snapshotHash = $snapshotHash
                bytes = [long]$source.bytes
                sourcePath = [string]$source.path
                addedAt = Get-DuoForgeUtcNow
            }
            Add-DuoForgeJsonLine -Path (Join-Path $directory 'decisions\user-evidence.jsonl') -Value $record
            $issue.evidence = @($issue.evidence) + @([ordered]@{ source = $snapshotName; location = 'entire-document'; excerptHash = $snapshotHash; addedBy = 'user'; evidenceId = $record.evidenceId })
            $issue.resolutionStatus = 'OPEN'
            $issue.history = @($issue.history) + @([ordered]@{ at = $record.addedAt; event = 'USER_EVIDENCE_ADDED'; actor = 'user'; status = 'OPEN'; evidenceId = $record.evidenceId; snapshotName = $snapshotName })
            Write-DuoForgeJsonAtomic -Path $ledgerPath -Value $ledger

            $pending.questions = @($pending.questions | Where-Object { [string]$_.issueKey -ne $IssueId })
            Write-DuoForgeJsonAtomic -Path $pendingPath -Value $pending
            $reset = Reset-DuoForgeDecisionAffectedSteps -RunDirectory $directory -Mode ([string]$state.mode)
            $state.status = 'PAUSED_USER'
            $state.lastCompletedStage = [string]$reset.lastCommittedStep
            $state.updatedAt = Get-DuoForgeUtcNow
            Write-DuoForgeJsonAtomic -Path $statePath -Value $state
            Add-DuoForgeRunEvent -RunDirectory $directory -Type 'USER_EVIDENCE_ADDED' -Status 'PAUSED_USER' -Data ([ordered]@{ issueId = $IssueId; evidenceId = $record.evidenceId; snapshotName = $snapshotName; snapshotHash = $snapshotHash; resetSteps = $reset.resetSteps })
            $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $directory
            return [ordered]@{ status = 'PAUSED_USER'; issueId = $IssueId; evidenceId = $record.evidenceId; snapshotName = $snapshotName; snapshotHash = $snapshotHash; resetSteps = $reset.resetSteps }
        }
    }
}
