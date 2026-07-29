function ConvertTo-DuoForgeDiagnosticTokenInternal {
    [CmdletBinding()]
    param(
        [AllowNull()]$Value,
        [string]$Fallback = '',
        [int]$MaximumLength = 120
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text) -or $text -notmatch '^[A-Za-z0-9._:/-]+$') { return $Fallback }
    if ($text.Length -gt $MaximumLength) { return $text.Substring(0, $MaximumLength) }
    return $text
}

function Get-DuoForgeDiagnosticPublicSummaryInternal {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Code)

    switch -Regex ($Code) {
        '^DF-STAGE-UNEXPECTED$' { return '단계 실행 중 예상하지 못한 오류가 발생했습니다.' }
        '^DF-STAGE-SCHEMA$' { return '공급자 응답이 단계 결과 계약을 충족하지 못했습니다.' }
        '^DF-STAGE-INTERRUPTED$' { return '이전에 중단된 단계를 안전하게 복구했습니다.' }
        '^DF-STAGE-RETRY-EXHAUSTED$' { return '중단된 단계가 재시도 상한에 도달했습니다.' }
        '^DF-FINAL-RENDERER$' { return '최종 산출물을 만드는 중 오류가 발생했습니다.' }
        '^DF-PROVIDER-TIMEOUT$' { return '공급자 응답 대기 시간이 초과되었습니다.' }
        '^DF-PROVIDER-QUOTA$' { return '공급자 구독 한도에 도달했습니다.' }
        '^DF-PROVIDER-RATE-LIMIT$' { return '공급자 요청 한도에 도달했습니다.' }
        '^DF-PROVIDER-AUTH$' { return '공급자 인증을 확인할 수 없습니다.' }
        '^DF-PROVIDER-PROCESS$' { return '공급자 프로세스 실행에 실패했습니다.' }
        '^DF-PROVIDER-' { return '공급자 호출 중 오류가 발생했습니다.' }
        '^DF-CLI-' { return '명령을 처리할 수 없습니다.' }
        '^DF-RUN-' { return '실행을 처리하는 중 오류가 발생했습니다.' }
        '^DF-' { return 'DuoForge 작업 중 오류가 발생했습니다.' }
        default { return 'DuoForge 작업 중 예상하지 못한 오류가 발생했습니다.' }
    }
}

