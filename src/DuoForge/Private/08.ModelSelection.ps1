function ConvertTo-DuoForgeCatalogTextInternal {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [int]$MaximumLength = 200
    )

    $value = [regex]::Replace(([string]$Text).Trim(), '[\p{C}]', ' ')
    if ($value.Length -gt $MaximumLength) { $value = $value.Substring(0, $MaximumLength) }
    return $value
}

function Test-DuoForgeReasoningEffortIdentifierInternal {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Effort)

    return -not [string]::IsNullOrWhiteSpace($Effort) -and $Effort -cmatch '^[a-z][a-z0-9_-]{0,31}$'
}

function Get-DuoForgePreferredReasoningEffortInternal {
    [CmdletBinding()]
    param(
        [string[]]$Efforts,
        [AllowNull()][AllowEmptyString()][string]$DefaultEffort
    )

    $supported = @($Efforts | Where-Object { Test-DuoForgeReasoningEffortIdentifierInternal -Effort $_ } | Select-Object -Unique)
    if ('high' -cin $supported) { return 'high' }
    if (-not [string]::IsNullOrWhiteSpace($DefaultEffort) -and $DefaultEffort -cin $supported) { return $DefaultEffort }
    if ('medium' -cin $supported) { return 'medium' }
    if ($supported.Count -gt 0) { return [string]$supported[0] }
    return $null
}

function Get-DuoForgeCodexModelFallbackInternal {
    [CmdletBinding()]
    param()

    return @(
        [ordered]@{
            value = 'gpt-5.6-sol'
            displayName = 'GPT-5.6-Sol'
            description = 'Latest frontier agentic coding model.'
            recommended = $true
            defaultReasoningEffort = 'low'
            recommendedReasoningEffort = 'high'
            reasoningEfforts = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')
        }
        [ordered]@{
            value = 'gpt-5.6-terra'
            displayName = 'GPT-5.6-Terra'
            description = 'Balanced agentic coding model for everyday work.'
            recommended = $false
            defaultReasoningEffort = 'medium'
            recommendedReasoningEffort = 'high'
            reasoningEfforts = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')
        }
        [ordered]@{
            value = 'gpt-5.6-luna'
            displayName = 'GPT-5.6-Luna'
            description = 'Fast and affordable agentic coding model.'
            recommended = $false
            defaultReasoningEffort = 'medium'
            recommendedReasoningEffort = 'high'
            reasoningEfforts = @('low', 'medium', 'high', 'xhigh', 'max')
        }
    )
}

function Get-DuoForgeCodexModelCachePathInternal {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$ProviderContext)

    if ($null -eq $ProviderContext) { $ProviderContext = Resolve-DuoForgeProviderExecutionContextInternal -Provider codex }
    if (-not [bool]$ProviderContext.liveRuntimeEligible) { return $null }
    $authHome = [string]$ProviderContext.authHomePath
    if ([string]::IsNullOrWhiteSpace($authHome)) { return $null }
    return Join-Path $authHome 'models_cache.json'
}

function Get-DuoForgeCodexModelsFromCacheInternal {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$CachePath)

    if ([string]::IsNullOrWhiteSpace($CachePath) -or -not (Test-Path -LiteralPath $CachePath -PathType Leaf)) {
        return @()
    }

    try {
        $cache = Get-Content -LiteralPath $CachePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $visible = @(
            @($cache.models) |
                Where-Object { [string]$_.visibility -eq 'list' } |
                Sort-Object { [int]$_.priority }
        )
        if ($visible.Count -eq 0) { return @() }

        $result = [System.Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt $visible.Count; $index++) {
            $model = $visible[$index]
            $value = [string]$model.slug
            if (-not (Test-DuoForgeModelIdentifierInternal -Model $value)) { return @() }

            $description = ConvertTo-DuoForgeCatalogTextInternal -Text ([string]$model.description) -MaximumLength 200
            $displayName = ConvertTo-DuoForgeCatalogTextInternal -Text ([string]$model.display_name) -MaximumLength 80
            if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $value }

            $efforts = @(
                @($model.supported_reasoning_levels) |
                    ForEach-Object { [string]$_.effort } |
                    Where-Object { Test-DuoForgeReasoningEffortIdentifierInternal -Effort $_ } |
                    Select-Object -Unique
            )
            if ($efforts.Count -eq 0) { return @() }
            $defaultEffort = [string](Get-DuoForgeObjectValue -Object $model -Name 'default_reasoning_level')
            $recommendedEffort = Get-DuoForgePreferredReasoningEffortInternal -Efforts $efforts -DefaultEffort $defaultEffort

            $result.Add([ordered]@{
                value = $value
                displayName = $displayName
                description = $description
                recommended = $index -eq 0
                defaultReasoningEffort = $defaultEffort
                recommendedReasoningEffort = $recommendedEffort
                reasoningEfforts = $efforts
            })
        }

        return @($result)
    }
    catch {
        return @()
    }
}

