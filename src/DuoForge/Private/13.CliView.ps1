function Write-DuoForgeHelp {
    [CmdletBinding()]
    param()
    $layout = Get-DuoForgeDisplayLayoutInternal
    $rows = [System.Collections.Generic.List[object]]::new()
    $append = { param([object[]]$Block) foreach ($row in @($Block)) { $rows.Add($row) } }
    & $append @(New-DuoForgePageHeaderRowsInternal -Title 'DuoForge 도움말' -Layout $layout)
    & $append @(New-DuoForgeSectionRowsInternal -Title '기본 사용' -Body '' -Layout $layout -First)
    & $append @(New-DuoForgeListRowsInternal -Items @(
        'duoforge',
        'duoforge doctor [--json]',
        'duoforge start shared-document --brief <파일> --codex-model <모델> --codex-effort <단계> --claude-model <모델> --claude-effort <단계> [--pause-after-round] [--allow-partial] [--plan-only]',
        'duoforge start document-merge --document-a <파일> --document-b <파일> --codex-model <모델> --codex-effort <단계> --claude-model <모델> --claude-effort <단계> [--pause-after-round] [--allow-partial] [--plan-only]',
        'duoforge start dual-document --document-a <파일> --document-b <파일> --codex-model <모델> --codex-effort <단계> --claude-model <모델> --claude-effort <단계> [--pause-after-round] [--allow-partial] [--plan-only]',
        'duoforge status --run <실행 ID> [--workspace <폴더>] [--json]',
        'duoforge list [--workspace <폴더>] [--json]'
    ) -Layout $layout)
    & $append @(New-DuoForgeSectionRowsInternal -Title '고급 명령' -Body '' -Layout $layout)
    & $append @(New-DuoForgeListRowsInternal -Items @(
        'duoforge issues --run <실행 ID> [--workspace <폴더>] [--json]',
        'duoforge explain --run <실행 ID> --issue <쟁점 ID> [--provider codex|claude|both] [--level beginner|general|expert] [--focus general|evidence|examples|tradeoffs|experiment] [--live]',
        'duoforge evidence --run <실행 ID> --issue <쟁점 ID> --file <Markdown 파일> [--workspace <폴더>]',
        'duoforge answer --run <실행 ID> --issue <쟁점 ID> --choice <번호> [--replace] [--workspace <폴더>]',
        'duoforge constraint --run <실행 ID> --issue <쟁점 ID> --text <제약 조건> [--confirm] [--workspace <폴더>]',
        'duoforge extend-round --run <실행 ID> [--workspace <폴더>]',
        'duoforge defer --run <실행 ID> --issue <쟁점 ID> [--workspace <폴더>] [--confirm-partial]',
        'duoforge pause --run <실행 ID> [--workspace <폴더>]',
        'duoforge resume --run <실행 ID> [--workspace <폴더>] [--live]',
        'duoforge abandon --run <실행 ID> [--workspace <폴더>] [--confirm-abandon]',
        'duoforge restore --run <실행 ID> [--workspace <폴더>] [--confirm-restore]',
        'duoforge recover --run <실행 ID> [--workspace <폴더>]',
        'duoforge delete --run <실행 ID> [--workspace <폴더>] [--confirm-delete]'
    ) -Layout $layout)
    & $append @(New-DuoForgeSectionRowsInternal -Title '분석 깊이' -Body '' -Layout $layout)
    & $append @(New-DuoForgeFieldRowsInternal -Label 'Codex' -Value 'low, medium, high, xhigh, max, ultra' -Layout $layout -KeyWidth 8)
    & $append @(New-DuoForgeFieldRowsInternal -Label 'Claude' -Value 'low, medium, high, xhigh, max' -Layout $layout -KeyWidth 8)
    & $append @(New-DuoForgeSectionRowsInternal -Title '안전 확인' -Body '' -Layout $layout)
    & $append @(New-DuoForgeListRowsInternal -Items @(
        'API 키 인증은 사용하지 않습니다.',
        '새 작업마다 Codex와 Claude의 모델과 분석 깊이를 명시적으로 선택합니다.',
        'AI 작업 전 입력 문서, 전송 범위와 최대 요청 횟수를 확인합니다.',
        '프로젝트 비교는 현재 Windows에서 안전을 충분히 확인하지 못해 사용할 수 없습니다.'
    ) -Layout $layout)
    & $append @(New-DuoForgeSectionRowsInternal -Title '호환 입력' -Body '' -Layout $layout)
    & $append @(New-DuoForgeListRowsInternal -Items @(
        '문서 모드의 --codex와 --claude는 각각 --document-a와 --document-b로 정규화되며 사용 중단 예정 경고가 표시됩니다.',
        'answer의 --choice는 화면과 같은 1, 2, 3 번호를 권장하며 기존 A, B, C 입력도 같은 내부 선택으로 처리합니다.'
    ) -Layout $layout)
    Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
}

