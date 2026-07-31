function Get-DuoForgeDisplayModeLabelInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Mode)

    switch ($Mode) {
        'shared-document' { '요구사항으로 공동 문서 만들기' }
        'document-merge' { '두 문서를 비교해 하나의 합의안 만들기' }
        'dual-document' { '두 문서를 각각 개선하기' }
        'dual-project-audit' { '두 프로젝트 비교하기 · 준비 중' }
        default { ConvertTo-DuoForgeProgressTextInternal -Text $Mode -MaximumCharacters 120 }
    }
}

function Get-DuoForgeDisplayStageLabelInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Stage)

    switch ($Stage) {
        'context-batch-analysis' { '나눈 문서 분석' }
        'independent-draft' { '각자 초안 작성' }
        'independent-merge-draft' { '각자 통합안 작성' }
        'cross-review' { '서로의 초안 검토' }
        'author-response' { '검토 의견에 답변' }
        'joint-document-review' { '공동 문서 검토' }
        'document-review' { '두 문서 함께 검토' }
        'review-response' { '검토 의견 판단' }
        'synthesis' { '공동 문서 작성' }
        'final-validation' { '최종 확인' }
        'owner-response' { '담당 문서 의견 답변' }
        'owned-document-revision' { '담당 문서 수정' }
        'document-revision' { '문서 수정' }
        'document-validation' { '수정 문서 최종 확인' }
        default { ConvertTo-DuoForgeProgressTextInternal -Text $Stage -MaximumCharacters 120 }
    }
}

function Get-DuoForgeDisplayReasoningEffortLabelInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory)][string]$ReasoningEffort)

    switch ($ReasoningEffort) {
        'low' { '낮음' }
        'medium' { '보통' }
        'high' { '높음' }
        'xhigh' { '매우 높음' }
        'max' { '최대' }
        'ultra' { '최대 확장' }
        default { ConvertTo-DuoForgeProgressTextInternal -Text $ReasoningEffort -MaximumCharacters 80 }
    }
}

function Get-DuoForgeDisplayCheckpointLabelInternal {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$StepKey,
        [AllowNull()][AllowEmptyString()][string]$RunDirectory
    )

    if ([string]::IsNullOrWhiteSpace($StepKey)) { return '아직 완료된 AI 작업 없음' }
    if ($StepKey -eq 'input-snapshot') { return '입력 문서 준비 완료' }

    $step = $null
    if (-not [string]::IsNullOrWhiteSpace($RunDirectory)) {
        $stepsPath = Join-Path $RunDirectory 'steps.json'
        if (Test-Path -LiteralPath $stepsPath -PathType Leaf) {
            try {
                $graph = Read-DuoForgeJson -Path $stepsPath
                $matches = @($graph.steps | Where-Object { [string]$_.stepKey -eq $StepKey })
                if ($matches.Count -eq 1) { $step = $matches[0] }
            }
            catch { $step = $null }
        }
    }

    if ($null -eq $step -and $StepKey -match '^r(?<round>\d+)-(?<provider>codex|claude)-(?<stage>.+)$') {
        $knownStage = [string]$Matches.stage
        if ($knownStage -in @(
            'independent-draft', 'independent-merge-draft', 'cross-review', 'author-response',
            'joint-document-review', 'document-review', 'review-response', 'synthesis',
            'final-validation', 'owner-response', 'owned-document-revision'
        )) {
            $step = [ordered]@{ round = [int]$Matches.round; provider = [string]$Matches.provider; stage = $knownStage; targetDocumentId = $null }
        }
    }

    if ($null -eq $step) { return '완료된 AI 작업' }
    $providerLabel = switch ([string]$step.provider) { 'codex' { 'Codex' } 'claude' { 'Claude' } default { 'AI' } }
    $stageLabel = Get-DuoForgeDisplayStageLabelInternal -Stage ([string]$step.stage)
    $targetDocumentId = [string](Get-DuoForgeObjectValue -Object $step -Name 'targetDocumentId')
    if ([string]$step.stage -eq 'document-revision' -and $targetDocumentId -in @('A', 'B')) { $stageLabel = "문서 $targetDocumentId 수정" }
    elseif ([string]$step.stage -eq 'document-validation' -and $targetDocumentId -in @('A', 'B')) { $stageLabel = "문서 $targetDocumentId 최종 확인" }
    $round = [int](Get-DuoForgeObjectValue -Object $step -Name 'round' -Default 0)
    if ($round -gt 0) { return ('{0}차 · {1} · {2}' -f $round, $providerLabel, $stageLabel) }
    return ('{0} · {1}' -f $providerLabel, $stageLabel)
}

function Get-DuoForgeDisplayStateLabelInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Status)

    switch ($Status) {
        'CREATED' { '작업 생성' }
        'PREFLIGHT' { '실행 환경 확인' }
        'SNAPSHOTTED' { '작업 준비 완료' }
        'RUNNING' { '진행 중' }
        'BLOCKED_PREFLIGHT' { '실행 환경 문제로 멈춤' }
        'PAUSED_USER' { '사용자 요청으로 멈춤' }
        'PAUSED_QUOTA' { '사용 한도 회복 대기' }
        'AWAITING_USER' { '답변 대기' }
        'AWAITING_EVIDENCE' { '추가 자료 대기' }
        'COMPLETED' { '완료' }
        'COMPLETED_PARTIAL' { '일부 범위만 완료' }
        'QUESTION_LIMIT_REACHED' { '사용자 확인을 3번 거친 뒤 멈춤' }
        'RESUMABLE_ERROR' { '오류 발생 · 이어서 가능' }
        'SOURCE_DRIFT' { '원본 파일이 변경됨' }
        'FAILED_STAGE' { '작업 실패' }
        'CANCELLED' { '포기함' }
        default { ConvertTo-DuoForgeProgressTextInternal -Text $Status -MaximumCharacters 120 }
    }
}

function Get-DuoForgeDisplaySeverityLabelInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Severity)

    switch ($Severity) {
        'critical' { '반드시 해결' }
        'major' { '중요' }
        'minor' { '참고' }
        default { ConvertTo-DuoForgeProgressTextInternal -Text $Severity -MaximumCharacters 80 }
    }
}

function Get-DuoForgeDisplayIssueStatusLabelInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Status)

    switch ($Status) {
        'OPEN' { '미해결' }
        'RESOLVED' { '검토 완료' }
        'AWAITING_USER' { '답변 필요' }
        'AWAITING_EVIDENCE' { '자료 필요' }
        'DEFERRED' { '보류됨' }
        'SUPERSEDED' { '새 항목으로 대체됨' }
        default { ConvertTo-DuoForgeProgressTextInternal -Text $Status -MaximumCharacters 120 }
    }
}

function Get-DuoForgeDisplayDispositionLabelInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][Parameter(Mandatory)][string]$Disposition,
        [ValidateSet('review', 'adoption')][string]$Context = 'review'
    )

    if ($Context -eq 'adoption') {
        switch ($Disposition) {
            'ACCEPTED' { '반영' }
            'PARTIALLY_ACCEPTED' { '일부 반영' }
            'REJECTED' { '미반영' }
            'DEFERRED' { '보류' }
            default { return ConvertTo-DuoForgeProgressTextInternal -Text $Disposition -MaximumCharacters 120 }
        }
    }
    switch ($Disposition) {
        'ACCEPTED' { '수용' }
        'PARTIALLY_ACCEPTED' { '일부 수용' }
        'REJECTED' { '거부' }
        'DEFERRED' { '보류' }
        'NEEDS_EVIDENCE' { '자료 필요' }
        'ASK_USER' { '답변 필요' }
        default { ConvertTo-DuoForgeProgressTextInternal -Text $Disposition -MaximumCharacters 120 }
    }
}

function Get-DuoForgeMenuCapabilityInternal {
    [CmdletBinding()]
    param([scriptblock]$CapabilityProbe)

    if ($null -ne $CapabilityProbe) {
        try {
            $value = & $CapabilityProbe
            if ($value -is [System.Collections.IDictionary]) { return $value }
            return [ordered]@{
                cursor = [bool]$value
                renderMode = if ([bool]$value) { 'ansi' } else { 'line' }
                reason = if ([bool]$value) { 'ready' } else { 'probe-disabled' }
            }
        }
        catch { return [ordered]@{ cursor = $false; renderMode = 'line'; reason = 'probe-failed' } }
    }
    if (-not (Test-DuoForgeInteractiveHost)) { return [ordered]@{ cursor = $false; renderMode = 'line'; reason = 'non-interactive' } }
    try {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return [ordered]@{ cursor = $false; renderMode = 'line'; reason = 'redirected' } }
    }
    catch { return [ordered]@{ cursor = $false; renderMode = 'line'; reason = 'console-unavailable' } }

    $supportsVirtualTerminal = $false
    try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { }
    $nativeCursor = Test-DuoForgeNativeMenuConsoleInternal
    $renderMode = Resolve-DuoForgeMenuRenderModeInternal -SupportsVirtualTerminal $supportsVirtualTerminal -NativeCursor $nativeCursor
    if ($renderMode -eq 'line') { return [ordered]@{ cursor = $false; renderMode = 'line'; reason = 'cursor-unavailable' } }
    return [ordered]@{
        cursor = $true
        renderMode = $renderMode
        reason = if ($renderMode -eq 'ansi') { 'virtual-terminal' } else { 'native-console' }
    }
}

