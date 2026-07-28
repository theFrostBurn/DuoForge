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
        [string]$DocumentA,
        [string]$DocumentB,
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
        $doctor = New-FakeDoctor
        $doctor.readyForProjectAudit = $true
        $config = New-TestConfig -ResultsRoot $workspace
        $config.features.dualProjectAudit = $true
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport $doctor -Config $config
        Assert-False ([bool]$validation.valid)
        Assert-Equal @($validation.errors | Where-Object { $_.code -eq 'DF-PREFLIGHT-3A-ISOLATION' }).Count 1
        Assert-ThrowsCode -ExpectedCode 'DF-RUN-INVALID' -Body { New-DuoForgeRun -ValidationResult $validation }
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

    Test-Case '정규 문서 입력은 공급자와 분리된 A/B 계보로 유지된다' {
        $normalized = & $module {
            Resolve-DuoForgeDocumentInputAliasesInternal -DocumentA '.\A\main.md' -DocumentB '.\B\main.md'
        }
        Assert-Equal $normalized.documentA '.\A\main.md'
        Assert-Equal $normalized.documentB '.\B\main.md'
        Assert-Equal @($normalized.warnings).Count 0
        Assert-False $normalized.Contains('codexDocument')
        Assert-False $normalized.Contains('claudeDocument')
    }

    Test-Case '공개 요청과 계획 API는 네 내부 모드를 수용한다' {
        foreach ($mode in @('shared-document', 'document-merge', 'dual-document', 'dual-project-audit')) {
            $parameters = @{
                Mode = $mode
                CodexModel = 'gpt-5.6-sol'
                CodexReasoningEffort = 'high'
                ClaudeModel = 'opus'
                ClaudeReasoningEffort = 'high'
            }
            if ($mode -eq 'shared-document') { $parameters.Brief = '.\brief.md' }
            elseif ($mode -eq 'dual-project-audit') { $parameters.CodexProject = '.\project-a'; $parameters.ClaudeProject = '.\project-b' }
            else { $parameters.DocumentA = '.\A\main.md'; $parameters.DocumentB = '.\B\main.md' }
            $request = New-DuoForgeStartRequest @parameters
            Assert-Equal $request.mode $mode
            $plan = Get-DuoForgeExecutionPlan -Mode $mode -MaxRounds 2
            Assert-Equal $plan.mode $mode
        }
    }

    Test-Case '새 작업 메뉴는 네 모드를 A/B 용어로 표시하고 모드 4를 실패 폐쇄한다' {
        $surface = & $module {
            [ordered]@{
                options = @(Get-DuoForgeInteractiveNewModeOptionsInternal)
                modeLabels = @(
                    Get-DuoForgeProgressModeLabelInternal -Mode shared-document
                    Get-DuoForgeProgressModeLabelInternal -Mode document-merge
                    Get-DuoForgeProgressModeLabelInternal -Mode dual-document
                    Get-DuoForgeProgressModeLabelInternal -Mode dual-project-audit
                )
                stageLabels = @(
                    Get-DuoForgeProgressStageLabelInternal -Stage independent-merge-draft
                    Get-DuoForgeProgressStageLabelInternal -Stage document-review
                    Get-DuoForgeProgressStageLabelInternal -Stage document-revision
                    Get-DuoForgeProgressStageLabelInternal -Stage document-validation
                )
            }
        }
        Assert-Equal @($surface.options).Count 4
        Assert-Equal ((@($surface.options.key) -join ',')) '1,2,3,4'
        Assert-Equal ((@($surface.options.mode) -join ',')) 'shared-document,document-merge,dual-document,dual-project-audit'
        Assert-Equal (@($surface.options | Where-Object { [bool]$_.enabled }).Count) 3
        Assert-False ([bool]$surface.options[3].enabled)
        Assert-ContainsText ([string]$surface.options[3].disabledReason) 'DF-PREFLIGHT-3A-ISOLATION'
        Assert-Equal ((@($surface.modeLabels) -join ',')) '컨셉으로 공동 문서 만들기,두 문서를 하나로 합의하기,두 문서를 각각 개선하기,두 프로젝트 비교하기(비활성)'
        Assert-Equal ((@($surface.stageLabels) -join ',')) '독립 병합 후보,문서 A/B 검토,대상 문서 개정,대상 문서 최종 검증'

        $interactiveSource = Get-Content -LiteralPath (Join-Path $projectRoot 'src\DuoForge\Private\14.Interactive.ps1') -Raw
        Assert-NotContainsText $interactiveSource "Role 'codex-document'"
        Assert-NotContainsText $interactiveSource "Role 'claude-document'"
        Assert-ContainsText $interactiveSource '-DocumentA $documentA -DocumentB $documentB'
    }

    Test-Case '모드 2와 3의 공개 요청은 정규 A/B 필드만 기록한다' {
        foreach ($mode in @('document-merge', 'dual-document')) {
            $request = New-TestStartRequest -Mode $mode -DocumentA '.\A\main.md' -DocumentB '.\B\main.md'
            Assert-Equal $request.inputs.documentA '.\A\main.md'
            Assert-Equal $request.inputs.documentB '.\B\main.md'
            Assert-False $request.inputs.Contains('codexDocument')
            Assert-False $request.inputs.Contains('claudeDocument')
            Assert-Equal @($request.compatibilityWarnings).Count 0
        }
    }

    Test-Case '공개 레거시 문서 별칭은 정규 요청으로 변환되고 경고한다' {
        $request = New-TestStartRequest -Mode dual-document -CodexDocument '.\A\legacy.md' -ClaudeDocument '.\B\legacy.md'
        Assert-Equal $request.inputs.documentA '.\A\legacy.md'
        Assert-Equal $request.inputs.documentB '.\B\legacy.md'
        Assert-False $request.inputs.Contains('codexDocument')
        Assert-False $request.inputs.Contains('claudeDocument')
        Assert-Equal @($request.compatibilityWarnings).Count 1
        Assert-Equal $request.compatibilityWarnings[0].code 'DF-DEPRECATED-DOCUMENT-ALIASES'
    }

    Test-Case '레거시 문서 별칭은 A/B로만 정규화되고 경로 없는 경고를 남긴다' {
        $normalized = & $module {
            Resolve-DuoForgeDocumentInputAliasesInternal -CodexDocument 'C:\private\A.md' -ClaudeDocument 'D:\private\B.md'
        }
        Assert-Equal $normalized.documentA 'C:\private\A.md'
        Assert-Equal $normalized.documentB 'D:\private\B.md'
        Assert-Equal @($normalized.warnings).Count 1
        Assert-Equal $normalized.warnings[0].code 'DF-DEPRECATED-DOCUMENT-ALIASES'
        $warningJson = $normalized.warnings | ConvertTo-Json -Depth 10 -Compress
        Assert-NotContainsText $warningJson 'C:\private\A.md'
        Assert-NotContainsText $warningJson 'D:\private\B.md'
    }

    Test-Case '정규 문서 입력과 레거시 별칭이 다르면 묵시적 우선순위 없이 차단한다' {
        Assert-ThrowsCode -ExpectedCode 'DF-INPUT-DOCUMENT-ALIAS-CONFLICT' -Body {
            & $module {
                Resolve-DuoForgeDocumentInputAliasesInternal -DocumentA '.\A\new.md' -CodexDocument '.\A\legacy.md'
            }
        }
        Assert-ThrowsCode -ExpectedCode 'DF-INPUT-DOCUMENT-ALIAS-CONFLICT' -Body {
            & $module {
                Resolve-DuoForgeDocumentInputAliasesInternal -DocumentB '.\B\new.md' -ClaudeDocument '.\B\legacy.md'
            }
        }
    }

    Test-Case '워크플로 버전이 없는 실행은 v1이며 명시된 v2만 신규 의미를 사용한다' {
        $versions = & $module {
            [ordered]@{
                legacy = Get-DuoForgeWorkflowVersionInternal -Manifest ([ordered]@{ mode = 'dual-document' })
                explicitLegacy = Get-DuoForgeWorkflowVersionInternal -Manifest ([ordered]@{ workflowVersion = 'workflow-v1' })
                current = Get-DuoForgeWorkflowVersionInternal -Manifest ([ordered]@{ workflowVersion = 'workflow-v2' })
            }
        }
        Assert-Equal $versions.legacy 'workflow-v1'
        Assert-Equal $versions.explicitLegacy 'workflow-v1'
        Assert-Equal $versions.current 'workflow-v2'
        Assert-ThrowsCode -ExpectedCode 'DF-WORKFLOW-VERSION' -Body {
            & $module { Get-DuoForgeWorkflowVersionInternal -Manifest ([ordered]@{ workflowVersion = 'workflow-v3' }) }
        }
    }

    Test-Case '신규 실행 요청은 레거시 워크플로로 낮춰 저장할 수 없다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'workflow-downgrade\input\brief.md')
        $workspace = Join-Path $tempRoot 'workflow-downgrade-results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace
        $request.workflowVersion = 'workflow-v1'
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        Assert-False ([bool]$validation.valid)
        Assert-Equal @($validation.errors | Where-Object { $_.code -eq 'DF-WORKFLOW-NEW-RUN' }).Count 1
        Assert-False (Test-Path -LiteralPath $workspace)
    }

    Test-Case '이미 저장된 레거시 단계 그래프는 초기화 시 재해석하거나 다시 쓰지 않는다' {
        $runDirectory = Join-Path $tempRoot 'legacy-graph'
        [System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null
        $stepsPath = Join-Path $runDirectory 'steps.json'
        $legacyGraph = [ordered]@{
            schemaVersion = 1
            mode = 'dual-document'
            maxRounds = 2
            steps = @(
                [ordered]@{ stepKey = 'r01-codex-owner-response'; provider = 'codex'; round = 1; stage = 'owner-response'; dependsOn = @(); status = 'PENDING' }
                [ordered]@{ stepKey = 'r01-claude-owned-document-revision'; provider = 'claude'; round = 1; stage = 'owned-document-revision'; dependsOn = @('r01-codex-owner-response'); status = 'PENDING' }
            )
        }
        [System.IO.File]::WriteAllText($stepsPath, ($legacyGraph | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
        $before = (Get-FileHash -LiteralPath $stepsPath -Algorithm SHA256).Hash
        $loaded = & $module { param($directory) Initialize-DuoForgeStageGraph -RunDirectory $directory } $runDirectory
        $after = (Get-FileHash -LiteralPath $stepsPath -Algorithm SHA256).Hash
        Assert-Equal $after $before
        Assert-Equal $loaded.steps[0].stage 'owner-response'
        Assert-Equal $loaded.steps[1].stage 'owned-document-revision'
    }

    Test-Case 'workflow-v1과 v2의 dual-document 단계 의미는 명시적으로 분리된다' {
        $graphs = & $module {
            [ordered]@{
                legacy = New-DuoForgeStageGraph -Mode dual-document -MaxRounds 2 -WorkflowVersion workflow-v1
                current = New-DuoForgeStageGraph -Mode dual-document -MaxRounds 2 -WorkflowVersion workflow-v2
            }
        }
        $plans = [ordered]@{
            legacy = Get-DuoForgeExecutionPlan -Mode dual-document -MaxRounds 2 -WorkflowVersion workflow-v1
            current = Get-DuoForgeExecutionPlan -Mode dual-document -MaxRounds 2 -WorkflowVersion workflow-v2
        }
        Assert-True ('owner-response' -in @($graphs.legacy.steps.stage))
        Assert-True ('owned-document-revision' -in @($graphs.legacy.steps.stage))
        Assert-False ('document-review' -in @($graphs.legacy.steps.stage))
        Assert-True ('document-review' -in @($graphs.current.steps.stage))
        Assert-True ('document-revision' -in @($graphs.current.steps.stage))
        Assert-True ('document-validation' -in @($graphs.current.steps.stage))
        Assert-False ('owner-response' -in @($graphs.current.steps.stage))
        $round1A = @($graphs.current.steps | Where-Object { $_.round -eq 1 -and $_.targetDocumentId -eq 'A' -and $_.stage -eq 'document-revision' })[0]
        $round2A = @($graphs.current.steps | Where-Object { $_.round -eq 2 -and $_.targetDocumentId -eq 'A' -and $_.stage -eq 'document-revision' })[0]
        Assert-Equal $round1A.provider 'codex'
        Assert-Equal $round2A.provider 'claude'
        Assert-True ('owner-response' -in @($plans.legacy.providers.codex.calls.stage))
        Assert-False ('document-validation' -in @($plans.legacy.providers.codex.calls.stage))
        Assert-True ('document-review' -in @($plans.current.providers.codex.calls.stage))
        Assert-True ('document-validation' -in @($plans.current.providers.codex.calls.stage))
        Assert-Equal $plans.legacy.workflowVersion 'workflow-v1'
        Assert-Equal $plans.current.workflowVersion 'workflow-v2'
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
        Assert-Equal $validation.inputs.documents.A.context.includedFiles 2
        Assert-Equal $validation.inputs.documents.B.context.includedFiles 2
    }

    Test-Case '모드 2와 3은 같은 A/B 검증 및 경로 경계를 공유한다' {
        foreach ($mode in @('document-merge', 'dual-document')) {
            $sameA = New-MarkdownFile -Path (Join-Path $tempRoot "$mode-same\A.md")
            $sameB = New-MarkdownFile -Path (Join-Path $tempRoot "$mode-same\B.md")
            $sameWorkspace = Join-Path $tempRoot "$mode-same-results"
            $sameRequest = New-TestStartRequest -Mode $mode -DocumentA $sameA -DocumentB $sameB -Workspace $sameWorkspace
            $sameValidation = Test-DuoForgeStartRequest -Request $sameRequest -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $sameWorkspace)
            Assert-False ([bool]$sameValidation.valid)
            Assert-Equal @($sameValidation.errors | Where-Object code -eq 'DF-PATH-DUAL-DOCUMENT-OVERLAP').Count 1

            $a = New-MarkdownFile -Path (Join-Path $tempRoot "$mode-ok\A\main.md")
            $null = New-MarkdownFile -Path (Join-Path $tempRoot "$mode-ok\A\context.md")
            $b = New-MarkdownFile -Path (Join-Path $tempRoot "$mode-ok\B\main.md")
            $null = New-MarkdownFile -Path (Join-Path $tempRoot "$mode-ok\B\context.md")
            $workspace = Join-Path $tempRoot "$mode-ok-results"
            $request = New-TestStartRequest -Mode $mode -DocumentA $a -DocumentB $b -Workspace $workspace
            $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
            Assert-True ([bool]$validation.valid) ($validation.errors | ConvertTo-Json -Depth 10 -Compress)
            Assert-Equal $validation.inputs.documents.A.context.includedFiles 2
            Assert-Equal $validation.inputs.documents.B.context.includedFiles 2
            $sourcePaths = & $module { param($value) @(Get-DuoForgeValidationSourceRecordsInternal -ValidationResult $value | ForEach-Object path) } $validation
            Assert-Equal @($sourcePaths | Sort-Object -Unique).Count @($sourcePaths).Count

            $nestedWorkspace = Join-Path ([System.IO.Path]::GetDirectoryName($a)) 'results'
            $nestedRequest = New-TestStartRequest -Mode $mode -DocumentA $a -DocumentB $b -Workspace $nestedWorkspace
            $nestedValidation = Test-DuoForgeStartRequest -Request $nestedRequest -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $nestedWorkspace)
            Assert-False ([bool]$nestedValidation.valid)
            Assert-Equal @($nestedValidation.errors | Where-Object code -eq 'DF-PATH-OUTPUT-IN-INPUT').Count 1
        }
    }

    Test-Case '신규 A/B 실행은 workflow-v2와 문서 계보 역할만 저장한다' {
        $a = New-MarkdownFile -Path (Join-Path $tempRoot 'v2-run\A\main.md')
        $null = New-MarkdownFile -Path (Join-Path $tempRoot 'v2-run\A\context.md')
        $b = New-MarkdownFile -Path (Join-Path $tempRoot 'v2-run\B\main.md')
        $workspace = Join-Path $tempRoot 'v2-run-results'
        $request = New-TestStartRequest -Mode document-merge -DocumentA $a -DocumentB $b -Workspace $workspace
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        Assert-True ([bool]$validation.valid) ($validation.errors | ConvertTo-Json -Depth 10 -Compress)
        $run = New-DuoForgeRun -ValidationResult $validation
        Assert-Equal $run.manifest.workflowVersion 'workflow-v2'
        Assert-Equal $run.manifest.promptTemplateVersion 'duoforge-stage-v3'
        $inventory = Get-Content -LiteralPath (Join-Path $run.runDirectory 'inputs\inventory.json') -Raw | ConvertFrom-Json -Depth 50
        Assert-True ($null -ne $inventory.roles.documents.A)
        Assert-True ($null -ne $inventory.roles.documents.B)
        Assert-True ($null -eq $inventory.roles.codex)
        Assert-True ($null -eq $inventory.roles.claude)
        $manifestText = Get-Content -LiteralPath (Join-Path $run.runDirectory 'manifest.json') -Raw
        Assert-NotContainsText $manifestText 'codexDocument'
        Assert-NotContainsText $manifestText 'claudeDocument'
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
        Assert-Equal $run.manifest.schemaVersion 3
        Assert-Equal $run.manifest.workflowVersion 'workflow-v2'
        Assert-Equal $run.manifest.promptTemplateVersion 'duoforge-stage-v3'
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

    Test-Case '고정형 진행판은 단계 장벽과 검증된 최근 요약을 터미널 크기 안에 렌더링한다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'progress-frame\input\brief.md')
        $workspace = Join-Path $tempRoot 'progress-frame\results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $engineResult = & $module {
            param($directory)
            $callback = { param($step) New-DuoForgeFakeStageResult -Step $step }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $engineResult.status 'COMPLETED'

        $rendered = & $module {
            param($directory)
            $snapshot = Get-DuoForgeProgressSnapshotInternal -RunDirectory $directory
            $wide = @(New-DuoForgeProgressFrameInternal -Snapshot $snapshot -Width 100 -Height 30 -Now ([datetimeoffset]'2026-07-28T12:00:00+09:00'))
            $finalView = [ordered]@{ finalMessage = '실행 종료 · 완료'; waitForInput = $true }
            $narrow = @(New-DuoForgeProgressFrameInternal -Snapshot $snapshot -Width 72 -Height 20 -Now ([datetimeoffset]'2026-07-28T12:00:00+09:00') -ViewState $finalView)
            $partial = ConvertTo-DuoForgeHashtable -InputObject $snapshot
            $partial.status = 'RUNNING'
            $partial.statusLabel = '실행 중'
            $partial.steps[0].status = 'COMMITTED'
            $partial.steps[1].status = 'STARTED'
            $partial.activeSteps = @($partial.steps[1])
            $partial.barriers = @(Get-DuoForgeProgressBarriersInternal -Steps @($partial.steps))
            $partial.lastEvent = [ordered]@{ type = 'STAGE_RESULT_RECEIVED'; data = [ordered]@{ stepKey = $partial.steps[1].stepKey } }
            $active = @(New-DuoForgeProgressFrameInternal -Snapshot $partial -Width 72 -Height 20 -ViewState ([ordered]@{ providerElapsedSeconds = 4 }))
            $emojiSafe = ConvertTo-DuoForgeProgressTextInternal -Text (('a' * 1199) + '😀후속')
            [ordered]@{
                wide = $wide
                narrow = $narrow
                active = $active
                narrowWidths = @($narrow | ForEach-Object { Get-DuoForgeProgressTextWidthInternal -Text ([string]$_) })
                koreanWidth = Get-DuoForgeProgressTextWidthInternal -Text '한글A'
                safe = ConvertTo-DuoForgeProgressTextInternal -Text ("`e[31m위험`e[0m`n다음")
                emojiSafe = $emojiSafe
                emojiWidth = Get-DuoForgeProgressTextWidthInternal -Text $emojiSafe
            }
        } $run.runDirectory
        Assert-ContainsText ($rendered.wide -join "`n") '장벽 레일'
        Assert-ContainsText ($rendered.wide -join "`n") '최근 확정'
        Assert-ContainsText ($rendered.wide -join "`n") '최종 검증'
        Assert-True ($rendered.narrow.Count -le 19)
        Assert-True (@($rendered.narrowWidths | Where-Object { [int]$_ -gt 71 }).Count -eq 0)
        Assert-ContainsText ($rendered.narrow -join "`n") '실행 종료 · 완료'
        Assert-ContainsText ($rendered.narrow -join "`n") '쟁점 전체'
        Assert-ContainsText ($rendered.narrow -join "`n") 'Enter 키를 누르면'
        Assert-ContainsText ($rendered.active -join "`n") '응답 수신 · 구조 검증 중'
        Assert-ContainsText ($rendered.active -join "`n") '쟁점 원장  전체 단계 확정 후 집계'
        Assert-Equal $rendered.koreanWidth 5
        Assert-Equal $rendered.safe '위험 다음'
        Assert-False ([string]$rendered.safe -like "*`e*")
        Assert-Equal $rendered.emojiSafe.Length 1199
        Assert-Equal $rendered.emojiWidth 1199

        $tampered = & $module {
            param($directory)
            $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path (Join-Path $directory 'steps.json'))
            $finalStep = @($graph.steps | Where-Object { [string]$_.stage -eq 'final-validation' } | Select-Object -Last 1)[0]
            $artifact = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path ([string]$finalStep.artifactPath))
            $artifact.result.summary = '변조된 확정 요약'
            Write-DuoForgeJsonAtomic -Path ([string]$finalStep.artifactPath) -Value $artifact
            $snapshot = Get-DuoForgeProgressSnapshotInternal -RunDirectory $directory
            [ordered]@{ latestSummary = [string]$snapshot.latest.summary; latestStepKey = [string]$snapshot.latest.stepKey; finalStepKey = [string]$finalStep.stepKey }
        } $run.runDirectory
        Assert-NotContainsText $tampered.latestSummary '변조된 확정 요약'
        Assert-True ($tampered.latestStepKey -ne $tampered.finalStepKey)
    }

    Test-Case '진행 이벤트는 검증과 저장 뒤에만 단계 확정을 공개하고 원문을 싣지 않는다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'progress-events\input\brief.md')
        $workspace = Join-Path $tempRoot 'progress-events\results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $events = [System.Collections.Generic.List[object]]::new()
        $documentMarker = 'DOCUMENT-CONTENT-MUST-NOT-ENTER-EVENTS'
        $providerMarker = 'PROVIDER-RAW-MUST-NOT-ENTER-EVENTS'
        $secretMarker = 'SECRET-VALUE-MUST-NOT-ENTER-EVENTS'
        $result = & $module {
            param($directory, $eventList, $documentText, $providerText, $secretText)
            $callback = {
                param($step)
                $fake = New-DuoForgeFakeStageResult -Step $step
                $fake.summary = "$providerText $secretText"
                if ($null -ne $fake.document) { $fake.document = $documentText }
                return $fake
            }
            $observer = { param($event) $eventList.Add($event) }.GetNewClosure()
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback -ProgressObserver $observer
        } $run.runDirectory $events $documentMarker $providerMarker $secretMarker
        Assert-Equal $result.status 'COMPLETED'
        $firstStepEvents = @($events | Where-Object { [string]$_.data.stepKey -eq 'r01-codex-independent-draft' } | ForEach-Object { [string]$_.type })
        Assert-Equal (($firstStepEvents -join ',')) 'STAGE_STARTED,STAGE_RESULT_RECEIVED,STAGE_COMMITTED'
        $committed = @($events | Where-Object { [string]$_.type -eq 'STAGE_COMMITTED' })
        Assert-Equal $committed.Count 13
        Assert-Equal $committed[0].data.workflowVersion 'workflow-v2'
        Assert-Equal $committed[0].data.targetDocumentId 'merged'
        Assert-False $committed[0].data.Contains('summary')
        Assert-False $committed[0].data.Contains('document')
        $observerJson = $events | ConvertTo-Json -Depth 100 -Compress
        Assert-NotContainsText $observerJson $documentMarker
        Assert-NotContainsText $observerJson $providerMarker
        Assert-NotContainsText $observerJson $secretMarker
        $durableEventText = Get-Content -LiteralPath (Join-Path $run.runDirectory 'events.jsonl') -Raw
        Assert-NotContainsText $durableEventText $documentMarker
        Assert-NotContainsText $durableEventText $providerMarker
        Assert-NotContainsText $durableEventText $secretMarker
        $durableEventLines = $durableEventText -split "`r?`n"
        $durableEvents = @($durableEventLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ConvertFrom-Json | Where-Object type -eq 'STAGE_COMMITTED')
        Assert-Equal $durableEvents.Count 13
        Assert-Equal $durableEvents[0].data.workflowVersion 'workflow-v2'
        Assert-Equal $durableEvents[0].data.targetDocumentId 'merged'
    }

    Test-Case '형식 복구 재시도는 실패 응답을 확정 요약으로 표시하지 않는다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'progress-retry\input\brief.md')
        $workspace = Join-Path $tempRoot 'progress-retry\results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $events = [System.Collections.Generic.List[object]]::new()
        $control = @{ failed = $false }
        $result = & $module {
            param($directory, $eventList, $controlState)
            $callback = {
                param($step)
                $key = [string]$step.stepKey
                $fake = New-DuoForgeFakeStageResult -Step $step
                if ($key -eq 'r01-codex-independent-draft' -and -not [bool]$controlState.failed) {
                    $controlState.failed = $true
                    $fake.provider = 'claude'
                }
                return $fake
            }
            $observer = { param($event) $eventList.Add($event) }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback -ProgressObserver $observer
        } $run.runDirectory $events $control
        Assert-Equal $result.status 'COMPLETED'
        $types = @($events | Where-Object { [string]$_.data.stepKey -eq 'r01-codex-independent-draft' } | ForEach-Object { [string]$_.type })
        Assert-Equal (($types -join ',')) 'STAGE_STARTED,STAGE_RESULT_RECEIVED,STAGE_RETRY_SCHEDULED,STAGE_STARTED,STAGE_RESULT_RECEIVED,STAGE_COMMITTED'
        Assert-Equal @($types | Where-Object { $_ -eq 'STAGE_COMMITTED' }).Count 1
    }

    Test-Case '중단된 STARTED 단계는 재개 대상으로 복구되고 진행 관찰자 오류는 실행을 깨뜨리지 않는다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'progress-recovery\input\brief.md')
        $workspace = Join-Path $tempRoot 'progress-recovery\results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        & $module {
            param($directory)
            $graph = Initialize-DuoForgeStageGraph -RunDirectory $directory
            $graph.steps[0].status = 'STARTED'
            $graph.steps[0].attemptCount = 1
            Write-DuoForgeJsonAtomic -Path (Join-Path $directory 'steps.json') -Value $graph
        } $run.runDirectory
        $result = & $module {
            param($directory)
            $callback = { param($step) New-DuoForgeFakeStageResult -Step $step }
            $brokenObserver = { param($event) throw '진행판 렌더러 실패' }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback -ProgressObserver $brokenObserver
        } $run.runDirectory
        Assert-Equal $result.status 'COMPLETED'
        $graph = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'steps.json') | ConvertFrom-Json -Depth 100
        Assert-Equal $graph.steps[0].attemptCount 2
        $recoveryEvents = @(Get-Content -LiteralPath (Join-Path $run.runDirectory 'events.jsonl') | ConvertFrom-Json | Where-Object type -eq 'STAGE_INTERRUPTED_RECOVERED')
        Assert-Equal $recoveryEvents.Count 1
    }

    Test-Case '두 번째 호출 중 중단된 단계는 재시도 상한을 넘겨 공급자를 호출하지 않는다' {
        $input = New-MarkdownFile -Path (Join-Path $tempRoot 'progress-recovery-exhausted\input\brief.md')
        $workspace = Join-Path $tempRoot 'progress-recovery-exhausted\results'
        $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        & $module {
            param($directory)
            $graph = Initialize-DuoForgeStageGraph -RunDirectory $directory
            $graph.steps[0].status = 'STARTED'
            $graph.steps[0].attemptCount = 2
            Write-DuoForgeJsonAtomic -Path (Join-Path $directory 'steps.json') -Value $graph
        } $run.runDirectory
        $calls = @{ count = 0 }
        $result = & $module {
            param($directory, $control)
            $callback = { param($step) $control.count++; New-DuoForgeFakeStageResult -Step $step }.GetNewClosure()
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory $calls
        Assert-Equal $result.status 'RESUMABLE_ERROR'
        Assert-Equal $result.code 'DF-STAGE-RETRY-EXHAUSTED'
        Assert-Equal $result.invoked 0
        Assert-Equal $calls.count 0
        $graph = Get-Content -Raw -LiteralPath (Join-Path $run.runDirectory 'steps.json') | ConvertFrom-Json -Depth 100
        Assert-Equal $graph.steps[0].attemptCount 2
        Assert-Equal $graph.steps[0].retryMode 'RETRY_EXHAUSTED'
    }

    Test-Case '공급자 프로세스 대기는 진행판 heartbeat를 초 단위로 전달한다' {
        $ticks = [System.Collections.Generic.List[int]]::new()
        $processResult = & $module {
            param($tickList)
            $onTick = { param($elapsed) $tickList.Add([int][Math]::Floor($elapsed.TotalSeconds)) }.GetNewClosure()
            Invoke-DuoForgeProcess -CommandName 'pwsh.exe' -Arguments @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Milliseconds 1200') -TimeoutSeconds 5 -OnTick $onTick
        } $ticks
        Assert-Equal $processResult.exitCode 0
        Assert-True ($ticks.Count -ge 2)
        Assert-Equal $ticks[0] 0
        Assert-True (1 -in @($ticks))
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
        $dualRequest = New-TestStartRequest -Mode dual-document -DocumentA $codexDocument -DocumentB $claudeDocument -Workspace $dualWorkspace -DocumentType prd
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
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r01-codex-document-review']) -join ',')) ''
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r01-claude-document-review']) -join ',')) ''
        $dualReviews = 'r01-codex-document-review,r01-claude-document-review'
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r01-codex-review-response']) -join ',')) $dualReviews
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r01-claude-review-response']) -join ',')) $dualReviews
        $dualResponses = "$dualReviews,r01-codex-review-response,r01-claude-review-response"
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r01-codex-document-a-revision']) -join ',')) $dualResponses
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r01-claude-document-b-revision']) -join ',')) $dualResponses
        $dualRound2Codex = @(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r02-codex-document-review'])
        $dualRound2Claude = @(Get-TestPromptPriorArtifactStepKeys -PromptText $dualPrompts['r02-claude-document-review'])
        Assert-Equal (($dualRound2Codex -join ',')) (($dualRound2Claude -join ','))
        Assert-False ('r02-claude-document-review' -in $dualRound2Codex)
        Assert-False ('r02-codex-document-review' -in $dualRound2Claude)
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

    Test-Case 'workflow-v2 단계 결과는 작업자와 대상 문서 및 출처 배열을 엄격히 검증한다' {
        $step = [ordered]@{
            stepKey = 'r01-codex-document-a-revision'
            provider = 'codex'
            performedBy = 'codex'
            targetDocumentId = 'A'
            sourceDocumentIds = @('A', 'B')
            stage = 'document-revision'
            round = 1
        }
        $valid = & $module {
            param($s)
            $result = New-DuoForgeFakeStageResult -Step $s
            Test-DuoForgeStageResultInternal -Result $result -ExpectedStage $s.stage -ExpectedProvider $s.provider -WorkflowVersion workflow-v2 -ExpectedTargetDocumentId A -ExpectedSourceDocumentIds $s.sourceDocumentIds
        } $step
        Assert-True ([bool]$valid.valid)

        Assert-ThrowsCode -ExpectedCode 'DF-STAGE-SCHEMA' -Body {
            & $module {
                param($s)
                $result = New-DuoForgeFakeStageResult -Step $s
                $result.performedBy = 'claude'
                Test-DuoForgeStageResultInternal -Result $result -ExpectedStage $s.stage -ExpectedProvider $s.provider -WorkflowVersion workflow-v2 -ExpectedTargetDocumentId A -ExpectedSourceDocumentIds $s.sourceDocumentIds -ThrowOnError
            } $step
        }
        Assert-ThrowsCode -ExpectedCode 'DF-STAGE-SCHEMA' -Body {
            & $module {
                param($s)
                $result = New-DuoForgeFakeStageResult -Step $s
                $result.targetDocumentId = 'B'
                Test-DuoForgeStageResultInternal -Result $result -ExpectedStage $s.stage -ExpectedProvider $s.provider -WorkflowVersion workflow-v2 -ExpectedTargetDocumentId A -ExpectedSourceDocumentIds $s.sourceDocumentIds -ThrowOnError
            } $step
        }
        Assert-ThrowsCode -ExpectedCode 'DF-STAGE-SCHEMA' -Body {
            & $module {
                param($s)
                $result = New-DuoForgeFakeStageResult -Step $s
                $result.sourceDocumentIds = 'A'
                Test-DuoForgeStageResultInternal -Result $result -ExpectedStage $s.stage -ExpectedProvider $s.provider -WorkflowVersion workflow-v2 -ExpectedTargetDocumentId A -ExpectedSourceDocumentIds $s.sourceDocumentIds -ThrowOnError
            } $step
        }
        Assert-ThrowsCode -ExpectedCode 'DF-STAGE-SCHEMA' -Body {
            & $module {
                param($s)
                $result = New-DuoForgeFakeStageResult -Step $s
                $result.sourceDocumentIds = @('A')
                Test-DuoForgeStageResultInternal -Result $result -ExpectedStage $s.stage -ExpectedProvider $s.provider -WorkflowVersion workflow-v2 -ExpectedTargetDocumentId A -ExpectedSourceDocumentIds $s.sourceDocumentIds -ThrowOnError
            } $step
        }
    }

    Test-Case '문서별 최종 검증 거부는 대상 계보의 Critical 쟁점으로 실패 폐쇄한다' {
        $merged = & $module {
            $step = [ordered]@{
                stepKey = 'r02-claude-document-a-validation'; provider = 'claude'; performedBy = 'claude'
                targetDocumentId = 'A'; sourceDocumentIds = @('A'); stage = 'document-validation'; round = 2
            }
            $result = New-DuoForgeFakeStageResult -Step $step
            $result.finalApproved = $false
            Merge-DuoForgeStageIssues -StageResults @([ordered]@{
                stepKey = $step.stepKey; provider = $step.provider; performedBy = $step.performedBy
                targetDocumentId = $step.targetDocumentId; sourceDocumentIds = $step.sourceDocumentIds
                stage = $step.stage; round = $step.round; result = $result
            }) -WorkflowVersion workflow-v2
        }
        Assert-Equal @($merged.issues).Count 1
        Assert-Equal $merged.issues[0].severity 'critical'
        Assert-Equal $merged.issues[0].targetDocumentId 'A'
        Assert-True ($null -eq $merged.issues[0].PSObject.Properties['target'])
        Assert-False ([bool](Test-DuoForgeCompletionAllowed -Issues @($merged.issues)).allowed)
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
        $stageSchemaV2 = Get-Content -LiteralPath (Join-Path $projectRoot 'schemas\stage-result-v2.schema.json') -Raw | ConvertFrom-Json -Depth 100
        $explanationSchema = Get-Content -LiteralPath (Join-Path $projectRoot 'schemas\explanation-result.schema.json') -Raw | ConvertFrom-Json -Depth 100
        Assert-Equal $stageSchema.properties.schemaVersion.type 'integer'
        Assert-Equal $stageSchema.properties.schemaVersion.const 1
        Assert-False ('independent-merge-draft' -in @($stageSchema.properties.stage.enum))
        Assert-False ('document-review' -in @($stageSchema.properties.stage.enum))
        Assert-Equal $stageSchemaV2.properties.schemaVersion.type 'integer'
        Assert-Equal $stageSchemaV2.properties.schemaVersion.const 2
        Assert-True ('independent-merge-draft' -in @($stageSchemaV2.properties.stage.enum))
        Assert-True ('document-review' -in @($stageSchemaV2.properties.stage.enum))
        foreach ($requiredName in @('performedBy', 'targetDocumentId', 'sourceDocumentIds')) {
            Assert-True ($requiredName -in @($stageSchemaV2.required))
        }
        Assert-True ($null -eq $stageSchemaV2.properties.sourceDocumentIds.PSObject.Properties['uniqueItems'])
        Assert-True ('targetDocumentId' -in @($stageSchemaV2.properties.issues.items.required))
        Assert-False ('target' -in @($stageSchemaV2.properties.issues.items.required))
        foreach ($requiredName in @('sourceDocumentId', 'proposedByProvider', 'path', 'location', 'excerptHash')) {
            Assert-True ($requiredName -in @($stageSchemaV2.properties.issues.items.properties.evidence.items.required))
        }
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

    Test-Case '문서 병합 모드는 같은 A/B에서 독립 후보를 만들고 합의 문서와 출처 추적표를 만든다' {
        $a = New-MarkdownFile -Path (Join-Path $tempRoot 'merge-e2e\A\source.md') -Text '# 문서 A'
        $b = New-MarkdownFile -Path (Join-Path $tempRoot 'merge-e2e\B\source.md') -Text '# 문서 B'
        $beforeA = (Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash
        $beforeB = (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash
        $workspace = Join-Path $tempRoot 'merge-e2e-results'
        $request = New-TestStartRequest -Mode document-merge -DocumentA $a -DocumentB $b -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $prompts = @{}
        $result = & $module {
            param($directory, $promptMap)
            $callback = {
                param($step, $prompt)
                $promptMap[[string]$step.stepKey] = [string]$prompt.text
                $stageResult = New-DuoForgeFakeStageResult -Step $step
                if ([string]$step.stepKey -eq 'r01-codex-cross-review') {
                    $stageResult.issues = @([ordered]@{
                        issueKey = 'MERGE-R01-001'; targetDocumentId = 'merged'; category = 'coverage'; severity = 'minor'
                        claim = '문서 A의 안전 조건을 합의 문서에 반영해야 합니다.'; evidence = @(); proposal = '안전 조건을 합의 문서에 포함하세요.'
                        requiresUser = $false; blockingProposal = $false
                    })
                }
                if ([string]$step.stepKey -eq 'r01-codex-synthesis') {
                    $stageResult.adoptions = @([ordered]@{
                        issueKey = 'MERGE-R01-001'; sourceDocumentId = 'A'; proposedByProvider = 'codex'; targetDocumentId = 'merged'
                        disposition = 'ACCEPTED'; rationale = '안전 조건을 합의 문서에 채택했습니다.'; locations = @('안전 경계')
                    })
                }
                return $stageResult
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory $prompts
        Assert-Equal $result.status 'COMPLETED'
        $drafts = 'r01-codex-independent-merge-draft,r01-claude-independent-merge-draft'
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $prompts['r01-codex-independent-merge-draft']) -join ',')) ''
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $prompts['r01-claude-independent-merge-draft']) -join ',')) ''
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $prompts['r01-codex-cross-review']) -join ',')) $drafts
        Assert-Equal ((@(Get-TestPromptPriorArtifactStepKeys -PromptText $prompts['r01-claude-cross-review']) -join ',')) $drafts
        foreach ($name in @('PRD.md', 'source-trace.md', 'DEBATE_SUMMARY.md', 'DECISIONS.md', 'OPEN_QUESTIONS.md')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $run.runDirectory "final\$name") -PathType Leaf)
        }
        $trace = Get-Content -LiteralPath (Join-Path $run.runDirectory 'final\source-trace.md') -Raw
        Assert-ContainsText $trace '| 쟁점 | 원천 문서 | 제안 작업자 | 대상 문서 | 채택 상태 | 이유 | 반영 위치 | 라운드 |'
        Assert-ContainsText $trace '| D-001 | A | codex | merged | ACCEPTED | 안전 조건을 합의 문서에 채택했습니다. | 안전 경계 | 1 |'
        $mergeLedger = Get-Content -LiteralPath (Join-Path $run.runDirectory 'issues.json') -Raw | ConvertFrom-Json -Depth 50
        Assert-Equal $mergeLedger.issues[0].targetDocumentId 'merged'
        Assert-True ($null -eq $mergeLedger.issues[0].PSObject.Properties['target'])
        Assert-Equal $mergeLedger.issues[0].resolutionStatus 'RESOLVED'
        Assert-Equal (Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash $beforeA
        Assert-Equal (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash $beforeB
    }

    Test-Case '독립 문서 모드는 양쪽 원본을 보존하고 최종 비교 산출물을 만든다' {
        $documentA = New-MarkdownFile -Path (Join-Path $tempRoot 'dual-e2e\A\main.md') -Text '# 문서 A 원본'
        $documentB = New-MarkdownFile -Path (Join-Path $tempRoot 'dual-e2e\B\main.md') -Text '# 문서 B 원본'
        $beforeA = (Get-FileHash -LiteralPath $documentA -Algorithm SHA256).Hash
        $beforeB = (Get-FileHash -LiteralPath $documentB -Algorithm SHA256).Hash
        $workspace = Join-Path $tempRoot 'dual-e2e-results'
        $request = New-TestStartRequest -Mode dual-document -DocumentA $documentA -DocumentB $documentB -Workspace $workspace -DocumentType prd
        $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
        $run = New-DuoForgeRun -ValidationResult $validation
        $result = & $module {
            param($directory)
            $callback = {
                param($step)
                $stageResult = New-DuoForgeFakeStageResult -Step $step
                if ([string]$step.stepKey -eq 'r01-codex-document-review') {
                    $stageResult.issues = @([ordered]@{
                        issueKey = 'DUAL-R01-001'; targetDocumentId = 'A'; category = 'clarity'; severity = 'minor'
                        claim = '문서 B의 용어 정의를 문서 A에 선택적으로 반영할 수 있습니다.'; evidence = @(); proposal = '용어 정의를 반영하세요.'
                        requiresUser = $false; blockingProposal = $false
                    })
                }
                if ([string]$step.stepKey -eq 'r01-codex-document-a-revision') {
                    $stageResult.adoptions = @([ordered]@{
                        issueKey = 'DUAL-R01-001'; sourceDocumentId = 'B'; proposedByProvider = 'claude'; targetDocumentId = 'A'
                        disposition = 'PARTIALLY_ACCEPTED'; rationale = '문서 A의 목적에 맞는 정의만 반영했습니다.'; locations = @('용어 정의')
                    })
                }
                return $stageResult
            }
            Invoke-DuoForgeStageEngine -RunDirectory $directory -ProviderInvoker $callback
        } $run.runDirectory
        Assert-Equal $result.status 'COMPLETED'
        foreach ($name in @('document-A-final.md', 'document-B-final.md', 'comparison.md', 'adoption-log.md', 'OPEN_QUESTIONS.md')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $run.runDirectory "final\$name") -PathType Leaf)
        }
        $adoptionLog = Get-Content -LiteralPath (Join-Path $run.runDirectory 'final\adoption-log.md') -Raw
        Assert-ContainsText $adoptionLog '| 쟁점 | 원천 문서 | 제안 작업자 | 편집 작업자 | 대상 문서 | 채택 상태 | 이유 | 반영 위치 | 라운드 |'
        Assert-ContainsText $adoptionLog '| D-001 | B | claude | codex | A | PARTIALLY_ACCEPTED | 문서 A의 목적에 맞는 정의만 반영했습니다. | 용어 정의 | 1 |'
        Assert-Equal (Get-FileHash -LiteralPath $documentA -Algorithm SHA256).Hash $beforeA
        Assert-Equal (Get-FileHash -LiteralPath $documentB -Algorithm SHA256).Hash $beforeB
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
                        targetDocumentId = 'merged'
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
                        targetDocumentId = 'merged'
                        category = 'core-requirement'
                        severity = 'critical'
                        claim = '데이터 보존 정책을 사용자가 결정해야 합니다.'
                        evidence = @([ordered]@{ sourceDocumentId = 'brief'; proposedByProvider = 'codex'; path = 'S000001.md'; location = '본문'; excerptHash = 'sha256:test' })
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
        $minorMerge = & $module {
            $minorIssue = [ordered]@{
                issueKey = 'MINOR-EVIDENCE-001'; targetDocumentId = 'merged'; category = 'preference'; severity = 'minor'
                claim = '선호 근거가 더 필요합니다.'; evidence = @(); proposal = '선호 근거를 추가하세요.'
                requiresUser = $false; blockingProposal = $false
            }
            $question = [ordered]@{
                issueKey = 'MINOR-EVIDENCE-001'; title = '선호 확인'; question = '선호를 확인할까요?'
                options = @('A', 'B'); recommendedOption = 'A'
            }
            $response = [ordered]@{
                issueKey = 'MINOR-EVIDENCE-001'; disposition = 'NEEDS_EVIDENCE'
                rationale = '현재 근거로는 선호를 확정할 수 없습니다.'; locations = @()
            }
            $records = @(
                [ordered]@{
                    stepKey = 'minor-question'; provider = 'codex'; round = 1; stage = 'document-review'
                    result = [ordered]@{ issues = @($minorIssue); issueResponses = @(); adoptions = @(); openQuestions = @($question) }
                },
                [ordered]@{
                    stepKey = 'minor-evidence'; provider = 'claude'; round = 1; stage = 'review-response'
                    result = [ordered]@{ issues = @(); issueResponses = @($response); adoptions = @(); openQuestions = @() }
                }
            )
            $merged = Merge-DuoForgeStageIssues -StageResults $records -WorkflowVersion workflow-v2
            $completion = Test-DuoForgeCompletionAllowedInternal -Issues @($merged.issues)
            return [ordered]@{ merged = $merged; completion = $completion }
        }
        $minorIssue = @($minorMerge.merged.issues)[0]
        Assert-Equal $minorIssue.resolutionStatus 'AWAITING_EVIDENCE'
        Assert-False ([bool]$minorIssue.blocking)
        Assert-Equal $minorMerge.completion.status 'COMPLETED'

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
                        targetDocumentId = 'merged'
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
                    $result.issues = @([ordered]@{ issueKey = 'CHANGE-R02-001'; targetDocumentId = 'merged'; category = 'preference'; severity = 'major'; claim = '배포 전략 선택이 필요합니다.'; evidence = @(); proposal = '점진 배포를 선택하세요.'; requiresUser = $true; blockingProposal = $true })
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
