function New-DuoForgeIssue {
    [CmdletBinding()]
    param(
        [object[]]$ExistingIssues = @(),
        [Parameter(Mandatory)][ValidateRange(1, 3)][int]$Round,
        [Parameter(Mandatory)][ValidateSet('codex', 'claude', 'orchestrator', 'user')][string]$RaisedBy,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][ValidateSet('critical', 'major', 'minor')][string]$Severity,
        [Parameter(Mandatory)][string]$Claim,
        [string]$Proposal,
        [bool]$RequiresUser = $false,
        [bool]$BlockingProposal = $false
    )

    return New-DuoForgeIssueInternal @PSBoundParameters
}
function Test-DuoForgeCompletionAllowed {
    [CmdletBinding()]
    param(
        [object[]]$Issues = @(),
        [switch]$AllowPartial
    )

    return Test-DuoForgeCompletionAllowedInternal @PSBoundParameters
}