function Write-DuoForgeDoctorReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Report)

    $layout = Get-DuoForgeDisplayLayoutInternal
    $rows = [System.Collections.Generic.List[object]]::new()
    $append = { param([object[]]$Block) foreach ($row in @($Block)) { $rows.Add($row) } }
    & $append @(New-DuoForgePageHeaderRowsInternal -Title 'DuoForge 실행 환경 확인' -Layout $layout)
    & $append @(New-DuoForgeSectionRowsInternal -Title '환경' -Body '' -Layout $layout -First)
    & $append @(New-DuoForgeFieldRowsInternal -Label 'PowerShell' -Value ('{0} · {1}' -f $Report.powershell.version, $(if ($Report.powershell.ready) { '정상' } else { '차단' })) -Layout $layout -KeyWidth 12)
    & $append @(New-DuoForgeSectionRowsInternal -Title 'AI 구독 실행 상태' -Body '' -Layout $layout)
    foreach ($provider in @('codex', 'claude')) {
        $item = $Report.providers[$provider]
        $displayName = if ($provider -eq 'codex') { 'Codex' } else { 'Claude' }
        $kind = if ($item.status -eq 'READY_DOCUMENTS') { 'success' } else { 'error' }
        & $append @(New-DuoForgeNoticeRowsInternal -Kind $kind -Title ("{0} · {1}" -f $displayName, $(if ($item.status -eq 'READY_DOCUMENTS') { '문서 작업 준비' } else { '확인 필요' })) -Message ("버전 {0} · 로그인 방식 {1} · 문서 작업 기능 {2}" -f $item.version, $item.authType, $(if ([bool]$item.documentProfileSupported) { '지원' } else { '미지원' })) -Layout $layout)
    }
    & $append @(New-DuoForgeSectionRowsInternal -Title '안전 확인' -Body '' -Layout $layout)
    if ($Report.apiCredentialConflicts.Count -gt 0) {
        & $append @(New-DuoForgeNoticeRowsInternal -Kind error -Title 'API용 로그인 설정이 발견되어 문서 작업을 시작할 수 없습니다.' -Message ('확인된 설정 이름: {0}. 값은 읽거나 표시하지 않았습니다.' -f ($Report.apiCredentialConflicts -join ', ')) -NextAction '환경을 안전하게 정리한 뒤 다시 검사해 주세요.' -Layout $layout)
    }
    else {
        & $append @(New-DuoForgeNoticeRowsInternal -Kind success -Title '문서 작업을 방해하는 API용 로그인 설정이 없습니다.' -Layout $layout)
    }
    & $append @(New-DuoForgeFieldRowsInternal -Label '문서 작업' -Value $(if ($Report.readyForDocumentModes) { '준비됨' } else { '준비되지 않음' }) -Layout $layout -KeyWidth 14)
    & $append @(New-DuoForgeFieldRowsInternal -Label '프로젝트 비교' -Value '준비 중 · 현재 Windows에서는 안전을 충분히 확인하지 못함' -Layout $layout -KeyWidth 14)
    if (@($Report.recommendations).Count -gt 0) {
        & $append @(New-DuoForgeSectionRowsInternal -Title '다음 행동' -Body '' -Layout $layout)
        & $append @(New-DuoForgeListRowsInternal -Items @($Report.recommendations) -Layout $layout)
    }
    Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
}

function New-DuoForgeProviderSelectionRowsInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ProviderSelections, [Parameter(Mandatory)][System.Collections.IDictionary]$Layout)

    $null = Assert-DuoForgeProviderSelectionsInternal -Selections $ProviderSelections
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($provider in @('codex', 'claude')) {
        $options = Get-DuoForgeProviderSelectionOptionsInternal -Provider $provider
        $selection = Get-DuoForgeObjectValue -Object $ProviderSelections -Name $provider
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label ([string]$options.displayName) -Value ('모델 {0} · 분석 깊이 {1}' -f $selection.model, (Get-DuoForgeDisplayReasoningEffortLabelInternal -ReasoningEffort ([string]$selection.reasoningEffort))) -Layout $Layout -KeyWidth 8)) { $rows.Add($row) }
    }
    return @($rows)
}

function Write-DuoForgeProviderSelectionSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ProviderSelections)

    $layout = Get-DuoForgeDisplayLayoutInternal
    Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeProviderSelectionRowsInternal -ProviderSelections $ProviderSelections -Layout $layout) -Layout $layout
}

function Format-DuoForgeRemainingCallBudgetLineInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProviderLabel,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ProviderBudget
    )

    $scheduled = [int](Get-DuoForgeObjectValue -Object $ProviderBudget -Name 'scheduledCallsRemaining' -Default ([int]$ProviderBudget.plannedRemaining))
    $retry = [int](Get-DuoForgeObjectValue -Object $ProviderBudget -Name 'failureRetryCallsRemaining' -Default ([Math]::Max(0, [int]$ProviderBudget.maximumPlannedAdditionalCalls - $scheduled)))
    $maximum = [int]$ProviderBudget.maximumPlannedAdditionalCalls
    $retryText = if ($retry -eq 0) { '실패 시 추가 요청 없음' } else { "실패 시 추가 요청 최대 ${retry}회" }
    return (('남은 작업 {0}개 · 예정 요청 {1}회' -f [int]$ProviderBudget.plannedRemaining, $scheduled) + [Environment]::NewLine + ('{0} · 모두 합쳐 최대 {1}회' -f $retryText, $maximum))
}

function Write-DuoForgeExecutionPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Validation)

    $layout = Get-DuoForgeDisplayLayoutInternal
    $rows = [System.Collections.Generic.List[object]]::new()
    $append = { param([object[]]$Block) foreach ($row in @($Block)) { $rows.Add($row) } }
    & $append @(New-DuoForgePageHeaderRowsInternal -Title '작업 시작 전 확인' -Tag '계획 확인' -Layout $layout)
    & $append @(New-DuoForgeSectionRowsInternal -Title '작업' -Body '' -Layout $layout -First)
    & $append @(New-DuoForgeFieldRowsInternal -Label '작업 방식' -Value (Get-DuoForgeDisplayModeLabelInternal -Mode ([string]$Validation.request.mode)) -Layout $layout -KeyWidth 18)
    & $append @(New-DuoForgeFieldRowsInternal -Label '토론 회차' -Value ("{0}회" -f $Validation.request.maxRounds) -Layout $layout -KeyWidth 18)
    & $append @(New-DuoForgeFieldRowsInternal -Label '실행 시간 상한' -Value ("{0}분" -f (Get-DuoForgeConfig).limits.maxWallClockMinutes) -Layout $layout -KeyWidth 18)
    & $append @(New-DuoForgeFieldRowsInternal -Label '회차별 일시정지' -Value $(if ([bool](Get-DuoForgeObjectValue -Object $Validation.request -Name 'pauseAfterRound' -Default $false)) { '사용' } else { '사용 안 함' }) -Layout $layout -KeyWidth 18)
    & $append @(New-DuoForgeFieldRowsInternal -Label '결과 저장 위치' -Value ([string]$Validation.resultsRoot) -Layout $layout -KeyWidth 18)
    & $append @(New-DuoForgeSectionRowsInternal -Title '입력' -Body '' -Layout $layout)
    if ($Validation.request.mode -eq 'shared-document') {
        & $append @(New-DuoForgeFieldRowsInternal -Label '주 입력' -Value ('{0} · {1}' -f $Validation.inputs.primary.path, (Format-DuoForgeByteSize -Bytes $Validation.inputs.primary.bytes)) -Layout $layout -KeyWidth 10)
    }
    elseif ($Validation.request.mode -in @('document-merge', 'dual-document')) {
        foreach ($documentId in @('A', 'B')) {
            $context = $Validation.inputs.documents[$documentId].context
            & $append @(New-DuoForgeFieldRowsInternal -Label ("문서 $documentId") -Value ('{0} · 참고 파일 {1}개 / {2}' -f $Validation.inputs.documents[$documentId].primary.path, $context.includedFiles, (Format-DuoForgeByteSize -Bytes $context.includedBytes)) -Layout $layout -KeyWidth 10)
        }
    }
    $contextPlan = Get-DuoForgeObjectValue -Object $Validation -Name 'contextPlan'
    if ($null -ne $contextPlan -and [bool](Get-DuoForgeObjectValue -Object $contextPlan -Name 'enabled' -Default $false)) {
        & $append @(New-DuoForgeFieldRowsInternal -Label '읽을 수 있는 파일' -Value ('전체 파일의 {0}%' -f $contextPlan.predictedFileCoveragePercent) -Layout $layout -KeyWidth 18)
        & $append @(New-DuoForgeFieldRowsInternal -Label '읽을 수 있는 분량' -Value ('전체 문서 분량의 {0}%' -f $contextPlan.predictedByteCoveragePercent) -Layout $layout -KeyWidth 18)
        if ([bool]$contextPlan.requiresPartialConsent) { & $append @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '일부 내용만 분석합니다.' -Message '결과는 일부 범위만 완료된 것으로 표시됩니다.' -Layout $layout) }
    }
    & $append @(New-DuoForgeSectionRowsInternal -Title '사용할 AI 설정' -Body '' -Layout $layout)
    & $append @(New-DuoForgeProviderSelectionRowsInternal -ProviderSelections $Validation.request.providerSelections -Layout $layout)
    & $append @(New-DuoForgeSectionRowsInternal -Title '예상 AI 요청 횟수' -Body '' -Layout $layout)
    foreach ($provider in @('codex', 'claude')) {
        $providerPlan = $Validation.executionPlan.providers[$provider]
        $providerLabel = if ($provider -eq 'codex') { 'Codex' } else { 'Claude' }
        & $append @(New-DuoForgeFieldRowsInternal -Label $providerLabel -Value ('예정 요청 {0}회 · 실패 시 추가 요청 최대 {1}회 · 최대 {2}회' -f $providerPlan.baseCalls, $providerPlan.retryBudget, $providerPlan.maximumCalls) -Layout $layout -KeyWidth 8)
    }
    & $append @(New-DuoForgeSectionRowsInternal -Title '전송과 다음 단계' -Body '' -Layout $layout)
    foreach ($warning in @($Validation.warnings)) {
        & $append @(New-DuoForgeNoticeRowsInternal -Kind warning -Title ([string]$warning.message) -Code ([string]$warning.code) -Layout $layout)
    }
    & $append @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '선택한 문서 내용은 Codex와 Claude에 전송될 수 있습니다.' -Message '지금은 작업 시작 때 사용할 문서 사본과 작업 기록만 만들며 AI 작업은 시작하지 않습니다.' -NextAction 'AI 작업은 나중에 문서 전송 범위와 최대 요청 횟수를 다시 확인한 뒤 시작합니다.' -Layout $layout)
    Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
}

