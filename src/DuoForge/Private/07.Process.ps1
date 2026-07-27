function Resolve-DuoForgeCommandInvocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CommandName
    )

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
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

        [string[]]$EnvironmentAllowList
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
        $environmentSnapshot = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process)
        $startInfo.Environment.Clear()
        foreach ($name in @($EnvironmentAllowList | Select-Object -Unique)) {
            if ($environmentSnapshot.Contains($name)) {
                $startInfo.Environment[[string]$name] = [string]$environmentSnapshot[$name]
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

        $completed = $process.WaitForExit($TimeoutSeconds * 1000)
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
