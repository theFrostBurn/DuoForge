function Get-DuoForgeLocalDataRoot {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:DUOFORGE_DATA_ROOT)) {
        return [System.IO.Path]::GetFullPath($env:DUOFORGE_DATA_ROOT)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return Join-Path $env:LOCALAPPDATA 'DuoForge'
    }

    return Join-Path $script:ProjectRoot '.duoforge'
}
function Read-DuoForgeConfigFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (New-DuoForgeException -Code 'DF-CONFIG-NOT-FOUND' -Message "설정 파일을 찾을 수 없습니다: $Path")
    }

    try {
        $content = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true))
        return ConvertTo-DuoForgeHashtable -InputObject ($content | ConvertFrom-Json -Depth 50)
    }
    catch {
        throw (New-DuoForgeException -Code 'DF-CONFIG-INVALID' -Message "설정 JSON을 읽을 수 없습니다: $Path ($($_.Exception.Message))")
    }
}

function Get-DuoForgeConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )

    $defaultsPath = Join-Path $script:ProjectRoot 'config\defaults.json'
    $config = Read-DuoForgeConfigFile -Path $defaultsPath
    $config['projectRoot'] = $script:ProjectRoot
    $config['resultsRoot'] = Join-Path $script:ProjectRoot 'results'
    $config['localDataRoot'] = Get-DuoForgeLocalDataRoot

    $effectiveConfigPath = $ConfigPath
    if ([string]::IsNullOrWhiteSpace($effectiveConfigPath)) {
        $candidate = Join-Path (Get-DuoForgeLocalDataRoot) 'config.json'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $effectiveConfigPath = $candidate
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($effectiveConfigPath)) {
        $override = Read-DuoForgeConfigFile -Path $effectiveConfigPath
        $config = Merge-DuoForgeHashtable -Base $config -Override $override
    }

    if ([int]$config.defaultRounds -lt 2 -or [int]$config.defaultRounds -gt 3) {
        throw (New-DuoForgeException -Code 'DF-CONFIG-ROUNDS' -Message 'defaultRounds는 2 또는 3이어야 합니다.')
    }
    if ([int]$config.maxRounds -ne 3) {
        throw (New-DuoForgeException -Code 'DF-CONFIG-MAX-ROUNDS' -Message 'v1의 maxRounds는 3이어야 합니다.')
    }

    return $config
}
