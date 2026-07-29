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
    $code = if ($_.Exception.Data.Contains('DuoForgeCode')) { [string]$_.Exception.Data['DuoForgeCode'] } else { 'DF-UNEXPECTED' }
    $summary = if ($_.Exception.Data.Contains('DuoForgePublicSummary')) { [string]$_.Exception.Data['DuoForgePublicSummary'] } else { 'DuoForge 작업 중 오류가 발생했습니다.' }
    Write-Error -Message ("[{0}] {1}" -f $code, $summary) -ErrorAction Continue
    if ($_.Exception.Data.Contains('DuoForgeDiagnosticId') -and -not [string]::IsNullOrWhiteSpace([string]$_.Exception.Data['DuoForgeDiagnosticId'])) {
        Write-Host ("진단 ID: {0}" -f [string]$_.Exception.Data['DuoForgeDiagnosticId'])
    }
    if ($_.Exception.Data.Contains('DuoForgeDiagnosticsPath') -and -not [string]::IsNullOrWhiteSpace([string]$_.Exception.Data['DuoForgeDiagnosticsPath'])) {
        Write-Host ("진단 파일: {0}" -f [string]$_.Exception.Data['DuoForgeDiagnosticsPath'])
    }
    if ($_.Exception.Data.Contains('DuoForgeDiagnosticWarningCode') -and [string]$_.Exception.Data['DuoForgeDiagnosticWarningCode'] -eq 'DF-DIAGNOSTIC-WRITE') {
        Write-Host '진단 기록 실패: DF-DIAGNOSTIC-WRITE'
    }
    exit 1
}
