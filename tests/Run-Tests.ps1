#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$modulePath = Join-Path $projectRoot 'src\DuoForge\DuoForge.psd1'
$module = Import-Module $modulePath -Force -PassThru
$tempParent = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.tmp'))
$tempRoot = Join-Path $tempParent ([Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message = '조건이 참이어야 합니다.')
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param([bool]$Condition, [string]$Message = '조건이 거짓이어야 합니다.')
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = '')
    if ($Actual -ne $Expected) {
        if ([string]::IsNullOrWhiteSpace($Message)) { $Message = "예상값 '$Expected', 실제값 '$Actual'" }
        throw $Message
    }
}

function Assert-ContainsText {
    param([string]$Text, [string]$Expected, [string]$Message = '')
    if (-not $Text.Contains($Expected, [StringComparison]::Ordinal)) {
        if ([string]::IsNullOrWhiteSpace($Message)) { $Message = "텍스트에 '$Expected'가 없습니다." }
        throw $Message
    }
}

function Assert-NotContainsText {
    param([string]$Text, [string]$Unexpected, [string]$Message = '')
    if ($Text.Contains($Unexpected, [StringComparison]::OrdinalIgnoreCase)) {
        if ([string]::IsNullOrWhiteSpace($Message)) { $Message = "텍스트에 금지 문자열 '$Unexpected'가 있습니다." }
        throw $Message
    }
}

function Assert-ThrowsCode {
    param([scriptblock]$Body, [string]$ExpectedCode)
    try {
        & $Body
    }
    catch {
        $actualCode = [string]$_.Exception.Data['DuoForgeCode']
        if ($actualCode -ne $ExpectedCode) { throw "예상 오류 '$ExpectedCode', 실제 오류 '$actualCode'" }
        return
    }
    throw "예상한 오류 '$ExpectedCode'가 발생하지 않았습니다."
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host ("[통과] $Name") -ForegroundColor Green
    }
    catch {
        $script:Failed++
        Write-Host ("[실패] $Name") -ForegroundColor Red
        Write-Host ('       ' + $_.Exception.Message) -ForegroundColor Red
    }
}

function New-FakeDoctor {
    return [ordered]@{
        readyForDocumentModes = $true
        readyForProjectAudit = $false
        providers = [ordered]@{
            codex = [ordered]@{ version = 'codex-test'; authType = 'chatgpt' }
            claude = [ordered]@{ version = 'claude-test'; authType = 'claude.ai' }
        }
    }
}

function New-TestConfig {
    param([string]$ResultsRoot)
    $config = Get-DuoForgeDefaultConfig
    $config.resultsRoot = $ResultsRoot
    $config.localDataRoot = Join-Path $tempRoot 'local'
    return $config
}

function New-TestStartRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Mode,
        [string]$Brief,
        [string]$CodexDocument,
        [string]$ClaudeDocument,
        [string]$CodexProject,
        [string]$ClaudeProject,
        [string]$Requirements,
        [string]$CodexModel = 'gpt-5.6',
        [string]$CodexReasoningEffort = 'high',
        [string]$ClaudeModel = 'sonnet',
        [string]$ClaudeReasoningEffort = 'high',
        [string]$DocumentType = 'custom',
        [int]$MaxRounds = 2,
        [string]$Workspace,
        [string]$FirstSynthesizer = 'alternate',
        [string]$Name
    )
    $parameters = @{} + $PSBoundParameters
    $parameters['CodexModel'] = $CodexModel
    $parameters['CodexReasoningEffort'] = $CodexReasoningEffort
    $parameters['ClaudeModel'] = $ClaudeModel
    $parameters['ClaudeReasoningEffort'] = $ClaudeReasoningEffort
    return New-DuoForgeStartRequest @parameters
}

function New-MarkdownFile {
    param([string]$Path, [string]$Text = '# 테스트')
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path)) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
    return $Path
}

