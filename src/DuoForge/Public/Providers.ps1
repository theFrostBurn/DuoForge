function ConvertFrom-DuoForgeCodexAuthStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$ExitCode = 0
    )
    return ConvertFrom-DuoForgeCodexAuthStatusInternal @PSBoundParameters
}
function ConvertFrom-DuoForgeClaudeAuthStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$ExitCode = 0
    )
    return ConvertFrom-DuoForgeClaudeAuthStatusInternal @PSBoundParameters
}

function Invoke-DuoForgeDoctor {
    [CmdletBinding()]
    param()

    return Invoke-DuoForgeDoctorInternal
}
