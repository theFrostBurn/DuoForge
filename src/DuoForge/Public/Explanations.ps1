function Get-DuoForgeIssueExplanations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$IssueId,
        [string]$ResultsRoot
    )

    return Get-DuoForgeIssueExplanationsInternal @PSBoundParameters
}

function Invoke-DuoForgeIssueExplanation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$IssueId,
        [ValidateSet('codex', 'claude', 'both')][string]$Provider = 'both',
        [ValidateSet('beginner', 'general', 'expert')][string]$Level = 'general',
        [ValidateSet('general', 'evidence', 'examples', 'tradeoffs', 'experiment')][string]$Focus = 'general',
        [string]$ResultsRoot,
        [Parameter(Mandatory)][bool]$LiveConsent
    )

    return Invoke-DuoForgeIssueExplanationInternal @PSBoundParameters
}
