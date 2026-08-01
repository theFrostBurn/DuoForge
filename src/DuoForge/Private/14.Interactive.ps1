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
        Write-DuoForgeTextInternal '로그인이 취소되었거나 완료되지 않았습니다. Codex 또는 Claude CLI가 표시한 URL·기기 코드 흐름을 그대로 사용하거나 수동 명령을 다시 실행해 주세요.' -ForegroundColor Yellow
    }
    elseif ([string]$outcome.status -eq 'AUTH_NOT_CONFIRMED') {
        Write-DuoForgeTextInternal '로그인 명령은 끝났지만 구독 인증을 확인하지 못했습니다. 수동 명령을 확인한 뒤 다시 검사해 주세요.' -ForegroundColor Yellow
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
        throw (New-DuoForgeException -Code 'DF-AUTH-CONTEXT' -Message '현재 분리된 실행 환경에서는 브라우저 로그인을 시작하지 않습니다. 일반 PowerShell 7 창에서 다시 실행해 주세요.')
    }
    if ($Provider -eq 'codex') {
        Write-DuoForgeTextInternal 'Codex 공식 브라우저 로그인을 시작합니다. DuoForge는 인증 정보나 코드를 입력받지 않습니다.'
    }
    else {
        Write-DuoForgeTextInternal 'Claude 공식 브라우저 로그인을 시작합니다. DuoForge는 인증 정보나 코드를 입력받지 않습니다.'
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
        $layout = Get-DuoForgeDisplayLayoutInternal
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '환경과 구독 로그인을 확인하고 있습니다.' -Layout $layout) -Layout $layout
        if ($null -eq $setupReport) {
            $setupReport = if ($null -ne $DoctorInvoker) { & $DoctorInvoker } else { Invoke-DuoForgeDoctorInternal }
        }
        if ([bool]$setupReport.readyForDocumentModes) {
            if ($ShowReadyReport) { Write-DuoForgeDoctorReport -Report $setupReport }
            else { Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title 'Codex와 Claude 구독 실행 환경이 준비되었습니다.' -Layout $layout) -Layout $layout }
            return $setupReport
        }

        Write-DuoForgeDoctorReport -Report $setupReport
        $actions = @(Get-DuoForgeInteractiveSetupActionsInternal -Report $setupReport)
        $menuItems = [System.Collections.Generic.List[object]]::new()
        if ('codex-login' -in $actions) { $menuItems.Add([ordered]@{ value = 'C'; label = 'Codex 공식 로그인 시작'; shortcuts = @('C'); enabled = $true }) }
        if ('claude-login' -in $actions) { $menuItems.Add([ordered]@{ value = 'A'; label = 'Claude 공식 로그인 시작'; shortcuts = @('A'); enabled = $true }) }
        $menuItems.Add([ordered]@{ value = 'M'; label = '수동 로그인 명령 보기'; shortcuts = @('M'); enabled = $true })
        $menuItems.Add([ordered]@{ value = 'R'; label = '다시 검사'; shortcuts = @('R'); enabled = $true })
        $menuItems.Add([ordered]@{ value = 'back'; label = '홈으로 돌아가기'; shortcuts = @('B'); enabled = $true })
        Write-DuoForgeDisplaySpacerInternal -Layout $layout
        $choiceInteraction = Invoke-DuoForgeMenuInteractionInternal -Items @($menuItems) -Title '실행 환경 복구' -ReturnTarget home -CancelReturnTarget home -InterruptReturnTarget home -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ([string]$choiceInteraction.action -ne 'submit') { return $setupReport }
        $choice = [string]$choiceInteraction.value
        if ($choice -ieq 'C' -and 'codex-login' -in $actions) { $setupReport = (Invoke-DuoForgeGuidedLogin -Provider codex -CurrentReport $setupReport).postReport; continue }
        if ($choice -ieq 'A' -and 'claude-login' -in $actions) { $setupReport = (Invoke-DuoForgeGuidedLogin -Provider claude -CurrentReport $setupReport).postReport; continue }
        if ($choice -ieq 'M') {
            $commandRows = [System.Collections.Generic.List[object]]::new()
            foreach ($row in @(New-DuoForgePageHeaderRowsInternal -Title '수동 로그인 명령' -Layout $layout)) { $commandRows.Add($row) }
            foreach ($row in @(New-DuoForgeSectionRowsInternal -Title 'AI별 로그인 명령' -Body '' -Layout $layout -First)) { $commandRows.Add($row) }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label 'Codex' -Value 'codex login' -Layout $layout -KeyWidth 14)) { $commandRows.Add($row) }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label 'Claude' -Value 'claude auth login' -Layout $layout -KeyWidth 14)) { $commandRows.Add($row) }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '로그인 확인' -Value 'codex login status / claude auth status' -Layout $layout -KeyWidth 14)) { $commandRows.Add($row) }
            Write-DuoForgeDisplayRowsInternal -Rows @($commandRows) -Layout $layout
            continue
        }
        if ($choice -ieq 'R') { $setupReport = $null; continue }
        Write-DuoForgeTextInternal '현재 가능한 항목을 선택해 주세요.' -ForegroundColor Yellow
    }
}

function Get-DuoForgeInteractiveNewModeOptionsInternal {
    [CmdletBinding()]
    param()

    return @(
        [ordered]@{ key = '1'; value = '1'; shortcuts = @('1'); mode = 'shared-document'; label = '요구사항으로 공동 문서 만들기'; enabled = $true; disabledReason = $null }
        [ordered]@{ key = '2'; value = '2'; shortcuts = @('2'); mode = 'document-merge'; label = '두 문서를 비교해 하나의 합의안 만들기'; enabled = $true; disabledReason = $null }
        [ordered]@{ key = '3'; value = '3'; shortcuts = @('3'); mode = 'dual-document'; label = '두 문서를 각각 개선하기'; enabled = $true; disabledReason = $null }
        [ordered]@{ key = '4'; value = '4'; shortcuts = @('4'); mode = 'dual-project-audit'; label = '두 프로젝트 비교하기 · 준비 중'; enabled = $false; disabledReason = '현재 Windows에서는 프로젝트 밖 파일 접근을 막는 안전 기능을 충분히 확인하지 못해 사용할 수 없습니다.' }
    )
}

function Invoke-DuoForgeRunCreationBoundaryInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Validation,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget = 'parent',
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$CancelReturnTarget = 'home',
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $CancelReturnTarget,
        [scriptblock]$InputReader,
        [scriptblock]$RunInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    $interaction = Read-DuoForgeYesNoConfirmationInternal -Prompt '선택한 문서를 작업 폴더에 복사하고 새 작업을 만들까요?' -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
    if ([string]$interaction.action -ne 'submit') {
        return [ordered]@{ interaction = $interaction; run = $null }
    }
    $run = if ($null -ne $RunInvoker) { & $RunInvoker $Validation } else { New-DuoForgeRunInternal -ValidationResult $Validation }
    return [ordered]@{ interaction = $interaction; run = $run }
}

function Invoke-DuoForgeEvidenceBoundaryInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [Parameter(Mandatory)][string]$IssueId,
        [Parameter(Mandatory)][string]$File,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget = 'parent',
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$CancelReturnTarget = 'work-menu',
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $CancelReturnTarget,
        [scriptblock]$InputReader,
        [scriptblock]$EvidenceInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    $interaction = Read-DuoForgeYesNoConfirmationInternal -Prompt '선택한 자료를 이 작업에 연결할까요?' -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
    if ([string]$interaction.action -ne 'submit') {
        return [ordered]@{ interaction = $interaction; result = $null }
    }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $result = if ($null -ne $EvidenceInvoker) {
        & $EvidenceInvoker ([string]$Run.state.runId) $IssueId $File $resultsRoot
    }
    else {
        Add-DuoForgeIssueEvidenceInternal -RunId ([string]$Run.state.runId) -IssueId $IssueId -File $File -ResultsRoot $resultsRoot
    }
    return [ordered]@{ interaction = $interaction; result = $result }
}

function Invoke-DuoForgeInteractiveNew {
    [CmdletBinding()]
    param(
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker,
        [scriptblock]$ValidationInvoker,
        [scriptblock]$RunInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    while ($true) {
    $modeOptions = @(Get-DuoForgeInteractiveNewModeOptionsInternal)
    $modeItems = @($modeOptions) + @([ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('B'); enabled = $true })
    $choiceInteraction = Invoke-DuoForgeMenuInteractionInternal -Items $modeItems -Title '무엇을 하시겠습니까?' -ReturnTarget home -CancelReturnTarget home -InterruptReturnTarget home -InputReader $InputReader -MenuInvoker $MenuInvoker
    if ([string]$choiceInteraction.action -ne 'submit') { return $choiceInteraction }
    $choice = [string]$choiceInteraction.value

    $selectedOption = @($modeOptions | Where-Object { [string]$_.key -eq $choice }) | Select-Object -First 1
    if ($null -eq $selectedOption) {
        Write-DuoForgeTextInternal '올바른 항목을 선택해 주세요.' -ForegroundColor Yellow
        return
    }
    if (-not [bool]$selectedOption.enabled) {
        $layout = Get-DuoForgeDisplayLayoutInternal
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '이 작업 방식은 아직 사용할 수 없습니다.' -Message ([string]$selectedOption.disabledReason) -NextAction '문서 전송이나 AI 작업을 시작하지 않고 이전 화면으로 돌아갑니다.' -Layout $layout) -Layout $layout
        return
    }

    if ($choice -eq '1') {
        $brief = Read-DuoForgePathChoice -Prompt '입력 Markdown 문서를 선택해 주세요.' -Role 'shared-brief' -Type File -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ($null -eq $brief) { return }
        $selections = Complete-DuoForgeInteractiveProviderSelectionsInternal -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ($null -eq $selections) { Write-DuoForgeTextInternal '모델 선택을 취소했습니다.'; return }
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
        if ($null -eq $selections) { Write-DuoForgeTextInternal '모델 선택을 취소했습니다.'; return }
        $request = New-DuoForgeStartRequestInternal -Mode ([string]$selectedOption.mode) -DocumentA $documentA -DocumentB $documentB -DocumentType 'custom' -MaxRounds 2 `
            -CodexModel ([string]$selections.codex.model) -CodexReasoningEffort ([string]$selections.codex.reasoningEffort) `
            -ClaudeModel ([string]$selections.claude.model) -ClaudeReasoningEffort ([string]$selections.claude.reasoningEffort)
    }

    $validation = Test-DuoForgeStartRequestInternal -Request $request
    $partialConfirmation = Confirm-DuoForgeInteractivePartialAnalysisInternal -Validation $validation -ReturnTarget parent -CancelReturnTarget home -InterruptReturnTarget home -InputReader $InputReader -ValidationInvoker $ValidationInvoker -ConfirmationKeyReader $ConfirmationKeyReader -ConfirmationFrameWriter $ConfirmationFrameWriter -ConfirmationCapabilityProbe $ConfirmationCapabilityProbe
    $validation = $partialConfirmation.validation
    if ($null -ne $partialConfirmation.interaction -and [string]$partialConfirmation.interaction.action -ne 'submit') {
        if ([string]$partialConfirmation.interaction.action -eq 'back' -and [string]$partialConfirmation.interaction.returnTarget -eq 'parent') { continue }
        return $partialConfirmation.interaction
    }
    if (-not $validation.valid) {
        Write-DuoForgeValidationErrors -Validation $validation
        return
    }
    Write-DuoForgeExecutionPlan -Validation $validation
    $creation = Invoke-DuoForgeRunCreationBoundaryInternal -Validation $validation -ReturnTarget parent -CancelReturnTarget home -InterruptReturnTarget home -InputReader $InputReader -RunInvoker $RunInvoker -ConfirmationKeyReader $ConfirmationKeyReader -ConfirmationFrameWriter $ConfirmationFrameWriter -ConfirmationCapabilityProbe $ConfirmationCapabilityProbe
    if ([string]$creation.interaction.action -eq 'back' -and [string]$creation.interaction.returnTarget -eq 'parent') { continue }
    if ([string]$creation.interaction.action -ne 'submit') {
        Write-DuoForgeTextInternal '취소했습니다. 문서 사본과 작업 기록을 만들지 않았습니다.'
        return
    }
    $run = $creation.run
    $layout = Get-DuoForgeDisplayLayoutInternal
    Write-DuoForgeDisplayRowsInternal -Rows @(
        New-DuoForgeNoticeRowsInternal -Kind success -Title '새 작업을 만들었습니다.' -Message '원본과 분리된 문서 사본과 작업 기록을 만들었습니다. AI 작업은 아직 시작하지 않았습니다.' -Layout $layout
        New-DuoForgeFieldRowsInternal -Label '작업 ID' -Value ([string]$run.runId) -Layout $layout -KeyWidth 10 -Role 'meta'
        New-DuoForgeFieldRowsInternal -Label '경로' -Value ([string]$run.runDirectory) -Layout $layout -KeyWidth 10 -Role 'meta'
    ) -Layout $layout
    return
    }
}

function Confirm-DuoForgeInteractivePartialAnalysisInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Validation,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget = 'parent',
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$CancelReturnTarget = $ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $CancelReturnTarget,
        [scriptblock]$InputReader,
        [scriptblock]$ValidationInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    $partialErrors = @($Validation.errors | Where-Object { [string]$_.code -eq 'DF-PARTIAL-CONSENT-REQUIRED' })
    $otherErrors = @($Validation.errors | Where-Object { [string]$_.code -ne 'DF-PARTIAL-CONSENT-REQUIRED' })
    if ($partialErrors.Count -eq 0 -or $otherErrors.Count -gt 0) {
        return [ordered]@{ validation = $Validation; interaction = $null; requiresConfirmation = $false }
    }
    $layout = Get-DuoForgeDisplayLayoutInternal
    Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '문서 전체를 읽을 수 없습니다.' -Message ([string]$partialErrors[0].message) -NextAction '문서 일부만 읽은 결과로 진행해도 될 때만 확인어 PARTIAL을 입력해 주세요.' -Code 'DF-PARTIAL-CONSENT-REQUIRED' -Layout $layout) -Layout $layout
    $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'PARTIAL' -Prompt '문서 일부만 읽은 결과에 동의하면 PARTIAL을 입력하세요' -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
    if ([string]$confirmation.action -ne 'submit') {
        return [ordered]@{ validation = $Validation; interaction = $confirmation; requiresConfirmation = $true }
    }
    $Validation.request.allowPartial = $true
    $revalidated = if ($null -ne $ValidationInvoker) {
        & $ValidationInvoker $Validation.request $Validation.doctor
    }
    else {
        Test-DuoForgeStartRequestInternal -Request $Validation.request -DoctorReport $Validation.doctor
    }
    return [ordered]@{ validation = $revalidated; interaction = $confirmation; requiresConfirmation = $true }
}

function Select-DuoForgeInteractiveRun {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Runs,
        [Parameter(Mandatory)][string]$Prompt,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker
    )

    if ($Runs.Count -eq 0) { Write-DuoForgeTextInternal '해당 실행이 없습니다.'; return $null }
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
    $items.Add([ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('B'); enabled = $true })
    $choiceInteraction = Invoke-DuoForgeMenuInteractionInternal -Items @($items) -Title $Prompt -ReturnTarget home -CancelReturnTarget home -InterruptReturnTarget home -InputReader $InputReader -MenuInvoker $MenuInvoker
    if ([string]$choiceInteraction.action -ne 'submit') { return $null }
    $choice = [string]$choiceInteraction.value
    return $Runs[[int]$choice]
}

