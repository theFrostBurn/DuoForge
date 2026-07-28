#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('shared-document', 'document-merge', 'dual-document')][string]$Mode,
    [Parameter(Mandatory)][string]$CodexModel,
    [Parameter(Mandatory)][ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')][string]$CodexEffort,
    [Parameter(Mandatory)][string]$ClaudeModel,
    [Parameter(Mandatory)][ValidateSet('low', 'medium', 'high', 'xhigh', 'max')][string]$ClaudeEffort,
    [Parameter(Mandatory)][string]$Consent,
    [string]$ResultsRoot
)

$ErrorActionPreference = 'Stop'
if ($Consent -cne 'LIVE') { throw '정확한 LIVE 동의가 필요합니다.' }

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
    $ResultsRoot = Join-Path $projectRoot 'results\workflow-v2-live-e2e'
}
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures\workflow-v2-live'
$module = Import-Module (Join-Path $projectRoot 'src\DuoForge\DuoForge.psd1') -Force -PassThru

try {
    $doctor = Invoke-DuoForgeDoctor
    if (-not [bool]$doctor.readyForDocumentModes) {
        throw [System.InvalidOperationException]::new('DF-PREFLIGHT-PROVIDERS')
    }

    $requestParameters = @{
        Mode = $Mode
        CodexModel = $CodexModel
        CodexReasoningEffort = $CodexEffort
        ClaudeModel = $ClaudeModel
        ClaudeReasoningEffort = $ClaudeEffort
        DocumentType = 'prd'
        MaxRounds = 2
        FirstSynthesizer = 'alternate'
        Workspace = $ResultsRoot
        Name = "workflow-v2-live-$Mode"
    }
    if ($Mode -eq 'shared-document') {
        $requestParameters.Brief = Join-Path $fixtureRoot 'shared\brief.md'
    }
    else {
        $requestParameters.DocumentA = Join-Path $fixtureRoot 'document-a\source.md'
        $requestParameters.DocumentB = Join-Path $fixtureRoot 'document-b\source.md'
    }

    $request = New-DuoForgeStartRequest @requestParameters
    $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport $doctor
    if (-not [bool]$validation.valid) {
        $codes = @($validation.errors | ForEach-Object { [string]$_.code } | Sort-Object -Unique)
        throw [System.InvalidOperationException]::new(('DF-VALIDATION:' + ($codes -join ',')))
    }

    $run = New-DuoForgeRun -ValidationResult $validation
    $result = & $module {
        param($RunId, $Root)
        Invoke-DuoForgeResumeLiveInternal -RunId $RunId -ResultsRoot $Root -LiveConsent $true
    } $run.runId $ResultsRoot

    $steps = Get-Content -LiteralPath (Join-Path $run.runDirectory 'steps.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    $state = Get-Content -LiteralPath (Join-Path $run.runDirectory 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 50
    $calls = [ordered]@{
        codex = @($steps.steps | Where-Object { [string]$_.provider -eq 'codex' } | Measure-Object -Property attemptCount -Sum).Sum
        claude = @($steps.steps | Where-Object { [string]$_.provider -eq 'claude' } | Measure-Object -Property attemptCount -Sum).Sum
    }
    [ordered]@{
        schemaVersion = 1
        runId = [string]$run.runId
        mode = $Mode
        workflowVersion = [string]$run.manifest.workflowVersion
        status = [string]$state.status
        totalSteps = @($steps.steps).Count
        committedSteps = @($steps.steps | Where-Object { [string]$_.status -eq 'COMMITTED' }).Count
        calls = $calls
        resultStatus = [string]$result.status
    } | ConvertTo-Json -Depth 10 -Compress
}
catch {
    $code = if ($_.Exception.Data.Contains('DuoForgeCode')) {
        [string]$_.Exception.Data['DuoForgeCode']
    }
    elseif ($_.Exception.Message -match '^DF-[A-Z0-9-]+') {
        [string]([regex]::Match($_.Exception.Message, '^DF-[A-Z0-9-]+').Value)
    }
    else {
        'DF-LIVE-E2E'
    }
    [ordered]@{
        schemaVersion = 1
        mode = $Mode
        status = 'FAILED'
        code = $code
        exceptionType = $_.Exception.GetType().Name
    } | ConvertTo-Json -Depth 5 -Compress
    exit 1
}
