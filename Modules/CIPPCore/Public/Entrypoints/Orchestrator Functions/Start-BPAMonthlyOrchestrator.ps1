function Start-BPAMonthlyOrchestrator {
    <#
    .SYNOPSIS
        Starts targeted monthly BPA runs without launching all tenants at once.
    .DESCRIPTION
        Checks which tenants are due for their monthly Best Practice Analyser run, queues
        a limited number of tenant-specific BPA orchestrations, and records queue state.
    .FUNCTIONALITY
        Entrypoint
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        $TenantFilter = 'AllTenants',
        [int]$MaxTenantsPerRun = 5,
        [int]$RerunIntervalDays = 30
    )

    try {
        $FeatureFlag = Get-CIPPFeatureFlag -Id 'BestPracticeAnalyser'
        if ($FeatureFlag -and $FeatureFlag.Enabled -eq $false) {
            Write-LogMessage -API 'BestPracticeAnalyser' -message 'Monthly BPA scheduler skipped because Best Practice Analyser is disabled via feature flag' -sev Info
            return $false
        }

        if ($MaxTenantsPerRun -lt 1) {
            $MaxTenantsPerRun = 1
        }

        if ($env:CIPP_BPA_MONTHLY_MAX_TENANTS -and $env:CIPP_BPA_MONTHLY_MAX_TENANTS -match '^\d+$') {
            $MaxTenantsPerRun = [int]$env:CIPP_BPA_MONTHLY_MAX_TENANTS
        }

        if ($env:CIPP_BPA_MONTHLY_RERUN_DAYS -and $env:CIPP_BPA_MONTHLY_RERUN_DAYS -match '^\d+$') {
            $RerunIntervalDays = [int]$env:CIPP_BPA_MONTHLY_RERUN_DAYS
        }

        $Now = (Get-Date).ToUniversalTime()
        $CurrentMonth = $Now.ToString('yyyy-MM')
        $RerunIntervalSeconds = [int64]$RerunIntervalDays * 86400

        if ($TenantFilter -ne 'AllTenants') {
            if ($TenantFilter -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
                $TenantList = @(Get-Tenants -TenantFilter $TenantFilter)
            } else {
                $TenantList = @(Get-Tenants | Where-Object { $_.defaultDomainName -eq $TenantFilter -or $_.customerId -eq $TenantFilter })
            }
        } else {
            $TenantList = @(Get-Tenants)
        }

        if (($TenantList | Measure-Object).Count -eq 0) {
            Write-Information 'Monthly BPA scheduler found no tenants to evaluate'
            return 0
        }

        $StateTable = Get-CippTable -TableName 'BPAScheduleState'
        $StateRows = @(Get-CIPPAzDataTableEntity @StateTable -Filter "PartitionKey eq 'MonthlyBPA'")

        $DueTenants = foreach ($Tenant in $TenantList) {
            $TenantDomain = $Tenant.defaultDomainName
            $TenantId = $Tenant.customerId ?? $TenantDomain
            if (!$TenantDomain -or !$TenantId) {
                continue
            }

            $HashInput = [System.Text.Encoding]::UTF8.GetBytes([string]$TenantId)
            $Hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($HashInput)
            $AssignedDay = ([System.BitConverter]::ToUInt32($Hash, 0) % 28) + 1
            $State = $StateRows | Where-Object { $_.RowKey -eq $TenantId } | Select-Object -First 1
            $AlreadyQueuedThisMonth = $State.LastQueuedMonth -eq $CurrentMonth

            # Run tenants on their assigned day, with a month-end catch-up window.
            $DueToday = $AssignedDay -le $Now.Day -or $Now.Day -ge 28
            if ($DueToday -and !$AlreadyQueuedThisMonth) {
                [PSCustomObject]@{
                    TenantDomain = $TenantDomain
                    TenantId     = $TenantId
                    AssignedDay  = [int]$AssignedDay
                    LastQueued   = $State.LastQueuedUtc ?? ''
                }
            }
        }

        $DueTenants = @($DueTenants | Sort-Object AssignedDay, TenantDomain | Select-Object -First $MaxTenantsPerRun)
        if (($DueTenants | Measure-Object).Count -eq 0) {
            Write-Information 'Monthly BPA scheduler found no tenants due for BPA today'
            return 0
        }

        if ($PSCmdlet.ShouldProcess("Monthly BPA for $($DueTenants.Count) tenant(s)", 'Queue tenant-targeted BPA orchestrations')) {
            foreach ($Tenant in $DueTenants) {
                Write-LogMessage -API 'BestPracticeAnalyser' -tenant $Tenant.TenantDomain -message "Queueing monthly BPA for $($Tenant.TenantDomain)" -sev Info
                $OrchestratorId = Start-BPAOrchestrator -TenantFilter $Tenant.TenantDomain -RerunIntervalSeconds $RerunIntervalSeconds

                $StateEntity = @{
                    PartitionKey       = 'MonthlyBPA'
                    RowKey             = [string]$Tenant.TenantId
                    Tenant             = [string]$Tenant.TenantDomain
                    AssignedDay        = [int]$Tenant.AssignedDay
                    LastQueuedUtc      = [string]$Now.ToString('o')
                    LastQueuedMonth    = [string]$CurrentMonth
                    LastOrchestratorId = [string]$OrchestratorId
                    Status             = 'Queued'
                }
                Add-CIPPAzDataTableEntity @StateTable -Entity $StateEntity -Force
            }
        }

        return $DueTenants.Count
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -API 'BestPracticeAnalyser' -message "Could not run monthly BPA scheduler: $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
        return $false
    }
}
