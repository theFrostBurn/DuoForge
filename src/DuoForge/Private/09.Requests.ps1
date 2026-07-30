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

function Resolve-DuoForgeContextInputAliasesInternal {
    [CmdletBinding()]
    param(
        [string]$DocumentAContext,
        [string]$DocumentBContext,
        [string]$CodexContext,
        [string]$ClaudeContext
    )

    $hasDocumentAContext = -not [string]::IsNullOrWhiteSpace($DocumentAContext)
    $hasDocumentBContext = -not [string]::IsNullOrWhiteSpace($DocumentBContext)
    $hasLegacyAContext = -not [string]::IsNullOrWhiteSpace($CodexContext)
    $hasLegacyBContext = -not [string]::IsNullOrWhiteSpace($ClaudeContext)
    if ($hasDocumentAContext -and $hasLegacyAContext -and -not [string]::Equals($DocumentAContext, $CodexContext, [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-DuoForgeException -Code 'DF-INPUT-CONTEXT-ALIAS-CONFLICT' -Message '문서 A 컨텍스트의 정규 입력과 레거시 --codex-context 입력이 서로 다릅니다.')
    }
    if ($hasDocumentBContext -and $hasLegacyBContext -and -not [string]::Equals($DocumentBContext, $ClaudeContext, [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-DuoForgeException -Code 'DF-INPUT-CONTEXT-ALIAS-CONFLICT' -Message '문서 B 컨텍스트의 정규 입력과 레거시 --claude-context 입력이 서로 다릅니다.')
    }
    $warnings = [System.Collections.Generic.List[object]]::new()
    if ($hasLegacyAContext -or $hasLegacyBContext) {
        $warnings.Add([ordered]@{
            code = 'DF-DEPRECATED-CONTEXT-ALIASES'
            message = '--codex-context와 --claude-context는 사용 중단 예정입니다. --document-a-context와 --document-b-context를 사용해 주세요.'
        })
    }
    return [ordered]@{
        documentAContext = if ($hasDocumentAContext) { $DocumentAContext } else { $CodexContext }
        documentBContext = if ($hasDocumentBContext) { $DocumentBContext } else { $ClaudeContext }
        warnings = @($warnings)
    }
}

function Merge-DuoForgeMarkdownInventoriesInternal {
    [CmdletBinding()]
    param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Inventories)

    $byPath = [ordered]@{}
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($inventory in @($Inventories | Where-Object { $null -ne $_ })) {
        $root = [string](Get-DuoForgeObjectValue -Object $inventory -Name 'root' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($root) -and $root -notin @($roots)) { $roots.Add($root) }
        foreach ($item in @(Get-DuoForgeObjectValue -Object $inventory -Name 'files' -Default @())) {
            $path = [string](Get-DuoForgeObjectValue -Object $item -Name 'path' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($path) -and -not $byPath.Contains($path)) {
                $byPath[$path] = ConvertTo-DuoForgeHashtable -InputObject $item
            }
        }
    }
    $files = @($byPath.Values)
    $included = @($files | Where-Object { [bool]$_.included })
    $excluded = @($files | Where-Object { -not [bool]$_.included })
    [long]$includedBytes = 0
    [long]$totalBytes = 0
    foreach ($item in $files) {
        $totalBytes += [long]$item.bytes
        if ([bool]$item.included) { $includedBytes += [long]$item.bytes }
    }
    return [ordered]@{
        root = if ($roots.Count -gt 0) { $roots[0] } else { '' }
        roots = @($roots)
        generatedAt = Get-DuoForgeUtcNow
        files = $files
        includedFiles = $included.Count
        excludedFiles = $excluded.Count
        includedBytes = $includedBytes
        totalBytes = $totalBytes
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
        [string]$DocumentAContext,
        [string]$DocumentBContext,
        [string]$CodexDocument,
        [string]$ClaudeDocument,
        [string]$CodexContext,
        [string]$ClaudeContext,
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
    $contextInputs = Resolve-DuoForgeContextInputAliasesInternal `
        -DocumentAContext $DocumentAContext `
        -DocumentBContext $DocumentBContext `
        -CodexContext $CodexContext `
        -ClaudeContext $ClaudeContext

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
        compatibilityWarnings = @($documentInputs.warnings) + @($contextInputs.warnings)
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
            documentAContext = [string]$contextInputs.documentAContext
            documentBContext = [string]$contextInputs.documentBContext
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

function Get-DuoForgeUnknownRequestFieldsInternal {
    [CmdletBinding()]
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string[]]$AllowedFields
    )

    if ($Value -isnot [System.Collections.IDictionary]) { return @() }
    return @($Value.Keys | ForEach-Object { [string]$_ } | Where-Object { $_ -notin $AllowedFields } | Sort-Object -Unique)
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
    $rootFields = @('schemaVersion', 'workflowVersion', 'mode', 'name', 'documentType', 'maxRounds', 'firstSynthesizer', 'pauseAfterRound', 'allowPartial', 'workspace', 'compatibilityWarnings', 'providerSelections', 'inputs')
    foreach ($field in @(Get-DuoForgeUnknownRequestFieldsInternal -Value $Request -AllowedFields $rootFields)) {
        $errors.Add([ordered]@{ code = 'DF-REQUEST-FIELD'; message = "신규 실행 요청에 허용되지 않은 필드가 있습니다: $field" })
    }
    $requestInputs = Get-DuoForgeObjectValue -Object $Request -Name 'inputs'
    if ($requestInputs -isnot [System.Collections.IDictionary]) {
        $errors.Add([ordered]@{ code = 'DF-REQUEST-FIELD'; message = '신규 실행 요청의 inputs는 객체여야 합니다.' })
        $requestInputs = [ordered]@{}
    }
    foreach ($field in @(Get-DuoForgeUnknownRequestFieldsInternal -Value $requestInputs -AllowedFields @('brief', 'documentA', 'documentB', 'documentAContext', 'documentBContext', 'codexProject', 'claudeProject', 'requirements'))) {
        $errors.Add([ordered]@{ code = 'DF-REQUEST-FIELD'; message = "신규 실행 요청 inputs에 허용되지 않은 필드가 있습니다: $field" })
    }
    $requestSelections = Get-DuoForgeObjectValue -Object $Request -Name 'providerSelections'
    if ($requestSelections -isnot [System.Collections.IDictionary]) {
        $errors.Add([ordered]@{ code = 'DF-REQUEST-FIELD'; message = '신규 실행 요청의 providerSelections는 객체여야 합니다.' })
        $requestSelections = [ordered]@{}
    }
    foreach ($field in @(Get-DuoForgeUnknownRequestFieldsInternal -Value $requestSelections -AllowedFields @('codex', 'claude'))) {
        $errors.Add([ordered]@{ code = 'DF-REQUEST-FIELD'; message = "providerSelections에 허용되지 않은 필드가 있습니다: $field" })
    }
    foreach ($provider in @('codex', 'claude')) {
        $selection = Get-DuoForgeObjectValue -Object $requestSelections -Name $provider
        foreach ($field in @(Get-DuoForgeUnknownRequestFieldsInternal -Value $selection -AllowedFields @('model', 'reasoningEffort'))) {
            $errors.Add([ordered]@{ code = 'DF-REQUEST-FIELD'; message = "$provider AI 설정에 사용할 수 없는 항목이 있습니다: $field" })
        }
    }
    if ([int](Get-DuoForgeObjectValue -Object $Request -Name 'schemaVersion' -Default 0) -ne 2) {
        $errors.Add([ordered]@{ code = 'DF-REQUEST-SCHEMA'; message = '신규 실행 요청 schemaVersion은 2여야 합니다.' })
    }
    $safeWarnings = [System.Collections.Generic.List[object]]::new()
    $deprecatedWarningMessage = '--codex와 --claude 문서 옵션은 사용 중단 예정입니다. --document-a와 --document-b를 사용해 주세요.'
    $deprecatedContextWarningMessage = '--codex-context와 --claude-context는 사용 중단 예정입니다. --document-a-context와 --document-b-context를 사용해 주세요.'
    foreach ($warning in @(Get-DuoForgeObjectValue -Object $Request -Name 'compatibilityWarnings' -Default @())) {
        $warningCode = [string](Get-DuoForgeObjectValue -Object $warning -Name 'code' -Default '')
        $warningMessage = [string](Get-DuoForgeObjectValue -Object $warning -Name 'message' -Default '')
        $validWarning = ($warningCode -eq 'DF-DEPRECATED-DOCUMENT-ALIASES' -and $warningMessage -eq $deprecatedWarningMessage) -or `
            ($warningCode -eq 'DF-DEPRECATED-CONTEXT-ALIASES' -and $warningMessage -eq $deprecatedContextWarningMessage)
        if (-not $validWarning) {
            $errors.Add([ordered]@{ code = 'DF-REQUEST-WARNING'; message = '신규 실행 요청에 검증되지 않은 호환성 경고가 포함되었습니다.' })
            continue
        }
        $safeWarnings.Add([ordered]@{ code = $warningCode; message = $warningMessage })
    }
    $Request = [ordered]@{
        schemaVersion = Get-DuoForgeObjectValue -Object $Request -Name 'schemaVersion' -Default 0
        workflowVersion = Get-DuoForgeObjectValue -Object $Request -Name 'workflowVersion' -Default ''
        mode = Get-DuoForgeObjectValue -Object $Request -Name 'mode' -Default ''
        name = Get-DuoForgeObjectValue -Object $Request -Name 'name'
        documentType = Get-DuoForgeObjectValue -Object $Request -Name 'documentType' -Default 'custom'
        maxRounds = Get-DuoForgeObjectValue -Object $Request -Name 'maxRounds' -Default 0
        firstSynthesizer = Get-DuoForgeObjectValue -Object $Request -Name 'firstSynthesizer' -Default 'alternate'
        pauseAfterRound = [bool](Get-DuoForgeObjectValue -Object $Request -Name 'pauseAfterRound' -Default $false)
        allowPartial = [bool](Get-DuoForgeObjectValue -Object $Request -Name 'allowPartial' -Default $false)
        workspace = Get-DuoForgeObjectValue -Object $Request -Name 'workspace'
        compatibilityWarnings = @($safeWarnings)
        providerSelections = ConvertTo-DuoForgeHashtable -InputObject $requestSelections
        inputs = ConvertTo-DuoForgeHashtable -InputObject $requestInputs
    }
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
            $documentAContextPath = if ([string]::IsNullOrWhiteSpace([string]$Request.inputs.documentAContext)) { $null } else { Resolve-DuoForgePathInternal -Path ([string]$Request.inputs.documentAContext) -ExpectedType Directory }
            $documentBContextPath = if ([string]::IsNullOrWhiteSpace([string]$Request.inputs.documentBContext)) { $null } else { Resolve-DuoForgePathInternal -Path ([string]$Request.inputs.documentBContext) -ExpectedType Directory }
            $documentABoundaries = @($documentAParent) + @(if ($null -ne $documentAContextPath) { $documentAContextPath })
            $documentBBoundaries = @($documentBParent) + @(if ($null -ne $documentBContextPath) { $documentBContextPath })
            foreach ($aBoundary in @($documentABoundaries | Sort-Object -Unique)) {
                foreach ($bBoundary in @($documentBBoundaries | Sort-Object -Unique)) {
                    Assert-DuoForgeDisjointPaths -PathA $aBoundary -PathB $bBoundary -Code 'DF-PATH-DUAL-DOCUMENT-OVERLAP' -LabelA '문서 A 입력 범위' -LabelB '문서 B 입력 범위'
                }
            }
            if ($errors.Count -eq 0) {
                Assert-DuoForgeOutputBoundary -ResultsRoot $resultsRoot -InputBoundaries @($documentABoundaries + $documentBBoundaries | Sort-Object -Unique)
            }
            $documentAInventories = @((Get-DuoForgeMarkdownInventoryInternal -Directory $documentAParent -MaximumFileBytes ([long]$Config.limits.documentBytes)))
            if ($null -ne $documentAContextPath) { $documentAInventories += @(Get-DuoForgeMarkdownInventoryInternal -Directory $documentAContextPath -MaximumFileBytes ([long]$Config.limits.documentBytes) -Recurse) }
            $documentBInventories = @((Get-DuoForgeMarkdownInventoryInternal -Directory $documentBParent -MaximumFileBytes ([long]$Config.limits.documentBytes)))
            if ($null -ne $documentBContextPath) { $documentBInventories += @(Get-DuoForgeMarkdownInventoryInternal -Directory $documentBContextPath -MaximumFileBytes ([long]$Config.limits.documentBytes) -Recurse) }
            $inputs['documents'] = [ordered]@{
                A = [ordered]@{
                    primary = $documentAPrimary
                    context = Merge-DuoForgeMarkdownInventoriesInternal -Inventories $documentAInventories
                }
                B = [ordered]@{
                    primary = $documentBPrimary
                    context = Merge-DuoForgeMarkdownInventoriesInternal -Inventories $documentBInventories
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
            message = '두 프로젝트 비교 기능은 현재 Windows에서 프로젝트 밖 파일 접근과 추가 프로그램 실행을 충분히 막지 못해 사용할 수 없습니다.'
        })
    }
    else {
        $errors.Add([ordered]@{ code = 'DF-MODE'; message = "지원하지 않는 모드입니다: $mode" })
    }

    $authenticationGate = Get-DuoForgeAuthenticationGateInternal -Report $DoctorReport
    if (-not [bool]$authenticationGate.modelCallsAllowed -and $mode -in @('shared-document', 'document-merge', 'dual-document')) {
        $errors.Add([ordered]@{
            code = [string]$authenticationGate.blockCode
            message = 'Codex와 Claude의 구독 로그인과 안전 설정이 모두 준비되지 않았습니다. duoforge doctor 결과를 확인해 주세요.'
        })
    }

    $plan = $null
    $contextPlan = $null
    try {
        $basePlan = Get-DuoForgeExecutionPlanInternal -Mode $mode -MaxRounds ([int]$Request.maxRounds) -FirstSynthesizer ([string]$Request.firstSynthesizer) -MaxCallsPerProvider ([int]$Config.limits.maxCallsPerProviderPerRun) -WorkflowVersion 'workflow-v2'
        $partialValidation = [ordered]@{ request = $Request; inputs = $inputs }
        $contextPlan = New-DuoForgeContextBatchPlanInternal -ValidationResult $partialValidation -Config $Config -BaseExecutionPlan $basePlan
        if ([bool]$contextPlan.enabled -and $mode -in @('document-merge', 'dual-document')) {
            $candidateById = @{}
            foreach ($candidate in @($contextPlan.candidateBlueprints)) { $candidateById[[string]$candidate.candidateId] = $candidate }
            $selectedDocumentIds = @($contextPlan.selectedCandidateIds | ForEach-Object { [string]$candidateById[[string]$_].documentId } | Sort-Object -Unique)
            $requiredDocumentIds = @($contextPlan.sourceBlueprints | ForEach-Object { [string]$_.documentId } | Sort-Object -Unique)
            $missingDocumentIds = @($requiredDocumentIds | Where-Object { $_ -notin $selectedDocumentIds })
            if ($missingDocumentIds.Count -gt 0) {
                $errors.Add([ordered]@{ code = 'DF-CONTEXT-DOCUMENT-CAPACITY'; message = "문서 A와 B를 모두 읽을 만큼 AI 요청 횟수가 남아 있지 않습니다. 읽지 못하는 문서: $($missingDocumentIds -join ', ')" })
            }
        }
        $plan = Get-DuoForgeExecutionPlanInternal -Mode $mode -MaxRounds ([int]$Request.maxRounds) -FirstSynthesizer ([string]$Request.firstSynthesizer) -MaxCallsPerProvider ([int]$Config.limits.maxCallsPerProviderPerRun) -ContextBatchCount ([int]$contextPlan.selectedBatchCount) -WorkflowVersion 'workflow-v2'
        if (-not $plan.withinLimits) {
            $errors.Add([ordered]@{ code = 'DF-PLAN-CALL-LIMIT'; message = '예상 AI 요청 횟수가 작업별 허용 상한을 초과합니다. 작업 범위를 줄여 주세요.' })
        }
        if ([bool]$contextPlan.requiresPartialConsent -and -not [bool](Get-DuoForgeObjectValue -Object $Request -Name 'allowPartial' -Default $false)) {
            $errors.Add([ordered]@{ code = 'DF-PARTIAL-CONSENT-REQUIRED'; message = "문서 전체 중 파일 기준 $($contextPlan.predictedFileCoveragePercent)%, 분량 기준 $($contextPlan.predictedByteCoveragePercent)%만 읽을 수 있습니다. 작업 범위를 줄이거나 일부만 읽은 결과로 진행하는 데 동의해 주세요. 명령줄에서는 --allow-partial 옵션을 사용합니다." })
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
