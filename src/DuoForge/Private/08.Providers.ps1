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
    $loggedOut = $Text -match '(?i)(not\s+logged\s+in|logged\s+out|login\s+required|please\s+(?:log\s*in|login))'
    return [ordered]@{
        authenticated = $ExitCode -eq 0
        subscription = $subscription -and -not $api
        authType = if ($subscription -and -not $api) { 'chatgpt' } elseif ($api) { 'api' } else { 'unknown' }
        exitCode = $ExitCode
        recognized = $subscription -or $api -or $loggedOut
        loggedOut = $loggedOut
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
    $recognized = $false
    try {
        $status = $Text | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        $loggedInProperty = $status.PSObject.Properties['loggedIn']
        if ($null -ne $loggedInProperty) {
            $recognized = $true
            $loggedIn = [bool]$status.loggedIn
            if (-not [string]::IsNullOrWhiteSpace([string]$status.authMethod)) { $authMethod = [string]$status.authMethod }
            if (-not [string]::IsNullOrWhiteSpace([string]$status.apiProvider)) { $apiProvider = [string]$status.apiProvider }
            if (-not [string]::IsNullOrWhiteSpace([string]$status.subscriptionType)) { $subscriptionType = [string]$status.subscriptionType }
        }
    }
    catch { $loggedIn = $false }

    $authenticated = $ExitCode -eq 0 -and $loggedIn
    $subscription = $authenticated -and $authMethod -eq 'claude.ai' -and $apiProvider -eq 'firstParty'
    return [ordered]@{
        authenticated = $authenticated
        subscription = $subscription
        authType = if ($subscription) { 'claude.ai' } elseif ($loggedIn) { 'non-subscription-or-unknown' } else { 'unknown' }
        subscriptionType = if ($subscription) { $subscriptionType } else { $null }
        exitCode = $ExitCode
        recognized = $recognized
        loggedOut = $recognized -and -not $loggedIn
    }
}

function Get-DuoForgeProviderAuthStatusInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$Provider,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ProcessResult,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ProviderContext
    )

    if ([string]$ProviderContext.authContextStatus -eq 'PROFILE_MISMATCH') {
        return [ordered]@{ status = 'PROFILE_MISMATCH'; authenticated = $false; subscription = $false; authType = 'unknown'; subscriptionType = $null; exitCode = $ProcessResult.exitCode }
    }
    if (-not [bool](Get-DuoForgeObjectValue -Object $ProcessResult -Name 'started' -Default $false) -or
        [bool](Get-DuoForgeObjectValue -Object $ProcessResult -Name 'timedOut' -Default $false)) {
        return [ordered]@{ status = 'STATUS_UNAVAILABLE'; authenticated = $false; subscription = $false; authType = 'unknown'; subscriptionType = $null; exitCode = $ProcessResult.exitCode }
    }

    $text = [string](Get-DuoForgeObjectValue -Object $ProcessResult -Name 'stdout' -Default '') + [Environment]::NewLine + [string](Get-DuoForgeObjectValue -Object $ProcessResult -Name 'stderr' -Default '')
    if ($text -match '(?i)(access\s+(?:is\s+)?denied|permission\s+denied|operation\s+not\s+permitted)') {
        return [ordered]@{ status = 'STATUS_UNAVAILABLE'; authenticated = $false; subscription = $false; authType = 'unknown'; subscriptionType = $null; exitCode = $ProcessResult.exitCode }
    }
    $exitCode = if ($null -eq $ProcessResult.exitCode) { 1 } else { [int]$ProcessResult.exitCode }
    $parsed = if ($Provider -eq 'codex') {
        ConvertFrom-DuoForgeCodexAuthStatusInternal -Text $text -ExitCode $exitCode
    }
    else {
        ConvertFrom-DuoForgeClaudeAuthStatusInternal -Text ([string]$ProcessResult.stdout) -ExitCode $exitCode
    }
    $status = if ($parsed.subscription) {
        'VERIFIED_SUBSCRIPTION'
    }
    elseif ($parsed.loggedOut) {
        'VERIFIED_NOT_LOGGED_IN'
    }
    elseif ($parsed.recognized -and $parsed.authenticated) {
        'VERIFIED_API_AUTH'
    }
    elseif ($exitCode -eq 0) {
        'STATUS_FORMAT_UNSUPPORTED'
    }
    else {
        'STATUS_UNAVAILABLE'
    }
    return [ordered]@{
        status = $status
        authenticated = [bool]$parsed.authenticated
        subscription = [bool]$parsed.subscription
        authType = [string]$parsed.authType
        subscriptionType = Get-DuoForgeObjectValue -Object $parsed -Name 'subscriptionType'
        exitCode = $exitCode
    }
}

function Invoke-DuoForgeProviderContextProcessInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$Provider,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ProviderContext,
        [scriptblock]$ProcessInvoker
    )

    if ($null -ne $ProcessInvoker) { return & $ProcessInvoker $Provider $Arguments $ProviderContext }
    return Invoke-DuoForgeProcess -CommandName $Provider -Arguments $Arguments -CommandInvocation $ProviderContext.invocation -EnvironmentAllowList @($ProviderContext.environmentAllowList) -EnvironmentOverrides $ProviderContext.environmentOverrides
}

function Get-DuoForgeProviderDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('codex', 'claude')]
        [string]$Provider,

        [System.Collections.IDictionary]$ProviderContext,

        [scriptblock]$ProcessInvoker
    )

    if ($null -eq $ProviderContext) {
        $ProviderContext = Resolve-DuoForgeProviderExecutionContextInternal -Provider $Provider
    }
    $command = $ProviderContext.invocation
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
            authStatus = 'STATUS_UNAVAILABLE'
            authContext = [ordered]@{ status = [string]$ProviderContext.authContextStatus; authHomeSource = [string]$ProviderContext.authHomeSource; profileMismatch = [bool]$ProviderContext.profileMismatch; hostElevation = [string]$ProviderContext.hostElevation; liveRuntimeEligible = $false }
            status = 'MISSING'
        }
    }

    $versionResult = Invoke-DuoForgeProviderContextProcessInternal -Provider $Provider -Arguments @('--version') -ProviderContext $ProviderContext -ProcessInvoker $ProcessInvoker
    $versionText = (($versionResult.stdout + ' ' + $versionResult.stderr).Trim() -split "`r?`n")[0]

    if ($Provider -eq 'codex') {
        $helpResult = Invoke-DuoForgeProviderContextProcessInternal -Provider $Provider -Arguments @('exec', '--help') -ProviderContext $ProviderContext -ProcessInvoker $ProcessInvoker
        $globalHelpResult = Invoke-DuoForgeProviderContextProcessInternal -Provider $Provider -Arguments @('--help') -ProviderContext $ProviderContext -ProcessInvoker $ProcessInvoker
        $helpText = $helpResult.stdout + [Environment]::NewLine + $helpResult.stderr + [Environment]::NewLine + $globalHelpResult.stdout + [Environment]::NewLine + $globalHelpResult.stderr
        $required = @('--ask-for-approval', '--config', '--model', '--sandbox', '--skip-git-repo-check', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--output-schema', '--json', '--output-last-message')
        $flagStatus = Test-DuoForgeHelpFlags -HelpText $helpText -RequiredFlags $required
        $authResult = Invoke-DuoForgeProviderContextProcessInternal -Provider $Provider -Arguments @('login', 'status') -ProviderContext $ProviderContext -ProcessInvoker $ProcessInvoker
        $auth = Get-DuoForgeProviderAuthStatusInternal -Provider codex -ProcessResult $authResult -ProviderContext $ProviderContext
        $documentSupported = @($flagStatus.Values | Where-Object { -not $_ }).Count -eq 0
        return [ordered]@{
            provider = 'codex'
            installed = $true
            version = $versionText
            authenticated = $auth.authenticated
            subscription = $auth.subscription
            authType = $auth.authType
            authStatus = $auth.status
            authStatusExitCode = $auth.exitCode
            authContext = [ordered]@{ status = [string]$ProviderContext.authContextStatus; authHomeSource = [string]$ProviderContext.authHomeSource; profileMismatch = [bool]$ProviderContext.profileMismatch; hostElevation = [string]$ProviderContext.hostElevation; liveRuntimeEligible = [bool]$ProviderContext.liveRuntimeEligible; commandSource = [string]$ProviderContext.invocation.source }
            liveCallability = 'UNVERIFIED'
            requiredFlags = $flagStatus
            ignoreRulesAvailable = [bool]$flagStatus['--ignore-rules']
            zeroToolSurfaceVerified = $false
            documentProfileSupported = $documentSupported
            projectAuditProfileSupported = $false
            status = if ($auth.subscription -and $documentSupported -and $ProviderContext.liveRuntimeEligible) { 'READY_DOCUMENTS' } elseif ($auth.status -eq 'PROFILE_MISMATCH') { 'BLOCKED_CONTEXT' } else { 'BLOCKED' }
        }
    }

    $helpResult = Invoke-DuoForgeProviderContextProcessInternal -Provider $Provider -Arguments @('--help') -ProviderContext $ProviderContext -ProcessInvoker $ProcessInvoker
    $helpText = $helpResult.stdout + [Environment]::NewLine + $helpResult.stderr
    $required = @('--model', '--effort', '--safe-mode', '--strict-mcp-config', '--tools', '--disallowedTools', '--no-chrome', '--no-session-persistence', '--permission-mode', '--output-format', '--json-schema')
    $flagStatus = Test-DuoForgeHelpFlags -HelpText $helpText -RequiredFlags $required
    $authResult = Invoke-DuoForgeProviderContextProcessInternal -Provider $Provider -Arguments @('auth', 'status') -ProviderContext $ProviderContext -ProcessInvoker $ProcessInvoker
    $auth = Get-DuoForgeProviderAuthStatusInternal -Provider claude -ProcessResult $authResult -ProviderContext $ProviderContext
    $documentSupported = @($flagStatus.Values | Where-Object { -not $_ }).Count -eq 0
    return [ordered]@{
        provider = 'claude'
        installed = $true
        version = $versionText
        authenticated = $auth.authenticated
        subscription = $auth.subscription
        authType = $auth.authType
        subscriptionType = $auth.subscriptionType
        authStatus = $auth.status
        authStatusExitCode = $auth.exitCode
        authContext = [ordered]@{ status = [string]$ProviderContext.authContextStatus; authHomeSource = [string]$ProviderContext.authHomeSource; profileMismatch = [bool]$ProviderContext.profileMismatch; hostElevation = [string]$ProviderContext.hostElevation; liveRuntimeEligible = [bool]$ProviderContext.liveRuntimeEligible; commandSource = [string]$ProviderContext.invocation.source }
        liveCallability = 'UNVERIFIED'
        requiredFlags = $flagStatus
        zeroToolSurfaceVerified = $false
        documentProfileSupported = $documentSupported
        projectAuditProfileSupported = $false
        status = if ($auth.subscription -and $documentSupported -and $ProviderContext.liveRuntimeEligible) { 'READY_DOCUMENTS' } elseif ($auth.status -eq 'PROFILE_MISMATCH') { 'BLOCKED_CONTEXT' } else { 'BLOCKED' }
    }
}

function Get-DuoForgeDoctorRecommendationsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$PowerShellReady,
        [Parameter(Mandatory)]$Codex,
        [Parameter(Mandatory)]$Claude,
        [AllowEmptyCollection()][string[]]$ApiConflicts = @()
    )

    $recommendations = [System.Collections.Generic.List[string]]::new()
    if (-not $PowerShellReady) { $recommendations.Add('PowerShell 7 이상에서 다시 실행해 주세요.') }
    if (-not $Codex.installed) { $recommendations.Add('Codex CLI를 설치해 주세요.') }
    elseif ($Codex.authStatus -eq 'VERIFIED_NOT_LOGGED_IN') { $recommendations.Add('codex login으로 ChatGPT 구독 로그인을 완료해 주세요.') }
    elseif ($Codex.authStatus -eq 'PROFILE_MISMATCH') { $recommendations.Add('현재 분리된 실행 환경에서는 Codex 로그인을 확인할 수 없습니다. 일반 PowerShell 7 창에서 duoforge doctor를 다시 실행해 주세요.') }
    elseif (-not $Codex.subscription) { $recommendations.Add('codex login status를 일반 호스트 PowerShell 7에서 다시 확인해 주세요. 상태 확인 실패를 미로그인으로 간주하지 않았습니다.') }
    if (-not $Claude.installed) { $recommendations.Add('Claude Code CLI를 설치해 주세요.') }
    elseif ($Claude.authStatus -eq 'VERIFIED_NOT_LOGGED_IN') { $recommendations.Add('claude auth login으로 Claude 구독 로그인을 완료해 주세요.') }
    elseif ($Claude.authStatus -eq 'PROFILE_MISMATCH') { $recommendations.Add('현재 분리된 실행 환경에서는 Claude 로그인을 확인할 수 없습니다. 일반 PowerShell 7 창에서 duoforge doctor를 다시 실행해 주세요.') }
    elseif (-not $Claude.subscription) { $recommendations.Add('claude auth status를 일반 호스트 PowerShell 7에서 다시 확인해 주세요. 상태 확인 실패를 미로그인으로 간주하지 않았습니다.') }
    if ($ApiConflicts.Count -gt 0) { $recommendations.Add('표시된 API 인증 우선 환경 변수를 사용자가 직접 정리한 뒤 다시 검사해 주세요. DuoForge는 값을 읽거나 자동 삭제하지 않습니다.') }
    $recommendations.Add('두 프로젝트 비교 기능은 현재 Windows에서 프로젝트 밖 파일 접근과 추가 프로그램 실행을 충분히 막지 못해 사용할 수 없습니다.')
    return @($recommendations)
}

function Update-DuoForgeDoctorProviderInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$Provider,
        [Parameter(Mandatory)]$Diagnostic
    )

    $updated = ConvertTo-DuoForgeHashtable -InputObject $Report
    $updated.providers[$Provider] = ConvertTo-DuoForgeHashtable -InputObject $Diagnostic
    $codex = $updated.providers.codex
    $claude = $updated.providers.claude
    $pwshReady = [bool](Get-DuoForgeObjectValue -Object $updated.powershell -Name 'ready' -Default $false)
    $apiConflicts = @(Get-DuoForgeObjectValue -Object $updated -Name 'apiCredentialConflicts' -Default @())
    $updated.checkedAt = Get-DuoForgeUtcNow
    $updated.readyForDocumentModes = $pwshReady -and $apiConflicts.Count -eq 0 -and $codex.subscription -and $claude.subscription -and $codex.documentProfileSupported -and $claude.documentProfileSupported
    $updated.readyForProjectAudit = $false
    $updated.recommendations = @(Get-DuoForgeDoctorRecommendationsInternal -PowerShellReady $pwshReady -Codex $codex -Claude $claude -ApiConflicts $apiConflicts)
    return $updated
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

    $recommendations = @(Get-DuoForgeDoctorRecommendationsInternal -PowerShellReady $pwshReady -Codex $codex -Claude $claude -ApiConflicts $apiConflicts)

    return [ordered]@{
        schemaVersion = 1
        checkedAt = Get-DuoForgeUtcNow
        powershell = [ordered]@{
            version = $pwshVersion
            executable = (Get-Process -Id $PID).Path
            ready = $pwshReady
        }
        hostContext = [ordered]@{
            elevation = [string]$codex.authContext.hostElevation
            profileMatch = -not [bool]$codex.authContext.profileMismatch
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

function Get-DuoForgeAuthenticationGateInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Report)

    $missingProviders = [System.Collections.Generic.List[string]]::new()
    $contextUnavailableProviders = [System.Collections.Generic.List[string]]::new()
    foreach ($provider in @('codex', 'claude')) {
        $diagnostic = Get-DuoForgeObjectValue -Object $Report.providers -Name $provider
        $subscription = [bool](Get-DuoForgeObjectValue -Object $diagnostic -Name 'subscription' -Default $false)
        if ($subscription) { continue }
        $authStatus = [string](Get-DuoForgeObjectValue -Object $diagnostic -Name 'authStatus' -Default 'VERIFIED_NOT_LOGGED_IN')
        if ($authStatus -eq 'VERIFIED_NOT_LOGGED_IN') { $missingProviders.Add($provider) }
        else { $contextUnavailableProviders.Add($provider) }
    }

    $ready = [bool](Get-DuoForgeObjectValue -Object $Report -Name 'readyForDocumentModes' -Default $false)
    if ($ready) { $missingProviders.Clear() }
    $actions = [System.Collections.Generic.List[string]]::new()
    foreach ($provider in $missingProviders) { $actions.Add("$provider-login") }
    if (-not $ready) {
        $actions.Add('show-manual-login')
        $actions.Add('recheck')
        $actions.Add('exit')
    }

    return [ordered]@{
        ready = $ready
        modelCallsAllowed = $ready
        inputTransferAllowed = $ready
        blockCode = if ($ready) { $null } else { 'DF-PREFLIGHT-PROVIDERS' }
        missingProviders = @($missingProviders)
        contextUnavailableProviders = @($contextUnavailableProviders)
        actions = @($actions)
    }
}

function Get-DuoForgeGuidedLoginOutcomeInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$Provider,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)]$PostReport
    )

    $diagnostic = Get-DuoForgeObjectValue -Object $PostReport.providers -Name $Provider
    $subscription = [bool](Get-DuoForgeObjectValue -Object $diagnostic -Name 'subscription' -Default $false)
    $authStatus = [string](Get-DuoForgeObjectValue -Object $diagnostic -Name 'authStatus' -Default '')
    $status = if ($subscription) {
        'READY'
    }
    elseif ($ExitCode -ne 0) {
        'CANCELLED_OR_FAILED'
    }
    elseif ($authStatus -in @('PROFILE_MISMATCH', 'STATUS_UNAVAILABLE', 'STATUS_FORMAT_UNSUPPORTED')) {
        'AUTH_STATUS_UNAVAILABLE'
    }
    else {
        'AUTH_NOT_CONFIRMED'
    }
    return [ordered]@{
        provider = $Provider
        status = $status
        exitCode = $ExitCode
        subscription = $subscription
        modelCallsAllowed = [bool](Get-DuoForgeAuthenticationGateInternal -Report $PostReport).modelCallsAllowed
        nextActions = if ($subscription) {
            @('recheck')
        }
        elseif ($status -eq 'AUTH_STATUS_UNAVAILABLE') {
            @('show-manual-login', 'recheck', 'exit')
        }
        else {
            @("$provider-login", 'show-manual-login', 'recheck', 'exit')
        }
    }
}
