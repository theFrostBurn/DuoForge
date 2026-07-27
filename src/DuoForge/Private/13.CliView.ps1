function Write-DuoForgeHelp {
    [CmdletBinding()]
    param()
    @'
DuoForge

사용법:
  duoforge
  duoforge doctor [--json]
  duoforge start shared-document --brief <파일> --codex-model <모델> --codex-effort <단계> --claude-model <모델> --claude-effort <단계> [--pause-after-round] [--plan-only]
  duoforge start dual-document --codex <파일> --claude <파일> --codex-model <모델> --codex-effort <단계> --claude-model <모델> --claude-effort <단계> [--pause-after-round] [--plan-only]
  duoforge status --run <실행 ID> [--workspace <폴더>] [--json]
  duoforge issues --run <실행 ID> [--workspace <폴더>] [--json]
  duoforge explain --run <실행 ID> --issue <쟁점 ID> [--provider codex|claude|both] [--level beginner|general|expert] [--focus general|evidence|examples|tradeoffs|experiment] [--live]
  duoforge evidence --run <실행 ID> --issue <쟁점 ID> --file <Markdown 파일> [--workspace <폴더>]
  duoforge answer --run <실행 ID> --issue <쟁점 ID> --choice <A|B> [--workspace <폴더>]
  duoforge defer --run <실행 ID> --issue <쟁점 ID> [--workspace <폴더>] [--confirm-partial]
  duoforge pause --run <실행 ID> [--workspace <폴더>]
  duoforge resume --run <실행 ID> [--workspace <폴더>] [--live]
  duoforge list [--workspace <폴더>] [--json]

추론 정도:
  - Codex: low, medium, high, xhigh, max, ultra
  - Claude: low, medium, high, xhigh, max

안전 원칙:
  - API 키 인증은 사용하지 않습니다.
  - 새 실행마다 두 공급자의 모델과 추론 정도를 명시적으로 선택합니다.
  - 모델 호출 전 입력, 전송 범위와 최악 호출 수를 확인합니다.
  - 3A는 현재 Windows 격리 후보가 필수 차단 계약을 충족하지 못해 비활성화되어 있습니다.
'@ | Write-Host
}

function Write-DuoForgeDoctorReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Report)

    Write-Host ''
    Write-Host 'DuoForge 환경 진단'
    Write-Host ('PowerShell: {0} ({1})' -f $Report.powershell.version, $(if ($Report.powershell.ready) { '정상' } else { '차단' }))
    foreach ($provider in @('codex', 'claude')) {
        $item = $Report.providers[$provider]
        $mark = if ($item.status -eq 'READY_DOCUMENTS') { '✓' } else { '✗' }
        Write-Host ("$mark {0}: {1}, 인증={2}, 문서 프로필={3}" -f $provider, $item.version, $item.authType, $item.documentProfileSupported)
    }
    if ($Report.apiCredentialConflicts.Count -gt 0) {
        Write-Host ('✗ API 인증 우선 환경 변수: {0}' -f ($Report.apiCredentialConflicts -join ', ')) -ForegroundColor Red
        Write-Host '  값은 읽거나 표시하지 않았습니다.'
    }
    else {
        Write-Host '✓ API 인증 우선 조건 없음'
    }
    Write-Host ('문서 모드 준비: {0}' -f $(if ($Report.readyForDocumentModes) { '예' } else { '아니요' }))
    Write-Host '프로젝트 비교 3A: 비활성화 (범위 밖 읽기·자식 프로세스 차단 실패)'
    foreach ($recommendation in $Report.recommendations) {
        Write-Host ("- $recommendation")
    }
}

function Write-DuoForgeProviderSelectionSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ProviderSelections)

    $null = Assert-DuoForgeProviderSelectionsInternal -Selections $ProviderSelections
    foreach ($provider in @('codex', 'claude')) {
        $options = Get-DuoForgeProviderSelectionOptionsInternal -Provider $provider
        $selection = Get-DuoForgeObjectValue -Object $ProviderSelections -Name $provider
        Write-Host ('{0} 선택: 모델={1}, 추론 정도={2}' -f $options.displayName, $selection.model, $selection.reasoningEffort)
    }
}

