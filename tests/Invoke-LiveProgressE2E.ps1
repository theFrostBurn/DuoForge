#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('gpt-5.6-luna')][string]$CodexModel,
    [Parameter(Mandatory)][ValidateSet('low')][string]$CodexEffort,
    [Parameter(Mandatory)][ValidateSet('sonnet')][string]$ClaudeModel,
    [Parameter(Mandatory)][ValidateSet('low')][string]$ClaudeEffort,
    [Parameter(Mandatory)][string]$Consent,
    [string]$ResultsRoot
)

$ErrorActionPreference = 'Stop'
if ($Consent -cne 'LIVE') { throw '정확한 LIVE 동의가 필요합니다.' }

function Assert-LiveProgressInvariant {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw [System.InvalidOperationException]::new("DF-LIVE-PROGRESS-$Code") }
}

function Read-LiveProgressJson {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
}

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
    $ResultsRoot = Join-Path $projectRoot 'results\live-progress-e2e'
}
$ResultsRoot = [System.IO.Path]::GetFullPath($ResultsRoot)
$fixture = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\workflow-v2-live\shared\brief.md'))
$fixtureHashBefore = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash
$module = Import-Module (Join-Path $projectRoot 'src\DuoForge\DuoForge.psd1') -Force -PassThru
$run = $null

