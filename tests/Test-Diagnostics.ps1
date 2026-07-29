function Get-DuoForgeDiagnosticTestRecords {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $records.Add(($line | ConvertFrom-Json -Depth 100))
    }
    return @($records)
}

function Assert-DuoForgeDiagnosticTestProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][string]$Context
    )

    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expected = @($Allowed | Sort-Object)
    Assert-Equal ($actual -join ',') ($expected -join ',') "$Context 허용 목록이 다릅니다."
}

function Assert-DuoForgeDiagnosticTestRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)

    Assert-DuoForgeDiagnosticTestProperties -Value $Record -Allowed @(
        'schemaVersion', 'at', 'diagnosticId', 'recordType', 'scope', 'code', 'category', 'phase', 'severity', 'publicSummary',
        'run', 'step', 'process', 'recovery', 'environment', 'stack'
    ) -Context 'diagnostic'
    Assert-DuoForgeDiagnosticTestProperties -Value $Record.run -Allowed @('runId', 'workflowVersion', 'status', 'lastCompletedStage') -Context 'run'
    Assert-DuoForgeDiagnosticTestProperties -Value $Record.step -Allowed @('stepKey', 'provider', 'stage', 'targetDocumentId', 'round', 'attempt') -Context 'step'
    Assert-DuoForgeDiagnosticTestProperties -Value $Record.process -Allowed @('started', 'timedOut', 'exitCode', 'errorCategory', 'exceptionType', 'hresult', 'stdoutBytes', 'stderrBytes') -Context 'process'
    Assert-DuoForgeDiagnosticTestProperties -Value $Record.recovery -Allowed @('retryable', 'retryMode', 'scheduled') -Context 'recovery'
    Assert-DuoForgeDiagnosticTestProperties -Value $Record.environment -Allowed @('duoforgeVersion', 'powershellVersion', 'powershellEdition', 'osDescription', 'processArchitecture', 'providerVersions') -Context 'environment'
    Assert-DuoForgeDiagnosticTestProperties -Value $Record.environment.providerVersions -Allowed @('codex', 'claude') -Context 'providerVersions'
    foreach ($frame in @($Record.stack)) {
        Assert-DuoForgeDiagnosticTestProperties -Value $frame -Allowed @('moduleRelativeFile', 'line', 'function') -Context 'stack frame'
    }
}

function New-DuoForgeDiagnosticTestRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $input = New-MarkdownFile -Path (Join-Path $tempRoot "$Name\input\brief.md")
    $workspace = Join-Path $tempRoot "$Name\results"
    $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
    $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
    Assert-True ([bool]$validation.valid) ($validation.errors | ConvertTo-Json -Depth 20 -Compress)
    return New-DuoForgeRun -ValidationResult $validation
}

$diagnosticCanaries = @(
    'DIAG-STDOUT-CANARY',
    'DIAG-STDERR-CANARY',
    'DIAG-PROMPT-CANARY',
    'DIAG-DOCUMENT-CANARY',
    'DIAG-CONTEXT-CANARY',
    'DIAG-MODEL-RESULT-CANARY',
    'DIAG-ARGUMENT-CANARY',
    'DIAG-ENVIRONMENT-CANARY',
    'DIAG-AUTH-CANARY',
    'DIAG-ABSOLUTE-INPUT-CANARY',
    'DIAG-EXCEPTION-MESSAGE-CANARY',
    'DIAG-EXCEPTION-DATA-CANARY'
)

