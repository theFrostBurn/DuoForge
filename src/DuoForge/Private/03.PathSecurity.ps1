function Get-DuoForgeComparablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if (-not [string]::Equals($fullPath, $root, [StringComparison]::OrdinalIgnoreCase)) {
        $fullPath = $fullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    }
    return $fullPath
}

function Resolve-DuoForgePathInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$BasePath = (Get-Location).Path,

        [ValidateSet('Any', 'File', 'Directory')]
        [string]$ExpectedType = 'Any',

        [switch]$AllowMissing
    )

    $candidate = $Path.Trim()
    if ($candidate.Length -ge 2) {
        $first = $candidate[0]
        $last = $candidate[$candidate.Length - 1]
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $candidate = $candidate.Substring(1, $candidate.Length - 2).Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        throw (New-DuoForgeException -Code 'DF-PATH-EMPTY' -Message '경로가 비어 있습니다.')
    }

    try {
        if ([System.IO.Path]::IsPathFullyQualified($candidate)) {
            $fullPath = [System.IO.Path]::GetFullPath($candidate)
        }
        else {
            $fullPath = [System.IO.Path]::GetFullPath($candidate, [System.IO.Path]::GetFullPath($BasePath))
        }
    }
    catch {
        throw (New-DuoForgeException -Code 'DF-PATH-INVALID' -Message "올바르지 않은 Windows 경로입니다: $Path")
    }

    $exists = Test-Path -LiteralPath $fullPath
    if (-not $exists -and -not $AllowMissing) {
        throw (New-DuoForgeException -Code 'DF-PATH-NOT-FOUND' -Message "경로를 찾을 수 없습니다: $fullPath")
    }

    if ($exists) {
        $item = Get-Item -LiteralPath $fullPath -Force
        if ($ExpectedType -eq 'File' -and $item.PSIsContainer) {
            throw (New-DuoForgeException -Code 'DF-PATH-EXPECTED-FILE' -Message "파일을 선택해야 합니다: $fullPath")
        }
        if ($ExpectedType -eq 'Directory' -and -not $item.PSIsContainer) {
            throw (New-DuoForgeException -Code 'DF-PATH-EXPECTED-DIRECTORY' -Message "폴더를 선택해야 합니다: $fullPath")
        }
    }

    return Get-DuoForgeComparablePath -Path $fullPath
}

function Get-DuoForgePathRelationshipInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PathA,

        [Parameter(Mandatory)]
        [string]$PathB
    )

    $a = Get-DuoForgeComparablePath -Path $PathA
    $b = Get-DuoForgeComparablePath -Path $PathB
    if ([string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)) {
        return 'Same'
    }

    $separator = [System.IO.Path]::DirectorySeparatorChar
    if ($b.StartsWith($a + $separator, [StringComparison]::OrdinalIgnoreCase)) {
        return 'AContainsB'
    }
    if ($a.StartsWith($b + $separator, [StringComparison]::OrdinalIgnoreCase)) {
        return 'BContainsA'
    }
    return 'Disjoint'
}

function Get-DuoForgeReparsePointsInPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = Get-DuoForgeComparablePath -Path $Path
    $current = $fullPath
    $found = [System.Collections.Generic.List[string]]::new()

    while (-not [string]::IsNullOrWhiteSpace($current) -and (Test-Path -LiteralPath $current)) {
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $found.Add($item.FullName)
        }

        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }

    return @($found)
}

function Assert-DuoForgeDisjointPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PathA,

        [Parameter(Mandatory)]
        [string]$PathB,

        [string]$Code = 'DF-PATH-OVERLAP',

        [string]$LabelA = '첫 번째 경로',

        [string]$LabelB = '두 번째 경로'
    )

    $relationship = Get-DuoForgePathRelationshipInternal -PathA $PathA -PathB $PathB
    if ($relationship -ne 'Disjoint') {
        throw (New-DuoForgeException -Code $Code -Message "${LabelA}와 ${LabelB}가 같거나 서로 중첩되어 있습니다. ($PathA, $PathB)")
    }
}

function Assert-DuoForgeOutputBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResultsRoot,

        [Parameter(Mandatory)]
        [string[]]$InputBoundaries
    )

    foreach ($boundary in $InputBoundaries) {
        $relationship = Get-DuoForgePathRelationshipInternal -PathA $boundary -PathB $ResultsRoot
        if ($relationship -in @('Same', 'AContainsB')) {
            throw (New-DuoForgeException -Code 'DF-PATH-OUTPUT-IN-INPUT' -Message "결과 루트는 입력 폴더와 같거나 그 내부일 수 없습니다: $ResultsRoot")
        }
    }
}
