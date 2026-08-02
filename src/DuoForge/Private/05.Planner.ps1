function Get-DuoForgeExecutionPlanInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('shared-document', 'document-merge', 'dual-document', 'dual-project-audit')]
        [string]$Mode,

        [ValidateRange(1, 3)]
        [int]$MaxRounds = 2,

        [ValidateSet('alternate', 'codex', 'claude')]
        [string]$FirstSynthesizer = 'alternate',

        [int]$MaxCallsPerProvider = 24,

        [ValidateRange(0, 100)][int]$ContextBatchCount = 0,

        [ValidateSet('workflow-v1', 'workflow-v2', 'workflow-v3')][string]$WorkflowVersion = 'workflow-v2'
    )

    if ($WorkflowVersion -in @('workflow-v1', 'workflow-v2') -and $MaxRounds -lt 2) {
        throw (New-DuoForgeException -Code 'DF-ROUNDS' -Message 'workflow-v1/v2 라운드는 2 또는 3이어야 합니다.')
    }
    if ($Mode -eq 'document-merge' -and $WorkflowVersion -ne 'workflow-v2') {
        if ($WorkflowVersion -ne 'workflow-v3') {
            throw (New-DuoForgeException -Code 'DF-WORKFLOW-MODE' -Message 'document-merge는 workflow-v2/v3에서만 지원합니다.')
        }
    }

    if ($WorkflowVersion -eq 'workflow-v3') {
        if ($Mode -notin @('shared-document', 'document-merge', 'dual-document')) {
            throw (New-DuoForgeException -Code 'DF-WORKFLOW-MODE' -Message 'workflow-v3 얇은 자동 코어는 문서 모드에서만 지원합니다.')
        }
        $synthesizer = if ($FirstSynthesizer -eq 'claude') { 'claude' } else { 'codex' }
        $validator = if ($synthesizer -eq 'codex') { 'claude' } else { 'codex' }
        $baseCalls = @(
            [ordered]@{ provider = 'codex'; round = 1; stage = 'independent-result' },
            [ordered]@{ provider = 'claude'; round = 1; stage = 'independent-result' },
            [ordered]@{ provider = $synthesizer; round = 1; stage = 'integration' },
            [ordered]@{ provider = $validator; round = 1; stage = 'final-validation' }
        )
        $conditionalCalls = @(
            [ordered]@{ provider = $synthesizer; round = 1; stage = 'final-revision'; condition = 'critical-or-blocking-major' }
        )
        $providerPlans = [ordered]@{}
        $withinLimits = $true
        foreach ($provider in @('codex', 'claude')) {
            $providerBaseCalls = @($baseCalls | Where-Object provider -eq $provider)
            $providerConditionalCalls = @($conditionalCalls | Where-Object provider -eq $provider)
            $maximumCalls = $providerBaseCalls.Count + $providerConditionalCalls.Count
            if ($maximumCalls -gt $MaxCallsPerProvider) { $withinLimits = $false }
            $providerPlans[$provider] = [ordered]@{
                baseCalls = $providerBaseCalls.Count
                conditionalCalls = $providerConditionalCalls.Count
                retryBudget = 0
                maximumCalls = $maximumCalls
                limit = $MaxCallsPerProvider
                calls = @($providerBaseCalls)
            }
        }
        return [ordered]@{
            schemaVersion = 2
            workflowVersion = 'workflow-v3'
            executionProfile = 'thin-core-v1'
            mode = $Mode
            maxRounds = 1
            minimumNormalRounds = 1
            retryPerStage = 0
            baseCallCount = $baseCalls.Count
            conditionalCallCount = $conditionalCalls.Count
            maximumCallCount = $baseCalls.Count + $conditionalCalls.Count
            baseCalls = @($baseCalls)
            conditionalCalls = @($conditionalCalls)
            providers = $providerPlans
            synthesizers = @($synthesizer)
            withinLimits = $withinLimits
            explanationCallsExcluded = $true
            contextBatchCount = $ContextBatchCount
            contextProcessing = 'local-only'
        }
    }

    $calls = [ordered]@{
        codex = [System.Collections.Generic.List[object]]::new()
        claude = [System.Collections.Generic.List[object]]::new()
    }

    $addCall = {
        param([string]$Provider, [int]$Round, [string]$Stage)
        $calls[$Provider].Add([ordered]@{
            provider = $Provider
            round = $Round
            stage = $Stage
        })
    }

    $synthesizers = [System.Collections.Generic.List[string]]::new()
    if ($ContextBatchCount -gt 0) {
        foreach ($provider in @('codex', 'claude')) {
            for ($batch = 1; $batch -le $ContextBatchCount; $batch++) { & $addCall $provider 0 'context-batch-analysis' }
        }
    }
    if ($Mode -in @('shared-document', 'document-merge')) {
        $initialDraftStage = if ($Mode -eq 'document-merge') { 'independent-merge-draft' } else { 'independent-draft' }
        $initialResponseStage = if ($Mode -eq 'document-merge') { 'review-response' } else { 'author-response' }
        foreach ($provider in @('codex', 'claude')) {
            & $addCall $provider 1 $initialDraftStage
            & $addCall $provider 1 'cross-review'
            & $addCall $provider 1 $initialResponseStage
        }

        $first = if ($FirstSynthesizer -eq 'claude') { 'claude' } else { 'codex' }
        for ($round = 1; $round -le $MaxRounds; $round++) {
            if ($round -gt 1) {
                foreach ($provider in @('codex', 'claude')) {
                    & $addCall $provider $round 'joint-document-review'
                    & $addCall $provider $round 'review-response'
                }
            }

            $synthesizer = if (($round % 2) -eq 1) { $first } elseif ($first -eq 'codex') { 'claude' } else { 'codex' }
            $synthesizers.Add($synthesizer)
            & $addCall $synthesizer $round 'synthesis'
        }

        $lastSynthesizer = $synthesizers[$synthesizers.Count - 1]
        $validator = if ($lastSynthesizer -eq 'codex') { 'claude' } else { 'codex' }
        & $addCall $validator $MaxRounds 'final-validation'
    }
    elseif ($Mode -eq 'dual-document') {
        if ($WorkflowVersion -eq 'workflow-v1') {
            for ($round = 1; $round -le $MaxRounds; $round++) {
                foreach ($provider in @('codex', 'claude')) {
                    & $addCall $provider $round 'cross-review'
                    & $addCall $provider $round 'owner-response'
                    & $addCall $provider $round 'owned-document-revision'
                }
            }
        }
        else {
            for ($round = 1; $round -le $MaxRounds; $round++) {
                foreach ($provider in @('codex', 'claude')) {
                    & $addCall $provider $round 'document-review'
                    & $addCall $provider $round 'review-response'
                    & $addCall $provider $round 'document-revision'
                }
            }
            foreach ($provider in @('codex', 'claude')) { & $addCall $provider $MaxRounds 'document-validation' }
        }
    }
    else {
        for ($round = 1; $round -le $MaxRounds; $round++) {
            foreach ($provider in @('codex', 'claude')) {
                & $addCall $provider $round $(if ($round -eq 1) { 'independent-analysis' } else { 'analysis-review' })
                & $addCall $provider $round 'peer-critique-response'
                & $addCall $provider $round 'analysis-revision'
            }
        }
    }

    $providerPlans = [ordered]@{}
    $withinLimits = $true
    foreach ($provider in @('codex', 'claude')) {
        $baseCalls = $calls[$provider].Count
        $retryCalls = $baseCalls
        $maximumCalls = $baseCalls + $retryCalls
        if ($maximumCalls -gt $MaxCallsPerProvider) {
            $withinLimits = $false
        }
        $providerPlans[$provider] = [ordered]@{
            baseCalls = $baseCalls
            retryBudget = $retryCalls
            maximumCalls = $maximumCalls
            limit = $MaxCallsPerProvider
            calls = @($calls[$provider])
        }
    }

    return [ordered]@{
        schemaVersion = 1
        workflowVersion = $WorkflowVersion
        mode = $Mode
        maxRounds = $MaxRounds
        minimumNormalRounds = 2
        retryPerStage = 1
        providers = $providerPlans
        synthesizers = @($synthesizers)
        withinLimits = $withinLimits
        explanationCallsExcluded = $true
        contextBatchCount = $ContextBatchCount
    }
}