function ConvertFrom-DuoForgeCodexModelListResponseInternal {
    [CmdletBinding()]
    param($Response)

    $data = Get-DuoForgeObjectValue -Object $Response -Name 'data'
    if ($null -eq $data) {
        $resultObject = Get-DuoForgeObjectValue -Object $Response -Name 'result'
        $data = Get-DuoForgeObjectValue -Object $resultObject -Name 'data'
    }
    if ($null -eq $data) { return @() }

    $models = [System.Collections.Generic.List[object]]::new()
    foreach ($model in @($data)) {
        if ([bool](Get-DuoForgeObjectValue -Object $model -Name 'hidden')) { continue }
        $value = [string](Get-DuoForgeObjectValue -Object $model -Name 'model')
        if (-not (Test-DuoForgeModelIdentifierInternal -Model $value)) { continue }

        $efforts = @(
            @(Get-DuoForgeObjectValue -Object $model -Name 'supportedReasoningEfforts') |
                ForEach-Object {
                    $valueObject = Get-DuoForgeObjectValue -Object $_ -Name 'reasoningEffort'
                    if ($null -ne $valueObject) { [string]$valueObject } else { [string]$_ }
                } |
                Where-Object { Test-DuoForgeReasoningEffortIdentifierInternal -Effort $_ } |
                Select-Object -Unique
        )
        if ($efforts.Count -eq 0) { continue }

        $displayName = ConvertTo-DuoForgeCatalogTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $model -Name 'displayName')) -MaximumLength 80
        if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $value }
        $defaultEffort = [string](Get-DuoForgeObjectValue -Object $model -Name 'defaultReasoningEffort')
        $models.Add([ordered]@{
            value = $value
            displayName = $displayName
            description = ConvertTo-DuoForgeCatalogTextInternal -Text ([string](Get-DuoForgeObjectValue -Object $model -Name 'description')) -MaximumLength 200
            recommended = [bool](Get-DuoForgeObjectValue -Object $model -Name 'isDefault')
            defaultReasoningEffort = $defaultEffort
            recommendedReasoningEffort = Get-DuoForgePreferredReasoningEffortInternal -Efforts $efforts -DefaultEffort $defaultEffort
            reasoningEfforts = $efforts
        })
    }

    if ($models.Count -gt 0 -and @($models | Where-Object { [bool]$_.recommended }).Count -eq 0) {
        $models[0].recommended = $true
    }
    return @($models)
}

function Resolve-DuoForgeCodexAppServerInvocationInternal {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$ProviderContext)

    if ($null -eq $ProviderContext) { $ProviderContext = Resolve-DuoForgeProviderExecutionContextInternal -Provider codex }
    $invocation = $ProviderContext.invocation
    if ($null -eq $invocation) { return $null }
    if ([System.IO.Path]::GetExtension([string]$invocation.source) -in @('.cmd', '.bat')) {
        $npmRoot = [System.IO.Path]::GetDirectoryName([string]$invocation.source)
        $codexJavaScript = Join-Path $npmRoot 'node_modules\@openai\codex\bin\codex.js'
        $node = @(Get-Command node.exe -All -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq [System.Management.Automation.CommandTypes]::Application } | Select-Object -First 1)
        if ($node.Count -eq 1 -and (Test-Path -LiteralPath $codexJavaScript -PathType Leaf)) {
            return [ordered]@{
                fileName = [string]$node[0].Source
                prefixArguments = @($codexJavaScript)
                source = [string]$invocation.source
            }
        }
    }
    return $invocation
}

