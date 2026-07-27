function Invoke-DuoForgeGuidedLogin {
    [CmdletBinding()]
    param([ValidateSet('codex', 'claude')][string]$Provider)

    if (-not (Test-DuoForgeInteractiveHost)) {
        throw (New-DuoForgeException -Code 'DF-AUTH-NONINTERACTIVE' -Message '비대화형 환경에서는 로그인 프로세스를 시작하지 않습니다.')
    }

    if ($Provider -eq 'codex') {
        Write-Host 'Codex 공식 브라우저 로그인을 시작합니다. DuoForge는 인증 정보나 코드를 입력받지 않습니다.'
        & codex login
    }
    else {
        Write-Host 'Claude 공식 브라우저 로그인을 시작합니다. DuoForge는 인증 정보나 코드를 입력받지 않습니다.'
        & claude auth login
    }
    Write-DuoForgeDoctorReport -Report (Invoke-DuoForgeDoctorInternal)
}

function Invoke-DuoForgeInteractiveNew {
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host '무엇을 하시겠습니까?'
    Write-Host '[1] 하나의 문서를 함께 검토하고 완성'
    Write-Host '[2] 두 문서를 서로 비교하여 각각 개선'
    Write-Host '[B] 이전으로'
    Write-Host '프로젝트 비교(3A)는 안전 격리 검증 전까지 표시하지 않습니다.' -ForegroundColor DarkYellow
    $choice = (Read-Host '선택').Trim()
    if ($choice -ieq 'B') { return }

    if ($choice -eq '1') {
        $brief = Read-DuoForgePathChoice -Prompt '입력 Markdown 문서를 선택해 주세요.' -Role 'shared-brief' -Type File
        if ($null -eq $brief) { return }
        $request = New-DuoForgeStartRequestInternal -Mode 'shared-document' -Brief $brief -DocumentType 'custom' -MaxRounds 2
    }
    elseif ($choice -eq '2') {
        $codexDocument = Read-DuoForgePathChoice -Prompt 'Codex 측 Markdown 문서를 선택해 주세요.' -Role 'codex-document' -Type File
        if ($null -eq $codexDocument) { return }
        $claudeDocument = Read-DuoForgePathChoice -Prompt 'Claude 측 Markdown 문서를 선택해 주세요.' -Role 'claude-document' -Type File
        if ($null -eq $claudeDocument) { return }
        $request = New-DuoForgeStartRequestInternal -Mode 'dual-document' -CodexDocument $codexDocument -ClaudeDocument $claudeDocument -DocumentType 'custom' -MaxRounds 2
    }
    else {
        Write-Host '올바른 항목을 선택해 주세요.' -ForegroundColor Yellow
        return
    }

    $validation = Test-DuoForgeStartRequestInternal -Request $request
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
    Write-Host '선택한 스냅샷 내용이 Codex와 Claude에 전송됩니다.' -ForegroundColor Yellow
    Write-Host ("Codex 추가 호출 최악: {0}, Claude 추가 호출 최악: {1}" -f $budget.providers.codex.maximumAdditionalCalls, $budget.providers.claude.maximumAdditionalCalls) -ForegroundColor Yellow
    $confirmation = (Read-Host '실제 공급자 호출을 시작하려면 LIVE를 입력하세요').Trim()
    if ($confirmation -cne 'LIVE') { Write-Host '라이브 실행을 취소했습니다.'; return }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $result = Invoke-DuoForgeResumeLiveInternal -RunId ([string]$Run.state.runId) -ResultsRoot $resultsRoot -LiveConsent $true
    Write-Host ("실행 상태: {0}, 이번 호출 단계: {1}" -f $result.status, $result.invoked)
}

function Invoke-DuoForgeInteractiveQuestion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Run)

    $pending = Read-DuoForgeJson -Path (Join-Path ([string]$Run.runDirectory) 'decisions\pending.json')
    $questions = @($pending.questions)
    if ($questions.Count -eq 0) { Write-Host '답변 대기 중인 질문이 없습니다.'; return }
    $question = $questions[0]
    Write-Host ''
    Write-Host ("{0} — {1}" -f $question.issueKey, $question.title)
    Write-Host ([string]$question.question)
    for ($index = 0; $index -lt @($question.options).Count; $index++) {
        Write-Host ("[{0}] {1}" -f [char]([int][char]'A' + $index), $question.options[$index])
    }
    Write-Host ("권장안: {0}" -f $question.recommendedOption)
    Write-Host '[B] 이전으로'
    $choice = (Read-Host '선택').Trim()
    if ($choice -ieq 'B') { return }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $result = Set-DuoForgeUserDecisionInternal -RunId ([string]$Run.state.runId) -IssueId ([string]$question.issueKey) -Action answer -Choice $choice -ResultsRoot $resultsRoot
    Write-Host ("결정을 기록했습니다. 다시 실행할 단계: {0}" -f ($result.resetSteps -join ', ')) -ForegroundColor Green
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
        if ([string]$run.state.status -notin @('COMPLETED', 'COMPLETED_PARTIAL', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')) { Write-Host '[R] 라이브 실행/재개' }
        Write-Host '[I] 쟁점 보기'
        if (Test-Path -LiteralPath (Join-Path ([string]$run.runDirectory) 'final') -PathType Container) { Write-Host '[O] 결과 폴더 열기' }
        Write-Host '[B] 이전으로'
        $choice = (Read-Host '선택').Trim()
        if ($choice -ieq 'B') { return }
        if ($choice -ieq 'A' -and [string]$run.state.status -eq 'AWAITING_USER') { Invoke-DuoForgeInteractiveQuestion -Run $run; continue }
        if ($choice -ieq 'R' -and [string]$run.state.status -notin @('COMPLETED', 'COMPLETED_PARTIAL', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')) { Invoke-DuoForgeInteractiveLiveResume -Run $run; continue }
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
            '^(1)$' { Invoke-DuoForgeInteractiveNew }
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
                $report = Invoke-DuoForgeDoctorInternal
                Write-DuoForgeDoctorReport -Report $report
                if (-not $report.providers.codex.subscription) { Write-Host '[C] Codex 로그인 시작' }
                if (-not $report.providers.claude.subscription) { Write-Host '[A] Claude 로그인 시작' }
                $loginChoice = (Read-Host '[Enter] 홈으로').Trim()
                if ($loginChoice -ieq 'C') { Invoke-DuoForgeGuidedLogin -Provider codex }
                elseif ($loginChoice -ieq 'A') { Invoke-DuoForgeGuidedLogin -Provider claude }
            }
            '^(Q|q)$' { return }
            default { Write-Host '올바른 항목을 선택해 주세요.' -ForegroundColor Yellow }
        }
    }
}
