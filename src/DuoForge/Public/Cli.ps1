function Invoke-DuoForgeCli {
    [CmdletBinding()]
    param([string[]]$Arguments = @())

    if ($Arguments.Count -eq 0) {
        if (Test-DuoForgeInteractiveHost) {
            Invoke-DuoForgeInteractiveHome
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
            else { $runs | Format-Table runId, name, mode, status, updatedAt -AutoSize | Out-Host }
            return
        }
        'status' {
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw (New-DuoForgeException -Code 'DF-CLI-RUN' -Message 'status에는 --run <실행 ID>가 필요합니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace
            if ([bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'json' -Default $false)) { $run | ConvertTo-Json -Depth 100 }
            else { $run.state | Format-List | Out-Host }
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
                Write-Host ('설명 호출 예산: 사용 {0}/{1}, 남음 {2}' -f $existing.budget.used, $existing.budget.maximum, $existing.budget.remaining)
                Write-Host '새 설명을 요청하려면 --live를 추가해 다시 실행해 주세요.' -ForegroundColor Yellow
                return
            }
            if (-not (Test-DuoForgeInteractiveHost)) { throw (New-DuoForgeException -Code 'DF-LIVE-NONINTERACTIVE' -Message '라이브 설명은 대화형 PowerShell에서만 확인할 수 있습니다.') }
            $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace
            $requiredCalls = if ($provider -eq 'both') { 2 } else { 1 }
            if ([int]$existing.budget.remaining -lt $requiredCalls) { throw (New-DuoForgeException -Code 'DF-EXPLANATION-LIMIT' -Message '설명 호출 잔여 예산이 부족합니다.') }
            Write-Host ('쟁점 {0}에 {1} 관점, {2} 수준, {3} 초점으로 설명을 요청합니다.' -f $issueId, $provider, $level, $focus) -ForegroundColor Yellow
            Write-DuoForgeProviderSelectionSummary -ProviderSelections $run.manifest.providerSelections
            Write-Host ('이번 설명 호출 수: {0}, 실행 전체 잔여 예산: {1}' -f $requiredCalls, $existing.budget.remaining) -ForegroundColor Yellow
            $confirmation = (Read-Host '실제 설명 호출을 시작하려면 LIVE를 입력하세요').Trim()
            if ($confirmation -cne 'LIVE') { Write-Host '설명 호출을 취소했습니다.'; return }
            $result = Invoke-DuoForgeIssueExplanationInternal -RunId $runId -IssueId $issueId -Provider $provider -Level $level -Focus $focus -ResultsRoot $workspace -LiveConsent $true
            Write-DuoForgeExplanationRecords -Records @($result.explanations)
            Write-Host ('설명 호출 예산: 사용 {0}/{1}, 남음 {2}' -f $result.budget.used, $result.budget.maximum, $result.budget.remaining)
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
                if (-not (Test-DuoForgeInteractiveHost)) { throw (New-DuoForgeException -Code 'DF-DEFER-CONFIRM' -Message '비대화형 보류에는 --confirm-partial이 필요합니다.') }
                $confirmation = (Read-Host 'Major 쟁점을 보류하면 부분 완료로 종료됩니다. DEFER를 입력하세요').Trim()
                $confirmed = $confirmation -ceq 'DEFER'
            }
            if (-not $confirmed) { Write-Host '보류를 취소했습니다.'; return }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $result = Set-DuoForgeUserDecisionInternal -RunId $runId -IssueId $issueId -Action defer -ResultsRoot $workspace -ConfirmPartial
            $result | ConvertTo-Json -Depth 30
            return
        }
        'pause' {
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw (New-DuoForgeException -Code 'DF-CLI-RUN' -Message 'pause에는 --run <실행 ID>가 필요합니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $result = Request-DuoForgePauseInternal -RunId $runId -ResultsRoot $workspace
            if ($result.alreadyPaused) { Write-Host '이미 사용자 일시정지 상태입니다.' }
            elseif ($result.alreadyRequested) { Write-Host ('이미 일시정지가 요청되어 있습니다: {0}' -f $result.requestId) }
            else { Write-Host ('일시정지를 요청했습니다. 현재 모델 호출이 있다면 완료 후 다음 호출 전에 멈춥니다: {0}' -f $result.requestId) -ForegroundColor Green }
            return
        }
        'resume' {
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw (New-DuoForgeException -Code 'DF-CLI-RUN' -Message 'resume에는 --run <실행 ID>가 필요합니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace
            $budget = Get-DuoForgeRemainingCallBudget -RunDirectory ([string]$run.runDirectory)
            if (-not [bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'live' -Default $false)) {
                Write-Host ("현재 상태: {0}" -f $run.state.status)
                if ([string]$run.state.status -eq 'AWAITING_EVIDENCE') { Write-Host '요청된 Markdown 근거를 evidence 명령으로 추가한 뒤 재개해 주세요.' -ForegroundColor Yellow }
                elseif ([string]$run.state.status -eq 'PAUSED_QUOTA') { Write-Host '구독 한도가 회복되고 구독 로그인이 유효한 뒤 재개해 주세요. API 과금 방식으로 자동 전환하지 않습니다.' -ForegroundColor Yellow }
                elseif ([string]$run.state.status -eq 'BLOCKED_PREFLIGHT') { Write-Host 'doctor와 공급자 구독 로그인을 다시 확인한 뒤 재개해 주세요.' -ForegroundColor Yellow }
                elseif ([string]$run.state.status -eq 'PAUSED_USER') { Write-Host '마지막 완료 체크포인트부터 재개할 수 있습니다.' -ForegroundColor Yellow }
                Write-Host ("Codex 남은 기본 단계 {0}, 추가 호출 최악 {1}" -f $budget.providers.codex.plannedRemaining, $budget.providers.codex.maximumAdditionalCalls)
                Write-Host ("Claude 남은 기본 단계 {0}, 추가 호출 최악 {1}" -f $budget.providers.claude.plannedRemaining, $budget.providers.claude.maximumAdditionalCalls)
                Write-Host '실제 구독 기반 CLI 호출을 시작하려면 --live를 추가해 다시 실행해 주세요.' -ForegroundColor Yellow
                return
            }
            if ([string]$run.state.status -eq 'AWAITING_EVIDENCE') {
                throw (New-DuoForgeException -Code 'DF-EVIDENCE-REQUIRED' -Message '요청된 근거를 먼저 추가해야 라이브 재개할 수 있습니다.')
            }
            if (-not (Test-DuoForgeInteractiveHost)) {
                throw (New-DuoForgeException -Code 'DF-LIVE-NONINTERACTIVE' -Message '라이브 실행은 대화형 PowerShell에서만 확인할 수 있습니다.')
            }
            $selections = Get-DuoForgeRunProviderSelectionsInternal -RunDirectory ([string]$run.runDirectory)
            Write-Host '선택한 스냅샷 내용이 Codex와 Claude에 전송됩니다.' -ForegroundColor Yellow
            Write-DuoForgeProviderSelectionSummary -ProviderSelections $selections
            Write-Host ("Codex 추가 호출 최악: {0}, Claude 추가 호출 최악: {1}" -f $budget.providers.codex.maximumAdditionalCalls, $budget.providers.claude.maximumAdditionalCalls) -ForegroundColor Yellow
            $confirmation = (Read-Host '실제 공급자 호출을 시작하려면 LIVE를 입력하세요').Trim()
            if ($confirmation -cne 'LIVE') { Write-Host '라이브 실행을 취소했습니다.'; return }
            $result = Invoke-DuoForgeResumeLiveInternal -RunId $runId -ResultsRoot $workspace -LiveConsent $true
            $result | ConvertTo-Json -Depth 30
            return
        }
        'start' {
            if ($parsed.positionals.Count -lt 2) { throw (New-DuoForgeException -Code 'DF-CLI-MODE' -Message 'start에는 모드가 필요합니다.') }
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
            if (-not $selectionValidation.valid -and (Test-DuoForgeInteractiveHost)) {
                $providerSelections = Complete-DuoForgeInteractiveProviderSelectionsInternal -InitialSelections $providerSelections
                if ($null -eq $providerSelections) { Write-Host '모델 선택을 취소했습니다.'; return }
            }
            $request = New-DuoForgeStartRequestInternal `
                -Mode $mode `
                -Brief ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'brief' -Default '')) `
                -CodexDocument ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'codex' -Default '')) `
                -ClaudeDocument ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'claude' -Default '')) `
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
            $validation = Confirm-DuoForgeInteractivePartialAnalysisInternal -Validation $validation
            if (-not $validation.valid) { Write-DuoForgeValidationErrors -Validation $validation; throw (New-DuoForgeException -Code 'DF-START-BLOCKED' -Message '실행 전 검증에 실패했습니다.') }
            Write-DuoForgeExecutionPlan -Validation $validation
            if ([bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'plan-only' -Default $false)) { return }
            if (-not (Test-DuoForgeInteractiveHost)) {
                throw (New-DuoForgeException -Code 'DF-CONFIRM-NONINTERACTIVE' -Message 'v1은 확정 실행 전에 대화형 사용자 확인이 필요합니다. 비대화형 환경에서는 --plan-only를 사용해 주세요.')
            }
            $confirmation = (Read-Host '스냅샷과 실행 기록을 만들까요? [Y/N]').Trim()
            if ($confirmation -notin @('Y', 'y')) { Write-Host '취소했습니다. 확정 실행은 생성하지 않았습니다.'; return }
            $run = New-DuoForgeRunInternal -ValidationResult $validation
            $run | ConvertTo-Json -Depth 20
            return
        }
        default { throw (New-DuoForgeException -Code 'DF-CLI-COMMAND' -Message "알 수 없는 명령입니다: $command") }
    }
}