function Invoke-DuoForgeCodexModelListInternal {
    [CmdletBinding()]
    param(
        [int]$TimeoutSeconds = 15,
        [System.Collections.IDictionary]$ProviderContext
    )

    if ($null -eq $ProviderContext) { $ProviderContext = Resolve-DuoForgeProviderExecutionContextInternal -Provider codex }
    if (-not [bool]$ProviderContext.liveRuntimeEligible) { return $null }
    $invocation = Resolve-DuoForgeCodexAppServerInvocationInternal -ProviderContext $ProviderContext
    if ($null -eq $invocation) { return $null }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [string]$invocation.fileName
    $startInfo.WorkingDirectory = $script:ProjectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    Set-DuoForgeProcessEnvironmentInternal -StartInfo $startInfo -EnvironmentAllowList @($ProviderContext.environmentAllowList) -EnvironmentOverrides $ProviderContext.environmentOverrides
    foreach ($argument in @($invocation.prefixArguments) + @('app-server', '--listen', 'stdio://')) {
        $startInfo.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { return $null }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $requests = @(
            ([ordered]@{ method = 'initialize'; id = 1; params = [ordered]@{ clientInfo = [ordered]@{ name = 'duoforge'; title = 'DuoForge'; version = $script:ModuleVersion } } } | ConvertTo-Json -Depth 10 -Compress),
            ([ordered]@{ method = 'initialized'; params = [ordered]@{} } | ConvertTo-Json -Depth 10 -Compress),
            ([ordered]@{ method = 'model/list'; id = 2; params = [ordered]@{ includeHidden = $false; limit = 100 } } | ConvertTo-Json -Depth 10 -Compress)
        )
        foreach ($request in $requests) { $process.StandardInput.WriteLine($request) }
        $process.StandardInput.Flush()

        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $readTask = $process.StandardOutput.ReadLineAsync()
            if (-not $readTask.Wait($remaining)) { return $null }
            $line = $readTask.Result
            if ($null -eq $line) { return $null }
            try {
                $message = $line | ConvertFrom-Json -Depth 50 -ErrorAction Stop
                if ([string]$message.id -eq '2') {
                    if ($null -ne (Get-DuoForgeObjectValue -Object $message -Name 'error')) { return $null }
                    return Get-DuoForgeObjectValue -Object $message -Name 'result'
                }
            }
            catch { }
        }
        return $null
    }
    catch {
        return $null
    }
    finally {
        try { $process.StandardInput.Close() } catch { }
        try {
            if (-not $process.HasExited -and -not $process.WaitForExit(1500)) { $process.Kill($true) }
        }
        catch { }
        $process.Dispose()
    }
}

function Get-DuoForgeCodexModelsFromCliInternal {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$ProviderContext)

    if ($null -eq $ProviderContext) { $ProviderContext = Resolve-DuoForgeProviderExecutionContextInternal -Provider codex }
    $cacheKey = 'codex|{0}|{1}|{2}' -f [string](Get-DuoForgeObjectValue -Object $ProviderContext.invocation -Name 'source' -Default ''), [string]$ProviderContext.authHomePath, [bool]$ProviderContext.liveRuntimeEligible
    if (-not (Get-Variable -Name DuoForgeCliCatalogCache -Scope Script -ErrorAction SilentlyContinue)) {
        $script:DuoForgeCliCatalogCache = @{}
    }
    if ($script:DuoForgeCliCatalogCache.ContainsKey($cacheKey)) {
        return @($script:DuoForgeCliCatalogCache[$cacheKey])
    }

    $response = Invoke-DuoForgeCodexModelListInternal -ProviderContext $ProviderContext
    $models = @(ConvertFrom-DuoForgeCodexModelListResponseInternal -Response $response)
    $script:DuoForgeCliCatalogCache[$cacheKey] = @($models)
    return @($models)
}

function Clear-DuoForgeProviderCatalogCacheInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('codex', 'claude')][string]$Provider)

    if (-not (Get-Variable -Name DuoForgeCliCatalogCache -Scope Script -ErrorAction SilentlyContinue)) { return }
    foreach ($key in @($script:DuoForgeCliCatalogCache.Keys | Where-Object { [string]$_ -like "$Provider|*" })) {
        $script:DuoForgeCliCatalogCache.Remove($key)
    }
}

