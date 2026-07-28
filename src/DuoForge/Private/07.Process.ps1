function Get-DuoForgeProviderEnvironmentAllowList {
    [CmdletBinding()]
    param()

    return @(
        'SystemRoot', 'WINDIR', 'ComSpec', 'TEMP', 'TMP', 'PATH', 'PATHEXT',
        'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'LOCALAPPDATA', 'APPDATA',
        'PROGRAMDATA', 'ProgramFiles', 'ProgramFiles(x86)', 'PROCESSOR_ARCHITECTURE',
        'PSModulePath', 'CODEX_HOME', 'CLAUDE_CONFIG_DIR',
        'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'SSL_CERT_FILE', 'REQUESTS_CA_BUNDLE'
    )
}

function Resolve-DuoForgeProviderExecutionContextInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$Provider,
        [AllowNull()][AllowEmptyString()][string]$ProcessUserProfile,
        [AllowNull()][AllowEmptyString()][string]$DotNetUserProfile,
        [AllowNull()][AllowEmptyString()][string]$ExplicitAuthHome
    )

    if (-not $PSBoundParameters.ContainsKey('ProcessUserProfile')) {
        $ProcessUserProfile = [Environment]::GetEnvironmentVariable('USERPROFILE', [EnvironmentVariableTarget]::Process)
    }
    if (-not $PSBoundParameters.ContainsKey('DotNetUserProfile')) {
        $DotNetUserProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    }
    $authHomeVariable = if ($Provider -eq 'codex') { 'CODEX_HOME' } else { 'CLAUDE_CONFIG_DIR' }
    if (-not $PSBoundParameters.ContainsKey('ExplicitAuthHome')) {
        $ExplicitAuthHome = [Environment]::GetEnvironmentVariable($authHomeVariable, [EnvironmentVariableTarget]::Process)
    }

    $normalizePath = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
        try { return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }
        catch { return $Path.Trim().TrimEnd('\', '/') }
    }
    $processProfilePath = & $normalizePath $ProcessUserProfile
    $dotNetProfilePath = & $normalizePath $DotNetUserProfile
    $profileMismatch = -not [string]::IsNullOrWhiteSpace($processProfilePath) -and
        -not [string]::IsNullOrWhiteSpace($dotNetProfilePath) -and
        -not $processProfilePath.Equals($dotNetProfilePath, [StringComparison]::OrdinalIgnoreCase)

    $defaultProfilePath = if (-not [string]::IsNullOrWhiteSpace($processProfilePath)) { $processProfilePath } else { $dotNetProfilePath }
    $authHomePath = if (-not [string]::IsNullOrWhiteSpace($ExplicitAuthHome)) {
        & $normalizePath $ExplicitAuthHome
    }
    elseif (-not [string]::IsNullOrWhiteSpace($defaultProfilePath)) {
        Join-Path $defaultProfilePath $(if ($Provider -eq 'codex') { '.codex' } else { '.claude' })
    }
    else { '' }
    $overrides = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($ExplicitAuthHome)) {
        $overrides[$authHomeVariable] = $authHomePath
    }

    return [ordered]@{
        provider = $Provider
        invocation = Resolve-DuoForgeCommandInvocation -CommandName $Provider
        authHomeVariable = $authHomeVariable
        authHomePath = $authHomePath
        authHomeSource = if (-not [string]::IsNullOrWhiteSpace($ExplicitAuthHome)) { 'explicit' } elseif ($profileMismatch) { 'mismatch' } else { 'profile-default' }
        authContextStatus = if ($profileMismatch) { 'PROFILE_MISMATCH' } else { 'AVAILABLE' }
        profileMismatch = $profileMismatch
        liveRuntimeEligible = -not $profileMismatch
        environmentAllowList = @(Get-DuoForgeProviderEnvironmentAllowList)
        environmentOverrides = $overrides
    }
}

function Set-DuoForgeProcessEnvironmentInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Diagnostics.ProcessStartInfo]$StartInfo,
        [string[]]$EnvironmentAllowList,
        [System.Collections.IDictionary]$EnvironmentOverrides
    )

    if ($PSBoundParameters.ContainsKey('EnvironmentAllowList') -or $PSBoundParameters.ContainsKey('EnvironmentOverrides')) {
        $StartInfo.Environment.Clear()
        foreach ($name in @($EnvironmentAllowList | Select-Object -Unique)) {
            $value = [Environment]::GetEnvironmentVariable([string]$name, [EnvironmentVariableTarget]::Process)
            if ($null -ne $value) { $StartInfo.Environment[[string]$name] = [string]$value }
        }
        if ($null -ne $EnvironmentOverrides) {
            foreach ($entry in @($EnvironmentOverrides.GetEnumerator())) {
                if ($null -ne $entry.Value) { $StartInfo.Environment[[string]$entry.Key] = [string]$entry.Value }
            }
        }
    }
}

