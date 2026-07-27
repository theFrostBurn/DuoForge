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
        if ($actualCode -ne $ExpectedCode) { throw "예상 오류 '$ExpectedCode', 실제 오류 '$actualCode': $($_.Exception.Message)" }
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
        Write-Host ('       ' + $_.ScriptStackTrace) -ForegroundColor DarkRed
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
        [string]$CodexModel = 'gpt-5.6-sol',
        [string]$CodexReasoningEffort = 'high',
        [string]$ClaudeModel = 'opus',
        [string]$ClaudeReasoningEffort = 'high',
        [string]$DocumentType = 'custom',
        [int]$MaxRounds = 2,
        [string]$Workspace,
        [string]$FirstSynthesizer = 'alternate',
        [bool]$PauseAfterRound = $false,
        [bool]$AllowPartial = $false,
        [string]$Name
    )
    $parameters = @{} + $PSBoundParameters
    $parameters['CodexModel'] = $CodexModel
    $parameters['CodexReasoningEffort'] = $CodexReasoningEffort
    $parameters['ClaudeModel'] = $ClaudeModel
        $parameters['ClaudeReasoningEffort'] = $ClaudeReasoningEffort
        $parameters['AllowPartial'] = $AllowPartial
        return New-DuoForgeStartRequest @parameters
}

function New-MarkdownFile {
    param([string]$Path, [string]$Text = '# 테스트')
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path)) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
    return $Path
}

