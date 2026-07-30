function Invoke-DuoForgeGuidedLoginCoreInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$Provider,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ProviderContext,
        [Parameter(Mandatory)]$CurrentReport,
        [scriptblock]$ProcessInvoker,
        [scriptblock]$ProviderDiagnosticInvoker,
        [switch]$RenderReport
    )
    $loginArguments = if ($Provider -eq 'codex') { @('login') } else { @('auth', 'login') }
    $processResult = if ($null -ne $ProcessInvoker) {
        & $ProcessInvoker $Provider $loginArguments $ProviderContext
    }
    else {
        Invoke-DuoForgeProcess -CommandName $Provider -Arguments $loginArguments -CommandInvocation $ProviderContext.invocation -EnvironmentAllowList @($ProviderContext.environmentAllowList) -EnvironmentOverrides $ProviderContext.environmentOverrides -Interactive -TimeoutSeconds 900
    }
    Clear-DuoForgeProviderCatalogCacheInternal -Provider $Provider
    $exitCode = if ($null -eq $processResult.exitCode) { 1 } else { [int]$processResult.exitCode }
    $diagnostic = if ($null -ne $ProviderDiagnosticInvoker) {
        & $ProviderDiagnosticInvoker $Provider $ProviderContext
    }
    else {
        Get-DuoForgeProviderDiagnostic -Provider $Provider -ProviderContext $ProviderContext
    }
    $report = Update-DuoForgeDoctorProviderInternal -Report $CurrentReport -Provider $Provider -Diagnostic $diagnostic
    $outcome = Get-DuoForgeGuidedLoginOutcomeInternal -Provider $Provider -ExitCode $exitCode -PostReport $report
    $outcome['postReport'] = $report
    if ([string]$outcome.status -eq 'CANCELLED_OR_FAILED') {
        Write-Host '로그인이 취소되었거나 완료되지 않았습니다. Codex 또는 Claude CLI가 표시한 URL·기기 코드 흐름을 그대로 사용하거나 수동 명령을 다시 실행해 주세요.' -ForegroundColor Yellow
    }
    elseif ([string]$outcome.status -eq 'AUTH_NOT_CONFIRMED') {
        Write-Host '로그인 명령은 끝났지만 구독 인증을 확인하지 못했습니다. 수동 명령을 확인한 뒤 다시 검사해 주세요.' -ForegroundColor Yellow
    }
    if ($RenderReport) { Write-DuoForgeDoctorReport -Report $report }
    return $outcome
}

function Invoke-DuoForgeGuidedLogin {
    [CmdletBinding()]
    param(
        [ValidateSet('codex', 'claude')][string]$Provider,
        $CurrentReport
    )

    if (-not (Test-DuoForgeInteractiveHost)) {
        throw (New-DuoForgeException -Code 'DF-AUTH-NONINTERACTIVE' -Message '비대화형 환경에서는 로그인 프로세스를 시작하지 않습니다.')
    }
    $providerContext = Resolve-DuoForgeProviderExecutionContextInternal -Provider $Provider
    if (-not [bool]$providerContext.liveRuntimeEligible) {
        throw (New-DuoForgeException -Code 'DF-AUTH-CONTEXT' -Message '현재 격리 프로필에서는 브라우저 로그인을 시작하지 않습니다. 일반 호스트 PowerShell 7에서 다시 실행해 주세요.')
    }
    if ($Provider -eq 'codex') {
        Write-Host 'Codex 공식 브라우저 로그인을 시작합니다. DuoForge는 인증 정보나 코드를 입력받지 않습니다.'
    }
    else {
        Write-Host 'Claude 공식 브라우저 로그인을 시작합니다. DuoForge는 인증 정보나 코드를 입력받지 않습니다.'
    }
    if ($null -eq $CurrentReport) { $CurrentReport = Invoke-DuoForgeDoctorInternal }
    return Invoke-DuoForgeGuidedLoginCoreInternal -Provider $Provider -ProviderContext $providerContext -CurrentReport $CurrentReport -RenderReport
}

function Get-DuoForgeInteractiveSetupActionsInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Report)

    return @((Get-DuoForgeAuthenticationGateInternal -Report $Report).actions)
}

function Invoke-DuoForgeInteractiveSetup {
    [CmdletBinding()]
    param(
        [switch]$ShowReadyReport,
        [scriptblock]$DoctorInvoker,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker
    )

    $setupReport = $null
    while ($true) {
        Write-Host '환경과 구독 로그인을 확인하고 있습니다...' -ForegroundColor DarkGray
        if ($null -eq $setupReport) {
            $setupReport = if ($null -ne $DoctorInvoker) { & $DoctorInvoker } else { Invoke-DuoForgeDoctorInternal }
        }
        if ([bool]$setupReport.readyForDocumentModes) {
            if ($ShowReadyReport) { Write-DuoForgeDoctorReport -Report $setupReport }
            else { Write-Host 'Codex와 Claude 구독 실행 환경이 준비되었습니다.' -ForegroundColor Green }
            return $setupReport
        }

        Write-DuoForgeDoctorReport -Report $setupReport
        $actions = @(Get-DuoForgeInteractiveSetupActionsInternal -Report $setupReport)
        $menuItems = [System.Collections.Generic.List[object]]::new()
        if ('codex-login' -in $actions) { $menuItems.Add([ordered]@{ value = 'C'; label = 'Codex 공식 로그인 시작'; shortcuts = @('C'); enabled = $true }) }
        if ('claude-login' -in $actions) { $menuItems.Add([ordered]@{ value = 'A'; label = 'Claude 공식 로그인 시작'; shortcuts = @('A'); enabled = $true }) }
        $menuItems.Add([ordered]@{ value = 'M'; label = '수동 로그인 명령 보기'; shortcuts = @('M'); enabled = $true })
        $menuItems.Add([ordered]@{ value = 'R'; label = '다시 검사'; shortcuts = @('R'); enabled = $true })
        $menuItems.Add([ordered]@{ value = 'B'; label = '홈으로 돌아가기'; shortcuts = @('B'); enabled = $true })
        $choice = Invoke-DuoForgeMenuInternal -Items @($menuItems) -Title '실행 환경 복구' -EscapeValue 'B' -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ($choice -ieq 'B') { return $setupReport }
        if ($choice -ieq 'C' -and 'codex-login' -in $actions) { $setupReport = (Invoke-DuoForgeGuidedLogin -Provider codex -CurrentReport $setupReport).postReport; continue }
        if ($choice -ieq 'A' -and 'claude-login' -in $actions) { $setupReport = (Invoke-DuoForgeGuidedLogin -Provider claude -CurrentReport $setupReport).postReport; continue }
        if ($choice -ieq 'M') {
            Write-Host 'Codex: codex login'
            Write-Host 'Claude: claude auth login'
            Write-Host '로그인 확인: codex login status / claude auth status'
            continue
        }
        if ($choice -ieq 'R') { $setupReport = $null; continue }
        Write-Host '현재 가능한 항목을 선택해 주세요.' -ForegroundColor Yellow
    }
}

function Get-DuoForgeInteractiveNewModeOptionsInternal {
    [CmdletBinding()]
    param()

    return @(
        [ordered]@{ key = '1'; value = '1'; shortcuts = @('1'); mode = 'shared-document'; label = '컨셉으로 공동 문서 만들기'; enabled = $true; disabledReason = $null }
        [ordered]@{ key = '2'; value = '2'; shortcuts = @('2'); mode = 'document-merge'; label = '두 문서를 하나로 합의하기'; enabled = $true; disabledReason = $null }
        [ordered]@{ key = '3'; value = '3'; shortcuts = @('3'); mode = 'dual-document'; label = '두 문서를 각각 개선하기'; enabled = $true; disabledReason = $null }
        [ordered]@{ key = '4'; value = '4'; shortcuts = @('4'); mode = 'dual-project-audit'; label = '두 프로젝트 비교하기'; enabled = $false; disabledReason = 'DF-PREFLIGHT-3A-ISOLATION: Windows 격리 게이트가 범위 밖 읽기와 자식 프로세스 차단을 증명하지 못했습니다.' }
    )
}

