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
        [ValidateSet('File', 'Directory')][string]$Type = 'File'
    )

    while ($true) {
        Write-Host ''
        Write-Host $Prompt
        Write-Host '[1] Windows 선택창 열기'
        Write-Host '[2] 경로 붙여넣기 또는 파일 끌어놓기'
        Write-Host '[3] 최근 사용 경로'
        Write-Host '[B] 이전으로'
        $choice = (Read-Host '선택').Trim()
        if ($choice -ieq 'B') { return $null }

        $path = $null
        if ($choice -eq '1') {
            $path = Select-DuoForgeWindowsPath -Type $Type -Title $Prompt
            if ([string]::IsNullOrWhiteSpace($path)) {
                Write-Host '선택창을 취소했거나 열 수 없습니다. 다른 방식을 선택해 주세요.' -ForegroundColor Yellow
                continue
            }
        }
        elseif ($choice -eq '2') {
            $path = Read-Host '경로'
        }
        elseif ($choice -eq '3') {
            $recent = @(Get-DuoForgeRecentPaths -Role $Role)
            if ($recent.Count -eq 0) {
                Write-Host '최근 경로가 없습니다.' -ForegroundColor Yellow
                continue
            }
            for ($index = 0; $index -lt $recent.Count; $index++) {
                Write-Host ('[{0}] {1}' -f ($index + 1), $recent[$index].path)
            }
            $recentChoice = Read-Host '번호'
            $selectedIndex = 0
            if (-not [int]::TryParse($recentChoice, [ref]$selectedIndex) -or $selectedIndex -lt 1 -or $selectedIndex -gt $recent.Count) {
                Write-Host '올바른 번호를 선택해 주세요.' -ForegroundColor Yellow
                continue
            }
            $path = [string]$recent[$selectedIndex - 1].path
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