Test-Case '진단 writer는 run 파일에 허용 목록 스키마만 UTF-8 JSONL로 기록한다' {
    $run = New-DuoForgeDiagnosticTestRun -Name 'diagnostic-writer-run'
    Assert-False (Test-Path -LiteralPath (Join-Path $run.runDirectory 'logs')) '신규 실행에 사용되지 않는 logs 폴더가 생성되었습니다.'
    Assert-False (Test-Path -LiteralPath (Join-Path $run.runDirectory 'diagnostics.jsonl')) '오류 없는 신규 실행에 빈 진단 파일이 생성되었습니다.'

    $errorRecord = $null
    try {
        $exception = [InvalidOperationException]::new('DIAG-EXCEPTION-MESSAGE-CANARY')
        $exception.Data['arbitrary'] = 'DIAG-EXCEPTION-DATA-CANARY'
        throw $exception
    }
    catch { $errorRecord = $_ }

    $written = & $module {
        param($directory, $runId, $error)
        Write-DuoForgeDiagnosticInternal -RunDirectory $directory -Code 'DF-STAGE-UNEXPECTED' -Category 'provider-error' -Phase 'stage' -Scope 'run' `
            -Run ([ordered]@{ runId = $runId; workflowVersion = 'workflow-v2'; status = 'RUNNING'; lastCompletedStage = '' }) `
            -Step ([ordered]@{ stepKey = 'r01-codex-independent-draft'; provider = 'codex'; stage = 'independent-draft'; targetDocumentId = 'merged'; round = 1; attempt = 1; prompt = 'DIAG-PROMPT-CANARY'; document = 'DIAG-DOCUMENT-CANARY'; modelResult = 'DIAG-MODEL-RESULT-CANARY' }) `
            -Process ([ordered]@{ started = $true; timedOut = $false; exitCode = 7; errorCategory = 'nonzero-exit'; exceptionType = ''; hresult = $null; stdoutBytes = 18; stderrBytes = 18; stdout = 'DIAG-STDOUT-CANARY'; stderr = 'DIAG-STDERR-CANARY'; arguments = 'DIAG-ARGUMENT-CANARY'; environment = 'DIAG-ENVIRONMENT-CANARY' }) `
            -Recovery ([ordered]@{ retryable = $false; retryMode = ''; scheduled = $false }) -ErrorRecord $error
    } $run.runDirectory $run.runId $errorRecord

    Assert-True ([bool]$written.written)
    Assert-Equal $written.location 'run'
    Assert-Equal $written.relativePath 'diagnostics.jsonl'
    Assert-Equal $written.diagnosticsPath (Join-Path $run.runDirectory 'diagnostics.jsonl')
    $records = @(Get-DuoForgeDiagnosticTestRecords -Path $written.diagnosticsPath)
    Assert-Equal $records.Count 1
    Assert-DuoForgeDiagnosticTestRecord -Record $records[0]
    Assert-Equal $records[0].diagnosticId $written.diagnosticId
    Assert-Equal $records[0].schemaVersion 1
    Assert-Equal $records[0].publicSummary '단계 실행 중 예상하지 못한 오류가 발생했습니다.'
    $json = $records[0] | ConvertTo-Json -Depth 100 -Compress
    foreach ($canary in $diagnosticCanaries) { Assert-NotContainsText $json $canary }
}

Test-Case 'run 진단 append 실패와 run 부재는 격리된 local 진단 경로로 폴백한다' {
    $previousDataRoot = $env:DUOFORGE_DATA_ROOT
    $localRoot = Join-Path $tempRoot 'diagnostic-local-fallback'
    $env:DUOFORGE_DATA_ROOT = $localRoot
    try {
        $run = New-DuoForgeDiagnosticTestRun -Name 'diagnostic-fallback-run'
        [System.IO.Directory]::CreateDirectory((Join-Path $run.runDirectory 'diagnostics.jsonl')) | Out-Null
        $fallback = & $module {
            param($directory, $runId)
            Write-DuoForgeDiagnosticInternal -RunDirectory $directory -Code 'DF-PROVIDER-PROCESS' -Category 'provider-process' -Phase 'provider' -Scope 'run' -Run ([ordered]@{ runId = $runId; workflowVersion = 'workflow-v2'; status = 'RUNNING'; lastCompletedStage = '' })
        } $run.runDirectory $run.runId
        Assert-True ([bool]$fallback.written)
        Assert-Equal $fallback.location 'local'
        Assert-True ($fallback.diagnosticsPath.StartsWith((Join-Path $localRoot 'diagnostics'), [StringComparison]::OrdinalIgnoreCase))
        $fallbackRecords = @(Get-DuoForgeDiagnosticTestRecords -Path $fallback.diagnosticsPath)
        Assert-Equal $fallbackRecords.Count 1
        Assert-Equal $fallbackRecords[0].scope 'local'

        $preRun = & $module {
            Write-DuoForgeDiagnosticInternal -Code 'DF-CLI-COMMAND' -Category 'cli' -Phase 'pre-run' -Scope 'local'
        }
        Assert-Equal $preRun.location 'local'
        Assert-True (Test-Path -LiteralPath $preRun.diagnosticsPath -PathType Leaf)
    }
    finally {
        $env:DUOFORGE_DATA_ROOT = $previousDataRoot
    }
}

