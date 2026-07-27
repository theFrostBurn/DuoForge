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

        [scriptblock]$OnTick
    )

    $invocation = Resolve-DuoForgeCommandInvocation -CommandName $CommandName
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
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $PSBoundParameters.ContainsKey('StandardInput')
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)

    if ($PSBoundParameters.ContainsKey('EnvironmentAllowList')) {
        $startInfo.Environment.Clear()
        foreach ($name in @($EnvironmentAllowList | Select-Object -Unique)) {
            $value = [Environment]::GetEnvironmentVariable([string]$name, [EnvironmentVariableTarget]::Process)
            if ($null -ne $value) {
                $startInfo.Environment[[string]$name] = [string]$value
            }
        }
    }

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

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
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
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
            errorCategory = if ($completed) { $null } else { 'timeout' }
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
