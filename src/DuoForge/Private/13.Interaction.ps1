function New-DuoForgeInteractionResultInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('submit', 'back', 'cancel', 'interrupt', 'invalid', 'unavailable')][string]$Action,
        [AllowNull()]$Value = $null,
        [Parameter(Mandatory)][ValidateSet('key', 'line', 'dialog')][string]$Source,
        [Parameter(Mandatory)][ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget
    )

    return [ordered]@{
        action = $Action
        value = $Value
        source = $Source
        returnTarget = $ReturnTarget
    }
}

function ConvertTo-DuoForgeMenuInvokerResultInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$CancelReturnTarget = $ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $CancelReturnTarget
    )

    if ($Result -isnot [System.Collections.IDictionary]) {
        throw (New-DuoForgeException -Code 'DF-INTERACTION-RESULT' -Message '메뉴 입력기는 구조화 interaction 결과를 반환해야 합니다.')
    }
    $action = [string](Get-DuoForgeObjectValue -Object $Result -Name 'action')
    if ($action -notin @('submit', 'back', 'cancel', 'interrupt', 'invalid', 'unavailable')) {
        throw (New-DuoForgeException -Code 'DF-INTERACTION-RESULT' -Message '메뉴 입력기의 action이 공통 interaction 계약과 다릅니다.')
    }
    $source = [string](Get-DuoForgeObjectValue -Object $Result -Name 'source' -Default 'line')
    if ($source -notin @('key', 'line')) {
        throw (New-DuoForgeException -Code 'DF-INTERACTION-RESULT' -Message '메뉴 입력기의 source는 key 또는 line이어야 합니다.')
    }
    $target = switch ($action) {
        'back' { $ReturnTarget }
        'cancel' { $CancelReturnTarget }
        'interrupt' { $InterruptReturnTarget }
        'unavailable' { $CancelReturnTarget }
        default { $ReturnTarget }
    }
    return New-DuoForgeInteractionResultInternal -Action $action -Value (Get-DuoForgeObjectValue -Object $Result -Name 'value') -Source $source -ReturnTarget $target
}

function ConvertTo-DuoForgeInteractionKeyInternal {
    [CmdletBinding()]
    param([AllowNull()]$Key)

    if ($null -eq $Key) { return [ordered]@{ action = 'None'; character = '' } }
    if ($Key -is [System.ConsoleKeyInfo]) {
        $controlPressed = ($Key.Modifiers -band [ConsoleModifiers]::Control) -eq [ConsoleModifiers]::Control
        if (($controlPressed -and $Key.Key -eq [ConsoleKey]::C) -or [int]$Key.KeyChar -eq 3) {
            return [ordered]@{ action = 'Interrupt'; character = '' }
        }
        switch ($Key.Key) {
            ([ConsoleKey]::UpArrow) { return [ordered]@{ action = 'Up'; character = '' } }
            ([ConsoleKey]::DownArrow) { return [ordered]@{ action = 'Down'; character = '' } }
            ([ConsoleKey]::Home) { return [ordered]@{ action = 'Home'; character = '' } }
            ([ConsoleKey]::End) { return [ordered]@{ action = 'End'; character = '' } }
            ([ConsoleKey]::Enter) { return [ordered]@{ action = 'Enter'; character = '' } }
            ([ConsoleKey]::Escape) { return [ordered]@{ action = 'Escape'; character = '' } }
            ([ConsoleKey]::Backspace) { return [ordered]@{ action = 'Backspace'; character = '' } }
            ([ConsoleKey]::PageUp) { return [ordered]@{ action = 'PageUp'; character = '' } }
            ([ConsoleKey]::PageDown) { return [ordered]@{ action = 'PageDown'; character = '' } }
        }
        if ($Key.KeyChar -ne [char]0) { return [ordered]@{ action = 'Character'; character = [string]$Key.KeyChar } }
        return [ordered]@{ action = 'None'; character = '' }
    }
    if ($Key -is [ConsoleKey]) { return ConvertTo-DuoForgeInteractionKeyInternal -Key ([string]$Key) }

    $text = [string]$Key
    switch -Regex ($text.Trim()) {
        '^(Ctrl\+C|Control\+C|Interrupt)$' { return [ordered]@{ action = 'Interrupt'; character = '' } }
        '^(Up|UpArrow|↑)$' { return [ordered]@{ action = 'Up'; character = '' } }
        '^(Down|DownArrow|↓)$' { return [ordered]@{ action = 'Down'; character = '' } }
        '^Home$' { return [ordered]@{ action = 'Home'; character = '' } }
        '^End$' { return [ordered]@{ action = 'End'; character = '' } }
        '^(Enter|Return)$' { return [ordered]@{ action = 'Enter'; character = '' } }
        '^(Esc|Escape)$' { return [ordered]@{ action = 'Escape'; character = '' } }
        '^(Backspace|Back)$' { return [ordered]@{ action = 'Backspace'; character = '' } }
        '^(PageUp|PgUp)$' { return [ordered]@{ action = 'PageUp'; character = '' } }
        '^(PageDown|PgDn)$' { return [ordered]@{ action = 'PageDown'; character = '' } }
        default {
            if ($text.Length -eq 1) { return [ordered]@{ action = 'Character'; character = $text } }
            return [ordered]@{ action = 'None'; character = '' }
        }
    }
}