function Invoke-DuoForgeInteractiveLiveResume {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [scriptblock]$InputReader,
        [scriptblock]$ResumeInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    $budget = Get-DuoForgeRemainingCallBudget -RunDirectory ([string]$Run.runDirectory)
    $selections = Get-DuoForgeRunProviderSelectionsInternal -RunDirectory ([string]$Run.runDirectory)
    $layout = Get-DuoForgeDisplayLayoutInternal
    $confirmationRows = [System.Collections.Generic.List[object]]::new()
    $blockedWorkItems = [int]$budget.providers.codex.blockedWorkItems + [int]$budget.providers.claude.blockedWorkItems
    if ($blockedWorkItems -gt 0) {
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind error -Title '계속할 수 없는 AI 작업이 있습니다.' -Message ("허용된 요청 횟수를 모두 사용한 작업이 ${blockedWorkItems}개 있습니다.") -NextAction '오류 내용을 확인한 뒤 해당 작업을 다시 준비해 주세요.' -Layout $layout) -Layout $layout
        return
    }
    foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title 'Codex와 Claude에 문서를 보내 작업을 계속하려고 합니다.' -Message '작업 시작 때 보관한 문서와 이후 추가한 자료·답변·조건이 두 AI에 전송됩니다.' -NextAction '아래 설정과 최대 요청 횟수를 확인한 뒤 확인어 LIVE를 입력해 주세요.' -Layout $layout)) { $confirmationRows.Add($row) }
    foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '사용할 AI 설정' -Body '' -Layout $layout)) { $confirmationRows.Add($row) }
    foreach ($row in @(New-DuoForgeProviderSelectionRowsInternal -ProviderSelections $selections -Layout $layout)) { $confirmationRows.Add($row) }
    foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '계속하면 실행되는 AI 작업' -Body '' -Layout $layout)) { $confirmationRows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label 'Codex' -Value (Format-DuoForgeRemainingCallBudgetLineInternal -ProviderLabel 'Codex' -ProviderBudget $budget.providers.codex) -Layout $layout -KeyWidth 8 -Role 'warning' -PreserveParagraphs)) { $confirmationRows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label 'Claude' -Value (Format-DuoForgeRemainingCallBudgetLineInternal -ProviderLabel 'Claude' -ProviderBudget $budget.providers.claude) -Layout $layout -KeyWidth 8 -Role 'warning' -PreserveParagraphs)) { $confirmationRows.Add($row) }
    Write-DuoForgeDisplayRowsInternal -Rows @($confirmationRows) -Layout $layout
    $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'LIVE' -Prompt '문서 전송과 AI 작업 시작에 동의하면 LIVE를 입력하세요' -ReturnTarget work-menu -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
    if ([string]$confirmation.action -ne 'submit') {
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title 'AI 작업을 시작하지 않았습니다.' -Message '재개, 공급자 호출 또는 실행 기록 변경이 발생하지 않았습니다.' -Layout $layout) -Layout $layout
        return $confirmation
    }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $result = if ($null -ne $ResumeInvoker) {
        & $ResumeInvoker ([string]$Run.state.runId) $resultsRoot $true
    }
    else {
        Invoke-DuoForgeResumeWithProgressInternal -RunId ([string]$Run.state.runId) -ResultsRoot $resultsRoot -WaitForAcknowledgement -ReturnTarget work-menu
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

    while ($true) {
        $providerInteraction = Invoke-DuoForgeMenuInteractionInternal -Title '어느 관점의 설명이 필요하십니까?' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -MenuInvoker $MenuInvoker -Items @(
            [ordered]@{ value = '1'; label = 'Codex 관점'; shortcuts = @('1'); enabled = $true }
            [ordered]@{ value = '2'; label = 'Claude 관점'; shortcuts = @('2'); enabled = $true }
            [ordered]@{ value = '3'; label = '양쪽 관점 비교'; shortcuts = @('3'); enabled = $true }
            [ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('B'); enabled = $true }
        )
        if ([string]$providerInteraction.action -ne 'submit') { return [ordered]@{ kind = 'interaction'; interaction = $providerInteraction } }
        $provider = switch ([string]$providerInteraction.value) { '1' { 'codex' } '2' { 'claude' } '3' { 'both' } default { $null } }
        if ($null -eq $provider) { continue }

        $levelInteraction = Invoke-DuoForgeMenuInteractionInternal -Title '설명 수준을 선택해 주세요.' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -MenuInvoker $MenuInvoker -Items @(
            [ordered]@{ value = '1'; label = '초급 - 전문용어를 풀어 설명'; shortcuts = @('1'); enabled = $true }
            [ordered]@{ value = '2'; label = '일반 - 실무 결정 중심'; shortcuts = @('2'); enabled = $true }
            [ordered]@{ value = '3'; label = '전문가 - 전제와 실패 조건까지 상세히'; shortcuts = @('3'); enabled = $true }
            [ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('B'); enabled = $true }
        )
        if ([string]$levelInteraction.action -eq 'back') { continue }
        if ([string]$levelInteraction.action -ne 'submit') { return [ordered]@{ kind = 'interaction'; interaction = $levelInteraction } }
        $level = switch ([string]$levelInteraction.value) { '1' { 'beginner' } '2' { 'general' } '3' { 'expert' } default { $null } }
        if ($null -ne $level) { return [ordered]@{ kind = 'request'; provider = $provider; level = $level; focus = 'general' } }
    }
}

function Invoke-DuoForgeInteractiveIssueExplanation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [Parameter(Mandatory)][string]$IssueId,
        [Parameter(Mandatory)][ValidateSet('codex', 'claude', 'both')][string]$Provider,
        [Parameter(Mandatory)][ValidateSet('beginner', 'general', 'expert')][string]$Level,
        [ValidateSet('general', 'evidence', 'examples', 'tradeoffs', 'experiment')][string]$Focus = 'general',
        [scriptblock]$InputReader,
        [scriptblock]$ProviderInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $existing = Get-DuoForgeIssueExplanationsInternal -RunId ([string]$Run.state.runId) -IssueId $IssueId -ResultsRoot $resultsRoot
    $requiredCalls = if ($Provider -eq 'both') { 2 } else { 1 }
    if ([int]$existing.budget.remaining -lt $requiredCalls) {
        $layout = Get-DuoForgeDisplayLayoutInternal
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '추가 설명을 요청할 수 있는 횟수가 부족합니다.' -Message ('요청 가능 {0}회 · 이번에 필요한 요청 {1}회' -f $existing.budget.remaining, $requiredCalls) -Layout $layout) -Layout $layout
        Write-DuoForgeExplanationRecords -Records @($existing.explanations)
        return
    }
    $layout = Get-DuoForgeDisplayLayoutInternal
    $confirmationRows = [System.Collections.Generic.List[object]]::new()
    $providerLabel = switch ($Provider) { 'codex' { 'Codex' } 'claude' { 'Claude' } 'both' { 'Codex와 Claude 비교' } }
    $levelLabel = switch ($Level) { 'beginner' { '쉽게' } 'general' { '일반' } 'expert' { '전문가' } }
    foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title 'AI에 새 설명을 요청하려고 합니다.' -Message ('확인할 내용 {0} · {1} · 설명 수준 {2}' -f $IssueId, $providerLabel, $levelLabel) -NextAction '아래 설정과 요청 횟수를 확인한 뒤 확인어 LIVE를 입력해 주세요.' -Layout $layout)) { $confirmationRows.Add($row) }
    foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '사용할 AI 설정' -Body '' -Layout $layout)) { $confirmationRows.Add($row) }
    foreach ($row in @(New-DuoForgeProviderSelectionRowsInternal -ProviderSelections $Run.manifest.providerSelections -Layout $layout)) { $confirmationRows.Add($row) }
    foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '추가 설명 요청 횟수' -Body '' -Layout $layout)) { $confirmationRows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '이번 요청' -Value ('{0}회' -f $requiredCalls) -Layout $layout -KeyWidth 12 -Role 'warning')) { $confirmationRows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '요청 가능' -Value ('{0}회' -f $existing.budget.remaining) -Layout $layout -KeyWidth 12 -Role 'warning')) { $confirmationRows.Add($row) }
    Write-DuoForgeDisplayRowsInternal -Rows @($confirmationRows) -Layout $layout
    $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'LIVE' -Prompt 'AI에 설명을 요청하려면 LIVE를 입력하세요' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
    if ([string]$confirmation.action -ne 'submit') {
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '설명을 요청하지 않았습니다.' -Message '공급자 호출 또는 설명 기록 변경이 발생하지 않았습니다.' -Layout $layout) -Layout $layout
        return $confirmation
    }
    $result = Invoke-DuoForgeIssueExplanationInternal -RunId ([string]$Run.state.runId) -IssueId $IssueId -Provider $Provider -Level $Level -Focus $Focus -ResultsRoot $resultsRoot -LiveConsent $true -ProviderInvoker $ProviderInvoker
    Write-DuoForgeExplanationRecords -Records @($result.explanations)
    Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title '새 설명을 받았습니다.' -Message ('사용 {0}/{1}회 · 추가 요청 가능 {2}회' -f $result.budget.used, $result.budget.maximum, $result.budget.remaining) -Layout $layout) -Layout $layout
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

    $value = Get-DuoForgeInteractiveReadableTextInternal -Text $Text -MaximumCharacters 1200
    if ($FirstSentence) {
        $match = [regex]::Match($value, '^.*?[.!?](?=\s|$)')
        if ($match.Success -and $match.Value.Length -ge 40) { $value = $match.Value }
    }
    return ConvertTo-DuoForgeProgressTextInternal -Text $value -MaximumCharacters $MaximumCharacters
}

function Get-DuoForgeInteractiveReadableTextInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [ValidateRange(1, 4000)][int]$MaximumCharacters = 1200
    )

    $value = ConvertTo-DuoForgeProgressTextInternal -Text $Text -MaximumCharacters 4000
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
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$Provider,
        [ValidateRange(1, 4000)][int]$MaximumCharacters = 600
    )

    $propertyName = if ($Provider -eq 'codex') { 'codexOpinion' } else { 'claudeOpinion' }
    $storedOpinion = ConvertTo-DuoForgeProgressTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $Question -Name $propertyName)) -MaximumCharacters $MaximumCharacters
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
    # 신규 단계 결과는 저장 전에 엄격히 검증한다. 이 필터는 검증 강화 전에 저장된
    # 질문에서 스키마 설명/자리 표시 문구가 실제 답변으로 노출되는 것만 방어한다.
    $rawOptions = @(Get-DuoForgeQuestionOptionsForInteractionInternal -Options @(Get-DuoForgeObjectValue -Object $Question -Name 'options' -Default @()))
    $genericApprovalPair = $rawOptions.Count -eq 2 -and [string]$rawOptions[0] -match '^\s*A\s*[:：.)-]\s*제안 내용을 반영' -and [string]$rawOptions[1] -match '^\s*B\s*[:：.)-]\s*현재 요구를 유지'
    for ($index = 0; $index -lt $rawOptions.Count; $index++) {
        $letter = [string][char]([int][char]'A' + $index)
        $rawLabel = ConvertTo-DuoForgeProgressTextInternal -Text ([string]$rawOptions[$index]) -MaximumCharacters 600
        $rawFullLabel = Get-DuoForgeInteractiveReadableTextInternal -Text ([string]$rawOptions[$index]) -MaximumCharacters 4000
        $prefixPattern = '^\s*' + [regex]::Escape($letter) + '\s*[:：.)-]\s*'
        $label = [regex]::Replace($rawLabel, $prefixPattern, '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Trim()
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $rawLabel }
        $fullLabel = [regex]::Replace($rawFullLabel, $prefixPattern, '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Trim()
        if ([string]::IsNullOrWhiteSpace($fullLabel)) { $fullLabel = $rawFullLabel }
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
            $fullLabel = $displayLabel
            $outcome = if ($hasAcceptedEditorial) {
                "${targetLabel}의 잠정 수정을 확정하고 관련 문서·검증 단계를 다시 실행합니다."
            }
            else {
                "${targetLabel}에 해결 방향을 반영하고 관련 문서·검증 단계를 다시 실행합니다."
            }
        }
        elseif ($genericApprovalPair -and $index -eq 1) {
            $displayLabel = if ($hasAcceptedEditorial) { '잠정 수정을 승인하지 않고 기존 요구를 유지' } else { '제안을 반영하지 않고 기존 요구를 유지' }
            $fullLabel = $displayLabel
            $outcome = '기존 요구를 기준으로 다시 검증하며, 충돌이 남으면 작업을 완료하지 못할 수 있습니다.'
        }
        $options.Add([ordered]@{
            internalCode = $letter
            letter = $letter
            displayOrdinal = $index + 1
            rawLabel = $rawLabel
            sourceLabel = $label
            label = $displayLabel
            fullLabel = $fullLabel
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
    $impactIfDeferredFull = Get-DuoForgeInteractiveReadableTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $Question -Name 'impactIfDeferred')) -MaximumCharacters 4000
    $impactIfDeferred = ConvertTo-DuoForgeProgressTextInternal -Text $impactIfDeferredFull -MaximumCharacters 600
    $impactIfDeferred = $impactIfDeferred -replace '\bMajor 쟁점', '중요 쟁점' -replace '\bCritical 쟁점', '반드시 해결할 쟁점'
    $impactIfDeferredFull = $impactIfDeferredFull -replace '\bMajor 쟁점', '중요 쟁점' -replace '\bCritical 쟁점', '반드시 해결할 쟁점'

    $questionTextFull = Get-DuoForgeInteractiveReadableTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $Question -Name 'question')) -MaximumCharacters 4000
    $questionText = ConvertTo-DuoForgeProgressTextInternal -Text $questionTextFull -MaximumCharacters 600
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
    $requestPromptFull = if ($genericApprovalPair -and $hasAcceptedEditorial) {
        'AI가 문서에 잠정 반영한 수정 방향을 최종 결정으로 승인할지 선택해 주세요.'
    }
    elseif ($genericApprovalPair) {
        'AI가 제안한 해결 방향을 문서에 반영할지 선택해 주세요.'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($questionTextFull)) {
        $questionTextFull
    }
    else {
        '아래 대안 중 문서에 확정할 방향을 선택해 주세요.'
    }
    $requestPurposeFull = Get-DuoForgeInteractiveReadableTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $Question -Name 'reasonNow')) -MaximumCharacters 4000
    $requestPurpose = Get-DuoForgeInteractiveSentenceSummaryInternal -Text $requestPurposeFull -MaximumCharacters 420
    if ([string]::IsNullOrWhiteSpace($requestPurpose)) { $requestPurpose = '선택 결과를 문서에 확정하고 관련 단계를 다시 검증하기 위해 묻습니다.' }
    if ([string]::IsNullOrWhiteSpace($requestPurposeFull)) { $requestPurposeFull = $requestPurpose }

    $plainExplanation = [string](Get-DuoForgeObjectValue -Object $Question -Name 'plainExplanation')
    $issueClaim = if ($null -ne $Issue) { [string](Get-DuoForgeObjectValue -Object $Issue -Name 'claim') } else { '' }
    $coreIssueSource = if (-not [string]::IsNullOrWhiteSpace($plainExplanation)) { $plainExplanation } else { $issueClaim }
    $coreIssue = Get-DuoForgeInteractiveSentenceSummaryInternal -Text $coreIssueSource -MaximumCharacters 460
    $coreIssueFull = Get-DuoForgeInteractiveReadableTextInternal -Text $coreIssueSource -MaximumCharacters 4000
    $compactCoreIssue = Get-DuoForgeInteractiveCompactIssueInternal -Text $coreIssueSource
    $proposal = if ($null -ne $Issue) { [string](Get-DuoForgeObjectValue -Object $Issue -Name 'proposal') } else { '' }
    $proposalSummary = Get-DuoForgeInteractiveSentenceSummaryInternal -Text $proposal -MaximumCharacters 360 -FirstSentence
    if ([string]::IsNullOrWhiteSpace($proposalSummary)) { $proposalSummary = '저장된 구체적인 해결 제안이 없습니다.' }
    $proposalFull = Get-DuoForgeInteractiveReadableTextInternal -Text $proposal -MaximumCharacters 4000
    if ([string]::IsNullOrWhiteSpace($proposalFull)) { $proposalFull = $proposalSummary }

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
        coreIssueFull = $coreIssueFull
        compactCoreIssue = $compactCoreIssue
        originSummary = $originSummary
        aiConsensus = $aiConsensus
        documentAction = $documentAction
        reviewFlow = $reviewFlow
        proposalSummary = $proposalSummary
        proposalFull = $proposalFull
        requestKind = $requestKind
        requestPrompt = $requestPrompt
        requestPromptFull = $requestPromptFull
        requestPurpose = $requestPurpose
        requestPurposeFull = $requestPurposeFull
        codexOpinion = Get-DuoForgeInteractiveProviderOpinionInternal -Question $Question -Issue $Issue -Provider codex
        claudeOpinion = Get-DuoForgeInteractiveProviderOpinionInternal -Question $Question -Issue $Issue -Provider claude
        codexOpinionFull = Get-DuoForgeInteractiveProviderOpinionInternal -Question $Question -Issue $Issue -Provider codex -MaximumCharacters 4000
        claudeOpinionFull = Get-DuoForgeInteractiveProviderOpinionInternal -Question $Question -Issue $Issue -Provider claude -MaximumCharacters 4000
        reversibility = $reversibility
        confidence = $confidence
        impactIfDeferred = $impactIfDeferred
        impactIfDeferredFull = $impactIfDeferredFull
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
    $items.Add([ordered]@{ value = 'custom'; label = '선택지에 없는 내 의견 직접 입력'; detail = '주관식 답변으로 확정하거나 여러 질문에 공통으로 적용할 전제를 추가합니다.'; shortcuts = @('O'); enabled = $true })
    $items.Add([ordered]@{ value = 'other'; label = '자세히 보기·추가 검토'; detail = '질문 전체 보기, 추가 토론, AI 상세 설명과 의견 비교를 선택합니다.'; shortcuts = @('M'); enabled = $true })
    $items.Add([ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('B'); enabled = $true })
    return @($items)
}

