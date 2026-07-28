function Test-DuoForgeSnapshotIntegrity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $inventory = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'inputs\inventory.json')
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($record in @($inventory.snapshots)) {
        $path = Join-Path $RunDirectory ("inputs\snapshots\{0}" -f [string]$record.snapshotName)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $problems.Add([string]$record.snapshotName)
            continue
        }
        if ((Get-DuoForgeSha256 -Path $path) -ne [string]$record.snapshotHash) {
            $problems.Add([string]$record.snapshotName)
        }
    }
    return [ordered]@{ valid = $problems.Count -eq 0; invalidSnapshots = @($problems) }
}

function Get-DuoForgeRemainingCallBudget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
    $stepsPath = Join-Path $RunDirectory 'steps.json'
    if (Test-Path -LiteralPath $stepsPath -PathType Leaf) {
        $graph = Read-DuoForgeJson -Path $stepsPath
    }
    else {
        $firstSynthesizer = if ([string]::IsNullOrWhiteSpace([string]$manifest.firstSynthesizer)) { 'alternate' } else { [string]$manifest.firstSynthesizer }
        $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
        $contextPlanPath = Join-Path $RunDirectory 'inputs\context-plan.json'
        $contextBatchCount = if (Test-Path -LiteralPath $contextPlanPath -PathType Leaf) { @((Read-DuoForgeJson -Path $contextPlanPath).batches).Count } else { 0 }
        $graph = New-DuoForgeStageGraph -Mode ([string]$manifest.mode) -MaxRounds ([int]$manifest.maxRounds) -FirstSynthesizer $firstSynthesizer -ContextBatchCount $contextBatchCount -WorkflowVersion $workflowVersion
    }

    $providers = [ordered]@{}
    foreach ($provider in @('codex', 'claude')) {
        $planned = @($graph.steps | Where-Object { $_.provider -eq $provider }).Count
        $completed = @($graph.steps | Where-Object { $_.provider -eq $provider -and $_.status -eq 'COMMITTED' }).Count
        $attempted = 0
        foreach ($step in @($graph.steps | Where-Object { $_.provider -eq $provider })) { $attempted += [int]$step.attemptCount }
        $providerPlans = Get-DuoForgeObjectValue -Object $manifest.executionPlan -Name 'providers'
        $providerPlan = Get-DuoForgeObjectValue -Object $providerPlans -Name $provider
        $maximum = [int](Get-DuoForgeObjectValue -Object $providerPlan -Name 'maximumCalls' -Default 0)
        $providers[$provider] = [ordered]@{
            plannedRemaining = [Math]::Max(0, $planned - $completed)
            maximumAdditionalCalls = [Math]::Max(0, $maximum - $attempted)
            attempted = $attempted
        }
    }
    return [ordered]@{ providers = $providers }
}

function Invoke-DuoForgeResumeLiveInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot,
        [Parameter(Mandatory)][bool]$LiveConsent,
        [scriptblock]$ProgressObserver
    )

    if (-not $LiveConsent) {
        throw (New-DuoForgeException -Code 'DF-LIVE-CONSENT' -Message '라이브 공급자 호출 동의가 없습니다.')
    }
    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $directory = [string]$run.runDirectory
    $null = Invoke-WithDuoForgeRunLock -RunDirectory $directory -ScriptBlock { $true }
    $run = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $ResultsRoot
    $null = Assert-DuoForgeRunStorageContractInternal -RunDirectory $directory
    if ([string]$run.manifest.mode -eq 'dual-project-audit') {
        throw (New-DuoForgeException -Code 'DF-MODE-3A-DISABLED' -Message '3A는 현재 Windows 격리 후보가 범위 밖 읽기와 자식 프로세스 차단에 실패하여 비활성화되어 있습니다.')
    }
    $null = Assert-DuoForgeProviderSelectionsInternal -Selections (Get-DuoForgeObjectValue -Object $run.manifest -Name 'providerSelections')
    if ([string]$run.state.status -in @('COMPLETED', 'COMPLETED_PARTIAL')) {
        return [ordered]@{ status = [string]$run.state.status; invoked = 0 }
    }
    $null = Assert-DuoForgeStagePromptPolicyInternal -Manifest $run.manifest

    $integrity = Test-DuoForgeSnapshotIntegrity -RunDirectory ([string]$run.runDirectory)
    if (-not $integrity.valid) {
        throw (New-DuoForgeException -Code 'DF-SNAPSHOT-INTEGRITY' -Message ('실행 스냅샷 무결성 검증에 실패했습니다: ' + ($integrity.invalidSnapshots -join ', ')))
    }

    $doctor = Invoke-DuoForgeDoctorInternal
    if (-not [bool]$doctor.readyForDocumentModes) {
        throw (New-DuoForgeException -Code 'DF-DOCTOR-BLOCKED' -Message '현재 환경 진단이 문서 모드 라이브 실행을 허용하지 않습니다.')
    }

    $providerStageCommand = Get-Command -Name 'Invoke-DuoForgeLiveProviderStage' -CommandType Function -ErrorAction Stop
    $callback = {
        param($step, $prompt, $graph)
        & $providerStageCommand -RunDirectory $directory -Graph $graph -Step $step -Prompt $prompt -LiveConsent $true -ProgressObserver $ProgressObserver
    }.GetNewClosure()
    return Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback -ProgressObserver $ProgressObserver
}
