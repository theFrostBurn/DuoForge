function Get-DuoForgeProviderEnvironmentAllowList {
    [CmdletBinding()]
    param()

    return @(
        'SystemRoot', 'WINDIR', 'ComSpec', 'TEMP', 'TMP', 'PATH', 'PATHEXT',
        'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'LOCALAPPDATA', 'APPDATA',
        'PROGRAMDATA', 'ProgramFiles', 'ProgramFiles(x86)', 'PROCESSOR_ARCHITECTURE',
        'PSModulePath', 'CODEX_HOME', 'CLAUDE_CONFIG_DIR',
        'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'SSL_CERT_FILE', 'REQUESTS_CA_BUNDLE'
    )
}

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

    $schema = Read-DuoForgeJson -Path (Get-DuoForgeStageSchemaPath)
    return Get-DuoForgeStructuredProviderCommandSpecInternal `
        -Provider $Provider `
        -RunDirectory $RunDirectory `
        -OperationKey ([string]$Step.stepKey) `
        -Prompt $Prompt `
        -Schema $schema `
        -SchemaFileName 'stage-result.schema.json'
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
        [Parameter(Mandatory)][string]$ExpectedStage
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
    return ConvertFrom-DuoForgeProviderResult -RawJson $raw -ExpectedStage $ExpectedStage -ExpectedProvider 'claude'
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
    $diagnosticText = ([string](Get-DuoForgeObjectValue -Object $ProcessResult -Name 'stdout')) + [Environment]::NewLine + ([string](Get-DuoForgeObjectValue -Object $ProcessResult -Name 'stderr'))

    if (-not $started -and $errorCategory -eq 'command-not-found') {
        return [ordered]@{ category = 'command-not-found'; code = 'DF-PROVIDER-NOT-FOUND'; targetStatus = 'BLOCKED_PREFLIGHT'; retryable = $false; message = "$Provider CLI를 찾을 수 없습니다."; exitCode = $null }
    }
    if (-not $started) {
        return [ordered]@{ category = 'process-start'; code = 'DF-PROVIDER-START'; targetStatus = 'RESUMABLE_ERROR'; retryable = $false; message = "$Provider CLI 프로세스를 시작하지 못했습니다."; exitCode = $null }
    }
    if ($timedOut) {
        return [ordered]@{ category = 'timeout'; code = 'DF-PROVIDER-TIMEOUT'; targetStatus = 'RESUMABLE_ERROR'; retryable = $true; message = "$Provider CLI 호출 시간이 초과되었습니다."; exitCode = $null }
    }
    if ($diagnosticText -match '(?i)(invalid_json_schema|invalid\s+schema\s+for\s+response_format)') {
        return [ordered]@{ category = 'schema-compatibility'; code = 'DF-PROVIDER-SCHEMA-COMPAT'; targetStatus = 'BLOCKED_PREFLIGHT'; retryable = $false; message = "$Provider 구조화 출력 스키마가 현재 CLI 또는 공급자 API와 호환되지 않습니다."; exitCode = $exitCode }
    }
    if ($diagnosticText -match "(?i)(usage\s+limit|quota|insufficient_quota|out\s+of\s+credits|plan\s+(?:usage\s+)?limit|limit\s+reached\s+for\s+your\s+plan|you(?:'|’)ve\s+hit\s+your\s+limit)") {
        return [ordered]@{ category = 'subscription-quota'; code = 'DF-PROVIDER-QUOTA'; targetStatus = 'PAUSED_QUOTA'; retryable = $false; message = "$Provider 구독 사용 한도에 도달했습니다. API 과금 방식으로 자동 전환하지 않습니다."; exitCode = $exitCode }
    }
    if ($diagnosticText -match '(?i)(rate\s+limit|too\s+many\s+requests|temporarily\s+throttled)') {
        return [ordered]@{ category = 'rate-limit'; code = 'DF-PROVIDER-RATE-LIMIT'; targetStatus = 'RESUMABLE_ERROR'; retryable = $true; message = "$Provider 요청 속도 제한이 감지되었습니다."; exitCode = $exitCode }
    }
    if ($diagnosticText -match '(?i)(not\s+logged\s+in|login\s+required|please\s+(?:log\s*in|login)|unauthorized|authentication\s+failed|invalid\s+(?:credential|token)|expired\s+(?:token|session))') {
        return [ordered]@{ category = 'authentication'; code = 'DF-PROVIDER-AUTH'; targetStatus = 'BLOCKED_PREFLIGHT'; retryable = $false; message = "$Provider 구독 인증을 다시 확인해야 합니다."; exitCode = $exitCode }
    }
    return [ordered]@{ category = 'provider-process'; code = 'DF-PROVIDER-PROCESS'; targetStatus = 'RESUMABLE_ERROR'; retryable = $false; message = "$Provider CLI가 정상 완료되지 않았습니다. 종료 코드: $exitCode"; exitCode = $exitCode }
}

function New-DuoForgeProviderFailureExceptionInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Classification)

    $exception = New-DuoForgeException -Code ([string]$Classification.code) -Message ([string]$Classification.message)
    $exception.Data['DuoForgeFailureCategory'] = [string]$Classification.category
    $exception.Data['DuoForgeFailureStatus'] = [string]$Classification.targetStatus
    $exception.Data['DuoForgeRetryable'] = [bool]$Classification.retryable
    if ($null -ne $Classification.exitCode) { $exception.Data['DuoForgeExitCode'] = [int]$Classification.exitCode }
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
        throw (New-DuoForgeException -Code 'DF-LIVE-CONSENT' -Message '실제 공급자 호출에는 명시적인 라이브 실행 동의가 필요합니다.')
    }

    if ($null -eq $Prompt) {
        $Prompt = New-DuoForgeStagePrompt -RunDirectory $RunDirectory -Graph $Graph -Step $Step
    }
    $spec = Get-DuoForgeProviderCommandSpecInternal -Provider ([string]$Step.provider) -RunDirectory $RunDirectory -Step $Step -Prompt $Prompt
    Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'PROVIDER_CALL_STARTED' -Status 'RUNNING' -Data ([ordered]@{
        stepKey = [string]$Step.stepKey
        provider = [string]$Step.provider
        promptHash = [string]$Prompt.sha256
        promptBytes = [int]$Prompt.bytes
        visibleArtifactStepKeys = @($Prompt.artifactStepKeys)
        visibleArtifactHashes = @($Prompt.artifactHashes)
    })

    try {
        $onTick = if ($null -ne $ProgressObserver) {
            {
                param($elapsed)
                Invoke-DuoForgeProgressObserverInternal -Observer $ProgressObserver -Type 'PROVIDER_TICK' -RunDirectory $RunDirectory -Data ([ordered]@{
                    stepKey = [string]$Step.stepKey
                    provider = [string]$Step.provider
                    stage = [string]$Step.stage
                    round = [int]$Step.round
                    elapsedSeconds = [int][Math]::Floor($elapsed.TotalSeconds)
                })
            }.GetNewClosure()
        }
        else { $null }
        $processArguments = [ordered]@{
            CommandName = [string]$spec.commandName
            Arguments = @($spec.arguments)
            WorkingDirectory = [string]$spec.workingDirectory
            TimeoutSeconds = $TimeoutSeconds
            StandardInput = [string]$spec.prompt
            EnvironmentAllowList = Get-DuoForgeProviderEnvironmentAllowList
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
            $converted = ConvertFrom-DuoForgeProviderResult -RawJson $rawJson -ExpectedStage ([string]$Step.stage) -ExpectedProvider 'codex'
        }
        else {
            $converted = ConvertFrom-DuoForgeClaudeEnvelope -Json ([string]$processResult.stdout) -ExpectedStage ([string]$Step.stage)
        }

        Add-DuoForgeRunEvent -RunDirectory $RunDirectory -Type 'PROVIDER_CALL_COMPLETED' -Status 'RUNNING' -Data ([ordered]@{
            stepKey = [string]$Step.stepKey
            provider = [string]$Step.provider
            promptHash = [string]$Prompt.sha256
            rawHash = [string]$converted.rawHash
            redactionCount = [int]$converted.redactionCount
        })
        return $converted.result
    }
    finally {
        Remove-DuoForgeProviderWorkDirectory -RunDirectory $RunDirectory -WorkDirectory ([string]$spec.workingDirectory)
    }
}

function New-DuoForgeFakeStageResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Step)

    $document = $null
    if ([string]$Step.stage -in @('independent-draft', 'synthesis', 'owned-document-revision')) {
        $document = "# 가짜 $($Step.provider) 문서`n`n단계: $($Step.stage), 라운드: $($Step.round)"
    }
    return [ordered]@{
        schemaVersion = 1
        stage = [string]$Step.stage
        provider = [string]$Step.provider
        summary = "가짜 공급자 결과: $($Step.stepKey)"
        document = $document
        issues = @()
        issueResponses = @()
        adoptions = @()
        openQuestions = @()
        finalApproved = if ([string]$Step.stage -eq 'final-validation') { $true } else { $null }
    }
}