function Get-DuoForgeClaudeModelFallbackInternal {
    [CmdletBinding()]
    param()

    $efforts = @('low', 'medium', 'high', 'xhigh', 'max')
    return [ordered]@{
        models = @(
            [ordered]@{ value = 'opus'; displayName = 'Opus'; description = 'Claude CLI의 최신 Opus 계열 별칭'; recommended = $true; defaultReasoningEffort = 'high'; recommendedReasoningEffort = 'high'; reasoningEfforts = $efforts }
            [ordered]@{ value = 'sonnet'; displayName = 'Sonnet'; description = 'Claude CLI의 최신 Sonnet 계열 별칭'; recommended = $false; defaultReasoningEffort = 'high'; recommendedReasoningEffort = 'high'; reasoningEfforts = $efforts }
            [ordered]@{ value = 'fable'; displayName = 'Fable'; description = 'Claude CLI의 최신 Fable 계열 별칭'; recommended = $false; defaultReasoningEffort = 'high'; recommendedReasoningEffort = 'high'; reasoningEfforts = $efforts }
            [ordered]@{ value = 'default'; displayName = '계정 기본 모델'; description = 'Claude CLI가 계정 또는 조직 권장 모델로 해석'; recommended = $false; defaultReasoningEffort = 'high'; recommendedReasoningEffort = 'high'; reasoningEfforts = $efforts }
        )
        efforts = $efforts
        recommendedModel = 'opus'
        recommendedReasoningEffort = 'high'
    }
}

function ConvertFrom-DuoForgeClaudeHelpInternal {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$HelpText)

    if ([string]::IsNullOrWhiteSpace($HelpText)) { return $null }
    $modelBlock = [regex]::Match($HelpText, '(?ms)^\s*--model <model>\s+(?<body>.*?)(?=^\s{2}(?:-[A-Za-z]|--[A-Za-z]))')
    $effortBlock = [regex]::Match($HelpText, '(?ms)^\s*--effort <level>\s+(?<body>.*?)(?=^\s{2}(?:-[A-Za-z]|--[A-Za-z]))')
    if (-not $modelBlock.Success -or -not $effortBlock.Success) { return $null }

    $advertisedAliases = @(
        [regex]::Matches($modelBlock.Groups['body'].Value, "'(?<value>[a-z][a-z0-9-]*)'") |
            ForEach-Object { [string]$_.Groups['value'].Value } |
            Where-Object { $_ -cnotlike 'claude-*' -and (Test-DuoForgeModelIdentifierInternal -Model $_) } |
            Select-Object -Unique
    )
    $effortMatch = [regex]::Match($effortBlock.Groups['body'].Value, '\((?<levels>[a-z0-9_, -]+)\)')
    $efforts = if ($effortMatch.Success) {
        @($effortMatch.Groups['levels'].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { Test-DuoForgeReasoningEffortIdentifierInternal -Effort $_ } | Select-Object -Unique)
    }
    else { @() }
    if ($advertisedAliases.Count -eq 0 -or $efforts.Count -eq 0) { return $null }

    $orderedAliases = [System.Collections.Generic.List[string]]::new()
    foreach ($preferred in @('opus', 'sonnet', 'fable', 'best', 'haiku', 'opusplan')) {
        if ($preferred -cin $advertisedAliases -and $preferred -cnotin $orderedAliases) { $orderedAliases.Add($preferred) }
    }
    foreach ($alias in $advertisedAliases) {
        if ($alias -cnotin $orderedAliases) { $orderedAliases.Add($alias) }
    }
    if ('default' -cnotin $orderedAliases) { $orderedAliases.Add('default') }

    $recommendedModel = if ('opus' -cin $orderedAliases) { 'opus' } elseif ('default' -cin $orderedAliases) { 'default' } else { [string]$orderedAliases[0] }
    $recommendedEffort = Get-DuoForgePreferredReasoningEffortInternal -Efforts $efforts -DefaultEffort 'high'
    $models = [System.Collections.Generic.List[object]]::new()
    foreach ($alias in $orderedAliases) {
        $displayName = switch ($alias) {
            'default' { '계정 기본 모델' }
            default { (Get-Culture).TextInfo.ToTitleCase($alias) }
        }
        $description = if ($alias -eq 'default') { 'Claude CLI가 계정 또는 조직 권장 모델로 해석' } else { "Claude CLI가 최신 $displayName 계열로 해석하는 별칭" }
        $models.Add([ordered]@{
            value = $alias
            displayName = $displayName
            description = $description
            recommended = $alias -ceq $recommendedModel
            defaultReasoningEffort = $recommendedEffort
            recommendedReasoningEffort = $recommendedEffort
            reasoningEfforts = $efforts
        })
    }

    return [ordered]@{
        models = @($models)
        efforts = $efforts
        recommendedModel = $recommendedModel
        recommendedReasoningEffort = $recommendedEffort
    }
}

