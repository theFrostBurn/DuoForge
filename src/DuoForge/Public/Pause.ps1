function Request-DuoForgePause {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )

    return Request-DuoForgePauseInternal @PSBoundParameters
}