function Get-TestPromptPriorArtifactStepKeys {
    param([Parameter(Mandatory)][string]$PromptText)

    $startMarker = '<DUOFORGE_UNTRUSTED_DATA_JSON>'
    $endMarker = '</DUOFORGE_UNTRUSTED_DATA_JSON>'
    $start = $PromptText.IndexOf($startMarker, [StringComparison]::Ordinal)
    $end = $PromptText.IndexOf($endMarker, [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -le $start) { throw '프롬프트에서 DuoForge DATA JSON을 찾을 수 없습니다.' }
    $jsonStart = $start + $startMarker.Length
    $payload = $PromptText.Substring($jsonStart, $end - $jsonStart).Trim() | ConvertFrom-Json -Depth 100
    return @($payload.priorArtifacts | ForEach-Object { [string]$_.stepKey })
}

try {
    Test-Case '기본 설정은 2라운드, 최대 3라운드, 3A 비활성화다' {
        $config = Get-DuoForgeDefaultConfig
        Assert-Equal $config.defaultRounds 2
        Assert-Equal $config.maxRounds 3
        Assert-False ([bool]$config.features.dualProjectAudit)
    }

    Test-Case '3A는 격리 게이트가 닫힌 동안 요청 단계에서 실패 폐쇄한다' {
        $codexProject = Join-Path $tempRoot '3a-gate\codex-project'
        $claudeProject = Join-Path $tempRoot '3a-gate\claude-project'
        [System.IO.Directory]::CreateDirectory($codexProject) | Out-Null
        [System.IO.Directory]::CreateDirectory($claudeProject) | Out-Null
        $workspace = Join-Path $tempRoot '3a-gate-results'
        $request = New-TestStartRequest -Mode dual-project-audit -CodexProject $codexProject -ClaudeProject $claudeProject -Workspace $workspace
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        Assert-False ([bool]$validation.valid)
        Assert-Equal @($validation.errors | Where-Object { $_.code -eq 'DF-PREFLIGHT-3A-ISOLATION' }).Count 1
        Assert-False (Test-Path -LiteralPath $workspace)
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

    Test-Case '모델 메뉴 폴백은 CLI 계열과 현재 존재하는 권장 모델 및 추론 정도만 표시한다' {
        $cachePath = Join-Path $tempRoot 'model-menu\models_cache.json'
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($cachePath)) | Out-Null
        $cache = [ordered]@{
            models = @(
                [ordered]@{ slug = 'gpt-5.6-luna'; display_name = 'GPT-5.6-Luna'; description = 'Fast and affordable agentic coding model.'; visibility = 'list'; priority = 3; supported_reasoning_levels = @(@{ effort = 'low' }, @{ effort = 'medium' }, @{ effort = 'high' }, @{ effort = 'xhigh' }, @{ effort = 'max' }) }
                [ordered]@{ slug = 'gpt-5.6-sol'; display_name = 'GPT-5.6-Sol'; description = 'Latest frontier agentic coding model.'; visibility = 'list'; priority = 1; supported_reasoning_levels = @(@{ effort = 'low' }, @{ effort = 'medium' }, @{ effort = 'high' }, @{ effort = 'xhigh' }, @{ effort = 'max' }, @{ effort = 'ultra' }) }
                [ordered]@{ slug = 'gpt-5.5'; display_name = 'GPT-5.5'; description = 'Legacy model.'; visibility = 'hide'; priority = 7; supported_reasoning_levels = @(@{ effort = 'medium' }, @{ effort = 'high' }) }
                [ordered]@{ slug = 'gpt-5.6-terra'; display_name = 'GPT-5.6-Terra'; description = 'Balanced agentic coding model for everyday work.'; visibility = 'list'; priority = 2; supported_reasoning_levels = @(@{ effort = 'low' }, @{ effort = 'medium' }, @{ effort = 'high' }, @{ effort = 'xhigh' }, @{ effort = 'max' }, @{ effort = 'ultra' }) }
            )
        }
        [System.IO.File]::WriteAllText($cachePath, ($cache | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))

        $claudeHelp = @'
  --effort <level>                      Effort level for the current session
                                        (low, medium, high, xhigh, max)
  --exclude-dynamic-system-prompt-sections
  --model <model>                       Model for the current session. Provide
                                        an alias for the latest model (e.g.
                                        'fable', 'opus', or 'sonnet') or a
                                        model's full name (e.g.
                                        'claude-fable-5').
  -n, --name <name>                     Set a display name
'@
        $menu = & $module {
            param($path, $help)
            $codex = Get-DuoForgeProviderSelectionOptionsInternal -Provider codex -CodexModelCachePath $path
            $claude = Get-DuoForgeProviderSelectionOptionsInternal -Provider claude -ClaudeHelpText $help
            [ordered]@{
                codex = $codex
                claude = $claude
                lunaEfforts = @(Get-DuoForgeReasoningEffortsForModelInternal -Options $codex -Model 'gpt-5.6-luna')
            }
        } $cachePath $claudeHelp

        Assert-Equal $menu.codex.catalogSource 'codex-model-cache'
        Assert-Equal (@($menu.codex.suggestedModels.value) -join ',') 'gpt-5.6-sol,gpt-5.6-terra,gpt-5.6-luna'
        Assert-Equal $menu.codex.recommendedModel 'gpt-5.6-sol'
        Assert-Equal $menu.codex.recommendedReasoningEffort 'high'
        Assert-False ('ultra' -cin @($menu.lunaEfforts))
        Assert-Equal $menu.claude.catalogSource 'claude-cli-help'
        Assert-Equal (@($menu.claude.suggestedModels.value) -join ',') 'opus,sonnet,fable,default'
        Assert-Equal $menu.claude.suggestedModels[0].displayName 'Opus'
        Assert-Equal $menu.claude.recommendedModel 'opus'
        Assert-Equal $menu.claude.recommendedReasoningEffort 'high'
    }

    Test-Case 'CLI 카탈로그 변경 시 사라진 모델과 추론 정도에는 권장을 붙이지 않는다' {
        $codexResponse = [ordered]@{
            data = @(
                [ordered]@{
                    model = 'gpt-next'
                    displayName = 'GPT Next'
                    description = 'Current default model.'
                    hidden = $false
                    isDefault = $true
                    defaultReasoningEffort = 'xhigh'
                    supportedReasoningEfforts = @(
                        [ordered]@{ reasoningEffort = 'low'; description = 'Fast' }
                        [ordered]@{ reasoningEffort = 'xhigh'; description = 'Deep' }
                    )
                }
            )
        }
        $claudeHelp = @'
  --effort <level>                      Effort level for the current session
                                        (low, medium)
  --exclude-dynamic-system-prompt-sections
  --model <model>                       Model for the current session. Provide
                                        an alias for the latest model (e.g.
                                        'sonnet') or a model's full name (e.g.
                                        'claude-sonnet-next').
  -n, --name <name>                     Set a display name
'@
        $menu = & $module {
            param($response, $help)
            [ordered]@{
                codex = Get-DuoForgeProviderSelectionOptionsInternal -Provider codex -CodexModelListResponse $response
                claude = Get-DuoForgeProviderSelectionOptionsInternal -Provider claude -ClaudeHelpText $help
                bracketModelValid = Test-DuoForgeModelIdentifierInternal -Model 'opus[1m]'
            }
        } $codexResponse $claudeHelp

        Assert-Equal $menu.codex.catalogSource 'codex-app-server-fixture'
        Assert-Equal (@($menu.codex.suggestedModels.value) -join ',') 'gpt-next'
        Assert-Equal $menu.codex.recommendedModel 'gpt-next'
        Assert-Equal $menu.codex.recommendedReasoningEffort 'xhigh'
        Assert-False ('high' -cin @($menu.codex.reasoningEfforts))
        Assert-Equal (@($menu.claude.suggestedModels.value) -join ',') 'sonnet,default'
        Assert-Equal $menu.claude.recommendedModel 'default'
        Assert-Equal $menu.claude.recommendedReasoningEffort 'medium'
        Assert-False ('opus' -cin @($menu.claude.suggestedModels.value))
        Assert-False ('high' -cin @($menu.claude.reasoningEfforts))
        Assert-True ([bool]$menu.bracketModelValid)
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

    Test-Case '첫 실행 설정은 준비되지 않은 공급자 로그인과 재검사만 제안한다' {
        $ready = [ordered]@{
            readyForDocumentModes = $true
            providers = [ordered]@{
                codex = [ordered]@{ subscription = $true }
                claude = [ordered]@{ subscription = $true }
            }
        }
        $readyActions = & $module { param($report) Get-DuoForgeInteractiveSetupActionsInternal -Report $report } $ready
        Assert-Equal @($readyActions).Count 0
        $blocked = [ordered]@{
            readyForDocumentModes = $false
            providers = [ordered]@{
                codex = [ordered]@{ subscription = $false }
                claude = [ordered]@{ subscription = $true }
            }
        }
        $blockedActions = & $module { param($report) Get-DuoForgeInteractiveSetupActionsInternal -Report $report } $blocked
        Assert-True ('codex-login' -in @($blockedActions))
        Assert-False ('claude-login' -in @($blockedActions))
        Assert-True ('recheck' -in @($blockedActions))
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

    Test-Case '공급자 프로세스는 PowerShell 래퍼보다 종료 코드를 보존하는 실행 파일을 우선한다' {
        $resolution = & $module { Resolve-DuoForgeCommandInvocation -CommandName 'codex' }
        Assert-True ($null -ne $resolution)
        Assert-False ([string]$resolution.source -like '*.ps1')

        $child = & $module {
            Invoke-DuoForgeProcess -CommandName 'pwsh.exe' -Arguments @(
                '-NoLogo', '-NoProfile', '-Command',
                "if ([string]::IsNullOrWhiteSpace(`$env:PATH)) { exit 9 } else { 'PATH_OK' }"
            ) -TimeoutSeconds 20 -EnvironmentAllowList @('PATH')
        }
        Assert-Equal $child.exitCode 0
        Assert-ContainsText ([string]$child.stdout) 'PATH_OK'
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
        Assert-Equal $run.manifest.promptTemplateVersion 'duoforge-stage-v2'
        Assert-Equal $run.manifest.artifactVisibilityPolicy 'transitive-dependencies-v1'
        Assert-Equal $run.manifest.providerSelections.codex.model 'gpt-5.6-sol'
        Assert-Equal $run.manifest.providerSelections.codex.reasoningEffort 'high'
        Assert-Equal $run.manifest.providerSelections.claude.model 'opus'
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
        Assert-Equal ((@($calls | Select-Object -First 4) -join ',')) 'r01-codex-independent-draft,r01-claude-independent-draft,r01-codex-cross-review,r01-claude-cross-review'
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

    Test-Case '같은 장벽의 양쪽 단계는 동일한 선행 산출물만 보고 순차 실행된다' {
        $sharedInput = New-MarkdownFile -Path (Join-Path $tempRoot 'fairness\shared\input\brief.md')
        $sharedWorkspace = Join-Path $tempRoot 'fairness\shared-results'
        $sharedRequest = New-TestStartRequest -Mode shared-document -Brief $sharedInput -Workspace $sharedWorkspace -DocumentType prd
        $sharedValidation = Test-DuoForgeStartRequest -Request $sharedRequest -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $sharedWorkspace)
        $sharedRun = New-DuoForgeRun -ValidationResult $sharedValidation
        $sharedPrompts = @{}
        $sharedCalls = [System.Collections.Generic.List[string]]::new()
        $sharedResult = & $module {
            param($directory, $promptMap, $callList)
            $callback = {
                param($step, $prompt)
                $callList.Add([string]$step.stepKey)
                $promptMap[[string]$step.stepKey] = [string]$prompt.text
                return New-DuoForgeFakeStageResult -Step $step
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $sharedRun.runDirectory $sharedPrompts $sharedCalls
        Assert-Equal $sharedResult.status 'COMPLETED'
        Assert-Equal ((@($sharedCalls | Select-Object -First 4) -join ',')) 'r01-codex-independent-draft,r01-claude-independent-draft,r01-codex-cross-review,r01-claude-cross-review'
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $sharedPrompts['r01-codex-independent-draft']) -join ',')) ''
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $sharedPrompts['r01-claude-independent-draft']) -join ',')) ''
        $sharedDrafts = 'r01-codex-independent-draft,r01-claude-independent-draft'
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $sharedPrompts['r01-codex-cross-review']) -join ',')) $sharedDrafts
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $sharedPrompts['r01-claude-cross-review']) -join ',')) $sharedDrafts
        $sharedReviews = "$sharedDrafts,r01-codex-cross-review,r01-claude-cross-review"
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $sharedPrompts['r01-codex-author-response']) -join ',')) $sharedReviews
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $sharedPrompts['r01-claude-author-response']) -join ',')) $sharedReviews
        $sharedRound2Codex = @(Get-TestPromptPriorArtifactStepKeys -PromptText $sharedPrompts['r02-codex-joint-document-review'])
        $sharedRound2Claude = @(Get-TestPromptPriorArtifactStepKeys -PromptText $sharedPrompts['r02-claude-joint-document-review'])
        Assert-Equal (($sharedRound2Codex -join ',')) (($sharedRound2Claude -join ','))
        Assert-False ('r02-claude-joint-document-review' -in $sharedRound2Codex)
        Assert-False ('r02-codex-joint-document-review' -in $sharedRound2Claude)

        $codexDocument = New-MarkdownFile -Path (Join-Path $tempRoot 'fairness\dual\codex\source.md')
        $claudeDocument = New-MarkdownFile -Path (Join-Path $tempRoot 'fairness\dual\claude\source.md')
        $dualWorkspace = Join-Path $tempRoot 'fairness\dual-results'
        $dualRequest = New-TestStartRequest -Mode dual-document -CodexDocument $codexDocument -ClaudeDocument $claudeDocument -Workspace $dualWorkspace -DocumentType prd
        $dualValidation = Test-DuoForgeStartRequest -Request $dualRequest -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $dualWorkspace)
        $dualRun = New-DuoForgeRun -ValidationResult $dualValidation
        $dualPrompts = @{}
        $dualResult = & $module {
            param($directory, $promptMap)
            $callback = {
                param($step, $prompt)
                $promptMap[[string]$step.stepKey] = [string]$prompt.text
                return New-DuoForgeFakeStageResult -Step $step
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $dualRun.runDirectory $dualPrompts
        Assert-Equal $dualResult.status 'COMPLETED'
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r01-codex-cross-review']) -join ',')) ''
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r01-claude-cross-review']) -join ',')) ''
        $dualReviews = 'r01-codex-cross-review,r01-claude-cross-review'
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r01-codex-owner-response']) -join ',')) $dualReviews
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r01-claude-owner-response']) -join ',')) $dualReviews
        $dualResponses = "$dualReviews,r01-codex-owner-response,r01-claude-owner-response"
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r01-codex-owned-document-revision']) -join ',')) $dualResponses
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r01-claude-owned-document-revision']) -join ',')) $dualResponses
        $dualRound2Codex = @(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r02-codex-cross-review'])
        $dualRound2Claude = @(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r02-claude-cross-review'])
        Assert-Equal (($dualRound2Codex -join ',')) (($dualRound2Claude -join ','))
        Assert-False ('r02-claude-cross-review' -in $dualRound2Codex)
        Assert-False ('r02-codex-cross-review' -in $dualRound2Claude)
    }

    Test-Case '실패 후 재개는 완료된 상대 단계를 다시 호출하지 않는다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'resume\input\brief.md')
        $workspace = Join-Path $tempRoot 'resume\results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $control = @{ fail = $true; calls = [System.Collections.Generic.List[string]]::new(); prompts = @{} }
        $first = & $module {
            param($directory, $controlState)
            $callback = {
                param($step, $prompt)
                $controlState.calls.Add([string]$step.stepKey)
                $controlState.prompts[[string]$step.stepKey] = [string]$prompt.text
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
                param($step, $prompt)
                $controlState.calls.Add([string]$step.stepKey)
                $controlState.prompts[[string]$step.stepKey] = [string]$prompt.text
                return New-DuoForgeFakeStageResult -Step $step
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory $control
        Assert-Equal $second.status 'COMPLETED'
        Assert-Equal @($control.calls | Where-Object { $_ -eq 'r01-codex-independent-draft' }).Count 1
        Assert-Equal @($control.calls | Where-Object { $_ -eq 'r01-claude-independent-draft' }).Count 1
        Assert-Equal @($control.calls | Where-Object { $_ -eq 'r01-codex-cross-review' }).Count 2
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $control.prompts['r01-claude-cross-review']) -join ',')) 'r01-codex-independent-draft,r01-claude-independent-draft'
    }

    Test-Case '단계 결과 계약은 단계와 공급자 불일치를 실패 폐쇄한다' {
        $step = [ordered]@{ stepKey = 'r01-codex-independent-draft'; provider = 'codex'; stage = 'independent-draft'; round = 1 }
        $valid = & $module { param($s) $result = New-DuoForgeFakeStageResult -Step $s; Test-DuoForgeStageResultInternal -Result $result -ExpectedStage $s.stage -ExpectedProvider $s.provider } $step
        Assert-True ([bool]$valid.valid)
        Assert-ThrowsCode -ExpectedCode 'DF-STAGE-SCHEMA' -Body {
            & $module { param($s) $result = New-DuoForgeFakeStageResult -Step $s; $result.provider = 'claude'; Test-DuoForgeStageResultInternal -Result $result -ExpectedStage $s.stage -ExpectedProvider $s.provider -ThrowOnError } $step
        }

        $diagnostic = & $module {
            param($s)
            try {
                $result = New-DuoForgeFakeStageResult -Step $s
                $result.document = $null
                $null = Test-DuoForgeStageResultInternal -Result $result -ExpectedStage $s.stage -ExpectedProvider $s.provider -ThrowOnError
            }
            catch { return @($_.Exception.Data['DuoForgeValidationErrors']) }
        } $step
        Assert-ContainsText ($diagnostic -join ' ') 'document'
    }

    Test-Case '비밀 제거 후 빈 구조화 배열은 두 번째 정규화에서도 배열로 유지된다' {
        $shape = & $module {
            $step = [ordered]@{ stepKey = 'r01-codex-independent-draft'; provider = 'codex'; stage = 'independent-draft'; round = 1 }
            $source = New-DuoForgeFakeStageResult -Step $step
            $source.issues = @(
                [ordered]@{ issueKey = 'I-1'; target = 'document'; category = 'test'; severity = 'minor'; claim = '단일 항목'; evidence = @(); proposal = '유지'; requiresUser = $false; blockingProposal = $false }
            )
            $source.openQuestions = @(
                [ordered]@{ issueKey = 'I-1'; title = '첫 질문'; question = '확인합니까?'; options = @('예', '아니요'); recommendedOption = '예'; reasonNow = '지금 결정'; plainExplanation = '쉬운 설명'; codexOpinion = 'Codex 의견'; claudeOpinion = 'Claude 의견'; impactIfDeferred = '진행 중단'; estimatedCost = '낮음'; reversibility = 'easy'; confidence = 'high'; safeDefault = '예'; experimentPossible = $false },
                [ordered]@{ issueKey = 'I-2'; title = '둘째 질문'; question = '계속합니까?'; options = @('예', '아니요'); recommendedOption = '예'; reasonNow = '지금 결정'; plainExplanation = '쉬운 설명'; codexOpinion = 'Codex 의견'; claudeOpinion = 'Claude 의견'; impactIfDeferred = '진행 중단'; estimatedCost = '낮음'; reversibility = 'easy'; confidence = 'high'; safeDefault = '예'; experimentPossible = $false }
            )
            $redactions = 0
            $protected = Protect-DuoForgeObjectInternal -Value $source -RedactionCount ([ref]$redactions)
            $normalized = ConvertTo-DuoForgeHashtable -InputObject $protected
            [ordered]@{
                validation = Test-DuoForgeStageResultInternal -Result $normalized -ExpectedStage $step.stage -ExpectedProvider $step.provider
                types = @('issues', 'issueResponses', 'adoptions', 'openQuestions') | ForEach-Object { $normalized[$_].GetType().FullName }
                counts = [ordered]@{
                    issues = @($normalized.issues).Count
                    issueResponses = @($normalized.issueResponses).Count
                    adoptions = @($normalized.adoptions).Count
                    openQuestions = @($normalized.openQuestions).Count
                }
            }
        }
        Assert-True ([bool]$shape.validation.valid)
        Assert-Equal (@($shape.types | Where-Object { $_ -eq 'System.Object[]' }).Count) 4
        Assert-Equal $shape.counts.issues 1
        Assert-Equal $shape.counts.issueResponses 0
        Assert-Equal $shape.counts.adoptions 0
        Assert-Equal $shape.counts.openQuestions 2
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

    Test-Case '공정성 가시성 정책이 없는 이전 실행은 새 모델 호출 전에 차단한다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'legacy-visibility\input\brief.md')
        $workspace = Join-Path $tempRoot 'legacy-visibility-results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        & $module {
            param($directory)
            $manifestPath = Join-Path $directory 'manifest.json'
            $manifest = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $manifestPath)
            $manifest.Remove('artifactVisibilityPolicy')
            Write-DuoForgeJsonAtomic -Path $manifestPath -Value $manifest
        } $run.runDirectory
        $control = @{ calls = 0 }
        Assert-ThrowsCode -ExpectedCode 'DF-PROMPT-VISIBILITY-POLICY' -Body {
            & $module {
                param($directory, $controlState)
                $callback = {
                    param($step)
                    $controlState.calls++
                    New-DuoForgeFakeStageResult -Step $step
                }
                Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
            } $run.runDirectory $control
        }
        Assert-Equal $control.calls 0
        Assert-False (Test-Path -LiteralPath (Join-Path $run.runDirectory 'steps.json') -PathType Leaf)
        $state = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'state.json') | ConvertFrom-Json -Depth 50
        Assert-Equal $state.status 'SNAPSHOTTED'
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
        Assert-ContainsText $codexArgs '--model gpt-5.6-sol'
        Assert-ContainsText $codexArgs '--config model_reasoning_effort="high"'
        Assert-ContainsText $codexArgs '--sandbox read-only'
        Assert-ContainsText $codexArgs '--ignore-user-config'
        Assert-ContainsText $codexArgs '--ignore-rules'
        Assert-ContainsText $codexArgs '--config web_search="disabled"'
        Assert-NotContainsText $codexArgs 'dangerously'
        $claudeArgs = @($specs.claude.arguments) -join ' '
        Assert-ContainsText $claudeArgs '--model opus'
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

    Test-Case '구조화 출력 스키마의 상수 필드는 Codex 호환 타입을 명시한다' {
        $stageSchema = Get-Content -LiteralPath (Join-Path $projectRoot 'schemas\stage-result.schema.json') -Raw | ConvertFrom-Json -Depth 100
        $explanationSchema = Get-Content -LiteralPath (Join-Path $projectRoot 'schemas\explanation-result.schema.json') -Raw | ConvertFrom-Json -Depth 100
        Assert-Equal $stageSchema.properties.schemaVersion.type 'integer'
        Assert-Equal $stageSchema.properties.schemaVersion.const 1
        Assert-Equal $explanationSchema.properties.schemaVersion.type 'integer'
        Assert-Equal $explanationSchema.properties.schemaVersion.const 1
    }

    Test-Case '공급자 오류 분류는 원문을 저장하지 않고 한도·인증·시간초과를 구분한다' {
        $classifications = & $module {
            [ordered]@{
                quota = Get-DuoForgeProviderFailureClassificationInternal -Provider claude -ProcessResult ([ordered]@{ started = $true; timedOut = $false; exitCode = 1; stdout = ''; stderr = 'usage limit reached secret-value'; errorCategory = $null })
                rate = Get-DuoForgeProviderFailureClassificationInternal -Provider codex -ProcessResult ([ordered]@{ started = $true; timedOut = $false; exitCode = 1; stdout = ''; stderr = 'too many requests'; errorCategory = $null })
                auth = Get-DuoForgeProviderFailureClassificationInternal -Provider codex -ProcessResult ([ordered]@{ started = $true; timedOut = $false; exitCode = 1; stdout = ''; stderr = 'login required'; errorCategory = $null })
                timeout = Get-DuoForgeProviderFailureClassificationInternal -Provider claude -ProcessResult ([ordered]@{ started = $true; timedOut = $true; exitCode = $null; stdout = ''; stderr = ''; errorCategory = 'timeout' })
                schema = Get-DuoForgeProviderFailureClassificationInternal -Provider codex -ProcessResult ([ordered]@{ started = $true; timedOut = $false; exitCode = 1; stdout = '{"type":"error","error":{"code":"invalid_json_schema"}}'; stderr = ''; errorCategory = $null })
            }
        }
        Assert-Equal $classifications.quota.code 'DF-PROVIDER-QUOTA'
        Assert-Equal $classifications.quota.targetStatus 'PAUSED_QUOTA'
        Assert-False ([bool]$classifications.quota.retryable)
        Assert-Equal $classifications.rate.code 'DF-PROVIDER-RATE-LIMIT'
        Assert-True ([bool]$classifications.rate.retryable)
        Assert-Equal $classifications.auth.targetStatus 'BLOCKED_PREFLIGHT'
        Assert-Equal $classifications.timeout.code 'DF-PROVIDER-TIMEOUT'
        Assert-True ([bool]$classifications.timeout.retryable)
        Assert-Equal $classifications.schema.code 'DF-PROVIDER-SCHEMA-COMPAT'
        Assert-Equal $classifications.schema.targetStatus 'BLOCKED_PREFLIGHT'
        Assert-False ([bool]$classifications.schema.retryable)
        Assert-NotContainsText ($classifications | ConvertTo-Json -Depth 20) 'secret-value'
    }

    Test-Case '구조 오류는 한 번만 자동 재시도하고 구독 한도는 안전하게 일시정지 후 재개한다' {
        $retryInput = New-MarkdownFile -Path (Join-Path $tempRoot 'retry-once\input\brief.md')
        $retryWorkspace = Join-Path $tempRoot 'retry-once-results'
        $retryRequest = New-TestStartRequest -Mode shared-document -Brief $retryInput -Workspace $retryWorkspace -DocumentType prd
        $retryValidation = Test-DuoForgeStartRequest -Request $retryRequest -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $retryWorkspace)
        $retryRun = New-DuoForgeRun -ValidationResult $retryValidation
        $retryControl = @{ failed = $false; promptKinds = @(); promptHashes = @() }
        $retryResult = & $module {
            param($directory, $control)
            $callback = {
                param($step, $prompt)
                $control.promptKinds = @($control.promptKinds) + @([string]$prompt.kind)
                $control.promptHashes = @($control.promptHashes) + @([string]$prompt.sha256)
                $result = New-DuoForgeFakeStageResult -Step $step
                if (-not $control.failed -and [string]$step.stepKey -eq 'r01-codex-independent-draft') {
                    $control.failed = $true
                    $result.provider = 'claude'
                }
                return $result
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $retryRun.runDirectory $retryControl
        Assert-Equal $retryResult.status 'COMPLETED'
        Assert-Equal @($retryControl.promptKinds | Where-Object { $_ -eq 'FORMAT_REPAIR' }).Count 1
        $stageIndex = [Array]::IndexOf([object[]]$retryControl.promptKinds, 'STAGE')
        $repairIndex = [Array]::IndexOf([object[]]$retryControl.promptKinds, 'FORMAT_REPAIR')
        Assert-True ($retryControl.promptHashes[$stageIndex] -ne $retryControl.promptHashes[$repairIndex]) '형식 복구 프롬프트 해시가 원래 프롬프트와 달라야 합니다.'
        $retryGraph = Get-Content -Raw -LiteralPath (Join-Path $retryRun.runDirectory 'steps.json') | ConvertFrom-Json -Depth 50
        Assert-Equal (@($retryGraph.steps | Where-Object { $_.stepKey -eq 'r01-codex-independent-draft' })[0].attemptCount) 2

        $quotaInput = New-MarkdownFile -Path (Join-Path $tempRoot 'quota\input\brief.md')
        $quotaWorkspace = Join-Path $tempRoot 'quota-results'
        $quotaRequest = New-TestStartRequest -Mode shared-document -Brief $quotaInput -Workspace $quotaWorkspace -DocumentType prd
        $quotaValidation = Test-DuoForgeStartRequest -Request $quotaRequest -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $quotaWorkspace)
        $quotaRun = New-DuoForgeRun -ValidationResult $quotaValidation
        $quotaControl = @{ failed = $false }
        $paused = & $module {
            param($directory, $control)
            $callback = {
                param($step)
                if (-not $control.failed) {
                    $control.failed = $true
                    $classification = Get-DuoForgeProviderFailureClassificationInternal -Provider ([string]$step.provider) -ProcessResult ([ordered]@{ started = $true; timedOut = $false; exitCode = 1; stdout = ''; stderr = 'usage limit reached'; errorCategory = $null })
                    throw (New-DuoForgeProviderFailureExceptionInternal -Classification $classification)
                }
                return New-DuoForgeFakeStageResult -Step $step
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $quotaRun.runDirectory $quotaControl
        Assert-Equal $paused.status 'PAUSED_QUOTA'
        Assert-Equal $paused.code 'DF-PROVIDER-QUOTA'
        $pausedGraph = Get-Content -Raw -LiteralPath (Join-Path $quotaRun.runDirectory 'steps.json') | ConvertFrom-Json -Depth 50
        Assert-Equal (@($pausedGraph.steps | Where-Object { $_.stepKey -eq $paused.failedStep })[0].attemptCount) 1
        $resumed = & $module {
            param($directory)
            $callback = { param($step) New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $quotaRun.runDirectory
        Assert-Equal $resumed.status 'COMPLETED'
        $resumedGraph = Get-Content -Raw -LiteralPath (Join-Path $quotaRun.runDirectory 'steps.json') | ConvertFrom-Json -Depth 50
        Assert-Equal (@($resumedGraph.steps | Where-Object { $_.stepKey -eq $paused.failedStep })[0].attemptCount) 2
    }

    Test-Case '사용자 일시정지 요청은 현재 호출을 보존하고 다음 호출 전에 멈춘다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'pause-user\input\brief.md')
        $workspace = Join-Path $tempRoot 'pause-user-results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $requested = Request-DuoForgePause -RunId $run.runId -ResultsRoot $workspace
        Assert-True ([bool]$requested.requested)
        $pausedBeforeCall = & $module {
            param($directory)
            $callback = { param($step) New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $pausedBeforeCall.status 'PAUSED_USER'
        Assert-Equal $pausedBeforeCall.invoked 0
        $completed = & $module {
            param($directory)
            $callback = { param($step) New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $completed.status 'COMPLETED'

        $duringInput = New-MarkdownFile -Path (Join-Path $tempRoot 'pause-during\input\brief.md')
        $duringWorkspace = Join-Path $tempRoot 'pause-during-results'
        $duringRequest = New-TestStartRequest -Mode shared-document -Brief $duringInput -Workspace $duringWorkspace -DocumentType prd
        $duringValidation = Test-DuoForgeStartRequest -Request $duringRequest -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $duringWorkspace)
        $duringRun = New-DuoForgeRun -ValidationResult $duringValidation
        $control = @{ requested = $false }
        $pausedAfterCall = & $module {
            param($directory, $runId, $resultsRoot, $control)
            $callback = {
                param($step)
                if (-not $control.requested) {
                    $control.requested = $true
                    $null = Request-DuoForgePauseInternal -RunId $runId -ResultsRoot $resultsRoot
                }
                return New-DuoForgeFakeStageResult -Step $step
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $duringRun.runDirectory $duringRun.runId $duringWorkspace $control
        Assert-Equal $pausedAfterCall.status 'PAUSED_USER'
        Assert-Equal $pausedAfterCall.invoked 1
        Assert-Equal $pausedAfterCall.checkpoint 'r01-codex-independent-draft'
        $duringGraph = Get-Content -Raw -LiteralPath (Join-Path $duringRun.runDirectory 'steps.json') | ConvertFrom-Json -Depth 50
        Assert-Equal (@($duringGraph.steps | Where-Object { $_.stepKey -eq 'r01-codex-independent-draft' })[0].status) 'COMMITTED'
        Assert-Equal (@($duringGraph.steps | Where-Object { $_.stepKey -eq 'r01-claude-independent-draft' })[0].status) 'PENDING'
        $resumeObservation = @{ firstStep = $null; prompt = $null }
        $duringCompleted = & $module {
            param($directory, $observation)
            $callback = {
                param($step, $prompt)
                if ($null -eq $observation.firstStep) {
                    $observation.firstStep = [string]$step.stepKey
                    $observation.prompt = [string]$prompt.text
                }
                New-DuoForgeFakeStageResult -Step $step
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $duringRun.runDirectory $resumeObservation
        Assert-Equal $duringCompleted.status 'COMPLETED'
        Assert-Equal $resumeObservation.firstStep 'r01-claude-independent-draft'
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $resumeObservation.prompt) -join ',')) ''
        $duringCompletedGraph = Get-Content -Raw -LiteralPath (Join-Path $duringRun.runDirectory 'steps.json') | ConvertFrom-Json -Depth 50
        Assert-Equal (@($duringCompletedGraph.steps | Where-Object { $_.stepKey -eq 'r01-codex-independent-draft' })[0].attemptCount) 1
    }

    Test-Case 'pause-after-round는 각 라운드 경계에서 한 번만 멈춘다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'pause-round\input\brief.md')
        $workspace = Join-Path $tempRoot 'pause-round-results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd -PauseAfterRound $true
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        Assert-True ([bool]$run.manifest.pauseAfterRound)
        $first = & $module {
            param($directory)
            $callback = { param($step) New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $first.status 'PAUSED_USER'
        Assert-Equal $first.pausedReason 'pause-after-round'
        Assert-Equal $first.round 1
        Assert-Equal $first.invoked 7
        $second = & $module {
            param($directory)
            $callback = { param($step) New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $second.status 'PAUSED_USER'
        Assert-Equal $second.round 2
        Assert-Equal $second.invoked 5
        $third = & $module {
            param($directory)
            $callback = { param($step) New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $third.status 'COMPLETED' ($third | ConvertTo-Json -Depth 20 -Compress)
        Assert-Equal $third.invoked 1
        $history = & $module { param($directory) Read-DuoForgeJsonLines -Path (Join-Path $directory 'control\pause-history.jsonl') } $run.runDirectory
        Assert-Equal @($history | Where-Object { $_.reason -eq 'pause-after-round' }).Count 2
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
        Assert-Equal $resumed.status 'COMPLETED' ($resumed | ConvertTo-Json -Depth 20 -Compress)
        Assert-Equal $resumed.invoked 2
        Assert-True (Test-Path -LiteralPath (Join-Path $run.runDirectory 'decisions\user-answers.jsonl') -PathType Leaf)
    }

    Test-Case '쟁점 설명은 같은 스냅샷으로 관점별 결과를 저장하고 상태와 예산을 지킨다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'explanation\input\brief.md') -Text '# 설명 대상 PRD'
        $workspace = Join-Path $tempRoot 'explanation-results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $engineResult = & $module {
            param($directory)
            $callback = {
                param($step)
                $stageResult = New-DuoForgeFakeStageResult -Step $step
                if ([string]$step.stage -eq 'final-validation') {
                    $stageResult.finalApproved = $false
                    $stageResult.issues = @([ordered]@{
                        issueKey = 'CLAUDE-R02-001'
                        target = 'shared-final-document'
                        category = 'core-requirement'
                        severity = 'critical'
                        claim = '데이터 보존 정책을 사용자가 결정해야 합니다.'
                        evidence = @([ordered]@{ source = 'S000001.md'; location = '본문'; excerptHash = 'sha256:test' })
                        proposal = '보존 기간을 선택하세요.'
                        requiresUser = $true
                        blockingProposal = $true
                    })
                }
                return $stageResult
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $engineResult.status 'AWAITING_USER'
        $pending = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'decisions\pending.json') | ConvertFrom-Json -Depth 50
        $issueId = [string]$pending.questions[0].issueKey

        $explanation = & $module {
            param($runId, $issueKey, $resultsRoot)
            $callback = {
                param($provider, $prompt, $issue)
                New-DuoForgeFakeExplanationResultInternal -Provider $provider -IssueId ([string]$issue.issueId) -Level beginner
            }
            Invoke-DuoForgeIssueExplanationInternal -RunId $runId -IssueId $issueKey -Provider both -Level beginner -Focus evidence -ResultsRoot $resultsRoot -ProviderInvoker $callback
        } $run.runId $issueId $workspace
        Assert-Equal $explanation.status 'AWAITING_USER'
        Assert-Equal @($explanation.explanations).Count 2
        Assert-Equal $explanation.explanations[0].contextHash $explanation.explanations[1].contextHash
        Assert-Equal (@($explanation.explanations[0].snapshotHashes) -join ',') (@($explanation.explanations[1].snapshotHashes) -join ',')
        Assert-Equal $explanation.budget.used 2
        Assert-Equal $explanation.budget.remaining 4
        $state = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'state.json') | ConvertFrom-Json -Depth 20
        Assert-Equal $state.status 'AWAITING_USER'
        $prompt = & $module { param($directory, $issueKey) New-DuoForgeIssueExplanationPromptInternal -RunDirectory $directory -Provider codex -IssueId $issueKey -Level expert -Focus tradeoffs } $run.runDirectory $issueId
        Assert-NotContainsText $prompt.text ([System.IO.Path]::GetFullPath($input))
        Assert-ContainsText $prompt.text 'DUOFORGE_UNTRUSTED_DATA_JSON'

        1..2 | ForEach-Object {
            $null = & $module {
                param($runId, $issueKey, $resultsRoot)
                $callback = { param($provider, $prompt, $issue) New-DuoForgeFakeExplanationResultInternal -Provider $provider -IssueId ([string]$issue.issueId) -Level general }
                Invoke-DuoForgeIssueExplanationInternal -RunId $runId -IssueId $issueKey -Provider both -Level general -ResultsRoot $resultsRoot -ProviderInvoker $callback
            } $run.runId $issueId $workspace
        }
        $stored = Get-DuoForgeIssueExplanations -RunId $run.runId -IssueId $issueId -ResultsRoot $workspace
        Assert-Equal @($stored.explanations).Count 6
        Assert-Equal $stored.budget.remaining 0
        Assert-ThrowsCode -ExpectedCode 'DF-EXPLANATION-LIMIT' -Body {
            & $module {
                param($runId, $issueKey, $resultsRoot)
                $callback = { param($provider, $prompt, $issue) New-DuoForgeFakeExplanationResultInternal -Provider $provider -IssueId ([string]$issue.issueId) -Level general }
                Invoke-DuoForgeIssueExplanationInternal -RunId $runId -IssueId $issueKey -Provider codex -Level general -ResultsRoot $resultsRoot -ProviderInvoker $callback
            } $run.runId $issueId $workspace
        }
        Assert-ThrowsCode -ExpectedCode 'DF-EXPLANATION-SCHEMA' -Body {
            & $module {
                $bad = New-DuoForgeFakeExplanationResultInternal -Provider codex -IssueId 'D-001' -Level general
                $bad.provider = 'claude'
                ConvertFrom-DuoForgeExplanationResultInternal -RawJson ($bad | ConvertTo-Json -Depth 30 -Compress) -ExpectedProvider codex -ExpectedIssueId 'D-001' -ExpectedLevel general
            }
        }
    }

    Test-Case '추가 근거는 불변 스냅샷으로 보존되고 요청 쟁점만 다시 검증한다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'evidence\input\brief.md') -Text '# 근거 대기 PRD'
        $evidenceFile = New-MarkdownFile -Path (Join-Path $tempRoot 'evidence-source\proof.md') -Text "# 검증 근거`n`n보존 기간은 30일입니다."
        $sourceHash = (Get-FileHash -LiteralPath $evidenceFile -Algorithm SHA256).Hash
        $workspace = Join-Path $tempRoot 'evidence-results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation

        $waiting = & $module {
            param($directory)
            $callback = {
                param($step)
                $stageResult = New-DuoForgeFakeStageResult -Step $step
                if ([string]$step.stage -eq 'final-validation') {
                    $stageResult.finalApproved = $false
                    $stageResult.issues = @([ordered]@{
                        issueKey = 'EVIDENCE-R02-001'
                        target = 'shared-final-document'
                        category = 'core-requirement'
                        severity = 'major'
                        claim = '보존 기간을 확인할 근거가 없습니다.'
                        evidence = @()
                        proposal = '보존 기간을 명시한 근거 문서를 추가하세요.'
                        requiresUser = $false
                        blockingProposal = $true
                    })
                    $stageResult.issueResponses = @([ordered]@{
                        issueKey = 'EVIDENCE-R02-001'
                        disposition = 'NEEDS_EVIDENCE'
                        rationale = '현재 입력으로 보존 기간을 확인할 수 없습니다.'
                        locations = @()
                    })
                }
                return $stageResult
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $waiting.status 'AWAITING_EVIDENCE'
        $ledger = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'issues.json') | ConvertFrom-Json -Depth 50
        $issue = @($ledger.issues | Where-Object { $_.resolutionStatus -eq 'AWAITING_EVIDENCE' })[0]
        Assert-True ($null -ne $issue) 'AWAITING_EVIDENCE 쟁점을 찾지 못했습니다.'
        $pending = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'decisions\pending.json') | ConvertFrom-Json -Depth 50
        Assert-Equal @($pending.questions).Count 0

        $added = Add-DuoForgeIssueEvidence -RunId $run.runId -IssueId ([string]$issue.issueId) -File $evidenceFile -ResultsRoot $workspace
        Assert-Equal $added.status 'PAUSED_USER'
        Assert-Equal $added.snapshotName 'E000001.md'
        Assert-Equal @($added.resetSteps).Count 2
        $snapshotPath = Join-Path $run.runDirectory 'inputs\snapshots\E000001.md'
        Assert-True (Test-Path -LiteralPath $snapshotPath -PathType Leaf) '근거 스냅샷 파일이 없습니다.'
        Assert-Equal (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash $sourceHash
        Assert-Equal (Get-FileHash -LiteralPath $evidenceFile -Algorithm SHA256).Hash $sourceHash

        $inventory = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'inputs\inventory.json') | ConvertFrom-Json -Depth 50
        Assert-True ('E000001.md' -in @($inventory.roles.shared.context)) '근거 스냅샷이 공유 문맥 역할에 없습니다.'
        Assert-Equal @($inventory.snapshots | Where-Object { $_.snapshotName -eq 'E000001.md' -and $_.issueId -eq $issue.issueId }).Count 1
        $manifest = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'manifest.json') | ConvertFrom-Json -Depth 50
        Assert-True ([string]$added.snapshotHash -in @($manifest.inputSnapshotHashes)) '근거 해시가 매니페스트에 없습니다.'
        $updatedLedger = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'issues.json') | ConvertFrom-Json -Depth 50
        $updatedIssue = @($updatedLedger.issues | Where-Object { $_.issueId -eq $issue.issueId })[0]
        Assert-Equal $updatedIssue.resolutionStatus 'OPEN'
        Assert-Equal @($updatedIssue.history | Where-Object { $_.event -eq 'USER_EVIDENCE_ADDED' }).Count 1
        Assert-ThrowsCode -ExpectedCode 'DF-EVIDENCE-NOT-REQUESTED' -Body {
            Add-DuoForgeIssueEvidence -RunId $run.runId -IssueId ([string]$issue.issueId) -File $evidenceFile -ResultsRoot $workspace
        }

        $prompt = & $module {
            param($directory)
            $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $directory 'steps.json'))
            $step = @($graph.steps | Where-Object { $_.status -in @('PENDING', 'STALE') } | Select-Object -First 1)[0]
            New-DuoForgeStagePrompt -RunDirectory $directory -Graph $graph -Step $step
        } $run.runDirectory
        Assert-True ('E000001.md' -in @($prompt.snapshotNames)) '재실행 프롬프트 스냅샷 목록에 근거가 없습니다.'
        Assert-ContainsText $prompt.text '보존 기간은 30일입니다.'
        Assert-ContainsText $prompt.text 'EVIDENCE-R02-001'
        Assert-NotContainsText $prompt.text ([System.IO.Path]::GetFullPath($evidenceFile))

        $resumed = & $module {
            param($directory, $issueId)
            $callback = {
                param($step)
                $stageResult = New-DuoForgeFakeStageResult -Step $step
                if ([string]$step.stage -eq 'synthesis') {
                    $stageResult.issueResponses = @([ordered]@{
                        issueKey = $issueId
                        disposition = 'ACCEPTED'
                        rationale = '추가 근거에서 30일 보존 기간을 확인해 문서에 반영했습니다.'
                        locations = @('보존 정책 섹션')
                    })
                }
                return $stageResult
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory ([string]$issue.issueId)
        Assert-Equal $resumed.status 'COMPLETED' ($resumed | ConvertTo-Json -Depth 20 -Compress)
        Assert-Equal $resumed.invoked 2
        $finalLedger = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'issues.json') | ConvertFrom-Json -Depth 50
        $finalIssue = @($finalLedger.issues | Where-Object { $_.issueId -eq $issue.issueId })[0]
        Assert-Equal $finalIssue.resolutionStatus 'RESOLVED'
        Assert-Equal @($finalIssue.history | Where-Object { $_.event -eq 'USER_EVIDENCE_ADDED' }).Count 1
        Assert-Equal @($finalIssue.evidence | Where-Object { $_.source -eq 'E000001.md' -and $_.addedBy -eq 'user' }).Count 1
    }

    Test-Case '인증 실패 행렬은 메뉴와 CLI에서 같은 실패 폐쇄 게이트를 사용한다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'auth-matrix\input\brief.md')
        $scenarios = @(
            [ordered]@{ name = '미로그인'; codex = $false; claude = $false; expectedActions = 'codex-login,claude-login,show-manual-login,recheck,exit' },
            [ordered]@{ name = 'Codex만 성공'; codex = $true; claude = $false; expectedActions = 'claude-login,show-manual-login,recheck,exit' },
            [ordered]@{ name = 'Claude 만료'; codex = $true; claude = $false; expectedActions = 'claude-login,show-manual-login,recheck,exit' }
        )
        foreach ($scenario in $scenarios) {
            $report = [ordered]@{
                readyForDocumentModes = $false
                readyForProjectAudit = $false
                providers = [ordered]@{
                    codex = [ordered]@{ version = 'codex-test'; authType = if ($scenario.codex) { 'chatgpt' } else { 'unknown' }; subscription = [bool]$scenario.codex; authenticated = [bool]$scenario.codex }
                    claude = [ordered]@{ version = 'claude-test'; authType = if ($scenario.claude) { 'claude.ai' } else { 'unknown' }; subscription = [bool]$scenario.claude; authenticated = [bool]$scenario.claude }
                }
            }
            $parity = & $module {
                param($doctor)
                [ordered]@{
                    gate = Get-DuoForgeAuthenticationGateInternal -Report $doctor
                    menuActions = @(Get-DuoForgeInteractiveSetupActionsInternal -Report $doctor)
                    cancelled = Get-DuoForgeGuidedLoginOutcomeInternal -Provider claude -ExitCode 1 -PostReport $doctor
                }
            } $report
            Assert-False ([bool]$parity.gate.modelCallsAllowed) "$($scenario.name)에서 모델 호출이 열렸습니다."
            Assert-False ([bool]$parity.gate.inputTransferAllowed) "$($scenario.name)에서 입력 전송이 열렸습니다."
            Assert-Equal ($parity.gate.actions -join ',') $scenario.expectedActions
            Assert-Equal ($parity.menuActions -join ',') $scenario.expectedActions
            Assert-Equal $parity.cancelled.status 'CANCELLED_OR_FAILED'

            $workspace = Join-Path $tempRoot ("auth-matrix-results\" + $scenario.name)
            $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
            $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport $report -Config (New-TestConfig -ResultsRoot $workspace)
            Assert-False ([bool]$validation.valid)
            Assert-Equal @($validation.errors | Where-Object { $_.code -eq 'DF-PREFLIGHT-PROVIDERS' }).Count 1
            Assert-False (Test-Path -LiteralPath $workspace) '인증 실패 시 실행 폴더가 생성되었습니다.'
        }
    }

    Test-Case '질문 카드는 우선순위대로 최대 3개만 한 배치에 표시하고 결정 정보를 보강한다' {
        $cardResult = & $module {
            $issues = @()
            $questions = @()
            for ($index = 1; $index -le 5; $index++) {
                $key = "Q-$index"
                $issues += [ordered]@{ issueKey = $key; target = 'document'; category = 'choice'; severity = if ($index -eq 1) { 'critical' } else { 'major' }; claim = "선택 $index 필요"; evidence = @(); proposal = '사용자 선택'; requiresUser = $true; blockingProposal = $true }
                $questions += [ordered]@{ issueKey = $key; title = "질문 $index"; question = '어느 쪽을 선택할까요?'; options = @('A안', 'B안'); recommendedOption = 'A안' }
            }
            $stage = [ordered]@{ stepKey = 'r02-claude-final-validation'; provider = 'claude'; stage = 'final-validation'; round = 2; result = [ordered]@{ schemaVersion = 1; stage = 'final-validation'; provider = 'claude'; summary = '질문'; document = $null; issues = $issues; issueResponses = @(); adoptions = @(); openQuestions = $questions; finalApproved = $false } }
            $secondStage = ConvertTo-DuoForgeHashtable -InputObject $stage
            $secondStage.stepKey = 'r02-codex-final-validation'
            $secondStage.provider = 'codex'
            $secondStage.result.provider = 'codex'
            $merged = Merge-DuoForgeStageIssues -StageResults @($stage, $secondStage)
            [ordered]@{ merged = $merged; batch = Get-DuoForgePendingQuestionBatchInternal -Questions @($merged.questions) }
        }
        Assert-Equal $cardResult.merged.questions.Count 5
        Assert-Equal $cardResult.batch.batchSize 3
        Assert-Equal $cardResult.batch.remainingAfterBatch 2
        $first = $cardResult.batch.questions[0]
        Assert-Equal $first.priority 1
        Assert-False ([string]::IsNullOrWhiteSpace([string]$first.impactIfDeferred))
        Assert-False ([string]::IsNullOrWhiteSpace([string]$first.estimatedCost))
        Assert-True ([string]$first.reversibility -in @('easy', 'moderate', 'hard', 'unknown'))
        Assert-True ([string]$first.confidence -in @('low', 'medium', 'high'))
    }

    Test-Case '최신 사용자 결정은 과거 라운드의 동일 질문을 확정 처리한다' {
        $decisionMerge = & $module {
            $stage = [ordered]@{
                stepKey = 'r01-claude-cross-review'
                provider = 'claude'
                stage = 'cross-review'
                round = 1
                result = [ordered]@{
                    schemaVersion = 1; stage = 'cross-review'; provider = 'claude'; summary = '결정 필요'; document = $null
                    issues = @([ordered]@{ issueKey = 'CLAUDE-R01-001'; target = 'document'; category = 'choice'; severity = 'major'; claim = '저장 주기를 정해야 합니다.'; evidence = @(); proposal = '5초 저장'; requiresUser = $true; blockingProposal = $true })
                    issueResponses = @(); adoptions = @()
                    openQuestions = @([ordered]@{ issueKey = 'CLAUDE-R01-001'; title = '저장 주기'; question = '어떻게 저장할까요?'; options = @('5초', '10초'); recommendedOption = '5초' })
                    finalApproved = $null
                }
            }
            $first = Merge-DuoForgeStageIssues -StageResults @($stage)
            $issueId = [string]$first.issues[0].issueId
            $decisions = @(
                [ordered]@{ decisionId = 'decision-old'; issueId = $issueId; action = 'ANSWER'; revision = 1; selectedOption = '10초'; recordedAt = '2026-07-27T00:00:00Z' },
                [ordered]@{ decisionId = 'decision-current'; issueId = $issueId; action = 'ANSWER'; revision = 2; selectedOption = '5초'; recordedAt = '2026-07-27T00:00:01Z' }
            )
            $merged = Merge-DuoForgeStageIssues -StageResults @($stage) -PreservedIssues @($first.issues) -UserDecisionRecords $decisions
            [ordered]@{ issueId = $issueId; merged = $merged }
        }
        Assert-Equal @($decisionMerge.merged.questions).Count 0
        $resolvedIssue = @($decisionMerge.merged.issues | Where-Object { [string]$_.issueId -eq [string]$decisionMerge.issueId })[0]
        Assert-Equal $resolvedIssue.resolutionStatus 'RESOLVED'
        Assert-False ([bool]$resolvedIssue.blocking)
        Assert-Equal @($resolvedIssue.responses.user | Where-Object { $_.decisionId -eq 'decision-current' }).Count 1
        Assert-Equal @($resolvedIssue.history | Where-Object { $_.event -eq 'USER_DECISION_APPLIED' -and $_.decisionId -eq 'decision-current' }).Count 1
    }

    Test-Case '사용자는 결정을 변경하고 자유 제약을 확인 후 적용하며 3라운드를 추가할 수 있다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'decision-round\input\brief.md')
        $workspace = Join-Path $tempRoot 'decision-round-results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $waiting = & $module {
            param($directory)
            $callback = {
                param($step)
                $result = New-DuoForgeFakeStageResult -Step $step
                if ([string]$step.stage -eq 'final-validation') {
                    $result.finalApproved = $false
                    $result.issues = @([ordered]@{ issueKey = 'CHANGE-R02-001'; target = 'shared-final-document'; category = 'preference'; severity = 'major'; claim = '배포 전략 선택이 필요합니다.'; evidence = @(); proposal = '점진 배포를 선택하세요.'; requiresUser = $true; blockingProposal = $true })
                    $result.openQuestions = @([ordered]@{ issueKey = 'CHANGE-R02-001'; title = '배포 전략'; question = '어떤 전략을 선택할까요?'; options = @('점진 배포', '일괄 배포'); recommendedOption = '점진 배포'; reasonNow = '배포 전에 전략을 확정해야 합니다.'; plainExplanation = '출시 범위를 한 번에 넓힐지 나눌지 정하는 문제입니다.'; codexOpinion = '점진 배포를 권고합니다.'; claudeOpinion = '점진 배포를 권고합니다.'; estimatedCost = '중간'; reversibility = 'moderate'; confidence = 'high'; impactIfDeferred = '출시 지연'; safeDefault = '점진 배포'; experimentPossible = $true })
                }
                $result
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $waiting.status 'AWAITING_USER'
        $pending = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'decisions\pending.json') | ConvertFrom-Json -Depth 50
        $issueId = [string]$pending.questions[0].issueKey
        $first = Set-DuoForgeIssueAnswer -RunId $run.runId -IssueId $issueId -Choice A -ResultsRoot $workspace
        $changed = Set-DuoForgeIssueAnswer -RunId $run.runId -IssueId $issueId -Choice B -ResultsRoot $workspace -ReplacePrevious
        Assert-Equal $first.revision 1
        Assert-Equal $changed.revision 2
        $decisionAudit = & $module {
            param($directory)
            $records = @(Read-DuoForgeJsonLines -Path (Join-Path $directory 'decisions\user-answers.jsonl') -AllowMissing)
            [ordered]@{ records = $records; effective = @(Get-DuoForgeEffectiveUserDecisionsInternal -Records $records) }
        } $run.runDirectory
        Assert-Equal @($decisionAudit.records | Where-Object { $_.action -eq 'ANSWER' }).Count 2
        Assert-Equal @($decisionAudit.effective | Where-Object { $_.action -eq 'ANSWER' }).Count 1
        Assert-Equal @($decisionAudit.effective | Where-Object { $_.action -eq 'ANSWER' })[0].selectedOption '일괄 배포'
        $multipleIssueDecisions = & $module {
            $records = @(
                [ordered]@{ action = 'ANSWER'; issueId = 'D-001'; revision = 1; selectedOption = '첫 답변'; recordedAt = '2026-07-27T00:00:00Z' },
                [ordered]@{ action = 'ANSWER'; issueId = 'D-002'; revision = 1; selectedOption = '둘째 쟁점 답변'; recordedAt = '2026-07-27T00:00:01Z' },
                [ordered]@{ action = 'ANSWER'; issueId = 'D-001'; revision = 2; selectedOption = '변경된 답변'; recordedAt = '2026-07-27T00:00:02Z' }
            )
            @(Get-DuoForgeEffectiveUserDecisionsInternal -Records $records)
        }
        Assert-Equal @($multipleIssueDecisions | Where-Object { $_.action -eq 'ANSWER' }).Count 2
        Assert-Equal @($multipleIssueDecisions | Where-Object { $_.issueId -eq 'D-001' })[0].selectedOption '변경된 답변'
        Assert-Equal @($multipleIssueDecisions | Where-Object { $_.issueId -eq 'D-002' })[0].selectedOption '둘째 쟁점 답변'
        $preview = Get-DuoForgeDecisionConstraintPreview -RunId $run.runId -IssueId $issueId -Text '  개인정보는   국내에만 저장한다.  ' -ResultsRoot $workspace
        Assert-Equal $preview.normalizedConstraint '개인정보는 국내에만 저장한다.'
        $beforeConstraintCount = @($decisionAudit.records | Where-Object { $_.action -eq 'CONSTRAINT' }).Count
        Assert-Equal $beforeConstraintCount 0
        $constraint = Set-DuoForgeDecisionConstraint -RunId $run.runId -IssueId $issueId -Text '개인정보는 국내에만 저장한다.' -ResultsRoot $workspace -Confirm
        Assert-Equal $constraint.status 'PAUSED_USER'
        $extended = Add-DuoForgeRound -RunId $run.runId -ResultsRoot $workspace
        Assert-Equal $extended.maxRounds 3
        Assert-True ($extended.addedSteps -gt 0)
        $extendedGraph = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'steps.json') | ConvertFrom-Json -Depth 100
        Assert-Equal $extendedGraph.maxRounds 3
        Assert-True (@($extendedGraph.steps | Where-Object { $_.round -eq 3 }).Count -gt 0)
        $resumed = & $module {
            param($directory)
            $callback = { param($step) New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $resumed.status 'COMPLETED' ($resumed | ConvertTo-Json -Depth 20 -Compress)
        $repeatedInvalidation = & $module {
            param($directory)
            $graphPath = Join-Path $directory 'steps.json'
            $before = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $graphPath)
            foreach ($step in @($before.steps | Where-Object { [int]$_.round -eq 3 -and [string]$_.stage -in @('synthesis', 'final-validation') })) {
                $step.history = @([ordered]@{ invalidatedAt = '2026-07-27T00:00:00Z'; reason = 'PREVIOUS_USER_DECISION'; previousArtifactHash = 'test'; preservedPath = 'history/test' })
            }
            Write-DuoForgeJsonAtomic -Path $graphPath -Value $before
            $reset = Reset-DuoForgeDecisionAffectedSteps -RunDirectory $directory -Mode 'shared-document'
            $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $graphPath)
            [ordered]@{
                reset = $reset
                affectedHistories = @($graph.steps | Where-Object { [int]$_.round -eq 3 -and [string]$_.stage -in @('synthesis', 'final-validation') } | ForEach-Object { @($_.history).Count })
            }
        } $run.runDirectory
        Assert-True (@($repeatedInvalidation.affectedHistories | Where-Object { $_ -eq 2 }).Count -eq 2) '반복 무효화 이력이 두 최종 단계에 누적되지 않았습니다.'
    }

    Test-Case '대용량 문맥은 배치와 예상 커버리지를 고정하고 부족하면 부분 완료 동의를 요구한다' {
        $largeText = "# 대용량 문서`n`n" + ('x' * 400000)
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'large-context\input\large.md') -Text $largeText
        $workspace = Join-Path $tempRoot 'large-context-results'
        $config = New-TestConfig -ResultsRoot $workspace
        $config.limits.maxInputBytesPerCall = 131072
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $blocked = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config $config
        Assert-False ([bool]$blocked.valid)
        Assert-Equal @($blocked.errors | Where-Object { $_.code -eq 'DF-PARTIAL-CONSENT-REQUIRED' }).Count 1
        Assert-True ([bool]$blocked.contextPlan.enabled)
        Assert-True ([bool]$blocked.contextPlan.requiresPartialConsent)

        $allowedRequest = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd -AllowPartial $true
        $allowed = Test-DuoForgeStartRequest -Request $allowedRequest -DoctorReport (New-FakeDoctor) -Config $config
        Assert-True ([bool]$allowed.valid) ($allowed.errors | ConvertTo-Json -Depth 20 -Compress)
        Assert-True ($allowed.executionPlan.contextBatchCount -gt 0)
        $run = New-DuoForgeRun -ValidationResult $allowed
        $contextPlan = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'inputs\context-plan.json') | ConvertFrom-Json -Depth 100
        Assert-Equal @($contextPlan.batches).Count $allowed.contextPlan.selectedBatchCount
        Assert-Equal $contextPlan.completionStatus 'COMPLETED_PARTIAL'
        $result = & $module {
            param($directory)
            $callback = { param($step) New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $result.status 'COMPLETED_PARTIAL'
        Assert-True (Test-Path -LiteralPath (Join-Path $run.runDirectory 'final\COVERAGE.md') -PathType Leaf)
        $coverageText = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'final\COVERAGE.md')
        Assert-ContainsText $coverageText '전체 입력에 대한 단정적 결론이 아닙니다.'
    }

    Test-Case '누적 모델 실행 90분 상한은 다음 공급자 호출 전에 실패 폐쇄한다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'runtime-limit\input\brief.md')
        $workspace = Join-Path $tempRoot 'runtime-limit-results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $statePath = Join-Path $run.runDirectory 'state.json'
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 50
        $state.runtimeSeconds = 5400.0
        [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 50), [System.Text.UTF8Encoding]::new($false))
        $control = @{ calls = 0 }
        $result = & $module {
            param($directory, $counter)
            $callback = { param($step) $counter.calls++; New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory $control
        Assert-Equal $result.status 'RESUMABLE_ERROR'
        Assert-Equal $result.code 'DF-RUN-TIME-LIMIT'
        Assert-Equal $control.calls 0
    }

    Test-Case '완료 산출물 손상은 해당 단계와 의존 단계만 감사 보존 후 재실행한다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'artifact-recovery\input\brief.md')
        $workspace = Join-Path $tempRoot 'artifact-recovery-results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $complete = & $module {
            param($directory)
            $callback = { param($step) New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $complete.status 'COMPLETED'
        $graphBefore = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'steps.json') | ConvertFrom-Json -Depth 100
        $damaged = @($graphBefore.steps | Where-Object { $_.stepKey -eq 'r01-codex-independent-draft' })[0]
        $unaffected = @($graphBefore.steps | Where-Object { $_.stepKey -eq 'r01-claude-independent-draft' })[0]
        $unaffectedHash = [string]$unaffected.artifactHash
        [System.IO.File]::WriteAllText([string]$damaged.artifactPath, '{broken-json', [System.Text.UTF8Encoding]::new($false))
        $control = @{ steps = @() }
        $recovered = & $module {
            param($directory, $counter)
            $callback = { param($step) $counter.steps = @($counter.steps) + @([string]$step.stepKey); New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory $control
        Assert-Equal $recovered.status 'COMPLETED'
        Assert-True ('r01-codex-independent-draft' -in @($control.steps))
        Assert-False ('r01-claude-independent-draft' -in @($control.steps))
        $graphAfter = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'steps.json') | ConvertFrom-Json -Depth 100
        Assert-Equal @($graphAfter.steps | Where-Object { $_.stepKey -eq 'r01-claude-independent-draft' })[0].artifactHash $unaffectedHash
        Assert-True ((Get-ChildItem -LiteralPath (Join-Path $run.runDirectory 'history\stages') -File).Count -gt 0)
        $recoveredStep = @($graphAfter.steps | Where-Object { $_.stepKey -eq 'r01-codex-independent-draft' })[0]
        [System.IO.File]::WriteAllText([string]$recoveredStep.artifactPath, '{broken-again', [System.Text.UTF8Encoding]::new($false))
        $secondRecovery = & $module {
            param($directory)
            $callback = { param($step) New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $secondRecovery.status 'COMPLETED'
        $graphAfterSecondRecovery = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'steps.json') | ConvertFrom-Json -Depth 100
        Assert-Equal @(@($graphAfterSecondRecovery.steps | Where-Object { $_.stepKey -eq 'r01-codex-independent-draft' })[0].history).Count 2
        $events = Get-Content -LiteralPath (Join-Path $run.runDirectory 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
        Assert-Equal @($events | Where-Object { $_.type -eq 'COMPLETED_OUTPUT_CORRUPTION_DETECTED' }).Count 2
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