Test-Case '프로세스 진단은 본문 대신 종료 상태와 UTF-8 바이트 수만 보존한다' {
    $run = New-DuoForgeDiagnosticTestRun -Name 'diagnostic-process'
    $processResult = & $module {
        $invocation = [ordered]@{
            fileName = (Get-Process -Id $PID).Path
            prefixArguments = @()
            commandSource = 'DIAG-ABSOLUTE-INPUT-CANARY'
            source = 'DIAG-ABSOLUTE-INPUT-CANARY'
        }
        Invoke-DuoForgeProcess -CommandName 'pwsh' -CommandInvocation $invocation -Arguments @('-NoLogo', '-NoProfile', '-Command', "[Console]::Out.Write('DIAG-STDOUT-CANARY'); [Console]::Error.Write('DIAG-STDERR-CANARY'); exit 7") -EnvironmentOverrides ([ordered]@{ DUOFORGE_TEST_SECRET = 'DIAG-ENVIRONMENT-CANARY' }) -TimeoutSeconds 10
    }
    Assert-True ([bool]$processResult.started)
    Assert-Equal $processResult.exitCode 7
    Assert-Equal $processResult.errorCategory 'nonzero-exit'
    Assert-True ([int64]$processResult.stdoutBytes -gt 0)
    Assert-True ([int64]$processResult.stderrBytes -gt 0)

    $written = & $module {
        param($directory, $runId, $process)
        Write-DuoForgeDiagnosticInternal -RunDirectory $directory -Code 'DF-PROVIDER-PROCESS' -Category 'provider-process' -Phase 'process' -Scope 'run' -Run ([ordered]@{ runId = $runId; workflowVersion = 'workflow-v2'; status = 'RUNNING'; lastCompletedStage = '' }) -Process $process
    } $run.runDirectory $run.runId $processResult
    $record = @(Get-DuoForgeDiagnosticTestRecords -Path $written.diagnosticsPath)[0]
    Assert-Equal $record.process.exitCode 7
    Assert-Equal $record.process.errorCategory 'nonzero-exit'
    Assert-Equal $record.process.stdoutBytes $processResult.stdoutBytes
    Assert-Equal $record.process.stderrBytes $processResult.stderrBytes
    $json = $record | ConvertTo-Json -Depth 100 -Compress
    Assert-NotContainsText $json 'DIAG-STDOUT-CANARY'
    Assert-NotContainsText $json 'DIAG-STDERR-CANARY'
    Assert-NotContainsText $json 'DIAG-ENVIRONMENT-CANARY'
    Assert-NotContainsText $json 'DIAG-ABSOLUTE-INPUT-CANARY'
}

