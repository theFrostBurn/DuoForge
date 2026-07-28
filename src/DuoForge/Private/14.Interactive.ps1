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
        Write-Host '로그인이 취소되었거나 완료되지 않았습니다. 공급자 CLI가 표시한 URL·기기 코드 흐름을 그대로 사용하거나 수동 명령을 다시 실행해 주세요.' -ForegroundColor Yellow
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
        [scriptblock]$InputReader
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
        Write-Host ''
        if ('codex-login' -in $actions) { Write-Host '[C] Codex 공식 로그인 시작' }
        if ('claude-login' -in $actions) { Write-Host '[A] Claude 공식 로그인 시작' }
        Write-Host '[M] 수동 로그인 명령 보기'
        Write-Host '[R] 다시 검사'
        Write-Host '[B] 홈으로 돌아가기'
        $choice = if ($null -ne $InputReader) { [string](& $InputReader '선택') } else { Read-Host '선택' }
        $choice = $choice.Trim()
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
        [ordered]@{ key = '1'; mode = 'shared-document'; label = '컨셉으로 공동 문서 만들기'; enabled = $true; disabledReason = $null }
        [ordered]@{ key = '2'; mode = 'document-merge'; label = '두 문서를 하나로 합의하기'; enabled = $true; disabledReason = $null }
        [ordered]@{ key = '3'; mode = 'dual-document'; label = '두 문서를 각각 개선하기'; enabled = $true; disabledReason = $null }
        [ordered]@{ key = '4'; mode = 'dual-project-audit'; label = '두 프로젝트 비교하기'; enabled = $false; disabledReason = 'DF-PREFLIGHT-3A-ISOLATION: Windows 격리 게이트가 범위 밖 읽기와 자식 프로세스 차단을 증명하지 못했습니다.' }
    )
}

function Invoke-DuoForgeInteractiveNew {
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host '무엇을 하시겠습니까?'
    $modeOptions = @(Get-DuoForgeInteractiveNewModeOptionsInternal)
    foreach ($option in $modeOptions) {
        $suffix = if ([bool]$option.enabled) { '' } else { ' — 비활성화' }
        Write-Host ("[{0}] {1}{2}" -f [string]$option.key, [string]$option.label, $suffix)
    }
    Write-Host '[B] 이전으로'
    $choice = (Read-Host '선택').Trim()
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
        $brief = Read-DuoForgePathChoice -Prompt '입력 Markdown 문서를 선택해 주세요.' -Role 'shared-brief' -Type File
        if ($null -eq $brief) { return }
        $selections = Complete-DuoForgeInteractiveProviderSelectionsInternal
        if ($null -eq $selections) { Write-Host '모델 선택을 취소했습니다.'; return }
        $request = New-DuoForgeStartRequestInternal -Mode 'shared-document' -Brief $brief -DocumentType 'custom' -MaxRounds 2 `
            -CodexModel ([string]$selections.codex.model) -CodexReasoningEffort ([string]$selections.codex.reasoningEffort) `
            -ClaudeModel ([string]$selections.claude.model) -ClaudeReasoningEffort ([string]$selections.claude.reasoningEffort)
    }
    elseif ($choice -in @('2', '3')) {
        $documentA = Read-DuoForgePathChoice -Prompt '문서 A의 주요 Markdown 파일을 선택해 주세요.' -Role 'document-a' -Type File
        if ($null -eq $documentA) { return }
        $documentB = Read-DuoForgePathChoice -Prompt '문서 B의 주요 Markdown 파일을 선택해 주세요.' -Role 'document-b' -Type File
        if ($null -eq $documentB) { return }
        $selections = Complete-DuoForgeInteractiveProviderSelectionsInternal
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
    $confirmation = (Read-Host '스냅샷과 실행 기록을 만들까요? [Y/N]').Trim()
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
        [Parameter(Mandatory)][string]$Prompt
    )

    if ($Runs.Count -eq 0) { Write-Host '해당 실행이 없습니다.'; return $null }
    Write-Host ''
    for ($index = 0; $index -lt $Runs.Count; $index++) {
        $run = $Runs[$index]
        Write-Host ("[{0}] {1} | {2} | {3}" -f ($index + 1), $run.name, $run.mode, $run.status)
    }
    Write-Host '[B] 이전으로'
    $choice = (Read-Host $Prompt).Trim()
    if ($choice -ieq 'B') { return $null }
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $Runs.Count) {
        Write-Host '올바른 실행 번호를 선택해 주세요.' -ForegroundColor Yellow
        return $null
    }
    return $Runs[$number - 1]
}