function Write-DuoForgeIssueList {
    [CmdletBinding()]
    param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Issues)

    $layout = Get-DuoForgeDisplayLayoutInternal
    if ($Issues.Count -eq 0) {
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '확인할 내용이 없습니다.' -Layout $layout) -Layout $layout
        return
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @(New-DuoForgePageHeaderRowsInternal -Title '확인할 내용' -Tag ("{0}개" -f $Issues.Count) -Layout $layout)) { $rows.Add($row) }
    for ($index = 0; $index -lt $Issues.Count; $index++) {
        $issue = $Issues[$index]
        $issueId = [string](Get-DuoForgeObjectValue -Object $issue -Name 'issueId')
        $severity = Get-DuoForgeDisplaySeverityLabelInternal -Severity ([string](Get-DuoForgeObjectValue -Object $issue -Name 'severity'))
        $blocking = if ([bool](Get-DuoForgeObjectValue -Object $issue -Name 'blocking' -Default $false)) { '예' } else { '아니요' }
        $status = Get-DuoForgeDisplayIssueStatusLabelInternal -Status ([string](Get-DuoForgeObjectValue -Object $issue -Name 'resolutionStatus'))
        $claim = [string](Get-DuoForgeObjectValue -Object $issue -Name 'claim')
        foreach ($row in @(New-DuoForgeSectionRowsInternal -Title ("{0} · {1}" -f $issueId, $status) -Body '' -Layout $layout -First:($index -eq 0))) { $rows.Add($row) }
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '중요도' -Value $severity -Layout $layout -KeyWidth 10)) { $rows.Add($row) }
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '진행 전 해결 필요' -Value $blocking -Layout $layout -KeyWidth 18)) { $rows.Add($row) }
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '내용' -Value $claim -Layout $layout -KeyWidth 10 -PreserveParagraphs)) { $rows.Add($row) }
    }
    Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
}

