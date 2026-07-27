function Get-DuoForgeExecutionPlanInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('shared-document', 'dual-document', 'dual-project-audit')]
        [string]$Mode,

        [ValidateRange(2, 3)]
        [int]$MaxRounds = 2,

        [ValidateSet('alternate', 'codex', 'claude')]
        [string]$FirstSynthesizer = 'alternate',

        [int]$MaxCallsPerProvider = 24
    )

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
    if ($Mode -eq 'shared-document') {
        foreach ($provider in @('codex', 'claude')) {
            & $addCall $provider 1 'independent-draft'
            & $addCall $provider 1 'cross-review'
            & $addCall $provider 1 'author-response'
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
        mode = $Mode
        maxRounds = $MaxRounds
        minimumNormalRounds = 2
        retryPerStage = 1
        providers = $providerPlans
        synthesizers = @($synthesizers)
        withinLimits = $withinLimits
        explanationCallsExcluded = $true
    }
}
