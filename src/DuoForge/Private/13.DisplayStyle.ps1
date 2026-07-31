function Get-DuoForgeDisplayLayoutInternal {
    [CmdletBinding()]
    param(
        [ValidateRange(0, 1000)][int]$Width = 0,
        [ValidateRange(0, 1000)][int]$Height = 0,
        [switch]$Ascii,
        [switch]$NoColor
    )

    if ($Width -le 0) {
        try { $Width = [int][Console]::WindowWidth } catch { $Width = 100 }
    }
    if ($Height -le 0) {
        try { $Height = [int][Console]::WindowHeight } catch { $Height = 30 }
    }
    $Width = [Math]::Max(20, [Math]::Min(1000, $Width))
    $Height = [Math]::Max(12, [Math]::Min(1000, $Height))

    $supportsColor = -not $NoColor -and [string]::IsNullOrWhiteSpace([string]$env:NO_COLOR)
    if ($supportsColor) {
        try { if ([Console]::IsOutputRedirected) { $supportsColor = $false } } catch { $supportsColor = $false }
    }

    $unicode = -not $Ascii
    return [ordered]@{
        width = $Width
        lineWidth = [Math]::Max(19, $Width - 1)
        height = $Height
        compact = $Height -le 23
        unicode = $unicode
        color = $supportsColor
        sectionMark = if ($unicode) { '──' } else { '--' }
        divider = if ($unicode) { '─' } else { '-' }
        successMark = if ($unicode) { '✓' } else { 'OK' }
        errorMark = if ($unicode) { '×' } else { 'X' }
        warningMark = '!'
        infoMark = 'i'
    }
}

function New-DuoForgeDisplayRowInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][Parameter(Mandatory)][string]$Text,
        [ValidateSet('text', 'page', 'tag', 'divider', 'section', 'field', 'list', 'selection', 'info', 'success', 'warning', 'error', 'meta', 'spacer')][string]$Role = 'text',
        [AllowEmptyString()][string]$Color = ''
    )

    return [ordered]@{ text = $Text; role = $Role; color = $Color }
}

function Get-DuoForgeDisplayRoleColorInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Role)

    switch ($Role) {
        'page' { 'Cyan' }
        'tag' { 'Yellow' }
        'section' { 'Cyan' }
        'selection' { 'Cyan' }
        'meta' { 'DarkGray' }
        'success' { 'Green' }
        'warning' { 'Yellow' }
        'error' { 'Red' }
        default { '' }
    }
}

function ConvertTo-DuoForgeDisplaySafeTextInternal {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $safe = $Text -replace "`e\][^`a]*(?:`a|`e\\)", ''
    $safe = $safe -replace "`e\[[0-?]*[ -/]*[@-~]", ''
    $safe = $safe -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]', ' '
    return $safe
}

