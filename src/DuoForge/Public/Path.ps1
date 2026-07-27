function Resolve-DuoForgePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$BasePath = (Get-Location).Path,

        [ValidateSet('Any', 'File', 'Directory')]
        [string]$ExpectedType = 'Any',

        [switch]$AllowMissing
    )

    return Resolve-DuoForgePathInternal -Path $Path -BasePath $BasePath -ExpectedType $ExpectedType -AllowMissing:$AllowMissing
}
function Test-DuoForgePathRelationship {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PathA,

        [Parameter(Mandatory)]
        [string]$PathB
    )

    return Get-DuoForgePathRelationshipInternal -PathA $PathA -PathB $PathB
}

function Get-DuoForgeMarkdownInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [long]$MaximumFileBytes = 2097152,

        [switch]$Recurse
    )

    return Get-DuoForgeMarkdownInventoryInternal -Directory $Directory -MaximumFileBytes $MaximumFileBytes -Recurse:$Recurse
}