function Read-DuoForgeConsoleKeyInternal {
    [CmdletBinding()]
    param([scriptblock]$KeyReader)

    if ($null -ne $KeyReader) { return & $KeyReader }
    return [Console]::ReadKey($true)
}

function Read-DuoForgeAvailableConsoleKeysInternal {
    [CmdletBinding()]
    param()

    $buffer = [System.Collections.Generic.List[object]]::new()
    try {
        while ([Console]::KeyAvailable) { $buffer.Add((Read-DuoForgeConsoleKeyInternal)) }
    }
    catch { }
    return @($buffer)
}

function Clear-DuoForgeConsoleInputBufferInternal {
    [CmdletBinding()]
    param()

    $null = @(Read-DuoForgeAvailableConsoleKeysInternal)
}

function Read-DuoForgeLineInteractionInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [scriptblock]$InputReader,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget = 'parent'
    )

    try {
        $value = if ($null -ne $InputReader) { [string](& $InputReader $Prompt) } else { [string](Read-Host $Prompt) }
        return New-DuoForgeInteractionResultInternal -Action submit -Value $value -Source line -ReturnTarget $ReturnTarget
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        return New-DuoForgeInteractionResultInternal -Action interrupt -Source line -ReturnTarget $ReturnTarget
    }
}

function Read-DuoForgeFreeTextInteractionInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget = 'parent',
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $ReturnTarget,
        [scriptblock]$InputReader,
        [scriptblock]$CapabilityProbe
    )

    if ($null -eq $InputReader) {
        $capability = Get-DuoForgeMenuCapabilityInternal -CapabilityProbe $CapabilityProbe
        if ([string](Get-DuoForgeObjectValue -Object $capability -Name 'reason') -in @('non-interactive', 'redirected', 'console-unavailable')) {
            return New-DuoForgeInteractionResultInternal -Action unavailable -Source line -ReturnTarget $ReturnTarget
        }
    }
    $result = Read-DuoForgeLineInteractionInternal -Prompt $Prompt -InputReader $InputReader -ReturnTarget $ReturnTarget
    if ([string]$result.action -eq 'interrupt') { return New-DuoForgeInteractionResultInternal -Action interrupt -Source line -ReturnTarget $InterruptReturnTarget }
    return $result
}

