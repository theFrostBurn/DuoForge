function Add-DuoForgeRound {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [string]$ResultsRoot)
    return Add-DuoForgeRoundInternal -RunId $RunId -ResultsRoot $ResultsRoot
}

function Get-DuoForgeDecisionConstraintPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$IssueId, [Parameter(Mandatory)][string]$Text, [string]$ResultsRoot)
    return New-DuoForgeDecisionConstraintPreviewInternal -RunId $RunId -IssueId $IssueId -Text $Text -ResultsRoot $ResultsRoot
}

function Set-DuoForgeDecisionConstraint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$IssueId, [Parameter(Mandatory)][string]$Text, [string]$ResultsRoot, [Parameter(Mandatory)][switch]$Confirm)
    return Set-DuoForgeUserConstraintInternal -RunId $RunId -IssueId $IssueId -Text $Text -ResultsRoot $ResultsRoot -Confirm:$Confirm
}