function Get-DuoForgeInteractiveQuestionAlternativeMenuItemsInternal {
    [CmdletBinding()]
    param([ValidateRange(1, 3)][int]$MaximumRounds = 2)

    $items = [System.Collections.Generic.List[object]]::new()
    $items.Add([ordered]@{ value = 'detail'; label = '질문 내용 전체 보기'; detail = '저장된 안전한 질문·쟁점·AI 검토·선택 결과를 줄임 없이 보여줍니다.'; shortcuts = @('V'); enabled = $true })
    if ($MaximumRounds -lt 3) { $items.Add([ordered]@{ value = 'round'; label = '한 토론 회차 더 진행'; shortcuts = @('R'); enabled = $true }) }
    $items.Add([ordered]@{ value = 'explain'; label = '관점과 수준을 선택해 상세 설명'; shortcuts = @('E'); enabled = $true })
    $items.Add([ordered]@{ value = 'compare'; label = '양쪽 의견과 장단점 비교'; shortcuts = @('C'); enabled = $true })
    $items.Add([ordered]@{ value = 'back'; label = '결정 화면으로 돌아가기'; shortcuts = @('B'); enabled = $true })
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

    $layout = Get-DuoForgeDisplayLayoutInternal -Width $Width -Height $Height -NoColor
    # 사용자 확인 화면과 실제 메뉴의 주관식·다른 방법·이전 동작까지 먼저 예약한다.
    # 넓은 화면은 메뉴 설명이 덜 줄바꿈되므로 남는 행을 질문 본문에 돌려준다.
    $estimatedMenuLines = @($Presentation.options).Count + $(
        if ($Width -le 80) { 12 }
        elseif ($Width -le 120) { 10 }
        else { 9 }
    )
    $budget = [Math]::Max(8, $Height - $estimatedMenuLines)
    $rows = [System.Collections.Generic.List[object]]::new()
    $append = {
        param([object[]]$Block)
        if ($null -eq $Block -or $Block.Count -eq 0) { return }
        if ($rows.Count + $Block.Count -gt $budget) { return }
        foreach ($row in $Block) { $rows.Add($row) }
    }

    $header = '{0} · {1} · {2}' -f $Question.issueKey, $Presentation.targetLabel, $Presentation.subjectLabel
    $denseExpandedHeader = $Height -eq 32
    $denseSections = $Height -le 27
    if ($Height -le 23) {
        # 20~23행에서는 요청 종류가 바로 아래 메뉴 제목에 반복되므로 한 줄 식별자만 남긴다.
        & $append @(New-DuoForgeTextRowsInternal -Text $header -Layout $layout -MaximumLines 1 -Role 'page')
    }
    else {
        & $append @(New-DuoForgePageHeaderRowsInternal -Title $header -Tag ([string]$Presentation.requestKind) -Layout $layout -NoTrailingSpacer:($denseSections -or $denseExpandedHeader))
    }

    $newQuestionSection = {
        param([string]$Title, [string]$Value, [int]$MaximumLines = 1, [string]$Role = 'text', [switch]$First, [switch]$Dense)
        return @(
            New-DuoForgeSectionRowsInternal -Title $Title -Body $Value -Layout $layout -First:$First -Compact:$Dense -MaximumBodyLines $MaximumLines -BodyRole $Role
        )
    }

    if ($Height -le 23) {
        # 가장 작은 화면은 상태·권장 행을 메뉴에 맡기되, 질문의 세 핵심 섹션은 제목과 본문을 분리한다.
        & $append @(& $newQuestionSection '확인할 핵심 내용' ([string]$Presentation.compactCoreIssue) 2 'text' -First -Dense)
        & $append @(& $newQuestionSection 'AI 검토와 문서 처리' ([string]$Presentation.reviewFlow) 1 'text' -Dense)
        & $append @(& $newQuestionSection '사용자에게 필요한 결정' ([string]$Presentation.requestPrompt) 1 'warning' -Dense)
    }
    elseif ($Height -le 31) {
        if ($Height -gt 24) {
            & $append @(& $newQuestionSection '현재 상태' ([string]$Presentation.compactCurrentState) 1 'text' -First -Dense:$denseSections)
        }
        & $append @(& $newQuestionSection '확인할 핵심 내용' ([string]$Presentation.compactCoreIssue) 1 'text' -First:($Height -le 24) -Dense:$denseSections)
        & $append @(& $newQuestionSection 'AI 검토와 문서 처리' ([string]$Presentation.reviewFlow) 1 'text' -Dense:$denseSections)
        & $append @(& $newQuestionSection '사용자에게 필요한 결정' ([string]$Presentation.requestPrompt) 1 'warning' -Dense:$denseSections)
    }
    else {
        # 넓고 높은 화면은 각 섹션 제목과 본문을 분리하고, 남는 행을 긴 내용에 공평하게 배분한다.
        # 메뉴에 다시 나오는 권장 방향은 실제 본문이 모두 보인 뒤 공간이 남을 때만 카드에도 표시한다.
        $expandedCoreIssue = [string](Get-DuoForgeObjectValue -Object $Presentation -Name 'coreIssueFull' -Default ([string]$Presentation.coreIssue))
        $expandedProposal = [string](Get-DuoForgeObjectValue -Object $Presentation -Name 'proposalFull' -Default ([string]$Presentation.proposalSummary))
        $fullLineCounts = [ordered]@{
            current = @(Split-DuoForgeDisplayTextInternal -Text ([string]$Presentation.currentState) -Width ([Math]::Max(1, [int]$layout.lineWidth - 2))).Count
            core = @(Split-DuoForgeDisplayTextInternal -Text $expandedCoreIssue -Width ([Math]::Max(1, [int]$layout.lineWidth - 2))).Count
            review = @(Split-DuoForgeDisplayTextInternal -Text ([string]$Presentation.reviewFlow) -Width ([Math]::Max(1, [int]$layout.lineWidth - 2))).Count
            proposal = @(Split-DuoForgeDisplayTextInternal -Text $expandedProposal -Width ([Math]::Max(1, [int]$layout.lineWidth - 2))).Count
            request = @(Split-DuoForgeDisplayTextInternal -Text ([string]$Presentation.requestPrompt) -Width ([Math]::Max(1, [int]$layout.lineWidth - 2))).Count
        }
        $lineBudget = [ordered]@{ current = 1; core = 1; review = 1; proposal = 1; request = 1 }
        $expandedMinimumRows = if ($denseExpandedHeader) { 17 } else { 18 }
        $remainingBodyLines = [Math]::Max(0, $budget - $expandedMinimumRows)
        $allocationOrder = @('core', 'proposal', 'request', 'current', 'review')
        while ($remainingBodyLines -gt 0) {
            $allocatedAny = $false
            foreach ($key in $allocationOrder) {
                if ($remainingBodyLines -le 0) { break }
                if ([int]$lineBudget[$key] -lt [Math]::Max(1, [int]$fullLineCounts[$key])) {
                    $lineBudget[$key] = [int]$lineBudget[$key] + 1
                    $remainingBodyLines--
                    $allocatedAny = $true
                }
            }
            if (-not $allocatedAny) { break }
        }
        $includeRecommendation = $remainingBodyLines -ge 3

        if ($budget -ge $expandedMinimumRows) {
            & $append @(New-DuoForgeSectionRowsInternal -Title '현재 상태' -Body ([string]$Presentation.currentState) -Layout $layout -First -Compact -MaximumBodyLines ([int]$lineBudget.current))
            & $append @(New-DuoForgeSectionRowsInternal -Title '확인할 핵심 내용' -Body $expandedCoreIssue -Layout $layout -MaximumBodyLines ([int]$lineBudget.core))
            & $append @(New-DuoForgeSectionRowsInternal -Title 'AI 검토와 문서 처리' -Body ([string]$Presentation.reviewFlow) -Layout $layout -MaximumBodyLines ([int]$lineBudget.review))
            & $append @(New-DuoForgeSectionRowsInternal -Title '제안 방향' -Body $expandedProposal -Layout $layout -MaximumBodyLines ([int]$lineBudget.proposal))
            & $append @(New-DuoForgeSectionRowsInternal -Title '사용자에게 필요한 결정' -Body ([string]$Presentation.requestPrompt) -Layout $layout -MaximumBodyLines ([int]$lineBudget.request) -BodyRole 'warning')
            if ($includeRecommendation) {
                & $append @(New-DuoForgeSectionRowsInternal -Title '권장 방향' -Body ([string]$Presentation.recommendedLabel) -Layout $layout -MaximumBodyLines 1 -BodyRole 'success')
            }
        }
        else {
            & $append @(& $newQuestionSection '현재 상태' ([string]$Presentation.compactCurrentState) 1 'text' -First)
            & $append @(& $newQuestionSection '확인할 핵심 내용' ([string]$Presentation.compactCoreIssue) 2)
            & $append @(& $newQuestionSection 'AI 검토와 문서 처리' ([string]$Presentation.reviewFlow) 1)
            & $append @(& $newQuestionSection '사용자에게 필요한 결정' ([string]$Presentation.requestPrompt) 1 'warning')
            & $append @(& $newQuestionSection '권장 방향' ([string]$Presentation.recommendedLabel) 1 'success')
        }
    }
    return @($rows)
}

function New-DuoForgeInteractiveQuestionDetailRowsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Question,
        [Parameter(Mandatory)]$Presentation,
        [AllowNull()]$Issue,
        [ValidateRange(48, 400)][int]$Width
    )

    $layout = Get-DuoForgeDisplayLayoutInternal -Width $Width -Height 30 -NoColor
    $rows = [System.Collections.Generic.List[object]]::new()
    $append = { param([object[]]$Block) foreach ($row in @($Block)) { $rows.Add($row) } }

    $plainExplanation = [string](Get-DuoForgeObjectValue -Object $Question -Name 'plainExplanation' -Default '')
    $claim = if ($null -ne $Issue) { [string](Get-DuoForgeObjectValue -Object $Issue -Name 'claim' -Default '') } else { '' }
    $coreIssue = Get-DuoForgeInteractiveReadableTextInternal -Text $(if ([string]::IsNullOrWhiteSpace($plainExplanation)) { $claim } else { $plainExplanation }) -MaximumCharacters 4000
    $proposal = if ($null -ne $Issue) { [string](Get-DuoForgeObjectValue -Object $Issue -Name 'proposal' -Default '') } else { '' }
    $proposal = Get-DuoForgeInteractiveReadableTextInternal -Text $proposal -MaximumCharacters 4000
    $request = [string](Get-DuoForgeObjectValue -Object $Question -Name 'question' -Default '')
    if ([string]::IsNullOrWhiteSpace($request)) { $request = [string](Get-DuoForgeObjectValue -Object $Presentation -Name 'requestPromptFull' -Default ([string]$Presentation.requestPrompt)) }
    $request = Get-DuoForgeInteractiveReadableTextInternal -Text $request -MaximumCharacters 4000
    $purpose = Get-DuoForgeInteractiveReadableTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $Question -Name 'reasonNow' -Default (Get-DuoForgeObjectValue -Object $Presentation -Name 'requestPurposeFull' -Default ([string]$Presentation.requestPurpose)))) -MaximumCharacters 4000
    $codexOpinion = [string](Get-DuoForgeObjectValue -Object $Presentation -Name 'codexOpinionFull' -Default ([string]$Presentation.codexOpinion))
    $claudeOpinion = [string](Get-DuoForgeObjectValue -Object $Presentation -Name 'claudeOpinionFull' -Default ([string]$Presentation.claudeOpinion))

    & $append @(New-DuoForgePageHeaderRowsInternal -Title ("{0} · {1} · {2}" -f $Question.issueKey, $Presentation.targetLabel, $Presentation.subjectLabel) -Tag ([string]$Presentation.requestKind) -Layout $layout)
    & $append @(New-DuoForgeSectionRowsInternal -Title '현재 상태' -Body ([string]$Presentation.currentState) -Layout $layout -First -PreserveParagraphs)
    & $append @(New-DuoForgeSectionRowsInternal -Title '확인할 핵심 내용' -Body $coreIssue -Layout $layout -PreserveParagraphs)
    & $append @(New-DuoForgeSectionRowsInternal -Title 'AI 검토와 문서 처리' -Body '' -Layout $layout)
    $aiKeyWidth = 12
    & $append @(New-DuoForgeFieldRowsInternal -Label '최초 제기' -Value ([string]$Presentation.originSummary) -Layout $layout -KeyWidth $aiKeyWidth)
    & $append @(New-DuoForgeFieldRowsInternal -Label '합의 상태' -Value ([string]$Presentation.aiConsensus) -Layout $layout -KeyWidth $aiKeyWidth)
    & $append @(New-DuoForgeFieldRowsInternal -Label '문서 처리' -Value ([string]$Presentation.documentAction) -Layout $layout -KeyWidth $aiKeyWidth)
    & $append @(New-DuoForgeFieldRowsInternal -Label 'Codex 의견' -Value (Get-DuoForgeInteractiveReadableTextInternal -Text $codexOpinion -MaximumCharacters 4000) -Layout $layout -KeyWidth $aiKeyWidth -PreserveParagraphs)
    & $append @(New-DuoForgeFieldRowsInternal -Label 'Claude 의견' -Value (Get-DuoForgeInteractiveReadableTextInternal -Text $claudeOpinion -MaximumCharacters 4000) -Layout $layout -KeyWidth $aiKeyWidth -PreserveParagraphs)
    & $append @(New-DuoForgeSectionRowsInternal -Title '제안 방향' -Body $proposal -Layout $layout -PreserveParagraphs)
    & $append @(New-DuoForgeSectionRowsInternal -Title '사용자에게 필요한 결정' -Body '' -Layout $layout)
    $requestKeyWidth = 14
    & $append @(New-DuoForgeFieldRowsInternal -Label '요청 내용' -Value $request -Layout $layout -KeyWidth $requestKeyWidth -Role 'warning' -PreserveParagraphs)
    & $append @(New-DuoForgeFieldRowsInternal -Label '묻는 이유' -Value $purpose -Layout $layout -KeyWidth $requestKeyWidth -PreserveParagraphs)
    & $append @(New-DuoForgeFieldRowsInternal -Label '예상 영향·비용' -Value (Get-DuoForgeInteractiveReadableTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $Question -Name 'estimatedCost' -Default '')) -MaximumCharacters 4000) -Layout $layout -KeyWidth $requestKeyWidth -PreserveParagraphs)
    & $append @(New-DuoForgeFieldRowsInternal -Label '보류 영향' -Value (Get-DuoForgeInteractiveReadableTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $Presentation -Name 'impactIfDeferredFull' -Default ([string]$Presentation.impactIfDeferred))) -MaximumCharacters 4000) -Layout $layout -KeyWidth $requestKeyWidth -PreserveParagraphs)
    & $append @(New-DuoForgeFieldRowsInternal -Label '되돌리기' -Value ([string]$Presentation.reversibility) -Layout $layout -KeyWidth $requestKeyWidth)
    & $append @(New-DuoForgeFieldRowsInternal -Label '권고 신뢰도' -Value ([string]$Presentation.confidence) -Layout $layout -KeyWidth $requestKeyWidth)
    & $append @(New-DuoForgeSectionRowsInternal -Title '권장 방향' -Body ([string]$Presentation.recommendedLabel) -Layout $layout -BodyRole 'success')
    & $append @(New-DuoForgeSectionRowsInternal -Title '선택지와 결과' -Body '' -Layout $layout)
    foreach ($option in @($Presentation.options)) {
        $optionLabel = '{0}안 · {1}' -f $option.displayOrdinal, (Get-DuoForgeObjectValue -Object $option -Name 'fullLabel' -Default ([string]$option.label))
        if ([bool]$option.isRecommended) { $optionLabel += ' · 권장' }
        & $append @(New-DuoForgeTextRowsInternal -Text $optionLabel -Layout $layout -Indent 2 -Role $(if ([bool]$option.isRecommended) { 'success' } else { 'warning' }) -PreserveParagraphs)
        & $append @(New-DuoForgeFieldRowsInternal -Label '결과' -Value ([string]$option.outcome) -Layout $layout -Indent 4 -KeyWidth 4 -PreserveParagraphs)
    }
    return @($rows)
}