function Invoke-DuoForgeInteractiveNew {
    [CmdletBinding()]
    param(
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker
    )

    $modeOptions = @(Get-DuoForgeInteractiveNewModeOptionsInternal)
    $modeItems = @($modeOptions) + @([ordered]@{ value = 'B'; label = '이전으로'; shortcuts = @('B'); enabled = $true })
    $choice = Invoke-DuoForgeMenuInternal -Items $modeItems -Title '무엇을 하시겠습니까?' -EscapeValue 'B' -InputReader $InputReader -MenuInvoker $MenuInvoker
    if ($choice -ieq 'B') { return }

    $selectedOption = @($modeOptions | Where-Object { [string]$_.key -eq $choice }) | Select-Object -First 1
    if ($null -eq $selectedOption) {
        Write-Host '올바른 항목을 선택해 주세요.' -ForegroundColor Yellow
        return
    }
    if (-not [bool]$selectedOption.enabled) {
        Write-Host ([string]$selectedOption.disabledReason) -ForegroundColor DarkYellow
        Write-Host '입력 전송과 모델 호출 없이 종료합니다.' -ForegroundColor DarkYellow
        return
    }

    if ($choice -eq '1') {
        $brief = Read-DuoForgePathChoice -Prompt '입력 Markdown 문서를 선택해 주세요.' -Role 'shared-brief' -Type File -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ($null -eq $brief) { return }
        $selections = Complete-DuoForgeInteractiveProviderSelectionsInternal -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ($null -eq $selections) { Write-Host '모델 선택을 취소했습니다.'; return }
        $request = New-DuoForgeStartRequestInternal -Mode 'shared-document' -Brief $brief -DocumentType 'custom' -MaxRounds 2 `
            -CodexModel ([string]$selections.codex.model) -CodexReasoningEffort ([string]$selections.codex.reasoningEffort) `
            -ClaudeModel ([string]$selections.claude.model) -ClaudeReasoningEffort ([string]$selections.claude.reasoningEffort)
    }
    elseif ($choice -in @('2', '3')) {
        $documentA = Read-DuoForgePathChoice -Prompt '문서 A의 주요 Markdown 파일을 선택해 주세요.' -Role 'document-a' -Type File -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ($null -eq $documentA) { return }
        $documentB = Read-DuoForgePathChoice -Prompt '문서 B의 주요 Markdown 파일을 선택해 주세요.' -Role 'document-b' -Type File -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ($null -eq $documentB) { return }
        $selections = Complete-DuoForgeInteractiveProviderSelectionsInternal -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ($null -eq $selections) { Write-Host '모델 선택을 취소했습니다.'; return }
        $request = New-DuoForgeStartRequestInternal -Mode ([string]$selectedOption.mode) -DocumentA $documentA -DocumentB $documentB -DocumentType 'custom' -MaxRounds 2 `
            -CodexModel ([string]$selections.codex.model) -CodexReasoningEffort ([string]$selections.codex.reasoningEffort) `
            -ClaudeModel ([string]$selections.claude.model) -ClaudeReasoningEffort ([string]$selections.claude.reasoningEffort)
    }

    $validation = Test-DuoForgeStartRequestInternal -Request $request
    $validation = Confirm-DuoForgeInteractivePartialAnalysisInternal -Validation $validation
    if (-not $validation.valid) {
        Write-DuoForgeValidationErrors -Validation $validation
        return
    }
    Write-DuoForgeExecutionPlan -Validation $validation
    $confirmation = (Read-Host '변경되지 않는 입력 사본과 작업 기록을 만들까요? [Y/N]').Trim()
    if ($confirmation -notin @('Y', 'y')) {
        Write-Host '취소했습니다. 확정 실행은 생성하지 않았습니다.'
        return
    }
    $run = New-DuoForgeRunInternal -ValidationResult $validation
    Write-Host ('실행 골격 생성 완료: {0}' -f $run.runId) -ForegroundColor Green
    Write-Host ('경로: {0}' -f $run.runDirectory)
}

function Confirm-DuoForgeInteractivePartialAnalysisInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Validation)

    $partialErrors = @($Validation.errors | Where-Object { [string]$_.code -eq 'DF-PARTIAL-CONSENT-REQUIRED' })
    $otherErrors = @($Validation.errors | Where-Object { [string]$_.code -ne 'DF-PARTIAL-CONSENT-REQUIRED' })
    if ($partialErrors.Count -eq 0 -or $otherErrors.Count -gt 0 -or -not (Test-DuoForgeInteractiveHost)) { return $Validation }
    Write-Host ([string]$partialErrors[0].message) -ForegroundColor Yellow
    $confirmation = (Read-Host '부분 분석과 COMPLETED_PARTIAL 결과에 동의하면 PARTIAL을 입력하세요').Trim()
    if ($confirmation -cne 'PARTIAL') { return $Validation }
    $Validation.request.allowPartial = $true
    return Test-DuoForgeStartRequestInternal -Request $Validation.request -DoctorReport $Validation.doctor
}

function Select-DuoForgeInteractiveRun {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Runs,
        [Parameter(Mandatory)][string]$Prompt,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker
    )

    if ($Runs.Count -eq 0) { Write-Host '해당 실행이 없습니다.'; return $null }
    $items = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Runs.Count; $index++) {
        $run = $Runs[$index]
        $items.Add([ordered]@{
            value = [string]$index
            label = ('{0} · {1} · {2}' -f $run.name, (Get-DuoForgeDisplayModeLabelInternal -Mode ([string]$run.mode)), (Get-DuoForgeDisplayStateLabelInternal -Status ([string]$run.status)))
            shortcuts = @([string]($index + 1))
            enabled = $true
        })
    }
    $items.Add([ordered]@{ value = 'B'; label = '이전으로'; shortcuts = @('B'); enabled = $true })
    $choice = Invoke-DuoForgeMenuInternal -Items @($items) -Title $Prompt -EscapeValue 'B' -InputReader $InputReader -MenuInvoker $MenuInvoker
    if ($choice -ieq 'B') { return $null }
    return $Runs[[int]$choice]
}

function Invoke-DuoForgeInteractiveLiveResume {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [scriptblock]$InputReader,
        [scriptblock]$ResumeInvoker
    )

    $budget = Get-DuoForgeRemainingCallBudget -RunDirectory ([string]$Run.runDirectory)
    $selections = Get-DuoForgeRunProviderSelectionsInternal -RunDirectory ([string]$Run.runDirectory)
    Write-Host '선택한 입력 사본 내용이 Codex와 Claude에 전송됩니다.' -ForegroundColor Yellow
    Write-DuoForgeProviderSelectionSummary -ProviderSelections $selections
    Write-Host (Format-DuoForgeRemainingCallBudgetLineInternal -ProviderLabel 'Codex' -ProviderBudget $budget.providers.codex) -ForegroundColor Yellow
    Write-Host (Format-DuoForgeRemainingCallBudgetLineInternal -ProviderLabel 'Claude' -ProviderBudget $budget.providers.claude) -ForegroundColor Yellow
    $confirmation = if ($null -ne $InputReader) { [string](& $InputReader '실제 Codex·Claude 호출을 시작하려면 LIVE를 입력하세요') } else { Read-Host '실제 Codex·Claude 호출을 시작하려면 LIVE를 입력하세요' }
    $confirmation = $confirmation.Trim()
    if ($confirmation -cne 'LIVE') { Write-Host '라이브 실행을 취소했습니다.'; return }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $result = if ($null -ne $ResumeInvoker) {
        & $ResumeInvoker ([string]$Run.state.runId) $resultsRoot $true
    }
    else {
        Invoke-DuoForgeResumeWithProgressInternal -RunId ([string]$Run.state.runId) -ResultsRoot $resultsRoot -WaitForAcknowledgement -ReturnTarget menu
    }
    if ($null -ne $result -and -not [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $result -Name 'diagnosticId'))) {
        Write-DuoForgeDiagnosticReferenceInternal -Source $result -RunDirectory ([string]$Run.runDirectory)
    }
}

function Read-DuoForgeInteractiveExplanationRequest {
    [CmdletBinding()]
    param(
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker
    )

    $providerChoice = Invoke-DuoForgeMenuInternal -Title '어느 관점의 설명이 필요하십니까?' -EscapeValue 'B' -InputReader $InputReader -MenuInvoker $MenuInvoker -Items @(
        [ordered]@{ value = '1'; label = 'Codex 관점'; shortcuts = @('1'); enabled = $true }
        [ordered]@{ value = '2'; label = 'Claude 관점'; shortcuts = @('2'); enabled = $true }
        [ordered]@{ value = '3'; label = '양쪽 관점 비교'; shortcuts = @('3'); enabled = $true }
        [ordered]@{ value = 'B'; label = '이전으로'; shortcuts = @('B'); enabled = $true }
    )
    if ($providerChoice -ieq 'B') { return $null }
    $provider = switch ($providerChoice) { '1' { 'codex' } '2' { 'claude' } '3' { 'both' } default { $null } }
    if ($null -eq $provider) { Write-Host '올바른 관점을 선택해 주세요.' -ForegroundColor Yellow; return $null }

    $levelChoice = Invoke-DuoForgeMenuInternal -Title '설명 수준을 선택해 주세요.' -EscapeValue 'B' -InputReader $InputReader -MenuInvoker $MenuInvoker -Items @(
        [ordered]@{ value = '1'; label = '초급 - 전문용어를 풀어 설명'; shortcuts = @('1'); enabled = $true }
        [ordered]@{ value = '2'; label = '일반 - 실무 결정 중심'; shortcuts = @('2'); enabled = $true }
        [ordered]@{ value = '3'; label = '전문가 - 전제와 실패 조건까지 상세히'; shortcuts = @('3'); enabled = $true }
        [ordered]@{ value = 'B'; label = '이전으로'; shortcuts = @('B'); enabled = $true }
    )
    if ($levelChoice -ieq 'B') { return $null }
    $level = switch ($levelChoice) { '1' { 'beginner' } '2' { 'general' } '3' { 'expert' } default { $null } }
    if ($null -eq $level) { Write-Host '올바른 설명 수준을 선택해 주세요.' -ForegroundColor Yellow; return $null }
    return [ordered]@{ provider = $provider; level = $level; focus = 'general' }
}