Test-Case '단계 실패는 diagnostics steps events observer result와 화면을 한 ID로 연결한다' {
    $run = New-DuoForgeDiagnosticTestRun -Name 'diagnostic-stage-correlation'
    $observerEvents = [System.Collections.Generic.List[object]]::new()
    $result = & $module {
        param($directory, $events)
        $callback = {
            param($step)
            $exception = New-DuoForgeException -Code 'DF-PROVIDER-PROCESS' -Message 'DIAG-EXCEPTION-MESSAGE-CANARY'
            $exception.Data['DuoForgeFailureCategory'] = 'provider-process'
            $exception.Data['DuoForgeFailureStatus'] = 'RESUMABLE_ERROR'
            $exception.Data['DuoForgeRetryable'] = $false
            $exception.Data['DuoForgeValidationErrors'] = @('DIAG-DOCUMENT-CANARY')
            $exception.Data['arbitrary'] = 'DIAG-EXCEPTION-DATA-CANARY'
            $exception.Data['DuoForgeProcess'] = [ordered]@{ started = $true; timedOut = $false; exitCode = 17; errorCategory = 'nonzero-exit'; exceptionType = ''; hresult = $null; stdoutBytes = 18; stderrBytes = 18; stdout = 'DIAG-STDOUT-CANARY'; stderr = 'DIAG-STDERR-CANARY' }
            throw $exception
        }
        $observer = { param($event) $events.Add($event) }.GetNewClosure()
        Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback -ProgressObserver $observer
    } $run.runDirectory $observerEvents

    Assert-Equal $result.status 'RESUMABLE_ERROR'
    Assert-Equal $result.code 'DF-PROVIDER-PROCESS'
    Assert-False ([string]::IsNullOrWhiteSpace([string]$result.diagnosticId))
    Assert-Equal $result.diagnosticsPath (Join-Path $run.runDirectory 'diagnostics.jsonl')
    $graph = Get-Content -LiteralPath (Join-Path $run.runDirectory 'steps.json') -Raw | ConvertFrom-Json -Depth 100
    $failedStep = @($graph.steps | Where-Object status -eq 'FAILED')[0]
    $durable = @(Get-Content -LiteralPath (Join-Path $run.runDirectory 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -Depth 100 })
    $failedEvent = @($durable | Where-Object type -eq 'STAGE_FAILED')[-1]
    $observerEvent = @($observerEvents | Where-Object type -eq 'STAGE_FAILED')[-1]
    foreach ($value in @($failedStep.lastError.diagnosticId, $failedEvent.data.diagnosticId, $observerEvent.data.diagnosticId)) { Assert-Equal $value $result.diagnosticId }
    Assert-Equal $failedStep.lastError.diagnosticsLocation 'run'
    Assert-Equal $failedStep.lastError.diagnosticsRelativePath 'diagnostics.jsonl'
    Assert-False $observerEvent.data.Contains('diagnosticsPath')
    Assert-Equal $observerEvent.data.diagnosticsRelativePath 'diagnostics.jsonl'
    $record = @(Get-DuoForgeDiagnosticTestRecords -Path $result.diagnosticsPath | Where-Object diagnosticId -eq $result.diagnosticId)[0]
    Assert-Equal $record.code $result.code
    Assert-Equal $record.process.exitCode 17

    $rendered = & $module {
        param($directory, $event, $resultValue)
        $event = ConvertTo-DuoForgeHashtable -InputObject $event
        $snapshot = Get-DuoForgeProgressSnapshotInternal -RunDirectory $directory -LastEvent $event
        $wide = @(New-DuoForgeProgressFrameInternal -Snapshot $snapshot -Width 240 -Height 40)
        $narrow = @(New-DuoForgeProgressFrameInternal -Snapshot $snapshot -Width 72 -Height 20)
        $log = (& { Write-DuoForgeProgressLogEventInternal -View ([ordered]@{ runDirectory = $directory }) -Event $event } 6>&1 | Out-String)
        $return = (& { Write-DuoForgeDiagnosticReferenceInternal -Source $resultValue } 6>&1 | Out-String)
        [ordered]@{ wide = $wide; narrow = $narrow; log = $log; return = $return }
    } $run.runDirectory $failedEvent $result
    Assert-ContainsText ($rendered.wide -join "`n") $result.code
    Assert-ContainsText ($rendered.wide -join "`n") $result.diagnosticId
    Assert-ContainsText ($rendered.wide -join "`n") $result.diagnosticsPath
    Assert-ContainsText (($rendered.narrow -join '') -replace '\s+$','') $result.diagnosticsPath
    foreach ($surface in @([string]$rendered.log, [string]$rendered.return)) {
        Assert-ContainsText $surface $result.code
        Assert-ContainsText $surface $result.diagnosticId
        Assert-ContainsText $surface $result.diagnosticsPath
    }
    $allSurfaces = ($record | ConvertTo-Json -Depth 100 -Compress) + ($durable | ConvertTo-Json -Depth 100 -Compress) + ($observerEvents | ConvertTo-Json -Depth 100 -Compress) + ($rendered.wide -join "`n") + $rendered.log + $rendered.return
    foreach ($canary in $diagnosticCanaries) { Assert-NotContainsText $allSurfaces $canary }
}