function Invoke-DuoForgeInteractiveQuestionDetailInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Question,
        [Parameter(Mandatory)]$Presentation,
        [AllowNull()]$Issue,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker
    )

    $viewWidth = 100
    try { $viewWidth = [Math]::Max(48, [Math]::Min(400, [Console]::WindowWidth)) } catch { }
    $layout = Get-DuoForgeDisplayLayoutInternal -Width $viewWidth
    $detailRows = @(New-DuoForgeInteractiveQuestionDetailRowsInternal -Question $Question -Presentation $Presentation -Issue $Issue -Width $viewWidth)
    Write-DuoForgeDisplayRowsInternal -Rows @(Add-DuoForgeTrailingSpacerRowInternal -Rows $detailRows) -Layout $layout
    $backItems = @([ordered]@{ value = 'back'; label = '결정 화면으로 돌아가기'; detail = '터미널 스크롤로 위 내용을 다시 읽을 수 있습니다.'; shortcuts = @('B'); enabled = $true })
    return Invoke-DuoForgeMenuInteractionInternal -Items $backItems -Title '질문 내용을 모두 확인했습니다.' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -MenuInvoker $MenuInvoker -ContextTransition
}

function Get-DuoForgeInteractivePendingQuestionsInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $pendingPath = Join-Path $RunDirectory 'decisions\pending.json'
    if (-not (Test-Path -LiteralPath $pendingPath -PathType Leaf)) { return @() }
    $pending = Read-DuoForgeJson -Path $pendingPath
    return @(Get-DuoForgeObjectValue -Object $pending -Name 'questions' -Default @())
}

function Invoke-DuoForgeInteractiveCustomDecisionInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [Parameter(Mandatory)][string]$IssueId,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker,
        [scriptblock]$DecisionInvoker,
        [scriptblock]$ConstraintInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    while ($true) {
    $scopeInteraction = Invoke-DuoForgeMenuInteractionInternal -Items @(
        [ordered]@{ value = 'answer'; label = '이 질문의 주관식 답변으로 사용'; detail = '객관식 선택 대신 직접 쓴 의견을 이 질문의 최종 답변으로 기록합니다.'; shortcuts = @('1'); enabled = $true },
        [ordered]@{ value = 'common'; label = '여러 질문에 공통 전제로 추가'; detail = '현재·이후 답변과 함께 두 AI의 마지막 문서·검증 단계에 적용하며 이 질문은 미답변으로 남깁니다.'; shortcuts = @('2'); enabled = $true },
        [ordered]@{ value = 'back'; label = '결정 화면으로 돌아가기'; shortcuts = @('B'); enabled = $true }
    ) -Title '내 의견을 어떻게 반영할까요?' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -MenuInvoker $MenuInvoker
    if ([string]$scopeInteraction.action -eq 'back') { return $null }
    if ([string]$scopeInteraction.action -ne 'submit') { return [ordered]@{ kind = 'interaction'; interaction = $scopeInteraction } }
    $scope = [string]$scopeInteraction.value

    $prompt = if ($scope -eq 'answer') { '이 질문에 대한 내 답변' } else { '여러 질문에 함께 적용할 공통 전제' }
    $textInteraction = Read-DuoForgeFreeTextInteractionInternal -Prompt $prompt -ReturnTarget parent -InterruptReturnTarget work-menu -InputReader $InputReader
    if ([string]$textInteraction.action -ne 'submit') { return [ordered]@{ kind = 'interaction'; interaction = $textInteraction } }
    $text = [string]$textInteraction.value
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    try {
        if ($scope -eq 'answer') {
            $preview = New-DuoForgeCustomAnswerPreviewInternal -RunId ([string]$Run.state.runId) -IssueId $IssueId -Text $text -ResultsRoot $resultsRoot
            $layout = Get-DuoForgeDisplayLayoutInternal
            $previewRows = [System.Collections.Generic.List[object]]::new()
            foreach ($row in @(New-DuoForgePageHeaderRowsInternal -Title '주관식 답변 미리보기' -Tag 'APPLY 확인 전' -Layout $layout)) { $previewRows.Add($row) }
            foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '입력과 적용' -Body '' -Layout $layout -First)) { $previewRows.Add($row) }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '입력 내용' -Value ([string]$preview.normalizedAnswer) -Layout $layout -KeyWidth 12 -PreserveParagraphs)) { $previewRows.Add($row) }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '적용 대상' -Value ("{0} · {1}" -f $IssueId, (Get-DuoForgeInteractiveDocumentLabelInternal -TargetDocumentId ([string]$preview.affectedTarget))) -Layout $layout -KeyWidth 12)) { $previewRows.Add($row) }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '처리 결과' -Value $(if ([bool]$preview.replacesPreviousAnswer) { '기존 답변을 이 주관식 답변으로 변경합니다.' } else { '이 질문을 답변 완료로 처리합니다.' }) -Layout $layout -KeyWidth 12)) { $previewRows.Add($row) }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '적용 방식' -Value ([string]$preview.application) -Layout $layout -KeyWidth 12)) { $previewRows.Add($row) }
            foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title 'APPLY를 입력하면 이 답변을 기록하고 관련 문서 작성과 확인 작업을 다시 진행합니다.' -Layout $layout)) { $previewRows.Add($row) }
            Write-DuoForgeDisplayRowsInternal -Rows @($previewRows) -Layout $layout
            $confirmation = Invoke-DuoForgeInteractiveApplyBoundaryInternal -Boundary answer -Run $Run -IssueId $IssueId -Text $text -ReplacePrevious:([bool]$preview.replacesPreviousAnswer) -InputReader $InputReader -DecisionInvoker $DecisionInvoker -ConstraintInvoker $ConstraintInvoker -ConfirmationKeyReader $ConfirmationKeyReader -ConfirmationFrameWriter $ConfirmationFrameWriter -ConfirmationCapabilityProbe $ConfirmationCapabilityProbe
            if ([string]$confirmation.action -ne 'submit') {
                if ([string]$confirmation.action -eq 'back' -and [string]$confirmation.returnTarget -eq 'parent') { continue }
                return [ordered]@{ kind = 'interaction'; interaction = $confirmation }
            }
            $applied = $confirmation.result
            Write-DuoForgeTextInternal ("주관식 답변을 기록했습니다. 관련 AI 작업 {0}개를 다시 진행합니다." -f @($applied.resetSteps).Count) -ForegroundColor Green
            return [ordered]@{ kind = 'answer'; result = $applied; preview = $preview }
        }

        $preview = New-DuoForgeDecisionConstraintPreviewInternal -RunId ([string]$Run.state.runId) -IssueId $IssueId -Text $text -ResultsRoot $resultsRoot
        $layout = Get-DuoForgeDisplayLayoutInternal
        $previewRows = [System.Collections.Generic.List[object]]::new()
        foreach ($row in @(New-DuoForgePageHeaderRowsInternal -Title '공통 전제 미리보기' -Tag 'APPLY 확인 전' -Layout $layout)) { $previewRows.Add($row) }
        foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '입력과 적용' -Body '' -Layout $layout -First)) { $previewRows.Add($row) }
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '입력 내용' -Value ([string]$preview.normalizedConstraint) -Layout $layout -KeyWidth 16 -PreserveParagraphs)) { $previewRows.Add($row) }
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '연결 기준' -Value ("{0} · {1}" -f $IssueId, (Get-DuoForgeInteractiveDocumentLabelInternal -TargetDocumentId ([string]$preview.affectedTarget))) -Layout $layout -KeyWidth 16)) { $previewRows.Add($row) }
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '적용 범위' -Value '현재·이후의 객관식 및 주관식 답변과 함께 두 AI의 마지막 문서 생성·검증 단계에 적용합니다.' -Layout $layout -KeyWidth 16)) { $previewRows.Add($row) }
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '현재 질문 처리' -Value '공통 전제이므로 현재 질문은 미답변으로 유지됩니다.' -Layout $layout -KeyWidth 16)) { $previewRows.Add($row) }
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '서로 맞지 않을 때' -Value '기존 답변과 함께 적용할 수 없으면 AI가 반드시 해결할 내용으로 알려야 합니다.' -Layout $layout -KeyWidth 18)) { $previewRows.Add($row) }
        foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title 'APPLY를 입력하면 이 전제를 기록하고 관련 문서 작성과 확인 작업을 다시 진행합니다.' -Layout $layout)) { $previewRows.Add($row) }
        Write-DuoForgeDisplayRowsInternal -Rows @($previewRows) -Layout $layout
        $confirmation = Invoke-DuoForgeInteractiveApplyBoundaryInternal -Boundary common -Run $Run -IssueId $IssueId -Text $text -InputReader $InputReader -DecisionInvoker $DecisionInvoker -ConstraintInvoker $ConstraintInvoker -ConfirmationKeyReader $ConfirmationKeyReader -ConfirmationFrameWriter $ConfirmationFrameWriter -ConfirmationCapabilityProbe $ConfirmationCapabilityProbe
        if ([string]$confirmation.action -ne 'submit') {
            if ([string]$confirmation.action -eq 'back' -and [string]$confirmation.returnTarget -eq 'parent') { continue }
            return [ordered]@{ kind = 'interaction'; interaction = $confirmation }
        }
        $applied = $confirmation.result
        Write-DuoForgeTextInternal ("공통 전제를 기록했습니다. 관련 AI 작업 {0}개를 다시 진행합니다." -f @($applied.resetSteps).Count) -ForegroundColor Green
        return [ordered]@{ kind = 'constraint'; result = $applied; preview = $preview }
    }
    catch {
        if ([string]$_.Exception.Data['DuoForgeCode'] -in @('DF-DECISION-CUSTOM-EMPTY', 'DF-DECISION-CUSTOM-LENGTH', 'DF-CONSTRAINT-EMPTY', 'DF-CONSTRAINT-LENGTH')) {
            Write-DuoForgeTextInternal $_.Exception.Message -ForegroundColor Yellow
            return $null
        }
        throw
    }
    }
}

function Invoke-DuoForgeInteractiveApplyBoundaryInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('answer', 'common')][string]$Boundary,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [Parameter(Mandatory)][string]$IssueId,
        [AllowEmptyString()][Parameter(Mandatory)][string]$Text,
        [switch]$ReplacePrevious,
        [scriptblock]$InputReader,
        [scriptblock]$DecisionInvoker,
        [scriptblock]$ConstraintInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    $prompt = switch ($Boundary) {
        'answer' { '이 내용으로 확정하려면 APPLY를 입력하세요' }
        'common' { '이 공통 전제를 적용하려면 APPLY를 입력하세요' }
    }
    $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'APPLY' -Prompt $prompt -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
    if ([string]$confirmation.action -ne 'submit') { return $confirmation }

    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    if ($Boundary -eq 'answer') {
        $applied = if ($null -ne $DecisionInvoker) {
            & $DecisionInvoker ([string]$Run.state.runId) $IssueId $Text $resultsRoot ([bool]$ReplacePrevious)
        }
        else {
            Set-DuoForgeUserDecisionInternal -RunId ([string]$Run.state.runId) -IssueId $IssueId -Action answer -CustomText $Text -ResultsRoot $resultsRoot -ReplacePrevious:$ReplacePrevious
        }
    }
    else {
        $applied = if ($null -ne $ConstraintInvoker) {
            & $ConstraintInvoker ([string]$Run.state.runId) $IssueId $Text $resultsRoot
        }
        else {
            Set-DuoForgeUserConstraintInternal -RunId ([string]$Run.state.runId) -IssueId $IssueId -Text $Text -ResultsRoot $resultsRoot -Confirm
        }
    }
    $confirmation['result'] = $applied
    return $confirmation
}

function Invoke-DuoForgeInteractiveRoundConfirmationInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [scriptblock]$InputReader,
        [scriptblock]$RoundInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'ROUND' -Prompt '최대 토론 회차를 3으로 늘리려면 ROUND를 입력하세요' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
    if ([string]$confirmation.action -ne 'submit') { return $confirmation }

    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $extended = if ($null -ne $RoundInvoker) {
        & $RoundInvoker ([string]$Run.state.runId) $resultsRoot
    }
    else {
        Add-DuoForgeRoundInternal -RunId ([string]$Run.state.runId) -ResultsRoot $resultsRoot
    }
    $confirmation['result'] = $extended
    Write-DuoForgeTextInternal ("3차 토론을 추가했습니다. 새 단계 {0}개를 이어서 진행할 수 있습니다." -f $extended.addedSteps) -ForegroundColor Green
    return $confirmation
}

