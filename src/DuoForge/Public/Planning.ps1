function Get-DuoForgeExecutionPlan {
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

        [ValidateSet('workflow-v1', 'workflow-v2', 'workflow-v3')]
        [string]$WorkflowVersion = 'workflow-v2'
    )

    return Get-DuoForgeExecutionPlanInternal @PSBoundParameters
}