Test-Case '형식 복구 재시도와 최종 실패는 서로 다른 진단 ID와 복구 의미를 보존한다' {
    $run = New-DuoForgeDiagnosticTestRun -Name 'diagnostic-retry-final'
    $observerEvents = [System.Collections.Generic.List[object]]::new()
    $result = & $module {
        param($directory, $events)
        $callback = {
            param($step)
            $fake = New-DuoForgeFakeStageResult -Step $step
            $fake.provider = if ([string]$step.provider -eq 'codex') { 'claude' } else { 'codex' }
            $fake
        }
        $observer = { param($event) $events.Add($event) }.GetNewClosure()
        Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback -ProgressObserver $observer
    } $run.runDirectory $observerEvents
    Assert-Equal $result.status 'RESUMABLE_ERROR'
    Assert-Equal $result.code 'DF-STAGE-SCHEMA'
    $records = @(Get-DuoForgeDiagnosticTestRecords -Path $result.diagnosticsPath | Where-Object code -eq 'DF-STAGE-SCHEMA')
    Assert-Equal $records.Count 3 ($records | ConvertTo-Json -Depth 100 -Compress)
    Assert-Equal @($records.diagnosticId | Sort-Object -Unique).Count 3
    foreach ($retryRecord in @($records | Select-Object -First 2)) {
        Assert-True ([bool]$retryRecord.recovery.retryable)
        Assert-True ([bool]$retryRecord.recovery.scheduled)
        Assert-Equal $retryRecord.recovery.retryMode 'FORMAT_REPAIR'
    }
    Assert-False ([bool]$records[-1].recovery.scheduled)
    Assert-Equal $records[-1].diagnosticId $result.diagnosticId
    $retryEvents = @($observerEvents | Where-Object type -eq 'STAGE_RETRY_SCHEDULED')
    Assert-Equal $retryEvents.Count 2
    Assert-Equal (@($retryEvents.data.diagnosticId) -join ',') (@($records | Select-Object -First 2 | ForEach-Object diagnosticId) -join ',')
    $failedEvent = @($observerEvents | Where-Object type -eq 'STAGE_FAILED')[-1]
    Assert-Equal $failedEvent.data.diagnosticId $records[-1].diagnosticId
}

