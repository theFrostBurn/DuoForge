function Get-DuoForgeDisplayModeLabelInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Mode)

    switch ($Mode) {
        'shared-document' { '컨셉으로 공동 문서 만들기' }
        'document-merge' { '두 문서를 하나로 합의하기' }
        'dual-document' { '두 문서를 각각 개선하기' }
        'dual-project-audit' { '두 프로젝트 비교하기(비활성)' }
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

function Get-DuoForgeDisplayStateLabelInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Status)

    switch ($Status) {
        'CREATED' { '작업 생성' }
        'PREFLIGHT' { '실행 환경 확인' }
        'SNAPSHOTTED' { '작업 준비 완료' }
        'RUNNING' { '진행 중' }
        'BLOCKED_PREFLIGHT' { '실행 환경 문제로 멈춤' }
        'PAUSED_USER' { '안전 일시정지' }
        'PAUSED_QUOTA' { '사용 한도 회복 대기' }
        'AWAITING_USER' { '답변 대기' }
        'AWAITING_EVIDENCE' { '추가 자료 대기' }
        'COMPLETED' { '완료' }
        'COMPLETED_PARTIAL' { '일부 범위만 완료' }
        'RESUMABLE_ERROR' { '오류 발생 · 이어서 가능' }
        'SOURCE_DRIFT' { '원본 파일이 변경됨' }
        'FAILED_STAGE' { '작업 실패' }
        'CANCELLED' { '취소됨' }
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
        'OPEN' { '검토 중' }
        'RESOLVED' { '처리됨' }
        'AWAITING_USER' { '답변 필요' }
        'AWAITING_EVIDENCE' { '자료 필요' }
        'DEFERRED' { '나중에 처리' }
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

function ConvertTo-DuoForgeMenuKeyInternal {
    [CmdletBinding()]
    param([AllowNull()]$Key)

    if ($null -eq $Key) { return [ordered]@{ action = 'None'; character = '' } }
    if ($Key -is [System.ConsoleKeyInfo]) {
        switch ($Key.Key) {
            ([ConsoleKey]::UpArrow) { return [ordered]@{ action = 'Up'; character = '' } }
            ([ConsoleKey]::DownArrow) { return [ordered]@{ action = 'Down'; character = '' } }
            ([ConsoleKey]::Home) { return [ordered]@{ action = 'Home'; character = '' } }
            ([ConsoleKey]::End) { return [ordered]@{ action = 'End'; character = '' } }
            ([ConsoleKey]::Enter) { return [ordered]@{ action = 'Enter'; character = '' } }
            ([ConsoleKey]::Escape) { return [ordered]@{ action = 'Escape'; character = '' } }
            ([ConsoleKey]::PageUp) { return [ordered]@{ action = 'PageUp'; character = '' } }
            ([ConsoleKey]::PageDown) { return [ordered]@{ action = 'PageDown'; character = '' } }
        }
        if ($Key.KeyChar -ne [char]0) { return [ordered]@{ action = 'Character'; character = [string]$Key.KeyChar } }
        return [ordered]@{ action = 'None'; character = '' }
    }
    if ($Key -is [ConsoleKey]) {
        return ConvertTo-DuoForgeMenuKeyInternal -Key ([string]$Key)
    }

    $text = [string]$Key
    switch -Regex ($text.Trim()) {
        '^(Up|UpArrow|↑)$' { return [ordered]@{ action = 'Up'; character = '' } }
        '^(Down|DownArrow|↓)$' { return [ordered]@{ action = 'Down'; character = '' } }
        '^Home$' { return [ordered]@{ action = 'Home'; character = '' } }
        '^End$' { return [ordered]@{ action = 'End'; character = '' } }
        '^(Enter|Return)$' { return [ordered]@{ action = 'Enter'; character = '' } }
        '^(Esc|Escape)$' { return [ordered]@{ action = 'Escape'; character = '' } }
        '^(PageUp|PgUp)$' { return [ordered]@{ action = 'PageUp'; character = '' } }
        '^(PageDown|PgDn)$' { return [ordered]@{ action = 'PageDown'; character = '' } }
        default {
            if ($text.Length -eq 1) { return [ordered]@{ action = 'Character'; character = $text } }
            return [ordered]@{ action = 'None'; character = '' }
        }
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

function New-DuoForgeMenuFrameInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Items,
        [AllowEmptyString()][string]$Title,
        [ValidateRange(0, 10000)][int]$SelectedIndex = 0,
        [AllowEmptyString()][string]$Message,
        [AllowEmptyString()][string]$Footer = '↑/↓ 이동 · Home/End · Enter 선택 · Esc 이전'
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Title)) { $lines.Add($Title); $lines.Add('') }
    if ($Items.Count -eq 0) {
        $lines.Add('선택할 수 있는 항목이 없습니다.')
    }
    else {
        $selected = [Math]::Max(0, [Math]::Min($SelectedIndex, $Items.Count - 1))
        for ($index = 0; $index -lt $Items.Count; $index++) {
            $item = $Items[$index]
            $prefix = if ($index -eq $selected) { '> ' } else { '  ' }
            $shortcut = if (@($item.shortcuts).Count -gt 0) { '[{0}] ' -f [string]$item.shortcuts[0] } else { '' }
            $suffix = if ([bool]$item.enabled) { '' } else { ' — 비활성화' }
            $lines.Add(('{0}{1}{2}{3}' -f $prefix, $shortcut, [string]$item.label, $suffix))
            if ($index -eq $selected -and -not [string]::IsNullOrWhiteSpace([string]$item.detail)) { $lines.Add(('    {0}' -f [string]$item.detail)) }
            if ($index -eq $selected -and -not [bool]$item.enabled) {
                $reason = if ([string]::IsNullOrWhiteSpace([string]$item.disabledReason)) { '현재 사용할 수 없는 항목입니다.' } else { [string]$item.disabledReason }
                $lines.Add(('    사용할 수 없는 이유: {0}' -f $reason))
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $lines.Add(''); $lines.Add($Message) }
    if (-not [string]::IsNullOrWhiteSpace($Footer)) { $lines.Add(''); $lines.Add($Footer) }
    return @($lines)
}

function Write-DuoForgeAnsiMenuFrameInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][string[]]$Lines,
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
    $lineCount = [Math]::Max([int](Get-DuoForgeObjectValue -Object $RenderState -Name 'lineCount' -Default 0), $Lines.Count)
    for ($index = 0; $index -lt $lineCount; $index++) {
        $null = $builder.Append("`r$escape[2K")
        if ($index -lt $Lines.Count) {
            $line = Limit-DuoForgeProgressTextInternal -Text ([string]$Lines[$index]) -Width $lineWidth
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
        [AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][System.Collections.IDictionary]$RenderState
    )

    $windowWidth = [Math]::Min(1000, [Math]::Max(2, [Console]::WindowWidth))
    $lineWidth = $windowWidth - 1
    if (-not [bool](Get-DuoForgeObjectValue -Object $RenderState -Name 'started' -Default $false)) {
        $RenderState.top = [Console]::CursorTop
        $RenderState.cursorVisible = $true
        try { $RenderState.cursorVisible = [Console]::CursorVisible } catch { }
        try { [Console]::CursorVisible = $false } catch { }
        $RenderState.started = $true
    }

    $top = [int]$RenderState.top
    $lineCount = [Math]::Max([int](Get-DuoForgeObjectValue -Object $RenderState -Name 'lineCount' -Default 0), $Lines.Count)
    if ($top -lt 0 -or $top + $lineCount -ge [Console]::BufferHeight) {
        throw '메뉴를 다시 그릴 콘솔 공간이 부족합니다.'
    }

    $blank = ' ' * $lineWidth
    for ($index = 0; $index -lt $lineCount; $index++) {
        $row = $top + $index
        [Console]::SetCursorPosition(0, $row)
        [Console]::Write($blank)
        [Console]::SetCursorPosition(0, $row)
        if ($index -lt $Lines.Count) {
            $line = Limit-DuoForgeProgressTextInternal -Text ([string]$Lines[$index]) -Width $lineWidth
            [Console]::Write($line)
        }
    }
    $RenderState.lineCount = $lineCount
    [Console]::SetCursorPosition(0, $top + $lineCount)
}

function Write-DuoForgeCursorMenuFrameInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][AllowEmptyString()][Parameter(Mandatory)][string[]]$Lines,
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

