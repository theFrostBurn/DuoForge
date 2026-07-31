function New-DuoForgeProviderWorkDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$StepKey
    )

    if ($StepKey -notmatch '^[a-z0-9-]+$') {
        throw (New-DuoForgeException -Code 'DF-PROVIDER-STEP-KEY' -Message '공급자 작업 폴더에 안전하지 않은 단계 키입니다.')
    }
    $runFull = [System.IO.Path]::GetFullPath($RunDirectory).TrimEnd('\')
    $workDirectory = [System.IO.Path]::GetFullPath((Join-Path $runFull ("provider-work\{0}\{1}" -f $StepKey, [Guid]::NewGuid().ToString('N'))))
    if (-not $workDirectory.StartsWith($runFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-DuoForgeException -Code 'DF-PROVIDER-WORK-BOUNDARY' -Message '공급자 작업 폴더가 실행 폴더 밖으로 벗어났습니다.')
    }
    [System.IO.Directory]::CreateDirectory($workDirectory) | Out-Null
    return $workDirectory
}

function Remove-DuoForgeProviderWorkDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$WorkDirectory
    )

    $runFull = [System.IO.Path]::GetFullPath($RunDirectory).TrimEnd('\')
    $providerRoot = [System.IO.Path]::GetFullPath((Join-Path $runFull 'provider-work')).TrimEnd('\')
    $workFull = [System.IO.Path]::GetFullPath($WorkDirectory).TrimEnd('\')
    if (-not $workFull.StartsWith($providerRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or $workFull.Length -le $providerRoot.Length + 1) {
        throw (New-DuoForgeException -Code 'DF-PROVIDER-CLEANUP-BOUNDARY' -Message '검증되지 않은 공급자 작업 폴더는 정리하지 않습니다.')
    }
    if (Test-Path -LiteralPath $workFull -PathType Container) {
        [System.IO.Directory]::Delete($workFull, $true)
    }
    $stepDirectory = [System.IO.Path]::GetDirectoryName($workFull)
    if ($stepDirectory.StartsWith($providerRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $stepDirectory -PathType Container) -and @(Get-ChildItem -LiteralPath $stepDirectory -Force).Count -eq 0) {
        [System.IO.Directory]::Delete($stepDirectory, $false)
    }
    if ((Test-Path -LiteralPath $providerRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $providerRoot -Force).Count -eq 0) {
        [System.IO.Directory]::Delete($providerRoot, $false)
    }
}

function Get-DuoForgeStructuredProviderCommandSpecInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$Provider,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$OperationKey,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Prompt,
        [Parameter(Mandatory)]$Schema,
        [Parameter(Mandatory)][string]$SchemaFileName
    )

    if ($SchemaFileName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]+\.json$') {
        throw (New-DuoForgeException -Code 'DF-PROVIDER-SCHEMA-NAME' -Message '구조화 출력 스키마 파일명이 안전하지 않습니다.')
    }
    $selections = Get-DuoForgeRunProviderSelectionsInternal -RunDirectory $RunDirectory
    $selection = Get-DuoForgeObjectValue -Object $selections -Name $Provider
    $model = [string](Get-DuoForgeObjectValue -Object $selection -Name 'model')
    $reasoningEffort = [string](Get-DuoForgeObjectValue -Object $selection -Name 'reasoningEffort')
    $workDirectory = New-DuoForgeProviderWorkDirectory -RunDirectory $RunDirectory -StepKey $OperationKey
    $schemaPath = Join-Path $workDirectory $SchemaFileName
    Write-DuoForgeJsonAtomic -Path $schemaPath -Value $Schema

    if ($Provider -eq 'codex') {
        $lastMessagePath = Join-Path $workDirectory 'last-message.json'
        $arguments = @(
            '--ask-for-approval', 'never',
            '--model', $model,
            '--config', ('model_reasoning_effort="{0}"' -f $reasoningEffort),
            'exec',
            '--sandbox', 'read-only',
            '--skip-git-repo-check',
            '--ephemeral',
            '--ignore-user-config',
            '--ignore-rules',
            '--config', 'web_search="disabled"',
            '--output-schema', $schemaPath,
            '--json',
            '--output-last-message', $lastMessagePath,
            '-'
        )
        return [ordered]@{
            provider = $Provider
            commandName = 'codex'
            arguments = $arguments
            workingDirectory = $workDirectory
            outputPath = $lastMessagePath
            prompt = [string]$Prompt.text
            promptHash = [string]$Prompt.sha256
        }
    }

    $schemaJson = $Schema | ConvertTo-Json -Depth 100 -Compress
    return [ordered]@{
        provider = $Provider
        commandName = 'claude'
        arguments = @(
            '-p',
            '--model', $model,
            '--effort', $reasoningEffort,
            '--safe-mode',
            '--strict-mcp-config',
            '--tools', '',
            '--disallowedTools', 'mcp__*',
            '--no-chrome',
            '--no-session-persistence',
            '--permission-mode', 'dontAsk',
            '--output-format', 'json',
            '--json-schema', $schemaJson
        )
        workingDirectory = $workDirectory
        outputPath = $null
        prompt = [string]$Prompt.text
        promptHash = [string]$Prompt.sha256
    }
}

function Get-DuoForgeProviderCommandSpecInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$Provider,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Step,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Prompt
    )

    $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
    $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
    $schemaPath = Get-DuoForgeStageSchemaPath -WorkflowVersion $workflowVersion
    $schema = Read-DuoForgeJson -Path $schemaPath
    return Get-DuoForgeStructuredProviderCommandSpecInternal `
        -Provider $Provider `
        -RunDirectory $RunDirectory `
        -OperationKey ([string]$Step.stepKey) `
        -Prompt $Prompt `
        -Schema $schema `
        -SchemaFileName ([System.IO.Path]::GetFileName($schemaPath))
}

function Assert-DuoForgeCodexEventStreamSafe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$JsonLines)

    $forbiddenItemTypes = @('command_execution', 'file_change', 'mcp_tool_call', 'web_search')
    foreach ($line in @($JsonLines -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = $line | ConvertFrom-Json -Depth 30 }
        catch { throw (New-DuoForgeException -Code 'DF-CODEX-EVENT-JSON' -Message 'Codex JSONL 이벤트를 해석할 수 없습니다.') }
        $itemType = [string](Get-DuoForgeObjectValue -Object (Get-DuoForgeObjectValue -Object $event -Name 'item') -Name 'type')
        if ($itemType -in $forbiddenItemTypes) {
            throw (New-DuoForgeException -Code 'DF-PROVIDER-TOOL-EVENT' -Message "Codex가 금지된 실행 이벤트를 반환했습니다: $itemType")
        }
    }
}

function ConvertFrom-DuoForgeClaudeEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][string]$ExpectedStage,
        [ValidateSet('workflow-v1', 'workflow-v2')][string]$WorkflowVersion = 'workflow-v1',
        [AllowNull()][string]$ExpectedTargetDocumentId,
        [AllowEmptyCollection()][string[]]$ExpectedSourceDocumentIds = @()
    )

    try { $envelope = ConvertTo-DuoForgeHashtable -InputObject ($Json | ConvertFrom-Json -Depth 100) }
    catch { throw (New-DuoForgeException -Code 'DF-CLAUDE-ENVELOPE' -Message 'Claude JSON 결과 봉투를 해석할 수 없습니다.') }
    if ([bool](Get-DuoForgeObjectValue -Object $envelope -Name 'is_error' -Default $false)) {
        throw (New-DuoForgeException -Code 'DF-CLAUDE-RESULT' -Message 'Claude가 오류 결과를 반환했습니다.')
    }
    if ([string](Get-DuoForgeObjectValue -Object $envelope -Name 'subtype') -ne 'success') {
        throw (New-DuoForgeException -Code 'DF-CLAUDE-RESULT' -Message 'Claude 구조화 출력이 성공 상태가 아닙니다.')
    }
    $structured = Get-DuoForgeObjectValue -Object $envelope -Name 'structured_output'
    if ($null -eq $structured) {
        throw (New-DuoForgeException -Code 'DF-CLAUDE-STRUCTURED-OUTPUT' -Message 'Claude 결과에 검증된 structured_output이 없습니다.')
    }
    $raw = $structured | ConvertTo-Json -Depth 100 -Compress
    return ConvertFrom-DuoForgeProviderResult -RawJson $raw -ExpectedStage $ExpectedStage -ExpectedProvider 'claude' -WorkflowVersion $WorkflowVersion -ExpectedTargetDocumentId $ExpectedTargetDocumentId -ExpectedSourceDocumentIds $ExpectedSourceDocumentIds
}

function Get-DuoForgeProviderFailureClassificationInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$Provider,
        [Parameter(Mandatory)]$ProcessResult
    )

    $started = [bool](Get-DuoForgeObjectValue -Object $ProcessResult -Name 'started' -Default $false)
    $timedOut = [bool](Get-DuoForgeObjectValue -Object $ProcessResult -Name 'timedOut' -Default $false)
    $exitCodeValue = Get-DuoForgeObjectValue -Object $ProcessResult -Name 'exitCode'
    $exitCode = if ($null -eq $exitCodeValue) { $null } else { [int]$exitCodeValue }
    $errorCategory = [string](Get-DuoForgeObjectValue -Object $ProcessResult -Name 'errorCategory')
    $diagnosticText = [string](Get-DuoForgeObjectValue -Object $ProcessResult -Name 'stderr')
    $processMetadata = Get-DuoForgeSafeProcessMetadataInternal -ProcessResult $ProcessResult
    try {
        if (-not $started -and $errorCategory -eq 'command-not-found') {
            return [ordered]@{ safeReason = 'COMMAND_NOT_FOUND'; category = 'command-not-found'; code = 'DF-PROVIDER-NOT-FOUND'; targetStatus = 'BLOCKED_PREFLIGHT'; retryable = $false; message = "$Provider CLI를 찾을 수 없습니다."; exitCode = $null; process = $processMetadata }
        }
        if (-not $started) {
            return [ordered]@{ safeReason = 'PROCESS_START'; category = 'process-start'; code = 'DF-PROVIDER-START'; targetStatus = 'RESUMABLE_ERROR'; retryable = $false; message = "$Provider CLI 프로세스를 시작하지 못했습니다."; exitCode = $null; process = $processMetadata }
        }
        if ($timedOut) {
            return [ordered]@{ safeReason = 'TIMEOUT'; category = 'timeout'; code = 'DF-PROVIDER-TIMEOUT'; targetStatus = 'RESUMABLE_ERROR'; retryable = $true; message = "$Provider CLI 호출 시간이 초과되었습니다."; exitCode = $null; process = $processMetadata }
        }
        if ($diagnosticText -match '(?i)(invalid_json_schema|invalid\s+(?:json\s+)?schema|schema.+(?:rejected|not\s+supported)|invalid\s+schema\s+for\s+response_format)') {
            return [ordered]@{ safeReason = 'SCHEMA_REJECTED'; category = 'schema-compatibility'; code = 'DF-PROVIDER-SCHEMA-REJECTED'; targetStatus = 'BLOCKED_PREFLIGHT'; retryable = $false; message = "$Provider 구조화 출력 스키마가 현재 CLI 또는 공급자 API와 호환되지 않습니다."; exitCode = $exitCode; process = $processMetadata }
        }
        if ($diagnosticText -match '(?i)(reasoning\s+(?:effort|level).*(?:not\s+supported|unsupported|unavailable|invalid)|(?:not\s+supported|unsupported|invalid).+reasoning\s+(?:effort|level))') {
            return [ordered]@{ safeReason = 'REASONING_UNAVAILABLE'; category = 'reasoning-unavailable'; code = 'DF-PROVIDER-REASONING-UNAVAILABLE'; targetStatus = 'BLOCKED_PREFLIGHT'; retryable = $false; message = "${Provider}에서 선택한 추론 단계를 이 모델과 함께 사용할 수 없습니다."; exitCode = $exitCode; process = $processMetadata }
        }
        if ($diagnosticText -match '(?i)(unsupported\s+value.+not\s+supported.+model|model.+configuration.+(?:not\s+supported|unsupported|invalid))') {
            return [ordered]@{ safeReason = 'MODEL_CONFIGURATION_UNAVAILABLE'; category = 'model-configuration'; code = 'DF-PROVIDER-MODEL-CONFIGURATION'; targetStatus = 'BLOCKED_PREFLIGHT'; retryable = $false; message = "${Provider}에서 선택한 모델과 실행 설정 조합을 사용할 수 없습니다."; exitCode = $exitCode; process = $processMetadata }
        }
        if ($diagnosticText -match '(?i)(model\s+.+(?:not\s+found|not\s+available|unavailable|not\s+supported|does\s+not\s+exist)|(?:do\s+not|don.t)\s+have\s+access\s+to\s+(?:the\s+)?model|invalid\s+model)') {
            return [ordered]@{ safeReason = 'MODEL_UNAVAILABLE'; category = 'model-unavailable'; code = 'DF-PROVIDER-MODEL-UNAVAILABLE'; targetStatus = 'BLOCKED_PREFLIGHT'; retryable = $false; message = "${Provider}에서 선택한 모델을 이 계정으로 호출할 수 없습니다."; exitCode = $exitCode; process = $processMetadata }
        }
        if ($diagnosticText -match '(?i)(not\s+logged\s+in|login\s+required|please\s+(?:log\s*in|login)|unauthorized|authentication\s+failed|invalid\s+(?:credential|token)|expired\s+(?:token|session))') {
            return [ordered]@{ safeReason = 'AUTH'; category = 'authentication'; code = 'DF-PROVIDER-AUTH'; targetStatus = 'BLOCKED_PREFLIGHT'; retryable = $false; message = "$Provider 구독 인증을 다시 확인해야 합니다."; exitCode = $exitCode; process = $processMetadata }
        }
        if ($diagnosticText -match '(?i)(unexpected\s+argument|unknown\s+(?:argument|option)|unrecognized\s+(?:argument|option)|invalid\s+value.+(?:argument|option))') {
            return [ordered]@{ safeReason = 'INVALID_OPTION'; category = 'invalid-option'; code = 'DF-PROVIDER-INVALID-OPTION'; targetStatus = 'BLOCKED_PREFLIGHT'; retryable = $false; message = "$Provider CLI가 현재 실행 옵션을 지원하지 않습니다."; exitCode = $exitCode; process = $processMetadata }
        }
        if ($diagnosticText -match "(?i)(usage\s+limit|quota|insufficient_quota|out\s+of\s+credits|plan\s+(?:usage\s+)?limit|limit\s+reached\s+for\s+your\s+plan|you(?:'|’)ve\s+hit\s+your\s+limit)") {
            return [ordered]@{ safeReason = 'QUOTA'; category = 'subscription-quota'; code = 'DF-PROVIDER-QUOTA'; targetStatus = 'PAUSED_QUOTA'; retryable = $false; message = "$Provider 구독 사용 한도에 도달했습니다. API 과금 방식으로 자동 전환하지 않습니다."; exitCode = $exitCode; process = $processMetadata }
        }
        if ($diagnosticText -match '(?i)(rate\s+limit|too\s+many\s+requests|temporarily\s+throttled)') {
            return [ordered]@{ safeReason = 'RATE_LIMIT'; category = 'rate-limit'; code = 'DF-PROVIDER-RATE-LIMIT'; targetStatus = 'RESUMABLE_ERROR'; retryable = $true; message = "$Provider 요청 속도 제한이 감지되었습니다."; exitCode = $exitCode; process = $processMetadata }
        }
        if ($diagnosticText -match '(?i)(network\s+(?:error|unavailable)|connection\s+(?:failed|refused|reset|timed\s*out)|name\s+resolution|dns\s+(?:error|failure)|service\s+unavailable|gateway\s+timeout|tls\s+(?:error|failure)|certificate\s+(?:error|failure))') {
            return [ordered]@{ safeReason = 'NETWORK'; category = 'network'; code = 'DF-PROVIDER-NETWORK'; targetStatus = 'RESUMABLE_ERROR'; retryable = $true; message = "$Provider 네트워크 또는 서비스 연결에 실패했습니다."; exitCode = $exitCode; process = $processMetadata }
        }
        return [ordered]@{ safeReason = 'UNKNOWN'; category = 'provider-process'; code = 'DF-PROVIDER-PROCESS'; targetStatus = 'RESUMABLE_ERROR'; retryable = $false; message = "$Provider CLI가 정상 완료되지 않았습니다. 종료 코드: $exitCode"; exitCode = $exitCode; process = $processMetadata }
    }
    finally {
        $diagnosticText = ''
        if ($ProcessResult -is [System.Collections.IDictionary]) {
            $ProcessResult['stdout'] = ''
            $ProcessResult['stderr'] = ''
        }
        else {
            try { $ProcessResult.stdout = '' } catch { }
            try { $ProcessResult.stderr = '' } catch { }
        }
    }
}

function New-DuoForgeProviderFailureExceptionInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Classification)

    $exception = New-DuoForgeException -Code ([string]$Classification.code) -Message ([string]$Classification.message)
    $exception.Data['DuoForgeFailureCategory'] = [string]$Classification.category
    $exception.Data['DuoForgeFailureReason'] = [string]$Classification.safeReason
    $exception.Data['DuoForgeFailureStatus'] = [string]$Classification.targetStatus
    $exception.Data['DuoForgeRetryable'] = [bool]$Classification.retryable
    if ($null -ne $Classification.exitCode) { $exception.Data['DuoForgeExitCode'] = [int]$Classification.exitCode }
    $exception.Data['DuoForgeProcess'] = Get-DuoForgeSafeProcessMetadataInternal -ProcessResult (Get-DuoForgeObjectValue -Object $Classification -Name 'process')
    return $exception
}

function Invoke-DuoForgeLiveProviderStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Graph,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Step,
        [Parameter(Mandatory)][bool]$LiveConsent,
        [System.Collections.IDictionary]$Prompt,
        [int]$TimeoutSeconds = 900,
        [scriptblock]$ProgressObserver
    )

    if (-not $LiveConsent) {
        throw (New-DuoForgeException -Code 'DF-LIVE-CONSENT' -Message '문서를 전송하고 AI 작업을 시작하려면 확인어 LIVE가 필요합니다.')
    }

    if ($null -eq $Prompt) {
        $Prompt = New-DuoForgeStagePrompt -RunDirectory $RunDirectory -Graph $Graph -Step $Step
    }
    $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
    $workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $manifest
    $providerContext = Resolve-DuoForgeProviderExecutionContextInternal -Provider ([string]$Step.provider)
    if (-not [bool]$providerContext.liveRuntimeEligible) {
        throw (New-DuoForgeException -Code 'DF-AUTH-CONTEXT' -Message '현재 PowerShell 환경에서는 AI 로그인 정보를 확인할 수 없습니다. 일반 PowerShell 7 창에서 다시 실행해 주세요.')
    }
    $expectedTargetDocumentId = Get-DuoForgeObjectValue -Object $Step -Name 'targetDocumentId'
    $expectedSourceDocumentIds = @(Get-DuoForgeObjectValue -Object $Step -Name 'sourceDocumentIds' -Default @())
    $spec = Get-DuoForgeProviderCommandSpecInternal -Provider ([string]$Step.provider) -RunDirectory $RunDirectory -Step $Step -Prompt $Prompt
    Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'PROVIDER_CALL_STARTED' -Status 'RUNNING' -Data ([ordered]@{
        workflowVersion = $workflowVersion
        stepKey = [string]$Step.stepKey
        provider = [string]$Step.provider
        stage = [string]$Step.stage
        targetDocumentId = $expectedTargetDocumentId
        promptHash = [string]$Prompt.sha256
        promptBytes = [int]$Prompt.bytes
        visibleArtifactStepKeys = @($Prompt.artifactStepKeys)
        visibleArtifactHashes = @($Prompt.artifactHashes)
    })

    $processResult = $null
    try {
        $onTick = if ($null -ne $ProgressObserver) {
            New-DuoForgeProviderTickCallbackInternal -Observer $ProgressObserver -RunDirectory $RunDirectory -Data ([ordered]@{
                workflowVersion = $workflowVersion
                stepKey = [string]$Step.stepKey
                provider = [string]$Step.provider
                stage = [string]$Step.stage
                targetDocumentId = $expectedTargetDocumentId
                round = [int]$Step.round
            })
        }
        else { $null }
        $processArguments = [ordered]@{
            CommandName = [string]$spec.commandName
            Arguments = @($spec.arguments)
            WorkingDirectory = [string]$spec.workingDirectory
            TimeoutSeconds = $TimeoutSeconds
            StandardInput = [string]$spec.prompt
            EnvironmentAllowList = @($providerContext.environmentAllowList)
            EnvironmentOverrides = $providerContext.environmentOverrides
            CommandInvocation = $providerContext.invocation
        }
        if ($null -ne $onTick) { $processArguments['OnTick'] = $onTick }
        $processResult = Invoke-DuoForgeProcess @processArguments

        if (-not $processResult.started -or $processResult.timedOut -or [int]$processResult.exitCode -ne 0) {
            $classification = Get-DuoForgeProviderFailureClassificationInternal -Provider ([string]$Step.provider) -ProcessResult $processResult
            throw (New-DuoForgeProviderFailureExceptionInternal -Classification $classification)
        }

        if ([string]$Step.provider -eq 'codex') {
            Assert-DuoForgeCodexEventStreamSafe -JsonLines ([string]$processResult.stdout)
            if (-not (Test-Path -LiteralPath ([string]$spec.outputPath) -PathType Leaf)) {
                throw (New-DuoForgeException -Code 'DF-CODEX-LAST-MESSAGE' -Message 'Codex 최종 구조화 출력 파일이 없습니다.')
            }
            $rawJson = [System.IO.File]::ReadAllText([string]$spec.outputPath, [System.Text.UTF8Encoding]::new($false, $true))
            $converted = ConvertFrom-DuoForgeProviderResult -RawJson $rawJson -ExpectedStage ([string]$Step.stage) -ExpectedProvider 'codex' -WorkflowVersion $workflowVersion -ExpectedTargetDocumentId $expectedTargetDocumentId -ExpectedSourceDocumentIds $expectedSourceDocumentIds
        }
        else {
            $converted = ConvertFrom-DuoForgeClaudeEnvelope -Json ([string]$processResult.stdout) -ExpectedStage ([string]$Step.stage) -WorkflowVersion $workflowVersion -ExpectedTargetDocumentId $expectedTargetDocumentId -ExpectedSourceDocumentIds $expectedSourceDocumentIds
        }

        Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'PROVIDER_CALL_COMPLETED' -Status 'RUNNING' -Data ([ordered]@{
            workflowVersion = $workflowVersion
            stepKey = [string]$Step.stepKey
            provider = [string]$Step.provider
            stage = [string]$Step.stage
            targetDocumentId = $expectedTargetDocumentId
            promptHash = [string]$Prompt.sha256
            rawHash = [string]$converted.rawHash
            redactionCount = [int]$converted.redactionCount
        })
        return $converted.result
    }
    catch {
        if ($null -ne $processResult -and -not $_.Exception.Data.Contains('DuoForgeProcess')) {
            try { $_.Exception.Data['DuoForgeProcess'] = Get-DuoForgeSafeProcessMetadataInternal -ProcessResult $processResult } catch { }
        }
        throw
    }
    finally {
        try { Remove-DuoForgeProviderWorkDirectory -RunDirectory $RunDirectory -WorkDirectory ([string]$spec.workingDirectory) }
        catch { Write-Verbose 'DuoForge 공급자 작업 폴더 정리 오류를 무시했습니다.' }
    }
}

function New-DuoForgeProviderTickCallbackInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Observer,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Data
    )

    $observerCommand = Get-Command -Name 'Invoke-DuoForgeProgressObserverInternal' -CommandType Function -ErrorAction Stop
    $eventCommand = Get-Command -Name 'Add-DuoForgeProgressRunEventInternal' -CommandType Function -ErrorAction Stop
    $failureState = @{ reported = $false }
    return {
        param($elapsed)
        $tickData = [ordered]@{}
        foreach ($key in $Data.Keys) { $tickData[$key] = $Data[$key] }
        $tickData.elapsedSeconds = [int][Math]::Floor($elapsed.TotalSeconds)
        try {
            & $observerCommand -Observer $Observer -Type 'PROVIDER_TICK' -RunDirectory $RunDirectory -Data $tickData -ThrowOnError
        }
        catch {
            if (-not [bool]$failureState.reported) {
                $failureState.reported = $true
                & $eventCommand -RunDirectory $RunDirectory -Type 'PROGRESS_OBSERVER_FAILED' -Status 'RUNNING' -Data ([ordered]@{ code = 'DF-PROGRESS-OBSERVER'; count = 1 })
            }
        }
    }.GetNewClosure()
}

function New-DuoForgeFakeStageResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Step)

    $document = $null
    if ([string]$Step.stage -in @('independent-draft', 'independent-merge-draft', 'synthesis', 'owned-document-revision', 'document-revision')) {
        $document = "# 가짜 $($Step.provider) 문서`n`n단계: $($Step.stage), 라운드: $($Step.round)"
    }
    $workflowVersion = if ($Step.Contains('performedBy')) { 'workflow-v2' } else { 'workflow-v1' }
    $result = [ordered]@{
        schemaVersion = if ($workflowVersion -eq 'workflow-v2') { 2 } else { 1 }
        stage = [string]$Step.stage
        provider = [string]$Step.provider
        summary = "가짜 공급자 결과: $($Step.stepKey)"
        document = $document
        issues = @()
        issueResponses = @()
        adoptions = @()
        openQuestions = @()
        finalApproved = if ([string]$Step.stage -in @('final-validation', 'document-validation')) { $true } else { $null }
    }
    if ($workflowVersion -eq 'workflow-v2') {
        $result.performedBy = [string]$Step.performedBy
        $result.targetDocumentId = Get-DuoForgeObjectValue -Object $Step -Name 'targetDocumentId'
        $result.sourceDocumentIds = @(Get-DuoForgeObjectValue -Object $Step -Name 'sourceDocumentIds' -Default @())
    }
    return $result
}
