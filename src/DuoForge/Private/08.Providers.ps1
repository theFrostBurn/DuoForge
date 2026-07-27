function Get-DuoForgeApiCredentialConflicts {
    [CmdletBinding()]
    param()

    $credentialNames = @(
        'OPENAI_API_KEY',
        'ANTHROPIC_API_KEY',
        'ANTHROPIC_AUTH_TOKEN',
        'CLAUDE_CODE_USE_BEDROCK',
        'CLAUDE_CODE_USE_VERTEX',
        'CLAUDE_CODE_USE_FOUNDRY'
    )
    $environmentNames = @([Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).Keys | ForEach-Object { [string]$_ })
    return @($credentialNames | Where-Object { $environmentNames -contains $_ })
}

function ConvertFrom-DuoForgeCodexAuthStatusInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [int]$ExitCode = 0
    )

    $subscription = $ExitCode -eq 0 -and $Text -match '(?i)logged\s+in\s+using\s+chatgpt'
    $api = $ExitCode -eq 0 -and $Text -match '(?i)(api[- ]?key|openai_api_key)'
    return [ordered]@{
        authenticated = $ExitCode -eq 0
        subscription = $subscription -and -not $api
        authType = if ($subscription -and -not $api) { 'chatgpt' } elseif ($api) { 'api' } else { 'unknown' }
        exitCode = $ExitCode
    }
}

function ConvertFrom-DuoForgeClaudeAuthStatusInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [int]$ExitCode = 0
    )

    $loggedIn = $false
    $authMethod = 'unknown'
    $apiProvider = 'unknown'
    $subscriptionType = $null
    if ($ExitCode -eq 0) {
        try {
            $status = $Text | ConvertFrom-Json -Depth 20
            $loggedIn = [bool]$status.loggedIn
            if (-not [string]::IsNullOrWhiteSpace([string]$status.authMethod)) { $authMethod = [string]$status.authMethod }
            if (-not [string]::IsNullOrWhiteSpace([string]$status.apiProvider)) { $apiProvider = [string]$status.apiProvider }
            if (-not [string]::IsNullOrWhiteSpace([string]$status.subscriptionType)) { $subscriptionType = [string]$status.subscriptionType }
        }
        catch {
            $loggedIn = $false
        }
    }

    $subscription = $loggedIn -and $authMethod -eq 'claude.ai' -and $apiProvider -eq 'firstParty'
    return [ordered]@{
        authenticated = $loggedIn
        subscription = $subscription
        authType = if ($subscription) { 'claude.ai' } elseif ($loggedIn) { 'non-subscription-or-unknown' } else { 'unknown' }
        subscriptionType = if ($subscription) { $subscriptionType } else { $null }
        exitCode = $ExitCode
    }
}