function Invoke-DuoForgeInteractiveLiveResume {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Run)

    $budget = Get-DuoForgeRemainingCallBudget -RunDirectory ([string]$Run.runDirectory)
    $selections = Get-DuoForgeRunProviderSelectionsInternal -RunDirectory ([string]$Run.runDirectory)
    Write-Host '선택한 스냅샷 내용이 Codex와 Claude에 전송됩니다.' -ForegroundColor Yellow
    Write-DuoForgeProviderSelectionSummary -ProviderSelections $selections
    Write-Host ("Codex 추가 호출 최악: {0}, Claude 추가 호출 최악: {1}" -f $budget.providers.codex.maximumAdditionalCalls, $budget.providers.claude.maximumAdditionalCalls) -ForegroundColor Yellow
    $confirmation = (Read-Host '실제 공급자 호출을 시작하려면 LIVE를 입력하세요').Trim()
    if ($confirmation -cne 'LIVE') { Write-Host '라이브 실행을 취소했습니다.'; return }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $null = Invoke-DuoForgeResumeWithProgressInternal -RunId ([string]$Run.state.runId) -ResultsRoot $resultsRoot -WaitForAcknowledgement
}

function Read-DuoForgeInteractiveExplanationRequest {
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host '어느 관점의 설명이 필요하십니까?'
    Write-Host '[1] Codex 관점'
    Write-Host '[2] Claude 관점'
    Write-Host '[3] 양쪽 관점 비교'
    Write-Host '[B] 이전으로'
    $providerChoice = (Read-Host '선택').Trim()
    if ($providerChoice -ieq 'B') { return $null }
    $provider = switch ($providerChoice) { '1' { 'codex' } '2' { 'claude' } '3' { 'both' } default { $null } }
    if ($null -eq $provider) { Write-Host '올바른 관점을 선택해 주세요.' -ForegroundColor Yellow; return $null }

    Write-Host ''
    Write-Host '설명 수준을 선택해 주세요.'
    Write-Host '[1] 초급 - 전문용어를 풀어 설명'
    Write-Host '[2] 일반 - 실무 결정 중심'
    Write-Host '[3] 전문가 - 전제와 실패 조건까지 상세히'
    Write-Host '[B] 이전으로'
    $levelChoice = (Read-Host '선택').Trim()
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
    Write-Host ('쟁점 {0}에 {1} 관점, {2} 수준의 설명을 요청합니다.' -f $IssueId, $Provider, $Level) -ForegroundColor Yellow
    Write-DuoForgeProviderSelectionSummary -ProviderSelections $Run.manifest.providerSelections
    Write-Host ('이번 호출 {0}회, 실행 전체 잔여 설명 예산 {1}회' -f $requiredCalls, $existing.budget.remaining) -ForegroundColor Yellow
    $confirmation = (Read-Host '실제 설명 호출을 시작하려면 LIVE를 입력하세요').Trim()
    if ($confirmation -cne 'LIVE') { Write-Host '설명 호출을 취소했습니다.'; return }
    $result = Invoke-DuoForgeIssueExplanationInternal -RunId ([string]$Run.state.runId) -IssueId $IssueId -Provider $Provider -Level $Level -Focus $Focus -ResultsRoot $resultsRoot -LiveConsent $true
    Write-DuoForgeExplanationRecords -Records @($result.explanations)
    Write-Host ('설명 호출 예산: 사용 {0}/{1}, 남음 {2}' -f $result.budget.used, $result.budget.maximum, $result.budget.remaining)
}

