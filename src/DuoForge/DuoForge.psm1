Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleRoot = $PSScriptRoot
$script:ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:ModuleVersion = [string](Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'DuoForge.psd1')).ModuleVersion

$privateFiles = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -File | Sort-Object Name
$publicFiles = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File | Sort-Object Name

foreach ($file in @($privateFiles) + @($publicFiles)) {
    . $file.FullName
}

Export-ModuleMember -Function @(
    'Invoke-DuoForgeCli',
    'Invoke-DuoForgeDoctor',
    'Get-DuoForgeDefaultConfig',
    'Get-DuoForgeExecutionPlan',
    'New-DuoForgeStartRequest',
    'Test-DuoForgeStartRequest',
    'New-DuoForgeRun',
    'Get-DuoForgeRun',
    'Get-DuoForgeRuns',
    'Get-DuoForgeIssueExplanations',
    'Invoke-DuoForgeIssueExplanation',
    'Request-DuoForgePause',
    'Add-DuoForgeIssueEvidence',
    'Set-DuoForgeIssueAnswer',
    'Suspend-DuoForgeIssue',
    'Resolve-DuoForgePath',
    'Test-DuoForgePathRelationship',
    'Get-DuoForgeMarkdownInventory',
    'New-DuoForgeIssue',
    'Test-DuoForgeCompletionAllowed',
    'ConvertFrom-DuoForgeCodexAuthStatus',
    'ConvertFrom-DuoForgeClaudeAuthStatus'
)
