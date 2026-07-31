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
        [AllowNull()][AllowEmptyString()][string]$ExplicitAuthHome,
        [AllowNull()]$IsElevated
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
    if (-not [string]::IsNullOrWhiteSpace($authHomePath)) {
        $overrides[$authHomeVariable] = $authHomePath
    }
    if (-not $PSBoundParameters.ContainsKey('IsElevated')) {
        try {
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
            $IsElevated = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        catch { $IsElevated = $null }
    }
    $elevation = if ($null -eq $IsElevated) { 'UNKNOWN' } elseif ([bool]$IsElevated) { 'ADMIN' } else { 'STANDARD' }

    return [ordered]@{
        provider = $Provider
        invocation = Resolve-DuoForgeCommandInvocation -CommandName $Provider
        authHomeVariable = $authHomeVariable
        authHomePath = $authHomePath
        authHomeSource = if (-not [string]::IsNullOrWhiteSpace($ExplicitAuthHome)) { 'explicit' } elseif ($profileMismatch) { 'mismatch' } else { 'profile-default' }
        authContextStatus = if ($profileMismatch) { 'PROFILE_MISMATCH' } else { 'AVAILABLE' }
        profileMismatch = $profileMismatch
        hostElevation = $elevation
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
    if ($CommandName -eq 'codex' -and $extension -in @('.cmd', '.bat')) {
        $npmRoot = [System.IO.Path]::GetDirectoryName($source)
        $codexJavaScript = Join-Path $npmRoot 'node_modules\@openai\codex\bin\codex.js'
        $node = @(Get-Command node.exe -All -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq [System.Management.Automation.CommandTypes]::Application } | Select-Object -First 1)
        if ($node.Count -eq 1 -and (Test-Path -LiteralPath $codexJavaScript -PathType Leaf)) {
            $prefixArguments.Add($codexJavaScript)
            return [ordered]@{ fileName = [string]$node[0].Source; prefixArguments = @($prefixArguments); source = $source }
        }
    }
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

        [scriptblock]$OnTick,

        [ValidateRange(250, 10000)]
        [int]$TickIntervalMilliseconds = 1000
    )

    $process = $null
    $started = $false
    $tickCallbackFailures = 0
    try {
        $invocation = if ($null -ne $CommandInvocation) { $CommandInvocation } else { Resolve-DuoForgeCommandInvocation -CommandName $CommandName }
        if ($null -eq $invocation) {
            return [ordered]@{ started = $false; exitCode = $null; timedOut = $false; stdout = ''; stderr = ''; errorCategory = 'command-not-found'; exceptionType = ''; hresult = $null; stdoutBytes = 0L; stderrBytes = 0L }
        }

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = [string](Get-DuoForgeObjectValue -Object $invocation -Name 'fileName')
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

        foreach ($argument in @(Get-DuoForgeObjectValue -Object $invocation -Name 'prefixArguments' -Default @()) + @($Arguments)) {
            $startInfo.ArgumentList.Add([string]$argument)
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $started = $process.Start()
        if (-not $started) {
            return [ordered]@{ started = $false; exitCode = $null; timedOut = $false; stdout = ''; stderr = ''; errorCategory = 'start-failed'; exceptionType = ''; hresult = $null; stdoutBytes = 0L; stderrBytes = 0L }
        }

        $stdoutTask = if ($Interactive) { $null } else { $process.StandardOutput.ReadToEndAsync() }
        $stderrTask = if ($Interactive) { $null } else { $process.StandardError.ReadToEndAsync() }
        if ($startInfo.RedirectStandardInput) {
            $process.StandardInput.Write($StandardInput)
            $process.StandardInput.Close()
        }

        $waitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $completed = $false
        $lastTickIndex = -1
        while (-not $completed -and $waitStopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $remainingMilliseconds = [Math]::Max(1, [int](($TimeoutSeconds - $waitStopwatch.Elapsed.TotalSeconds) * 1000))
            $completed = $process.WaitForExit([Math]::Min(250, $remainingMilliseconds))
            if (-not $completed -and $null -ne $OnTick) {
                $tickIndex = [int][Math]::Floor($waitStopwatch.Elapsed.TotalMilliseconds / $TickIntervalMilliseconds)
                if ($tickIndex -ne $lastTickIndex) {
                    $lastTickIndex = $tickIndex
                    try { $null = & $OnTick $waitStopwatch.Elapsed }
                    catch {
                        $tickCallbackFailures++
                        Write-Verbose 'DuoForge 프로세스 진행 콜백 오류를 안전하게 격리했습니다.'
                    }
                }
            }
        }
        $waitStopwatch.Stop()
        if (-not $completed) {
            try { $process.Kill($true) } catch { }
            $process.WaitForExit()
        }

        $stdout = if ($Interactive) { '' } else { $stdoutTask.GetAwaiter().GetResult() }
        $stderr = if ($Interactive) { '' } else { $stderrTask.GetAwaiter().GetResult() }
        $exitCode = if ($completed) { $process.ExitCode } else { $null }
        return [ordered]@{
            started = $true
            exitCode = $exitCode
            timedOut = -not $completed
            stdout = $stdout
            stderr = $stderr
            errorCategory = if (-not $completed) { 'timeout' } elseif ([int]$exitCode -ne 0) { 'nonzero-exit' } else { $null }
            commandSource = [string](Get-DuoForgeObjectValue -Object $invocation -Name 'source')
            exceptionType = ''
            hresult = $null
            stdoutBytes = [int64][System.Text.UTF8Encoding]::new($false).GetByteCount($stdout)
            stderrBytes = [int64][System.Text.UTF8Encoding]::new($false).GetByteCount($stderr)
            tickCallbackFailures = $tickCallbackFailures
        }
    }
    catch {
        return [ordered]@{
            started = $started
            exitCode = $null
            timedOut = $false
            stdout = ''
            stderr = ''
            errorCategory = 'process-error'
            exceptionType = $_.Exception.GetType().Name
            hresult = [int64]$_.Exception.HResult
            stdoutBytes = 0L
            stderrBytes = 0L
            tickCallbackFailures = $tickCallbackFailures
        }
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Get-DuoForgeSafeProcessMetadataInternal {
    [CmdletBinding()]
    param([AllowNull()]$ProcessResult)

    return [ordered]@{
        started = Get-DuoForgeObjectValue -Object $ProcessResult -Name 'started'
        timedOut = Get-DuoForgeObjectValue -Object $ProcessResult -Name 'timedOut'
        exitCode = Get-DuoForgeObjectValue -Object $ProcessResult -Name 'exitCode'
        errorCategory = [string](Get-DuoForgeObjectValue -Object $ProcessResult -Name 'errorCategory')
        exceptionType = [string](Get-DuoForgeObjectValue -Object $ProcessResult -Name 'exceptionType')
        hresult = Get-DuoForgeObjectValue -Object $ProcessResult -Name 'hresult'
        stdoutBytes = Get-DuoForgeObjectValue -Object $ProcessResult -Name 'stdoutBytes'
        stderrBytes = Get-DuoForgeObjectValue -Object $ProcessResult -Name 'stderrBytes'
        tickCallbackFailures = [int](Get-DuoForgeObjectValue -Object $ProcessResult -Name 'tickCallbackFailures' -Default 0)
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
