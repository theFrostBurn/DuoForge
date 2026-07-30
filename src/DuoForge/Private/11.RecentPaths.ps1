function Get-DuoForgeRecentPathStorePath {
    [CmdletBinding()]
    param()
    return Join-Path (Get-DuoForgeLocalDataRoot) 'recent-paths.json'
}
function Get-DuoForgeRecentPaths {
    [CmdletBinding()]
    param([string]$Role)

    $storePath = Get-DuoForgeRecentPathStorePath
    if (-not (Test-Path -LiteralPath $storePath -PathType Leaf)) { return @() }
    try {
        $store = Read-DuoForgeJson -Path $storePath
        $items = @($store.items)
        if (-not [string]::IsNullOrWhiteSpace($Role)) {
            $items = @($items | Where-Object { $_.role -eq $Role })
        }
        return @($items | Sort-Object lastUsedAt -Descending)
    }
    catch {
        return @()
    }
}

function Add-DuoForgeRecentPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Role
    )

    $storePath = Get-DuoForgeRecentPathStorePath
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-DuoForgeRecentPaths)) {
        if (-not ([string]::Equals([string]$item.path, $Path, [StringComparison]::OrdinalIgnoreCase) -and [string]$item.role -eq $Role)) {
            $items.Add([ordered]@{ path = [string]$item.path; role = [string]$item.role; lastUsedAt = [string]$item.lastUsedAt })
        }
    }
    $items.Insert(0, [ordered]@{ path = $Path; role = $Role; lastUsedAt = Get-DuoForgeUtcNow })
    Write-DuoForgeJsonAtomic -Path $storePath -Value ([ordered]@{ schemaVersion = 1; items = @($items | Select-Object -First 20) })
}

function Clear-DuoForgeRecentPaths {
    [CmdletBinding()]
    param()
    Write-DuoForgeJsonAtomic -Path (Get-DuoForgeRecentPathStorePath) -Value ([ordered]@{ schemaVersion = 1; items = @() })
}

function Select-DuoForgeWindowsPath {
    [CmdletBinding()]
    param(
        [ValidateSet('File', 'Directory')]
        [string]$Type,

        [string]$Title = 'DuoForge 입력 선택',
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$ReturnTarget = 'parent',
        [scriptblock]$HostProbe,
        [scriptblock]$DialogInvoker
    )

    $interactive = if ($null -ne $HostProbe) { [bool](& $HostProbe) } else { [bool][Environment]::UserInteractive }
    $inputRedirected = if ($null -ne $HostProbe) { $false } else { [bool][Console]::IsInputRedirected }
    if (-not $interactive -or $inputRedirected) {
        $unavailable = New-DuoForgeInteractionResultInternal -Action unavailable -Source dialog -ReturnTarget $ReturnTarget
        $unavailable['reason'] = 'non-interactive'
        return $unavailable
    }

    try {
        if ($null -ne $DialogInvoker) {
            $dialogResult = & $DialogInvoker $Type $Title
            if ($dialogResult -is [System.Collections.IDictionary] -and -not [string]::IsNullOrWhiteSpace([string](Get-DuoForgeObjectValue -Object $dialogResult -Name 'action'))) { return $dialogResult }
            if ($dialogResult -is [System.Collections.IDictionary]) {
                $resultName = [string](Get-DuoForgeObjectValue -Object $dialogResult -Name 'result')
                $selectedPath = [string](Get-DuoForgeObjectValue -Object $dialogResult -Name 'path')
                if ($resultName -ieq 'OK' -and -not [string]::IsNullOrWhiteSpace($selectedPath)) { return New-DuoForgeInteractionResultInternal -Action submit -Value $selectedPath -Source dialog -ReturnTarget $ReturnTarget }
                return New-DuoForgeInteractionResultInternal -Action back -Source dialog -ReturnTarget $ReturnTarget
            }
            if ([string]::IsNullOrWhiteSpace([string]$dialogResult)) { return New-DuoForgeInteractionResultInternal -Action back -Source dialog -ReturnTarget $ReturnTarget }
            return New-DuoForgeInteractionResultInternal -Action submit -Value ([string]$dialogResult) -Source dialog -ReturnTarget $ReturnTarget
        }
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        if ($Type -eq 'File') {
            $dialog = [System.Windows.Forms.OpenFileDialog]::new()
            $dialog.Title = $Title
            $dialog.Filter = 'Markdown 문서 (*.md)|*.md|모든 파일 (*.*)|*.*'
            $dialog.Multiselect = $false
        }
        else {
            $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
            $dialog.Description = $Title
            $dialog.UseDescriptionForTitle = $true
            $dialog.ShowNewFolderButton = $true
        }

        try {
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $selectedPath = if ($Type -eq 'File') { $dialog.FileName } else { $dialog.SelectedPath }
                return New-DuoForgeInteractionResultInternal -Action submit -Value $selectedPath -Source dialog -ReturnTarget $ReturnTarget
            }
            return New-DuoForgeInteractionResultInternal -Action back -Source dialog -ReturnTarget $ReturnTarget
        }
        finally {
            $dialog.Dispose()
        }
    }
    catch {
        $unavailable = New-DuoForgeInteractionResultInternal -Action unavailable -Source dialog -ReturnTarget $ReturnTarget
        $unavailable['reason'] = 'launch-failed'
        return $unavailable
    }
}

