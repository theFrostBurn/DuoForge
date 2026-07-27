function Get-DuoForgeExecutionPlan {
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

    return Get-DuoForgeExecutionPlanInternal @PSBoundParameters
}