function Get-DuoForgeClaudeCatalogFromCliInternal {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$ProviderContext)

    if ($null -eq $ProviderContext) { $ProviderContext = Resolve-DuoForgeProviderExecutionContextInternal -Provider claude }
    $cacheKey = 'claude|{0}|{1}|{2}' -f [string](Get-DuoForgeObjectValue -Object $ProviderContext.invocation -Name 'source' -Default ''), [string]$ProviderContext.authHomePath, [bool]$ProviderContext.liveRuntimeEligible
    if (-not (Get-Variable -Name DuoForgeCliCatalogCache -Scope Script -ErrorAction SilentlyContinue)) {
        $script:DuoForgeCliCatalogCache = @{}
    }
    if ($script:DuoForgeCliCatalogCache.ContainsKey($cacheKey)) {
        return $script:DuoForgeCliCatalogCache[$cacheKey]
    }

    $process = if ([bool]$ProviderContext.liveRuntimeEligible) {
        Invoke-DuoForgeProcess -CommandName 'claude' -Arguments @('--help') -TimeoutSeconds 10 -CommandInvocation $ProviderContext.invocation -EnvironmentAllowList @($ProviderContext.environmentAllowList) -EnvironmentOverrides $ProviderContext.environmentOverrides
    }
    else { [ordered]@{ started = $false; timedOut = $false; exitCode = $null; stdout = ''; stderr = ''; errorCategory = 'profile-mismatch' } }
    $catalog = if ($process.started -and -not $process.timedOut -and $process.exitCode -eq 0) {
        ConvertFrom-DuoForgeClaudeHelpInternal -HelpText ([string]$process.stdout)
    }
    else { $null }
    $script:DuoForgeCliCatalogCache[$cacheKey] = $catalog
    return $catalog
}

function Get-DuoForgeProviderSelectionOptionsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('codex', 'claude')]
        [string]$Provider,
        [AllowNull()][AllowEmptyString()][string]$CodexModelCachePath,
        $CodexModelListResponse,
        [AllowNull()][AllowEmptyString()][string]$ClaudeHelpText
    )

    if ($Provider -eq 'codex') {
        $providerContext = Resolve-DuoForgeProviderExecutionContextInternal -Provider codex
        if (-not $PSBoundParameters.ContainsKey('CodexModelCachePath')) {
            $CodexModelCachePath = Get-DuoForgeCodexModelCachePathInternal -ProviderContext $providerContext
        }
        $models = @()
        $catalogSource = 'codex-app-server'
        if ($PSBoundParameters.ContainsKey('CodexModelListResponse')) {
            $models = @(ConvertFrom-DuoForgeCodexModelListResponseInternal -Response $CodexModelListResponse)
            $catalogSource = 'codex-app-server-fixture'
        }
        elseif ($PSBoundParameters.ContainsKey('CodexModelCachePath')) {
            $models = @(Get-DuoForgeCodexModelsFromCacheInternal -CachePath $CodexModelCachePath)
            $catalogSource = 'codex-model-cache'
        }
        else {
            $models = @(Get-DuoForgeCodexModelsFromCliInternal -ProviderContext $providerContext)
        }
        if ($models.Count -eq 0 -and -not $PSBoundParameters.ContainsKey('CodexModelCachePath')) {
            $models = @(Get-DuoForgeCodexModelsFromCacheInternal -CachePath $CodexModelCachePath)
            $catalogSource = 'codex-model-cache-fallback'
        }
        if ($models.Count -eq 0) {
            $models = @(Get-DuoForgeCodexModelFallbackInternal)
            $catalogSource = 'built-in-fallback'
        }
        $recommendedModelObject = @($models | Where-Object { [bool]$_.recommended } | Select-Object -First 1)
        if ($recommendedModelObject.Count -eq 0) { $recommendedModelObject = @($models[0]) }
        $recommendedModel = [string]$recommendedModelObject[0].value
        $reasoningEfforts = @($models.reasoningEfforts | Select-Object -Unique)
        return [ordered]@{
            provider = 'codex'
            displayName = 'Codex'
            catalogSource = $catalogSource
            suggestedModels = $models
            recommendedModel = $recommendedModel
            recommendedReasoningEffort = [string]$recommendedModelObject[0].recommendedReasoningEffort
            reasoningEfforts = $reasoningEfforts
        }
    }

    $catalog = if ($PSBoundParameters.ContainsKey('ClaudeHelpText')) {
        ConvertFrom-DuoForgeClaudeHelpInternal -HelpText $ClaudeHelpText
    }
    else {
        Get-DuoForgeClaudeCatalogFromCliInternal -ProviderContext (Resolve-DuoForgeProviderExecutionContextInternal -Provider claude)
    }
    $catalogSource = 'claude-cli-help'
    if ($null -eq $catalog) {
        $catalog = Get-DuoForgeClaudeModelFallbackInternal
        $catalogSource = 'built-in-alias-fallback'
    }
    return [ordered]@{
        provider = 'claude'
        displayName = 'Claude'
        catalogSource = $catalogSource
        suggestedModels = @($catalog.models)
        recommendedModel = [string]$catalog.recommendedModel
        recommendedReasoningEffort = [string]$catalog.recommendedReasoningEffort
        reasoningEfforts = @($catalog.efforts)
    }
}

function Get-DuoForgeReasoningEffortsForModelInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Options,
        [AllowNull()][AllowEmptyString()][string]$Model
    )

    $known = @($Options.suggestedModels | Where-Object { [string]$_.value -ceq $Model } | Select-Object -First 1)
    if ($known.Count -eq 1 -and @($known[0].reasoningEfforts).Count -gt 0) {
        return @($known[0].reasoningEfforts)
    }
    return @($Options.reasoningEfforts)
}

function Get-DuoForgeRecommendedReasoningEffortForModelInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Options,
        [AllowNull()][AllowEmptyString()][string]$Model
    )

    $known = @($Options.suggestedModels | Where-Object { [string]$_.value -ceq $Model } | Select-Object -First 1)
    if ($known.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$known[0].recommendedReasoningEffort)) {
        return [string]$known[0].recommendedReasoningEffort
    }
    return [string]$Options.recommendedReasoningEffort
}

function Test-DuoForgeModelIdentifierInternal {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Model)

    if ([string]::IsNullOrWhiteSpace($Model)) { return $false }
    return $Model.Trim() -cmatch '^[A-Za-z0-9][A-Za-z0-9._:/\[\]-]{0,127}$'
}

function Test-DuoForgeProviderSelectionsInternal {
    [CmdletBinding()]
    param($Selections)

    $errors = [System.Collections.Generic.List[object]]::new()
    foreach ($provider in @('codex', 'claude')) {
        $options = Get-DuoForgeProviderSelectionOptionsInternal -Provider $provider
        $selection = Get-DuoForgeObjectValue -Object $Selections -Name $provider
        $model = [string](Get-DuoForgeObjectValue -Object $selection -Name 'model')
        $effort = [string](Get-DuoForgeObjectValue -Object $selection -Name 'reasoningEffort')

        if ([string]::IsNullOrWhiteSpace($model)) {
            $errors.Add([ordered]@{
                code = 'DF-PROVIDER-SELECTION-REQUIRED'
                message = "$($options.displayName) 모델을 반드시 선택해야 합니다."
            })
        }
        elseif (-not (Test-DuoForgeModelIdentifierInternal -Model $model)) {
            $errors.Add([ordered]@{
                code = 'DF-PROVIDER-MODEL'
                message = "$($options.displayName) 모델 식별자 형식이 올바르지 않습니다: $model"
            })
        }

        if ([string]::IsNullOrWhiteSpace($effort)) {
            $errors.Add([ordered]@{
                code = 'DF-PROVIDER-SELECTION-REQUIRED'
                message = "$($options.displayName) 분석 깊이를 반드시 선택해야 합니다."
            })
        }
        $supportedEfforts = @(Get-DuoForgeReasoningEffortsForModelInternal -Options $options -Model $model)
        if (-not [string]::IsNullOrWhiteSpace($effort) -and $effort -cnotin $supportedEfforts) {
            $errors.Add([ordered]@{
                code = 'DF-PROVIDER-EFFORT'
                message = "$($options.displayName) 모델 '$model'의 분석 깊이 '$effort'는 지원 목록에 없습니다: $($supportedEfforts -join ', ')"
            })
        }
    }

    return [ordered]@{
        valid = $errors.Count -eq 0
        errors = @($errors)
    }
}