try {
    Assert-LiveProgressInvariant ($CodexModel -ceq 'gpt-5.6-luna' -and $CodexEffort -ceq 'low') 'CODEX-SELECTION'
    Assert-LiveProgressInvariant ($ClaudeModel -ceq 'sonnet' -and $ClaudeEffort -ceq 'low') 'CLAUDE-SELECTION'

    $preflight = & $module {
        param($ExpectedCodexModel, $ExpectedCodexEffort, $ExpectedClaudeModel, $ExpectedClaudeEffort)
        $doctor = Invoke-DuoForgeDoctorInternal
        $codex = Get-DuoForgeProviderSelectionOptionsInternal -Provider codex
        $claude = Get-DuoForgeProviderSelectionOptionsInternal -Provider claude
        $codexModels = @($codex.suggestedModels | Where-Object { [string]$_.value -ceq $ExpectedCodexModel })
        $claudeModels = @($claude.suggestedModels | Where-Object { [string]$_.value -ceq $ExpectedClaudeModel })
        $codexEfforts = if ($codexModels.Count -eq 1) { @(Get-DuoForgeReasoningEffortsForModelInternal -Options $codex -Model $ExpectedCodexModel) } else { @() }
        $claudeEfforts = if ($claudeModels.Count -eq 1) { @(Get-DuoForgeReasoningEffortsForModelInternal -Options $claude -Model $ExpectedClaudeModel) } else { @() }
        return [ordered]@{
            ready = [bool]$doctor.readyForDocumentModes
            hostElevation = [string]$doctor.hostContext.elevation
            codexSource = [string]$codex.catalogSource
            claudeSource = [string]$claude.catalogSource
            codexExact = $codexModels.Count -eq 1 -and $ExpectedCodexEffort -cin $codexEfforts
            claudeExact = $claudeModels.Count -eq 1 -and $ExpectedClaudeEffort -cin $claudeEfforts
        }
    } $CodexModel $CodexEffort $ClaudeModel $ClaudeEffort

    Assert-LiveProgressInvariant ([bool]$preflight.ready) 'PROVIDERS-NOT-READY'
    Assert-LiveProgressInvariant ([string]$preflight.hostElevation -ceq 'STANDARD') 'HOST-MUST-BE-NON-ADMIN'
    Assert-LiveProgressInvariant ([string]$preflight.codexSource -ceq 'codex-app-server') 'CODEX-CATALOG-FALLBACK'
    Assert-LiveProgressInvariant ([string]$preflight.claudeSource -ceq 'claude-cli-help') 'CLAUDE-CATALOG-FALLBACK'
    Assert-LiveProgressInvariant ([bool]$preflight.codexExact) 'CODEX-NOT-EXPOSED'
    Assert-LiveProgressInvariant ([bool]$preflight.claudeExact) 'CLAUDE-NOT-EXPOSED'

    $doctor = Invoke-DuoForgeDoctor
    Assert-LiveProgressInvariant ([bool]$doctor.readyForDocumentModes) 'DOCTOR'
    $request = New-DuoForgeStartRequest -Mode shared-document -Brief $fixture -DocumentType prd -MaxRounds 2 `
        -FirstSynthesizer alternate -PauseAfterRound:$false -Workspace $ResultsRoot -Name 'live-progress-e2e' `
        -CodexModel $CodexModel -CodexReasoningEffort $CodexEffort -ClaudeModel $ClaudeModel -ClaudeReasoningEffort $ClaudeEffort
    $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport $doctor
    Assert-LiveProgressInvariant ([bool]$validation.valid) 'REQUEST'
    $run = New-DuoForgeRun -ValidationResult $validation

    $execution = & $module {
        param($RunId, $Root)
        $runState = Get-DuoForgeRunInternal -RunId $RunId -ResultsRoot $Root
        $view = New-DuoForgeProgressViewInternal -RunDirectory ([string]$runState.runDirectory) -Mode fullscreen
        $initialViewMode = [string]$view.mode
        $requestPauseCommand = Get-Command -Name 'Request-DuoForgePauseInternal' -CommandType Function -ErrorAction Stop
        $getValueCommand = Get-Command -Name 'Get-DuoForgeObjectValue' -CommandType Function -ErrorAction Stop
        $spinnerCommand = Get-Command -Name 'Get-DuoForgeProgressSpinnerFrameInternal' -CommandType Function -ErrorAction Stop
        $forwardObserver = $view.observer
        $tickElapsed = [ordered]@{
            codex = [System.Collections.Generic.List[int]]::new()
            claude = [System.Collections.Generic.List[int]]::new()
        }
        $spinnerFrames = [ordered]@{
            codex = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            claude = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        }
        $pauseState = @{ requested = $false; count = 0 }
        $observer = {
            param($event)
            $type = [string]$event.type
            $provider = [string](& $getValueCommand -Object $event.data -Name 'provider' -Default '')
            if ($type -ceq 'PROVIDER_TICK' -and $provider -in @('codex', 'claude')) {
                $elapsed = [int](& $getValueCommand -Object $event.data -Name 'elapsedSeconds' -Default 0)
                $tickElapsed[$provider].Add($elapsed)
                $null = $spinnerFrames[$provider].Add([string](& $spinnerCommand -ElapsedSeconds $elapsed))
            }
            if ($type -ceq 'STAGE_STARTED' -and $provider -ceq 'claude' -and -not [bool]$pauseState.requested) {
                $round = [int](& $getValueCommand -Object $event.data -Name 'round' -Default 0)
                $stage = [string](& $getValueCommand -Object $event.data -Name 'stage' -Default '')
                if ($round -eq 1 -and $stage -ceq 'independent-draft') {
                    $pauseState.requested = $true
                    $null = & $requestPauseCommand -RunId $RunId -ResultsRoot $Root
                    $pauseState.count = [int]$pauseState.count + 1
                }
            }
            & $forwardObserver $event
        }.GetNewClosure()

        $result = $null
        $diagnostic = $null
        try {
            $result = Invoke-DuoForgeResumeLiveInternal -RunId $RunId -ResultsRoot $Root -LiveConsent $true -ProgressObserver $observer
        }
        catch {
            if ($_.Exception.Data.Contains('DuoForgeCode')) {
                $diagnostic = [ordered]@{ code = [string]$_.Exception.Data['DuoForgeCode'] }
            }
            throw
        }
        finally {
            try { Close-DuoForgeProgressViewInternal -View $view -Result $result -ErrorDiagnostic $diagnostic } catch { }
        }

        return [ordered]@{
            result = $result
            initialViewMode = $initialViewMode
            finalViewMode = [string]$view.mode
            observerFailureCount = [int]$view.observerFailureCount
            pauseRequestCount = [int]$pauseState.count
            ticks = [ordered]@{
                codex = @($tickElapsed.codex)
                claude = @($tickElapsed.claude)
            }
            distinctSpinnerFrames = [ordered]@{
                codex = [int]$spinnerFrames.codex.Count
                claude = [int]$spinnerFrames.claude.Count
            }
        }
    } $run.runId $ResultsRoot

    $runDirectory = [string]$run.runDirectory
    $manifest = Read-LiveProgressJson -Path (Join-Path $runDirectory 'manifest.json')
    $state = Read-LiveProgressJson -Path (Join-Path $runDirectory 'state.json')
    $steps = Read-LiveProgressJson -Path (Join-Path $runDirectory 'steps.json')
    $inventory = Read-LiveProgressJson -Path (Join-Path $runDirectory 'inputs\inventory.json')
    $eventPath = Join-Path $runDirectory 'events.jsonl'
    $eventText = Get-Content -LiteralPath $eventPath -Raw -Encoding UTF8
    $diagnosticPath = Join-Path $runDirectory 'diagnostics.jsonl'
    $diagnosticRows = if (Test-Path -LiteralPath $diagnosticPath -PathType Leaf) {
        @(Get-Content -LiteralPath $diagnosticPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -Depth 100 })
    }
    else { @() }
    $committed = @($steps.steps | Where-Object { [string]$_.status -ceq 'COMMITTED' })
    $calls = [ordered]@{
        codex = [int](@($steps.steps | Where-Object { [string]$_.provider -ceq 'codex' } | ForEach-Object { [int]$(if ($null -ne $_.totalAttemptCount) { $_.totalAttemptCount } else { $_.attemptCount }) } | Measure-Object -Sum).Sum)
        claude = [int](@($steps.steps | Where-Object { [string]$_.provider -ceq 'claude' } | ForEach-Object { [int]$(if ($null -ne $_.totalAttemptCount) { $_.totalAttemptCount } else { $_.attemptCount }) } | Measure-Object -Sum).Sum)
    }
    $totalCalls = [int]$calls.codex + [int]$calls.claude
    $forbiddenKeyPattern = '"(?i:stdout|stderr|prompt|promptText|document|documentText|context|contextText|raw|rawOutput|responseText|secret|apiKey|accessToken|refreshToken|authorization|password|content|text)"\s*:'
    $providerWorkRoot = Join-Path $runDirectory 'provider-work'
    $providerWorkCount = if (Test-Path -LiteralPath $providerWorkRoot -PathType Container) { @(Get-ChildItem -LiteralPath $providerWorkRoot -Force).Count } else { 0 }
    $snapshot = @($inventory.snapshots | Select-Object -First 1)

    Assert-LiveProgressInvariant ([string]$manifest.workflowVersion -ceq 'workflow-v2') 'WORKFLOW'
    Assert-LiveProgressInvariant ([string]$manifest.providerSelections.codex.model -ceq 'gpt-5.6-luna' -and [string]$manifest.providerSelections.codex.reasoningEffort -ceq 'low') 'CODEX-MANIFEST'
    Assert-LiveProgressInvariant ([string]$manifest.providerSelections.claude.model -ceq 'sonnet' -and [string]$manifest.providerSelections.claude.reasoningEffort -ceq 'low') 'CLAUDE-MANIFEST'
    if ([string]$state.status -cne 'PAUSED_USER' -or [string]$execution.result.status -cne 'PAUSED_USER') {
        $failureCode = if ($diagnosticRows.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$diagnosticRows[-1].code)) {
            [string]$diagnosticRows[-1].code
        }
        else { 'DF-LIVE-PROGRESS-END-STATE' }
        throw [System.InvalidOperationException]::new($failureCode)
    }
    Assert-LiveProgressInvariant ($committed.Count -eq 2) 'COMMITTED-COUNT'
    Assert-LiveProgressInvariant ((@($committed.provider) -join ',') -ceq 'codex,claude') 'BARRIER-ORDER'
    Assert-LiveProgressInvariant ([int]$execution.pauseRequestCount -eq 1) 'PAUSE-REQUEST-COUNT'
    Assert-LiveProgressInvariant ($totalCalls -ge 2 -and $totalCalls -le 4) 'CALL-LIMIT'
    Assert-LiveProgressInvariant ($totalCalls -eq 2) 'FORMAT-RECOVERY-NOT-CLEAN'
    Assert-LiveProgressInvariant ([string]$execution.initialViewMode -ceq 'fullscreen' -and [string]$execution.finalViewMode -ceq 'fullscreen') 'FULLSCREEN'
    Assert-LiveProgressInvariant ([int]$execution.observerFailureCount -eq 0) 'OBSERVER'
    foreach ($provider in @('codex', 'claude')) {
        $elapsed = @($execution.ticks[$provider])
        Assert-LiveProgressInvariant ($elapsed.Count -ge 2 -and [int]$elapsed[0] -eq 0 -and [int]($elapsed | Measure-Object -Maximum).Maximum -ge 1) ("$($provider.ToUpperInvariant())-TICKS")
        Assert-LiveProgressInvariant ([int]$execution.distinctSpinnerFrames[$provider] -ge 2) ("$($provider.ToUpperInvariant())-SPINNER")
    }
    Assert-LiveProgressInvariant ($providerWorkCount -eq 0) 'PROVIDER-WORK'
    Assert-LiveProgressInvariant ($eventText -notmatch '(?i)"type"\s*:\s*"[^"]*(tool|command|shell|web|mcp)[^"]*"') 'EVENT-TYPE'
    Assert-LiveProgressInvariant ($eventText -notmatch $forbiddenKeyPattern) 'EVENT-KEY'
    foreach ($row in $diagnosticRows) {
        $diagnosticText = $row | ConvertTo-Json -Depth 100 -Compress
        Assert-LiveProgressInvariant ($diagnosticText -notmatch $forbiddenKeyPattern) 'DIAGNOSTIC-KEY'
    }
    Assert-LiveProgressInvariant ($snapshot.Count -eq 1) 'SNAPSHOT'
    Assert-LiveProgressInvariant ([string]::Equals([string]$snapshot[0].sourceHash, [string]$snapshot[0].snapshotHash, [StringComparison]::OrdinalIgnoreCase)) 'SNAPSHOT-RECORD'
    Assert-LiveProgressInvariant ([string]::Equals((Get-FileHash -LiteralPath ([string]$snapshot[0].snapshotPath) -Algorithm SHA256).Hash, ([string]$snapshot[0].snapshotHash -replace '^(?i)sha256:', ''), [StringComparison]::OrdinalIgnoreCase)) 'SNAPSHOT-HASH'
    Assert-LiveProgressInvariant ([string]::Equals((Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash, $fixtureHashBefore, [StringComparison]::OrdinalIgnoreCase)) 'SOURCE-HASH'

    $summary = [ordered]@{
        schemaVersion = 1
        runId = [string]$run.runId
        status = [string]$state.status
        committedSteps = $committed.Count
        calls = $calls
        totalCalls = $totalCalls
        progress = [ordered]@{
            mode = [string]$execution.finalViewMode
            codexTicks = @($execution.ticks.codex).Count
            claudeTicks = @($execution.ticks.claude).Count
            codexMaximumElapsedSeconds = [int](@($execution.ticks.codex) | Measure-Object -Maximum).Maximum
            claudeMaximumElapsedSeconds = [int](@($execution.ticks.claude) | Measure-Object -Maximum).Maximum
            codexDistinctSpinnerFrames = [int]$execution.distinctSpinnerFrames.codex
            claudeDistinctSpinnerFrames = [int]$execution.distinctSpinnerFrames.claude
            observerFailures = [int]$execution.observerFailureCount
        }
        pauseRequestCount = [int]$execution.pauseRequestCount
        providerWorkArtifacts = $providerWorkCount
        diagnosticRowsParsed = $diagnosticRows.Count
        sensitiveEventOrDiagnosticKeys = 0
        inputHashesUnchanged = $true
        runDirectory = [System.IO.Path]::GetRelativePath($projectRoot, $runDirectory)
    }
    $summaryPath = Join-Path $ResultsRoot 'latest-safe-summary.json'
    [System.IO.Directory]::CreateDirectory($ResultsRoot) | Out-Null
    [System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
    $summary | ConvertTo-Json -Depth 20 -Compress
}
catch {
    $code = if ($_.Exception.Data.Contains('DuoForgeCode')) { [string]$_.Exception.Data['DuoForgeCode'] }
    elseif ($_.Exception.Message -match '^DF-[A-Z0-9-]+') { [string]([regex]::Match($_.Exception.Message, '^DF-[A-Z0-9-]+').Value) }
    else { 'DF-LIVE-PROGRESS' }
    [ordered]@{
        schemaVersion = 1
        runId = if ($null -eq $run) { $null } else { [string]$run.runId }
        status = 'FAILED'
        code = $code
        exceptionType = $_.Exception.GetType().Name
    } | ConvertTo-Json -Depth 5 -Compress
    exit 1
}
