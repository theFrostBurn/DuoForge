#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Consent
)

$ErrorActionPreference = 'Stop'
if ($Consent -cne 'LIVE') { throw '정확한 LIVE 동의가 필요합니다.' }

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$module = Import-Module (Join-Path $projectRoot 'src\DuoForge\DuoForge.psd1') -Force -PassThru

try {
    $summary = & $module {
        $providerContext = Resolve-DuoForgeProviderExecutionContextInternal -Provider codex
        $doctor = Invoke-DuoForgeDoctorInternal
        $options = Get-DuoForgeProviderSelectionOptionsInternal -Provider codex
        $required = [ordered]@{
            'gpt-5.6-sol' = @('high')
            'gpt-5.6-luna' = @('low', 'medium')
        }
        foreach ($model in $required.Keys) {
            $matches = @($options.suggestedModels | Where-Object { [string]$_.value -ceq $model })
            if ($matches.Count -ne 1) { throw [System.InvalidOperationException]::new('DF-CODEX-PROBE-MODEL-CATALOG') }
            $efforts = @(Get-DuoForgeReasoningEffortsForModelInternal -Options $options -Model $model)
            foreach ($effort in $required[$model]) {
                if ($effort -cnotin $efforts) { throw [System.InvalidOperationException]::new('DF-CODEX-PROBE-EFFORT-CATALOG') }
            }
        }
        if (-not [bool]$doctor.readyForDocumentModes) { throw [System.InvalidOperationException]::new('DF-CODEX-PROBE-DOCTOR') }
        if ([string]$doctor.hostContext.elevation -cne 'STANDARD') { throw [System.InvalidOperationException]::new('DF-CODEX-PROBE-HOST') }
        if ([string]$options.catalogSource -cne 'codex-app-server') { throw [System.InvalidOperationException]::new('DF-CODEX-PROBE-CATALOG-SOURCE') }
        if (-not [bool]$providerContext.liveRuntimeEligible) { throw [System.InvalidOperationException]::new('DF-CODEX-PROBE-AUTH-CONTEXT') }

        $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
        $workDirectory = [System.IO.Path]::GetFullPath((Join-Path $tempBase ('duoforge-codex-probe-' + [Guid]::NewGuid().ToString('N'))))
        if (-not $workDirectory.StartsWith($tempBase + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw [System.InvalidOperationException]::new('DF-CODEX-PROBE-WORK-BOUNDARY')
        }
        [System.IO.Directory]::CreateDirectory($workDirectory) | Out-Null
        $schemaPath = Join-Path $workDirectory 'stage-result-v2.schema.json'
        [System.IO.File]::Copy((Join-Path $script:ProjectRoot 'schemas\stage-result-v2.schema.json'), $schemaPath, $false)

        $profiles = @(
            [ordered]@{ name = 'SOL_HIGH_BASE'; model = 'gpt-5.6-sol'; effort = 'high'; schema = $false },
            [ordered]@{ name = 'LUNA_LOW_BASE'; model = 'gpt-5.6-luna'; effort = 'low'; schema = $false },
            [ordered]@{ name = 'LUNA_MEDIUM_BASE'; model = 'gpt-5.6-luna'; effort = 'medium'; schema = $false },
            [ordered]@{ name = 'LUNA_LOW_STAGE_SCHEMA'; model = 'gpt-5.6-luna'; effort = 'low'; schema = $true }
        )
        $results = [System.Collections.Generic.List[object]]::new()
        $solSucceeded = $false
        $lunaLowSucceeded = $false
        try {
            foreach ($profile in $profiles) {
                if ([string]$profile.name -ceq 'LUNA_LOW_STAGE_SCHEMA' -and -not $lunaLowSucceeded) { continue }
                if ([string]$profile.name -ne 'SOL_HIGH_BASE' -and -not $solSucceeded) { break }

                $arguments = @(
                    '--ask-for-approval', 'never',
                    '--model', [string]$profile.model,
                    '--config', ('model_reasoning_effort="{0}"' -f [string]$profile.effort),
                    'exec',
                    '--sandbox', 'read-only',
                    '--skip-git-repo-check',
                    '--ephemeral',
                    '--ignore-user-config',
                    '--ignore-rules',
                    '--config', 'web_search="disabled"',
                    '--json'
                )
                if ([bool]$profile.schema) { $arguments += @('--output-schema', $schemaPath) }
                $arguments += '-'
                $prompt = if ([bool]$profile.schema) {
                    'Return one valid synthetic object matching the supplied schema. Use empty arrays and neutral values. Do not call tools.'
                }
                else {
                    'Return a minimal synthetic confirmation. Do not call tools.'
                }

                $process = Invoke-DuoForgeProcess -CommandName codex -Arguments $arguments -WorkingDirectory $workDirectory -TimeoutSeconds 180 `
                    -StandardInput $prompt -EnvironmentAllowList @($providerContext.environmentAllowList) `
                    -EnvironmentOverrides $providerContext.environmentOverrides -CommandInvocation $providerContext.invocation
                $stdoutBytes = [int64]$process.stdoutBytes
                $stderrBytes = [int64]$process.stderrBytes
                $exitCode = $process.exitCode
                $safeReason = 'OK'
                $code = 'OK'
                $toolEventCount = 0
                if (-not $process.started -or $process.timedOut -or $null -eq $process.exitCode -or [int]$process.exitCode -ne 0) {
                    $classification = Get-DuoForgeProviderFailureClassificationInternal -Provider codex -ProcessResult $process
                    $safeReason = [string]$classification.safeReason
                    $code = [string]$classification.code
                }
                else {
                    foreach ($line in @(([string]$process.stdout) -split "`r?`n")) {
                        if ([string]::IsNullOrWhiteSpace($line)) { continue }
                        try {
                            $event = $line | ConvertFrom-Json -Depth 30 -ErrorAction Stop
                            $item = Get-DuoForgeObjectValue -Object $event -Name 'item'
                            $itemType = [string](Get-DuoForgeObjectValue -Object $item -Name 'type')
                            if ($itemType -in @('command_execution', 'file_change', 'mcp_tool_call', 'web_search')) { $toolEventCount++ }
                        }
                        catch { }
                    }
                    $process.stdout = ''
                    $process.stderr = ''
                    if ($toolEventCount -gt 0) {
                        $safeReason = 'TOOL_EVENT'
                        $code = 'DF-CODEX-PROBE-TOOL-EVENT'
                    }
                }
                $success = [string]$code -ceq 'OK'
                if ([string]$profile.name -ceq 'SOL_HIGH_BASE') { $solSucceeded = $success }
                if ([string]$profile.name -ceq 'LUNA_LOW_BASE') { $lunaLowSucceeded = $success }
                $results.Add([ordered]@{
                    profile = [string]$profile.name
                    model = [string]$profile.model
                    effort = [string]$profile.effort
                    schema = [bool]$profile.schema
                    success = $success
                    code = $code
                    safeReason = $safeReason
                    exitCode = $exitCode
                    stdoutBytes = $stdoutBytes
                    stderrBytes = $stderrBytes
                    toolEventCount = $toolEventCount
                })
            }
        }
        finally {
            if (Test-Path -LiteralPath $workDirectory -PathType Container) {
                [System.IO.Directory]::Delete($workDirectory, $true)
            }
        }

        return [ordered]@{
            schemaVersion = 1
            status = 'PAUSED_USER'
            catalogSource = 'codex-app-server'
            hostElevation = 'STANDARD'
            maximumCalls = 4
            executedCalls = $results.Count
            results = @($results)
        }
    }
    $summary | ConvertTo-Json -Depth 20 -Compress
}
catch {
    $code = if ($_.Exception.Message -match '^DF-[A-Z0-9-]+') {
        [string]([regex]::Match($_.Exception.Message, '^DF-[A-Z0-9-]+').Value)
    }
    else { 'DF-CODEX-PROBE' }
    [ordered]@{ schemaVersion = 1; status = 'FAILED'; code = $code; maximumCalls = 4 } | ConvertTo-Json -Compress
    exit 1
}