function Resolve-DuoForgeMenuRenderModeInternal {
    [CmdletBinding()]
    param(
        [bool]$SupportsVirtualTerminal,
        [bool]$NativeCursor
    )

    if ($SupportsVirtualTerminal) { return 'ansi' }
    if ($NativeCursor) { return 'console' }
    return 'line'
}

function Test-DuoForgeNativeMenuConsoleInternal {
    [CmdletBinding()]
    param()

    try {
        if ([Console]::WindowWidth -lt 2 -or [Console]::BufferHeight -lt 2) { return $false }
        $left = [Console]::CursorLeft
        $top = [Console]::CursorTop
        [Console]::SetCursorPosition($left, $top)
        return $true
    }
    catch {
        return $false
    }
}

function ConvertTo-DuoForgeMenuItemsInternal {
    [CmdletBinding()]
    param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Items)

    $normalized = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Items) {
        $value = [string](Get-DuoForgeObjectValue -Object $item -Name 'value' -Default (Get-DuoForgeObjectValue -Object $item -Name 'key'))
        $label = [string](Get-DuoForgeObjectValue -Object $item -Name 'label' -Default $value)
        $shortcuts = @(
            @(Get-DuoForgeObjectValue -Object $item -Name 'shortcuts' -Default @()) |
                ForEach-Object { ([string]$_).Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        if ($shortcuts.Count -eq 0) {
            $legacyKey = [string](Get-DuoForgeObjectValue -Object $item -Name 'key')
            if (-not [string]::IsNullOrWhiteSpace($legacyKey)) { $shortcuts = @($legacyKey) }
        }
        $normalized.Add([ordered]@{
            value = $value
            label = ConvertTo-DuoForgeProgressTextInternal -Text $label -MaximumCharacters 600
            shortcuts = $shortcuts
            enabled = [bool](Get-DuoForgeObjectValue -Object $item -Name 'enabled' -Default $true)
            disabledReason = ConvertTo-DuoForgeProgressTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $item -Name 'disabledReason')) -MaximumCharacters 600
            detail = ConvertTo-DuoForgeProgressTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $item -Name 'detail')) -MaximumCharacters 600
        })
    }
    return @($normalized)
}

function New-DuoForgeMenuFrameRowsInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Items,
        [AllowEmptyString()][string]$Title,
        [ValidateRange(0, 10000)][int]$SelectedIndex = 0,
        [AllowEmptyString()][string]$Message,
        [AllowEmptyString()][string]$Footer = '↑/↓ 이동 · Home/End · Enter 선택 · Esc 이전',
        [ValidateRange(0, 1000)][int]$Width = 0,
        [ValidateRange(0, 1000)][int]$Height = 0,
        [switch]$Ascii,
        [switch]$ContextTransition,
        [switch]$ExpandAllDetails
    )

    $layout = Get-DuoForgeDisplayLayoutInternal -Width $Width -Height $Height -Ascii:$Ascii -NoColor
    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        foreach ($row in @(New-DuoForgePageHeaderRowsInternal -Title $Title -Layout $layout -NoTrailingSpacer:([bool]$layout.compact -or $ContextTransition))) { $rows.Add($row) }
    }
    if ($Items.Count -eq 0) {
        foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind info -Title '선택할 수 있는 항목이 없습니다.' -Layout $layout)) { $rows.Add($row) }
    }
    else {
        $selected = [Math]::Max(0, [Math]::Min($SelectedIndex, $Items.Count - 1))
        for ($index = 0; $index -lt $Items.Count; $index++) {
            $item = $Items[$index]
            $prefix = if ($index -eq $selected) { '> ' } else { '  ' }
            $shortcut = if (@($item.shortcuts).Count -gt 0) { '[{0}] ' -f [string]$item.shortcuts[0] } else { '' }
            $suffix = if ([bool]$item.enabled) { '' } else { ' · 비활성' }
            $itemPrefix = $prefix + $shortcut
            $prefixWidth = Get-DuoForgeProgressTextWidthInternal -Text $itemPrefix
            $itemWidth = [Math]::Max(8, [int]$layout.lineWidth - $prefixWidth)
            $itemMaximumLines = if ($ExpandAllDetails) { 1000 } elseif ([int]$layout.height -ge 32) { 3 } else { 2 }
            $itemLines = @(Split-DuoForgeDisplayTextInternal -Text (([string]$item.label) + $suffix) -Width $itemWidth -MaximumLines $itemMaximumLines)
            for ($lineIndex = 0; $lineIndex -lt $itemLines.Count; $lineIndex++) {
                $linePrefix = if ($lineIndex -eq 0) { $itemPrefix } else { ' ' * $prefixWidth }
                $rows.Add((New-DuoForgeDisplayRowInternal -Text ($linePrefix + [string]$itemLines[$lineIndex]) -Role $(if ($index -eq $selected) { 'selection' } else { 'list' })))
            }
            $showDetail = ($index -eq $selected -or $ExpandAllDetails) -and -not [string]::IsNullOrWhiteSpace([string]$item.detail)
            if ($showDetail) {
                $detailMaximumLines = if ($ExpandAllDetails) { 1000 } elseif ($ContextTransition -and [int]$layout.height -le 24) { 1 } elseif ([int]$layout.height -le 24) { 2 } else { 3 }
                foreach ($row in @(New-DuoForgeTextRowsInternal -Text ([string]$item.detail) -Layout $layout -Indent 4 -MaximumLines $detailMaximumLines -Role 'meta')) { $rows.Add($row) }
            }
            if (($index -eq $selected -or $ExpandAllDetails) -and -not [bool]$item.enabled) {
                $reason = if ([string]::IsNullOrWhiteSpace([string]$item.disabledReason)) { '현재 사용할 수 없는 항목입니다.' } else { [string]$item.disabledReason }
                foreach ($row in @(New-DuoForgeTextRowsInternal -Text '! 사용할 수 없는 이유' -Layout $layout -Indent 4 -MaximumLines 1 -Role 'warning')) { $rows.Add($row) }
                $reasonMaximumLines = if ($ExpandAllDetails) { 1000 } else { 3 }
                foreach ($row in @(New-DuoForgeTextRowsInternal -Text $reason -Layout $layout -Indent 6 -MaximumLines $reasonMaximumLines -Role 'meta')) { $rows.Add($row) }
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $rows.Add((New-DuoForgeDisplayRowInternal -Text '' -Role 'spacer'))
        foreach ($row in @(New-DuoForgeNoticeRowsInternal -Kind warning -Title $Message -Layout $layout)) { $rows.Add($row) }
    }
    if (-not [string]::IsNullOrWhiteSpace($Footer)) {
        if (-not [bool]$layout.compact) { $rows.Add((New-DuoForgeDisplayRowInternal -Text '' -Role 'spacer')) }
        foreach ($row in @(New-DuoForgeTextRowsInternal -Text $Footer -Layout $layout -MaximumLines 2 -Role 'meta')) { $rows.Add($row) }
    }
    return @($rows)
}

function New-DuoForgeMenuFrameInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Items,
        [AllowEmptyString()][string]$Title,
        [ValidateRange(0, 10000)][int]$SelectedIndex = 0,
        [AllowEmptyString()][string]$Message,
        [AllowEmptyString()][string]$Footer = '↑/↓ 이동 · Home/End · Enter 선택 · Esc 이전',
        [ValidateRange(0, 1000)][int]$Width = 0,
        [ValidateRange(0, 1000)][int]$Height = 0,
        [switch]$Ascii,
        [switch]$ContextTransition
    )

    return @(
        New-DuoForgeMenuFrameRowsInternal -Items $Items -Title $Title -SelectedIndex $SelectedIndex -Message $Message -Footer $Footer -Width $Width -Height $Height -Ascii:$Ascii -ContextTransition:$ContextTransition |
            ForEach-Object { [string]$_.text }
    )
}

