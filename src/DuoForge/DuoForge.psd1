@{
    RootModule = 'DuoForge.psm1'
    ModuleVersion = '0.3.0'
    GUID = '44d683b2-48c3-40cb-a935-c5f3ff5e3036'
    Author = 'DuoForge'
    CompanyName = 'DuoForge'
    Copyright = '(c) 2026 DuoForge'
    Description = 'Codex와 Claude의 안전한 문서 토론을 조율하는 PowerShell 7 CLI 코어'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Invoke-DuoForgeCli',
        'Invoke-DuoForgeDoctor',
        'Get-DuoForgeDefaultConfig',
        'Get-DuoForgeExecutionPlan',
        'New-DuoForgeStartRequest',
        'Test-DuoForgeStartRequest',
        'New-DuoForgeRun',
        'Get-DuoForgeRun',
        'Get-DuoForgeRuns',
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
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('PowerShell', 'Codex', 'Claude', 'Windows')
            ProjectUri = 'https://github.com/'
        }
    }
}
