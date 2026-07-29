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

        [string]$Title = 'DuoForge 입력 선택'
    )

    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        return $null
    }

    try {
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
                if ($Type -eq 'File') { return $dialog.FileName }
                return $dialog.SelectedPath
            }
            return $null
        }
        finally {
            $dialog.Dispose()
        }
    }
    catch {
        return $null
    }
}

function Read-DuoForgePathChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Role,
        [ValidateSet('File', 'Directory')][string]$Type = 'File',
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker,
        [scriptblock]$PathPicker
    )

    while ($true) {
        $choice = Invoke-DuoForgeMenuInternal -Title $Prompt -EscapeValue 'B' -InputReader $InputReader -MenuInvoker $MenuInvoker -Items @(
            [ordered]@{ value = '1'; label = 'Windows 선택창 열기'; shortcuts = @('1'); enabled = $true }
            [ordered]@{ value = '2'; label = '경로 붙여넣기 또는 파일 끌어놓기'; shortcuts = @('2'); enabled = $true }
            [ordered]@{ value = '3'; label = '최근 사용 경로'; shortcuts = @('3'); enabled = $true }
            [ordered]@{ value = 'B'; label = '이전으로'; shortcuts = @('B'); enabled = $true }
        )
        if ($choice -ieq 'B') { return $null }

        $path = $null
        if ($choice -eq '1') {
            $path = if ($null -ne $PathPicker) { & $PathPicker $Type $Prompt } else { Select-DuoForgeWindowsPath -Type $Type -Title $Prompt }
            if ([string]::IsNullOrWhiteSpace($path)) {
                Write-Host '선택창을 취소했거나 열 수 없습니다. 다른 방식을 선택해 주세요.' -ForegroundColor Yellow
                continue
            }
        }
        elseif ($choice -eq '2') {
            $path = if ($null -ne $InputReader) { [string](& $InputReader '경로') } else { [string](Read-Host '경로') }
        }
        elseif ($choice -eq '3') {
            $recent = @(Get-DuoForgeRecentPaths -Role $Role)
            if ($recent.Count -eq 0) {
                Write-Host '최근 경로가 없습니다.' -ForegroundColor Yellow
                continue
            }
            $recentItems = [System.Collections.Generic.List[object]]::new()
            for ($index = 0; $index -lt $recent.Count; $index++) { $recentItems.Add([ordered]@{ value = [string]$index; label = [string]$recent[$index].path; shortcuts = @([string]($index + 1)); enabled = $true }) }
            $recentItems.Add([ordered]@{ value = 'B'; label = '이전으로'; shortcuts = @('B'); enabled = $true })
            $recentChoice = Invoke-DuoForgeMenuInternal -Items @($recentItems) -Title '최근 사용 경로' -EscapeValue 'B' -InputReader $InputReader -MenuInvoker $MenuInvoker
            if ($recentChoice -ieq 'B') { continue }
            $path = [string]$recent[[int]$recentChoice].path
        }
        else {
            Write-Host '올바른 항목을 선택해 주세요.' -ForegroundColor Yellow
            continue
        }

        try {
            $resolved = Resolve-DuoForgePathInternal -Path $path -ExpectedType $Type
            Add-DuoForgeRecentPath -Path $resolved -Role $Role
            return $resolved
        }
        catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }
    }
}