function New-DuoForgeDiagnosticIdInternal {
    [CmdletBinding()]
    param()

    return 'diag-{0}-{1}' -f ([datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')), ([Guid]::NewGuid().ToString('N').Substring(0, 12))
}

function Get-DuoForgeDiagnosticBooleanInternal {
    [CmdletBinding()]
    param([AllowNull()]$Value, [AllowNull()]$Default = $null)

    if ($null -eq $Value) { return $Default }
    return [bool]$Value
}

function Get-DuoForgeDiagnosticIntegerInternal {
    [CmdletBinding()]
    param([AllowNull()]$Value, [AllowNull()]$Default = $null)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Default }
    try { return [int64]$Value } catch { return $Default }
}

function New-DuoForgeDiagnosticRecordInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DiagnosticId,
        [Parameter(Mandatory)][string]$Code,
        [string]$Category = 'unexpected',
        [string]$Phase = 'unknown',
        [ValidateSet('error', 'warning')][string]$Severity = 'error',
        [ValidateSet('run', 'local')][string]$Scope = 'run',
        [System.Collections.IDictionary]$Run,
        [System.Collections.IDictionary]$Step,
        [System.Collections.IDictionary]$Process,
        [System.Collections.IDictionary]$Recovery,
        [System.Collections.IDictionary]$ProviderVersions,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $safeCode = ConvertTo-DuoForgeDiagnosticTokenInternal -Value $Code -Fallback 'DF-UNEXPECTED'
    $exceptionType = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $Process -Name 'exceptionType' -Default '')
    $hresult = Get-DuoForgeDiagnosticIntegerInternal -Value (Get-DuoForgeObjectValue -Object $Process -Name 'hresult')
    if ($null -ne $ErrorRecord) {
        if ([string]::IsNullOrWhiteSpace($exceptionType)) { $exceptionType = ConvertTo-DuoForgeDiagnosticTokenInternal -Value $ErrorRecord.Exception.GetType().Name }
        if ($null -eq $hresult) { $hresult = Get-DuoForgeDiagnosticIntegerInternal -Value $ErrorRecord.Exception.HResult }
    }

    $providerVersionRecord = [ordered]@{
        codex = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $ProviderVersions -Name 'codex') -MaximumLength 80
        claude = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $ProviderVersions -Name 'claude') -MaximumLength 80
    }
    return [ordered]@{
        schemaVersion = 1
        at = Get-DuoForgeUtcNow
        diagnosticId = $DiagnosticId
        recordType = 'failure'
        scope = $Scope
        code = $safeCode
        category = ConvertTo-DuoForgeDiagnosticTokenInternal -Value $Category -Fallback 'unexpected'
        phase = ConvertTo-DuoForgeDiagnosticTokenInternal -Value $Phase -Fallback 'unknown'
        severity = $Severity
        publicSummary = Get-DuoForgeDiagnosticPublicSummaryInternal -Code $safeCode
        run = [ordered]@{
            runId = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $Run -Name 'runId')
            workflowVersion = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $Run -Name 'workflowVersion')
            status = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $Run -Name 'status')
            lastCompletedStage = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $Run -Name 'lastCompletedStage')
        }
        step = [ordered]@{
            stepKey = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $Step -Name 'stepKey')
            provider = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $Step -Name 'provider')
            stage = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $Step -Name 'stage')
            targetDocumentId = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $Step -Name 'targetDocumentId')
            round = Get-DuoForgeDiagnosticIntegerInternal -Value (Get-DuoForgeObjectValue -Object $Step -Name 'round')
            attempt = Get-DuoForgeDiagnosticIntegerInternal -Value (Get-DuoForgeObjectValue -Object $Step -Name 'attempt')
        }
        process = [ordered]@{
            started = Get-DuoForgeDiagnosticBooleanInternal -Value (Get-DuoForgeObjectValue -Object $Process -Name 'started')
            timedOut = Get-DuoForgeDiagnosticBooleanInternal -Value (Get-DuoForgeObjectValue -Object $Process -Name 'timedOut')
            exitCode = Get-DuoForgeDiagnosticIntegerInternal -Value (Get-DuoForgeObjectValue -Object $Process -Name 'exitCode')
            errorCategory = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $Process -Name 'errorCategory')
            exceptionType = $exceptionType
            hresult = $hresult
            stdoutBytes = Get-DuoForgeDiagnosticIntegerInternal -Value (Get-DuoForgeObjectValue -Object $Process -Name 'stdoutBytes')
            stderrBytes = Get-DuoForgeDiagnosticIntegerInternal -Value (Get-DuoForgeObjectValue -Object $Process -Name 'stderrBytes')
        }
        recovery = [ordered]@{
            retryable = Get-DuoForgeDiagnosticBooleanInternal -Value (Get-DuoForgeObjectValue -Object $Recovery -Name 'retryable') -Default $false
            retryMode = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $Recovery -Name 'retryMode')
            scheduled = Get-DuoForgeDiagnosticBooleanInternal -Value (Get-DuoForgeObjectValue -Object $Recovery -Name 'scheduled') -Default $false
        }
        environment = [ordered]@{
            duoforgeVersion = ConvertTo-DuoForgeDiagnosticTokenInternal -Value $script:ModuleVersion -MaximumLength 40
            powershellVersion = ConvertTo-DuoForgeDiagnosticTokenInternal -Value $PSVersionTable.PSVersion.ToString() -MaximumLength 40
            powershellEdition = ConvertTo-DuoForgeDiagnosticTokenInternal -Value $PSVersionTable.PSEdition -MaximumLength 40
            osDescription = ConvertTo-DuoForgeDiagnosticTokenInternal -Value ([System.Runtime.InteropServices.RuntimeInformation]::OSDescription -replace '\s+', '-') -MaximumLength 120
            processArchitecture = ConvertTo-DuoForgeDiagnosticTokenInternal -Value ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()) -MaximumLength 40
            providerVersions = $providerVersionRecord
        }
        stack = @()
    }
}