function Invoke-DuoForgeInteractiveQuestion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker,
        [scriptblock]$RoundInvoker,
        [scriptblock]$DecisionInvoker,
        [scriptblock]$ConstraintInvoker,
        [scriptblock]$ChoiceDecisionInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    $questions = @(Get-DuoForgeInteractivePendingQuestionsInternal -RunDirectory ([string]$Run.runDirectory))
    if ($questions.Count -eq 0) { Write-DuoForgeTextInternal '답변 대기 중인 질문이 없습니다.'; return }
    $reviewProgress = Get-DuoForgeDecisionReviewProgressInternal -RunDirectory ([string]$Run.runDirectory) -State $Run.state -InferPendingGate
    $issueLedger = Get-DuoForgeObjectValue -Object $Run -Name 'issues'
    $runIssues = if ($null -ne $issueLedger) { @(Get-DuoForgeObjectValue -Object $issueLedger -Name 'issues' -Default @()) } else { @() }
    $batch = Get-DuoForgePendingQuestionBatchInternal -Questions $questions
    $layout = Get-DuoForgeDisplayLayoutInternal
    Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeFieldRowsInternal -Label '사용자 확인 단계' -Value ("{0}/{1} · 지금 볼 질문 {2}개 · 이후 {3}개" -f $reviewProgress.cycle, $reviewProgress.maximum, $batch.batchSize, $batch.remainingAfterBatch) -Layout $layout -Indent 0 -KeyWidth 16 -Role 'meta') -Layout $layout
    if ([int]$reviewProgress.cycle -ge [int]$reviewProgress.maximum) {
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '마지막 사용자 확인 단계입니다.' -Message '이번 답변을 반영한 뒤 새 질문이 생겨도 자동으로 다시 묻지 않습니다.' -Layout $layout) -Layout $layout
    }
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
        $batchItems.Add([ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('B'); enabled = $true })
        Write-DuoForgeDisplaySpacerInternal -Layout $layout
        $batchInteraction = Invoke-DuoForgeMenuInteractionInternal -Items @($batchItems) -Title '먼저 확인할 요청을 선택해 주세요.' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ([string]$batchInteraction.action -ne 'submit') { return $batchInteraction }
        $selectedText = [string]$batchInteraction.value
        $question = $batch.questions[[int]$selectedText]
    }
    else {
        $question = $batch.questions[0]
    }
    $issue = @($runIssues | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'issueId') -eq [string]$question.issueKey } | Select-Object -First 1)
    $presentation = Get-DuoForgeInteractiveQuestionPresentationInternal -Question $question -Issue $(if ($issue.Count -gt 0) { $issue[0] } else { $null })
    $showAlternativeMenu = $false
    while ($true) {
        if ($showAlternativeMenu) {
            $choice = 'other'
            $showAlternativeMenu = $false
        }
        else {
        $viewWidth = 100
        $viewHeight = 30
        try {
            $viewWidth = [Math]::Max(48, [Math]::Min(400, [Console]::WindowWidth))
            $viewHeight = [Math]::Max(12, [Math]::Min(200, [Console]::WindowHeight))
        }
        catch { }
        $questionLayout = Get-DuoForgeDisplayLayoutInternal -Width $viewWidth -Height $viewHeight
        $cardRows = @(New-DuoForgeInteractiveQuestionCardRowsInternal -Question $question -Presentation $presentation -Width $viewWidth -Height $viewHeight)
        Write-DuoForgeDisplayRowsInternal -Rows @(Add-DuoForgeTrailingSpacerRowInternal -Rows $cardRows) -Layout $questionLayout
        $questionItems = @(Get-DuoForgeInteractiveQuestionMenuItemsInternal -Presentation $presentation -MaximumRounds ([int]$Run.manifest.maxRounds))
        $questionInteraction = Invoke-DuoForgeMenuInteractionInternal -Items $questionItems -Title ("{0}: 번호로 선택하거나 O로 내 의견을 입력해 주세요." -f $presentation.requestKind) -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -MenuInvoker $MenuInvoker -ContextTransition
        if ([string]$questionInteraction.action -ne 'submit') { return $questionInteraction }
        $choice = [string]$questionInteraction.value
        }
        if ($choice -eq 'custom') {
            $customResult = Invoke-DuoForgeInteractiveCustomDecisionInternal -Run $Run -IssueId ([string]$question.issueKey) -InputReader $InputReader -MenuInvoker $MenuInvoker -DecisionInvoker $DecisionInvoker -ConstraintInvoker $ConstraintInvoker -ConfirmationKeyReader $ConfirmationKeyReader -ConfirmationFrameWriter $ConfirmationFrameWriter -ConfirmationCapabilityProbe $ConfirmationCapabilityProbe
            if ($null -ne $customResult -and [string](Get-DuoForgeObjectValue -Object $customResult -Name 'kind') -eq 'interaction') {
                if ([string]$customResult.interaction.action -in @('cancel', 'interrupt', 'unavailable')) { return $customResult.interaction }
                continue
            }
            if ($null -eq $customResult -or [string]$customResult.kind -eq 'constraint') { continue }
            $remainingQuestions = @(Get-DuoForgeInteractivePendingQuestionsInternal -RunDirectory ([string]$Run.runDirectory))
            if ($remainingQuestions.Count -gt 0) {
                Write-DuoForgeTextInternal ("아직 답하지 않은 질문이 {0}개 있습니다. 다음 질문 목록을 이어서 표시합니다. Q를 누르면 나중에 다시 답할 수 있습니다." -f $remainingQuestions.Count) -ForegroundColor Yellow
                $nextInteraction = Invoke-DuoForgeInteractiveQuestion -Run $Run -InputReader $InputReader -MenuInvoker $MenuInvoker -RoundInvoker $RoundInvoker -DecisionInvoker $DecisionInvoker -ConstraintInvoker $ConstraintInvoker -ChoiceDecisionInvoker $ChoiceDecisionInvoker -ConfirmationKeyReader $ConfirmationKeyReader -ConfirmationFrameWriter $ConfirmationFrameWriter -ConfirmationCapabilityProbe $ConfirmationCapabilityProbe
                if ($null -ne $nextInteraction -and [string](Get-DuoForgeObjectValue -Object $nextInteraction -Name 'action') -in @('back', 'cancel', 'interrupt', 'unavailable')) { return $nextInteraction }
            }
            else {
                Write-DuoForgeTextInternal '모든 대기 질문에 답했습니다. 이제 작업 계속하기를 선택하면 답변을 반영해 다시 검증합니다.' -ForegroundColor Green
            }
            return
        }
        if ($choice -eq 'other') {
            while ($true) {
                $alternativeItems = @(Get-DuoForgeInteractiveQuestionAlternativeMenuItemsInternal -MaximumRounds ([int]$Run.manifest.maxRounds))
                $alternativeInteraction = Invoke-DuoForgeMenuInteractionInternal -Items $alternativeItems -Title '자세히 보기·추가 검토 항목을 선택해 주세요.' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -MenuInvoker $MenuInvoker
                if ([string]$alternativeInteraction.action -eq 'back') { break }
                if ([string]$alternativeInteraction.action -ne 'submit') { return $alternativeInteraction }
                $choice = [string]$alternativeInteraction.value
                if ($choice -eq 'round' -and [int]$Run.manifest.maxRounds -lt 3) {
                    $roundInteraction = Invoke-DuoForgeInteractiveRoundConfirmationInternal -Run $Run -InputReader $InputReader -RoundInvoker $RoundInvoker -ConfirmationKeyReader $ConfirmationKeyReader -ConfirmationFrameWriter $ConfirmationFrameWriter -ConfirmationCapabilityProbe $ConfirmationCapabilityProbe
                    if ([string]$roundInteraction.action -eq 'submit') { return $roundInteraction }
                    if ([string]$roundInteraction.action -eq 'back') { continue }
                    return $roundInteraction
                }
                break
            }
            if ([string]$alternativeInteraction.action -eq 'back') { continue }
        }
        if ($choice -eq 'detail') {
            $detailInteraction = Invoke-DuoForgeInteractiveQuestionDetailInternal -Question $question -Presentation $presentation -Issue $(if ($issue.Count -gt 0) { $issue[0] } else { $null }) -InputReader $InputReader -MenuInvoker $MenuInvoker
            if ([string]$detailInteraction.action -in @('cancel', 'interrupt', 'unavailable')) { return $detailInteraction }
            continue
        }
        if ($choice -eq 'explain') {
            $request = Read-DuoForgeInteractiveExplanationRequest -InputReader $InputReader -MenuInvoker $MenuInvoker
            if ($null -ne $request -and [string](Get-DuoForgeObjectValue -Object $request -Name 'kind') -eq 'interaction') {
                if ([string]$request.interaction.action -eq 'back') { $showAlternativeMenu = $true; continue }
                return $request.interaction
            }
            if ($null -ne $request) {
                $explanationResult = Invoke-DuoForgeInteractiveIssueExplanation -Run $Run -IssueId ([string]$question.issueKey) -Provider ([string]$request.provider) -Level ([string]$request.level) -Focus ([string]$request.focus) -InputReader $InputReader
                if ([string](Get-DuoForgeObjectValue -Object $explanationResult -Name 'action') -in @('cancel', 'interrupt', 'unavailable')) { return $explanationResult }
            }
            continue
        }
        if ($choice -eq 'compare') {
            $explanationResult = Invoke-DuoForgeInteractiveIssueExplanation -Run $Run -IssueId ([string]$question.issueKey) -Provider both -Level general -Focus tradeoffs -InputReader $InputReader
            if ([string](Get-DuoForgeObjectValue -Object $explanationResult -Name 'action') -in @('cancel', 'interrupt', 'unavailable')) { return $explanationResult }
            continue
        }
        $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
        try {
            $answerChoice = if ($choice -like 'answer:*') { $choice.Substring(7) } else { $choice }
            $result = if ($null -ne $ChoiceDecisionInvoker) {
                & $ChoiceDecisionInvoker ([string]$Run.state.runId) ([string]$question.issueKey) $answerChoice $resultsRoot $false
            }
            else {
                Set-DuoForgeUserDecisionInternal -RunId ([string]$Run.state.runId) -IssueId ([string]$question.issueKey) -Action answer -Choice $answerChoice -ResultsRoot $resultsRoot
            }
            Write-DuoForgeTextInternal ("답변을 기록했습니다. 관련 AI 작업 {0}개를 다시 진행합니다." -f @($result.resetSteps).Count) -ForegroundColor Green
            $remainingQuestions = @(Get-DuoForgeInteractivePendingQuestionsInternal -RunDirectory ([string]$Run.runDirectory))
            if ($remainingQuestions.Count -gt 0) {
                Write-DuoForgeTextInternal ("아직 답하지 않은 질문이 {0}개 있습니다. 다음 질문 목록을 이어서 표시합니다. Q를 누르면 나중에 다시 답할 수 있습니다." -f $remainingQuestions.Count) -ForegroundColor Yellow
                $nextInteraction = Invoke-DuoForgeInteractiveQuestion -Run $Run -InputReader $InputReader -MenuInvoker $MenuInvoker -RoundInvoker $RoundInvoker -DecisionInvoker $DecisionInvoker -ConstraintInvoker $ConstraintInvoker -ChoiceDecisionInvoker $ChoiceDecisionInvoker -ConfirmationKeyReader $ConfirmationKeyReader -ConfirmationFrameWriter $ConfirmationFrameWriter -ConfirmationCapabilityProbe $ConfirmationCapabilityProbe
                if ($null -ne $nextInteraction -and [string](Get-DuoForgeObjectValue -Object $nextInteraction -Name 'action') -in @('back', 'cancel', 'interrupt', 'unavailable')) { return $nextInteraction }
            }
            else {
                Write-DuoForgeTextInternal '모든 대기 질문에 답했습니다. 이제 작업 계속하기를 선택하면 답변을 반영해 다시 검증합니다.' -ForegroundColor Green
            }
            return
        }
        catch {
            if ([string]$_.Exception.Data['DuoForgeCode'] -eq 'DF-DECISION-CHOICE') {
                Write-DuoForgeTextInternal '올바른 선택지 또는 설명 동작을 선택해 주세요.' -ForegroundColor Yellow
                continue
            }
            throw
        }
    }
}

function New-DuoForgeInteractiveEvidenceIssueRowsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Issue,
        [ValidateRange(0, 1000)][int]$Width = 0,
        [switch]$IncludeHeader
    )

    $layout = Get-DuoForgeDisplayLayoutInternal -Width $Width -NoColor
    $rows = [System.Collections.Generic.List[object]]::new()
    if ($IncludeHeader) {
        $targetLabel = Get-DuoForgeInteractiveDocumentLabelInternal -TargetDocumentId (Get-DuoForgeIssueTargetInternal -Issue $Issue)
        $subjectLabel = Get-DuoForgeInteractiveCategoryLabelInternal -Category ([string](Get-DuoForgeObjectValue -Object $Issue -Name 'category' -Default ''))
        foreach ($row in @(New-DuoForgePageHeaderRowsInternal -Title ('{0} · {1} · {2}' -f $Issue.issueId, $targetLabel, $subjectLabel) -Tag '추가 자료 요청' -Layout $layout)) { $rows.Add($row) }
    }
    foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '확인할 핵심 내용' -Body (Get-DuoForgeInteractiveReadableTextInternal -Text ([string]$Issue.claim) -MaximumCharacters 4000) -Layout $layout -First:$IncludeHeader -PreserveParagraphs)) { $rows.Add($row) }
    foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '필요한 자료' -Body (Get-DuoForgeInteractiveReadableTextInternal -Text ([string]$Issue.proposal) -MaximumCharacters 4000) -Layout $layout -PreserveParagraphs)) { $rows.Add($row) }
    return @($rows)
}

function Invoke-DuoForgeInteractiveEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker,
        [scriptblock]$EvidenceInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    $issues = @($Run.issues.issues | Where-Object { [string]$_.resolutionStatus -eq 'AWAITING_EVIDENCE' })
    if ($issues.Count -eq 0) { Write-DuoForgeTextInternal '추가 자료가 필요한 내용이 없습니다.'; return }
    $items = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $issues.Count; $index++) {
        $targetLabel = Get-DuoForgeInteractiveDocumentLabelInternal -TargetDocumentId (Get-DuoForgeIssueTargetInternal -Issue $issues[$index])
        $subjectLabel = Get-DuoForgeInteractiveCategoryLabelInternal -Category ([string](Get-DuoForgeObjectValue -Object $issues[$index] -Name 'category' -Default ''))
        $items.Add([ordered]@{
            value = [string]$index
            label = ('{0} · {1} · {2}' -f $issues[$index].issueId, $targetLabel, $subjectLabel)
            detail = '선택하면 확인할 핵심 내용과 필요한 자료를 모두 보여줍니다.'
            shortcuts = @([string]($index + 1))
            enabled = $true
        })
    }
    $items.Add([ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('B'); enabled = $true })
    $issueInteraction = Invoke-DuoForgeMenuInteractionInternal -Items @($items) -Title '자료를 추가할 내용을 선택해 주세요.' -ReturnTarget work-menu -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -MenuInvoker $MenuInvoker
    if ([string]$issueInteraction.action -ne 'submit') { return $issueInteraction }
    $choice = [string]$issueInteraction.value
    $issue = $issues[[int]$choice]
    $layout = Get-DuoForgeDisplayLayoutInternal
    $issueRows = @(New-DuoForgeInteractiveEvidenceIssueRowsInternal -Issue $issue -Width ([int]$layout.width) -IncludeHeader)
    Write-DuoForgeDisplayRowsInternal -Rows @(Add-DuoForgeTrailingSpacerRowInternal -Rows $issueRows) -Layout $layout
    while ($true) {
        $file = Read-DuoForgePathChoice -Prompt '추가할 Markdown 자료 문서를 선택해 주세요.' -Role 'user-evidence' -Type File -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ($null -eq $file) { return }
        $evidenceRows = [System.Collections.Generic.List[object]]::new()
        foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '추가 자료를 작업에 연결하려고 합니다.' -Message '선택한 문서를 작업 폴더에 별도로 보관하며 원본 파일은 변경하지 않습니다.' -Layout $layout)) { $evidenceRows.Add($row) }
        foreach ($row in @(New-DuoForgeInteractiveEvidenceIssueRowsInternal -Issue $issue -Width ([int]$layout.width))) { $evidenceRows.Add($row) }
        foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '추가할 근거' -Body '' -Layout $layout)) { $evidenceRows.Add($row) }
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '확인할 내용' -Value ([string]$issue.issueId) -Layout $layout -KeyWidth 14)) { $evidenceRows.Add($row) }
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '문서 경로' -Value ([string]$file) -Layout $layout -KeyWidth 12)) { $evidenceRows.Add($row) }
        Write-DuoForgeDisplayRowsInternal -Rows @($evidenceRows) -Layout $layout
        $evidence = Invoke-DuoForgeEvidenceBoundaryInternal -Run $Run -IssueId ([string]$issue.issueId) -File $file -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -EvidenceInvoker $EvidenceInvoker -ConfirmationKeyReader $ConfirmationKeyReader -ConfirmationFrameWriter $ConfirmationFrameWriter -ConfirmationCapabilityProbe $ConfirmationCapabilityProbe
        if ([string]$evidence.interaction.action -eq 'back' -and [string]$evidence.interaction.returnTarget -eq 'parent') { continue }
        if ([string]$evidence.interaction.action -ne 'submit') {
            Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '근거 추가를 취소했습니다.' -Layout $layout) -Layout $layout
            return $evidence.interaction
        }
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title '추가 자료를 연결했습니다.' -Message ("관련 AI 작업 {0}개를 다시 진행합니다." -f @($evidence.result.resetSteps).Count) -Layout $layout) -Layout $layout
        return
    }
}

