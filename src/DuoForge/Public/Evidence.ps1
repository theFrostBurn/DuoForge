function Add-DuoForgeIssueEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$IssueId,
        [Parameter(Mandatory)][string]$File,
        [string]$ResultsRoot
    )

    return Add-DuoForgeIssueEvidenceInternal @PSBoundParameters
}