Test-Case '중단 복구 소진과 최종 renderer 실패도 동일 진단 상관관계를 제공한다' {
    $interruptedRun = New-DuoForgeDiagnosticTestRun -Name 'diagnostic-interrupted'
    & $module {
        param($directory)
        $graph = Initialize-DuoForgeStageGraph -RunDirectory $directory
        $graph.steps[0].status = 'STARTED'
        $graph.steps[0].attemptCount = 2
        Write-DuoForgeJsonAtomic -Path (Join-Path $directory 'steps.json') -Value $graph
    } $interruptedRun.runDirectory
    $interruptedEvents = [System.Collections.Generic.List[object]]::new()
    $calls = @{ count = 0 }
    $interruptedResult = & $module {
        param($directory, $events, $control)
        $callback = { param($step) $control.count++; New-DuoForgeFakeStageResult -Step $step }.GetNewClosure()
        $observer = { param($event) $events.Add($event) }.GetNewClosure()
        Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback -ProgressObserver $observer
    } $interruptedRun.runDirectory $interruptedEvents $calls
    Assert-Equal $interruptedResult.code 'DF-STAGE-RETRY-EXHAUSTED'
    Assert-Equal $calls.count 0
    $interruptedGraph = Get-Content -LiteralPath (Join-Path $interruptedRun.runDirectory 'steps.json') -Raw | ConvertFrom-Json -Depth 100
    Assert-Equal $interruptedGraph.steps[0].lastError.code $interruptedResult.code
    Assert-Equal $interruptedGraph.steps[0].lastError.diagnosticId $interruptedResult.diagnosticId
    foreach ($type in @('STAGE_INTERRUPTED_RECOVERED', 'STAGE_FAILED')) {
        $event = @($interruptedEvents | Where-Object type -eq $type)[-1]
        Assert-Equal $event.data.code $interruptedResult.code
        Assert-Equal $event.data.diagnosticId $interruptedResult.diagnosticId
    }

    $rendererRun = New-DuoForgeDiagnosticTestRun -Name 'diagnostic-renderer'
    $rendererEvents = [System.Collections.Generic.List[object]]::new()
    $rendererResult = & $module {
        param($directory, $events)
        $callback = { param($step) New-DuoForgeFakeStageResult -Step $step }
        $renderer = { param($runDirectory, $graph) throw (New-DuoForgeException -Code 'DF-FINAL-RENDERER' -Message 'DIAG-EXCEPTION-MESSAGE-CANARY') }
        $observer = { param($event) $events.Add($event) }.GetNewClosure()
        Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback -ProgressObserver $observer -FinalRenderer $renderer
    } $rendererRun.runDirectory $rendererEvents
    Assert-Equal $rendererResult.status 'RESUMABLE_ERROR'
    Assert-Equal $rendererResult.code 'DF-FINAL-RENDERER'
    Assert-True (Test-Path -LiteralPath $rendererResult.diagnosticsPath -PathType Leaf)
    $rendererEvent = @($rendererEvents | Where-Object type -eq 'FINAL_ARTIFACTS_FAILED')[-1]
    Assert-Equal $rendererEvent.data.diagnosticId $rendererResult.diagnosticId
    $rendererRecord = @(Get-DuoForgeDiagnosticTestRecords -Path $rendererResult.diagnosticsPath | Where-Object diagnosticId -eq $rendererResult.diagnosticId)[0]
    Assert-Equal $rendererRecord.code 'DF-FINAL-RENDERER'
}

