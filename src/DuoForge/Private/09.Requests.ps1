function Resolve-DuoForgeDocumentInputAliasesInternal {
    [CmdletBinding()]
    param(
        [string]$DocumentA,
        [string]$DocumentB,
        [string]$CodexDocument,
        [string]$ClaudeDocument
    )

    $hasDocumentA = -not [string]::IsNullOrWhiteSpace($DocumentA)
    $hasDocumentB = -not [string]::IsNullOrWhiteSpace($DocumentB)
    $hasLegacyA = -not [string]::IsNullOrWhiteSpace($CodexDocument)
    $hasLegacyB = -not [string]::IsNullOrWhiteSpace($ClaudeDocument)

    if ($hasDocumentA -and $hasLegacyA -and -not [string]::Equals($DocumentA, $CodexDocument, [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-DuoForgeException -Code 'DF-INPUT-DOCUMENT-ALIAS-CONFLICT' -Message '문서 A의 정규 입력과 레거시 --codex 입력이 서로 다릅니다.')
    }
    if ($hasDocumentB -and $hasLegacyB -and -not [string]::Equals($DocumentB, $ClaudeDocument, [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-DuoForgeException -Code 'DF-INPUT-DOCUMENT-ALIAS-CONFLICT' -Message '문서 B의 정규 입력과 레거시 --claude 입력이 서로 다릅니다.')
    }

    $warnings = [System.Collections.Generic.List[object]]::new()
    if ($hasLegacyA -or $hasLegacyB) {
        $warnings.Add([ordered]@{
            code = 'DF-DEPRECATED-DOCUMENT-ALIASES'
            message = '--codex와 --claude 문서 옵션은 사용 중단 예정입니다. --document-a와 --document-b를 사용해 주세요.'
        })
    }

    return [ordered]@{
        documentA = if ($hasDocumentA) { $DocumentA } else { $CodexDocument }
        documentB = if ($hasDocumentB) { $DocumentB } else { $ClaudeDocument }
        warnings = @($warnings)
    }
}

function New-DuoForgeStartRequestInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('shared-document', 'document-merge', 'dual-document', 'dual-project-audit')]
        [string]$Mode,

        [string]$Brief,
        [string]$DocumentA,
        [string]$DocumentB,
        [string]$CodexDocument,
        [string]$ClaudeDocument,
        [string]$CodexProject,
        [string]$ClaudeProject,
        [string]$Requirements,
        [string]$CodexModel,
        [string]$CodexReasoningEffort,
        [string]$ClaudeModel,
        [string]$ClaudeReasoningEffort,
        [ValidateSet('prd', 'architecture', 'implementation-plan', 'adr', 'custom')]
        [string]$DocumentType = 'custom',
        [ValidateRange(2, 3)]
        [int]$MaxRounds = 2,
        [string]$Workspace,
        [ValidateSet('alternate', 'codex', 'claude')]
        [string]$FirstSynthesizer = 'alternate',
        [bool]$PauseAfterRound = $false,
        [bool]$AllowPartial = $false,
        [string]$Name
    )

    $documentInputs = Resolve-DuoForgeDocumentInputAliasesInternal `
        -DocumentA $DocumentA `
        -DocumentB $DocumentB `
        -CodexDocument $CodexDocument `
        -ClaudeDocument $ClaudeDocument

    return [ordered]@{
        schemaVersion = 2
        workflowVersion = 'workflow-v2'
        mode = $Mode
        name = $Name
        documentType = $DocumentType
        maxRounds = $MaxRounds
        firstSynthesizer = $FirstSynthesizer
        pauseAfterRound = $PauseAfterRound
        allowPartial = $AllowPartial
        workspace = $Workspace
        compatibilityWarnings = @($documentInputs.warnings)
        providerSelections = [ordered]@{
            codex = [ordered]@{
                model = ([string]$CodexModel).Trim()
                reasoningEffort = ([string]$CodexReasoningEffort).Trim()
            }
            claude = [ordered]@{
                model = ([string]$ClaudeModel).Trim()
                reasoningEffort = ([string]$ClaudeReasoningEffort).Trim()
            }
        }
        inputs = [ordered]@{
            brief = $Brief
            documentA = [string]$documentInputs.documentA
            documentB = [string]$documentInputs.documentB
            codexProject = $CodexProject
            claudeProject = $ClaudeProject
            requirements = $Requirements
        }
    }
}
function Get-DuoForgeExceptionCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Exception]$Exception
    )

    if ($Exception.Data.Contains('DuoForgeCode')) {
        return [string]$Exception.Data['DuoForgeCode']
    }
    if ($Exception.Message -match '^\[([^\]]+)\]') {
        return $Matches[1]
    }
    return 'DF-VALIDATION'
}