function Write-DuoForgeExecutionPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Validation)

    Write-Host ''
    Write-Host '실행 전 확인'
    Write-Host ('모드: {0}' -f $Validation.request.mode)
    Write-Host ('라운드: {0}' -f $Validation.request.maxRounds)
    Write-Host ('라운드마다 일시정지: {0}' -f $(if ([bool](Get-DuoForgeObjectValue -Object $Validation.request -Name 'pauseAfterRound' -Default $false)) { '예' } else { '아니요' }))
    Write-Host ('결과 루트: {0}' -f $Validation.resultsRoot)
    Write-DuoForgeProviderSelectionSummary -ProviderSelections $Validation.request.providerSelections
    if ($Validation.request.mode -eq 'shared-document') {
        Write-Host ('입력: {0} ({1})' -f $Validation.inputs.primary.path, (Format-DuoForgeByteSize -Bytes $Validation.inputs.primary.bytes))
    }
    elseif ($Validation.request.mode -eq 'dual-document') {
        foreach ($side in @('codex', 'claude')) {
            $context = $Validation.inputs[$side].context
            Write-Host ('{0}: {1}, 자동 문맥 {2}개 / {3}' -f $side, $Validation.inputs[$side].primary.path, $context.includedFiles, (Format-DuoForgeByteSize -Bytes $context.includedBytes))
        }
    }
    foreach ($provider in @('codex', 'claude')) {
        $providerPlan = $Validation.executionPlan.providers[$provider]
        Write-Host ('{0} 호출: 기본 {1}, 재시도 예산 {2}, 최악 {3}/{4}' -f $provider, $providerPlan.baseCalls, $providerPlan.retryBudget, $providerPlan.maximumCalls, $providerPlan.limit)
    }
    Write-Host '선택한 입력 내용은 두 모델 공급자에게 전송될 수 있습니다.' -ForegroundColor Yellow
    Write-Host 'start는 검증된 스냅샷만 만들며 모델을 호출하지 않습니다. 이후 resume --live에서 다시 확인하고 호출합니다.' -ForegroundColor Yellow
}

function Write-DuoForgeIssueList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Issues)

    if ($Issues.Count -eq 0) {
        Write-Host '등록된 쟁점이 없습니다.'
        return
    }
    $Issues | Select-Object issueId, severity, blocking, resolutionStatus, claim | Format-Table -Wrap -AutoSize | Out-Host
}

function Write-DuoForgeExplanationRecords {
    [CmdletBinding()]
    param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Records)

    if ($Records.Count -eq 0) {
        Write-Host '저장된 설명이 없습니다.'
        return
    }
    foreach ($record in $Records) {
        $result = $record.result
        Write-Host ''
        Write-Host ('{0} | {1} | {2} | {3}' -f $record.issueId, $record.provider, $record.level, $record.focus) -ForegroundColor Cyan
        Write-Host ([string]$result.summary)
        Write-Host ([string]$result.explanation)
        if (@($result.existingEvidence).Count -gt 0) {
            Write-Host '기존 입력 근거:'
            foreach ($item in @($result.existingEvidence)) { Write-Host ("- $item") }
        }
        if (@($result.newClaims).Count -gt 0) {
            Write-Host '새 주장 또는 가정:'
            foreach ($item in @($result.newClaims)) { Write-Host ('- [{0}] {1} — {2}' -f $item.status, $item.claim, $item.basis) }
        }
        if (@($result.tradeoffs).Count -gt 0) {
            Write-Host '선택지 비교:'
            foreach ($item in @($result.tradeoffs)) {
                Write-Host ('- {0}: 장점={1}; 비용={2}; 위험={3}; 되돌리기={4}' -f $item.option, (@($item.benefits) -join ', '), (@($item.costs) -join ', '), (@($item.risks) -join ', '), $item.reversibility)
            }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$result.suggestedExperiment)) {
            Write-Host ('검증 실험 제안: {0}' -f $result.suggestedExperiment)
        }
    }
}

function Write-DuoForgeValidationErrors {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Validation)

    Write-Host '요청을 시작할 수 없습니다.' -ForegroundColor Red
    foreach ($errorItem in $Validation.errors) {
        Write-Host ('- [{0}] {1}' -f $errorItem.code, $errorItem.message) -ForegroundColor Red
    }
}