function Write-DuoForgeDiagnosticCoreInternal {
    [CmdletBinding()]
    param(
        [string]$RunDirectory,
        [Parameter(Mandatory)][string]$Code,
        [string]$Category = 'unexpected',
        [string]$Phase = 'unknown',
        [ValidateSet('error', 'warning')][string]$Severity = 'error',
        [ValidateSet('run', 'local')][string]$Scope = 'run',
        [System.Collections.IDictionary]$Run,
        [System.Collections.IDictionary]$Step,
        [System.Collections.IDictionary]$Process,
        [System.Collections.IDictionary]$Recovery,
        [System.Collections.IDictionary]$ProviderVersions,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$DiagnosticId
    )

    if ([string]::IsNullOrWhiteSpace($DiagnosticId)) { $DiagnosticId = New-DuoForgeDiagnosticIdInternal }
    $recordScope = if (-not [string]::IsNullOrWhiteSpace($RunDirectory) -and (Test-Path -LiteralPath $RunDirectory -PathType Container)) { 'run' } else { 'local' }
    $record = New-DuoForgeDiagnosticRecordInternal -DiagnosticId $DiagnosticId -Code $Code -Category $Category -Phase $Phase -Severity $Severity -Scope $recordScope -Run $Run -Step $Step -Process $Process -Recovery $Recovery -ProviderVersions $ProviderVersions -ErrorRecord $ErrorRecord
    $result = [ordered]@{
        diagnosticId = $DiagnosticId
        written = $false
        location = 'none'
        relativePath = ''
        diagnosticsPath = ''
        warningCode = ''
        record = $record
    }

    if ($recordScope -eq 'run') {
        $runPath = Join-Path ([System.IO.Path]::GetFullPath($RunDirectory)) 'diagnostics.jsonl'
        try {
            Add-DuoForgeJsonLine -Path $runPath -Value $record
            $result.written = $true
            $result.location = 'run'
            $result.relativePath = 'diagnostics.jsonl'
            $result.diagnosticsPath = $runPath
            return $result
        }
        catch { }
    }

    try {
        if ($record.scope -ne 'local') {
            $record = New-DuoForgeDiagnosticRecordInternal -DiagnosticId $DiagnosticId -Code $Code -Category $Category -Phase $Phase -Severity $Severity -Scope 'local' -Run $Run -Step $Step -Process $Process -Recovery $Recovery -ProviderVersions $ProviderVersions -ErrorRecord $ErrorRecord
            $result.record = $record
        }
        $relativePath = Join-Path 'diagnostics' (Join-Path $DiagnosticId 'diagnostics.jsonl')
        $localPath = Join-Path (Get-DuoForgeLocalDataRoot) $relativePath
        Add-DuoForgeJsonLine -Path $localPath -Value $record
        $result.written = $true
        $result.location = 'local'
        $result.relativePath = $relativePath
        $result.diagnosticsPath = [System.IO.Path]::GetFullPath($localPath)
        return $result
    }
    catch {
        $result.warningCode = 'DF-DIAGNOSTIC-WRITE'
        return $result
    }
}

function Write-DuoForgeDiagnosticInternal {
    [CmdletBinding()]
    param(
        [string]$RunDirectory,
        [Parameter(Mandatory)][string]$Code,
        [string]$Category = 'unexpected',
        [string]$Phase = 'unknown',
        [ValidateSet('error', 'warning')][string]$Severity = 'error',
        [ValidateSet('run', 'local')][string]$Scope = 'run',
        [System.Collections.IDictionary]$Run,
        [System.Collections.IDictionary]$Step,
        [System.Collections.IDictionary]$Process,
        [System.Collections.IDictionary]$Recovery,
        [System.Collections.IDictionary]$ProviderVersions,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$DiagnosticId
    )

    $parameters = [ordered]@{}
    foreach ($name in $PSBoundParameters.Keys) { $parameters[$name] = $PSBoundParameters[$name] }
    if ([string]::IsNullOrWhiteSpace($DiagnosticId)) {
        try { $DiagnosticId = New-DuoForgeDiagnosticIdInternal }
        catch { $DiagnosticId = 'diag-unavailable-' + [Guid]::NewGuid().ToString('N').Substring(0, 12) }
        $parameters['DiagnosticId'] = $DiagnosticId
    }
    try { return Write-DuoForgeDiagnosticCoreInternal @parameters }
    catch {
        return [ordered]@{
            diagnosticId = $DiagnosticId
            written = $false
            location = 'none'
            relativePath = ''
            diagnosticsPath = ''
            warningCode = 'DF-DIAGNOSTIC-WRITE'
            record = [ordered]@{ publicSummary = Get-DuoForgeDiagnosticPublicSummaryInternal -Code $Code }
        }
    }
}

function Get-DuoForgeDiagnosticCorrelationInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Diagnostic)

    return [ordered]@{
        diagnosticId = [string](Get-DuoForgeObjectValue -Object $Diagnostic -Name 'diagnosticId')
        diagnosticsLocation = [string](Get-DuoForgeObjectValue -Object $Diagnostic -Name 'location' -Default 'none')
        diagnosticsRelativePath = [string](Get-DuoForgeObjectValue -Object $Diagnostic -Name 'relativePath')
        diagnosticWarningCode = [string](Get-DuoForgeObjectValue -Object $Diagnostic -Name 'warningCode')
    }
}

