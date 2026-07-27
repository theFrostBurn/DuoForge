function Get-DuoForgeUtcNow {
    [CmdletBinding()]
    param()

    return [DateTimeOffset]::UtcNow.ToString('o')
}

function New-DuoForgeException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $exception = [System.InvalidOperationException]::new("[$Code] $Message")
    $exception.Data['DuoForgeCode'] = $Code
    return $exception
}

function ConvertTo-DuoForgeHashtable {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        $InputObject
    )

    process {
        if ($null -eq $InputObject) {
            return $null
        }

        if ($InputObject -is [string] -or $InputObject.GetType().IsValueType) {
            return $InputObject
        }

        if ($InputObject -is [System.Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($key in $InputObject.Keys) {
                $child = $InputObject[$key]
                if ($child -is [System.Collections.IEnumerable] -and $child -isnot [string] -and $child -isnot [System.Collections.IDictionary]) {
                    $items = [System.Collections.Generic.List[object]]::new()
                    foreach ($item in $child) {
                        $items.Add((ConvertTo-DuoForgeHashtable -InputObject $item))
                    }
                    $result[[string]$key] = [object[]]$items.ToArray()
                }
                else {
                    $result[[string]$key] = ConvertTo-DuoForgeHashtable -InputObject ($child)
                }
            }
            return $result
        }

        if ($InputObject -is [pscustomobject]) {
            $result = [ordered]@{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $child = $property.Value
                if ($child -is [System.Collections.IEnumerable] -and $child -isnot [string] -and $child -isnot [System.Collections.IDictionary]) {
                    $items = [System.Collections.Generic.List[object]]::new()
                    foreach ($item in $child) {
                        $items.Add((ConvertTo-DuoForgeHashtable -InputObject $item))
                    }
                    $result[$property.Name] = [object[]]$items.ToArray()
                }
                else {
                    $result[$property.Name] = ConvertTo-DuoForgeHashtable -InputObject ($child)
                }
            }
            return $result
        }

        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $items = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $InputObject) {
                $items.Add((ConvertTo-DuoForgeHashtable -InputObject $item))
            }
            Write-Output -NoEnumerate ([object[]]$items.ToArray())
            return
        }

        return $InputObject
    }
}

function Merge-DuoForgeHashtable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Base,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Override
    )

    $merged = ConvertTo-DuoForgeHashtable -InputObject $Base
    foreach ($key in $Override.Keys) {
        if (
            $merged.Contains($key) -and
            $merged[$key] -is [System.Collections.IDictionary] -and
            $Override[$key] -is [System.Collections.IDictionary]
        ) {
            $merged[$key] = Merge-DuoForgeHashtable -Base $merged[$key] -Override $Override[$key]
        }
        else {
            $merged[$key] = ConvertTo-DuoForgeHashtable -InputObject $Override[$key]
        }
    }

    return $merged
}

function Test-DuoForgeInteractiveHost {
    [CmdletBinding()]
    param()

    try {
        return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    }
    catch {
        return $false
    }
}

function Format-DuoForgeByteSize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [long]$Bytes
    )

    if ($Bytes -ge 1GB) { return ('{0:N2} GiB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MiB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KiB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}
