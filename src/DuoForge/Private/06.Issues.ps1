function Get-DuoForgeIssueBlockingValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('critical', 'major', 'minor')]
        [string]$Severity,

        [Parameter(Mandatory)]
        [string]$Category,

        [bool]$RequiresUser,

        [bool]$BlockingProposal
    )

    if ($Severity -eq 'critical') { return $true }
    if ($Severity -eq 'minor') { return $false }
    if ($RequiresUser) { return $true }
    if ($Category -in @('safety', 'required-artifact', 'core-requirement', 'consistency')) { return $true }
    return $BlockingProposal
}

function Get-DuoForgeIssueTargetInternal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Issue)

    $targetDocumentId = [string](Get-DuoForgeObjectValue -Object $Issue -Name 'targetDocumentId' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($targetDocumentId)) { return $targetDocumentId }
    return [string](Get-DuoForgeObjectValue -Object $Issue -Name 'target' -Default '')
}

function New-DuoForgeIssueInternal {
    [CmdletBinding()]
    param(
        [object[]]$ExistingIssues = @(),

        [Parameter(Mandatory)]
        [ValidateRange(1, 3)]
        [int]$Round,

        [Parameter(Mandatory)]
        [ValidateSet('codex', 'claude', 'orchestrator', 'user')]
        [string]$RaisedBy,

        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [ValidateSet('critical', 'major', 'minor')]
        [string]$Severity,

        [Parameter(Mandatory)]
        [string]$Claim,

        [string]$Proposal,

        [bool]$RequiresUser = $false,

        [bool]$BlockingProposal = $false
    )

    $maximumId = 0
    foreach ($issue in @($ExistingIssues)) {
        $id = if ($issue -is [System.Collections.IDictionary]) { [string]$issue.issueId } else { [string]$issue.issueId }
        if ($id -match '^D-(\d+)$') {
            $maximumId = [Math]::Max($maximumId, [int]$Matches[1])
        }
    }
    $issueId = 'D-{0:D3}' -f ($maximumId + 1)
    $timestamp = Get-DuoForgeUtcNow
    $blocking = Get-DuoForgeIssueBlockingValue -Severity $Severity -Category $Category -RequiresUser $RequiresUser -BlockingProposal $BlockingProposal

    return [ordered]@{
        issueId = $issueId
        round = $Round
        raisedBy = $RaisedBy
        target = $Target
        category = $Category
        severity = $Severity
        claim = $Claim
        evidence = @()
        proposal = $Proposal
        responses = [ordered]@{}
        ownerDecisions = @()
        reviewerVerdicts = @()
        adoptions = @()
        requiresUser = $RequiresUser
        blockingProposals = [ordered]@{ $RaisedBy = $BlockingProposal }
        blocking = $blocking
        resolutionStatus = if ($RequiresUser) { 'AWAITING_USER' } else { 'OPEN' }
        history = @(
            [ordered]@{
                at = $timestamp
                event = 'CREATED'
                actor = $RaisedBy
                status = if ($RequiresUser) { 'AWAITING_USER' } else { 'OPEN' }
            }
        )
    }
}

function Test-DuoForgeCompletionAllowedInternal {
    [CmdletBinding()]
    param(
        [object[]]$Issues = @(),

        [switch]$AllowPartial
    )

    $blockingOpen = @($Issues | Where-Object {
        $blocking = if ($_ -is [System.Collections.IDictionary]) { [bool]$_['blocking'] } else { [bool]$_.blocking }
        $status = if ($_ -is [System.Collections.IDictionary]) { [string]$_['resolutionStatus'] } else { [string]$_.resolutionStatus }
        $blocking -and $status -notin @('RESOLVED', 'SUPERSEDED')
    })

    if ($blockingOpen.Count -eq 0) {
        return [ordered]@{ allowed = $true; status = 'COMPLETED'; blockingIssues = @() }
    }

    $containsCritical = @($blockingOpen | Where-Object {
        $severity = if ($_ -is [System.Collections.IDictionary]) { [string]$_['severity'] } else { [string]$_.severity }
        $severity -eq 'critical'
    }).Count -gt 0

    if ($AllowPartial -and -not $containsCritical) {
        return [ordered]@{
            allowed = $true
            status = 'COMPLETED_PARTIAL'
            blockingIssues = @($blockingOpen | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_['issueId'] } else { $_.issueId } })
        }
    }

    return [ordered]@{
        allowed = $false
        status = 'AWAITING_USER'
        blockingIssues = @($blockingOpen | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_['issueId'] } else { $_.issueId } })
    }
}