function Resolve-DuoForgeDiagnosticsPathInternal {
    [CmdletBinding()]
    param(
        [string]$RunDirectory,
        [string]$Location,
        [string]$RelativePath,
        [string]$DiagnosticsPath
    )

    if (-not [string]::IsNullOrWhiteSpace($DiagnosticsPath)) { return $DiagnosticsPath }
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return '' }
    try {
        if ($Location -eq 'run' -and -not [string]::IsNullOrWhiteSpace($RunDirectory)) { return [System.IO.Path]::GetFullPath((Join-Path $RunDirectory $RelativePath)) }
        if ($Location -eq 'local') { return [System.IO.Path]::GetFullPath((Join-Path (Get-DuoForgeLocalDataRoot) $RelativePath)) }
    }
    catch { }
    return ''
}

function Add-DuoForgeDiagnosticMetadataToExceptionInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Exception]$Exception,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Diagnostic
    )

    try {
        $Exception.Data['DuoForgeDiagnosticId'] = [string]$Diagnostic.diagnosticId
        $Exception.Data['DuoForgeDiagnosticsLocation'] = [string]$Diagnostic.location
        $Exception.Data['DuoForgeDiagnosticsRelativePath'] = [string]$Diagnostic.relativePath
        $Exception.Data['DuoForgeDiagnosticsPath'] = [string]$Diagnostic.diagnosticsPath
        $Exception.Data['DuoForgeDiagnosticWarningCode'] = [string]$Diagnostic.warningCode
        $record = Get-DuoForgeObjectValue -Object $Diagnostic -Name 'record'
        $Exception.Data['DuoForgePublicSummary'] = [string](Get-DuoForgeObjectValue -Object $record -Name 'publicSummary' -Default (Get-DuoForgeDiagnosticPublicSummaryInternal -Code ([string]$Exception.Data['DuoForgeCode'])))
    }
    catch { }
}

function Write-DuoForgeDiagnosticReferenceInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Source,
        [string]$RunDirectory
    )

    $code = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $Source -Name 'code') -Fallback 'DF-UNEXPECTED'
    $diagnosticId = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $Source -Name 'diagnosticId')
    $location = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $Source -Name 'diagnosticsLocation')
    $relativePath = [string](Get-DuoForgeObjectValue -Object $Source -Name 'diagnosticsRelativePath')
    $diagnosticsPath = Resolve-DuoForgeDiagnosticsPathInternal -RunDirectory $RunDirectory -Location $location -RelativePath $relativePath -DiagnosticsPath ([string](Get-DuoForgeObjectValue -Object $Source -Name 'diagnosticsPath'))
    $warningCode = ConvertTo-DuoForgeDiagnosticTokenInternal -Value (Get-DuoForgeObjectValue -Object $Source -Name 'diagnosticWarningCode')
    Write-Host ("오류 코드: {0}" -f $code) -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($diagnosticId)) { Write-Host ("진단 ID: {0}" -f $diagnosticId) }
    if (-not [string]::IsNullOrWhiteSpace($diagnosticsPath)) { Write-Host ("진단 파일: {0}" -f $diagnosticsPath) }
    if ($warningCode -eq 'DF-DIAGNOSTIC-WRITE') { Write-Host '진단 기록 실패: DF-DIAGNOSTIC-WRITE' -ForegroundColor Yellow }
}

function Get-DuoForgeDiagnosticSourceFromExceptionInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Exception]$Exception)

    return [ordered]@{
        code = if ($Exception.Data.Contains('DuoForgeCode')) { [string]$Exception.Data['DuoForgeCode'] } else { 'DF-UNEXPECTED' }
        diagnosticId = if ($Exception.Data.Contains('DuoForgeDiagnosticId')) { [string]$Exception.Data['DuoForgeDiagnosticId'] } else { '' }
        diagnosticsLocation = if ($Exception.Data.Contains('DuoForgeDiagnosticsLocation')) { [string]$Exception.Data['DuoForgeDiagnosticsLocation'] } else { '' }
        diagnosticsRelativePath = if ($Exception.Data.Contains('DuoForgeDiagnosticsRelativePath')) { [string]$Exception.Data['DuoForgeDiagnosticsRelativePath'] } else { '' }
        diagnosticsPath = if ($Exception.Data.Contains('DuoForgeDiagnosticsPath')) { [string]$Exception.Data['DuoForgeDiagnosticsPath'] } else { '' }
        diagnosticWarningCode = if ($Exception.Data.Contains('DuoForgeDiagnosticWarningCode')) { [string]$Exception.Data['DuoForgeDiagnosticWarningCode'] } else { '' }
        publicSummary = if ($Exception.Data.Contains('DuoForgePublicSummary')) { [string]$Exception.Data['DuoForgePublicSummary'] } else { Get-DuoForgeDiagnosticPublicSummaryInternal -Code (if ($Exception.Data.Contains('DuoForgeCode')) { [string]$Exception.Data['DuoForgeCode'] } else { 'DF-UNEXPECTED' }) }
    }
}