function Write-DuoForgeExplanationRecords {
    [CmdletBinding()]
    param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Records)

    $layout = Get-DuoForgeDisplayLayoutInternal
    if ($Records.Count -eq 0) {
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '저장된 설명이 없습니다.' -Layout $layout) -Layout $layout
        return
    }
    for ($recordIndex = 0; $recordIndex -lt $Records.Count; $recordIndex++) {
        $record = $Records[$recordIndex]
        $result = $record.result
        $rows = [System.Collections.Generic.List[object]]::new()
        $append = { param([object[]]$Block) foreach ($row in @($Block)) { $rows.Add($row) } }
        & $append @(New-DuoForgePageHeaderRowsInternal -Title ("{0} · 검토 설명" -f $record.issueId) -Tag ("{0} · {1} · {2}" -f $record.provider, $record.level, $record.focus) -Layout $layout)
        & $append @(New-DuoForgeSectionRowsInternal -Title '요약' -Body ([string]$result.summary) -Layout $layout -First -PreserveParagraphs)
        & $append @(New-DuoForgeSectionRowsInternal -Title '설명' -Body ([string]$result.explanation) -Layout $layout -PreserveParagraphs)
        if (@($result.existingEvidence).Count -gt 0) {
            & $append @(New-DuoForgeSectionRowsInternal -Title '기존 입력 근거' -Body '' -Layout $layout)
            & $append @(New-DuoForgeListRowsInternal -Items @($result.existingEvidence) -Layout $layout)
        }
        if (@($result.newClaims).Count -gt 0) {
            & $append @(New-DuoForgeSectionRowsInternal -Title '새 주장 또는 가정' -Body '' -Layout $layout)
            foreach ($item in @($result.newClaims)) {
                & $append @(New-DuoForgeFieldRowsInternal -Label ([string]$item.status) -Value ("{0} · 근거 {1}" -f $item.claim, $item.basis) -Layout $layout -KeyWidth 14 -PreserveParagraphs)
            }
        }
        if (@($result.tradeoffs).Count -gt 0) {
            & $append @(New-DuoForgeSectionRowsInternal -Title '선택지 비교' -Body '' -Layout $layout)
            $tradeoffs = @($result.tradeoffs)
            for ($tradeoffIndex = 0; $tradeoffIndex -lt $tradeoffs.Count; $tradeoffIndex++) {
                $item = $tradeoffs[$tradeoffIndex]
                if ($tradeoffIndex -gt 0) { $rows.Add((New-DuoForgeDisplayRowInternal -Text '' -Role 'spacer')) }
                & $append @(New-DuoForgeTextRowsInternal -Text ([string]$item.option) -Layout $layout -Indent 2 -Role 'warning' -PreserveParagraphs)
                & $append @(New-DuoForgeFieldRowsInternal -Label '장점' -Value (@($item.benefits) -join ', ') -Layout $layout -Indent 4 -KeyWidth 10 -PreserveParagraphs)
                & $append @(New-DuoForgeFieldRowsInternal -Label '비용' -Value (@($item.costs) -join ', ') -Layout $layout -Indent 4 -KeyWidth 10 -PreserveParagraphs)
                & $append @(New-DuoForgeFieldRowsInternal -Label '위험' -Value (@($item.risks) -join ', ') -Layout $layout -Indent 4 -KeyWidth 10 -PreserveParagraphs)
                & $append @(New-DuoForgeFieldRowsInternal -Label '되돌리기' -Value ([string]$item.reversibility) -Layout $layout -Indent 4 -KeyWidth 10 -PreserveParagraphs)
            }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$result.suggestedExperiment)) {
            & $append @(New-DuoForgeSectionRowsInternal -Title '검증 실험 제안' -Body ([string]$result.suggestedExperiment) -Layout $layout -PreserveParagraphs)
        }
        Write-DuoForgeDisplayRowsInternal -Rows @(Add-DuoForgeTrailingSpacerRowInternal -Rows @($rows)) -Layout $layout
    }
}

function Write-DuoForgeValidationErrors {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Validation)

    $layout = Get-DuoForgeDisplayLayoutInternal
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind error -Title '요청을 시작할 수 없습니다.' -Message '입력과 실행 조건을 확인한 뒤 다시 시도해 주세요.' -Layout $layout)) { $rows.Add($row) }
    if (@($Validation.errors).Count -gt 0) {
        foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '확인할 내용' -Body '' -Layout $layout)) { $rows.Add($row) }
    }
    $errors = @($Validation.errors)
    for ($errorIndex = 0; $errorIndex -lt $errors.Count; $errorIndex++) {
        $errorItem = $errors[$errorIndex]
        if ($errorIndex -gt 0) { $rows.Add((New-DuoForgeDisplayRowInternal -Text '' -Role 'spacer')) }
        foreach ($row in @(New-DuoForgeTextRowsInternal -Text ([string]$errorItem.message) -Layout $layout -Indent 2 -Role 'error' -PreserveParagraphs)) { $rows.Add($row) }
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '오류 코드' -Value ([string]$errorItem.code) -Layout $layout -Indent 4 -KeyWidth 12 -Role 'meta')) { $rows.Add($row) }
    }
    Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
}
