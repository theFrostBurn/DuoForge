function Set-DuoForgeIssueAnswer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$IssueId,
        [Parameter(Mandatory)][string]$Choice,
        [string]$ResultsRoot,
        [switch]$ReplacePrevious
    )
    return Set-DuoForgeUserDecisionInternal -RunId $RunId -IssueId $IssueId -Action answer -Choice $Choice -ResultsRoot $ResultsRoot -ReplacePrevious:$ReplacePrevious
}

function Suspend-DuoForgeIssue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$IssueId,
        [string]$ResultsRoot,
        [Parameter(Mandatory)][switch]$ConfirmPartial
    )
    return Set-DuoForgeUserDecisionInternal -RunId $RunId -IssueId $IssueId -Action defer -ResultsRoot $ResultsRoot -ConfirmPartial:$ConfirmPartial
}