function Resolve-DuoForgeCommandInvocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CommandName
    )

    $commands = @(Get-Command $CommandName -All -ErrorAction SilentlyContinue)
    $command = @($commands | Where-Object { $_.CommandType -eq [System.Management.Automation.CommandTypes]::Application } | Select-Object -First 1)
    if ($command.Count -eq 0) {
        $command = @($commands | Select-Object -First 1)
    }
    if ($command.Count -gt 0) { $command = $command[0] }
    else { $command = $null }
    if ($null -eq $command) {
        return $null
    }

    $source = $command.Source
    $prefixArguments = [System.Collections.Generic.List[string]]::new()
    $extension = [System.IO.Path]::GetExtension($source)
    if ($extension -ieq '.ps1') {
        $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
        $prefixArguments.Add('-NoLogo')
        $prefixArguments.Add('-NoProfile')
        $prefixArguments.Add('-File')
        $prefixArguments.Add($source)
        return [ordered]@{ fileName = $pwsh; prefixArguments = @($prefixArguments); source = $source }
    }

    if ($extension -in @('.cmd', '.bat')) {
        $cmd = (Get-Command cmd.exe -ErrorAction Stop).Source
        $prefixArguments.Add('/d')
        $prefixArguments.Add('/s')
        $prefixArguments.Add('/c')
        $prefixArguments.Add($source)
        return [ordered]@{ fileName = $cmd; prefixArguments = @($prefixArguments); source = $source }
    }

    return [ordered]@{ fileName = $source; prefixArguments = @(); source = $source }
}

function Invoke-DuoForgeProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CommandName,

        [string[]]$Arguments = @(),

        [string]$WorkingDirectory = $script:ProjectRoot,

        [int]$TimeoutSeconds = 20,

        [string]$StandardInput,

        [string[]]$EnvironmentAllowList,

        [System.Collections.IDictionary]$EnvironmentOverrides,

        [System.Collections.IDictionary]$CommandInvocation,

        [switch]$Interactive,

        [scriptblock]$OnTick
    )

    $invocation = if ($null -ne $CommandInvocation) { $CommandInvocation } else { Resolve-DuoForgeCommandInvocation -CommandName $CommandName }
    if ($null -eq $invocation) {
        return [ordered]@{
            started = $false
            exitCode = $null
            timedOut = $false
            stdout = ''
            stderr = ''
            errorCategory = 'command-not-found'
        }
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $invocation.fileName
    $startInfo.WorkingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = -not $Interactive
    $startInfo.RedirectStandardOutput = -not $Interactive
    $startInfo.RedirectStandardError = -not $Interactive
    $startInfo.RedirectStandardInput = -not $Interactive -and $PSBoundParameters.ContainsKey('StandardInput')
    if (-not $Interactive) {
        $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    }
    $environmentParameters = @{ StartInfo = $startInfo }
    if ($PSBoundParameters.ContainsKey('EnvironmentAllowList')) { $environmentParameters['EnvironmentAllowList'] = $EnvironmentAllowList }
    if ($PSBoundParameters.ContainsKey('EnvironmentOverrides')) { $environmentParameters['EnvironmentOverrides'] = $EnvironmentOverrides }
    Set-DuoForgeProcessEnvironmentInternal @environmentParameters

    foreach ($argument in @($invocation.prefixArguments) + @($Arguments)) {
        $startInfo.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        $started = $process.Start()
        if (-not $started) {
            return [ordered]@{ started = $false; exitCode = $null; timedOut = $false; stdout = ''; stderr = ''; errorCategory = 'start-failed' }
        }

        $stdoutTask = if ($Interactive) { $null } else { $process.StandardOutput.ReadToEndAsync() }
        $stderrTask = if ($Interactive) { $null } else { $process.StandardError.ReadToEndAsync() }
        if ($startInfo.RedirectStandardInput) {
            $process.StandardInput.Write($StandardInput)
            $process.StandardInput.Close()
        }

        $waitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $completed = $false
        $lastTickSecond = -1
        while (-not $completed -and $waitStopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $remainingMilliseconds = [Math]::Max(1, [int](($TimeoutSeconds - $waitStopwatch.Elapsed.TotalSeconds) * 1000))
            $completed = $process.WaitForExit([Math]::Min(250, $remainingMilliseconds))
            if (-not $completed -and $null -ne $OnTick) {
                $tickSecond = [int][Math]::Floor($waitStopwatch.Elapsed.TotalSeconds)
                if ($tickSecond -ne $lastTickSecond) {
                    $lastTickSecond = $tickSecond
                    try { $null = & $OnTick $waitStopwatch.Elapsed }
                    catch { Write-Verbose ("DuoForge 프로세스 진행 콜백 오류를 무시했습니다: {0}" -f $_.Exception.Message) }
                }
            }
        }
        $waitStopwatch.Stop()
        if (-not $completed) {
            try { $process.Kill($true) } catch { }
            $process.WaitForExit()
        }

        return [ordered]@{
            started = $true
            exitCode = if ($completed) { $process.ExitCode } else { $null }
            timedOut = -not $completed
            stdout = if ($Interactive) { '' } else { $stdoutTask.GetAwaiter().GetResult() }
            stderr = if ($Interactive) { '' } else { $stderrTask.GetAwaiter().GetResult() }
            errorCategory = if ($completed) { $null } else { 'timeout' }
            commandSource = [string]$invocation.source
        }
    }
    catch {
        return [ordered]@{
            started = $false
            exitCode = $null
            timedOut = $false
            stdout = ''
            stderr = ''
            errorCategory = 'process-error'
        }
    }
    finally {
        $process.Dispose()
    }
}

function Test-DuoForgeHelpFlags {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HelpText,

        [Parameter(Mandatory)]
        [string[]]$RequiredFlags
    )

    $result = [ordered]@{}
    foreach ($flag in $RequiredFlags) {
        $result[$flag] = $HelpText.Contains($flag, [StringComparison]::Ordinal)
    }
    return $result
}
