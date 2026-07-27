function ConvertFrom-DuoForgeCliArguments {
    [CmdletBinding()]
    param([string[]]$Arguments = @())

    $positionals = [System.Collections.Generic.List[string]]::new()
    $options = [ordered]@{}
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $token = [string]$Arguments[$index]
        if ($token.StartsWith('--', [StringComparison]::Ordinal)) {
            $nameValue = $token.Substring(2).Split('=', 2)
            $name = $nameValue[0].ToLowerInvariant()
            if ($nameValue.Count -eq 2) {
                $options[$name] = $nameValue[1]
            }
            elseif ($index + 1 -lt $Arguments.Count -and -not ([string]$Arguments[$index + 1]).StartsWith('--', [StringComparison]::Ordinal)) {
                $index++
                $options[$name] = [string]$Arguments[$index]
            }
            else {
                $options[$name] = $true
            }
        }
        else {
            $positionals.Add($token)
        }
    }
    return [ordered]@{ positionals = @($positionals); options = $options }
}
function Get-DuoForgeCliOption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parsed,
        [Parameter(Mandatory)][string]$Name,
        $Default
    )
    if ($Parsed.options.Contains($Name)) { return $Parsed.options[$Name] }
    return $Default
}

function ConvertTo-DuoForgeIntOption {
    [CmdletBinding()]
    param(
        $Value,
        [Parameter(Mandatory)][string]$Name,
        [int]$Default
    )
    if ($null -eq $Value) { return $Default }
    $number = 0
    if (-not [int]::TryParse([string]$Value, [ref]$number)) {
        throw (New-DuoForgeException -Code 'DF-CLI-OPTION' -Message "--$Name 값은 정수여야 합니다.")
    }
    return $number
}