function Get-DuoForgeInteractiveDecisionChangeContextInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Decision,
        [AllowNull()]$Issue
    )

    $questionTitle = [string](Get-DuoForgeObjectValue -Object $Decision -Name 'questionTitle' -Default '')
    $questionText = [string](Get-DuoForgeObjectValue -Object $Decision -Name 'questionText' -Default '')
    $questionWasStored = -not [string]::IsNullOrWhiteSpace($questionText)
    $issueForPresentation = $Issue
    if ($null -eq $issueForPresentation) {
        $issueForPresentation = [ordered]@{
            issueId = [string](Get-DuoForgeObjectValue -Object $Decision -Name 'issueId' -Default '')
            claim = [string](Get-DuoForgeObjectValue -Object $Decision -Name 'claim' -Default '')
            proposal = [string](Get-DuoForgeObjectValue -Object $Decision -Name 'proposal' -Default '')
            category = ''
            targetDocumentId = ''
            editorialDecisions = @()
            reviewerVerdicts = @()
        }
    }
    if ([string]::IsNullOrWhiteSpace($questionTitle)) {
        $questionTitle = [string](Get-DuoForgeObjectValue -Object $issueForPresentation -Name 'category' -Default '')
    }
    $question = [ordered]@{
        issueKey = [string](Get-DuoForgeObjectValue -Object $Decision -Name 'issueId' -Default '')
        title = $questionTitle
        question = $questionText
        options = @((Get-DuoForgeObjectValue -Object $Decision -Name 'questionOptions' -Default @()))
        recommendedOption = [string](Get-DuoForgeObjectValue -Object $Decision -Name 'recommendedOption' -Default '')
    }
    $presentation = Get-DuoForgeInteractiveQuestionPresentationInternal -Question $question -Issue $issueForPresentation
    $selectedOption = [string](Get-DuoForgeObjectValue -Object $Decision -Name 'selectedOption' -Default '')
    $decisionOptions = @($question.options)
    $selectedIndex = [array]::IndexOf([object[]]$decisionOptions, [object]$selectedOption)
    $currentAnswer = if ($selectedIndex -ge 0 -and $selectedIndex -lt @($presentation.options).Count) {
        '{0}안 · {1}' -f ($selectedIndex + 1), [string](Get-DuoForgeObjectValue -Object $presentation.options[$selectedIndex] -Name 'fullLabel' -Default ([string]$presentation.options[$selectedIndex].label))
    }
    else {
        '주관식 · ' + (Get-DuoForgeInteractiveReadableTextInternal -Text $selectedOption -MaximumCharacters 4000)
    }
    $requestPrompt = if ($questionWasStored) {
        Get-DuoForgeInteractiveReadableTextInternal -Text $questionText -MaximumCharacters 4000
    }
    else {
        [string](Get-DuoForgeObjectValue -Object $presentation -Name 'requestPromptFull' -Default ([string]$presentation.requestPrompt))
    }

    return [ordered]@{
        issueId = [string](Get-DuoForgeObjectValue -Object $Decision -Name 'issueId' -Default '')
        targetLabel = [string]$presentation.targetLabel
        subjectLabel = [string]$presentation.subjectLabel
        requestPrompt = $requestPrompt
        questionWasStored = $questionWasStored
        legacyNote = if ($questionWasStored) { '' } else { '당시 질문 문장은 없어 저장된 쟁점과 선택지로 복원했습니다.' }
        coreIssue = [string](Get-DuoForgeObjectValue -Object $presentation -Name 'coreIssueFull' -Default ([string]$presentation.coreIssue))
        proposalSummary = [string]$presentation.proposalSummary
        currentAnswer = $currentAnswer
        selectedIndex = $selectedIndex
        revision = [int](Get-DuoForgeObjectValue -Object $Decision -Name 'revision' -Default 1)
        options = @($presentation.options)
    }
}

function New-DuoForgeInteractiveDecisionChangeRowsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [ValidateRange(48, 400)][int]$Width,
        [ValidateRange(12, 200)][int]$Height
    )

    $layout = Get-DuoForgeDisplayLayoutInternal -Width $Width -Height $Height -NoColor
    $rows = [System.Collections.Generic.List[object]]::new()
    $append = { param([object[]]$Block) foreach ($row in @($Block)) { $rows.Add($row) } }
    & $append @(New-DuoForgePageHeaderRowsInternal -Title ("{0} · {1} · {2}" -f $Context.issueId, $Context.targetLabel, $Context.subjectLabel) -Tag '답변 변경' -Layout $layout)
    & $append @(New-DuoForgeSectionRowsInternal -Title '원래 질문' -Body ([string]$Context.requestPrompt) -Layout $layout -First -PreserveParagraphs)
    if (-not [string]::IsNullOrWhiteSpace([string]$Context.legacyNote)) {
        & $append @(New-DuoForgeSectionRowsInternal -Title '복원 안내' -Body ([string]$Context.legacyNote) -Layout $layout -BodyRole 'warning' -PreserveParagraphs)
    }
    & $append @(New-DuoForgeSectionRowsInternal -Title '확인할 핵심 내용' -Body ([string]$Context.coreIssue) -Layout $layout -PreserveParagraphs)
    & $append @(New-DuoForgeSectionRowsInternal -Title '현재 답변' -Body ([string]$Context.currentAnswer) -Layout $layout -BodyRole 'success' -PreserveParagraphs)
    return @($rows)
}

function Invoke-DuoForgeInteractiveDecisionChangeInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker,
        [scriptblock]$DecisionInvoker,
        [scriptblock]$ConstraintInvoker,
        [scriptblock]$DecisionChangeInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    $records = @(Read-DuoForgeJsonLines -Path (Join-Path ([string]$Run.runDirectory) 'decisions\user-answers.jsonl') -AllowMissing)
    $decisions = @(Get-DuoForgeEffectiveUserDecisionsInternal -Records $records | Where-Object { [string]$_.action -eq 'ANSWER' })
    if ($decisions.Count -eq 0) { Write-DuoForgeTextInternal '변경할 사용자 결정이 없습니다.'; return }
    $runIssues = @((Get-DuoForgeObjectValue -Object (Get-DuoForgeObjectValue -Object $Run -Name 'issues' -Default ([ordered]@{})) -Name 'issues' -Default @()))
    $contexts = [System.Collections.Generic.List[object]]::new()
    $items = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $decisions.Count; $index++) {
        $decisionIssue = @($runIssues | Where-Object { [string](Get-DuoForgeObjectValue -Object $_ -Name 'issueId' -Default '') -eq [string]$decisions[$index].issueId } | Select-Object -First 1)
        $context = Get-DuoForgeInteractiveDecisionChangeContextInternal -Decision $decisions[$index] -Issue $(if ($decisionIssue.Count -gt 0) { $decisionIssue[0] } else { $null })
        $contexts.Add($context)
        $items.Add([ordered]@{
            value = [string]$index
            label = ('{0} · {1} · {2}' -f $context.issueId, $context.targetLabel, $context.subjectLabel)
            detail = ('현재 답변 · {0}' -f $context.currentAnswer)
            shortcuts = @([string]($index + 1))
            enabled = $true
        })
    }
    $items.Add([ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('B'); enabled = $true })
    while ($true) {
    $selectionInteraction = Invoke-DuoForgeMenuInteractionInternal -Items @($items) -Title '변경할 답변을 선택해 주세요.' -ReturnTarget work-menu -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -MenuInvoker $MenuInvoker
    if ([string]$selectionInteraction.action -ne 'submit') { return $selectionInteraction }
    $selection = [string]$selectionInteraction.value
    $decision = $decisions[[int]$selection]
    $context = $contexts[[int]$selection]
    $viewWidth = 100
    $viewHeight = 30
    try {
        $viewWidth = [Math]::Max(48, [Math]::Min(400, [Console]::WindowWidth))
        $viewHeight = [Math]::Max(12, [Math]::Min(200, [Console]::WindowHeight))
    }
    catch { }
    $layout = Get-DuoForgeDisplayLayoutInternal -Width $viewWidth -Height $viewHeight
    $contextRows = @(New-DuoForgeInteractiveDecisionChangeRowsInternal -Context $context -Width $viewWidth -Height $viewHeight)
    Write-DuoForgeDisplayRowsInternal -Rows @(Add-DuoForgeTrailingSpacerRowInternal -Rows $contextRows) -Layout $layout
    $optionItems = [System.Collections.Generic.List[object]]::new()
    for ($optionIndex = 0; $optionIndex -lt @($context.options).Count; $optionIndex++) {
        $option = $context.options[$optionIndex]
        $detail = if ($optionIndex -eq [int]$context.selectedIndex) { '현재 답변입니다.' } else { '{0}안으로 변경합니다.' -f ($optionIndex + 1) }
        $optionItems.Add([ordered]@{ value = [string]$option.internalCode; label = [string]$option.label; detail = $detail; shortcuts = @([string]($optionIndex + 1), [string]$option.internalCode); enabled = $true })
    }
    $optionItems.Add([ordered]@{ value = 'custom'; label = '선택지에 없는 내 의견 직접 입력'; detail = '기존 답변을 주관식 답변으로 바꾸거나 여러 질문에 공통 전제를 추가합니다.'; shortcuts = @('O'); enabled = $true })
    $optionItems.Add([ordered]@{ value = 'back'; label = '답변 목록으로 돌아가기'; shortcuts = @('B'); enabled = $true })
    $initialSelectedIndex = if ([int]$context.selectedIndex -ge 0) { [int]$context.selectedIndex } else { 0 }
    $choiceInteraction = Invoke-DuoForgeMenuInteractionInternal -Items @($optionItems) -Title '새 답변을 선택하거나 O로 내 의견을 입력해 주세요.' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InitialSelectedIndex $initialSelectedIndex -InputReader $InputReader -MenuInvoker $MenuInvoker -ContextTransition
    if ([string]$choiceInteraction.action -eq 'back') { continue }
    if ([string]$choiceInteraction.action -ne 'submit') { return $choiceInteraction }
    $choice = [string]$choiceInteraction.value
    if ($choice -eq 'custom') {
        $customResult = Invoke-DuoForgeInteractiveCustomDecisionInternal -Run $Run -IssueId ([string]$decision.issueId) -InputReader $InputReader -MenuInvoker $MenuInvoker -DecisionInvoker $DecisionInvoker -ConstraintInvoker $ConstraintInvoker -ConfirmationKeyReader $ConfirmationKeyReader -ConfirmationFrameWriter $ConfirmationFrameWriter -ConfirmationCapabilityProbe $ConfirmationCapabilityProbe
        if ($null -ne $customResult -and [string](Get-DuoForgeObjectValue -Object $customResult -Name 'kind') -eq 'interaction') { return $customResult.interaction }
        return $customResult
    }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    try {
        $changed = if ($null -ne $DecisionChangeInvoker) {
            & $DecisionChangeInvoker ([string]$Run.state.runId) ([string]$decision.issueId) $choice $resultsRoot $true
        }
        else {
            Set-DuoForgeUserDecisionInternal -RunId ([string]$Run.state.runId) -IssueId ([string]$decision.issueId) -Action answer -Choice $choice -ResultsRoot $resultsRoot -ReplacePrevious
        }
        Write-DuoForgeTextInternal ("답변을 변경했습니다. 관련 AI 작업 {0}개를 다시 진행합니다." -f @($changed.resetSteps).Count) -ForegroundColor Green
        return $changed
    }
    catch {
        if ([string]$_.Exception.Data['DuoForgeCode'] -eq 'DF-DECISION-CHOICE') { Write-DuoForgeTextInternal '올바른 선택지를 입력해 주세요.' -ForegroundColor Yellow; continue }
        throw
    }
    }
}

function Invoke-DuoForgeInteractiveAbandonInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [scriptblock]$InputReader,
        [scriptblock]$AbandonInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    $layout = Get-DuoForgeDisplayLayoutInternal
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '이 작업을 포기하려고 합니다.' -Message 'AI 작업을 다시 이어갈 수 없게 되지만 문서 사본과 작업 기록은 보존됩니다.' -NextAction '계속하려면 확인어 ABANDON을 입력해 주세요.' -Layout $layout)) { $rows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 이름' -Value ([string]$Run.manifest.name) -Layout $layout -KeyWidth 12)) { $rows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 ID' -Value ([string]$Run.state.runId) -Layout $layout -KeyWidth 12 -Role 'meta')) { $rows.Add($row) }
    Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
    $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'ABANDON' -Prompt '작업을 포기하려면 ABANDON을 입력하세요' -ReturnTarget work-menu -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
    if ([string]$confirmation.action -ne 'submit') {
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '작업을 포기하지 않았습니다.' -Message '작업 상태와 저장 파일을 변경하지 않았습니다.' -Layout $layout) -Layout $layout
        return [ordered]@{ interaction = $confirmation; result = $null }
    }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $result = if ($null -ne $AbandonInvoker) { & $AbandonInvoker ([string]$Run.state.runId) $resultsRoot } else { Abandon-DuoForgeRunInternal -RunId ([string]$Run.state.runId) -ResultsRoot $resultsRoot }
    Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title '작업을 포기했습니다.' -Message '문서 사본과 작업 기록은 보존되며 홈의 포기한 작업 관리에서 영구 삭제할 수 있습니다.' -Layout $layout) -Layout $layout
    return [ordered]@{ interaction = $confirmation; result = $result }
}

function Invoke-DuoForgeInteractiveRestoreInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [scriptblock]$InputReader,
        [scriptblock]$RestoreInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    if ([string]$Run.state.status -ne 'CANCELLED') {
        throw (New-DuoForgeException -Code 'DF-RUN-RESTORE-STATE' -Message '복원은 포기한 작업에만 사용할 수 있습니다.')
    }
    $layout = Get-DuoForgeDisplayLayoutInternal
    $rows = [System.Collections.Generic.List[object]]::new()
    $abandonedFromStatus = [string](Get-DuoForgeObjectValue -Object $Run.state -Name 'abandonedFromStatus' -Default '')
    $restoreMessage = if ($abandonedFromStatus -in @('FAILED_STAGE', 'SOURCE_DRIFT')) { '작업은 원래 실패 상태로 돌아가며 AI 작업은 시작되지 않습니다.' } else { '작업은 사용자 요청으로 멈춘 상태로 돌아가며 AI 작업은 시작되지 않습니다.' }
    foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '이 작업을 복원하려고 합니다.' -Message $restoreMessage -NextAction '계속하려면 확인어 RESTORE를 입력해 주세요.' -Layout $layout)) { $rows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 이름' -Value ([string]$Run.manifest.name) -Layout $layout -KeyWidth 12)) { $rows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 ID' -Value ([string]$Run.state.runId) -Layout $layout -KeyWidth 12 -Role 'meta')) { $rows.Add($row) }
    Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
    $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'RESTORE' -Prompt '포기한 작업을 복원하려면 RESTORE를 입력하세요' -ReturnTarget work-menu -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
    if ([string]$confirmation.action -ne 'submit') {
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '작업을 복원하지 않았습니다.' -Message '작업 상태와 저장 파일을 변경하지 않았습니다.' -Layout $layout) -Layout $layout
        return [ordered]@{ interaction = $confirmation; result = $null }
    }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $result = if ($null -ne $RestoreInvoker) { & $RestoreInvoker ([string]$Run.state.runId) $resultsRoot } else { Restore-DuoForgeRunInternal -RunId ([string]$Run.state.runId) -ResultsRoot $resultsRoot }
    $restoredStatus = [string](Get-DuoForgeObjectValue -Object $result -Name 'status' -Default '')
    $restoredFailure = $restoredStatus -in @('FAILED_STAGE', 'SOURCE_DRIFT')
    $successMessage = if ($restoredFailure) { '원래 실패 상태로 돌아갔습니다. AI 작업은 시작하지 않았습니다.' } else { '사용자 요청으로 멈춘 상태로 돌아갔습니다. AI 작업은 시작하지 않았습니다.' }
    $nextAction = if ($restoredFailure) { '홈의 실패한 작업에서 기록을 확인하고, 가능한 경우 추가 시도를 준비해 주세요.' } else { '홈의 진행 중인 작업에서 내용을 확인한 뒤 직접 이어가 주세요.' }
    Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title '작업을 복원했습니다.' -Message $successMessage -NextAction $nextAction -Layout $layout) -Layout $layout
    return [ordered]@{ interaction = $confirmation; result = $result }
}

