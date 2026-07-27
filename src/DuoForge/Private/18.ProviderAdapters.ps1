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
}

function Get-DuoForgeProviderCommandSpecInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$Provider,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Step,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Prompt
    )

    $workDirectory = New-DuoForgeProviderWorkDirectory -RunDirectory $RunDirectory -StepKey ([string]$Step.stepKey)
    $schema = Read-DuoForgeJson -Path (Get-DuoForgeStageSchemaPath)
    $schemaPath = Join-Path $workDirectory 'stage-result.schema.json'
    Write-DuoForgeJsonAtomic -Path $schemaPath -Value $schema

    if ($Provider -eq 'codex') {
        $lastMessagePath = Join-Path $workDirectory 'last-message.json'
        $arguments = @(
            '--ask-for-approval', 'never',
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

    $schemaJson = $schema | ConvertTo-Json -Depth 100 -Compress
    return [ordered]@{
        provider = $Provider
        commandName = 'claude'
        arguments = @(
            '-p',
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

function Invoke-DuoForgeLiveProviderStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Graph,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Step,
        [Parameter(Mandatory)][bool]$LiveConsent,
        [System.Collections.IDictionary]$Prompt,
        [int]$TimeoutSeconds = 900
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
    })

    try {
        $processResult = Invoke-DuoForgeProcess `
            -CommandName ([string]$spec.commandName) `
            -Arguments @($spec.arguments) `
            -WorkingDirectory ([string]$spec.workingDirectory) `
            -TimeoutSeconds $TimeoutSeconds `
            -StandardInput ([string]$spec.prompt) `
            -EnvironmentAllowList (Get-DuoForgeProviderEnvironmentAllowList)

        if (-not $processResult.started -or $processResult.timedOut -or [int]$processResult.exitCode -ne 0) {
            throw (New-DuoForgeException -Code 'DF-PROVIDER-PROCESS' -Message "공급자 프로세스가 정상 완료되지 않았습니다: $($Step.provider)")
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