function Read-DuoForgePathChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Role,
        [ValidateSet('File', 'Directory')][string]$Type = 'File',
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$CancelReturnTarget = 'home',
        [ValidateSet('parent', 'work-menu', 'home', 'shell')][string]$InterruptReturnTarget = $CancelReturnTarget,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker,
        [scriptblock]$PathPicker,
        [scriptblock]$RecentPathWriter
    )

    while ($true) {
        $choiceInteraction = Invoke-DuoForgeMenuInteractionInternal -Title $Prompt -ReturnTarget parent -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -InputReader $InputReader -MenuInvoker $MenuInvoker -Items @(
            [ordered]@{ value = '1'; label = 'Windows 선택창 열기'; shortcuts = @('1'); enabled = $true }
            [ordered]@{ value = '2'; label = '경로 붙여넣기 또는 파일 끌어놓기'; shortcuts = @('2'); enabled = $true }
            [ordered]@{ value = '3'; label = '최근 사용 경로'; shortcuts = @('3'); enabled = $true }
            [ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('B'); enabled = $true }
        )
        if ([string]$choiceInteraction.action -ne 'submit') { return $null }
        $choice = [string]$choiceInteraction.value

        $path = $null
        if ($choice -eq '1') {
            $pickerResult = if ($null -ne $PathPicker) { & $PathPicker $Type $Prompt } else { Select-DuoForgeWindowsPath -Type $Type -Title $Prompt }
            if ($pickerResult -isnot [System.Collections.IDictionary]) {
                throw (New-DuoForgeException -Code 'DF-INTERACTION-RESULT' -Message 'Windows 경로 선택기는 구조화 interaction 결과를 반환해야 합니다.')
            }
            if ([string]$pickerResult.action -eq 'back') { continue }
            if ([string]$pickerResult.action -ne 'submit') {
                $layout = Get-DuoForgeDisplayLayoutInternal
                Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind warning -Title 'Windows 선택창을 열 수 없습니다.' -Message '선택창 취소가 아니라 실행 환경에서 선택창을 사용할 수 없는 상태입니다.' -NextAction '경로를 직접 입력하거나 최근 경로를 선택해 주세요.' -Layout $layout) -Layout $layout
                Write-DuoForgeDisplaySpacerInternal -Layout $layout
                continue
            }
            $path = [string]$pickerResult.value
        }
        elseif ($choice -eq '2') {
            $pathInteraction = Read-DuoForgeFreeTextInteractionInternal -Prompt '경로' -ReturnTarget parent -InputReader $InputReader
            if ([string]$pathInteraction.action -ne 'submit') { return $null }
            $path = [string]$pathInteraction.value
        }
        elseif ($choice -eq '3') {
            $recent = @(Get-DuoForgeRecentPaths -Role $Role)
            if ($recent.Count -eq 0) {
                $layout = Get-DuoForgeDisplayLayoutInternal
                Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind info -Title '이 역할에 저장된 최근 경로가 없습니다.' -NextAction '선택창을 열거나 경로를 직접 입력해 주세요.' -Layout $layout) -Layout $layout
                Write-DuoForgeDisplaySpacerInternal -Layout $layout
                continue
            }
            $recentItems = [System.Collections.Generic.List[object]]::new()
            for ($index = 0; $index -lt $recent.Count; $index++) { $recentItems.Add([ordered]@{ value = [string]$index; label = [string]$recent[$index].path; shortcuts = @([string]($index + 1)); enabled = $true }) }
            $recentItems.Add([ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('B'); enabled = $true })
            $recentInteraction = Invoke-DuoForgeMenuInteractionInternal -Items @($recentItems) -Title '최근 사용 경로' -ReturnTarget parent -CancelReturnTarget $CancelReturnTarget -InterruptReturnTarget $InterruptReturnTarget -InputReader $InputReader -MenuInvoker $MenuInvoker
            if ([string]$recentInteraction.action -eq 'back') { continue }
            if ([string]$recentInteraction.action -ne 'submit') { return $null }
            $recentChoice = [string]$recentInteraction.value
            $path = [string]$recent[[int]$recentChoice].path
        }
        else {
            $layout = Get-DuoForgeDisplayLayoutInternal
            Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '현재 가능한 경로 입력 방식을 선택해 주세요.' -Layout $layout) -Layout $layout
            Write-DuoForgeDisplaySpacerInternal -Layout $layout
            continue
        }

        try {
            $resolved = Resolve-DuoForgePathInternal -Path $path -ExpectedType $Type
            if ($null -ne $RecentPathWriter) { & $RecentPathWriter $resolved $Role }
            else { Add-DuoForgeRecentPath -Path $resolved -Role $Role }
            return $resolved
        }
        catch {
            $layout = Get-DuoForgeDisplayLayoutInternal
            Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind error -Title '선택한 경로를 사용할 수 없습니다.' -Message ([string]$_.Exception.Message) -Layout $layout) -Layout $layout
            Write-DuoForgeDisplaySpacerInternal -Layout $layout
        }
    }
}