function Invoke-DuoForgeInteractiveDeleteInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [scriptblock]$InputReader,
        [scriptblock]$DeleteInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    if ([string]$Run.state.status -ne 'CANCELLED') {
        throw (New-DuoForgeException -Code 'DF-RUN-DELETE-STATE' -Message '영구 삭제는 먼저 포기한 작업에만 사용할 수 있습니다.')
    }
    $layout = Get-DuoForgeDisplayLayoutInternal
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind error -Title '이 작업을 영구 삭제하려고 합니다.' -Message '문서 사본, 작업 기록, 답변, 진단과 결과 파일이 모두 삭제되며 복구할 수 없습니다.' -NextAction '계속하려면 확인어 DELETE를 입력해 주세요.' -Layout $layout)) { $rows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 이름' -Value ([string]$Run.manifest.name) -Layout $layout -KeyWidth 12)) { $rows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 ID' -Value ([string]$Run.state.runId) -Layout $layout -KeyWidth 12 -Role 'meta')) { $rows.Add($row) }
    Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
    $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'DELETE' -Prompt '작업과 모든 저장 파일을 영구 삭제하려면 DELETE를 입력하세요' -ReturnTarget work-menu -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
    if ([string]$confirmation.action -ne 'submit') {
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '작업을 삭제하지 않았습니다.' -Message '작업 상태와 저장 파일을 변경하지 않았습니다.' -Layout $layout) -Layout $layout
        return [ordered]@{ interaction = $confirmation; result = $null }
    }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $result = if ($null -ne $DeleteInvoker) { & $DeleteInvoker ([string]$Run.state.runId) $resultsRoot } else { Remove-DuoForgeRunInternal -RunId ([string]$Run.state.runId) -ResultsRoot $resultsRoot }
    Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title '작업을 영구 삭제했습니다.' -Message '이 작업의 저장 파일은 복구할 수 없습니다.' -Layout $layout) -Layout $layout
    return [ordered]@{ interaction = $confirmation; result = $result }
}

function Invoke-DuoForgeInteractiveFailedRetryInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [scriptblock]$InputReader,
        [scriptblock]$RetryInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    $eligibility = Get-DuoForgeFailedStageRetryEligibilityInternal -RunDirectory ([string]$Run.runDirectory)
    if (-not [bool]$eligibility.eligible) {
        throw (New-DuoForgeException -Code 'DF-RUN-RETRY-UNAVAILABLE' -Message ([string]$eligibility.reason))
    }
    $step = $eligibility.step
    $runtimeExtension = [string]$eligibility.recoveryKind -eq 'runtime-extension'
    $layout = Get-DuoForgeDisplayLayoutInternal
    $rows = [System.Collections.Generic.List[object]]::new()
    $title = if ($runtimeExtension) { '이 실행의 총 실행시간을 60분 연장할 수 있게 준비합니다.' } else { '실패한 AI 작업을 한 번 더 시도할 수 있게 준비합니다.' }
    $message = if ($runtimeExtension) { '기본 90분과 누적 사용시간은 그대로 두고 유효 상한을 150분으로 한 번만 늘립니다. 이 확인만으로 AI를 호출하지 않으며 실제 계속하기에는 별도의 LIVE 확인이 필요합니다.' } else { '이 확인만으로 AI를 호출하지 않습니다. 준비 뒤 작업 계속하기에서 확인어 LIVE를 별도로 입력해야 하며 추가 시도는 1회뿐입니다.' }
    foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title $title -Message $message -NextAction '계속하려면 확인어 RETRY를 입력해 주세요.' -Layout $layout)) { $rows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '실패한 작업' -Value (Get-DuoForgeDisplayCheckpointLabelInternal -StepKey ([string]$step.stepKey) -RunDirectory ([string]$Run.runDirectory)) -Layout $layout -KeyWidth 14)) { $rows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '오류 코드' -Value ([string](Get-DuoForgeObjectValue -Object (Get-DuoForgeObjectValue -Object $step -Name 'lastError') -Name 'code' -Default '')) -Layout $layout -KeyWidth 14 -Role 'error')) { $rows.Add($row) }
    if ($runtimeExtension) {
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '총 실행시간' -Value '기본 90분 + 추가 60분 = 150분' -Layout $layout -KeyWidth 14)) { $rows.Add($row) }
    }
    Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
    $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'RETRY' -Prompt '추가 시도 1회를 준비하려면 RETRY를 입력하세요' -ReturnTarget work-menu -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
    if ([string]$confirmation.action -ne 'submit') {
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '다시 시도를 준비하지 않았습니다.' -Message '작업 상태와 저장 파일을 변경하지 않았고 AI도 호출하지 않았습니다.' -Layout $layout) -Layout $layout
        return [ordered]@{ interaction = $confirmation; result = $null }
    }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $result = if ($null -ne $RetryInvoker) { & $RetryInvoker ([string]$Run.state.runId) $resultsRoot } else { Enable-DuoForgeFailedStageRetryInternal -RunId ([string]$Run.state.runId) -ResultsRoot $resultsRoot }
    $successTitle = if ($runtimeExtension) { '총 실행시간을 60분 연장했습니다.' } else { '추가 시도 1회를 준비했습니다.' }
    Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title $successTitle -Message '아직 AI를 호출하지 않았습니다.' -NextAction '홈의 진행 중인 작업에서 이 작업을 열고, 계속하려면 별도의 LIVE 확인을 진행해 주세요.' -Layout $layout) -Layout $layout
    return [ordered]@{ interaction = $confirmation; result = $result }
}

function Invoke-DuoForgeInteractiveSchemaRepairInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [scriptblock]$InputReader,
        [scriptblock]$RepairInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    $eligibility = Get-DuoForgeSchemaRepairEligibilityInternal -RunDirectory ([string]$Run.runDirectory)
    if (-not [bool]$eligibility.eligible) {
        throw (New-DuoForgeException -Code 'DF-SCHEMA-REPAIR-UNAVAILABLE' -Message ([string]$eligibility.reason))
    }
    $layout = Get-DuoForgeDisplayLayoutInternal
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '쟁점 참조 오류를 한 번 복구할 수 있게 준비합니다.' -Message '새 쟁점 키 공간으로 바꾸고 현재 단계의 시도 계수만 초기화합니다. 이 확인만으로 AI를 호출하지 않으며 실제 계속하기에는 별도의 LIVE 확인이 필요합니다.' -NextAction '계속하려면 확인어 REPAIR를 입력해 주세요.' -Layout $layout)) { $rows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '실패한 작업' -Value (Get-DuoForgeDisplayCheckpointLabelInternal -StepKey ([string]$eligibility.step.stepKey) -RunDirectory ([string]$Run.runDirectory)) -Layout $layout -KeyWidth 14)) { $rows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '오류 분류' -Value '쟁점 참조 오류' -Layout $layout -KeyWidth 14 -Role 'error')) { $rows.Add($row) }
    Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
    $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'REPAIR' -Prompt '쟁점 참조 복구를 준비하려면 REPAIR를 입력하세요' -ReturnTarget work-menu -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
    if ([string]$confirmation.action -ne 'submit') {
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '쟁점 참조 복구를 준비하지 않았습니다.' -Message '작업 상태와 저장 파일을 변경하지 않았고 AI도 호출하지 않았습니다.' -Layout $layout) -Layout $layout
        return [ordered]@{ interaction = $confirmation; result = $null }
    }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $result = if ($null -ne $RepairInvoker) { & $RepairInvoker ([string]$Run.state.runId) $resultsRoot } else { Enable-DuoForgeSchemaRepairInternal -RunId ([string]$Run.state.runId) -ResultsRoot $resultsRoot }
    Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title '쟁점 참조 복구를 준비했습니다.' -Message '아직 AI를 호출하지 않았습니다.' -NextAction '홈의 진행 중인 작업에서 이 작업을 열고, 계속하려면 별도의 LIVE 확인을 진행해 주세요.' -Layout $layout) -Layout $layout
    return [ordered]@{ interaction = $confirmation; result = $result }
}

function Invoke-DuoForgeInteractivePromptRepairInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Run,
        [scriptblock]$InputReader,
        [scriptblock]$RepairInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    $eligibility = Get-DuoForgePromptRepairEligibilityInternal -RunDirectory ([string]$Run.runDirectory)
    if (-not [bool]$eligibility.eligible) {
        throw (New-DuoForgeException -Code 'DF-PROMPT-REPAIR-UNAVAILABLE' -Message ([string]$eligibility.reason))
    }
    $layout = Get-DuoForgeDisplayLayoutInternal
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '최종 확인 입력을 한 번 조정할 수 있게 준비합니다.' -Message '모든 선행 결과의 무결성은 확인하되, 대상 최신 문서와 관련 기록만 다음 요청에 넣습니다. 이 확인만으로 AI를 호출하지 않으며 실제 계속하기에는 별도의 LIVE 확인이 필요합니다.' -NextAction '계속하려면 확인어 REPAIR를 입력해 주세요.' -Layout $layout)) { $rows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '실패한 작업' -Value (Get-DuoForgeDisplayCheckpointLabelInternal -StepKey ([string]$eligibility.step.stepKey) -RunDirectory ([string]$Run.runDirectory)) -Layout $layout -KeyWidth 14)) { $rows.Add($row) }
    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '조정 후 크기' -Value ("{0:N0} / {1:N0} 바이트" -f [long]$eligibility.promptBytes, [long]$eligibility.maximumInputBytes) -Layout $layout -KeyWidth 14 -Role 'meta')) { $rows.Add($row) }
    Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
    $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'REPAIR' -Prompt '입력 크기 복구를 준비하려면 REPAIR를 입력하세요' -ReturnTarget work-menu -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
    if ([string]$confirmation.action -ne 'submit') {
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '입력 크기 복구를 준비하지 않았습니다.' -Message '작업 상태와 저장 파일을 변경하지 않았고 AI도 호출하지 않았습니다.' -Layout $layout) -Layout $layout
        return [ordered]@{ interaction = $confirmation; result = $null }
    }
    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$Run.runDirectory)
    $result = if ($null -ne $RepairInvoker) { & $RepairInvoker ([string]$Run.state.runId) $resultsRoot } else { Enable-DuoForgePromptRepairInternal -RunId ([string]$Run.state.runId) -ResultsRoot $resultsRoot }
    Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title '입력 크기 복구를 준비했습니다.' -Message '아직 AI를 호출하지 않았습니다.' -NextAction '홈의 진행 중인 작업에서 이 작업을 열고, 계속하려면 별도의 LIVE 확인을 진행해 주세요.' -Layout $layout) -Layout $layout
    return [ordered]@{ interaction = $confirmation; result = $result }
}

