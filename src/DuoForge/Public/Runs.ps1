function New-DuoForgeStartRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('shared-document', 'dual-document', 'dual-project-audit')][string]$Mode,
        [string]$Brief,
        [string]$CodexDocument,
        [string]$ClaudeDocument,
        [string]$CodexProject,
        [string]$ClaudeProject,
        [string]$Requirements,
        [string]$CodexModel,
        [string]$CodexReasoningEffort,
        [string]$ClaudeModel,
        [string]$ClaudeReasoningEffort,
        [ValidateSet('prd', 'architecture', 'implementation-plan', 'adr', 'custom')][string]$DocumentType = 'custom',
        [ValidateRange(2, 3)][int]$MaxRounds = 2,
        [string]$Workspace,
        [ValidateSet('alternate', 'codex', 'claude')][string]$FirstSynthesizer = 'alternate',
        [bool]$PauseAfterRound = $false,
        [bool]$AllowPartial = $false,
        [string]$Name
    )
    return New-DuoForgeStartRequestInternal @PSBoundParameters
}
function Test-DuoForgeStartRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Request,
        [System.Collections.IDictionary]$DoctorReport,
        [System.Collections.IDictionary]$Config
    )
    return Test-DuoForgeStartRequestInternal @PSBoundParameters
}

function New-DuoForgeRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ValidationResult
    )
    return New-DuoForgeRunInternal @PSBoundParameters
}

function Get-DuoForgeRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$ResultsRoot
    )
    return Get-DuoForgeRunInternal @PSBoundParameters
}

function Get-DuoForgeRuns {
    [CmdletBinding()]
    param([string]$ResultsRoot)
    return Get-DuoForgeRunsInternal @PSBoundParameters
}
