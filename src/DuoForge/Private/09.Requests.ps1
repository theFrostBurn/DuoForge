function New-DuoForgeStartRequestInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('shared-document', 'dual-document', 'dual-project-audit')]
        [string]$Mode,

        [string]$Brief,
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
        [string]$Name
    )

    return [ordered]@{
        mode = $Mode
        name = $Name
        documentType = $DocumentType
        maxRounds = $MaxRounds
        firstSynthesizer = $FirstSynthesizer
        workspace = $Workspace
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
            codexDocument = $CodexDocument
            claudeDocument = $ClaudeDocument
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
    $resultsRoot = if ([string]::IsNullOrWhiteSpace([string]$Request.workspace)) { [string]$Config.resultsRoot } else { [string]$Request.workspace }

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
    elseif ($mode -eq 'dual-document') {
        try {
            if ([string]::IsNullOrWhiteSpace([string]$Request.inputs.codexDocument) -or [string]::IsNullOrWhiteSpace([string]$Request.inputs.claudeDocument)) {
                throw (New-DuoForgeException -Code 'DF-INPUT-DUAL-REQUIRED' -Message '독립 문서 모드에는 --codex와 --claude Markdown 파일이 모두 필요합니다.')
            }
            $codexPrimary = Assert-DuoForgeMarkdownFile -Path ([string]$Request.inputs.codexDocument) -MaximumBytes ([long]$Config.limits.documentBytes)
            $claudePrimary = Assert-DuoForgeMarkdownFile -Path ([string]$Request.inputs.claudeDocument) -MaximumBytes ([long]$Config.limits.documentBytes)
            $codexParent = [System.IO.Path]::GetDirectoryName($codexPrimary.path)
            $claudeParent = [System.IO.Path]::GetDirectoryName($claudePrimary.path)
            Assert-DuoForgeDisjointPaths -PathA $codexParent -PathB $claudeParent -Code 'DF-PATH-DUAL-DOCUMENT-OVERLAP' -LabelA 'Codex 문서 폴더' -LabelB 'Claude 문서 폴더'
            if ($errors.Count -eq 0) {
                Assert-DuoForgeOutputBoundary -ResultsRoot $resultsRoot -InputBoundaries @($codexParent, $claudeParent)
            }
            $inputs['codex'] = [ordered]@{
                primary = $codexPrimary
                context = Get-DuoForgeMarkdownInventoryInternal -Directory $codexParent -MaximumFileBytes ([long]$Config.limits.documentBytes)
            }
            $inputs['claude'] = [ordered]@{
                primary = $claudePrimary
                context = Get-DuoForgeMarkdownInventoryInternal -Directory $claudeParent -MaximumFileBytes ([long]$Config.limits.documentBytes)
            }
        }
        catch {
            $errors.Add([ordered]@{ code = Get-DuoForgeExceptionCode -Exception $_.Exception; message = $_.Exception.Message })
        }
    }
    elseif ($mode -eq 'dual-project-audit') {
        $errors.Add([ordered]@{
            code = 'DF-PREFLIGHT-3A-ISOLATION'
            message = '3A는 Codex 무도구 표면 또는 OS 격리가 검증되지 않아 현재 빌드에서 비활성화되어 있습니다.'
        })
    }
    else {
        $errors.Add([ordered]@{ code = 'DF-MODE'; message = "지원하지 않는 모드입니다: $mode" })
    }

    if (-not [bool]$DoctorReport.readyForDocumentModes -and $mode -in @('shared-document', 'dual-document')) {
        $errors.Add([ordered]@{
            code = 'DF-PREFLIGHT-PROVIDERS'
            message = '두 공급자의 구독 인증과 안전 실행 프로필이 모두 준비되지 않았습니다. duoforge doctor 결과를 확인해 주세요.'
        })
    }

    $plan = $null
    try {
        $plan = Get-DuoForgeExecutionPlanInternal -Mode $mode -MaxRounds ([int]$Request.maxRounds) -FirstSynthesizer ([string]$Request.firstSynthesizer) -MaxCallsPerProvider ([int]$Config.limits.maxCallsPerProviderPerRun)
        if (-not $plan.withinLimits) {
            $errors.Add([ordered]@{ code = 'DF-PLAN-CALL-LIMIT'; message = '최악 호출 계획이 공급자별 강제 호출 상한을 초과합니다.' })
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
        doctor = $DoctorReport
        errors = @($errors)
        warnings = @($warnings)
    }
}