function Invoke-DuoForgeInteractiveRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RunRecord,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker,
        [scriptblock]$AbandonInvoker,
        [scriptblock]$RestoreInvoker,
        [scriptblock]$DeleteInvoker,
        [scriptblock]$RetryInvoker,
        [scriptblock]$RepairInvoker,
        [scriptblock]$PromptRepairInvoker
    )

    $resultsRoot = [System.IO.Path]::GetDirectoryName([string]$RunRecord.runDirectory)
    while ($true) {
        $run = ConvertTo-DuoForgeHashtable -InputObject (Get-DuoForgeRunInternal -RunId ([string]$RunRecord.runId) -ResultsRoot $resultsRoot)
        $runtimeLimitFailure = Test-DuoForgeRuntimeLimitFailureInternal -RunDirectory ([string]$run.runDirectory)
        $continuation = Get-DuoForgeContinuationEligibilityInternal -RunDirectory ([string]$run.runDirectory)
        $failureCode = [string]$continuation.failureCode
        $reviewProgress = Get-DuoForgeDecisionReviewProgressInternal -RunDirectory ([string]$run.runDirectory) -State $run.state -InferPendingGate
        $layout = Get-DuoForgeDisplayLayoutInternal
        $statusRows = [System.Collections.Generic.List[object]]::new()
        foreach ($row in @(New-DuoForgePageHeaderRowsInternal -Title ([string]$run.manifest.name) -Tag (Get-DuoForgeDisplayStateLabelInternal -Status ([string]$run.state.status) -FailureCode $(if ($runtimeLimitFailure) { 'DF-RUN-TIME-LIMIT' } else { $failureCode })) -Layout $layout)) { $statusRows.Add($row) }
        foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '현재 상태' -Body '' -Layout $layout -First)) { $statusRows.Add($row) }
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '마지막 완료' -Value (Get-DuoForgeDisplayCheckpointLabelInternal -StepKey ([string]$run.state.lastCompletedStage) -RunDirectory ([string]$run.runDirectory)) -Layout $layout -KeyWidth 14)) { $statusRows.Add($row) }
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '남은 확인 사항' -Value ("미해결 {0}개 · 계속하려면 해결할 사항 {1}개" -f @($run.state.openIssues).Count, @($run.state.blockingIssues).Count) -Layout $layout -KeyWidth 16)) { $statusRows.Add($row) }
        if ([int]$reviewProgress.cycle -gt 0) { foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '사용자 확인 단계' -Value ("{0}/{1}" -f $reviewProgress.cycle, $reviewProgress.maximum) -Layout $layout -KeyWidth 16 -Role 'meta')) { $statusRows.Add($row) } }
        if ([bool]$reviewProgress.limitReached) { foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '사용자 확인을 3번 거친 뒤 멈췄습니다.' -Message '답변을 세 차례 반영했지만 아직 사용자가 결정해야 할 내용이 남았습니다.' -NextAction '확인할 내용과 결과 문서를 검토해 주세요.' -Layout $layout)) { $statusRows.Add($row) } }
        Write-DuoForgeDisplayRowsInternal -Rows @(Add-DuoForgeTrailingSpacerRowInternal -Rows @($statusRows)) -Layout $layout
        $menuItems = [System.Collections.Generic.List[object]]::new()
        $terminalStates = @('COMPLETED', 'COMPLETED_PARTIAL', 'QUESTION_LIMIT_REACHED', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')
        $pendingQuestions = @(Get-DuoForgeInteractivePendingQuestionsInternal -RunDirectory ([string]$run.runDirectory))
        $pendingQuestionCount = $pendingQuestions.Count
        if ($pendingQuestionCount -gt 0 -and [string]$run.state.status -notin $terminalStates -and -not $runtimeLimitFailure) {
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
        if ($decisionRecords.Count -gt 0 -and [string]$run.state.status -notin $terminalStates -and -not $runtimeLimitFailure) { $menuItems.Add([ordered]@{ value = 'D'; label = '이전 답변 변경'; shortcuts = @('D'); enabled = $true }) }
        if ([string]$run.state.status -notin @('AWAITING_EVIDENCE') -and [string]$run.state.status -notin $terminalStates -and -not $runtimeLimitFailure -and [bool]$continuation.eligible) {
            $menuItems.Add([ordered]@{
                value = 'R'
                label = if ($pendingQuestionCount -gt 0) { '작업 계속하기 — 남은 질문 답변 후 가능' } else { '작업 계속하기' }
                shortcuts = @('R')
                enabled = $pendingQuestionCount -eq 0
                disabledReason = if ($pendingQuestionCount -gt 0) { "아직 답하지 않은 질문이 ${pendingQuestionCount}개 있습니다." } else { '' }
            })
        }
        if ([string]$run.state.status -notin @('PAUSED_USER') -and [string]$run.state.status -notin $terminalStates -and -not $runtimeLimitFailure -and [bool]$continuation.eligible) { $menuItems.Add([ordered]@{ value = 'P'; label = '현재 AI 작업이 끝난 뒤 멈추기'; shortcuts = @('P'); enabled = $true }) }
        $menuItems.Add([ordered]@{ value = 'I'; label = '확인할 내용 보기'; shortcuts = @('I'); enabled = $true })
        if (Test-Path -LiteralPath (Join-Path ([string]$run.runDirectory) 'final') -PathType Container) { $menuItems.Add([ordered]@{ value = 'O'; label = '결과 폴더 열기'; shortcuts = @('O'); enabled = $true }) }
        if ([string]$run.state.status -eq 'FAILED_STAGE' -or $runtimeLimitFailure) {
            $retryEligibility = Get-DuoForgeFailedStageRetryEligibilityInternal -RunDirectory ([string]$run.runDirectory)
            $runtimeExtension = [string]$retryEligibility.recoveryKind -eq 'runtime-extension'
            $menuItems.Add([ordered]@{
                value = 'retry-failed'
                label = if ($runtimeExtension) { '총 실행시간 60분 연장 준비' } else { '실패 단계 한 번 더 시도 준비' }
                detail = if ($runtimeExtension) { '기본 90분을 보존하고 유효 상한을 150분으로 한 번만 늘립니다. 실제 계속하기에는 별도의 LIVE 확인이 필요합니다.' } else { '이 동작은 AI를 호출하지 않으며, 실제 시도에는 별도의 LIVE 확인이 필요합니다.' }
                shortcuts = @('T')
                enabled = [bool]$retryEligibility.eligible
                disabledReason = if ([bool]$retryEligibility.eligible) { '' } else { [string]$retryEligibility.reason }
            })
            if ([string]$run.state.status -eq 'FAILED_STAGE') {
                $repairEligibility = Get-DuoForgeSchemaRepairEligibilityInternal -RunDirectory ([string]$run.runDirectory)
                if (@($repairEligibility.failures).Count -gt 0) {
                    $menuItems.Add([ordered]@{
                        value = 'repair-schema'
                        label = '쟁점 참조 복구 준비'
                        detail = '새 쟁점 키 공간으로 한 번만 준비하며, 실제 계속하기에는 별도의 LIVE 확인이 필요합니다.'
                        shortcuts = @('Y')
                        enabled = [bool]$repairEligibility.eligible
                        disabledReason = if ([bool]$repairEligibility.eligible) { '' } else { [string]$repairEligibility.reason }
                    })
                }
            }
        }
        if ($failureCode -eq 'DF-PROMPT-SIZE-LIMIT') {
            $promptRepairEligibility = Get-DuoForgePromptRepairEligibilityInternal -RunDirectory ([string]$run.runDirectory)
            $menuItems.Add([ordered]@{
                value = 'repair-prompt'
                label = '입력 크기 조정 준비'
                detail = '대상 최신 문서와 관련 기록만 전송하도록 한 번만 준비하며, 실제 계속하기에는 별도의 LIVE 확인이 필요합니다.'
                shortcuts = @('Y')
                enabled = [bool]$promptRepairEligibility.eligible
                disabledReason = if ([bool]$promptRepairEligibility.eligible) { '' } else { [string]$promptRepairEligibility.reason }
            })
        }
        if ([string]$run.state.status -eq 'CANCELLED') {
            $abandonedFromStatus = [string](Get-DuoForgeObjectValue -Object $run.state -Name 'abandonedFromStatus' -Default '')
            $restoreDetail = if ($abandonedFromStatus -in @('FAILED_STAGE', 'SOURCE_DRIFT')) { '원래 실패 상태로 되돌리며 AI 작업은 시작하지 않습니다.' } else { '사용자 요청으로 멈춘 상태로 되돌리며 AI 작업은 시작하지 않습니다.' }
            $menuItems.Add([ordered]@{ value = 'restore'; label = '이 작업 복원'; detail = $restoreDetail; shortcuts = @('R'); enabled = $true })
            $menuItems.Add([ordered]@{ value = 'delete'; label = '이 작업 영구 삭제'; detail = '문서 사본과 모든 작업 기록을 복구할 수 없게 삭제합니다.'; shortcuts = @('X'); enabled = $true })
        }
        elseif ([string]$run.state.status -notin $terminalStates -or [string]$run.state.status -in @('FAILED_STAGE', 'SOURCE_DRIFT')) {
            $menuItems.Add([ordered]@{ value = 'abandon'; label = '이 작업 포기'; detail = '다시 이어갈 수 없게 종료하지만 저장된 기록은 남깁니다.'; shortcuts = @('X'); enabled = $true })
        }
        $menuItems.Add([ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('B'); enabled = $true })
        $choiceInteraction = Invoke-DuoForgeMenuInteractionInternal -Items @($menuItems) -Title '다음 동작' -ReturnTarget home -CancelReturnTarget home -InterruptReturnTarget home -InputReader $InputReader -MenuInvoker $MenuInvoker -ContextTransition
        if ([string]$choiceInteraction.action -ne 'submit') { return $choiceInteraction }
        $choice = [string]$choiceInteraction.value
        if ($choice -ieq 'A' -and $pendingQuestionCount -gt 0 -and [string]$run.state.status -notin $terminalStates) { $null = Invoke-DuoForgeInteractiveQuestion -Run $run -InputReader $InputReader -MenuInvoker $MenuInvoker; continue }
        if ($choice -ieq 'E' -and [string]$run.state.status -eq 'AWAITING_EVIDENCE') { $null = Invoke-DuoForgeInteractiveEvidence -Run $run -InputReader $InputReader -MenuInvoker $MenuInvoker; continue }
        if ($choice -ieq 'D' -and $decisionRecords.Count -gt 0 -and [string]$run.state.status -notin @('COMPLETED', 'COMPLETED_PARTIAL', 'QUESTION_LIMIT_REACHED', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')) {
            $decisionChangeResult = Invoke-DuoForgeInteractiveDecisionChangeInternal -Run $run -InputReader $InputReader -MenuInvoker $MenuInvoker
            if ($null -ne $decisionChangeResult -and [string](Get-DuoForgeObjectValue -Object $decisionChangeResult -Name 'returnTarget') -eq 'work-menu') { continue }
            continue
        }
        if ($choice -ieq 'R' -and $pendingQuestionCount -eq 0 -and [string]$run.state.status -notin @('AWAITING_EVIDENCE') -and [string]$run.state.status -notin $terminalStates) { $null = Invoke-DuoForgeInteractiveLiveResume -Run $run -InputReader $InputReader; continue }
        if ($choice -ieq 'P' -and [string]$run.state.status -notin @('PAUSED_USER', 'COMPLETED', 'COMPLETED_PARTIAL', 'QUESTION_LIMIT_REACHED', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED')) {
            $pause = Request-DuoForgePauseInternal -RunId ([string]$run.state.runId) -ResultsRoot $resultsRoot
            if ($pause.alreadyRequested) { Write-DuoForgeTextInternal ('이미 일시정지가 요청되어 있습니다: {0}' -f $pause.requestId) }
            else { Write-DuoForgeTextInternal '멈추기를 요청했습니다. 현재 AI 작업이 끝난 뒤 멈춥니다.' -ForegroundColor Green }
            continue
        }
        if ($choice -ieq 'I') { Write-DuoForgeIssueList -Issues @($run.issues.issues); continue }
        if ($choice -ieq 'O') {
            $finalDirectory = Join-Path ([string]$run.runDirectory) 'final'
            if (Test-Path -LiteralPath $finalDirectory -PathType Container) { Start-Process -FilePath 'explorer.exe' -ArgumentList @($finalDirectory); continue }
        }
        if ($choice -ieq 'retry-failed' -and ([string]$run.state.status -eq 'FAILED_STAGE' -or $runtimeLimitFailure)) {
            $outcome = Invoke-DuoForgeInteractiveFailedRetryInternal -Run $run -InputReader $InputReader -RetryInvoker $RetryInvoker
            if ($null -ne $outcome.result) { return [ordered]@{ action = 'submit'; value = 'retry-failed'; source = 'menu'; returnTarget = 'home' } }
            continue
        }
        if ($choice -ieq 'repair-schema' -and [string]$run.state.status -eq 'FAILED_STAGE') {
            $outcome = Invoke-DuoForgeInteractiveSchemaRepairInternal -Run $run -InputReader $InputReader -RepairInvoker $RepairInvoker
            if ($null -ne $outcome.result) { return [ordered]@{ action = 'submit'; value = 'repair-schema'; source = 'menu'; returnTarget = 'home' } }
            continue
        }
        if ($choice -ieq 'repair-prompt' -and $failureCode -eq 'DF-PROMPT-SIZE-LIMIT') {
            $outcome = Invoke-DuoForgeInteractivePromptRepairInternal -Run $run -InputReader $InputReader -RepairInvoker $PromptRepairInvoker
            if ($null -ne $outcome.result) { return [ordered]@{ action = 'submit'; value = 'repair-prompt'; source = 'menu'; returnTarget = 'home' } }
            continue
        }
        if ($choice -ieq 'abandon') {
            $outcome = Invoke-DuoForgeInteractiveAbandonInternal -Run $run -InputReader $InputReader -AbandonInvoker $AbandonInvoker
            if ($null -ne $outcome.result) { return [ordered]@{ action = 'submit'; value = 'abandon'; source = 'menu'; returnTarget = 'home' } }
            continue
        }
        if ($choice -ieq 'restore') {
            $outcome = Invoke-DuoForgeInteractiveRestoreInternal -Run $run -InputReader $InputReader -RestoreInvoker $RestoreInvoker
            if ($null -ne $outcome.result) { return [ordered]@{ action = 'submit'; value = 'restore'; source = 'menu'; returnTarget = 'home' } }
            continue
        }
        if ($choice -ieq 'delete') {
            $outcome = Invoke-DuoForgeInteractiveDeleteInternal -Run $run -InputReader $InputReader -DeleteInvoker $DeleteInvoker
            if ($null -ne $outcome.result) { return [ordered]@{ action = 'submit'; value = 'delete'; source = 'menu'; returnTarget = 'home' } }
            continue
        }
        Write-DuoForgeTextInternal '올바른 항목을 선택해 주세요.' -ForegroundColor Yellow
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
        $failedStates = @('FAILED_STAGE', 'SOURCE_DRIFT')
        $runtimeLimitedRunIds = @($runs | Where-Object { [string]$_.status -eq 'RESUMABLE_ERROR' -and (Test-DuoForgeRuntimeLimitFailureInternal -RunDirectory ([string]$_.runDirectory)) } | ForEach-Object { [string]$_.runId })
        $recoveryRequiredRunIds = @($runs | Where-Object {
            if ([string]$_.status -ne 'RESUMABLE_ERROR') { return $false }
            try { return -not [bool](Get-DuoForgeContinuationEligibilityInternal -RunDirectory ([string]$_.runDirectory)).eligible } catch { return $false }
        } | ForEach-Object { [string]$_.runId })
        $failedLikeRunIds = @($runtimeLimitedRunIds + $recoveryRequiredRunIds | Sort-Object -Unique)
        $activeCount = @($runs | Where-Object { $_.status -notin @('COMPLETED', 'COMPLETED_PARTIAL', 'QUESTION_LIMIT_REACHED', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED') -and [string]$_.runId -notin $failedLikeRunIds }).Count
        $failedCount = @($runs | Where-Object { $_.status -in $failedStates -or [string]$_.runId -in $failedLikeRunIds }).Count
        $abandonedCount = @($runs | Where-Object { $_.status -eq 'CANCELLED' }).Count
        Write-DuoForgeDisplaySpacerInternal
        $choiceInteraction = Invoke-DuoForgeMenuInteractionInternal -Title 'DuoForge' -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -Footer '↑/↓ 이동 · Home/End · Enter 선택 · Esc/Q 종료' -InputReader $InputReader -MenuInvoker $MenuInvoker -Items @(
            [ordered]@{ value = '1'; label = '새 작업 시작'; shortcuts = @('1'); enabled = $true }
            [ordered]@{ value = '2'; label = "진행 중인 작업 보기 ($activeCount)"; shortcuts = @('2'); enabled = $true }
            [ordered]@{ value = '3'; label = '완료된 결과 보기'; shortcuts = @('3'); enabled = $true }
            [ordered]@{ value = '4'; label = "실패한 작업 확인 ($failedCount)"; shortcuts = @('4'); enabled = $true }
            [ordered]@{ value = '5'; label = "포기한 작업 관리 ($abandonedCount)"; shortcuts = @('5'); enabled = $true }
            [ordered]@{ value = '6'; label = '실행 환경 확인, 로그인 및 설정'; shortcuts = @('6'); enabled = $true }
            [ordered]@{ value = 'exit'; label = '종료'; shortcuts = @('Q'); enabled = $true }
        )
        if ([string]$choiceInteraction.action -ne 'submit') { return }
        $choice = [string]$choiceInteraction.value
        switch -Regex ($choice) {
            '^(1)$' {
                if (-not [bool]$setupReport.readyForDocumentModes) {
                    $setupReport = & $invokeSetup $false
                    if (-not [bool]$setupReport.readyForDocumentModes) { Write-DuoForgeTextInternal '두 구독 실행 환경이 준비되기 전에는 새 작업을 시작할 수 없습니다.' -ForegroundColor Yellow; continue }
                }
                $null = Invoke-DuoForgeInteractiveNew -InputReader $InputReader -MenuInvoker $MenuInvoker
            }
            '^(2|3|4|5)$' {
                if ($runs.Count -eq 0) { Write-DuoForgeTextInternal '저장된 실행이 없습니다.'; continue }
                $candidates = @(if ($choice -eq '2') {
                    $runs | Where-Object { $_.status -notin @('COMPLETED', 'COMPLETED_PARTIAL', 'QUESTION_LIMIT_REACHED', 'FAILED_STAGE', 'SOURCE_DRIFT', 'CANCELLED') -and [string]$_.runId -notin $failedLikeRunIds }
                }
                elseif ($choice -eq '3') {
                    $runs | Where-Object { $_.status -in @('COMPLETED', 'COMPLETED_PARTIAL', 'QUESTION_LIMIT_REACHED') }
                }
                elseif ($choice -eq '4') { $runs | Where-Object { $_.status -in $failedStates -or [string]$_.runId -in $failedLikeRunIds } }
                else { $runs | Where-Object { $_.status -eq 'CANCELLED' } })
                if ($candidates.Count -eq 0) {
                    $emptyMessage = if ($choice -eq '2') { '진행 중인 작업이 없습니다.' } elseif ($choice -eq '3') { '완료된 결과가 없습니다.' } elseif ($choice -eq '4') { '실패한 작업이 없습니다.' } else { '포기한 작업이 없습니다.' }
                    Write-DuoForgeTextInternal $emptyMessage
                    continue
                }
                $selected = Select-DuoForgeInteractiveRun -Runs $candidates -Prompt '작업을 선택해 주세요.' -InputReader $InputReader -MenuInvoker $MenuInvoker
                if ($null -ne $selected) { $null = Invoke-DuoForgeInteractiveRun -RunRecord $selected -InputReader $InputReader -MenuInvoker $MenuInvoker }
            }
            '^(6)$' {
                $setupReport = & $invokeSetup $true
            }
            '^(exit)$' { return }
            default { Write-DuoForgeTextInternal '올바른 항목을 선택해 주세요.' -ForegroundColor Yellow }
        }
    }
}