function Invoke-DuoForgeLineMenuSelectionInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Items,
        [AllowEmptyString()][string]$Title,
        [string]$Prompt = '선택',
        [AllowNull()][AllowEmptyString()][string]$EscapeValue,
        [scriptblock]$InputReader
    )

    if (-not [string]::IsNullOrWhiteSpace($Title)) { Write-Host ''; Write-Host $Title }
    if ($Items.Count -eq 0) { Write-Host '선택할 수 있는 항목이 없습니다.' -ForegroundColor Yellow; return $EscapeValue }
    foreach ($item in $Items) {
        $shortcut = if (@($item.shortcuts).Count -gt 0) { [string]$item.shortcuts[0] } else { '' }
        $prefix = if ([string]::IsNullOrWhiteSpace($shortcut)) { '-' } else { "[$shortcut]" }
        $suffix = if ([bool]$item.enabled) { '' } else { ' — 비활성화' }
        Write-Host ('{0} {1}{2}' -f $prefix, [string]$item.label, $suffix)
    }
    while ($true) {
        $choice = if ($null -ne $InputReader) { [string](& $InputReader $Prompt) } else { [string](Read-Host $Prompt) }
        $choice = $choice.Trim()
        if ([string]::IsNullOrWhiteSpace($choice) -and $Items.Count -gt 0) { $selected = $Items[0] }
        else {
            $selected = Find-DuoForgeMenuItemByShortcutInternal -Items $Items -Shortcut $choice
            if ($null -eq $selected -and ($choice -ieq 'Esc' -or $choice -ieq 'Escape')) { return $EscapeValue }
        }
        if ($null -eq $selected) { Write-Host '현재 가능한 항목을 선택해 주세요.' -ForegroundColor Yellow; continue }
        if (-not [bool]$selected.enabled) {
            $reason = if ([string]::IsNullOrWhiteSpace([string]$selected.disabledReason)) { '현재 사용할 수 없는 항목입니다.' } else { [string]$selected.disabledReason }
            Write-Host $reason -ForegroundColor DarkYellow
            continue
        }
        return [string]$selected.value
    }
}

function Invoke-DuoForgeMenuSelectionInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Items,
        [AllowEmptyString()][string]$Title,
        [string]$Prompt = '선택',
        [AllowNull()][AllowEmptyString()][string]$EscapeValue,
        [ValidateRange(0, 10000)][int]$InitialSelectedIndex = 0,
        [AllowEmptyString()][string]$Footer = '↑/↓ 이동 · Home/End · Enter 선택 · Esc 이전',
        [scriptblock]$KeyReader,
        [scriptblock]$InputReader,
        [scriptblock]$FrameWriter,
        [scriptblock]$CapabilityProbe
    )

    $menuItems = @(ConvertTo-DuoForgeMenuItemsInternal -Items $Items)
    if ($menuItems.Count -eq 0) { return $EscapeValue }
    if ($null -ne $InputReader -and $null -eq $KeyReader -and $null -eq $CapabilityProbe) {
        return Invoke-DuoForgeLineMenuSelectionInternal -Items $menuItems -Title $Title -Prompt $Prompt -EscapeValue $EscapeValue -InputReader $InputReader
    }
    $capability = Get-DuoForgeMenuCapabilityInternal -CapabilityProbe $CapabilityProbe
    if (-not [bool](Get-DuoForgeObjectValue -Object $capability -Name 'cursor' -Default $false)) {
        if ($null -eq $InputReader -and [string](Get-DuoForgeObjectValue -Object $capability -Name 'reason') -in @('non-interactive', 'redirected')) { return $EscapeValue }
        return Invoke-DuoForgeLineMenuSelectionInternal -Items $menuItems -Title $Title -Prompt $Prompt -EscapeValue $EscapeValue -InputReader $InputReader
    }

    $selectedIndex = [Math]::Max(0, [Math]::Min($InitialSelectedIndex, $menuItems.Count - 1))
    $message = ''
    $renderState = [ordered]@{
        started = $false
        lineCount = 0
        renderMode = [string](Get-DuoForgeObjectValue -Object $capability -Name 'renderMode' -Default 'ansi')
    }
    try {
        while ($true) {
            $frame = @(New-DuoForgeMenuFrameInternal -Items $menuItems -Title $Title -SelectedIndex $selectedIndex -Message $message -Footer $Footer)
            if ($null -ne $FrameWriter) { & $FrameWriter ([string[]]$frame) }
            else { Write-DuoForgeCursorMenuFrameInternal -Lines $frame -RenderState $renderState }
            $message = ''
            $rawKey = if ($null -ne $KeyReader) { & $KeyReader } else { [Console]::ReadKey($true) }
            $key = ConvertTo-DuoForgeMenuKeyInternal -Key $rawKey
            $selected = $null
            switch ([string]$key.action) {
                'Up' { $selectedIndex = ($selectedIndex - 1 + $menuItems.Count) % $menuItems.Count; continue }
                'Down' { $selectedIndex = ($selectedIndex + 1) % $menuItems.Count; continue }
                'Home' { $selectedIndex = 0; continue }
                'End' { $selectedIndex = $menuItems.Count - 1; continue }
                'Escape' { return $EscapeValue }
                'Character' {
                    $selected = Find-DuoForgeMenuItemByShortcutInternal -Items $menuItems -Shortcut ([string]$key.character)
                    if ($null -eq $selected) { $message = '현재 가능한 항목을 선택해 주세요.'; continue }
                }
                'Enter' { $selected = $menuItems[$selectedIndex] }
                default { continue }
            }
            if ($null -eq $selected) { continue }
            if (-not [bool]$selected.enabled) {
                $message = if ([string]::IsNullOrWhiteSpace([string]$selected.disabledReason)) { '현재 사용할 수 없는 항목입니다.' } else { [string]$selected.disabledReason }
                continue
            }
            return [string]$selected.value
        }
    }
    catch {
        if ($null -eq $FrameWriter) { Complete-DuoForgeMenuRenderInternal -RenderState $renderState }
        if ($null -eq $InputReader -and ($null -ne $FrameWriter -or $null -ne $KeyReader -or $null -ne $CapabilityProbe)) { throw }
        return Invoke-DuoForgeLineMenuSelectionInternal -Items $menuItems -Title $Title -Prompt $Prompt -EscapeValue $EscapeValue -InputReader $InputReader
    }
    finally {
        if ($null -eq $FrameWriter) { Complete-DuoForgeMenuRenderInternal -RenderState $renderState }
    }
}

function Invoke-DuoForgeMenuInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Items,
        [AllowEmptyString()][string]$Title,
        [string]$Prompt = '선택',
        [AllowNull()][AllowEmptyString()][string]$EscapeValue,
        [ValidateRange(0, 10000)][int]$InitialSelectedIndex = 0,
        [AllowEmptyString()][string]$Footer = '↑/↓ 이동 · Home/End · Enter 선택 · Esc 이전',
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker
    )

    if ($null -ne $MenuInvoker) { return & $MenuInvoker $Items $Title $EscapeValue $InitialSelectedIndex }
    return Invoke-DuoForgeMenuSelectionInternal -Items $Items -Title $Title -Prompt $Prompt -EscapeValue $EscapeValue -InitialSelectedIndex $InitialSelectedIndex -Footer $Footer -InputReader $InputReader
}
