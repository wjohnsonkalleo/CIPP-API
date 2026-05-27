function Invoke-PublicWebhooks {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Public
    #>
    param($Request, $TriggerMetadata)
    $Headers = $Request.Headers
    Write-Host 'Received request'
    $url = ($Headers.'x-ms-original-url').split('/API') | Select-Object -First 1
    $CIPPURL = [string]$url
    Write-Host $url

    if ($Request.Query.ValidationToken) {
        Write-Host 'Validation token received - query ValidationToken'
        $body = $Request.Query.ValidationToken
        $StatusCode = [HttpStatusCode]::OK
    } elseif ($Request.Body.validationCode) {
        Write-Host 'Validation token received - body validationCode'
        $body = $Request.Body.validationCode
        $StatusCode = [HttpStatusCode]::OK
    } elseif ($Request.Query.validationCode) {
        Write-Host 'Validation token received - query validationCode'
        $body = $Request.Query.validationCode
        $StatusCode = [HttpStatusCode]::OK
    } elseif ($Request.Query.CIPPID) {
        $WebhookTable = Get-CIPPTable -TableName webhookTable
        $Webhookinfo = Get-CIPPAzDataTableEntity @WebhookTable -Filter "RowKey eq '$($Request.Query.CIPPID)'" -First 1
        if (-not $Webhookinfo) {
            Write-Host "No matching CIPPID found: $($Request.Query.CIPPID)"
            $Body = 'This webhook is not authorized.'
            $StatusCode = [HttpStatusCode]::Forbidden
        } elseif ($Webhookinfo.Resource -eq 'M365AuditLogs') {
            Write-Host "Found M365AuditLogs - This is an old entry, we'll deny so Microsoft stops sending it."
            $Body = 'This webhook is not authorized, its an old entry.'
            $StatusCode = [HttpStatusCode]::Forbidden
        } else {
            Write-Host 'Found matching CIPPID'
            $WebhookIncoming = Get-CIPPTable -TableName WebhookIncoming
            $GetWebhookRowKey = {
                param($WebhookType, $CippId, $WebhookData)
                $WebhookJson = $WebhookData | ConvertTo-Json -Depth 20 -Compress
                $HashInput = [System.Text.Encoding]::UTF8.GetBytes("$WebhookType|$CippId|$WebhookJson")
                $Hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($HashInput)
                $HashString = [System.BitConverter]::ToString($Hash).Replace('-', '').ToLowerInvariant()
                return "$WebhookType-$HashString"
            }

            if ($Request.Query.Type -eq 'GraphSubscription') {
                # Graph Subscriptions
                [pscustomobject]$ReceivedItem = $Request.Body.value
                $WebhookData = [string]($ReceivedItem | ConvertTo-Json -Depth 10)
                $Entity = [PSCustomObject]@{
                    PartitionKey = 'Webhook'
                    RowKey       = [string](& $GetWebhookRowKey -WebhookType $Request.Query.Type -CippId $Request.Query.CIPPID -WebhookData $ReceivedItem)
                    Type         = $Request.Query.Type
                    Data         = $WebhookData
                    CIPPID       = $Request.Query.CIPPID
                    WebhookInfo  = [string]($WebhookInfo | ConvertTo-Json -Depth 10)
                    FunctionName = 'PublicWebhookProcess'
                }
                Add-CIPPAzDataTableEntity @WebhookIncoming -Entity $Entity -Force

            } elseif ($Request.Query.Type -eq 'PartnerCenter') {
                [pscustomobject]$ReceivedItem = $Request.Body
                $WebhookData = [string]($ReceivedItem | ConvertTo-Json -Depth 10)
                $Entity = [PSCustomObject]@{
                    PartitionKey = 'Webhook'
                    RowKey       = [string](& $GetWebhookRowKey -WebhookType $Request.Query.Type -CippId $Request.Query.CIPPID -WebhookData $ReceivedItem)
                    Type         = $Request.Query.Type
                    Data         = $WebhookData
                    CIPPID       = $Request.Query.CIPPID
                    WebhookInfo  = [string]($WebhookInfo | ConvertTo-Json -Depth 10)
                    FunctionName = 'PublicWebhookProcess'
                }
                Add-CIPPAzDataTableEntity @WebhookIncoming -Entity $Entity -Force
            } else {
                $Body = 'This webhook is not authorized.'
                $StatusCode = [HttpStatusCode]::Forbidden
            }
            $Body = 'Webhook Received'
            $StatusCode = [HttpStatusCode]::OK
        }

    } else {
        $Body = 'This webhook is not authorized.'
        $StatusCode = [HttpStatusCode]::Forbidden
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
