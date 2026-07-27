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
        'answer' {
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            $issueId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'issue' -Default '')
            $choice = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'choice' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId) -or [string]::IsNullOrWhiteSpace($issueId) -or [string]::IsNullOrWhiteSpace($choice)) {
                throw (New-DuoForgeException -Code 'DF-CLI-ANSWER' -Message 'answer에는 --run, --issue, --choice가 필요합니다.')
            }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $result = Set-DuoForgeUserDecisionInternal -RunId $runId -IssueId $issueId -Action answer -Choice $choice -ResultsRoot $workspace
            $result | ConvertTo-Json -Depth 30
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
        'resume' {
            $runId = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'run' -Default '')
            if ([string]::IsNullOrWhiteSpace($runId)) { throw (New-DuoForgeException -Code 'DF-CLI-RUN' -Message 'resume에는 --run <실행 ID>가 필요합니다.') }
            $workspace = [string](Get-DuoForgeCliOption -Parsed $parsed -Name 'workspace' -Default '')
            $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $workspace
            $budget = Get-DuoForgeRemainingCallBudget -RunDirectory ([string]$run.runDirectory)
            if (-not [bool](Get-DuoForgeCliOption -Parsed $parsed -Name 'live' -Default $false)) {
                Write-Host ("현재 상태: {0}" -f $run.state.status)
                Write-Host ("Codex 남은 기본 단계 {0}, 추가 호출 최악 {1}" -f $budget.providers.codex.plannedRemaining, $budget.providers.codex.maximumAdditionalCalls)
                Write-Host ("Claude 남은 기본 단계 {0}, 추가 호출 최악 {1}" -f $budget.providers.claude.plannedRemaining, $budget.providers.claude.maximumAdditionalCalls)
                Write-Host '실제 구독 기반 CLI 호출을 시작하려면 --live를 추가해 다시 실행해 주세요.' -ForegroundColor Yellow
                return
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
                -Name ([string](Get-DuoForgeCliOption -Parsed $parsed -Name 'name' -Default ''))
            $validation = Test-DuoForgeStartRequestInternal -Request $request
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
