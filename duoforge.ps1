#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CliArguments
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'src\DuoForge\DuoForge.psd1'
Import-Module $modulePath -Force

try {
    Invoke-DuoForgeCli -Arguments $CliArguments
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