function ConvertTo-DuoForgeMenuRenderRowInternal {
    [CmdletBinding()]
    param([AllowNull()]$Row)

    if ($null -eq $Row -or $Row -is [string]) {
        return [ordered]@{ text = [string]$Row; color = '' }
    }
    $role = [string](Get-DuoForgeObjectValue -Object $Row -Name 'role' -Default 'text')
    $color = [string](Get-DuoForgeObjectValue -Object $Row -Name 'color' -Default '')
    if ([string]::IsNullOrWhiteSpace($color)) { $color = Get-DuoForgeDisplayRoleColorInternal -Role $role }
    return [ordered]@{
        text = [string](Get-DuoForgeObjectValue -Object $Row -Name 'text' -Default '')
        color = $color
    }
}

function Get-DuoForgeAnsiForegroundCodeInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Color)

    switch ($Color) {
        'Black' { '30' }
        'DarkBlue' { '34' }
        'DarkGreen' { '32' }
        'DarkCyan' { '36' }
        'DarkRed' { '31' }
        'DarkMagenta' { '35' }
        'DarkYellow' { '33' }
        'Gray' { '37' }
        'DarkGray' { '90' }
        'Blue' { '94' }
        'Green' { '92' }
        'Cyan' { '96' }
        'Red' { '91' }
        'Magenta' { '95' }
        'Yellow' { '93' }
        'White' { '97' }
        default { '' }
    }
}

function Format-DuoForgeAnsiMenuRowInternal {
    [CmdletBinding()]
    param(
        [AllowNull()]$Row,
        [ValidateRange(1, 1000)][int]$Width,
        [switch]$UseColor
    )

    $renderRow = ConvertTo-DuoForgeMenuRenderRowInternal -Row $Row
    $text = Limit-DuoForgeProgressTextInternal -Text ([string]$renderRow.text) -Width $Width
    if (-not $UseColor -or [string]::IsNullOrWhiteSpace([string]$renderRow.color)) { return $text }
    $code = Get-DuoForgeAnsiForegroundCodeInternal -Color ([string]$renderRow.color)
    if ([string]::IsNullOrWhiteSpace($code)) { return $text }
    $escape = [char]27
    return "$escape[$($code)m$text$escape[0m"
}

function Test-DuoForgeMenuColorEnabledInternal {
    [CmdletBinding()]
    param()

    return [string]::IsNullOrWhiteSpace([string]$env:NO_COLOR)
}

function Write-DuoForgeAnsiMenuFrameInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][object[]]$Lines,
        [Parameter(Mandatory)][System.Collections.IDictionary]$RenderState
    )

    $escape = [char]27
    $windowWidth = [Math]::Min(1000, [Math]::Max(2, [Console]::WindowWidth))
    $lineWidth = $windowWidth - 1
    if (-not [bool](Get-DuoForgeObjectValue -Object $RenderState -Name 'started' -Default $false)) {
        [Console]::Write("$escape[?25l$escape[s")
        $RenderState.started = $true
    }
    else {
        [Console]::Write("$escape[u")
    }
    $builder = [System.Text.StringBuilder]::new()
    $useColor = Test-DuoForgeMenuColorEnabledInternal
    $lineCount = [Math]::Max([int](Get-DuoForgeObjectValue -Object $RenderState -Name 'lineCount' -Default 0), $Lines.Count)
    for ($index = 0; $index -lt $lineCount; $index++) {
        $null = $builder.Append("`r$escape[0m$escape[2K")
        if ($index -lt $Lines.Count) {
            $line = Format-DuoForgeAnsiMenuRowInternal -Row $Lines[$index] -Width $lineWidth -UseColor:$useColor
            $null = $builder.Append($line)
        }
        if ($index -lt $lineCount - 1) { $null = $builder.Append([Environment]::NewLine) }
    }
    [Console]::Write($builder.ToString())
    $RenderState.lineCount = $lineCount
}

function Write-DuoForgeNativeMenuFrameInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][object[]]$Lines,
        [Parameter(Mandatory)][System.Collections.IDictionary]$RenderState
    )

    $windowWidth = [Math]::Min(1000, [Math]::Max(2, [Console]::WindowWidth))
    $lineWidth = $windowWidth - 1
    if (-not [bool](Get-DuoForgeObjectValue -Object $RenderState -Name 'started' -Default $false)) {
        $RenderState.top = [Console]::CursorTop
        $RenderState.cursorVisible = $true
        $RenderState.foregroundColor = $null
        try { $RenderState.cursorVisible = [Console]::CursorVisible } catch { }
        try { $RenderState.foregroundColor = [Console]::ForegroundColor } catch { }
        try { [Console]::CursorVisible = $false } catch { }
        $RenderState.started = $true
    }

    $top = [int]$RenderState.top
    $lineCount = [Math]::Max([int](Get-DuoForgeObjectValue -Object $RenderState -Name 'lineCount' -Default 0), $Lines.Count)
    if ($top -lt 0 -or $top + $lineCount -ge [Console]::BufferHeight) {
        throw '메뉴를 다시 그릴 콘솔 공간이 부족합니다.'
    }

    $blank = ' ' * $lineWidth
    $originalForegroundColor = Get-DuoForgeObjectValue -Object $RenderState -Name 'foregroundColor'
    $useColor = Test-DuoForgeMenuColorEnabledInternal
    try {
        for ($index = 0; $index -lt $lineCount; $index++) {
            $row = $top + $index
            [Console]::SetCursorPosition(0, $row)
            if ($null -ne $originalForegroundColor) { try { [Console]::ForegroundColor = $originalForegroundColor } catch { } }
            [Console]::Write($blank)
            [Console]::SetCursorPosition(0, $row)
            if ($index -lt $Lines.Count) {
                $renderRow = ConvertTo-DuoForgeMenuRenderRowInternal -Row $Lines[$index]
                $line = Limit-DuoForgeProgressTextInternal -Text ([string]$renderRow.text) -Width $lineWidth
                if ($useColor -and -not [string]::IsNullOrWhiteSpace([string]$renderRow.color)) {
                    try { [Console]::ForegroundColor = [System.Enum]::Parse([ConsoleColor], [string]$renderRow.color, $true) } catch { }
                }
                [Console]::Write($line)
            }
        }
    }
    finally {
        if ($null -ne $originalForegroundColor) { try { [Console]::ForegroundColor = $originalForegroundColor } catch { } }
    }
    $RenderState.lineCount = $lineCount
    [Console]::SetCursorPosition(0, $top + $lineCount)
}

function Write-DuoForgeCursorMenuFrameInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][object[]]$Lines,
        [Parameter(Mandatory)][System.Collections.IDictionary]$RenderState
    )

    if ([string](Get-DuoForgeObjectValue -Object $RenderState -Name 'renderMode' -Default 'ansi') -eq 'console') {
        Write-DuoForgeNativeMenuFrameInternal -Lines $Lines -RenderState $RenderState
        return
    }
    Write-DuoForgeAnsiMenuFrameInternal -Lines $Lines -RenderState $RenderState
}

function Complete-DuoForgeMenuRenderInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$RenderState)

    if (-not [bool](Get-DuoForgeObjectValue -Object $RenderState -Name 'started' -Default $false)) { return }
    $renderMode = [string](Get-DuoForgeObjectValue -Object $RenderState -Name 'renderMode' -Default 'ansi')
    try {
        if ($renderMode -eq 'console') {
            $top = [int](Get-DuoForgeObjectValue -Object $RenderState -Name 'top' -Default [Console]::CursorTop)
            $lineCount = [int](Get-DuoForgeObjectValue -Object $RenderState -Name 'lineCount' -Default 0)
            [Console]::SetCursorPosition(0, [Math]::Min([Console]::BufferHeight - 1, $top + $lineCount))
            try { [Console]::CursorVisible = [bool](Get-DuoForgeObjectValue -Object $RenderState -Name 'cursorVisible' -Default $true) } catch { }
            $foregroundColor = Get-DuoForgeObjectValue -Object $RenderState -Name 'foregroundColor'
            if ($null -ne $foregroundColor) { try { [Console]::ForegroundColor = $foregroundColor } catch { } }
            [Console]::WriteLine()
        }
        else {
            $escape = [char]27
            $lineCount = [int](Get-DuoForgeObjectValue -Object $RenderState -Name 'lineCount' -Default 0)
            [Console]::Write("$escape[u`r$escape[$($lineCount)B$escape[0m$escape[?25h" + [Environment]::NewLine)
        }
    }
    catch { }
    finally { $RenderState.started = $false }
}

function Find-DuoForgeMenuItemByShortcutInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Items,
        [AllowEmptyString()][string]$Shortcut
    )

    foreach ($item in $Items) {
        foreach ($candidate in @($item.shortcuts)) {
            if ([string]::Equals([string]$candidate, $Shortcut, [StringComparison]::OrdinalIgnoreCase)) { return $item }
        }
    }
    return $null
}