function Resolve-DuoForgeMenuChoiceInteractionInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Items,
        [AllowNull()][AllowEmptyString()]$Value,
        [ValidateRange(0, 10000)][int]$InitialSelectedIndex = 0,
        [Parameter(Mandatory)][ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$CancelReturnTarget = $ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $CancelReturnTarget,
        [ValidateSet('key', 'line')][string]$Source = 'line'
    )

    $menuItems = @(ConvertTo-DuoForgeMenuItemsInternal -Items $Items)
    $choice = [string]$Value
    $trimmed = $choice.Trim()
    if ($trimmed -ieq 'B' -or $trimmed -ieq 'Esc' -or $trimmed -ieq 'Escape') {
        return New-DuoForgeInteractionResultInternal -Action back -Source $Source -ReturnTarget $ReturnTarget
    }
    if ($trimmed -ieq 'Q') { return New-DuoForgeInteractionResultInternal -Action cancel -Source $Source -ReturnTarget $CancelReturnTarget }
    if ($trimmed -ieq 'Ctrl+C' -or $trimmed -ieq 'Control+C') {
        return New-DuoForgeInteractionResultInternal -Action interrupt -Source $Source -ReturnTarget $InterruptReturnTarget
    }
    if ([string]::IsNullOrWhiteSpace($trimmed) -and $menuItems.Count -gt 0) {
        $selectedIndex = [Math]::Max(0, [Math]::Min($InitialSelectedIndex, $menuItems.Count - 1))
        $selected = $menuItems[$selectedIndex]
    }
    else {
        $selected = Find-DuoForgeMenuItemByShortcutInternal -Items $menuItems -Shortcut $trimmed
        if ($null -eq $selected) { $selected = @($menuItems | Where-Object { [string]$_.value -eq $trimmed } | Select-Object -First 1) }
        if ($selected -is [array]) { $selected = if ($selected.Count -gt 0) { $selected[0] } else { $null } }
    }
    if ($null -eq $selected -or -not [bool]$selected.enabled) {
        return New-DuoForgeInteractionResultInternal -Action invalid -Value $choice -Source $Source -ReturnTarget $ReturnTarget
    }
    if ([string]$selected.value -eq 'back') {
        return New-DuoForgeInteractionResultInternal -Action back -Source $Source -ReturnTarget $ReturnTarget
    }
    return New-DuoForgeInteractionResultInternal -Action submit -Value ([string]$selected.value) -Source $Source -ReturnTarget $ReturnTarget
}

function Read-DuoForgeLineMenuInteractionInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Items,
        [AllowEmptyString()][string]$Title,
        [string]$Prompt = '선택',
        [ValidateRange(0, 10000)][int]$InitialSelectedIndex = 0,
        [Parameter(Mandatory)][ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$CancelReturnTarget = $ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $CancelReturnTarget,
        [scriptblock]$InputReader
    )

    $menuItems = @(ConvertTo-DuoForgeMenuItemsInternal -Items $Items)
    if ($menuItems.Count -eq 0) { return New-DuoForgeInteractionResultInternal -Action unavailable -Source line -ReturnTarget $CancelReturnTarget }
    $layout = Get-DuoForgeDisplayLayoutInternal -NoColor
    $selectedIndex = [Math]::Max(0, [Math]::Min($InitialSelectedIndex, $menuItems.Count - 1))
    Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeMenuFrameRowsInternal -Items $menuItems -Title $Title -SelectedIndex $selectedIndex -Footer '' -Width ([int]$layout.width) -Height ([int]$layout.height) -ExpandAllDetails) -Layout $layout
    while ($true) {
        $lineResult = Read-DuoForgeLineInteractionInternal -Prompt $Prompt -InputReader $InputReader -ReturnTarget $ReturnTarget
        if ([string]$lineResult.action -eq 'interrupt') { return New-DuoForgeInteractionResultInternal -Action interrupt -Source line -ReturnTarget $InterruptReturnTarget }
        $resolved = Resolve-DuoForgeMenuChoiceInteractionInternal -Items $menuItems -Value $lineResult.value -InitialSelectedIndex $selectedIndex -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -Source line
        if ([string]$resolved.action -ne 'invalid') { return $resolved }
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '현재 가능한 항목과 지원 키를 선택해 주세요.' -Layout $layout) -Layout $layout
    }
}

function Read-DuoForgeMenuInteractionInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Items,
        [AllowEmptyString()][string]$Title,
        [string]$Prompt = '선택',
        [ValidateRange(0, 10000)][int]$InitialSelectedIndex = 0,
        [AllowEmptyString()][string]$Footer = '↑/↓ 이동 · Home/End · Enter 선택 · Esc/B 이전 · Q 취소',
        [Parameter(Mandatory)][ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$CancelReturnTarget = $ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $CancelReturnTarget,
        [scriptblock]$InputReader,
        [scriptblock]$KeyReader,
        [scriptblock]$FrameWriter,
        [scriptblock]$CapabilityProbe,
        [switch]$ContextTransition
    )

    $menuItems = @(ConvertTo-DuoForgeMenuItemsInternal -Items $Items)
    if ($menuItems.Count -eq 0) { return New-DuoForgeInteractionResultInternal -Action unavailable -Source line -ReturnTarget $CancelReturnTarget }
    if ($null -ne $InputReader -and $null -eq $KeyReader -and $null -eq $CapabilityProbe) {
        return Read-DuoForgeLineMenuInteractionInternal -Items $menuItems -Title $Title -Prompt $Prompt -InitialSelectedIndex $InitialSelectedIndex -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -InputReader $InputReader
    }
    $capability = Get-DuoForgeMenuCapabilityInternal -CapabilityProbe $CapabilityProbe
    if (-not [bool](Get-DuoForgeObjectValue -Object $capability -Name 'cursor' -Default $false)) {
        $reason = [string](Get-DuoForgeObjectValue -Object $capability -Name 'reason')
        if ($null -eq $InputReader -and $reason -in @('non-interactive', 'redirected', 'console-unavailable')) {
            return New-DuoForgeInteractionResultInternal -Action unavailable -Source line -ReturnTarget $CancelReturnTarget
        }
        return Read-DuoForgeLineMenuInteractionInternal -Items $menuItems -Title $Title -Prompt $Prompt -InitialSelectedIndex $InitialSelectedIndex -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -InputReader $InputReader
    }

    $selectedIndex = [Math]::Max(0, [Math]::Min($InitialSelectedIndex, $menuItems.Count - 1))
    $message = ''
    $renderState = [ordered]@{ started = $false; lineCount = 0; renderMode = [string](Get-DuoForgeObjectValue -Object $capability -Name 'renderMode' -Default 'ansi') }
    $restoreTreatControlC = $false
    $originalTreatControlC = $false
    try {
        if ($null -eq $KeyReader) {
            try {
                $originalTreatControlC = [Console]::TreatControlCAsInput
                if (-not $originalTreatControlC) { [Console]::TreatControlCAsInput = $true; $restoreTreatControlC = $true }
            }
            catch { }
        }
        while ($true) {
            $frameWidth = 0
            $frameHeight = 0
            try { $frameWidth = [int][Console]::WindowWidth; $frameHeight = [int][Console]::WindowHeight } catch { }
            $frameRows = @(New-DuoForgeMenuFrameRowsInternal -Items $menuItems -Title $Title -SelectedIndex $selectedIndex -Message $message -Footer $Footer -Width $frameWidth -Height $frameHeight -ContextTransition:$ContextTransition)
            if ($null -ne $FrameWriter) { & $FrameWriter ([string[]]@($frameRows | ForEach-Object { [string]$_.text })) }
            else { Write-DuoForgeCursorMenuFrameInternal -Lines $frameRows -RenderState $renderState }
            $message = ''
            $rawKey = Read-DuoForgeConsoleKeyInternal -KeyReader $KeyReader
            $key = ConvertTo-DuoForgeInteractionKeyInternal -Key $rawKey
            $selected = $null
            switch ([string]$key.action) {
                'Interrupt' { return New-DuoForgeInteractionResultInternal -Action interrupt -Source key -ReturnTarget $InterruptReturnTarget }
                'Escape' { return New-DuoForgeInteractionResultInternal -Action back -Source key -ReturnTarget $ReturnTarget }
                'Up' { $selectedIndex = ($selectedIndex - 1 + $menuItems.Count) % $menuItems.Count; continue }
                'Down' { $selectedIndex = ($selectedIndex + 1) % $menuItems.Count; continue }
                'Home' { $selectedIndex = 0; continue }
                'End' { $selectedIndex = $menuItems.Count - 1; continue }
                'Enter' { $selected = $menuItems[$selectedIndex] }
                'Character' {
                    $character = [string]$key.character
                    if ($character -ieq 'B') { return New-DuoForgeInteractionResultInternal -Action back -Source key -ReturnTarget $ReturnTarget }
                    if ($character -ieq 'Q') { return New-DuoForgeInteractionResultInternal -Action cancel -Source key -ReturnTarget $CancelReturnTarget }
                    $selected = Find-DuoForgeMenuItemByShortcutInternal -Items $menuItems -Shortcut $character
                    if ($null -eq $selected) { $message = '현재 가능한 항목과 지원 키를 선택해 주세요.'; continue }
                }
                default { continue }
            }
            if ($null -eq $selected) { continue }
            if (-not [bool]$selected.enabled) { $message = if ([string]::IsNullOrWhiteSpace([string]$selected.disabledReason)) { '현재 사용할 수 없는 항목입니다.' } else { [string]$selected.disabledReason }; continue }
            if ([string]$selected.value -eq 'back') { return New-DuoForgeInteractionResultInternal -Action back -Source key -ReturnTarget $ReturnTarget }
            return New-DuoForgeInteractionResultInternal -Action submit -Value ([string]$selected.value) -Source key -ReturnTarget $ReturnTarget
        }
    }
    catch {
        if ($null -eq $FrameWriter) { Complete-DuoForgeMenuRenderInternal -RenderState $renderState }
        if ($restoreTreatControlC) { try { [Console]::TreatControlCAsInput = $originalTreatControlC } catch { }; $restoreTreatControlC = $false }
        if ($null -eq $InputReader -and ($null -ne $FrameWriter -or $null -ne $KeyReader -or $null -ne $CapabilityProbe)) { throw }
        return Read-DuoForgeLineMenuInteractionInternal -Items $menuItems -Title $Title -Prompt $Prompt -InitialSelectedIndex $InitialSelectedIndex -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -InputReader $InputReader
    }
    finally {
        if ($restoreTreatControlC) { try { [Console]::TreatControlCAsInput = $originalTreatControlC } catch { } }
        if ($null -eq $FrameWriter) { Complete-DuoForgeMenuRenderInternal -RenderState $renderState }
    }
}

function Invoke-DuoForgeMenuInteractionInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Items,
        [AllowEmptyString()][string]$Title,
        [string]$Prompt = '선택',
        [ValidateRange(0, 10000)][int]$InitialSelectedIndex = 0,
        [AllowEmptyString()][string]$Footer = '↑/↓ 이동 · Home/End · Enter 선택 · Esc/B 이전 · Q 취소',
        [Parameter(Mandatory)][ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$CancelReturnTarget = $ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $CancelReturnTarget,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker,
        [scriptblock]$KeyReader,
        [scriptblock]$FrameWriter,
        [scriptblock]$CapabilityProbe,
        [switch]$ContextTransition
    )

    if ($null -ne $MenuInvoker) {
        $result = & $MenuInvoker $Items $Title $InitialSelectedIndex $ReturnTarget $CancelReturnTarget $InterruptReturnTarget
        return ConvertTo-DuoForgeMenuInvokerResultInternal -Result $result -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget
    }
    return Read-DuoForgeMenuInteractionInternal -Items $Items -Title $Title -Prompt $Prompt -InitialSelectedIndex $InitialSelectedIndex -Footer $Footer -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -InputReader $InputReader -KeyReader $KeyReader -FrameWriter $FrameWriter -CapabilityProbe $CapabilityProbe -ContextTransition:$ContextTransition
}

function Resolve-DuoForgeYesNoInputInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$CancelReturnTarget = $ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $CancelReturnTarget,
        [ValidateSet('key', 'line')][string]$Source = 'line'
    )

    $choice = $Value.Trim()
    if ($choice -ieq 'B' -or $choice -ieq 'Esc' -or $choice -ieq 'Escape') {
        return New-DuoForgeInteractionResultInternal -Action back -Source $Source -ReturnTarget $ReturnTarget
    }
    if ($choice -ieq 'Q' -or $choice -ieq 'N') {
        return New-DuoForgeInteractionResultInternal -Action cancel -Value $(if ($choice -ieq 'N') { $false } else { $null }) -Source $Source -ReturnTarget $CancelReturnTarget
    }
    if ($choice -ieq 'Ctrl+C' -or $choice -ieq 'Control+C') {
        return New-DuoForgeInteractionResultInternal -Action interrupt -Source $Source -ReturnTarget $InterruptReturnTarget
    }
    if ($choice -ieq 'Y') {
        return New-DuoForgeInteractionResultInternal -Action submit -Value $true -Source $Source -ReturnTarget $ReturnTarget
    }
    return New-DuoForgeInteractionResultInternal -Action invalid -Value $Value -Source $Source -ReturnTarget $ReturnTarget
}

function Read-DuoForgeYesNoLineConfirmationInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$CancelReturnTarget = $ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $CancelReturnTarget,
        [scriptblock]$InputReader
    )

    while ($true) {
        $lineResult = Read-DuoForgeLineInteractionInternal -Prompt $Prompt -InputReader $InputReader -ReturnTarget $ReturnTarget
        if ([string]$lineResult.action -eq 'interrupt') {
            return New-DuoForgeInteractionResultInternal -Action interrupt -Source line -ReturnTarget $InterruptReturnTarget
        }
        $resolved = Resolve-DuoForgeYesNoInputInternal -Value ([string]$lineResult.value) -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -Source line
        if ([string]$resolved.action -ne 'invalid') { return $resolved }
        $layout = Get-DuoForgeDisplayLayoutInternal -NoColor
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind warning -Title 'Y 또는 N과 지원 키를 정확히 입력해 주세요.' -Layout $layout) -Layout $layout
    }
}

function Read-DuoForgeYesNoConfirmationInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$CancelReturnTarget = $ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $CancelReturnTarget,
        [scriptblock]$InputReader,
        [scriptblock]$KeyReader,
        [scriptblock]$FrameWriter,
        [scriptblock]$CapabilityProbe
    )

    if ($null -ne $InputReader -and $null -eq $KeyReader -and $null -eq $CapabilityProbe) {
        return Read-DuoForgeYesNoLineConfirmationInternal -Prompt $Prompt -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -InputReader $InputReader
    }
    $capability = Get-DuoForgeMenuCapabilityInternal -CapabilityProbe $CapabilityProbe
    if (-not [bool](Get-DuoForgeObjectValue -Object $capability -Name 'cursor' -Default $false)) {
        $reason = [string](Get-DuoForgeObjectValue -Object $capability -Name 'reason')
        if ($null -eq $InputReader -and $reason -in @('non-interactive', 'redirected', 'console-unavailable')) {
            return New-DuoForgeInteractionResultInternal -Action unavailable -Source line -ReturnTarget $CancelReturnTarget
        }
        return Read-DuoForgeYesNoLineConfirmationInternal -Prompt $Prompt -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -InputReader $InputReader
    }

    $items = @(ConvertTo-DuoForgeMenuItemsInternal -Items @(
        [ordered]@{ value = 'Y'; label = '예, 계속합니다'; shortcuts = @('Y'); enabled = $true }
        [ordered]@{ value = 'N'; label = '아니요, 변경하지 않습니다'; shortcuts = @('N'); enabled = $true }
    ))
    $selectedIndex = 1
    $message = ''
    $renderState = [ordered]@{ started = $false; lineCount = 0; renderMode = [string](Get-DuoForgeObjectValue -Object $capability -Name 'renderMode' -Default 'ansi') }
    $restoreTreatControlC = $false
    $originalTreatControlC = $false
    try {
        if ($null -eq $KeyReader) {
            try {
                $originalTreatControlC = [Console]::TreatControlCAsInput
                if (-not $originalTreatControlC) {
                    [Console]::TreatControlCAsInput = $true
                    $restoreTreatControlC = $true
                }
            }
            catch { }
        }
        while ($true) {
            $frameRows = @(New-DuoForgeMenuFrameRowsInternal -Items $items -Title $Prompt -SelectedIndex $selectedIndex -Message $message -Footer 'Y/N 선택 · Enter 확정 · Esc/B 이전 · Q 취소')
            if ($null -ne $FrameWriter) { & $FrameWriter ([string[]]@($frameRows | ForEach-Object { [string]$_.text })) }
            else { Write-DuoForgeCursorMenuFrameInternal -Lines $frameRows -RenderState $renderState }
            $message = ''

            $rawKey = Read-DuoForgeConsoleKeyInternal -KeyReader $KeyReader
            $key = ConvertTo-DuoForgeInteractionKeyInternal -Key $rawKey
            $choice = $null
            switch ([string]$key.action) {
                'Interrupt' { return New-DuoForgeInteractionResultInternal -Action interrupt -Source key -ReturnTarget $InterruptReturnTarget }
                'Escape' { return New-DuoForgeInteractionResultInternal -Action back -Source key -ReturnTarget $ReturnTarget }
                'Up' { $selectedIndex = ($selectedIndex - 1 + $items.Count) % $items.Count; continue }
                'Down' { $selectedIndex = ($selectedIndex + 1) % $items.Count; continue }
                'Home' { $selectedIndex = 0; continue }
                'End' { $selectedIndex = $items.Count - 1; continue }
                'Enter' { $choice = [string]$items[$selectedIndex].value }
                'Character' {
                    $character = [string]$key.character
                    if ($character -ieq 'B') { return New-DuoForgeInteractionResultInternal -Action back -Source key -ReturnTarget $ReturnTarget }
                    if ($character -ieq 'Q') { return New-DuoForgeInteractionResultInternal -Action cancel -Source key -ReturnTarget $CancelReturnTarget }
                    if ($character -ieq 'Y' -or $character -ieq 'N') { $choice = $character }
                    else { $message = 'Y 또는 N과 지원 키를 선택해 주세요.'; continue }
                }
                default { continue }
            }
            if ($null -eq $choice) { continue }
            return Resolve-DuoForgeYesNoInputInternal -Value $choice -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -Source key
        }
    }
    catch {
        if ($null -eq $FrameWriter) { Complete-DuoForgeMenuRenderInternal -RenderState $renderState }
        if ($restoreTreatControlC) {
            try { [Console]::TreatControlCAsInput = $originalTreatControlC } catch { }
            $restoreTreatControlC = $false
        }
        if ($null -eq $InputReader -and ($null -ne $FrameWriter -or $null -ne $KeyReader -or $null -ne $CapabilityProbe)) { throw }
        return Read-DuoForgeYesNoLineConfirmationInternal -Prompt $Prompt -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -InputReader $InputReader
    }
    finally {
        if ($restoreTreatControlC) { try { [Console]::TreatControlCAsInput = $originalTreatControlC } catch { } }
        if ($null -eq $FrameWriter) { Complete-DuoForgeMenuRenderInternal -RenderState $renderState }
    }
}

function Resolve-DuoForgeExactTokenInputInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][ValidatePattern('^[A-Z]+$')][string]$Token,
        [Parameter(Mandatory)][ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$CancelReturnTarget = $ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $CancelReturnTarget,
        [ValidateSet('key', 'line')][string]$Source = 'line'
    )

    if ($Value -ieq 'B' -or $Value -ieq 'Esc' -or $Value -ieq 'Escape') {
        return New-DuoForgeInteractionResultInternal -Action back -Source $Source -ReturnTarget $ReturnTarget
    }
    if ($Value -ieq 'Q') { return New-DuoForgeInteractionResultInternal -Action cancel -Source $Source -ReturnTarget $CancelReturnTarget }
    if ($Value -ieq 'Ctrl+C' -or $Value -ieq 'Control+C') {
        return New-DuoForgeInteractionResultInternal -Action interrupt -Source $Source -ReturnTarget $InterruptReturnTarget
    }
    if ($Value -ceq $Token) { return New-DuoForgeInteractionResultInternal -Action submit -Value $Value -Source $Source -ReturnTarget $ReturnTarget }
    return New-DuoForgeInteractionResultInternal -Action invalid -Value $Value -Source $Source -ReturnTarget $ReturnTarget
}

function Read-DuoForgeExactLineConfirmationInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Z]+$')][string]$Token,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$CancelReturnTarget = $ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $CancelReturnTarget,
        [scriptblock]$InputReader
    )

    while ($true) {
        $lineResult = Read-DuoForgeLineInteractionInternal -Prompt $Prompt -InputReader $InputReader -ReturnTarget $ReturnTarget
        if ([string]$lineResult.action -eq 'interrupt') { return New-DuoForgeInteractionResultInternal -Action interrupt -Source line -ReturnTarget $InterruptReturnTarget }
        $resolved = Resolve-DuoForgeExactTokenInputInternal -Value ([string]$lineResult.value) -Token $Token -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -Source line
        if ([string]$resolved.action -ne 'invalid') { return $resolved }
        $layout = Get-DuoForgeDisplayLayoutInternal -NoColor
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind warning -Title ("확인어 $Token 또는 지원 키를 정확히 입력해 주세요.") -Layout $layout) -Layout $layout
    }
}

function Read-DuoForgeExactConfirmationInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Z]+$')][string]$Token,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$CancelReturnTarget = $ReturnTarget,
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $CancelReturnTarget,
        [scriptblock]$InputReader,
        [scriptblock]$KeyReader,
        [scriptblock]$FrameWriter,
        [scriptblock]$CapabilityProbe
    )

    if ($null -ne $InputReader -and $null -eq $KeyReader -and $null -eq $CapabilityProbe) {
        return Read-DuoForgeExactLineConfirmationInternal -Token $Token -Prompt $Prompt -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -InputReader $InputReader
    }
    $capability = Get-DuoForgeMenuCapabilityInternal -CapabilityProbe $CapabilityProbe
    if (-not [bool](Get-DuoForgeObjectValue -Object $capability -Name 'cursor' -Default $false)) {
        $reason = [string](Get-DuoForgeObjectValue -Object $capability -Name 'reason')
        if ($null -eq $InputReader -and $reason -in @('non-interactive', 'redirected', 'console-unavailable')) {
            return New-DuoForgeInteractionResultInternal -Action unavailable -Source line -ReturnTarget $CancelReturnTarget
        }
        return Read-DuoForgeExactLineConfirmationInternal -Token $Token -Prompt $Prompt -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -InputReader $InputReader
    }

    $buffer = ''
    $message = ''
    $renderState = [ordered]@{ started = $false; lineCount = 0; renderMode = [string](Get-DuoForgeObjectValue -Object $capability -Name 'renderMode' -Default 'ansi') }
    $restoreTreatControlC = $false
    $originalTreatControlC = $false
    try {
        if ($null -eq $KeyReader) {
            try {
                $originalTreatControlC = [Console]::TreatControlCAsInput
                if (-not $originalTreatControlC) {
                    [Console]::TreatControlCAsInput = $true
                    $restoreTreatControlC = $true
                }
            }
            catch { }
        }
        while ($true) {
            $lines = @(
                $Prompt
                ("확인어: {0}" -f $buffer)
                $(if ([string]::IsNullOrWhiteSpace($message)) { '' } else { "! $message" })
                ("$Token 입력 · Enter 확정 · Esc/B 이전 · Q 취소")
            )
            if ($null -ne $FrameWriter) { & $FrameWriter ([string[]]$lines) }
            else { Write-DuoForgeCursorMenuFrameInternal -Lines $lines -RenderState $renderState }

            $rawKey = Read-DuoForgeConsoleKeyInternal -KeyReader $KeyReader
            $key = ConvertTo-DuoForgeInteractionKeyInternal -Key $rawKey
            switch ([string]$key.action) {
                'Interrupt' { return New-DuoForgeInteractionResultInternal -Action interrupt -Source key -ReturnTarget $InterruptReturnTarget }
                'Escape' { return New-DuoForgeInteractionResultInternal -Action back -Source key -ReturnTarget $ReturnTarget }
                'Backspace' {
                    if ($buffer.Length -gt 0) { $buffer = $buffer.Substring(0, $buffer.Length - 1) }
                    $message = ''
                    continue
                }
                'Character' {
                    $character = [string]$key.character
                    if ($buffer.Length -eq 0 -and $character -ieq 'B') { return New-DuoForgeInteractionResultInternal -Action back -Source key -ReturnTarget $ReturnTarget }
                    if ($buffer.Length -eq 0 -and $character -ieq 'Q') { return New-DuoForgeInteractionResultInternal -Action cancel -Source key -ReturnTarget $CancelReturnTarget }
                    if ($character.Length -eq 1 -and [int][char]$character -ge 32 -and [int][char]$character -le 126) {
                        if ($buffer.Length -lt 64) { $buffer += $character }
                        $message = ''
                    }
                    continue
                }
                'Enter' {
                    $resolved = Resolve-DuoForgeExactTokenInputInternal -Value $buffer -Token $Token -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -Source key
                    if ([string]$resolved.action -ne 'invalid') { return $resolved }
                    $buffer = ''
                    $message = "확인어 ${Token}을(를) 대소문자와 공백까지 정확히 입력해 주세요."
                    continue
                }
                default { continue }
            }
        }
    }
    catch {
        if ($null -eq $FrameWriter) { Complete-DuoForgeMenuRenderInternal -RenderState $renderState }
        if ($restoreTreatControlC) {
            try { [Console]::TreatControlCAsInput = $originalTreatControlC } catch { }
            $restoreTreatControlC = $false
        }
        if ($null -eq $InputReader -and ($null -ne $FrameWriter -or $null -ne $KeyReader -or $null -ne $CapabilityProbe)) { throw }
        return Read-DuoForgeExactLineConfirmationInternal -Token $Token -Prompt $Prompt -ReturnTarget $ReturnTarget -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -InputReader $InputReader
    }
    finally {
        if ($restoreTreatControlC) { try { [Console]::TreatControlCAsInput = $originalTreatControlC } catch { } }
        if ($null -eq $FrameWriter) { Complete-DuoForgeMenuRenderInternal -RenderState $renderState }
    }
}