function Get-DuoForgeProviderDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('codex', 'claude')]
        [string]$Provider
    )

    $command = Resolve-DuoForgeCommandInvocation -CommandName $Provider
    if ($null -eq $command) {
        return [ordered]@{
            provider = $Provider
            installed = $false
            version = $null
            authenticated = $false
            subscription = $false
            authType = 'unknown'
            requiredFlags = [ordered]@{}
            documentProfileSupported = $false
            projectAuditProfileSupported = $false
            status = 'MISSING'
        }
    }

    $versionResult = Invoke-DuoForgeProcess -CommandName $Provider -Arguments @('--version')
    $versionText = (($versionResult.stdout + ' ' + $versionResult.stderr).Trim() -split "`r?`n")[0]

    if ($Provider -eq 'codex') {
        $helpResult = Invoke-DuoForgeProcess -CommandName 'codex' -Arguments @('exec', '--help')
        $globalHelpResult = Invoke-DuoForgeProcess -CommandName 'codex' -Arguments @('--help')
        $helpText = $helpResult.stdout + [Environment]::NewLine + $helpResult.stderr + [Environment]::NewLine + $globalHelpResult.stdout + [Environment]::NewLine + $globalHelpResult.stderr
        $required = @('--ask-for-approval', '--config', '--model', '--sandbox', '--skip-git-repo-check', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--output-schema', '--json', '--output-last-message')
        $flagStatus = Test-DuoForgeHelpFlags -HelpText $helpText -RequiredFlags $required
        $authResult = Invoke-DuoForgeProcess -CommandName 'codex' -Arguments @('login', 'status')
        $auth = ConvertFrom-DuoForgeCodexAuthStatusInternal -Text ($authResult.stdout + [Environment]::NewLine + $authResult.stderr) -ExitCode $(if ($null -eq $authResult.exitCode) { 1 } else { $authResult.exitCode })
        $documentSupported = @($flagStatus.Values | Where-Object { -not $_ }).Count -eq 0
        return [ordered]@{
            provider = 'codex'
            installed = $true
            version = $versionText
            authenticated = $auth.authenticated
            subscription = $auth.subscription
            authType = $auth.authType
            authStatusExitCode = $auth.exitCode
            requiredFlags = $flagStatus
            ignoreRulesAvailable = [bool]$flagStatus['--ignore-rules']
            zeroToolSurfaceVerified = $false
            documentProfileSupported = $documentSupported
            projectAuditProfileSupported = $false
            status = if ($auth.subscription -and $documentSupported) { 'READY_DOCUMENTS' } else { 'BLOCKED' }
        }
    }

    $helpResult = Invoke-DuoForgeProcess -CommandName 'claude' -Arguments @('--help')
    $helpText = $helpResult.stdout + [Environment]::NewLine + $helpResult.stderr
    $required = @('--model', '--effort', '--safe-mode', '--strict-mcp-config', '--tools', '--disallowedTools', '--no-chrome', '--no-session-persistence', '--permission-mode', '--output-format', '--json-schema')
    $flagStatus = Test-DuoForgeHelpFlags -HelpText $helpText -RequiredFlags $required
    $authResult = Invoke-DuoForgeProcess -CommandName 'claude' -Arguments @('auth', 'status')
    $auth = ConvertFrom-DuoForgeClaudeAuthStatusInternal -Text $authResult.stdout -ExitCode $(if ($null -eq $authResult.exitCode) { 1 } else { $authResult.exitCode })
    $documentSupported = @($flagStatus.Values | Where-Object { -not $_ }).Count -eq 0
    return [ordered]@{
        provider = 'claude'
        installed = $true
        version = $versionText
        authenticated = $auth.authenticated
        subscription = $auth.subscription
        authType = $auth.authType
        subscriptionType = $auth.subscriptionType
        authStatusExitCode = $auth.exitCode
        requiredFlags = $flagStatus
        zeroToolSurfaceVerified = $false
        documentProfileSupported = $documentSupported
        projectAuditProfileSupported = $false
        status = if ($auth.subscription -and $documentSupported) { 'READY_DOCUMENTS' } else { 'BLOCKED' }
    }
}

function Invoke-DuoForgeDoctorInternal {
    [CmdletBinding()]
    param()

    $apiConflicts = @(Get-DuoForgeApiCredentialConflicts)
    $codex = Get-DuoForgeProviderDiagnostic -Provider codex
    $claude = Get-DuoForgeProviderDiagnostic -Provider claude
    $pwshVersion = $PSVersionTable.PSVersion.ToString()
    $pwshReady = $PSVersionTable.PSVersion.Major -ge 7
    $documentReady = $pwshReady -and $apiConflicts.Count -eq 0 -and $codex.subscription -and $claude.subscription -and $codex.documentProfileSupported -and $claude.documentProfileSupported

    $recommendations = [System.Collections.Generic.List[string]]::new()
    if (-not $pwshReady) { $recommendations.Add('PowerShell 7 이상에서 다시 실행해 주세요.') }
    if (-not $codex.installed) { $recommendations.Add('Codex CLI를 설치해 주세요.') }
    elseif (-not $codex.subscription) { $recommendations.Add('codex login으로 ChatGPT 구독 로그인을 완료해 주세요.') }
    if (-not $claude.installed) { $recommendations.Add('Claude Code CLI를 설치해 주세요.') }
    elseif (-not $claude.subscription) { $recommendations.Add('claude auth login으로 Claude 구독 로그인을 완료해 주세요.') }
    if ($apiConflicts.Count -gt 0) { $recommendations.Add('표시된 API 인증 우선 환경 변수를 사용자가 직접 정리한 뒤 다시 검사해 주세요. DuoForge는 값을 읽거나 자동 삭제하지 않습니다.') }
    $recommendations.Add('3A는 Codex 무도구 표면 또는 OS 격리가 검증되지 않아 비활성화되어 있습니다.')

    return [ordered]@{
        schemaVersion = 1
        checkedAt = Get-DuoForgeUtcNow
        powershell = [ordered]@{
            version = $pwshVersion
            executable = (Get-Process -Id $PID).Path
            ready = $pwshReady
        }
        subscriptionOnly = $true
        apiCredentialConflicts = @($apiConflicts)
        providers = [ordered]@{
            codex = $codex
            claude = $claude
        }
        readyForDocumentModes = $documentReady
        readyForProjectAudit = $false
        projectAuditBlockCode = 'DF-PREFLIGHT-3A-ISOLATION'
        recommendations = @($recommendations)
    }
}