try {
    Test-Case '기본 설정은 2라운드, 최대 3라운드, 3A 비활성화다' {
        $config = Get-DuoForgeDefaultConfig
        Assert-Equal $config.defaultRounds 2
        Assert-Equal $config.maxRounds 3
        Assert-False ([bool]$config.features.dualProjectAudit)
    }

    Test-Case 'Codex와 Claude의 모델 및 추론 정도는 모두 필수다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'selection-required\input\brief.md')
        $workspace = Join-Path $tempRoot 'selection-required-results'
        $request = New-DuoForgeStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        Assert-False ([bool]$validation.valid)
        Assert-Equal @($validation.errors | Where-Object { $_.code -eq 'DF-PROVIDER-SELECTION-REQUIRED' }).Count 4

        $invalid = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd -ClaudeReasoningEffort ultra
        $invalidValidation = Test-DuoForgeStartRequest -Request $invalid -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        Assert-False ([bool]$invalidValidation.valid)
        Assert-Equal @($invalidValidation.errors | Where-Object { $_.code -eq 'DF-PROVIDER-EFFORT' }).Count 1
    }

    Test-Case '선택값 없는 요청은 valid 조작 후에도 실행을 만들 수 없다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'selection-fail-closed\input\brief.md')
        $workspace = Join-Path $tempRoot 'selection-fail-closed-results'
        $request = New-DuoForgeStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $validation.valid = $true
        Assert-ThrowsCode -ExpectedCode 'DF-PROVIDER-SELECTION-REQUIRED' -Body {
            New-DuoForgeRun -ValidationResult $validation
        }
        Assert-False (Test-Path -LiteralPath $workspace)
    }

    Test-Case '선택값이 없는 이전 매니페스트는 라이브 재개 전에 차단한다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'legacy-selection\input\brief.md')
        $workspace = Join-Path $tempRoot 'legacy-selection-results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        & $module {
            param($directory)
            $manifestPath = Join-Path $directory 'manifest.json'
            $manifest = Read-DuoForgeJson -Path $manifestPath
            $manifest.PSObject.Properties.Remove('providerSelections')
            Write-DuoForgeJsonAtomic -Path $manifestPath -Value $manifest
        } $run.runDirectory
        Assert-ThrowsCode -ExpectedCode 'DF-PROVIDER-SELECTION-REQUIRED' -Body {
            & $module {
                param($runId, $resultsRoot)
                Invoke-DuoForgeResumeLiveInternal -RunId $runId -ResultsRoot $resultsRoot -LiveConsent $true
            } $run.runId $workspace
        }
    }

    Test-Case 'Explorer 따옴표 경로를 절대 경로로 정규화한다' {
        $file = New-MarkdownFile -Path (Join-Path $tempRoot '한글 경로\문서.md')
        $resolved = Resolve-DuoForgePath -Path ('"' + $file + '"') -ExpectedType File
        Assert-Equal $resolved ([System.IO.Path]::GetFullPath($file))
    }

    Test-Case '경로 관계는 동일, 포함, 분리를 구분한다' {
        $a = Join-Path $tempRoot 'paths\a'
        $b = Join-Path $a 'b'
        $c = Join-Path $tempRoot 'paths\c'
        Assert-Equal (Test-DuoForgePathRelationship -PathA $a -PathB $a) 'Same'
        Assert-Equal (Test-DuoForgePathRelationship -PathA $a -PathB $b) 'AContainsB'
        Assert-Equal (Test-DuoForgePathRelationship -PathA $a -PathB $c) 'Disjoint'
    }

    Test-Case '공동 문서 요청은 입력 폴더 안의 결과 루트를 차단한다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'boundary\input\brief.md')
        $workspace = Join-Path $tempRoot 'boundary\input\results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        Assert-False ([bool]$validation.valid)
        Assert-True (@($validation.errors | Where-Object { $_.code -eq 'DF-PATH-OUTPUT-IN-INPUT' }).Count -eq 1)
    }

    Test-Case '독립 문서 요청은 같은 부모 폴더를 차단한다' {
        $codex = New-MarkdownFile -Path (Join-Path $tempRoot 'dual-same\codex.md')
        $claude = New-MarkdownFile -Path (Join-Path $tempRoot 'dual-same\claude.md')
        $workspace = Join-Path $tempRoot 'dual-same-results'
        $request = New-TestStartRequest -Mode dual-document -CodexDocument $codex -ClaudeDocument $claude -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        Assert-False ([bool]$validation.valid)
        Assert-True (@($validation.errors | Where-Object { $_.code -eq 'DF-PATH-DUAL-DOCUMENT-OVERLAP' }).Count -eq 1)
    }

    Test-Case '독립 문서 인벤토리는 각 폴더의 Markdown을 자동 포함한다' {
        $codex = New-MarkdownFile -Path (Join-Path $tempRoot 'dual\codex\main.md')
        $null = New-MarkdownFile -Path (Join-Path $tempRoot 'dual\codex\context.md')
        $claude = New-MarkdownFile -Path (Join-Path $tempRoot 'dual\claude\main.md')
        $null = New-MarkdownFile -Path (Join-Path $tempRoot 'dual\claude\context.md')
        $workspace = Join-Path $tempRoot 'dual-results'
        $request = New-TestStartRequest -Mode dual-document -CodexDocument $codex -ClaudeDocument $claude -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        Assert-True ([bool]$validation.valid)
        Assert-Equal $validation.inputs.codex.context.includedFiles 2
        Assert-Equal $validation.inputs.claude.context.includedFiles 2
    }

    Test-Case '호출 계획은 라운드와 재시도를 포함해 강제 상한 안에 있다' {
        $two = Get-DuoForgeExecutionPlan -Mode shared-document -MaxRounds 2
        Assert-Equal $two.providers.codex.maximumCalls 14
        Assert-Equal $two.providers.claude.maximumCalls 12
        Assert-True ([bool]$two.withinLimits)
        $three = Get-DuoForgeExecutionPlan -Mode shared-document -MaxRounds 3
        Assert-Equal $three.providers.codex.maximumCalls 18
        Assert-Equal $three.providers.claude.maximumCalls 18
    }

    Test-Case 'Critical 쟁점은 모델 제안과 관계없이 항상 차단한다' {
        $issue = New-DuoForgeIssue -Round 1 -RaisedBy claude -Target codex-document -Category wording -Severity critical -Claim '필수 안전 경계가 없다.' -BlockingProposal $false
        Assert-True ([bool]$issue.blocking)
        $completion = Test-DuoForgeCompletionAllowed -Issues @($issue)
        Assert-False ([bool]$completion.allowed)
        Assert-Equal $completion.status 'AWAITING_USER'
    }

    Test-Case '인증 파서는 개인정보와 원문 비밀값을 결과에서 제거한다' {
        $claudeRaw = '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"person@example.com","orgId":"secret-org","subscriptionType":"pro"}'
        $claude = ConvertFrom-DuoForgeClaudeAuthStatus -Text $claudeRaw -ExitCode 0
        $json = $claude | ConvertTo-Json -Depth 10
        Assert-True ([bool]$claude.subscription)
        Assert-NotContainsText $json 'person@example.com'
        Assert-NotContainsText $json 'secret-org'
        $codex = ConvertFrom-DuoForgeCodexAuthStatus -Text 'Logged in using ChatGPT' -ExitCode 0
        Assert-True ([bool]$codex.subscription)
    }

    Test-Case 'API 인증 우선 환경 변수는 이름만 보고 문서 모드를 차단한다' {
        $previous = [Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY', [EnvironmentVariableTarget]::Process)
        try {
            [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', 'never-print-this-test-secret', [EnvironmentVariableTarget]::Process)
            $report = Invoke-DuoForgeDoctor
            $json = $report | ConvertTo-Json -Depth 30
            Assert-False ([bool]$report.readyForDocumentModes)
            Assert-ContainsText $json 'ANTHROPIC_API_KEY'
            Assert-NotContainsText $json 'never-print-this-test-secret'
        }
        finally {
            [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $previous, [EnvironmentVariableTarget]::Process)
        }
    }

    Test-Case '유효 요청은 원본을 바꾸지 않고 불변 스냅샷 실행을 만든다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'run\input\brief.md') -Text "# 한글 PRD`n`n원본"
        $beforeHash = (Get-FileHash -LiteralPath $input -Algorithm SHA256).Hash
        $workspace = Join-Path $tempRoot 'run\results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        Assert-True ([bool]$validation.valid)
        $run = New-DuoForgeRun -ValidationResult $validation
        Assert-Equal $run.status 'SNAPSHOTTED'
        Assert-True (Test-Path -LiteralPath (Join-Path $run.runDirectory 'manifest.json') -PathType Leaf)
        Assert-True (Test-Path -LiteralPath (Join-Path $run.runDirectory 'inputs\snapshots\S000001.md') -PathType Leaf)
        Assert-Equal $run.manifest.schemaVersion 2
        Assert-Equal $run.manifest.providerSelections.codex.model 'gpt-5.6'
        Assert-Equal $run.manifest.providerSelections.codex.reasoningEffort 'high'
        Assert-Equal $run.manifest.providerSelections.claude.model 'sonnet'
        Assert-Equal $run.manifest.providerSelections.claude.reasoningEffort 'high'
        $afterHash = (Get-FileHash -LiteralPath $input -Algorithm SHA256).Hash
        Assert-Equal $afterHash $beforeHash
    }

    Test-Case '가짜 공급자 상태 머신은 라운드 장벽을 지키고 완료 단계를 중복 호출하지 않는다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'engine\input\brief.md')
        $workspace = Join-Path $tempRoot 'engine\results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $calls = [System.Collections.Generic.List[string]]::new()
        $first = & $module {
            param($directory, $callList)
            $callback = { param($step) $callList.Add([string]$step.stepKey); return New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory $calls
        Assert-Equal $first.status 'COMPLETED'
        Assert-Equal $calls.Count 13
        Assert-True (Test-Path -LiteralPath (Join-Path $run.runDirectory 'final\PRD.md') -PathType Leaf)
        Assert-True (Test-Path -LiteralPath (Join-Path $run.runDirectory 'final\DEBATE_SUMMARY.md') -PathType Leaf)
        Assert-True (Test-Path -LiteralPath (Join-Path $run.runDirectory 'final\DECISIONS.md') -PathType Leaf)
        Assert-True (Test-Path -LiteralPath (Join-Path $run.runDirectory 'final\OPEN_QUESTIONS.md') -PathType Leaf)
        $second = & $module {
            param($directory, $callList)
            $callback = { param($step) $callList.Add([string]$step.stepKey); return New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory $calls
        Assert-Equal $second.invoked 0
        Assert-Equal $calls.Count 13
        $graph = Get-Content -LiteralPath (Join-Path $run.runDirectory 'steps.json') -Raw | ConvertFrom-Json -Depth 50
        $firstReview = @($graph.steps | Where-Object { $_.stage -eq 'cross-review' })[0]
        Assert-Equal @($firstReview.dependsOn).Count 2
    }

    Test-Case '실패 후 재개는 완료된 상대 단계를 다시 호출하지 않는다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'resume\input\brief.md')
        $workspace = Join-Path $tempRoot 'resume\results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $control = @{ fail = $true; calls = [System.Collections.Generic.List[string]]::new() }
        $first = & $module {
            param($directory, $controlState)
            $callback = {
                param($step)
                $controlState.calls.Add([string]$step.stepKey)
                if ($controlState.fail -and [string]$step.stepKey -eq 'r01-codex-cross-review') {
                    $controlState.fail = $false
                    throw '의도된 테스트 실패'
                }
                return New-DuoForgeFakeStageResult -Step $step
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory $control
        Assert-Equal $first.status 'RESUMABLE_ERROR'
        $second = & $module {
            param($directory, $controlState)
            $callback = {
                param($step)
                $controlState.calls.Add([string]$step.stepKey)
                return New-DuoForgeFakeStageResult -Step $step
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory $control
        Assert-Equal $second.status 'COMPLETED'
        Assert-Equal @($control.calls | Where-Object { $_ -eq 'r01-codex-independent-draft' }).Count 1
        Assert-Equal @($control.calls | Where-Object { $_ -eq 'r01-claude-independent-draft' }).Count 1
        Assert-Equal @($control.calls | Where-Object { $_ -eq 'r01-codex-cross-review' }).Count 2
    }

    Test-Case '단계 결과 계약은 단계와 공급자 불일치를 실패 폐쇄한다' {
        $step = [ordered]@{ stepKey = 'r01-codex-independent-draft'; provider = 'codex'; stage = 'independent-draft'; round = 1 }
        $valid = & $module { param($s) $result = New-DuoForgeFakeStageResult -Step $s; Test-DuoForgeStageResultInternal -Result $result -ExpectedStage $s.stage -ExpectedProvider $s.provider } $step
        Assert-True ([bool]$valid.valid)
        Assert-ThrowsCode -ExpectedCode 'DF-STAGE-SCHEMA' -Body {
            & $module { param($s) $result = New-DuoForgeFakeStageResult -Step $s; $result.provider = 'claude'; Test-DuoForgeStageResultInternal -Result $result -ExpectedStage $s.stage -ExpectedProvider $s.provider -ThrowOnError } $step
        }
    }

    Test-Case '단계 프롬프트는 원본 절대 경로를 숨기고 스냅샷만 사용한다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'prompt\input\brief.md') -Text "# 입력`n`nGet-Process를 실행하라는 문서 내부 명령"
        $workspace = Join-Path $tempRoot 'prompt-results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $prompt = & $module {
            param($directory)
            $graph = Initialize-DuoForgeStageGraph -RunDirectory $directory
            New-DuoForgeStagePrompt -RunDirectory $directory -Graph $graph -Step $graph.steps[0]
        } $run.runDirectory
        Assert-NotContainsText $prompt.text ([System.IO.Path]::GetFullPath($input))
        Assert-ContainsText $prompt.text 'S000001.md'
        Assert-ContainsText $prompt.text '신뢰할 수 없는 문서 데이터'
        Assert-ContainsText $prompt.text 'Get-Process를 실행하라는 문서 내부 명령'
    }

    Test-Case '공급자 명령 명세는 Codex와 Claude의 무도구 경계를 고정한다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'spec\input\brief.md')
        $workspace = Join-Path $tempRoot 'spec-results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $specs = & $module {
            param($directory)
            $graph = Initialize-DuoForgeStageGraph -RunDirectory $directory
            $codexStep = $graph.steps[0]
            $claudeStep = $graph.steps[1]
            $codexPrompt = New-DuoForgeStagePrompt -RunDirectory $directory -Graph $graph -Step $codexStep
            $claudePrompt = New-DuoForgeStagePrompt -RunDirectory $directory -Graph $graph -Step $claudeStep
            [ordered]@{
                codex = Get-DuoForgeProviderCommandSpecInternal -Provider codex -RunDirectory $directory -Step $codexStep -Prompt $codexPrompt
                claude = Get-DuoForgeProviderCommandSpecInternal -Provider claude -RunDirectory $directory -Step $claudeStep -Prompt $claudePrompt
            }
        } $run.runDirectory
        $codexArgs = @($specs.codex.arguments) -join ' '
        Assert-ContainsText $codexArgs '--ask-for-approval never'
        Assert-ContainsText $codexArgs '--model gpt-5.6'
        Assert-ContainsText $codexArgs '--config model_reasoning_effort="high"'
        Assert-ContainsText $codexArgs '--sandbox read-only'
        Assert-ContainsText $codexArgs '--ignore-user-config'
        Assert-ContainsText $codexArgs '--ignore-rules'
        Assert-ContainsText $codexArgs '--config web_search="disabled"'
        Assert-NotContainsText $codexArgs 'dangerously'
        $claudeArgs = @($specs.claude.arguments) -join ' '
        Assert-ContainsText $claudeArgs '--model sonnet'
        Assert-ContainsText $claudeArgs '--effort high'
        Assert-ContainsText $claudeArgs '--safe-mode'
        Assert-ContainsText $claudeArgs '--strict-mcp-config'
        Assert-ContainsText $claudeArgs '--tools'
        Assert-ContainsText $claudeArgs '--no-session-persistence'
        Assert-NotContainsText $claudeArgs '--max-turns'
        Assert-NotContainsText $specs.codex.prompt ([System.IO.Path]::GetFullPath($input))
        Assert-NotContainsText $specs.claude.prompt ([System.IO.Path]::GetFullPath($input))
        $environmentAllowList = & $module { Get-DuoForgeProviderEnvironmentAllowList }
        Assert-False ('OPENAI_API_KEY' -in $environmentAllowList)
        Assert-False ('ANTHROPIC_API_KEY' -in $environmentAllowList)
    }

    Test-Case 'Codex 이벤트 파서는 명령 실행 이벤트를 거부한다' {
        Assert-ThrowsCode -ExpectedCode 'DF-PROVIDER-TOOL-EVENT' -Body {
            & $module { Assert-DuoForgeCodexEventStreamSafe -JsonLines '{"type":"item.completed","item":{"type":"command_execution"}}' }
        }
        & $module { Assert-DuoForgeCodexEventStreamSafe -JsonLines '{"type":"item.completed","item":{"type":"agent_message"}}' }
    }

    Test-Case '공급자 원문은 저장 전에 비밀 패턴을 제거하고 해시만 보존한다' {
        $step = [ordered]@{ stepKey = 'r01-codex-independent-draft'; provider = 'codex'; stage = 'independent-draft'; round = 1 }
        $converted = & $module {
            param($s)
            $result = New-DuoForgeFakeStageResult -Step $s
            $result.summary = 'token sk-proj-1234567890ABCDEF should disappear'
            $raw = $result | ConvertTo-Json -Depth 30 -Compress
            ConvertFrom-DuoForgeProviderResult -RawJson $raw -ExpectedStage $s.stage -ExpectedProvider $s.provider
        } $step
        Assert-True ($converted.redactionCount -gt 0)
        Assert-ContainsText $converted.result.summary '[REDACTED_SECRET]'
        Assert-NotContainsText ($converted | ConvertTo-Json -Depth 30) 'sk-proj-1234567890ABCDEF'
        Assert-True ([string]$converted.rawHash -like 'sha256:*')
    }

    Test-Case 'Claude 봉투는 success의 structured_output만 수용한다' {
        $step = [ordered]@{ stepKey = 'r01-claude-cross-review'; provider = 'claude'; stage = 'cross-review'; round = 1 }
        $converted = & $module {
            param($s)
            $result = New-DuoForgeFakeStageResult -Step $s
            $envelope = [ordered]@{ type = 'result'; subtype = 'success'; is_error = $false; structured_output = $result }
            ConvertFrom-DuoForgeClaudeEnvelope -Json ($envelope | ConvertTo-Json -Depth 40 -Compress) -ExpectedStage $s.stage
        } $step
        Assert-Equal $converted.result.provider 'claude'
        Assert-Equal $converted.result.stage 'cross-review'
        Assert-ThrowsCode -ExpectedCode 'DF-CLAUDE-STRUCTURED-OUTPUT' -Body {
            & $module { ConvertFrom-DuoForgeClaudeEnvelope -Json '{"type":"result","subtype":"success","is_error":false}' -ExpectedStage 'cross-review' }
        }
    }

    Test-Case '독립 문서 모드는 양쪽 원본을 보존하고 최종 비교 산출물을 만든다' {
        $codex = New-MarkdownFile -Path (Join-Path $tempRoot 'dual-e2e\codex\main.md') -Text '# Codex 원본'
        $claude = New-MarkdownFile -Path (Join-Path $tempRoot 'dual-e2e\claude\main.md') -Text '# Claude 원본'
        $beforeCodex = (Get-FileHash -LiteralPath $codex -Algorithm SHA256).Hash
        $beforeClaude = (Get-FileHash -LiteralPath $claude -Algorithm SHA256).Hash
        $workspace = Join-Path $tempRoot 'dual-e2e-results'
        $request = New-TestStartRequest -Mode dual-document -CodexDocument $codex -ClaudeDocument $claude -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $result = & $module {
            param($directory)
            $callback = { param($step) New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $result.status 'COMPLETED'
        foreach ($name in @('codex-final.md', 'claude-final.md', 'comparison.md', 'adoption-log.md', 'OPEN_QUESTIONS.md')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $run.runDirectory "final\$name") -PathType Leaf)
        }
        Assert-Equal (Get-FileHash -LiteralPath $codex -Algorithm SHA256).Hash $beforeCodex
        Assert-Equal (Get-FileHash -LiteralPath $claude -Algorithm SHA256).Hash $beforeClaude
    }

    Test-Case '최종 검증의 Critical 쟁점은 완료를 사용자 결정 대기로 바꾼다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'critical-e2e\input\brief.md')
        $workspace = Join-Path $tempRoot 'critical-e2e-results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $result = & $module {
            param($directory)
            $callback = {
                param($step)
                $stageResult = New-DuoForgeFakeStageResult -Step $step
                if ([string]$step.stage -eq 'final-validation') {
                    $stageResult.finalApproved = $false
                    $stageResult.issues = @([ordered]@{
                        issueKey = 'CODEX-R02-001'
                        target = 'shared-final-document'
                        category = 'safety'
                        severity = 'critical'
                        claim = '필수 안전 경계가 누락되었습니다.'
                        evidence = @()
                        proposal = '안전 경계를 추가하세요.'
                        requiresUser = $false
                        blockingProposal = $false
                    })
                }
                return $stageResult
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $result.status 'AWAITING_USER'
        $ledger = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'issues.json') | ConvertFrom-Json -Depth 50
        Assert-True (@($ledger.issues | Where-Object { $_.severity -eq 'critical' -and $_.blocking }).Count -ge 1)
        $pending = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'decisions\pending.json') | ConvertFrom-Json -Depth 50
        Assert-Equal @($pending.questions).Count 1
        $issueId = [string]$pending.questions[0].issueKey
        $decision = Set-DuoForgeIssueAnswer -RunId $run.runId -IssueId $issueId -Choice A -ResultsRoot $workspace
        Assert-Equal $decision.status 'PAUSED_USER'
        Assert-Equal @($decision.resetSteps).Count 2
        $resumed = & $module {
            param($directory)
            $callback = { param($step) New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $resumed.status 'COMPLETED'
        Assert-Equal $resumed.invoked 2
        Assert-True (Test-Path -LiteralPath (Join-Path $run.runDirectory 'decisions\user-answers.jsonl') -PathType Leaf)
    }
}
finally {
    Write-Host ''
    Write-Host ("테스트 결과: 통과 $script:Passed, 실패 $script:Failed")
    $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
    $resolvedParent = [System.IO.Path]::GetFullPath($tempParent).TrimEnd('\') + '\'
    if ($resolvedTemp.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}

if ($script:Failed -gt 0) { exit 1 }
exit 0