function Assert-DuoForgeProviderSelectionsInternal {
    [CmdletBinding()]
    param($Selections)

    $validation = Test-DuoForgeProviderSelectionsInternal -Selections $Selections
    if (-not [bool]$validation.valid) {
        $first = $validation.errors[0]
        throw (New-DuoForgeException -Code ([string]$first.code) -Message (@($validation.errors.message) -join ' '))
    }
    return $Selections
}

function Get-DuoForgeRunProviderSelectionsInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory)

    $manifest = Read-DuoForgeJson -Path (Join-Path $RunDirectory 'manifest.json')
    $selections = Get-DuoForgeObjectValue -Object $manifest -Name 'providerSelections'
    return Assert-DuoForgeProviderSelectionsInternal -Selections $selections
}

function Read-DuoForgeModelChoiceInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('codex', 'claude')]
        [string]$Provider,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker,
        $SelectionOptions
    )

    $options = if ($null -ne $SelectionOptions) { $SelectionOptions } else { Get-DuoForgeProviderSelectionOptionsInternal -Provider $Provider }
    while ($true) {
        $layout = Get-DuoForgeDisplayLayoutInternal
        Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeFieldRowsInternal -Label '목록 출처' -Value ([string]$options.catalogSource) -Layout $layout -Indent 0 -KeyWidth 10 -Role 'meta') -Layout $layout
        if ([string]$options.catalogSource -like '*fallback*') {
            Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '현재 모델 목록을 읽지 못했습니다.' -Message '검증된 제한 목록으로 선택을 계속합니다.' -Layout $layout) -Layout $layout
        }
        Write-DuoForgeDisplaySpacerInternal -Layout $layout
        $items = [System.Collections.Generic.List[object]]::new()
        $recommendedIndex = 0
        for ($index = 0; $index -lt @($options.suggestedModels).Count; $index++) {
            $item = $options.suggestedModels[$index]
            $recommended = if ([bool]$item.recommended) { ' (권장)' } else { '' }
            $label = if ($Provider -eq 'claude') { '{0} ({1})' -f $item.displayName, $item.value } else { [string]$item.value }
            if ([bool]$item.recommended) { $recommendedIndex = $index }
            $items.Add([ordered]@{ value = "model:$index"; label = "$label$recommended"; detail = [string]$item.description; shortcuts = @([string]($index + 1)); enabled = $true })
        }
        $customNumber = @($options.suggestedModels).Count + 1
        $items.Add([ordered]@{ value = 'custom'; label = '모델명 직접 입력'; shortcuts = @([string]$customNumber); enabled = $true })
        $items.Add([ordered]@{ value = 'B'; label = '이전으로'; shortcuts = @('B'); enabled = $true })
        $choice = Invoke-DuoForgeMenuInternal -Items @($items) -Title ("{0} 모델을 선택해 주세요." -f $options.displayName) -EscapeValue 'B' -InitialSelectedIndex $recommendedIndex -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ($choice -ieq 'B') { return $null }
        if ($choice -like 'model:*') { return [string]$options.suggestedModels[[int]$choice.Substring(6)].value }
        if ($choice -eq 'custom') {
            $model = $(if ($null -ne $InputReader) { [string](& $InputReader 'CLI에 전달할 정확한 모델명') } else { [string](Read-Host 'CLI에 전달할 정확한 모델명') }).Trim()
            if (Test-DuoForgeModelIdentifierInternal -Model $model) { return $model }
            Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeNoticeRowsInternal -Kind warning -Title '모델명 형식이 올바르지 않습니다.' -Message '영문자나 숫자로 시작하고 영문자, 숫자, 점, 밑줄, 콜론, 슬래시, 대괄호, 하이픈만 사용할 수 있습니다.' -Layout $layout) -Layout $layout
            Write-DuoForgeDisplaySpacerInternal -Layout $layout
            continue
        }
    }
}

function Read-DuoForgeReasoningEffortChoiceInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('codex', 'claude')]
        [string]$Provider,
        [AllowNull()][AllowEmptyString()][string]$Model,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker,
        $SelectionOptions
    )

    $options = if ($null -ne $SelectionOptions) { $SelectionOptions } else { Get-DuoForgeProviderSelectionOptionsInternal -Provider $Provider }
    $reasoningEfforts = @(Get-DuoForgeReasoningEffortsForModelInternal -Options $options -Model $Model)
    $recommendedReasoningEffort = Get-DuoForgeRecommendedReasoningEffortForModelInternal -Options $options -Model $Model
    while ($true) {
        $items = [System.Collections.Generic.List[object]]::new()
        $recommendedIndex = 0
        for ($index = 0; $index -lt $reasoningEfforts.Count; $index++) {
            $recommended = if ([string]$reasoningEfforts[$index] -ceq [string]$recommendedReasoningEffort) { ' (권장)' } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($recommended)) { $recommendedIndex = $index }
            $items.Add([ordered]@{ value = [string]$reasoningEfforts[$index]; label = ([string]$reasoningEfforts[$index] + $recommended); shortcuts = @([string]($index + 1)); enabled = $true })
        }
        $items.Add([ordered]@{ value = 'B'; label = '이전으로'; shortcuts = @('B'); enabled = $true })
        $choice = Invoke-DuoForgeMenuInternal -Items @($items) -Title ("{0} 분석 깊이를 선택해 주세요. (모델: {1})" -f $options.displayName, $Model) -EscapeValue 'B' -InitialSelectedIndex $recommendedIndex -InputReader $InputReader -MenuInvoker $MenuInvoker
        if ($choice -ieq 'B') { return $null }
        return [string]$choice
    }
}

function Complete-DuoForgeInteractiveProviderSelectionsInternal {
    [CmdletBinding()]
    param(
        $InitialSelections,
        [scriptblock]$InputReader,
        [scriptblock]$MenuInvoker
    )

    $result = [ordered]@{}
    foreach ($provider in @('codex', 'claude')) {
        $existing = Get-DuoForgeObjectValue -Object $InitialSelections -Name $provider
        $model = [string](Get-DuoForgeObjectValue -Object $existing -Name 'model')
        $effort = [string](Get-DuoForgeObjectValue -Object $existing -Name 'reasoningEffort')
        $options = Get-DuoForgeProviderSelectionOptionsInternal -Provider $provider

        if (-not (Test-DuoForgeModelIdentifierInternal -Model $model)) {
            $model = Read-DuoForgeModelChoiceInternal -Provider $provider -InputReader $InputReader -MenuInvoker $MenuInvoker
            if ($null -eq $model) { return $null }
        }
        else {
            $layout = Get-DuoForgeDisplayLayoutInternal
            Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeFieldRowsInternal -Label ("{0} 모델" -f $options.displayName) -Value ([string]$model) -Layout $layout -KeyWidth 16) -Layout $layout
            Write-DuoForgeDisplaySpacerInternal -Layout $layout
        }

        $supportedEfforts = @(Get-DuoForgeReasoningEffortsForModelInternal -Options $options -Model $model)
        if ($effort -cnotin $supportedEfforts) {
            $effort = Read-DuoForgeReasoningEffortChoiceInternal -Provider $provider -Model $model -InputReader $InputReader -MenuInvoker $MenuInvoker
            if ($null -eq $effort) { return $null }
        }
        else {
            Write-DuoForgeDisplayRowsInternal -Rows @(New-DuoForgeFieldRowsInternal -Label ("{0} 분석 깊이" -f $options.displayName) -Value ([string]$effort) -Layout $layout -KeyWidth 16) -Layout $layout
            Write-DuoForgeDisplaySpacerInternal -Layout $layout
        }

        $result[$provider] = [ordered]@{
            model = $model
            reasoningEffort = $effort
        }
    }
    return $result
}