function ConvertTo-DuoForgeDisplayFallbackTextInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Layout
    )

    if ([bool]$Layout.unicode) { return $Text }
    return $Text `
        -replace '──', '--' `
        -replace '─', '-' `
        -replace '✓', 'OK' `
        -replace '[×✗]', 'X' `
        -replace '●', '*' `
        -replace '◐', '~' `
        -replace '○', 'o' `
        -replace '↻', '~' `
        -replace '↑↓', 'Up/Down' `
        -replace '↑', 'Up' `
        -replace '↓', 'Down' `
        -replace '›', '>' `
        -replace '█', '#' `
        -replace '░', '-' `
        -replace '…', '...'
}

function Split-DuoForgeDisplayLineInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][Parameter(Mandatory)][string]$Text,
        [ValidateRange(1, 1000)][int]$Width
    )

    $safe = (ConvertTo-DuoForgeDisplaySafeTextInternal -Text $Text) -replace '\s+', ' '
    $remaining = $safe.Trim()
    $lines = [System.Collections.Generic.List[string]]::new()
    while (-not [string]::IsNullOrWhiteSpace($remaining)) {
        if ((Get-DuoForgeProgressTextWidthInternal -Text $remaining) -le $Width) {
            $lines.Add($remaining)
            break
        }
        $builder = [System.Text.StringBuilder]::new()
        $used = 0
        $consumedLength = 0
        $lastBreakLength = -1
        foreach ($unit in @(Get-DuoForgeProgressTextUnitsInternal -Text $remaining)) {
            $unitText = [string]$unit.text
            if ($used + [int]$unit.width -gt $Width) { break }
            $null = $builder.Append($unitText)
            $used += [int]$unit.width
            $consumedLength += $unitText.Length
            if ($unitText -eq ' ') { $lastBreakLength = $builder.Length }
        }
        if ($builder.Length -eq 0) { break }
        $nextIsSpace = $consumedLength -lt $remaining.Length -and [char]::IsWhiteSpace($remaining[$consumedLength])
        $takeLength = if ($nextIsSpace) { $builder.Length } elseif ($lastBreakLength -gt 0) { $lastBreakLength - 1 } else { $builder.Length }
        if ($takeLength -le 0) { $takeLength = $consumedLength }
        $line = $remaining.Substring(0, $takeLength).Trim()
        if (-not [string]::IsNullOrWhiteSpace($line)) { $lines.Add($line) }
        $remaining = $remaining.Substring([Math]::Min($remaining.Length, $takeLength)).TrimStart()
    }
    return @($lines)
}

function Split-DuoForgeDisplayTextInternal {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [ValidateRange(1, 1000)][int]$Width,
        [ValidateRange(1, 1000)][int]$MaximumLines = 1000,
        [switch]$PreserveParagraphs
    )

    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $sourceLines = if ($PreserveParagraphs) { @((ConvertTo-DuoForgeDisplaySafeTextInternal -Text $Text) -split "\r?\n") } else { @($Text) }
    $result = [System.Collections.Generic.List[string]]::new()
    $truncated = $false
    foreach ($sourceLine in $sourceLines) {
        if ($result.Count -ge $MaximumLines) { $truncated = $true; break }
        if ($PreserveParagraphs -and [string]::IsNullOrWhiteSpace([string]$sourceLine)) {
            if ($result.Count -gt 0 -and $result[$result.Count - 1] -ne '') { $result.Add('') }
            continue
        }
        foreach ($line in @(Split-DuoForgeDisplayLineInternal -Text ([string]$sourceLine) -Width $Width)) {
            if ($result.Count -ge $MaximumLines) { $truncated = $true; break }
            $result.Add([string]$line)
        }
        if ($truncated) { break }
    }
    while ($result.Count -gt 0 -and $result[$result.Count - 1] -eq '') { $result.RemoveAt($result.Count - 1) }
    if ($truncated -and $result.Count -gt 0) {
        $ellipsis = if ($Width -ge 3) { '…' } else { '.' }
        $result[$result.Count - 1] = Limit-DuoForgeProgressTextInternal -Text ($result[$result.Count - 1].TrimEnd('…') + $ellipsis) -Width $Width
    }
    return @($result)
}

function New-DuoForgeTextRowsInternal {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Layout,
        [ValidateRange(0, 100)][int]$Indent = 0,
        [ValidateRange(1, 1000)][int]$MaximumLines = 1000,
        [string]$Role = 'text',
        [AllowEmptyString()][string]$Color = '',
        [switch]$PreserveParagraphs
    )

    $prefix = ' ' * $Indent
    $contentWidth = [Math]::Max(1, [int]$Layout.lineWidth - $Indent)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in @(Split-DuoForgeDisplayTextInternal -Text $Text -Width $contentWidth -MaximumLines $MaximumLines -PreserveParagraphs:$PreserveParagraphs)) {
        $rows.Add((New-DuoForgeDisplayRowInternal -Text $(if ($line -eq '') { '' } else { $prefix + [string]$line }) -Role $(if ($line -eq '') { 'spacer' } else { $Role }) -Color $Color))
    }
    return @($rows)
}

function New-DuoForgePageHeaderRowsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [AllowEmptyString()][string]$Tag = '',
        [Parameter(Mandatory)][System.Collections.IDictionary]$Layout,
        [switch]$NoTrailingSpacer
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @(New-DuoForgeTextRowsInternal -Text $Title -Layout $Layout -MaximumLines 2 -Role 'page')) { $rows.Add($row) }
    if (-not [string]::IsNullOrWhiteSpace($Tag)) {
        $tagText = if ($Tag -match '^<.*>$') { $Tag } else { "<$Tag>" }
        foreach ($row in @(New-DuoForgeTextRowsInternal -Text $tagText -Layout $Layout -MaximumLines 1 -Role 'tag')) { $rows.Add($row) }
    }
    $dividerWidth = [Math]::Max(1, [int]$Layout.lineWidth)
    $rows.Add((New-DuoForgeDisplayRowInternal -Text ([string]$Layout.divider * $dividerWidth) -Role 'divider'))
    if (-not $NoTrailingSpacer) { $rows.Add((New-DuoForgeDisplayRowInternal -Text '' -Role 'spacer')) }
    return @($rows)
}

function New-DuoForgeSectionRowsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [AllowNull()][AllowEmptyString()][string]$Body,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Layout,
        [switch]$First,
        [switch]$Compact,
        [ValidateRange(0, 100)][int]$BodyIndent = 2,
        [ValidateRange(1, 1000)][int]$MaximumBodyLines = 1000,
        [string]$BodyRole = 'text',
        [switch]$PreserveParagraphs
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not $First -and -not $Compact) { $rows.Add((New-DuoForgeDisplayRowInternal -Text '' -Role 'spacer')) }
    $titlePrefix = "{0} " -f $Layout.sectionMark
    $titlePrefixWidth = Get-DuoForgeProgressTextWidthInternal -Text $titlePrefix
    $titleWidth = [Math]::Max(1, [int]$Layout.lineWidth - $titlePrefixWidth)
    $titleLines = @(Split-DuoForgeDisplayTextInternal -Text $Title -Width $titleWidth)
    for ($titleIndex = 0; $titleIndex -lt $titleLines.Count; $titleIndex++) {
        $prefix = if ($titleIndex -eq 0) { $titlePrefix } else { ' ' * $titlePrefixWidth }
        $rows.Add((New-DuoForgeDisplayRowInternal -Text ($prefix + [string]$titleLines[$titleIndex]) -Role 'section'))
    }
    if (-not [string]::IsNullOrWhiteSpace($Body)) {
        foreach ($row in @(New-DuoForgeTextRowsInternal -Text $Body -Layout $Layout -Indent $BodyIndent -MaximumLines $MaximumBodyLines -Role $BodyRole -PreserveParagraphs:$PreserveParagraphs)) { $rows.Add($row) }
    }
    return @($rows)
}

function New-DuoForgeFieldRowsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Layout,
        [ValidateRange(0, 100)][int]$Indent = 2,
        [ValidateRange(0, 100)][int]$KeyWidth = 0,
        [ValidateRange(1, 1000)][int]$MaximumLines = 1000,
        [string]$Role = 'field',
        [AllowEmptyString()][string]$Color = '',
        [switch]$PreserveParagraphs
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    $labelWidth = Get-DuoForgeProgressTextWidthInternal -Text $Label
    if ($KeyWidth -le 0) { $KeyWidth = $labelWidth }
    $valueColumn = $Indent + $KeyWidth + 2
    if ($valueColumn -gt [int]$Layout.lineWidth - 12) {
        $rows = [System.Collections.Generic.List[object]]::new()
        $rows.Add((New-DuoForgeDisplayRowInternal -Text ((' ' * $Indent) + $Label) -Role 'meta'))
        foreach ($row in @(New-DuoForgeTextRowsInternal -Text $Value -Layout $Layout -Indent ([Math]::Max(4, $Indent + 2)) -MaximumLines $MaximumLines -Role $Role -Color $Color -PreserveParagraphs:$PreserveParagraphs)) { $rows.Add($row) }
        return @($rows)
    }

    $padding = ' ' * [Math]::Max(0, $KeyWidth - $labelWidth)
    $firstPrefix = (' ' * $Indent) + $Label + $padding + '  '
    $continuationPrefix = ' ' * $valueColumn
    $valueWidth = [Math]::Max(1, [int]$Layout.lineWidth - $valueColumn)
    $lines = @(Split-DuoForgeDisplayTextInternal -Text $Value -Width $valueWidth -MaximumLines $MaximumLines -PreserveParagraphs:$PreserveParagraphs)
    $rows = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -eq '') { $rows.Add((New-DuoForgeDisplayRowInternal -Text '' -Role 'spacer')); continue }
        $prefix = if ($index -eq 0) { $firstPrefix } else { $continuationPrefix }
        $rows.Add((New-DuoForgeDisplayRowInternal -Text ($prefix + [string]$lines[$index]) -Role $Role -Color $Color))
    }
    return @($rows)
}

function New-DuoForgeListRowsInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Layout,
        [ValidateRange(0, 100)][int]$Indent = 2,
        [switch]$Numbered,
        [string]$Role = 'list'
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Items.Count; $index++) {
        $marker = if ($Numbered) { '{0}. ' -f ($index + 1) } else { '- ' }
        $prefix = (' ' * $Indent) + $marker
        $continuation = ' ' * ($Indent + (Get-DuoForgeProgressTextWidthInternal -Text $marker))
        $width = [Math]::Max(1, [int]$Layout.lineWidth - (Get-DuoForgeProgressTextWidthInternal -Text $prefix))
        $lines = @(Split-DuoForgeDisplayTextInternal -Text ([string]$Items[$index]) -Width $width)
        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            $rows.Add((New-DuoForgeDisplayRowInternal -Text ($(if ($lineIndex -eq 0) { $prefix } else { $continuation }) + [string]$lines[$lineIndex]) -Role $Role))
        }
    }
    return @($rows)
}

function New-DuoForgeNoticeRowsInternal {
    [CmdletBinding()]
    param(
        [ValidateSet('info', 'success', 'warning', 'error')][string]$Kind = 'info',
        [Parameter(Mandatory)][string]$Title,
        [AllowNull()][AllowEmptyString()][string]$Message = '',
        [AllowNull()][AllowEmptyString()][string]$NextAction = '',
        [AllowNull()][AllowEmptyString()][string]$Code = '',
        [Parameter(Mandatory)][System.Collections.IDictionary]$Layout
    )

    $mark = switch ($Kind) {
        'success' { [string]$Layout.successMark }
        'warning' { [string]$Layout.warningMark }
        'error' { [string]$Layout.errorMark }
        default { [string]$Layout.infoMark }
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    $titlePrefix = "$mark "
    $titlePrefixWidth = Get-DuoForgeProgressTextWidthInternal -Text $titlePrefix
    $titleWidth = [Math]::Max(1, [int]$Layout.lineWidth - $titlePrefixWidth)
    $titleLines = @(Split-DuoForgeDisplayTextInternal -Text $Title -Width $titleWidth)
    for ($titleIndex = 0; $titleIndex -lt $titleLines.Count; $titleIndex++) {
        $prefix = if ($titleIndex -eq 0) { $titlePrefix } else { ' ' * $titlePrefixWidth }
        $rows.Add((New-DuoForgeDisplayRowInternal -Text ($prefix + [string]$titleLines[$titleIndex]) -Role $Kind))
    }
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        foreach ($row in @(New-DuoForgeTextRowsInternal -Text $Message -Layout $Layout -Indent 2 -Role 'text' -PreserveParagraphs)) { $rows.Add($row) }
    }
    if (-not [string]::IsNullOrWhiteSpace($NextAction)) {
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '다음 행동' -Value $NextAction -Layout $Layout -Indent 2 -Role 'text')) { $rows.Add($row) }
    }
    if (-not [string]::IsNullOrWhiteSpace($Code)) {
        foreach ($row in @(New-DuoForgeFieldRowsInternal -Label '참조' -Value $Code -Layout $Layout -Indent 2 -Role 'meta')) { $rows.Add($row) }
    }
    return @($rows)
}

function Write-DuoForgeDisplayRowsInternal {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Rows,
        [System.Collections.IDictionary]$Layout
    )

    if ($null -eq $Layout) { $Layout = Get-DuoForgeDisplayLayoutInternal }
    foreach ($row in $Rows) {
        $text = if ($row -is [string]) { [string]$row } else { [string](Get-DuoForgeObjectValue -Object $row -Name 'text' -Default '') }
        $role = if ($row -is [string]) { 'text' } else { [string](Get-DuoForgeObjectValue -Object $row -Name 'role' -Default 'text') }
        $color = if ($row -is [string]) { '' } else { [string](Get-DuoForgeObjectValue -Object $row -Name 'color' -Default '') }
        $text = ConvertTo-DuoForgeDisplayFallbackTextInternal -Text $text -Layout $Layout
        if ((Get-DuoForgeProgressTextWidthInternal -Text $text) -gt [int]$Layout.lineWidth) {
            $text = Limit-DuoForgeProgressTextInternal -Text $text -Width ([int]$Layout.lineWidth)
        }
        $parameters = @{ Object = $text }
        if ([bool]$Layout.color) {
            if ([string]::IsNullOrWhiteSpace($color)) { $color = Get-DuoForgeDisplayRoleColorInternal -Role $role }
            if (-not [string]::IsNullOrWhiteSpace($color)) { $parameters.ForegroundColor = $color }
        }
        Write-Host @parameters
    }
}

function Add-DuoForgeTrailingSpacerRowInternal {
    [CmdletBinding()]
    param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Rows)

    $completedRows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($Rows)) { $completedRows.Add($row) }
    if ($completedRows.Count -eq 0) { return @() }

    $lastRow = $completedRows[$completedRows.Count - 1]
    $lastText = if ($lastRow -is [string]) { [string]$lastRow } else { [string](Get-DuoForgeObjectValue -Object $lastRow -Name 'text' -Default '') }
    if (-not [string]::IsNullOrWhiteSpace($lastText)) {
        $completedRows.Add((New-DuoForgeDisplayRowInternal -Text '' -Role 'spacer'))
    }
    return @($completedRows)
}

function Write-DuoForgeDisplaySpacerInternal {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Layout)

    if ($null -eq $Layout) { $Layout = Get-DuoForgeDisplayLayoutInternal }
    Write-DuoForgeDisplayRowsInternal -Rows @((New-DuoForgeDisplayRowInternal -Text '' -Role 'spacer')) -Layout $Layout
}

function Write-DuoForgeTextInternal {
    [CmdletBinding()]
    param(
        [Alias('Object')][AllowNull()][AllowEmptyString()][string]$Text,
        [ValidateSet('text', 'page', 'tag', 'section', 'field', 'list', 'selection', 'info', 'success', 'warning', 'error', 'meta')][string]$Role = 'text',
        [Alias('ForegroundColor')][AllowEmptyString()][string]$Color = '',
        [ValidateRange(0, 100)][int]$Indent = 0,
        [System.Collections.IDictionary]$Layout,
        [switch]$PreserveParagraphs
    )

    if ($null -eq $Layout) { $Layout = Get-DuoForgeDisplayLayoutInternal }
    $rows = @(New-DuoForgeTextRowsInternal -Text $Text -Layout $Layout -Indent $Indent -Role $Role -Color $Color -PreserveParagraphs:$PreserveParagraphs)
    Write-DuoForgeDisplayRowsInternal -Rows $rows -Layout $Layout
}
