function Invoke-DuoForgeCliCoreInternal {
    [CmdletBinding()]
    param(
        [string[]]$Arguments = @(),
        [scriptblock]$InputReader,
        [scriptblock]$ResumeInvoker,
        [scriptblock]$ProviderInvoker,
        [scriptblock]$ValidationInvoker,
        [scriptblock]$RunInvoker,
        [scriptblock]$DecisionInvoker,
        [scriptblock]$AbandonInvoker,
        [scriptblock]$RestoreInvoker,
        [scriptblock]$DeleteInvoker,
        [scriptblock]$RetryInvoker,
        [scriptblock]$RepairInvoker,
        [scriptblock]$PromptRepairInvoker,
        [scriptblock]$InteractiveHostProbe,
        [scriptblock]$InteractiveHomeInvoker,
        [scriptblock]$ConfirmationKeyReader,
        [scriptblock]$ConfirmationFrameWriter,
        [scriptblock]$ConfirmationCapabilityProbe
    )

    if ($null -eq $Arguments) { $Arguments = @() }
    $isInteractive = { if ($null -ne $InteractiveHostProbe) { return [bool](& $InteractiveHostProbe) }; return [bool](Test-DuoForgeInteractiveHost) }
    if ($Arguments.Count -eq 0) {
        if (& $isInteractive) {
            if ($null -ne $InteractiveHomeInvoker) { $null = & $InteractiveHomeInvoker }
            else { $null = Invoke-DuoForgeInteractiveHome }
        }
        else {
            Write-DuoForgeHelp
        }
        return
    }

    $parsed = ConvertFrom-DuoForgeCliArguments -Arguments $Arguments
    $command = if ($parsed.positionals.Count -gt 0) { [string]$parsed.positionals[0] } else { 'help' }
    switch ($command.ToLowerInvariant()) {
        'help' { Write-DuoForgeHelp; return }
        '--help' { Write-DuoForgeHelp; return }
        '-h' { Write-DuoForgeHelp; return }
        'doctor' {
            $report = Invoke-DuoForgeDoctorInternal
            if ([bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'json' -Default $false)) {
                $report | ConvertTo-Json -Depth 100
            }
            else {
                Write-DuoForgeDoctorReport -Report $report
            }
            return
        }
        'list' {
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $runs = @(Get-DuoForgeRunsInternal -ResultsRoot $workspace)
            if ([bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'json' -Default $false)) { $runs | ConvertTo-Json -Depth 20 }
            else {
                $layout = Get-DuoForgeDisplayLayoutInternal
                if ($runs.Count -eq 0) {
                    Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '저장된 작업이 없습니다.' -NextAction '새 작업을 시작하거나 다른 --workspace를 확인해 주세요.' -Layout $layout) -Layout $layout
                }
                else {
                    $displayRows = [System.Collections.Generic.List[object]]::new()
                    foreach ($row in @(New-DuoForgePageHeaderRowsInternal -Title '저장된 작업' -Tag ("{0}개" -f $runs.Count) -Layout $layout)) { $displayRows.Add($row) }
                    for ($index = 0; $index -lt $runs.Count; $index++) {
                        $item = $runs[$index]
                        foreach ($row in @(New-DuoForgeSectionRowsInternal -Title ("{0} · {1}" -f $item.name, (Get-DuoForgeDisplayStateLabelInternal -Status ([string]$item.status))) -Body '' -Layout $layout -First:($index -eq 0))) { $displayRows.Add($row) }
                        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 방식' -Value (Get-DuoForgeDisplayModeLabelInternal -Mode ([string]$item.mode)) -Layout $layout -KeyWidth 12)) { $displayRows.Add($row) }
                        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '최근 변경' -Value ([string]$item.updatedAt) -Layout $layout -KeyWidth 12)) { $displayRows.Add($row) }
                        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 ID' -Value ([string]$item.runId) -Layout $layout -KeyWidth 12 -Role 'meta')) { $displayRows.Add($row) }
                    }
                    Write-DuoForgeDisplayRowsInternal -Rows @($displayRows) -Layout $layout
                }
            }
            return
        }
        'status' {
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw (New-DuoForgeException -Code 'DF-CLI-RUN' -Message 'status에는 --run <실행 ID>가 필요합니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace
            if ([bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'json' -Default $false)) { $run | ConvertTo-Json -Depth 100 }
            else {
                $layout = Get-DuoForgeDisplayLayoutInternal
                $displayRows = [System.Collections.Generic.List[object]]::new()
                foreach ($row in @(New-DuoForgePageHeaderRowsInternal -Title ([string]$run.manifest.name) -Tag (Get-DuoForgeDisplayStateLabelInternal -Status ([string]$run.state.status)) -Layout $layout)) { $displayRows.Add($row) }
                foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '현재 상태' -Body '' -Layout $layout -First)) { $displayRows.Add($row) }
                foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 방식' -Value (Get-DuoForgeDisplayModeLabelInternal -Mode ([string]$run.state.mode)) -Layout $layout -KeyWidth 18)) { $displayRows.Add($row) }
                foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '토론 회차' -Value ([string]$run.state.round) -Layout $layout -KeyWidth 18)) { $displayRows.Add($row) }
                foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '마지막 완료' -Value (Get-DuoForgeDisplayCheckpointLabelInternal -StepKey ([string]$run.state.lastCompletedStage) -RunDirectory ([string]$run.runDirectory)) -Layout $layout -KeyWidth 18)) { $displayRows.Add($row) }
                foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 ID' -Value ([string]$run.state.runId) -Layout $layout -KeyWidth 18 -Role 'meta')) { $displayRows.Add($row) }
                Write-DuoForgeDisplayRowsInternal -Rows @($displayRows) -Layout $layout
            }
            return
        }
        'issues' {
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw (New-DuoForgeException -Code 'DF-CLI-RUN' -Message 'issues에는 --run <실행 ID>가 필요합니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace
            if ([bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'json' -Default $false)) { $run.issues | ConvertTo-Json -Depth 100 }
            else { Write-DuoForgeIssueList -Issues @($run.issues.issues) }
            return
        }
        'explain' {
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            $issueId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'issue' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId) -or [string]::IsNullOrWhiteSpace($issueId)) {
                throw (New-DuoForgeException -Code 'DF-CLI-EXPLAIN' -Message 'explain에는 --run과 --issue가 필요합니다.')
            }
            $provider = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'provider' -Default 'both')
            $level = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'level' -Default 'general')
            $focus = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'focus' -Default 'general')
            if ($provider -notin @('codex', 'claude', 'both')) { throw (New-DuoForgeException -Code 'DF-CLI-EXPLAIN-PROVIDER' -Message 'provider는 codex, claude 또는 both여야 합니다.') }
            if ($level -notin @('beginner', 'general', 'expert')) { throw (New-DuoForgeException -Code 'DF-CLI-EXPLAIN-LEVEL' -Message 'level은 beginner, general 또는 expert여야 합니다.') }
            if ($focus -notin @('general', 'evidence', 'examples', 'tradeoffs', 'experiment')) { throw (New-DuoForgeException -Code 'DF-CLI-EXPLAIN-FOCUS' -Message 'focus 값이 지원 목록에 없습니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $existing = Get-DuoForgeIssueExplanationsInternal -RunId $runId -IssueId $issueId -ResultsRoot $workspace
            if (-not [bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'live' -Default $false)) {
                Write-DuoForgeExplanationRecords -Records @($existing.explanations)
                $layout = Get-DuoForgeDisplayLayoutInternal
                Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title ('추가 설명 요청 · 사용 {0}/{1}회, 요청 가능 {2}회' -f $existing.budget.used, $existing.budget.maximum, $existing.budget.remaining) -NextAction '새 설명을 요청하려면 --live를 추가해 다시 실행해 주세요.' -Layout $layout) -Layout $layout
                return
            }
            if (-not (& $isInteractive)) { throw (New-DuoForgeException -Code 'DF-LIVE-NONINTERACTIVE' -Message 'AI에 실제 설명을 요청하려면 대화형 PowerShell에서 확인해야 합니다.') }
            $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace
            $requiredCalls = if ($provider -eq 'both') { 2 } else { 1 }
            if ([int]$existing.budget.remaining -lt $requiredCalls) { throw (New-DuoForgeException -Code 'DF-EXPLANATION-LIMIT' -Message '추가 설명을 요청할 수 있는 횟수가 부족합니다.') }
            $layout = Get-DuoForgeDisplayLayoutInternal
            $confirmationRows = [System.Collections.Generic.List[object]]::new()
            $providerLabel = switch ($provider) { 'codex' { 'Codex' } 'claude' { 'Claude' } 'both' { 'Codex와 Claude 비교' } }
            $levelLabel = switch ($level) { 'beginner' { '쉽게' } 'general' { '일반' } 'expert' { '전문가' } }
            foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title 'AI에 새 설명을 요청하려고 합니다.' -Message ('확인할 내용 {0} · {1} · 설명 수준 {2}' -f $issueId, $providerLabel, $levelLabel) -NextAction '아래 설정과 요청 횟수를 확인한 뒤 확인어 LIVE를 입력해 주세요.' -Layout $layout)) { $confirmationRows.Add($row) }
            foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '사용할 AI 설정' -Body '' -Layout $layout)) { $confirmationRows.Add($row) }
            foreach ($row in @(New-DuoForgeProviderSelectionRowsInternal -ProviderSelections $run.manifest.providerSelections -Layout $layout)) { $confirmationRows.Add($row) }
            foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '추가 설명 요청 횟수' -Body '' -Layout $layout)) { $confirmationRows.Add($row) }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '이번 요청' -Value ('{0}회' -f $requiredCalls) -Layout $layout -KeyWidth 12 -Role 'warning')) { $confirmationRows.Add($row) }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '요청 가능' -Value ('{0}회' -f $existing.budget.remaining) -Layout $layout -KeyWidth 12 -Role 'warning')) { $confirmationRows.Add($row) }
            Write-DuoForgeDisplayRowsInternal -Rows @($confirmationRows) -Layout $layout
            $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'LIVE' -Prompt 'AI에 설명을 요청하려면 LIVE를 입력하세요' -ReturnTarget shell -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
            if ([string]$confirmation.action -ne 'submit') { Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '설명을 요청하지 않았습니다.' -Message '공급자 호출 또는 설명 기록 변경이 발생하지 않았습니다.' -Layout $layout) -Layout $layout; return }
            $result = Invoke-DuoForgeIssueExplanationInternal -RunId $runId -IssueId $issueId -Provider $provider -Level $level -Focus $focus -ResultsRoot $workspace -LiveConsent $true -ProviderInvoker $ProviderInvoker
            Write-DuoForgeExplanationRecords -Records @($result.explanations)
            Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title '새 설명을 받았습니다.' -Message ('사용 {0}/{1}회 · 추가 요청 가능 {2}회' -f $result.budget.used, $result.budget.maximum, $result.budget.remaining) -Layout $layout) -Layout $layout
            return
        }
        'evidence' {
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            $issueId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'issue' -Default '')
            $file = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'file' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId) -or [string]::IsNullOrWhiteSpace($issueId) -or [string]::IsNullOrWhiteSpace($file)) {
                throw (New-DuoForgeException -Code 'DF-CLI-EVIDENCE' -Message 'evidence에는 --run, --issue, --file이 필요합니다.')
            }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $result = Add-DuoForgeIssueEvidenceInternal -RunId $runId -IssueId $issueId -File $file -ResultsRoot $workspace
            $result | ConvertTo-Json -Depth 30
            return
        }
        'answer' {
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            $issueId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'issue' -Default '')
            $choice = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'choice' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId) -or [string]::IsNullOrWhiteSpace($issueId) -or [string]::IsNullOrWhiteSpace($choice)) {
                throw (New-DuoForgeException -Code 'DF-CLI-ANSWER' -Message 'answer에는 --run, --issue, --choice가 필요합니다.')
            }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $replace = [bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'replace' -Default $false)
            $result = Set-DuoForgeUserDecisionInternal -RunId $runId -IssueId $issueId -Action answer -Choice $choice -ResultsRoot $workspace -ReplacePrevious:$replace
            $result | ConvertTo-Json -Depth 30
            return
        }
        'constraint' {
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            $issueId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'issue' -Default '')
            $text = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'text' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId) -or [string]::IsNullOrWhiteSpace($issueId) -or [string]::IsNullOrWhiteSpace($text)) {
                throw (New-DuoForgeException -Code 'DF-CLI-CONSTRAINT' -Message 'constraint에는 --run, --issue, --text가 필요합니다.')
            }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $confirm = [bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'confirm' -Default $false)
            if ($confirm) {
                $result = Set-DuoForgeUserConstraintInternal -RunId $runId -IssueId $issueId -Text $text -ResultsRoot $workspace -Confirm
            }
            else {
                $result = New-DuoForgeDecisionConstraintPreviewInternal -RunId $runId -IssueId $issueId -Text $text -ResultsRoot $workspace
            }
            $result | ConvertTo-Json -Depth 30
            return
        }
        'extend-round' {
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw (New-DuoForgeException -Code 'DF-CLI-RUN' -Message 'extend-round에는 --run <실행 ID>가 필요합니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            Add-DuoForgeRoundInternal -RunId $runId -ResultsRoot $workspace | ConvertTo-Json -Depth 30
            return
        }
        'defer' {
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            $issueId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'issue' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId) -or [string]::IsNullOrWhiteSpace($issueId)) {
                throw (New-DuoForgeException -Code 'DF-CLI-DEFER' -Message 'defer에는 --run과 --issue가 필요합니다.')
            }
            $confirmed = [bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'confirm-partial' -Default $false)
            if (-not $confirmed) {
                if (-not (& $isInteractive)) { throw (New-DuoForgeException -Code 'DF-DEFER-CONFIRM' -Message '비대화형 보류에는 --confirm-partial이 필요합니다.') }
                $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'DEFER' -Prompt '반드시 확인할 내용을 보류하면 일부 범위만 완료됩니다. DEFER를 입력하세요' -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
                $confirmed = [string]$confirmation.action -eq 'submit'
            }
            if (-not $confirmed) { $layout = Get-DuoForgeDisplayLayoutInternal; Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '보류를 적용하지 않았습니다.' -Message '답변·파일·단계 상태를 변경하지 않았습니다.' -Layout $layout) -Layout $layout; return }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $result = if ($null -ne $DecisionInvoker) {
                & $DecisionInvoker $runId $issueId 'defer' $workspace $true
            }
            else {
                Set-DuoForgeUserDecisionInternal -RunId $runId -IssueId $issueId -Action defer -ResultsRoot $workspace -ConfirmPartial
            }
            $result | ConvertTo-Json -Depth 30
            return
        }
        'pause' {
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw (New-DuoForgeException -Code 'DF-CLI-RUN' -Message 'pause에는 --run <실행 ID>가 필요합니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $result = Request-DuoForgePauseInternal -RunId $runId -ResultsRoot $workspace
            $layout = Get-DuoForgeDisplayLayoutInternal
            if ($result.alreadyPaused) { Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '이미 사용자 일시정지 상태입니다.' -Layout $layout) -Layout $layout }
            elseif ($result.alreadyRequested) { Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '이미 일시정지가 요청되어 있습니다.' -Code ([string]$result.requestId) -Layout $layout) -Layout $layout }
            else { Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title '멈추기를 요청했습니다.' -Message '현재 AI 작업이 있다면 끝난 뒤 멈춥니다.' -Code ([string]$result.requestId) -Layout $layout) -Layout $layout }
            return
        }
        'abandon' {
            $null = Assert-DuoForgeCliOptionsInternal -Parsed $parsed -AllowedNames @('run', 'workspace', 'confirm-abandon')
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw (New-DuoForgeException -Code 'DF-CLI-RUN' -Message 'abandon에는 --run <실행 ID>가 필요합니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace
            $confirmed = [bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'confirm-abandon' -Default $false)
            if (-not $confirmed) {
                if (-not (& $isInteractive)) { throw (New-DuoForgeException -Code 'DF-RUN-ABANDON-CONFIRM' -Message '비대화형 작업 포기에는 --confirm-abandon이 필요합니다.') }
                $layout = Get-DuoForgeDisplayLayoutInternal
                $rows = [System.Collections.Generic.List[object]]::new()
                foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '이 작업을 포기하려고 합니다.' -Message 'AI 작업을 다시 이어갈 수 없게 되지만 문서 사본과 작업 기록은 보존됩니다.' -NextAction '계속하려면 확인어 ABANDON을 입력해 주세요.' -Layout $layout)) { $rows.Add($row) }
                foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 이름' -Value ([string]$run.manifest.name) -Layout $layout -KeyWidth 12)) { $rows.Add($row) }
                foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 ID' -Value $runId -Layout $layout -KeyWidth 12 -Role 'meta')) { $rows.Add($row) }
                Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
                $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'ABANDON' -Prompt '작업을 포기하려면 ABANDON을 입력하세요' -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
                $confirmed = [string]$confirmation.action -eq 'submit'
            }
            if (-not $confirmed) { $layout = Get-DuoForgeDisplayLayoutInternal; Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '작업을 포기하지 않았습니다.' -Message '작업 상태와 저장 파일을 변경하지 않았습니다.' -Layout $layout) -Layout $layout; return }
            $result = if ($null -ne $AbandonInvoker) { & $AbandonInvoker $runId $workspace } else { Abandon-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace }
            $layout = Get-DuoForgeDisplayLayoutInternal
            Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title '작업을 포기했습니다.' -Message '문서 사본과 작업 기록은 보존되며 포기한 작업 관리에서 영구 삭제할 수 있습니다.' -Layout $layout) -Layout $layout
            return $result
        }
        'restore' {
            $null = Assert-DuoForgeCliOptionsInternal -Parsed $parsed -AllowedNames @('run', 'workspace', 'confirm-restore')
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw (New-DuoForgeException -Code 'DF-CLI-RUN' -Message 'restore에는 --run <실행 ID>가 필요합니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace
            if ([string]$run.state.status -ne 'CANCELLED') { throw (New-DuoForgeException -Code 'DF-RUN-RESTORE-STATE' -Message '복원은 포기한 작업에만 사용할 수 있습니다.') }
            $confirmRestore = Get-DuoForgeCliOption -Parsed $parsed -Name 'confirm-restore' -Default $false
            if ($parsed.options.Contains('confirm-restore') -and $confirmRestore -isnot [bool]) {
                throw (New-DuoForgeException -Code 'DF-CLI-OPTION' -Message '--confirm-restore는 값을 붙이지 않은 확인 플래그로만 사용할 수 있습니다.')
            }
            $confirmed = [bool]$confirmRestore
            if (-not $confirmed) {
                if (-not (& $isInteractive)) { throw (New-DuoForgeException -Code 'DF-RUN-RESTORE-CONFIRM' -Message '비대화형 작업 복원에는 --confirm-restore가 필요합니다.') }
                $layout = Get-DuoForgeDisplayLayoutInternal
                $rows = [System.Collections.Generic.List[object]]::new()
                $abandonedFromStatus = [string](Get-DuoForgeObjectValue -Object $run.state -Name 'abandonedFromStatus' -Default '')
                $restoreMessage = if ($abandonedFromStatus -in @('FAILED_STAGE', 'SOURCE_DRIFT')) { '작업은 원래 실패 상태로 돌아가며 AI 작업은 시작되지 않습니다.' } else { '작업은 사용자 요청으로 멈춘 상태로 돌아가며 AI 작업은 시작되지 않습니다.' }
                foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '이 작업을 복원하려고 합니다.' -Message $restoreMessage -NextAction '계속하려면 확인어 RESTORE를 입력해 주세요.' -Layout $layout)) { $rows.Add($row) }
                foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 이름' -Value ([string]$run.manifest.name) -Layout $layout -KeyWidth 12)) { $rows.Add($row) }
                foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 ID' -Value $runId -Layout $layout -KeyWidth 12 -Role 'meta')) { $rows.Add($row) }
                Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
                $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'RESTORE' -Prompt '포기한 작업을 복원하려면 RESTORE를 입력하세요' -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
                $confirmed = [string]$confirmation.action -eq 'submit'
            }
            if (-not $confirmed) { $layout = Get-DuoForgeDisplayLayoutInternal; Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '작업을 복원하지 않았습니다.' -Message '작업 상태와 저장 파일을 변경하지 않았습니다.' -Layout $layout) -Layout $layout; return }
            $result = if ($null -ne $RestoreInvoker) { & $RestoreInvoker $runId $workspace } else { Restore-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace }
            $layout = Get-DuoForgeDisplayLayoutInternal
            $restoredStatus = [string](Get-DuoForgeObjectValue -Object $result -Name 'status' -Default '')
            $restoredFailure = $restoredStatus -in @('FAILED_STAGE', 'SOURCE_DRIFT')
            $successMessage = if ($restoredFailure) { '원래 실패 상태로 돌아갔습니다. AI 작업은 시작하지 않았습니다.' } else { '사용자 요청으로 멈춘 상태로 돌아갔습니다. AI 작업은 시작하지 않았습니다.' }
            $nextAction = if ($restoredFailure) { '실패한 작업 기록을 확인하고, 가능한 경우 retry-failed 명령으로 추가 시도를 준비해 주세요.' } else { '내용을 확인한 뒤 resume 명령으로 직접 이어가 주세요.' }
            Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title '작업을 복원했습니다.' -Message $successMessage -NextAction $nextAction -Layout $layout) -Layout $layout
            return $result
        }
        'retry-failed' {
            $null = Assert-DuoForgeCliOptionsInternal -Parsed $parsed -AllowedNames @('run', 'workspace', 'confirm-retry')
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw (New-DuoForgeException -Code 'DF-CLI-RUN' -Message 'retry-failed에는 --run <실행 ID>가 필요합니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace
            $eligibility = Get-DuoForgeFailedStageRetryEligibilityInternal -RunDirectory ([string]$run.runDirectory)
            if (-not [bool]$eligibility.eligible) { throw (New-DuoForgeException -Code 'DF-RUN-RETRY-UNAVAILABLE' -Message ([string]$eligibility.reason)) }
            $runtimeExtension = [string]$eligibility.recoveryKind -eq 'runtime-extension'
            $confirmRetry = Get-DuoForgeCliOption -Parsed $parsed -Name 'confirm-retry' -Default $false
            if ($parsed.options.Contains('confirm-retry') -and $confirmRetry -isnot [bool]) {
                throw (New-DuoForgeException -Code 'DF-CLI-OPTION' -Message '--confirm-retry는 값을 붙이지 않은 확인 플래그로만 사용할 수 있습니다.')
            }
            if ($runtimeExtension -and [bool]$confirmRetry) {
                throw (New-DuoForgeException -Code 'DF-RUN-RETRY-CONFIRM' -Message '총 실행시간 연장은 대화형 화면에서 정확한 RETRY 확인이 필요합니다.')
            }
            $confirmed = -not $runtimeExtension -and [bool]$confirmRetry
            if (-not $confirmed) {
                if (-not (& $isInteractive)) {
                    $confirmMessage = if ($runtimeExtension) { '총 실행시간 연장은 대화형 화면에서 정확한 RETRY 확인이 필요합니다.' } else { '비대화형 추가 시도 준비에는 --confirm-retry가 필요합니다.' }
                    throw (New-DuoForgeException -Code 'DF-RUN-RETRY-CONFIRM' -Message $confirmMessage)
                }
                $layout = Get-DuoForgeDisplayLayoutInternal
                $rows = [System.Collections.Generic.List[object]]::new()
                $title = if ($runtimeExtension) { '이 실행의 총 실행시간을 60분 연장할 수 있게 준비합니다.' } else { '실패한 AI 작업을 한 번 더 시도할 수 있게 준비합니다.' }
                $message = if ($runtimeExtension) { '기본 90분과 누적 사용시간은 그대로 두고 유효 상한을 150분으로 한 번만 늘립니다. 이 확인만으로 AI를 호출하지 않으며 실제 계속하기에는 별도의 LIVE 확인이 필요합니다.' } else { '이 확인만으로 AI를 호출하지 않습니다. 준비 뒤 실제 시도에는 별도의 LIVE 확인이 필요합니다.' }
                foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title $title -Message $message -NextAction '계속하려면 확인어 RETRY를 입력해 주세요.' -Layout $layout)) { $rows.Add($row) }
                foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '실패한 작업' -Value (Get-DuoForgeDisplayCheckpointLabelInternal -StepKey ([string]$eligibility.step.stepKey) -RunDirectory ([string]$run.runDirectory)) -Layout $layout -KeyWidth 14)) { $rows.Add($row) }
                foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '오류 코드' -Value ([string](Get-DuoForgeObjectValue -Object (Get-DuoForgeObjectValue -Object $eligibility.step -Name 'lastError') -Name 'code' -Default '')) -Layout $layout -KeyWidth 14 -Role 'error')) { $rows.Add($row) }
                if ($runtimeExtension) {
                    foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '총 실행시간' -Value '기본 90분 + 추가 60분 = 150분' -Layout $layout -KeyWidth 14)) { $rows.Add($row) }
                }
                Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
                $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'RETRY' -Prompt '추가 시도 1회를 준비하려면 RETRY를 입력하세요' -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
                $confirmed = [string]$confirmation.action -eq 'submit'
            }
            if (-not $confirmed) { $layout = Get-DuoForgeDisplayLayoutInternal; Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '다시 시도를 준비하지 않았습니다.' -Message '작업 상태와 저장 파일을 변경하지 않았고 AI도 호출하지 않았습니다.' -Layout $layout) -Layout $layout; return }
            $result = if ($null -ne $RetryInvoker) { & $RetryInvoker $runId $workspace } else { Enable-DuoForgeFailedStageRetryInternal -RunId $runId -ResultsRoot $workspace }
            $layout = Get-DuoForgeDisplayLayoutInternal
            $successTitle = if ($runtimeExtension) { '총 실행시간을 60분 연장했습니다.' } else { '추가 시도 1회를 준비했습니다.' }
            Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title $successTitle -Message '아직 AI를 호출하지 않았습니다.' -NextAction '내용을 확인한 뒤 resume --live에서 별도의 LIVE 확인을 진행해 주세요.' -Layout $layout) -Layout $layout
            return $result
        }
        'repair-schema' {
            $null = Assert-DuoForgeCliOptionsInternal -Parsed $parsed -AllowedNames @('run', 'workspace')
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw (New-DuoForgeException -Code 'DF-CLI-RUN' -Message 'repair-schema에는 --run <실행 ID>가 필요합니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace
            $eligibility = Get-DuoForgeSchemaRepairEligibilityInternal -RunDirectory ([string]$run.runDirectory)
            if (-not [bool]$eligibility.eligible) { throw (New-DuoForgeException -Code 'DF-SCHEMA-REPAIR-UNAVAILABLE' -Message ([string]$eligibility.reason)) }
            if (-not (& $isInteractive)) {
                throw (New-DuoForgeException -Code 'DF-SCHEMA-REPAIR-CONFIRM' -Message '쟁점 참조 복구는 대화형 화면에서 정확한 REPAIR 확인이 필요합니다.')
            }
            $layout = Get-DuoForgeDisplayLayoutInternal
            $rows = [System.Collections.Generic.List[object]]::new()
            foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '쟁점 참조 오류를 한 번 복구할 수 있게 준비합니다.' -Message '새 쟁점 키 공간으로 바꾸고 현재 단계의 시도 계수만 초기화합니다. 이 확인만으로 AI를 호출하지 않으며 실제 계속하기에는 별도의 LIVE 확인이 필요합니다.' -NextAction '계속하려면 확인어 REPAIR를 입력해 주세요.' -Layout $layout)) { $rows.Add($row) }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '실패한 작업' -Value (Get-DuoForgeDisplayCheckpointLabelInternal -StepKey ([string]$eligibility.step.stepKey) -RunDirectory ([string]$run.runDirectory)) -Layout $layout -KeyWidth 14)) { $rows.Add($row) }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '오류 분류' -Value '쟁점 참조 오류' -Layout $layout -KeyWidth 14 -Role 'error')) { $rows.Add($row) }
            Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
            $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'REPAIR' -Prompt '쟁점 참조 복구를 준비하려면 REPAIR를 입력하세요' -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
            if ([string]$confirmation.action -ne 'submit') {
                Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '쟁점 참조 복구를 준비하지 않았습니다.' -Message '작업 상태와 저장 파일을 변경하지 않았고 AI도 호출하지 않았습니다.' -Layout $layout) -Layout $layout
                return
            }
            $result = if ($null -ne $RepairInvoker) { & $RepairInvoker $runId $workspace } else { Enable-DuoForgeSchemaRepairInternal -RunId $runId -ResultsRoot $workspace }
            Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title '쟁점 참조 복구를 준비했습니다.' -Message '아직 AI를 호출하지 않았습니다.' -NextAction '내용을 확인한 뒤 resume --live에서 별도의 LIVE 확인을 진행해 주세요.' -Layout $layout) -Layout $layout
            return $result
        }
        'repair-prompt' {
            $null = Assert-DuoForgeCliOptionsInternal -Parsed $parsed -AllowedNames @('run', 'workspace')
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw (New-DuoForgeException -Code 'DF-CLI-RUN' -Message 'repair-prompt에는 --run <실행 ID>가 필요합니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace
            $eligibility = Get-DuoForgePromptRepairEligibilityInternal -RunDirectory ([string]$run.runDirectory)
            if (-not [bool]$eligibility.eligible) { throw (New-DuoForgeException -Code 'DF-PROMPT-REPAIR-UNAVAILABLE' -Message ([string]$eligibility.reason)) }
            if (-not (& $isInteractive)) {
                throw (New-DuoForgeException -Code 'DF-PROMPT-REPAIR-CONFIRM' -Message '입력 크기 복구는 대화형 화면에서 정확한 REPAIR 확인이 필요합니다.')
            }
            $layout = Get-DuoForgeDisplayLayoutInternal
            $rows = [System.Collections.Generic.List[object]]::new()
            foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '최종 확인 입력을 한 번 조정할 수 있게 준비합니다.' -Message '모든 선행 결과의 무결성은 확인하되, 대상 최신 문서와 관련 기록만 다음 요청에 넣습니다. 이 확인만으로 AI를 호출하지 않으며 실제 계속하기에는 별도의 LIVE 확인이 필요합니다.' -NextAction '계속하려면 확인어 REPAIR를 입력해 주세요.' -Layout $layout)) { $rows.Add($row) }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '실패한 작업' -Value (Get-DuoForgeDisplayCheckpointLabelInternal -StepKey ([string]$eligibility.step.stepKey) -RunDirectory ([string]$run.runDirectory)) -Layout $layout -KeyWidth 14)) { $rows.Add($row) }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '조정 후 크기' -Value ("{0:N0} / {1:N0} 바이트" -f [long]$eligibility.promptBytes, [long]$eligibility.maximumInputBytes) -Layout $layout -KeyWidth 14 -Role 'meta')) { $rows.Add($row) }
            Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
            $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'REPAIR' -Prompt '입력 크기 복구를 준비하려면 REPAIR를 입력하세요' -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
            if ([string]$confirmation.action -ne 'submit') {
                Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '입력 크기 복구를 준비하지 않았습니다.' -Message '작업 상태와 저장 파일을 변경하지 않았고 AI도 호출하지 않았습니다.' -Layout $layout) -Layout $layout
                return
            }
            $result = if ($null -ne $PromptRepairInvoker) { & $PromptRepairInvoker $runId $workspace } else { Enable-DuoForgePromptRepairInternal -RunId $runId -ResultsRoot $workspace }
            Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title '입력 크기 복구를 준비했습니다.' -Message '아직 AI를 호출하지 않았습니다.' -NextAction '내용을 확인한 뒤 resume --live에서 별도의 LIVE 확인을 진행해 주세요.' -Layout $layout) -Layout $layout
            return $result
        }
        'delete' {
            $null = Assert-DuoForgeCliOptionsInternal -Parsed $parsed -AllowedNames @('run', 'workspace', 'confirm-delete')
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw (New-DuoForgeException -Code 'DF-CLI-RUN' -Message 'delete에는 --run <실행 ID>가 필요합니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace
            if ([string]$run.state.status -ne 'CANCELLED') { throw (New-DuoForgeException -Code 'DF-RUN-DELETE-STATE' -Message '영구 삭제는 먼저 포기한 작업에만 사용할 수 있습니다.') }
            $confirmed = [bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'confirm-delete' -Default $false)
            if (-not $confirmed) {
                if (-not (& $isInteractive)) { throw (New-DuoForgeException -Code 'DF-RUN-DELETE-CONFIRM' -Message '비대화형 영구 삭제에는 --confirm-delete가 필요합니다.') }
                $layout = Get-DuoForgeDisplayLayoutInternal
                $rows = [System.Collections.Generic.List[object]]::new()
                foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind error -Title '이 작업을 영구 삭제하려고 합니다.' -Message '문서 사본, 작업 기록, 답변, 진단과 결과 파일이 모두 삭제되며 복구할 수 없습니다.' -NextAction '계속하려면 확인어 DELETE를 입력해 주세요.' -Layout $layout)) { $rows.Add($row) }
                foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 이름' -Value ([string]$run.manifest.name) -Layout $layout -KeyWidth 12)) { $rows.Add($row) }
                foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '작업 ID' -Value $runId -Layout $layout -KeyWidth 12 -Role 'meta')) { $rows.Add($row) }
                Write-DuoForgeDisplayRowsInternal -Rows @($rows) -Layout $layout
                $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'DELETE' -Prompt '작업과 모든 저장 파일을 영구 삭제하려면 DELETE를 입력하세요' -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
                $confirmed = [string]$confirmation.action -eq 'submit'
            }
            if (-not $confirmed) { $layout = Get-DuoForgeDisplayLayoutInternal; Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '작업을 삭제하지 않았습니다.' -Message '작업 상태와 저장 파일을 변경하지 않았습니다.' -Layout $layout) -Layout $layout; return }
            $result = if ($null -ne $DeleteInvoker) { & $DeleteInvoker $runId $workspace } else { Remove-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace }
            $layout = Get-DuoForgeDisplayLayoutInternal
            Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind success -Title '작업을 영구 삭제했습니다.' -Message '이 작업의 저장 파일은 복구할 수 없습니다.' -Layout $layout) -Layout $layout
            return $result
        }
        'resume' {
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw (New-DuoForgeException -Code 'DF-CLI-RUN' -Message 'resume에는 --run <실행 ID>가 필요합니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace
            $budget = Get-DuoForgeRemainingCallBudget -RunDirectory ([string]$run.runDirectory)
            $continuation = Get-DuoForgeContinuationEligibilityInternal -RunDirectory ([string]$run.runDirectory)
            if (-not [bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'live' -Default $false)) {
                $layout = Get-DuoForgeDisplayLayoutInternal
                $displayRows = [System.Collections.Generic.List[object]]::new()
                foreach ($row in @(New-DuoForgePageHeaderRowsInternal -Title '작업 재개 안내' -Tag (Get-DuoForgeDisplayStateLabelInternal -Status ([string]$run.state.status) -FailureCode ([string]$continuation.failureCode)) -Layout $layout)) { $displayRows.Add($row) }
                foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '현재 상태' -Body '' -Layout $layout -First)) { $displayRows.Add($row) }
                $nextAction = '상태를 확인한 뒤 계속할 수 있습니다.'
                if ([string]$run.state.status -eq 'AWAITING_EVIDENCE') { $nextAction = '요청된 Markdown 자료를 evidence 명령으로 추가한 뒤 계속해 주세요.' }
                elseif ([string]$run.state.status -eq 'PAUSED_QUOTA') { $nextAction = '사용 한도가 회복되고 구독 로그인이 유효한 뒤 계속해 주세요. API 과금 방식으로 자동 전환하지 않습니다.' }
                elseif ([string]$run.state.status -eq 'BLOCKED_PREFLIGHT') { $nextAction = 'doctor와 Codex·Claude 구독 로그인을 다시 확인한 뒤 계속해 주세요.' }
                elseif ([string]$run.state.status -eq 'PAUSED_USER') { $nextAction = '마지막 완료 지점부터 계속할 수 있습니다.' }
                elseif (-not [bool]$continuation.eligible -and [string]$continuation.recoveryKind -eq 'prompt-size-repair') { $nextAction = 'repair-prompt 명령에서 입력 크기 조정을 준비한 뒤 다시 확인해 주세요.' }
                foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind info -Title (Get-DuoForgeDisplayStateLabelInternal -Status ([string]$run.state.status) -FailureCode ([string]$continuation.failureCode)) -NextAction $nextAction -Layout $layout)) { $displayRows.Add($row) }
                foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '계속하면 실행되는 AI 작업' -Body '' -Layout $layout)) { $displayRows.Add($row) }
                foreach ($row in @(New-DuoForgeFieldRowsInternal -Label 'Codex' -Value (Format-DuoForgeRemainingCallBudgetLineInternal -ProviderLabel 'Codex' -ProviderBudget $budget.providers.codex) -Layout $layout -KeyWidth 8 -PreserveParagraphs)) { $displayRows.Add($row) }
                foreach ($row in @(New-DuoForgeFieldRowsInternal -Label 'Claude' -Value (Format-DuoForgeRemainingCallBudgetLineInternal -ProviderLabel 'Claude' -ProviderBudget $budget.providers.claude) -Layout $layout -KeyWidth 8 -PreserveParagraphs)) { $displayRows.Add($row) }
                foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '아직 AI 작업을 시작하지 않았습니다.' -NextAction '문서를 전송하고 AI 작업을 시작하려면 --live를 추가해 다시 실행해 주세요.' -Layout $layout)) { $displayRows.Add($row) }
                Write-DuoForgeDisplayRowsInternal -Rows @($displayRows) -Layout $layout
                return
            }
            if (-not [bool]$continuation.eligible) {
                throw (New-DuoForgeException -Code 'DF-RUN-RECOVERY-REQUIRED' -Message ([string]$continuation.reason))
            }
            if ([string]$run.state.status -eq 'AWAITING_EVIDENCE') {
                throw (New-DuoForgeException -Code 'DF-EVIDENCE-REQUIRED' -Message '요청된 자료를 먼저 추가해야 AI 작업을 계속할 수 있습니다.')
            }
            if (-not (& $isInteractive)) {
                throw (New-DuoForgeException -Code 'DF-LIVE-NONINTERACTIVE' -Message 'AI 작업을 실제로 계속하려면 대화형 PowerShell에서 확인해야 합니다.')
            }
            $selections = Get-DuoForgeRunProviderSelectionsInternal -RunDirectory ([string]$run.runDirectory)
            $layout = Get-DuoForgeDisplayLayoutInternal
            $confirmationRows = [System.Collections.Generic.List[object]]::new()
            $blockedWorkItems = [int]$budget.providers.codex.blockedWorkItems + [int]$budget.providers.claude.blockedWorkItems
            if ($blockedWorkItems -gt 0) { throw (New-DuoForgeException -Code 'DF-STAGE-ATTEMPT-LIMIT' -Message "허용된 AI 요청 횟수를 모두 사용한 작업이 ${blockedWorkItems}개 있어 계속할 수 없습니다. 오류 내용을 확인한 뒤 해당 작업을 다시 준비해 주세요.") }
            foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title 'Codex와 Claude에 문서를 보내 작업을 계속하려고 합니다.' -Message '작업 시작 때 보관한 문서와 이후 추가한 자료·답변·조건이 두 AI에 전송됩니다.' -NextAction '아래 설정과 최대 요청 횟수를 확인한 뒤 확인어 LIVE를 입력해 주세요.' -Layout $layout)) { $confirmationRows.Add($row) }
            foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '사용할 AI 설정' -Body '' -Layout $layout)) { $confirmationRows.Add($row) }
            foreach ($row in @(New-DuoForgeProviderSelectionRowsInternal -ProviderSelections $selections -Layout $layout)) { $confirmationRows.Add($row) }
            foreach ($row in @(New-DuoForgeSectionRowsInternal -Title '계속하면 실행되는 AI 작업' -Body '' -Layout $layout)) { $confirmationRows.Add($row) }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label 'Codex' -Value (Format-DuoForgeRemainingCallBudgetLineInternal -ProviderLabel 'Codex' -ProviderBudget $budget.providers.codex) -Layout $layout -KeyWidth 8 -Role 'warning' -PreserveParagraphs)) { $confirmationRows.Add($row) }
            foreach ($row in @(New-DuoForgeFieldRowsInternal -Label 'Claude' -Value (Format-DuoForgeRemainingCallBudgetLineInternal -ProviderLabel 'Claude' -ProviderBudget $budget.providers.claude) -Layout $layout -KeyWidth 8 -Role 'warning' -PreserveParagraphs)) { $confirmationRows.Add($row) }
            Write-DuoForgeDisplayRowsInternal -Rows @($confirmationRows) -Layout $layout
            $confirmation = Read-DuoForgeExactConfirmationInternal -Token 'LIVE' -Prompt '문서 전송과 AI 작업 시작에 동의하면 LIVE를 입력하세요' -ReturnTarget shell -InputReader $InputReader -KeyReader $ConfirmationKeyReader -FrameWriter $ConfirmationFrameWriter -CapabilityProbe $ConfirmationCapabilityProbe
            if ([string]$confirmation.action -ne 'submit') { Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title 'AI 작업을 시작하지 않았습니다.' -Message '재개, 공급자 호출 또는 실행 기록 변경이 발생하지 않았습니다.' -Layout $layout) -Layout $layout; return }
            $result = if ($null -ne $ResumeInvoker) { & $ResumeInvoker $runId $workspace $true } else { Invoke-DuoForgeResumeWithProgressInternal -RunId $runId -ResultsRoot $workspace -WaitForAcknowledgement -ReturnTarget shell }
            $result | ConvertTo-Json -Depth 30
            return
        }
        'start' {
            if ($parsed.positionals.Count -lt 2) { throw (New-DuoForgeException -Code 'DF-CLI-MODE' -Message 'start에는 모드가 필요합니다.') }
            $null = Assert-DuoForgeCliOptionsInternal -Parsed $parsed -AllowedNames @(
                'brief', 'document-a', 'document-b', 'document-a-context', 'document-b-context',
                'codex', 'claude', 'codex-context', 'claude-context', 'codex-project', 'claude-project', 'requirements',
                'codex-model', 'codex-effort', 'claude-model', 'claude-effort', 'type', 'max-rounds', 'workspace',
                'first-synthesizer', 'pause-after-round', 'allow-partial', 'name', 'plan-only'
            )
            $mode = [string]$parsed.positionals[1]
            $rounds = ConvertTo-DuoForgeIntOption -Value (Get-DuoForgeCliOption -Parsed $parsed -Name 'max-rounds' -Default 2) -Name 'max-rounds' -Default 2
            $providerSelections = [ordered]@{
                codex = [ordered]@{
                    model = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'codex-model' -Default '')
                    reasoningEffort = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'codex-effort' -Default '')
                }
                claude = [ordered]@{
                    model = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'claude-model' -Default '')
                    reasoningEffort = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'claude-effort' -Default '')
                }
            }
            $selectionValidation = Test-DuoForgeProviderSelectionsInternal -Selections $providerSelections
            if (-not $selectionValidation.valid -and (& $isInteractive)) {
                $providerSelections = Complete-DuoForgeInteractiveProviderSelectionsInternal -InitialSelections $providerSelections
                if ($null -eq $providerSelections) { $layout = Get-DuoForgeDisplayLayoutInternal; Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '모델 선택을 취소했습니다.' -Layout $layout) -Layout $layout; return }
            }
            $request = New-DuoForgeStartRequestInternal `
                -Mode $mode `
                -Brief ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'brief' -Default '')) `
                -DocumentA ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'document-a' -Default '')) `
                -DocumentB ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'document-b' -Default '')) `
                -DocumentAContext ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'document-a-context' -Default '')) `
                -DocumentBContext ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'document-b-context' -Default '')) `
                -CodexDocument ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'codex' -Default '')) `
                -ClaudeDocument ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'claude' -Default '')) `
                -CodexContext ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'codex-context' -Default '')) `
                -ClaudeContext ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'claude-context' -Default '')) `
                -CodexProject ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'codex-project' -Default '')) `
                -ClaudeProject ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'claude-project' -Default '')) `
                -Requirements ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'requirements' -Default '')) `
                -CodexModel ([string]$providerSelections.codex.model) `
                -CodexReasoningEffort ([string]$providerSelections.codex.reasoningEffort) `
                -ClaudeModel ([string]$providerSelections.claude.model) `
                -ClaudeReasoningEffort ([string]$providerSelections.claude.reasoningEffort) `
                -DocumentType ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'type' -Default 'custom')) `
                -MaxRounds $rounds `
                -Workspace ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')) `
                -FirstSynthesizer ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'first-synthesizer' -Default 'alternate')) `
                -PauseAfterRound ([bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'pause-after-round' -Default $false)) `
                -AllowPartial ([bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'allow-partial' -Default $false)) `
                -Name ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'name' -Default ''))
            $validation = Test-DuoForgeStartRequestInternal -Request $request
            $partialConfirmation = Confirm-DuoForgeInteractivePartialAnalysisInternal -Validation $validation -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -InputReader $InputReader -ValidationInvoker $ValidationInvoker -ConfirmationKeyReader $ConfirmationKeyReader -ConfirmationFrameWriter $ConfirmationFrameWriter -ConfirmationCapabilityProbe $ConfirmationCapabilityProbe
            $validation = $partialConfirmation.validation
            if ($null -ne $partialConfirmation.interaction -and [string]$partialConfirmation.interaction.action -ne 'submit') {
                $layout = Get-DuoForgeDisplayLayoutInternal
                Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '부분 분석 동의를 적용하지 않았습니다.' -Message '새 작업, 문서 사본 또는 실행 기록을 만들지 않았습니다.' -Layout $layout) -Layout $layout
                return
            }
            if (-not $validation.valid) { Write-DuoForgeValidationErrors -Validation $validation; throw (New-DuoForgeException -Code 'DF-START-BLOCKED' -Message '실행 전 검증에 실패했습니다.') }
            Write-DuoForgeExecutionPlan -Validation $validation
            if ([bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'plan-only' -Default $false)) { return }
            if (-not (& $isInteractive)) {
                throw (New-DuoForgeException -Code 'DF-CONFIRM-NONINTERACTIVE' -Message '새 작업을 만들기 전에 대화형 사용자 확인이 필요합니다. 비대화형 환경에서는 --plan-only를 사용해 주세요.')
            }
            $creation = Invoke-DuoForgeRunCreationBoundaryInternal -Validation $validation -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -InputReader $InputReader -RunInvoker $RunInvoker -ConfirmationKeyReader $ConfirmationKeyReader -ConfirmationFrameWriter $ConfirmationFrameWriter -ConfirmationCapabilityProbe $ConfirmationCapabilityProbe
            if ([string]$creation.interaction.action -ne 'submit') { $layout = Get-DuoForgeDisplayLayoutInternal; Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '작업 생성을 취소했습니다.' -Message '문서 사본과 작업 기록을 만들지 않았습니다.' -Layout $layout) -Layout $layout; return }
            $run = $creation.run
            $run | ConvertTo-Json -Depth 20
            return
        }
        default { throw (New-DuoForgeException -Code 'DF-CLI-COMMAND' -Message "알 수 없는 명령입니다: $command") }
    }
}

function Invoke-DuoForgeCli {
    [CmdletBinding()]
    param([string[]]$Arguments = @())

    if ($null -eq $Arguments) { $Arguments = @() }
    try {
        return Invoke-DuoForgeCliCoreInternal -Arguments $Arguments
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        throw
    }
    catch {
        $originalError = $_
        if (-not $originalError.Exception.Data.Contains('DuoForgeDiagnosticId')) {
            $runDirectory = ''
            $runContext = $null
            try {
                $parsed = ConvertFrom-DuoForgeCliArguments -Arguments $Arguments
                $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($runId)) {
                    $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
                    $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace
                    $runDirectory = [string]$run.runDirectory
                    $runContext = [ordered]@{ runId = $runId; workflowVersion = Get-DuoForgeWorkflowVersionInternal -Manifest $run.manifest; status = Get-DuoForgeObjectValue -Object $run.state -Name 'status'; lastCompletedStage = Get-DuoForgeObjectValue -Object $run.state -Name 'lastCompletedStage' }
                }
            }
            catch { }
            $code = if ($originalError.Exception.Data.Contains('DuoForgeCode')) { [string]$originalError.Exception.Data['DuoForgeCode'] } else { 'DF-CLI-UNEXPECTED' }
            $diagnostic = Write-DuoForgeDiagnosticInternal -RunDirectory $runDirectory -Code $code -Category 'cli' -Phase 'cli' -Scope 'local' -Run $runContext -ErrorRecord $originalError
            Add-DuoForgeDiagnosticMetadataToExceptionInternal -Exception $originalError.Exception -Diagnostic $diagnostic
        }
        throw $originalError.Exception
    }
}