function Invoke-DuoForgeInteractiveIssueExplanation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [Parameter(Mandatory)][string]$IssueId,
        [Parameter(Mandatory)][ValidateSet('codex', 'claude', 'both')][string]$Provider,
        [Parameter(Mandatory)][ValidateSet('beginner', 'general', 'expert')][string]$Level,
        [ValidateSet('general', 'evidence', 'examples', 'tradeoffs', 'experiment')][string]$Focus = 'general'
    )

    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $existing = Get-DuoForgeIssueExplanationsInternal -RunId ([string]$Run.state.runId) -IssueId $IssueId -ResultsRoot $resultsRoot
    $requiredCalls = if ($Provider -eq 'both') { 2 } else { 1 }
    if ([int]$existing.budget.remaining -lt $requiredCalls) {
        Write-Host ('설명 호출 잔여 예산이 부족합니다. 남음 {0}, 필요 {1}' -f $existing.budget.remaining, $requiredCalls) -ForegroundColor Yellow
        Write-DuoForgeExplanationRecords -Records @($existing.explanations)
        return
    }
    Write-Host ('검토 항목 {0}에 {1} 관점, {2} 수준의 설명을 요청합니다.' -f $IssueId, $Provider, $Level) -ForegroundColor Yellow
    Write-DuoForgeProviderSelectionSummary -ProviderSelections $Run.manifest.providerSelections
    Write-Host ('이번 호출 {0}회, 실행 전체 잔여 설명 예산 {1}회' -f $requiredCalls, $existing.budget.remaining) -ForegroundColor Yellow
    $confirmation = (Read-Host '실제 설명 호출을 시작하려면 LIVE를 입력하세요').Trim()
    if ($confirmation -cne 'LIVE') { Write-Host '설명 호출을 취소했습니다.'; return }
    $result = Invoke-DuoForgeIssueExplanationInternal -RunId ([string]$Run.state.runId) -IssueId $IssueId -Provider $Provider -Level $Level -Focus $Focus -ResultsRoot $resultsRoot -LiveConsent $true
    Write-DuoForgeExplanationRecords -Records @($result.explanations)
    Write-Host ('설명 호출 예산: 사용 {0}/{1}, 남음 {2}' -f $result.budget.used, $result.budget.maximum, $result.budget.remaining)
}

function Test-DuoForgeInteractiveOpinionPlaceholderInternal {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    return $Text -match '쟁점 이력과 상세 설명|상세 설명에서 확인|기록된 (?:Codex|Claude) 의견'
}

function Get-DuoForgeInteractiveProviderLabelInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Provider)

    switch ($Provider.ToLowerInvariant()) {
        'codex' { 'Codex' }
        'claude' { 'Claude' }
        'orchestrator' { 'DuoForge' }
        default { ConvertTo-DuoForgeProgressTextInternal -Text $Provider -MaximumCharacters 80 }
    }
}

function Get-DuoForgeInteractiveDocumentLabelInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$TargetDocumentId)

    switch ($TargetDocumentId) {
        'A' { '문서 A' }
        'B' { '문서 B' }
        'AB' { '문서 A와 문서 B' }
        'document-a' { '문서 A' }
        'document-b' { '문서 B' }
        'merged' { '최종 문서' }
        'brief' { '공통 요구 문서' }
        'document' { '작업 문서' }
        default { '관련 문서' }
    }
}

function Get-DuoForgeInteractiveCategoryLabelInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Category)

    switch ($Category) {
        'consistency/privacy' { '개인정보·오프라인 정책 충돌' }
        'scope-consistency' { '배포 범위 충돌' }
        'regression/binding-constraint' { '빠진 필수 조건' }
        'regression/verification' { '빠진 실기기 검증' }
        'regression/testability' { '빠진 데이터·검증 정의' }
        default {
            $label = ConvertTo-DuoForgeProgressTextInternal -Text $Category -MaximumCharacters 100
            if ([string]::IsNullOrWhiteSpace($label)) { return '사용자 결정 필요' }
            return ($label -replace '/', ' · ')
        }
    }
}

function Get-DuoForgeInteractiveQuestionSubjectInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Question,
        [AllowNull()]$Issue
    )

    $title = ConvertTo-DuoForgeProgressTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $Question -Name 'title')) -MaximumCharacters 600
    $claim = if ($null -ne $Issue) { [string](Get-DuoForgeObjectValue -Object $Issue -Name 'claim') } else { '' }
    $category = if ($null -ne $Issue) { [string](Get-DuoForgeObjectValue -Object $Issue -Name 'category') } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($category) -and ($title.Length -gt 72 -or [string]::Equals($title.Trim(), $claim.Trim(), [StringComparison]::Ordinal))) {
        return Get-DuoForgeInteractiveCategoryLabelInternal -Category $category
    }
    if ([string]::IsNullOrWhiteSpace($title)) { return Get-DuoForgeInteractiveCategoryLabelInternal -Category $category }
    return $title
}