function Invoke-DuoForgeInteractiveQuestion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Run)

    $pending = Read-DuoForgeJson -Path (Join-Path ([string]$Run.runDirectory) 'decisions\pending.json')
    $questions = @($pending.questions)
    if ($questions.Count -eq 0) { Write-Host '답변 대기 중인 질문이 없습니다.'; return }
    $batch = Get-DuoForgePendingQuestionBatchInternal -Questions $questions
    Write-Host ("현재 질문 배치 {0}개, 이 배치 뒤 남은 질문 {1}개" -f $batch.batchSize, $batch.remainingAfterBatch) -ForegroundColor DarkGray
    if ($batch.batchSize -gt 1) {
        for ($index = 0; $index -lt $batch.batchSize; $index++) {
            Write-Host ("[{0}] {1} — {2}" -f ($index + 1), $batch.questions[$index].issueKey, $batch.questions[$index].title)
        }
        $selectedNumber = 0
        $selectedText = (Read-Host '먼저 답할 질문 번호').Trim()
        if (-not [int]::TryParse($selectedText, [ref]$selectedNumber) -or $selectedNumber -lt 1 -or $selectedNumber -gt $batch.batchSize) {
            Write-Host '현재 배치의 질문 번호를 선택해 주세요.' -ForegroundColor Yellow
            return
        }
        $question = $batch.questions[$selectedNumber - 1]
    }
    else {
        $question = $batch.questions[0]
    }
    while ($true) {
        Write-Host ''
        Write-Host ("{0} — {1}" -f $question.issueKey, $question.title)
        Write-Host ("지금 결정하는 이유: {0}" -f $question.reasonNow)
        Write-Host ("쉬운 설명: {0}" -f $question.plainExplanation)
        Write-Host ("Codex 의견: {0}" -f $question.codexOpinion)
        Write-Host ("Claude 의견: {0}" -f $question.claudeOpinion)
        Write-Host ("예상 비용: {0} | 되돌리기: {1} | 권고 신뢰도: {2}" -f $question.estimatedCost, $question.reversibility, $question.confidence)
        Write-Host ("보류 영향: {0}" -f $question.impactIfDeferred)
        Write-Host ([string]$question.question)
        for ($index = 0; $index -lt @($question.options).Count; $index++) {
            Write-Host ("[{0}] {1}" -f [char]([int][char]'A' + $index), $question.options[$index])
        }
        Write-Host ("권장안: {0}" -f $question.recommendedOption)
        if ([int]$Run.manifest.maxRounds -lt 3) { Write-Host '[R] 한 라운드 더 토론' }
        Write-Host '[F] 자유 입력 제약 조건 미리보기'
        Write-Host '[E] 관점과 수준을 선택해 상세 설명'
        Write-Host '[C] 양쪽 의견과 장단점 비교'
        Write-Host '[Q] 이전으로'
        $choice = (Read-Host '선택').Trim()
        if ($choice -ieq 'Q') { return }
        if ($choice -ieq 'R' -and [int]$Run.manifest.maxRounds -lt 3) {
            $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
            $confirmation = (Read-Host '최대 라운드를 3으로 늘리려면 ROUND를 입력하세요').Trim()
            if ($confirmation -cne 'ROUND') { Write-Host '추가 라운드를 취소했습니다.'; continue }
            $extended = Add-DuoForgeRoundInternal -RunId ([string]$Run.state.runId) -ResultsRoot $resultsRoot
            Write-Host ("3라운드를 추가했습니다. 새 단계 {0}개를 재개할 수 있습니다." -f $extended.addedSteps) -ForegroundColor Green
            return
        }
        if ($choice -ieq 'F') {
            $constraintText = Read-Host '두 공급자에 적용할 새 제약 조건'
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
        if ($choice -ieq 'E') {
            $request = Read-DuoForgeInteractiveExplanationRequest
            if ($null -ne $request) {
                Invoke-DuoForgeInteractiveIssueExplanation -Run $Run -IssueId ([string]$question.issueKey) -Provider ([string]$request.provider) -Level ([string]$request.level) -Focus ([string]$request.focus)
            }
            continue
        }
        if ($choice -ieq 'C') {
            Invoke-DuoForgeInteractiveIssueExplanation -Run $Run -IssueId ([string]$question.issueKey) -Provider both -Level general -Focus tradeoffs
            continue
        }
        $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
        try {
            $result = Set-DuoForgeUserDecisionInternal -RunId ([string]$Run.state.runId) -IssueId ([string]$question.issueKey) -Action answer -Choice $choice -ResultsRoot $resultsRoot
            Write-Host ("결정을 기록했습니다. 다시 실행할 단계: {0}" -f ($result.resetSteps -join ', ')) -ForegroundColor Green
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
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Run)

    $issues = @($Run.issues.issues | Where-Object { [string]$_.resolutionStatus -eq 'AWAITING_EVIDENCE' })
    if ($issues.Count -eq 0) { Write-Host '추가 근거를 기다리는 쟁점이 없습니다.'; return }
    Write-Host ''
    Write-Host '근거를 추가할 쟁점을 선택해 주세요.'
    for ($index = 0; $index -lt $issues.Count; $index++) {
        Write-Host ('[{0}] {1} — {2}' -f ($index + 1), $issues[$index].issueId, $issues[$index].claim)
        if (-not [string]::IsNullOrWhiteSpace([string]$issues[$index].proposal)) { Write-Host ('    필요한 근거: {0}' -f $issues[$index].proposal) }
    }
    Write-Host '[B] 이전으로'
    $choice = (Read-Host '쟁점 번호').Trim()
    if ($choice -ieq 'B') { return }
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $issues.Count) {
        Write-Host '올바른 쟁점 번호를 선택해 주세요.' -ForegroundColor Yellow
        return
    }
    $issue = $issues[$number - 1]
    $file = Read-DuoForgePathChoice -Prompt '추가할 Markdown 근거 문서를 선택해 주세요.' -Role 'user-evidence' -Type File
    if ($null -eq $file) { return }
    Write-Host ('쟁점 {0}에 다음 문서를 불변 스냅샷으로 추가합니다: {1}' -f $issue.issueId, $file) -ForegroundColor Yellow
    $confirmation = (Read-Host '추가하려면 Y를 입력하세요').Trim()
    if ($confirmation -notin @('Y', 'y')) { Write-Host '근거 추가를 취소했습니다.'; return }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $result = Add-DuoForgeIssueEvidenceInternal -RunId ([string]$Run.state.runId) -IssueId ([string]$issue.issueId) -File $file -ResultsRoot $resultsRoot
    Write-Host ('근거를 {0}로 보존했습니다. 다시 실행할 단계: {1}' -f $result.snapshotName, ($result.resetSteps -join ', ')) -ForegroundColor Green
}