Test-Case '진단 writer 이중 실패는 원래 DF 오류를 가리지 않고 안전 경고만 반환한다' {
    $previousDataRoot = $env:DUOFORGE_DATA_ROOT
    $run = New-DuoForgeDiagnosticTestRun -Name 'diagnostic-writer-double-failure'
    [System.IO.Directory]::CreateDirectory((Join-Path $run.runDirectory 'diagnostics.jsonl')) | Out-Null
    $blockedLocalRoot = Join-Path $tempRoot 'diagnostic-blocked-local-root'
    [System.IO.File]::WriteAllText($blockedLocalRoot, 'blocked', [System.Text.UTF8Encoding]::new($false))
    $env:DUOFORGE_DATA_ROOT = $blockedLocalRoot
    try {
        $result = & $module {
            param($directory)
            $callback = {
                param($step)
                throw (New-DuoForgeException -Code 'DF-TEST-ORIGINAL' -Message 'DIAG-EXCEPTION-MESSAGE-CANARY')
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $result.code 'DF-TEST-ORIGINAL'
        Assert-Equal $result.status 'RESUMABLE_ERROR'
        Assert-Equal $result.diagnosticWarningCode 'DF-DIAGNOSTIC-WRITE'
        Assert-False ([string]::IsNullOrWhiteSpace([string]$result.diagnosticId))
        Assert-True ([string]::IsNullOrWhiteSpace([string]$result.diagnosticsPath))
    }
    finally {
        $env:DUOFORGE_DATA_ROOT = $previousDataRoot
    }
}

Test-Case 'run 생성 전 CLI 오류는 local 진단에 기록되고 원시 명령 인자를 기록하지 않는다' {
    $previousDataRoot = $env:DUOFORGE_DATA_ROOT
    $localRoot = Join-Path $tempRoot 'diagnostic-cli-local'
    $env:DUOFORGE_DATA_ROOT = $localRoot
    try {
        $captured = $null
        try { Invoke-DuoForgeCli -Arguments @('DIAG-ARGUMENT-CANARY') }
        catch { $captured = $_ }
        Assert-True ($null -ne $captured)
        $code = [string]$captured.Exception.Data['DuoForgeCode']
        $diagnosticId = [string]$captured.Exception.Data['DuoForgeDiagnosticId']
        $diagnosticsPath = [string]$captured.Exception.Data['DuoForgeDiagnosticsPath']
        Assert-Equal $code 'DF-CLI-COMMAND'
        Assert-False ([string]::IsNullOrWhiteSpace($diagnosticId))
        Assert-True (Test-Path -LiteralPath $diagnosticsPath -PathType Leaf)
        $record = @(Get-DuoForgeDiagnosticTestRecords -Path $diagnosticsPath)[0]
        Assert-Equal $record.diagnosticId $diagnosticId
        Assert-NotContainsText ($record | ConvertTo-Json -Depth 100 -Compress) 'DIAG-ARGUMENT-CANARY'
    }
    finally {
        $env:DUOFORGE_DATA_ROOT = $previousDataRoot
    }
}

Test-Case 'run 폴더 생성 전 요청 오류도 local 진단을 남기고 원래 코드를 보존한다' {
    $previousDataRoot = $env:DUOFORGE_DATA_ROOT
    $localRoot = Join-Path $tempRoot 'diagnostic-run-create-local'
    $env:DUOFORGE_DATA_ROOT = $localRoot
    try {
        $captured = $null
        try { New-DuoForgeRun -ValidationResult ([ordered]@{ valid = $false }) }
        catch { $captured = $_ }
        Assert-True ($null -ne $captured)
        Assert-Equal ([string]$captured.Exception.Data['DuoForgeCode']) 'DF-RUN-INVALID'
        $diagnosticsPath = [string]$captured.Exception.Data['DuoForgeDiagnosticsPath']
        Assert-True (Test-Path -LiteralPath $diagnosticsPath -PathType Leaf)
        $record = @(Get-DuoForgeDiagnosticTestRecords -Path $diagnosticsPath)[0]
        Assert-Equal $record.code 'DF-RUN-INVALID'
        Assert-Equal $record.scope 'local'
    }
    finally { $env:DUOFORGE_DATA_ROOT = $previousDataRoot }
}

Test-Case '메뉴 복귀 화면과 명시적 resume --live JSON은 같은 진단 참조를 보존한다' {
    $run = New-DuoForgeDiagnosticTestRun -Name 'diagnostic-menu-cli'
    $run['state'] = Get-Content -LiteralPath (Join-Path $run.runDirectory 'state.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $fake = [ordered]@{
        status = 'RESUMABLE_ERROR'
        code = 'DF-STAGE-UNEXPECTED'
        diagnosticId = 'diag-20260730T000000000Z-abcdef123456'
        diagnosticsPath = (Join-Path $run.runDirectory 'diagnostics.jsonl')
        diagnosticsLocation = 'run'
        diagnosticsRelativePath = 'diagnostics.jsonl'
    }
    $surfaces = & $module {
        param($runValue, $resultValue, $workspace)
        $inputReader = { param($prompt) 'LIVE' }
        $resumeInvoker = { param($runId, $resultsRoot, $waitForAcknowledgement) $resultValue }.GetNewClosure()
        $interactiveProbe = { $true }
        $menuText = (& {
            Invoke-DuoForgeInteractiveLiveResume -Run $runValue -InputReader $inputReader -ResumeInvoker $resumeInvoker
        } 6>&1 | Out-String)
        $cliOutput = @(
            Invoke-DuoForgeCliCoreInternal -Arguments @('resume', '--run', [string]$runValue.runId, '--workspace', $workspace, '--live') `
                -InputReader $inputReader -ResumeInvoker $resumeInvoker -InteractiveHostProbe $interactiveProbe
        )
        [ordered]@{ menu = $menuText; cli = [string]$cliOutput[-1] }
    } $run $fake ([System.IO.Path]::GetDirectoryName($run.runDirectory))

    foreach ($value in @($fake.code, $fake.diagnosticId, $fake.diagnosticsPath)) {
        Assert-ContainsText $surfaces.menu $value
    }
    $cliResult = $surfaces.cli | ConvertFrom-Json -Depth 100
    Assert-Equal $cliResult.code $fake.code
    Assert-Equal $cliResult.diagnosticId $fake.diagnosticId
    Assert-Equal $cliResult.diagnosticsPath $fake.diagnosticsPath
}

Test-Case 'CLI 엔트리포인트 오류 화면은 고정 요약과 진단 참조만 공개한다' {
    $localRoot = Join-Path $tempRoot 'diagnostic-entrypoint-local'
    $entrypoint = Join-Path $projectRoot 'duoforge.ps1'
    $process = & $module {
        param($scriptPath, $dataRoot)
        Invoke-DuoForgeProcess -CommandName 'pwsh' `
            -Arguments @('-NoLogo', '-NoProfile', '-File', $scriptPath, 'DIAG-ARGUMENT-CANARY') `
            -EnvironmentOverrides ([ordered]@{ DUOFORGE_DATA_ROOT = $dataRoot }) `
            -TimeoutSeconds 30
    } $entrypoint $localRoot

    Assert-True ([bool]$process.started)
    Assert-Equal ([int]$process.exitCode) 1
    $screen = @([string]$process.stdout, [string]$process.stderr) -join "`n"
    Assert-ContainsText $screen 'DF-CLI-COMMAND'
    Assert-NotContainsText $screen 'DIAG-ARGUMENT-CANARY'

    $files = @(Get-ChildItem -LiteralPath $localRoot -Recurse -File -Filter 'diagnostics.jsonl')
    Assert-Equal $files.Count 1
    $record = @(Get-DuoForgeDiagnosticTestRecords -Path $files[0].FullName)[0]
    Assert-Equal $record.code 'DF-CLI-COMMAND'
    Assert-ContainsText $screen $record.diagnosticId
    Assert-ContainsText $screen $files[0].FullName
    Assert-NotContainsText ($record | ConvertTo-Json -Depth 100 -Compress) 'DIAG-ARGUMENT-CANARY'
}

Test-Case '생성된 모든 diagnostics.jsonl 행은 Depth 100으로 재파싱되고 허용 목록을 지킨다' {
    $files = @(Get-ChildItem -LiteralPath $tempRoot -Recurse -File -Filter 'diagnostics.jsonl')
    Assert-True ($files.Count -gt 0) '검증할 diagnostics.jsonl이 생성되지 않았습니다.'
    $recordCount = 0
    foreach ($file in $files) {
        foreach ($record in @(Get-DuoForgeDiagnosticTestRecords -Path $file.FullName)) {
            $recordCount++
            Assert-DuoForgeDiagnosticTestRecord -Record $record
            $json = $record | ConvertTo-Json -Depth 100 -Compress
            foreach ($canary in $diagnosticCanaries) { Assert-NotContainsText $json $canary }
        }
    }
    Assert-True ($recordCount -gt 0) '파싱된 진단 행이 없습니다.'
}