function Get-DuoForgeInteractiveSentenceSummaryInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [ValidateRange(80, 1000)][int]$MaximumCharacters = 360,
        [switch]$FirstSentence
    )

    $value = ConvertTo-DuoForgeProgressTextInternal -Text $Text -MaximumCharacters 1200
    $value = $value `
        -replace '기술 스파이크가', '사전 기술 시험이' `
        -replace '기술 스파이크', '사전 기술 시험' `
        -replace '온디바이스 플랫폼 STT로', '기기 안에서 처리되는 휴대폰 기본 음성 인식으로' `
        -replace '플랫폼 STT로', '휴대폰 기본 음성 인식으로' `
        -replace '온디바이스 플랫폼 STT', '기기 안에서 처리되는 휴대폰 기본 음성 인식' `
        -replace '플랫폼 STT', '휴대폰 기본 음성 인식' `
        -replace '온디바이스', '기기 안에서 처리되는 방식' `
        -replace '\bSTT\b', '음성 인식' `
        -replace '\bNF-05\b', '오프라인 동작 요구(NF-05)' `
        -replace '\brecognizer\b', '음성 인식 기능' `
        -replace '\bP0\b', '최우선 요구'
    if ($FirstSentence) {
        $match = [regex]::Match($value, '^.*?[.!?](?=\s|$)')
        if ($match.Success -and $match.Value.Length -ge 40) { $value = $match.Value }
    }
    return ConvertTo-DuoForgeProgressTextInternal -Text $value -MaximumCharacters $MaximumCharacters
}

function Get-DuoForgeInteractiveCompactIssueInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $value = Get-DuoForgeInteractiveSentenceSummaryInternal -Text $Text -MaximumCharacters 600
    $sentences = @([regex]::Matches($value, '[^.!?]+[.!?](?=\s|$)|[^.!?]+$') | ForEach-Object { $_.Value.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($sentences.Count -gt 1 -and $sentences[-1].Length -ge 30) {
        return ConvertTo-DuoForgeProgressTextInternal -Text $sentences[-1] -MaximumCharacters 300
    }
    return ConvertTo-DuoForgeProgressTextInternal -Text $value -MaximumCharacters 300
}

function Get-DuoForgeInteractiveProviderOpinionInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Question,
        [AllowNull()]$Issue,
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$Provider
    )

    $propertyName = if ($Provider -eq 'codex') { 'codexOpinion' } else { 'claudeOpinion' }
    $storedOpinion = ConvertTo-DuoForgeProgressTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $Question -Name $propertyName)) -MaximumCharacters 600
    if (-not (Test-DuoForgeInteractiveOpinionPlaceholderInternal -Text $storedOpinion)) { return $storedOpinion }
    if ($null -eq $Issue) { return '이 질문에 저장된 구체적인 검토 의견이 없습니다.' }

    $verdicts = @(
        @(Get-DuoForgeObjectValue -Object $Issue -Name 'reviewerVerdicts' -Default @()) |
            Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'reviewer') -ieq $Provider }
    )
    $raisedBy = if ($null -ne $Issue) { [string](Get-DuoForgeObjectValue -Object $Issue -Name 'raisedBy') } else { '' }
    $isOriginator = [string]::Equals($raisedBy, $Provider, [StringComparison]::OrdinalIgnoreCase)
    if ($verdicts.Count -gt 0) {
        $verdict = [string](Get-DuoForgeObjectValue -Object $verdicts[-1] -Name 'verdict')
        switch ($verdict) {
            'AGREES' {
                if ($isOriginator) { return '이 문제를 처음 제기했고, 해결이 필요하다는 판단을 유지했습니다.' }
                return '같은 문제라고 보고 해결이 필요하다는 데 동의했습니다.'
            }
            'PARTIALLY_AGREES' {
                if ($isOriginator) { return '이 문제를 처음 제기했고, 뒤이은 처리 판단에는 일부만 동의했습니다.' }
                return '문제의 일부에는 동의했지만 해결 방향 전체에는 동의하지 않았습니다.'
            }
            'DISAGREES' { return '이 문제 또는 제안된 해결 방향에 동의하지 않았습니다.' }
            'UNVERIFIABLE' { return '현재 근거만으로는 이 문제와 해결 방향을 확인하기 어렵다고 봤습니다.' }
        }
    }

    if ($isOriginator) { return '이 문제를 처음 제기했습니다.' }

    $blockingProposals = Get-DuoForgeObjectValue -Object $Issue -Name 'blockingProposals' -Default ([ordered]@{})
    if ($blockingProposals -is [System.Collections.IDictionary] -and $blockingProposals.Contains($Provider)) {
        if ([bool]$blockingProposals[$Provider]) { return '이 쟁점을 해결하기 전에는 진행을 멈춰야 한다고 봤습니다.' }
        return '이 쟁점이 진행을 막을 정도는 아니라고 봤습니다.'
    }
    return '이 질문에 저장된 구체적인 검토 의견이 없습니다.'
}

function Get-DuoForgeInteractiveQuestionPresentationInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Question,
        [AllowNull()]$Issue
    )

    $recommendedToken = ([string](Get-DuoForgeObjectValue -Object $Question -Name 'recommendedOption')).Trim()
    $safeDefaultToken = ([string](Get-DuoForgeObjectValue -Object $Question -Name 'safeDefault')).Trim()
    $targetDocumentId = if ($null -ne $Issue) { Get-DuoForgeIssueTargetInternal -Issue $Issue } else { '' }
    $targetLabel = Get-DuoForgeInteractiveDocumentLabelInternal -TargetDocumentId $targetDocumentId
    $editorialDecisions = @()
    if ($null -ne $Issue) { $editorialDecisions = @(Get-DuoForgeObjectValue -Object $Issue -Name 'editorialDecisions' -Default @()) }
    if ($editorialDecisions.Count -eq 0 -and $null -ne $Issue) { $editorialDecisions = @(Get-DuoForgeObjectValue -Object $Issue -Name 'ownerDecisions' -Default @()) }
    if ($editorialDecisions.Count -eq 0 -and $null -ne $Issue) { $editorialDecisions = @(Get-DuoForgeObjectValue -Object $Issue -Name 'adoptions' -Default @()) }
    $latestEditorial = @($editorialDecisions | Select-Object -Last 1)
    $hasAcceptedEditorial = $latestEditorial.Count -gt 0 -and [string](Get-DuoForgeObjectValue -Object $latestEditorial[0] -Name 'disposition') -in @('ACCEPTED', 'PARTIALLY_ACCEPTED')
    $acceptedEditorial = @()
    if ($hasAcceptedEditorial) { $acceptedEditorial = @($latestEditorial[0]) }
    $options = [System.Collections.Generic.List[object]]::new()
    $rawOptions = @(Get-DuoForgeObjectValue -Object $Question -Name 'options' -Default @())
    $genericApprovalPair = $rawOptions.Count -eq 2 -and [string]$rawOptions[0] -match '^\s*A\s*[:：.)-]\s*제안 내용을 반영' -and [string]$rawOptions[1] -match '^\s*B\s*[:：.)-]\s*현재 요구를 유지'
    for ($index = 0; $index -lt $rawOptions.Count; $index++) {
        $letter = [string][char]([int][char]'A' + $index)
        $rawLabel = ConvertTo-DuoForgeProgressTextInternal -Text ([string]$rawOptions[$index]) -MaximumCharacters 600
        $prefixPattern = '^\s*' + [regex]::Escape($letter) + '\s*[:：.)-]\s*'
        $label = [regex]::Replace($rawLabel, $prefixPattern, '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Trim()
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $rawLabel }
        $isRecommended = (
            [string]::Equals($recommendedToken, $letter, [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($recommendedToken, $rawLabel, [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($recommendedToken, $label, [StringComparison]::OrdinalIgnoreCase) -or
            $recommendedToken -match $prefixPattern
        )
        $displayLabel = $label
        $outcome = '선택하면 이 방향을 사용자 결정으로 확정하고 관련 문서·검증 단계를 다시 실행합니다.'
        if ($genericApprovalPair -and $index -eq 0) {
            $displayLabel = if ($hasAcceptedEditorial) { 'AI가 잠정 반영한 수정 방향을 승인' } else { 'AI가 제안한 수정 방향을 선택' }
            $outcome = if ($hasAcceptedEditorial) {
                "${targetLabel}의 잠정 수정을 확정하고 관련 문서·검증 단계를 다시 실행합니다."
            }
            else {
                "${targetLabel}에 해결 방향을 반영하고 관련 문서·검증 단계를 다시 실행합니다."
            }
        }
        elseif ($genericApprovalPair -and $index -eq 1) {
            $displayLabel = if ($hasAcceptedEditorial) { '잠정 수정을 승인하지 않고 기존 요구를 유지' } else { '제안을 반영하지 않고 기존 요구를 유지' }
            $outcome = '기존 요구를 기준으로 다시 검증하며, 충돌이 남으면 작업을 완료하지 못할 수 있습니다.'
        }
        $options.Add([ordered]@{
            internalCode = $letter
            letter = $letter
            displayOrdinal = $index + 1
            rawLabel = $rawLabel
            sourceLabel = $label
            label = $displayLabel
            outcome = $outcome
            isRecommended = $isRecommended
        })
    }

    $recommended = @($options | Where-Object { [bool]$_.isRecommended } | Select-Object -First 1)
    if ($recommended.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($safeDefaultToken)) {
        $recommended = @($options | Where-Object {
            [string]::Equals($safeDefaultToken, [string]$_.letter, [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($safeDefaultToken, [string]$_.rawLabel, [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($safeDefaultToken, [string]$_.label, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($recommended.Count -gt 0) { $recommended[0].isRecommended = $true }
    }
    $recommendedLabel = if ($recommended.Count -gt 0) {
        '{0}안 · {1}' -f [int]$recommended[0].displayOrdinal, [string]$recommended[0].label
    }
    elseif (-not [string]::IsNullOrWhiteSpace($recommendedToken)) {
        ConvertTo-DuoForgeProgressTextInternal -Text $recommendedToken -MaximumCharacters 600
    }
    else {
        '별도 권장 없음'
    }

    $reversibility = switch ([string](Get-DuoForgeObjectValue -Object $Question -Name 'reversibility')) {
        'easy' { '쉬움' }
        'moderate' { '보통 — 일부 단계 재실행 필요' }
        'hard' { '어려움' }
        'unknown' { '확인 필요' }
        default { ConvertTo-DuoForgeProgressTextInternal -Text ([string]$_) -MaximumCharacters 120 }
    }
    $confidence = switch ([string](Get-DuoForgeObjectValue -Object $Question -Name 'confidence')) {
        'low' { '낮음' }
        'medium' { '보통' }
        'high' { '높음' }
        default { ConvertTo-DuoForgeProgressTextInternal -Text ([string]$_) -MaximumCharacters 120 }
    }
    $impactIfDeferred = ConvertTo-DuoForgeProgressTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $Question -Name 'impactIfDeferred')) -MaximumCharacters 600
    $impactIfDeferred = $impactIfDeferred -replace '\bMajor 쟁점', '중요 쟁점' -replace '\bCritical 쟁점', '반드시 해결할 쟁점'

    $questionText = ConvertTo-DuoForgeProgressTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $Question -Name 'question')) -MaximumCharacters 600
    $requestKind = if ($genericApprovalPair -and $hasAcceptedEditorial) {
        '승인 요청'
    }
    elseif ($questionText -match '승인|동의|확정|결정') {
        '방향 확정 요청'
    }
    elseif ($rawOptions.Count -gt 1) {
        '선택 요청'
    }
    else {
        '사용자 확인 요청'
    }
    $requestPrompt = if ($genericApprovalPair -and $hasAcceptedEditorial) {
        'AI가 문서에 잠정 반영한 수정 방향을 최종 결정으로 승인할지 선택해 주세요.'
    }
    elseif ($genericApprovalPair) {
        'AI가 제안한 해결 방향을 문서에 반영할지 선택해 주세요.'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($questionText)) {
        $questionText
    }
    else {
        '아래 대안 중 문서에 확정할 방향을 선택해 주세요.'
    }
    $requestPurpose = Get-DuoForgeInteractiveSentenceSummaryInternal -Text ([string](Get-DuoForgeObjectValue -Object $Question -Name 'reasonNow')) -MaximumCharacters 420
    if ([string]::IsNullOrWhiteSpace($requestPurpose)) { $requestPurpose = '선택 결과를 문서에 확정하고 관련 단계를 다시 검증하기 위해 묻습니다.' }

    $plainExplanation = [string](Get-DuoForgeObjectValue -Object $Question -Name 'plainExplanation')
    $issueClaim = if ($null -ne $Issue) { [string](Get-DuoForgeObjectValue -Object $Issue -Name 'claim') } else { '' }
    $coreIssueSource = if (-not [string]::IsNullOrWhiteSpace($plainExplanation)) { $plainExplanation } else { $issueClaim }
    $coreIssue = Get-DuoForgeInteractiveSentenceSummaryInternal -Text $coreIssueSource -MaximumCharacters 460
    $compactCoreIssue = Get-DuoForgeInteractiveCompactIssueInternal -Text $coreIssueSource
    $proposal = if ($null -ne $Issue) { [string](Get-DuoForgeObjectValue -Object $Issue -Name 'proposal') } else { '' }
    $proposalSummary = Get-DuoForgeInteractiveSentenceSummaryInternal -Text $proposal -MaximumCharacters 360 -FirstSentence
    if ([string]::IsNullOrWhiteSpace($proposalSummary)) { $proposalSummary = '저장된 구체적인 해결 제안이 없습니다.' }

    $raisedBy = if ($null -ne $Issue) { [string](Get-DuoForgeObjectValue -Object $Issue -Name 'raisedBy') } else { '' }
    $raisedByLabel = Get-DuoForgeInteractiveProviderLabelInternal -Provider $raisedBy
    $originSummary = if ([string]::IsNullOrWhiteSpace($raisedBy)) {
        '최초 문제 제기자는 구조화된 기록에서 확인되지 않습니다.'
    }
    else {
        "${raisedByLabel}가 ${targetLabel}에서 이 문제를 처음 제기했습니다."
    }

    $verdictMap = @{}
    if ($null -ne $Issue) {
        foreach ($verdictRecord in @(Get-DuoForgeObjectValue -Object $Issue -Name 'reviewerVerdicts' -Default @())) {
            $reviewerKey = ([string](Get-DuoForgeObjectValue -Object $verdictRecord -Name 'reviewer')).ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($reviewerKey)) { $verdictMap[$reviewerKey] = [string](Get-DuoForgeObjectValue -Object $verdictRecord -Name 'verdict') }
        }
    }
    $aiConsensus = if ($verdictMap.ContainsKey('codex') -and $verdictMap.ContainsKey('claude') -and $verdictMap['codex'] -eq 'AGREES' -and $verdictMap['claude'] -eq 'AGREES') {
        'Codex와 Claude 모두 이 문제가 실제로 존재하며 해결이 필요하다는 데 동의했습니다.'
    }
    elseif (@($verdictMap.Values | Where-Object { $_ -eq 'DISAGREES' }).Count -gt 0) {
        '두 AI의 판단이 일치하지 않습니다. 각 AI의 기록을 확인한 뒤 방향을 선택해야 합니다.'
    }
    elseif (@($verdictMap.Values | Where-Object { $_ -eq 'AGREES' }).Count -gt 0) {
        '한 AI가 문제 해결 필요성에 동의했지만, 양쪽의 명시적인 합의 기록은 아직 없습니다.'
    }
    else {
        '두 AI가 이 문제에 합의했다는 구조화된 기록은 아직 없습니다.'
    }

    $documentAction = if ($hasAcceptedEditorial) {
        $action = $acceptedEditorial[0]
        $actor = Get-DuoForgeInteractiveProviderLabelInternal -Provider ([string](Get-DuoForgeObjectValue -Object $action -Name 'performedBy' -Default (Get-DuoForgeObjectValue -Object $action -Name 'actor')))
        $locations = @(Get-DuoForgeObjectValue -Object $action -Name 'locations' -Default @())
        $locationText = if ($locations.Count -gt 0) { "의 $($locations.Count)곳에" } else { '에' }
        "${actor}가 ${targetLabel}${locationText} 해결 방향을 잠정 반영했습니다. 사용자 승인 전이라 최종 확정은 아닙니다."
    }
    elseif ($editorialDecisions.Count -gt 0) {
        '문서 처리 판단은 기록됐지만, 해결 방향이 반영됐다는 기록은 없습니다.'
    }
    else {
        "${targetLabel}에는 아직 이 문제의 해결 방향이 반영되지 않았습니다."
    }
    $consensusShort = if ($verdictMap.ContainsKey('codex') -and $verdictMap.ContainsKey('claude') -and $verdictMap['codex'] -eq 'AGREES' -and $verdictMap['claude'] -eq 'AGREES') {
        'Codex·Claude 모두 동의'
    }
    elseif (@($verdictMap.Values | Where-Object { $_ -eq 'DISAGREES' }).Count -gt 0) {
        'AI 판단 불일치'
    }
    elseif (@($verdictMap.Values | Where-Object { $_ -eq 'AGREES' }).Count -gt 0) {
        '한 AI만 명시적으로 동의'
    }
    else {
        '양쪽 합의 기록 없음'
    }
    $reviewFlowParts = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($raisedBy)) { $reviewFlowParts.Add("$raisedByLabel 문제 제기") }
    $reviewFlowParts.Add($consensusShort)
    if ($hasAcceptedEditorial) {
        $flowAction = $acceptedEditorial[0]
        $flowActor = Get-DuoForgeInteractiveProviderLabelInternal -Provider ([string](Get-DuoForgeObjectValue -Object $flowAction -Name 'performedBy' -Default (Get-DuoForgeObjectValue -Object $flowAction -Name 'actor')))
        $flowLocations = @(Get-DuoForgeObjectValue -Object $flowAction -Name 'locations' -Default @())
        $flowLocationText = if ($flowLocations.Count -gt 0) { "의 $($flowLocations.Count)곳" } else { '' }
        $reviewFlowParts.Add("${flowActor}가 ${targetLabel}${flowLocationText}에 잠정 반영")
    }
    else {
        $reviewFlowParts.Add('문서 반영 전')
    }
    $reviewFlow = $reviewFlowParts -join ' · '
    $currentState = if ($hasAcceptedEditorial) {
        "${targetLabel}의 검토와 잠정 수정은 끝났지만 사용자 결정이 남아 있어 전체 작업은 '답변 대기' 상태입니다."
    }
    else {
        "${targetLabel}에서 해결되지 않은 문제가 발견됐고 사용자 결정이 남아 있어 전체 작업은 '답변 대기' 상태입니다."
    }
    $compactCurrentState = if ($hasAcceptedEditorial) {
        "${targetLabel} · AI 검토와 잠정 수정 완료 · 사용자 승인 대기"
    }
    else {
        "${targetLabel} · 해결 방향 미확정 · 사용자 선택 대기"
    }

    return [ordered]@{
        options = @($options)
        recommendedLabel = $recommendedLabel
        targetLabel = $targetLabel
        subjectLabel = Get-DuoForgeInteractiveQuestionSubjectInternal -Question $Question -Issue $Issue
        currentState = $currentState
        compactCurrentState = $compactCurrentState
        coreIssue = $coreIssue
        compactCoreIssue = $compactCoreIssue
        originSummary = $originSummary
        aiConsensus = $aiConsensus
        documentAction = $documentAction
        reviewFlow = $reviewFlow
        proposalSummary = $proposalSummary
        requestKind = $requestKind
        requestPrompt = $requestPrompt
        requestPurpose = $requestPurpose
        codexOpinion = Get-DuoForgeInteractiveProviderOpinionInternal -Question $Question -Issue $Issue -Provider codex
        claudeOpinion = Get-DuoForgeInteractiveProviderOpinionInternal -Question $Question -Issue $Issue -Provider claude
        reversibility = $reversibility
        confidence = $confidence
        impactIfDeferred = $impactIfDeferred
        choiceNotice = '문서 계보는 "문서 A/문서 B", 사용자 선택은 "1안/2안/3안"으로 구분합니다.'
        providerNotice = 'AI 이름은 검토 기록에만 표시되며 사용자 선택 번호와 연결되지 않습니다.'
    }
}

function Get-DuoForgeInteractiveQuestionMenuItemsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Presentation,
        [ValidateRange(1, 3)][int]$MaximumRounds = 2
    )

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($option in @($Presentation.options)) {
        $detailPrefix = if ([bool]$option.isRecommended) { '권장 · 결과: ' } else { '결과: ' }
        $items.Add([ordered]@{
            value = "answer:$([string]$option.internalCode)"
            label = [string]$option.label
            detail = $detailPrefix + [string]$option.outcome
            shortcuts = @([string][int]$option.displayOrdinal, [string]$option.internalCode)
            enabled = $true
        })
    }
    $items.Add([ordered]@{ value = 'other'; label = '다른 방법 보기'; detail = '추가 토론, 조건 입력, 상세 설명과 의견 비교를 선택할 수 있습니다.'; shortcuts = @('M'); enabled = $true })
    $items.Add([ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('Q'); enabled = $true })
    return @($items)
}

function Get-DuoForgeInteractiveQuestionAlternativeMenuItemsInternal {
    [CmdletBinding()]
    param([ValidateRange(1, 3)][int]$MaximumRounds = 2)

    $items = [System.Collections.Generic.List[object]]::new()
    if ($MaximumRounds -lt 3) { $items.Add([ordered]@{ value = 'round'; label = '한 토론 회차 더 진행'; shortcuts = @('R'); enabled = $true }) }
    $items.Add([ordered]@{ value = 'constraint'; label = '추가 조건 직접 입력'; shortcuts = @('F'); enabled = $true })
    $items.Add([ordered]@{ value = 'explain'; label = '관점과 수준을 선택해 상세 설명'; shortcuts = @('E'); enabled = $true })
    $items.Add([ordered]@{ value = 'compare'; label = '양쪽 의견과 장단점 비교'; shortcuts = @('C'); enabled = $true })
    $items.Add([ordered]@{ value = 'back-to-question'; label = '결정 화면으로 돌아가기'; shortcuts = @('Q'); enabled = $true })
    return @($items)
}

function New-DuoForgeInteractiveQuestionCardRowsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Question,
        [Parameter(Mandatory)]$Presentation,
        [ValidateRange(48, 400)][int]$Width,
        [ValidateRange(12, 200)][int]$Height
    )

    $lineWidth = [Math]::Max(20, $Width - 1)
    $estimatedMenuLines = @($Presentation.options).Count + 7
    $budget = [Math]::Max(8, $Height - $estimatedMenuLines)
    $rows = [System.Collections.Generic.List[object]]::new()
    $add = {
        param(
            [string]$Text,
            [string]$Color = '',
            [int]$MaximumLines = 1
        )
        if ($rows.Count -ge $budget) { return }
        $remaining = [Math]::Max(1, $budget - $rows.Count)
        $allowed = [Math]::Min([Math]::Max(1, $MaximumLines), $remaining)
        foreach ($line in @(Split-DuoForgeProgressTextInternal -Text $Text -Width $lineWidth -MaximumLines $allowed)) {
            if ($rows.Count -ge $budget) { break }
            $rows.Add([ordered]@{ text = [string]$line; color = $Color })
        }
    }

    $header = '{0} · {1} · {2}' -f $Question.issueKey, $Presentation.targetLabel, $Presentation.subjectLabel
    & $add $header 'Cyan' 1
    & $add ("[{0}]" -f $Presentation.requestKind) 'Yellow' 1

    if ($Height -le 23) {
        & $add ("현재 · {0}" -f $Presentation.compactCurrentState) '' 1
        & $add ("쟁점 · {0}" -f $Presentation.compactCoreIssue) '' 2
        & $add ("AI 처리 · {0}" -f $Presentation.reviewFlow) '' 2
        & $add ("요청 · {0}" -f $Presentation.requestPrompt) 'Yellow' 1
        & $add ("목적 · {0}" -f $Presentation.requestPurpose) '' 1
    }
    elseif ($Height -le 31) {
        & $add ("현재 · {0}" -f $Presentation.currentState) '' 2
        & $add ("쟁점 · {0}" -f $Presentation.coreIssue) '' 2
        & $add ("AI 처리 · {0}" -f $Presentation.reviewFlow) '' 2
        & $add ("제안 · {0}" -f $Presentation.proposalSummary) '' 2
        & $add ("요청 · {0}" -f $Presentation.requestPrompt) 'Yellow' 2
        & $add ("목적 · {0}" -f $Presentation.requestPurpose) '' 1
    }
    else {
        & $add '현재 상태' 'Cyan' 1
        & $add ("  {0}" -f $Presentation.currentState) '' 2
        & $add '핵심 쟁점' 'Cyan' 1
        & $add ("  {0}" -f $Presentation.coreIssue) '' 2
        & $add 'AI 검토와 문서 처리' 'Cyan' 1
        & $add ("  최초 제기 · {0}" -f $Presentation.originSummary) '' 1
        & $add ("  합의 상태 · {0}" -f $Presentation.aiConsensus) '' 1
        & $add ("  문서 처리 · {0}" -f $Presentation.documentAction) '' 1
        & $add ("  제안 방향 · {0}" -f $Presentation.proposalSummary) '' 2
        & $add '사용자에게 요청하는 것' 'Cyan' 1
        & $add ("  요청 내용 · {0}" -f $Presentation.requestPrompt) 'Yellow' 2
        & $add ("  묻는 목적 · {0}" -f $Presentation.requestPurpose) '' 1
    }

    $reservedForRecommendation = 1
    if ($rows.Count -lt $budget - $reservedForRecommendation -and $Height -ge 24) {
        & $add ("표시 · {0}" -f $Presentation.choiceNotice) 'DarkGray' 1
    }
    if ($rows.Count -lt $budget - $reservedForRecommendation -and $Height -ge 30) {
        $estimatedCost = [string](Get-DuoForgeObjectValue -Object $Question -Name 'estimatedCost' -Default '선택 뒤 관련 단계를 다시 검증합니다.')
        & $add ("영향 · {0}" -f $estimatedCost) '' 1
    }
    if ($rows.Count -ge $budget) { $rows.RemoveAt($rows.Count - 1) }
    & $add ("권장 · {0}" -f $Presentation.recommendedLabel) 'Green' 1
    return @($rows)
}

function Get-DuoForgeInteractivePendingQuestionsInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $pendingPath = Join-Path $RunDirectory 'decisions\pending.json'
    if (-not (Test-Path -LiteralPath $pendingPath -PathType Leaf)) { return @() }
    $pending = Read-DuoForgeJson -Path $pendingPath
    return @(Get-DuoForgeObjectValue -Object $pending -Name 'questions' -Default @())
}

function Invoke-DuoForgeInteractiveQuestion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker
    )

    $readText = { param([string]$Prompt) if ($null -ne $InputReader) { return [string](& $InputReader $Prompt) }; return [string](Read-Host $Prompt) }

    $questions = @(Get-DuoForgeInteractivePendingQuestionsInternal -RunDirectory ([string]$Run.runDirectory))
    if ($questions.Count -eq 0) { Write-Host '답변 대기 중인 질문이 없습니다.'; return }
    $issueLedger = Get-DuoForgeObjectValue -Object $Run -Name 'issues'
    $runIssues = if ($null -ne $issueLedger) { @(Get-DuoForgeObjectValue -Object $issueLedger -Name 'issues' -Default @()) } else { @() }
    $batch = Get-DuoForgePendingQuestionBatchInternal -Questions $questions
    Write-Host ("현재 질문 배치 {0}개, 이 배치 뒤 남은 질문 {1}개" -f $batch.batchSize, $batch.remainingAfterBatch) -ForegroundColor DarkGray
    if ($batch.batchSize -gt 1) {
        $batchItems = [System.Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt $batch.batchSize; $index++) {
            $batchQuestion = $batch.questions[$index]
            $batchIssue = @($runIssues | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'issueId') -eq [string]$batchQuestion.issueKey } | Select-Object -First 1)
            $batchPresentation = Get-DuoForgeInteractiveQuestionPresentationInternal -Question $batchQuestion -Issue $(if ($batchIssue.Count -gt 0) { $batchIssue[0] } else { $null })
            $batchItems.Add([ordered]@{
                value = [string]$index
                label = ('{0} · {1} · {2}' -f $batchQuestion.issueKey, $batchPresentation.targetLabel, $batchPresentation.subjectLabel)
                detail = [string]$batchPresentation.requestKind
                shortcuts = @([string]($index + 1))
                enabled = $true
            })
        }
        $batchItems.Add([ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('0'); enabled = $true })
        $selectedText = Invoke-DuoForgeMenuInternal -Items @($batchItems) -Title '먼저 확인할 요청을 선택해 주세요.' -EscapeValue 'back' -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ($selectedText -eq 'back') { return }
        $question = $batch.questions[[int]$selectedText]
    }
    else {
        $question = $batch.questions[0]
    }
    $issue = @($runIssues | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'issueId') -eq [string]$question.issueKey } | Select-Object -First 1)
    $presentation = Get-DuoForgeInteractiveQuestionPresentationInternal -Question $question -Issue $(if ($issue.Count -gt 0) { $issue[0] } else { $null })
    while ($true) {
        $viewWidth = 100
        $viewHeight = 30
        try {
            $viewWidth = [Math]::Max(48, [Math]::Min(400, [Console]::WindowWidth))
            $viewHeight = [Math]::Max(12, [Math]::Min(200, [Console]::WindowHeight))
        }
        catch { }
        foreach ($row in @(New-DuoForgeInteractiveQuestionCardRowsInternal -Question $question -Presentation $presentation -Width $viewWidth -Height $viewHeight)) {
            $writeParameters = @{ Object = [string]$row.text }
            if (-not [string]::IsNullOrWhiteSpace([string]$row.color)) { $writeParameters.ForegroundColor = [string]$row.color }
            Write-Host @writeParameters
        }
        $questionItems = @(Get-DuoForgeInteractiveQuestionMenuItemsInternal -Presentation $presentation -MaximumRounds ([int]$Run.manifest.maxRounds))
        $choice = Invoke-DuoForgeMenuInternal -Items $questionItems -Title ("{0}: 1안, 2안처럼 번호로 선택해 주세요." -f $presentation.requestKind) -EscapeValue 'back' -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ($choice -eq 'back') { return }
        if ($choice -eq 'other') {
            $alternativeItems = @(Get-DuoForgeInteractiveQuestionAlternativeMenuItemsInternal -MaximumRounds ([int]$Run.manifest.maxRounds))
            $choice = Invoke-DuoForgeMenuInternal -Items $alternativeItems -Title '다른 방법을 선택해 주세요.' -EscapeValue 'back-to-question' -InputReader $InputReader -MenuInvoker $MenuInvoker
            if ($choice -eq 'back-to-question') { continue }
        }
        if ($choice -eq 'round' -and [int]$Run.manifest.maxRounds -lt 3) {
            $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
            $confirmation = ([string](& $readText '최대 토론 회차를 3으로 늘리려면 ROUND를 입력하세요')).Trim()
            if ($confirmation -cne 'ROUND') { Write-Host '추가 토론 회차를 취소했습니다.'; continue }
            $extended = Add-DuoForgeRoundInternal -RunId ([string]$Run.state.runId) -ResultsRoot $resultsRoot
            Write-Host ("3차 토론을 추가했습니다. 새 단계 {0}개를 이어서 진행할 수 있습니다." -f $extended.addedSteps) -ForegroundColor Green
            return
        }
        if ($choice -eq 'constraint') {
            $constraintText = & $readText '두 AI에 적용할 추가 조건'
            $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
            $preview = New-DuoForgeDecisionConstraintPreviewInternal -RunId ([string]$Run.state.runId) -IssueId ([string]$question.issueKey) -Text $constraintText -ResultsRoot $resultsRoot
            Write-Host ("정규화된 제약: {0}" -f $preview.normalizedConstraint)
            Write-Host ("영향 대상: {0}" -f $preview.affectedTarget)
            Write-Host ("적용 방식: {0}" -f $preview.application)
            $confirmation = (Read-Host '이 구조화 미리보기대로 적용하려면 APPLY를 입력하세요').Trim()
            if ($confirmation -cne 'APPLY') { Write-Host '제약 조건 적용을 취소했습니다.'; continue }
            $applied = Set-DuoForgeUserConstraintInternal -RunId ([string]$Run.state.runId) -IssueId ([string]$question.issueKey) -Text $constraintText -ResultsRoot $resultsRoot -Confirm
            Write-Host ("제약 조건을 기록했습니다. 다시 실행할 단계: {0}" -f ($applied.resetSteps -join ', ')) -ForegroundColor Green
            return
        }
        if ($choice -eq 'explain') {
            $request = Read-DuoForgeInteractiveExplanationRequest -InputReader $InputReader -MenuInvoker $MenuInvoker
            if ($null -ne $request) {
                Invoke-DuoForgeInteractiveIssueExplanation -Run $Run -IssueId ([string]$question.issueKey) -Provider ([string]$request.provider) -Level ([string]$request.level) -Focus ([string]$request.focus)
            }
            continue
        }
        if ($choice -eq 'compare') {
            Invoke-DuoForgeInteractiveIssueExplanation -Run $Run -IssueId ([string]$question.issueKey) -Provider both -Level general -Focus tradeoffs
            continue
        }
        $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
        try {
            $answerChoice = if ($choice -like 'answer:*') { $choice.Substring(7) } else { $choice }
            $result = Set-DuoForgeUserDecisionInternal -RunId ([string]$Run.state.runId) -IssueId ([string]$question.issueKey) -Action answer -Choice $answerChoice -ResultsRoot $resultsRoot
            Write-Host ("결정을 기록했습니다. 다시 실행할 단계: {0}" -f ($result.resetSteps -join ', ')) -ForegroundColor Green
            $remainingQuestions = @(Get-DuoForgeInteractivePendingQuestionsInternal -RunDirectory ([string]$Run.runDirectory))
            if ($remainingQuestions.Count -gt 0) {
                Write-Host ("아직 답하지 않은 질문이 {0}개 있습니다. 다음 질문 목록을 이어서 표시합니다. Q를 누르면 나중에 다시 답할 수 있습니다." -f $remainingQuestions.Count) -ForegroundColor Yellow
                Invoke-DuoForgeInteractiveQuestion -Run $Run -InputReader $InputReader -MenuInvoker $MenuInvoker
            }
            else {
                Write-Host '모든 대기 질문에 답했습니다. 이제 작업 계속하기를 선택하면 답변을 반영해 다시 검증합니다.' -ForegroundColor Green
            }
            return
        }
        catch {
            if ([string]$_.Exception.Data['DuoForgeCode'] -eq 'DF-DECISION-CHOICE') {
                Write-Host '올바른 선택지 또는 설명 동작을 선택해 주세요.' -ForegroundColor Yellow
                continue
            }
            throw
        }
    }
}

function Invoke-DuoForgeInteractiveEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker
    )

    $issues = @($Run.issues.issues | Where-Object { [string]$_.resolutionStatus -eq 'AWAITING_EVIDENCE' })
    if ($issues.Count -eq 0) { Write-Host '추가 자료를 기다리는 검토 항목이 없습니다.'; return }
    $items = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $issues.Count; $index++) {
        $detail = if (-not [string]::IsNullOrWhiteSpace([string]$issues[$index].proposal)) { '필요한 자료: ' + [string]$issues[$index].proposal } else { '' }
        $items.Add([ordered]@{ value = [string]$index; label = ('{0} — {1}' -f $issues[$index].issueId, $issues[$index].claim); detail = $detail; shortcuts = @([string]($index + 1)); enabled = $true })
    }
    $items.Add([ordered]@{ value = 'B'; label = '이전으로'; shortcuts = @('B'); enabled = $true })
    $choice = Invoke-DuoForgeMenuInternal -Items @($items) -Title '자료를 추가할 검토 항목을 선택해 주세요.' -EscapeValue 'B' -InputReader $InputReader -MenuInvoker $MenuInvoker
    if ($choice -ieq 'B') { return }
    $issue = $issues[[int]$choice]
    $file = Read-DuoForgePathChoice -Prompt '추가할 Markdown 자료 문서를 선택해 주세요.' -Role 'user-evidence' -Type File -InputReader $InputReader -MenuInvoker $MenuInvoker
    if ($null -eq $file) { return }
    Write-Host ('검토 항목 {0}에 다음 문서를 변경되지 않는 입력 사본으로 추가합니다: {1}' -f $issue.issueId, $file) -ForegroundColor Yellow
    $confirmation = (Read-Host '추가하려면 Y를 입력하세요').Trim()
    if ($confirmation -notin @('Y', 'y')) { Write-Host '근거 추가를 취소했습니다.'; return }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $result = Add-DuoForgeIssueEvidenceInternal -RunId ([string]$Run.state.runId) -IssueId ([string]$issue.issueId) -File $file -ResultsRoot $resultsRoot
    Write-Host ('근거를 {0}로 보존했습니다. 다시 실행할 단계: {1}' -f $result.snapshotName, ($result.resetSteps -join ', ')) -ForegroundColor Green
}

function Invoke-DuoForgeInteractiveDecisionChangeInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker
    )

    $records = @(Read-DuoForgeJsonLines -Path (Join-Path ([string]$Run.runDirectory) 'decisions\user-answers.jsonl') -AllowMissing)
    $decisions = @(Get-DuoForgeEffectiveUserDecisionsInternal -Records $records | Where-Object { [string]$_.action -eq 'ANSWER' })
    if ($decisions.Count -eq 0) { Write-Host '변경할 사용자 결정이 없습니다.'; return }
    $items = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $decisions.Count; $index++) {
        $decisionOptions = @($decisions[$index].questionOptions)
        $selectedIndex = [array]::IndexOf([object[]]$decisionOptions, [object]$decisions[$index].selectedOption)
        $selectedLabel = if ($selectedIndex -ge 0) { '{0}안' -f ($selectedIndex + 1) } else { ConvertTo-DuoForgeProgressTextInternal -Text ([string]$decisions[$index].selectedOption) -MaximumCharacters 80 }
        $items.Add([ordered]@{ value = [string]$index; label = ('{0} · 현재 {1} · 변경 {2}' -f $decisions[$index].issueId, $selectedLabel, $decisions[$index].revision); shortcuts = @([string]($index + 1)); enabled = $true })
    }
    $items.Add([ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('0'); enabled = $true })
    $selection = Invoke-DuoForgeMenuInternal -Items @($items) -Title '변경할 답변을 선택해 주세요.' -EscapeValue 'back' -InputReader $InputReader -MenuInvoker $MenuInvoker
    if ($selection -eq 'back') { return }
    $decision = $decisions[[int]$selection]
    $optionItems = [System.Collections.Generic.List[object]]::new()
    for ($optionIndex = 0; $optionIndex -lt @($decision.questionOptions).Count; $optionIndex++) {
        $letter = [string][char]([int][char]'A' + $optionIndex)
        $rawLabel = ConvertTo-DuoForgeProgressTextInternal -Text ([string]$decision.questionOptions[$optionIndex]) -MaximumCharacters 600
        $prefixPattern = '^\s*' + [regex]::Escape($letter) + '\s*[:：.)-]\s*'
        $displayLabel = [regex]::Replace($rawLabel, $prefixPattern, '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Trim()
        if ([string]::IsNullOrWhiteSpace($displayLabel)) { $displayLabel = $rawLabel }
        if (@($decision.questionOptions).Count -eq 2 -and $optionIndex -eq 0 -and $displayLabel -match '^제안 내용을 반영') { $displayLabel = 'AI가 제안한 수정 방향을 선택' }
        if (@($decision.questionOptions).Count -eq 2 -and $optionIndex -eq 1 -and $displayLabel -match '^현재 요구를 유지') { $displayLabel = '제안을 반영하지 않고 기존 요구를 유지' }
        $optionItems.Add([ordered]@{ value = $letter; label = $displayLabel; detail = ('{0}안으로 변경합니다.' -f ($optionIndex + 1)); shortcuts = @([string]($optionIndex + 1), $letter); enabled = $true })
    }
    $choice = Invoke-DuoForgeMenuInternal -Items @($optionItems) -Title '새 답변을 1안, 2안처럼 번호로 선택해 주세요.' -EscapeValue '' -InputReader $InputReader -MenuInvoker $MenuInvoker
    if ([string]::IsNullOrWhiteSpace([string]$choice)) { return }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    try {
        $changed = Set-DuoForgeUserDecisionInternal -RunId ([string]$Run.state.runId) -IssueId ([string]$decision.issueId) -Action answer -Choice $choice -ResultsRoot $resultsRoot -ReplacePrevious
        Write-Host ("결정을 개정 {0}로 변경했습니다. 다시 실행할 단계: {1}" -f $changed.revision, ($changed.resetSteps -join ', ')) -ForegroundColor Green
    }
    catch {
        if ([string]$_.Exception.Data['DuoForgeCode'] -eq 'DF-DECISION-CHOICE') { Write-Host '올바른 선택지를 입력해 주세요.' -ForegroundColor Yellow; return }
        throw
    }
}

function Invoke-DuoForgeInteractiveRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RunRecord,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker
    )

    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$RunRecord.runDirectory)
    while ($true) {
        $run = ConvertTo-DuoForgeHashtable -InputObject (Get-DuoForgeRunInternal -RunId ([string]$RunRecord.runId) -ResultsRoot $resultsRoot)
        Write-Host ''
        Write-Host ("{0} · {1}" -f $run.manifest.name, (Get-DuoForgeDisplayStateLabelInternal -Status ([string]$run.state.status)))
        Write-Host ("마지막 완료 단계: {0}" -f (Get-DuoForgeDisplayStageLabelInternal -Stage ([string]$run.state.lastCompletedStage)) )
        Write-Host ("남은 검토 항목 {0}개, 진행을 막는 항목 {1}개" -f @($run.state.openIssues).Count, @($run.state.blockingIssues).Count)
        $menuItems = [System.Collections.Generic.List[object]]::new()
        $terminalStates = @('COMPLETED', 'COMPLETED_PARTIAL', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')
        $pendingQuestions = @(Get-DuoForgeInteractivePendingQuestionsInternal -RunDirectory ([string]$run.runDirectory))
        $pendingQuestionCount = $pendingQuestions.Count
        if ($pendingQuestionCount -gt 0 -and [string]$run.state.status -notin $terminalStates) {
            $menuItems.Add([ordered]@{
                value = 'A'
                label = "남은 질문에 답하기 ($pendingQuestionCount)"
                detail = 'AI 작업을 계속하기 전에 남은 결정을 차례로 입력합니다.'
                shortcuts = @('A')
                enabled = $true
            })
        }
        if ([string]$run.state.status -eq 'AWAITING_EVIDENCE') { $menuItems.Add([ordered]@{ value = 'E'; label = '요청된 자료 문서 추가'; shortcuts = @('E'); enabled = $true }) }
        $decisionRecords = @(Read-DuoForgeJsonLines -Path (Join-Path ([string]$run.runDirectory) 'decisions\user-answers.jsonl') -AllowMissing | Where-Object { [string]$_.action -eq 'ANSWER' })
        if ($decisionRecords.Count -gt 0 -and [string]$run.state.status -notin $terminalStates) { $menuItems.Add([ordered]@{ value = 'D'; label = '이전 답변 변경'; shortcuts = @('D'); enabled = $true }) }
        if ([string]$run.state.status -notin @('AWAITING_EVIDENCE') -and [string]$run.state.status -notin $terminalStates) {
            $menuItems.Add([ordered]@{
                value = 'R'
                label = if ($pendingQuestionCount -gt 0) { '작업 계속하기 — 남은 질문 답변 후 가능' } else { '작업 계속하기' }
                shortcuts = @('R')
                enabled = $pendingQuestionCount -eq 0
                disabledReason = if ($pendingQuestionCount -gt 0) { "아직 답하지 않은 질문이 ${pendingQuestionCount}개 있습니다." } else { '' }
            })
        }
        if ([string]$run.state.status -notin @('PAUSED_USER') -and [string]$run.state.status -notin $terminalStates) { $menuItems.Add([ordered]@{ value = 'P'; label = '다음 AI 호출 전 안전 일시정지 요청'; shortcuts = @('P'); enabled = $true }) }
        $menuItems.Add([ordered]@{ value = 'I'; label = '검토 항목 보기'; shortcuts = @('I'); enabled = $true })
        if (Test-Path -LiteralPath (Join-Path ([string]$run.runDirectory) 'final') -PathType Container) { $menuItems.Add([ordered]@{ value = 'O'; label = '결과 폴더 열기'; shortcuts = @('O'); enabled = $true }) }
        $menuItems.Add([ordered]@{ value = 'B'; label = '이전으로'; shortcuts = @('B'); enabled = $true })
        $choice = Invoke-DuoForgeMenuInternal -Items @($menuItems) -Title '다음 동작' -EscapeValue 'B' -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ($choice -ieq 'B') { return }
        if ($choice -ieq 'A' -and $pendingQuestionCount -gt 0 -and [string]$run.state.status -notin $terminalStates) { Invoke-DuoForgeInteractiveQuestion -Run $run -InputReader $InputReader -MenuInvoker $MenuInvoker; continue }
        if ($choice -ieq 'E' -and [string]$run.state.status -eq 'AWAITING_EVIDENCE') { Invoke-DuoForgeInteractiveEvidence -Run $run -InputReader $InputReader -MenuInvoker $MenuInvoker; continue }
        if ($choice -ieq 'D' -and $decisionRecords.Count -gt 0 -and [string]$run.state.status -notin @('COMPLETED', 'COMPLETED_PARTIAL', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')) { Invoke-DuoForgeInteractiveDecisionChangeInternal -Run $run -InputReader $InputReader -MenuInvoker $MenuInvoker; continue }
        if ($choice -ieq 'R' -and $pendingQuestionCount -eq 0 -and [string]$run.state.status -notin @('AWAITING_EVIDENCE') -and [string]$run.state.status -notin $terminalStates) { Invoke-DuoForgeInteractiveLiveResume -Run $run -InputReader $InputReader; continue }
        if ($choice -ieq 'P' -and [string]$run.state.status -notin @('PAUSED_USER', 'COMPLETED', 'COMPLETED_PARTIAL', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')) {
            $pause = Request-DuoForgePauseInternal -RunId ([string]$run.state.runId) -ResultsRoot $resultsRoot
            if ($pause.alreadyRequested) { Write-Host ('이미 일시정지가 요청되어 있습니다: {0}' -f $pause.requestId) }
            else { Write-Host '일시정지를 요청했습니다. 현재 호출이 완료된 뒤 다음 호출 전에 멈춥니다.' -ForegroundColor Green }
            continue
        }
        if ($choice -ieq 'I') { Write-DuoForgeIssueList -Issues @($run.issues.issues); continue }
        if ($choice -ieq 'O') {
            $finalDirectory = Join-Path ([string]$run.runDirectory) 'final'
            if (Test-Path -LiteralPath $finalDirectory -PathType Container) { Start-Process -FilePath 'explorer.exe' -ArgumentList @($finalDirectory); continue }
        }
        Write-Host '올바른 항목을 선택해 주세요.' -ForegroundColor Yellow
    }
}

function Invoke-DuoForgeInteractiveHome {
    [CmdletBinding()]
    param(
        [scriptblock]$SetupInvoker,
        [scriptblock]$RunsInvoker,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker
    )

    $invokeSetup = {
        param([bool]$ShowReadyReport)
        if ($null -ne $SetupInvoker) { return & $SetupInvoker $ShowReadyReport }
        if ($ShowReadyReport) { return Invoke-DuoForgeInteractiveSetup -ShowReadyReport }
        return Invoke-DuoForgeInteractiveSetup
    }
    $setupReport = & $invokeSetup $false
    while ($true) {
        $runs = @(if ($null -ne $RunsInvoker) { & $RunsInvoker } else { Get-DuoForgeRunsInternal })
        $activeCount = @($runs | Where-Object { $_.status -notin @('COMPLETED', 'COMPLETED_PARTIAL', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED') }).Count
        $choice = Invoke-DuoForgeMenuInternal -Title 'DuoForge' -EscapeValue 'Q' -InputReader $InputReader -MenuInvoker $MenuInvoker -Items @(
            [ordered]@{ value = '1'; label = '새 작업 시작'; shortcuts = @('1'); enabled = $true }
            [ordered]@{ value = '2'; label = "진행 중인 작업 보기 ($activeCount)"; shortcuts = @('2'); enabled = $true }
            [ordered]@{ value = '3'; label = '완료된 결과 보기'; shortcuts = @('3'); enabled = $true }
            [ordered]@{ value = '4'; label = '실행 환경 확인, 로그인 및 설정'; shortcuts = @('4'); enabled = $true }
            [ordered]@{ value = 'Q'; label = '종료'; shortcuts = @('Q'); enabled = $true }
        )
        switch -Regex ($choice) {
            '^(1)$' {
                if (-not [bool]$setupReport.readyForDocumentModes) {
                    $setupReport = & $invokeSetup $false
                    if (-not [bool]$setupReport.readyForDocumentModes) { Write-Host '두 구독 실행 환경이 준비되기 전에는 새 작업을 시작할 수 없습니다.' -ForegroundColor Yellow; continue }
                }
                Invoke-DuoForgeInteractiveNew -InputReader $InputReader -MenuInvoker $MenuInvoker
            }
            '^(2|3)$' {
                if ($runs.Count -eq 0) { Write-Host '저장된 실행이 없습니다.'; continue }
                $candidates = if ($choice -eq '2') {
                    @($runs | Where-Object { $_.status -notin @('COMPLETED', 'COMPLETED_PARTIAL', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED') })
                }
                else {
                    @($runs | Where-Object { $_.status -in @('COMPLETED', 'COMPLETED_PARTIAL') })
                }
                $selected = Select-DuoForgeInteractiveRun -Runs $candidates -Prompt '작업을 선택해 주세요.' -InputReader $InputReader -MenuInvoker $MenuInvoker
                if ($null -ne $selected) { Invoke-DuoForgeInteractiveRun -RunRecord $selected -InputReader $InputReader -MenuInvoker $MenuInvoker }
            }
            '^(4)$' {
                $setupReport = & $invokeSetup $true
            }
            '^(Q|q)$' { return }
            default { Write-Host '올바른 항목을 선택해 주세요.' -ForegroundColor Yellow }
        }
    }
}