function Test-DuoForgeStartRequestInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Request,

        [System.Collections.IDictionary]$DoctorReport,

        [System.Collections.IDictionary]$Config
    )

    if ($null -eq $Config) { $Config = Get-DuoForgeConfig }
    if ($null -eq $DoctorReport) { $DoctorReport = Invoke-DuoForgeDoctorInternal }

    $errors = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[object]]::new()
    $inputs = [ordered]@{}
    $mode = [string]$Request.mode
    $requestWorkflowVersion = [string](Get-DuoForgeObjectValue -Object $Request -Name 'workflowVersion' -Default '')
    $resultsRoot = if ([string]::IsNullOrWhiteSpace([string]$Request.workspace)) { [string]$Config.resultsRoot } else { [string]$Request.workspace }

    if ($requestWorkflowVersion -ne 'workflow-v2') {
        $errors.Add([ordered]@{ code = 'DF-WORKFLOW-NEW-RUN'; message = '신규 실행 요청은 workflow-v2 계약으로만 만들 수 있습니다.' })
    }

    foreach ($warning in @(Get-DuoForgeObjectValue -Object $Request -Name 'compatibilityWarnings' -Default @())) {
        $warnings.Add((ConvertTo-DuoForgeHashtable -InputObject $warning))
    }

    try {
        $resultsRoot = Resolve-DuoForgePathInternal -Path $resultsRoot -ExpectedType Directory -AllowMissing
    }
    catch {
        $errors.Add([ordered]@{ code = Get-DuoForgeExceptionCode -Exception $_.Exception; message = $_.Exception.Message })
    }

    if ([int]$Request.maxRounds -notin @(2, 3)) {
        $errors.Add([ordered]@{ code = 'DF-ROUNDS'; message = '라운드는 2 또는 3이어야 합니다.' })
    }

    $selectionValidation = Test-DuoForgeProviderSelectionsInternal -Selections (Get-DuoForgeObjectValue -Object $Request -Name 'providerSelections')
    foreach ($selectionError in @($selectionValidation.errors)) {
        $errors.Add($selectionError)
    }

    if ($mode -eq 'shared-document') {
        try {
            if ([string]::IsNullOrWhiteSpace([string]$Request.inputs.brief)) {
                throw (New-DuoForgeException -Code 'DF-INPUT-BRIEF-REQUIRED' -Message '공동 문서 모드에는 --brief Markdown 파일이 필요합니다.')
            }
            $primary = Assert-DuoForgeMarkdownFile -Path ([string]$Request.inputs.brief) -MaximumBytes ([long]$Config.limits.documentBytes)
            $inputs['primary'] = $primary
            if ($errors.Count -eq 0) {
                Assert-DuoForgeOutputBoundary -ResultsRoot $resultsRoot -InputBoundaries @([System.IO.Path]::GetDirectoryName($primary.path))
            }
        }
        catch {
            $errors.Add([ordered]@{ code = Get-DuoForgeExceptionCode -Exception $_.Exception; message = $_.Exception.Message })
        }
    }
    elseif ($mode -in @('document-merge', 'dual-document')) {
        try {
            if ([string]::IsNullOrWhiteSpace([string]$Request.inputs.documentA) -or [string]::IsNullOrWhiteSpace([string]$Request.inputs.documentB)) {
                throw (New-DuoForgeException -Code 'DF-INPUT-DUAL-REQUIRED' -Message '문서 모드에는 --document-a와 --document-b Markdown 파일이 모두 필요합니다.')
            }
            $documentAPrimary = Assert-DuoForgeMarkdownFile -Path ([string]$Request.inputs.documentA) -MaximumBytes ([long]$Config.limits.documentBytes)
            $documentBPrimary = Assert-DuoForgeMarkdownFile -Path ([string]$Request.inputs.documentB) -MaximumBytes ([long]$Config.limits.documentBytes)
            $documentAParent = [System.IO.Path]::GetDirectoryName($documentAPrimary.path)
            $documentBParent = [System.IO.Path]::GetDirectoryName($documentBPrimary.path)
            Assert-DuoForgeDisjointPaths -PathA $documentAParent -PathB $documentBParent -Code 'DF-PATH-DUAL-DOCUMENT-OVERLAP' -LabelA '문서 A 폴더' -LabelB '문서 B 폴더'
            if ($errors.Count -eq 0) {
                Assert-DuoForgeOutputBoundary -ResultsRoot $resultsRoot -InputBoundaries @($documentAParent, $documentBParent)
            }
            $inputs['documents'] = [ordered]@{
                A = [ordered]@{
                    primary = $documentAPrimary
                    context = Get-DuoForgeMarkdownInventoryInternal -Directory $documentAParent -MaximumFileBytes ([long]$Config.limits.documentBytes)
                }
                B = [ordered]@{
                    primary = $documentBPrimary
                    context = Get-DuoForgeMarkdownInventoryInternal -Directory $documentBParent -MaximumFileBytes ([long]$Config.limits.documentBytes)
                }
            }
        }
        catch {
            $errors.Add([ordered]@{ code = Get-DuoForgeExceptionCode -Exception $_.Exception; message = $_.Exception.Message })
        }
    }
    elseif ($mode -eq 'dual-project-audit') {
        $errors.Add([ordered]@{
            code = 'DF-PREFLIGHT-3A-ISOLATION'
            message = '3A는 현재 Windows 격리 후보가 범위 밖 읽기와 자식 프로세스 차단에 실패하여 이 빌드에서 비활성화되어 있습니다.'
        })
    }
    else {
        $errors.Add([ordered]@{ code = 'DF-MODE'; message = "지원하지 않는 모드입니다: $mode" })
    }

    $authenticationGate = Get-DuoForgeAuthenticationGateInternal -Report $DoctorReport
    if (-not [bool]$authenticationGate.modelCallsAllowed -and $mode -in @('shared-document', 'document-merge', 'dual-document')) {
        $errors.Add([ordered]@{
            code = [string]$authenticationGate.blockCode
            message = '두 공급자의 구독 인증과 안전 실행 프로필이 모두 준비되지 않았습니다. duoforge doctor 결과를 확인해 주세요.'
        })
    }

    $plan = $null
    $contextPlan = $null
    try {
        $basePlan = Get-DuoForgeExecutionPlanInternal -Mode $mode -MaxRounds ([int]$Request.maxRounds) -FirstSynthesizer ([string]$Request.firstSynthesizer) -MaxCallsPerProvider ([int]$Config.limits.maxCallsPerProviderPerRun) -WorkflowVersion 'workflow-v2'
        $partialValidation = [ordered]@{ request = $Request; inputs = $inputs }
        $contextPlan = New-DuoForgeContextBatchPlanInternal -ValidationResult $partialValidation -Config $Config -BaseExecutionPlan $basePlan
        $plan = Get-DuoForgeExecutionPlanInternal -Mode $mode -MaxRounds ([int]$Request.maxRounds) -FirstSynthesizer ([string]$Request.firstSynthesizer) -MaxCallsPerProvider ([int]$Config.limits.maxCallsPerProviderPerRun) -ContextBatchCount ([int]$contextPlan.selectedBatchCount) -WorkflowVersion 'workflow-v2'
        if (-not $plan.withinLimits) {
            $errors.Add([ordered]@{ code = 'DF-PLAN-CALL-LIMIT'; message = '최악 호출 계획이 공급자별 강제 호출 상한을 초과합니다.' })
        }
        if ([bool]$contextPlan.requiresPartialConsent -and -not [bool](Get-DuoForgeObjectValue -Object $Request -Name 'allowPartial' -Default $false)) {
            $errors.Add([ordered]@{ code = 'DF-PARTIAL-CONSENT-REQUIRED'; message = "예상 문맥 커버리지는 파일 $($contextPlan.predictedFileCoveragePercent)%, 바이트 $($contextPlan.predictedByteCoveragePercent)%입니다. 범위를 줄이거나 --allow-partial로 부분 분석에 명시적으로 동의해 주세요." })
        }
    }
    catch {
        $errors.Add([ordered]@{ code = 'DF-PLAN'; message = $_.Exception.Message })
    }

    return [ordered]@{
        schemaVersion = 1
        valid = $errors.Count -eq 0
        checkedAt = Get-DuoForgeUtcNow
        request = $Request
        resultsRoot = $resultsRoot
        inputs = $inputs
        executionPlan = $plan
        contextPlan = $contextPlan
        doctor = $DoctorReport
        authenticationGate = $authenticationGate
        errors = @($errors)
        warnings = @($warnings)
    }
}