function Invoke-DuoForgeInteractiveDecisionChangeInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Run)

    $records = @(Read-DuoForgeJsonLines -Path (Join-Path ([string]$Run.runDirectory) 'decisions\user-answers.jsonl') -AllowMissing)
    $decisions = @(Get-DuoForgeEffectiveUserDecisionsInternal -Records $records | Where-Object { [string]$_.action -eq 'ANSWER' })
    if ($decisions.Count -eq 0) { Write-Host '변경할 사용자 결정이 없습니다.'; return }
    Write-Host ''
    Write-Host '변경할 결정을 선택해 주세요.'
    for ($index = 0; $index -lt $decisions.Count; $index++) {
        Write-Host ("[{0}] {1} | 현재: {2} | 개정 {3}" -f ($index + 1), $decisions[$index].issueId, $decisions[$index].selectedOption, $decisions[$index].revision)
    }
    Write-Host '[B] 이전으로'
    $selection = (Read-Host '결정 번호').Trim()
    if ($selection -ieq 'B') { return }
    $number = 0
    if (-not [int]::TryParse($selection, [ref]$number) -or $number -lt 1 -or $number -gt $decisions.Count) {
        Write-Host '올바른 결정 번호를 선택해 주세요.' -ForegroundColor Yellow
        return
    }
    $decision = $decisions[$number - 1]
    for ($optionIndex = 0; $optionIndex -lt @($decision.questionOptions).Count; $optionIndex++) {
        Write-Host ("[{0}] {1}" -f [char]([int][char]'A' + $optionIndex), $decision.questionOptions[$optionIndex])
    }
    $choice = (Read-Host '새 선택').Trim()
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
    param([Parameter(Mandatory)]$RunRecord)

    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$RunRecord.runDirectory)
    while ($true) {
        $run = ConvertTo-DuoForgeHashtable -InputObject (Get-DuoForgeRunInternal -RunId ([string]$RunRecord.runId) -ResultsRoot $resultsRoot)
        Write-Host ''
        Write-Host ("{0} | {1}" -f $run.manifest.name, $run.state.status)
        Write-Host ("마지막 완료 단계: {0}" -f $run.state.lastCompletedStage)
        Write-Host ("열린 쟁점 {0}개, 차단 쟁점 {1}개" -f @($run.state.openIssues).Count, @($run.state.blockingIssues).Count)
        if ([string]$run.state.status -eq 'AWAITING_USER') { Write-Host '[A] 질문에 답하기' }
        if ([string]$run.state.status -eq 'AWAITING_EVIDENCE') { Write-Host '[E] 요청된 근거 문서 추가' }
        $decisionRecords = @(Read-DuoForgeJsonLines -Path (Join-Path ([string]$run.runDirectory) 'decisions\user-answers.jsonl') -AllowMissing | Where-Object { [string]$_.action -eq 'ANSWER' })
        if ($decisionRecords.Count -gt 0 -and [string]$run.state.status -notin @('COMPLETED', 'COMPLETED_PARTIAL', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')) { Write-Host '[D] 이전 결정 변경' }
        if ([string]$run.state.status -notin @('AWAITING_EVIDENCE', 'COMPLETED', 'COMPLETED_PARTIAL', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')) { Write-Host '[R] 라이브 실행/재개' }
        if ([string]$run.state.status -notin @('PAUSED_USER', 'COMPLETED', 'COMPLETED_PARTIAL', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')) { Write-Host '[P] 다음 호출 전 일시정지 요청' }
        Write-Host '[I] 쟁점 보기'
        if (Test-Path -LiteralPath (Join-Path ([string]$run.runDirectory) 'final') -PathType Container) { Write-Host '[O] 결과 폴더 열기' }
        Write-Host '[B] 이전으로'
        $choice = (Read-Host '선택').Trim()
        if ($choice -ieq 'B') { return }
        if ($choice -ieq 'A' -and [string]$run.state.status -eq 'AWAITING_USER') { Invoke-DuoForgeInteractiveQuestion -Run $run; continue }
        if ($choice -ieq 'E' -and [string]$run.state.status -eq 'AWAITING_EVIDENCE') { Invoke-DuoForgeInteractiveEvidence -Run $run; continue }
        if ($choice -ieq 'D' -and $decisionRecords.Count -gt 0 -and [string]$run.state.status -notin @('COMPLETED', 'COMPLETED_PARTIAL', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')) { Invoke-DuoForgeInteractiveDecisionChangeInternal -Run $run; continue }
        if ($choice -ieq 'R' -and [string]$run.state.status -notin @('AWAITING_EVIDENCE', 'COMPLETED', 'COMPLETED_PARTIAL', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')) { Invoke-DuoForgeInteractiveLiveResume -Run $run; continue }
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
    param()

    $setupReport = Invoke-DuoForgeInteractiveSetup
    while ($true) {
        $runs = @(Get-DuoForgeRunsInternal)
        $activeCount = @($runs | Where-Object { $_.status -notin @('COMPLETED', 'COMPLETED_PARTIAL', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED') }).Count
        Write-Host ''
        Write-Host 'DuoForge'
        Write-Host ''
        Write-Host '[1] 새 작업 시작'
        Write-Host ("[2] 진행 중인 작업 보기 ($activeCount)")
        Write-Host '[3] 완료된 결과 보기'
        Write-Host '[4] 환경 진단, 로그인 및 설정'
        Write-Host '[Q] 종료'
        $choice = (Read-Host '선택').Trim()
        switch -Regex ($choice) {
            '^(1)$' {
                if (-not [bool]$setupReport.readyForDocumentModes) {
                    $setupReport = Invoke-DuoForgeInteractiveSetup
                    if (-not [bool]$setupReport.readyForDocumentModes) { Write-Host '두 구독 실행 환경이 준비되기 전에는 새 작업을 시작할 수 없습니다.' -ForegroundColor Yellow; continue }
                }
                Invoke-DuoForgeInteractiveNew
            }
            '^(2|3)$' {
                if ($runs.Count -eq 0) { Write-Host '저장된 실행이 없습니다.'; continue }
                $candidates = if ($choice -eq '2') {
                    @($runs | Where-Object { $_.status -notin @('COMPLETED', 'COMPLETED_PARTIAL', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED') })
                }
                else {
                    @($runs | Where-Object { $_.status -in @('COMPLETED', 'COMPLETED_PARTIAL') })
                }
                $selected = Select-DuoForgeInteractiveRun -Runs $candidates -Prompt '실행 번호'
                if ($null -ne $selected) { Invoke-DuoForgeInteractiveRun -RunRecord $selected }
            }
            '^(4)$' {
                $setupReport = Invoke-DuoForgeInteractiveSetup -ShowReadyReport
            }
            '^(Q|q)$' { return }
            default { Write-Host '올바른 항목을 선택해 주세요.' -ForegroundColor Yellow }
        }
    }
}
