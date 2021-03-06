<#
    .DESCRIPTION
        Sample Runbook that Starts Session Host VM
	.PARAMETER WebHookData
        JSON formated data to be passed from the webhook call.
		Format: {"WebHookName": "web hook name","RequestBody": [{"Secret": "secret value","Upn": "user principal name", "HostPoolName":"hostpool name", "VMName":"Session Host VM Name", "StorageAccountRG":"storage account rg", "StorageAccountName": "storage account name", "SubscriptionId":"Subscription where storage/session hosts are located"}] }

		Example:
		{"WebHookName": "mywebhook","RequestBody": [{"Secret": "123","Upn": "wvduser01@pmcglobal.me", "HostPoolName":"Pool 2016 Persistent Desktop", "VMName":"RDSH-PD-2", "StorageAccountRG":"Support-RG", "StorageAccountName": "pmcstorage07", "SubscriptionId":"66bc9830-19b6-4987-94d2-0e487be7aa47"}] }
	.EXAMPLE
		Running from Powershell

		$params = @{"WebHookData"="{`"WebHookName`": `"mywebhook`",`"RequestBody`": [{`"Secret`": `"123`",`"Upn`": `"wvduser01@pmcglobal.me`", `"HostPoolName`":`"Pool 2016 Persistent Desktop`", `"VMName`":`"RDSH-PD-2`", `"StorageAccountRG`":`"Support-RG`", `"StorageAccountName`": `"pmcstorage07`", `"SubscriptionId`":`"<subscription id>`"}] }"}

		$result = Start-AzAutomationRunbook -Name "Start-SessionHost" `
                                              -Parameters $params `
                                              -AutomationAccountName "pmcAutomation02" `
                                              -ResourceGroupName "automation-accounts" -Wait

	.EXAMPLE
		# Executing via WebHook

		$request = "{`"Secret`": `"123`",`"Upn`": `"wvduser01@pmcglobal.me`", `"HostPoolName`":`"Pool 2016 Persistent Desktop`", `"VMName`":`"RDSH-PD-2`", `"StorageAccountRG`":`"Support-RG`", `"StorageAccountName`": `"pmcstorage07`", `"SubscriptionId`":`"<subscription id>`"}"
		$uri = "https://s1events.azure-automation.net/webhooks?token=<token>"
		$response = Invoke-WebRequest -Method Post -Uri $uri -Body $request


    .NOTES
        AUTHOR: Paulo Marques da Costa (MSFT)
        LASTEDIT: 04/30/2019
		RETURNS:
			It outputs a table entity with the following information:
				PartitionKey => Start-SessionHost
				RowKey       => This is the job id that the webhook invocation got as result, this is the Azure Automation Runbook Job ID
				Result       => JSON string as follows:
									{
										"VMStatus":"<vm status info>",
										"VMName":"<Azure VM Name>"
									}

#>
param
(
	[Parameter(Mandatory=$false)]
    [object] $WebHookData
)

Import-Module Az.Accounts, Az.Resources, Az.Compute, AzTable | Out-Null

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = "Stop"

# Functions

# Main Script

Write-Verbose  "Basic checks"
if (-Not $WebHookData)
{
	Write-Error "WebHookData cannot be null"
}

if (-Not $WebhookData.RequestBody)
{
	$WebHookData = (ConvertFrom-Json -InputObject $WebhookData)
	$RequestInfo =  $WebhookData.RequestBody
}
else
{
	$RequestInfo =  (ConvertFrom-Json -InputObject $WebhookData.RequestBody)
}

if (($RequestInfo.Secret -eq $null) -or 
	($RequestInfo.Upn -eq $null) -or
	($RequestInfo.HostPoolName -eq $null) -or
	($RequestInfo.VMName -eq $null) -or
	($RequestInfo.StorageAccountRG -eq $null) -or
	($RequestInfo.StorageAccountName -eq $null)  -or
	($RequestInfo.SubscriptionId -eq $null))
{
	Write-Error "Required information missing"
}

Write-Verbose  "Performing Azure Authentication"
$connectionName = "AzureRunAsConnection"
try
{
	# Get the connection "AzureRunAsConnection "
	$servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         

	Add-AzAccount `
		-ServicePrincipal `
		-TenantId $servicePrincipalConnection.TenantId `
		-ApplicationId $servicePrincipalConnection.ApplicationId `
		-CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint | Out-Null
}
catch
{
	if (!$servicePrincipalConnection)
	{
		$ErrorMessage = "Connection $connectionName not found."
		throw $ErrorMessage
	}
	else
	{
		Write-Error -Message $_.Exception
		throw $_.Exception
	}
}

write-output "$($PsPrivateMetaData | ConvertTo-Json -Depth 99)"

Write-Verbose  "Selecting subscription where Storge Account and Session Hosts are located"
Select-AzSubscription -SubscriptionId $RequestInfo.SubscriptionId | Out-Null

$OffPeakTableName = "WVDOffPeakInfo"
$OffPeakTable = Get-AzTableTable -resourceGroup $RequestInfo.StorageAccountRG -TableName $OffPeakTableName -storageAccountName $RequestInfo.StorageAccountName

$JobsTableName = "WVDRunBookJobs"
$JobsResultTable = Get-AzTableTable -resourceGroup $RequestInfo.StorageAccountRG -TableName $JobsTableName -storageAccountName $RequestInfo.StorageAccountName

if ($OffPeakTable -eq $null) 
{
    Write-Error "An error ocurred trying to obtain table $OffPeakTable in Storage Account $($RequestInfo.StorageAccountName) at Resource Group $($RequestInfo.StorageAccountRG)"
}

if ($JobsResultTable -eq $null) 
{
    Write-Error "An error ocurred trying to obtain table $JobsTableName in Storage Account $($RequestInfo.StorageAccountName) at Resource Group $($RequestInfo.StorageAccountRG)"
}

Write-Verbose  "Before proceeding, check if request secret matches table secret"
$RowKey = $RequestInfo.Upn

$UserEntity = Get-AzTableRow -PartitionKey $RequestInfo.HostPoolName -RowKey $RequestInfo.Upn -Table $OffPeakTable

if ($UserEntity -ne $null)
{
	Write-Verbose  "Check received secret against table"
	if (($null -eq [string]::IsNullOrEmpty($UserEntity.Secret)) -or $UserEntity.Secret -ne $RequestInfo.Secret)
	{
		Write-Error "Information mismatch"
	}

	if ($RequestInfo.VMName -ne $null)
	{
		try
		{
			$roleInstance = Get-AzVM -Status -Name $RequestInfo.VMName
			$VmName = $roleInstance.Name

			if ($roleInstance.PowerState -eq "VM running")
            {
				Write-Verbose "SessionHost already running"
			}
			else
			{
				Write-Verbose "Starting SessionHost $($VmName)"
				Start-AzVM -Name $VmName -Id $roleInstance.Id
				
				$isInstanceReady = $false
				$retries = 0
				$instance = $null

				while (!$isInstanceReady -and $retries -le 9)
				{
					$roleInstance = Get-AzVM -Status -Name $VmName
					if ($roleInstance.PowerState -eq "VM running" -and $roleInstance.ProvisioningState -eq "Succeeded")
					{
						$isInstanceReady = $true
					}

					$retries++

					Start-Sleep -Seconds 30
				}
			}

			Add-AzTableRow -PartitionKey "Start-SessionHost" -RowKey ($PsPrivateMetaData.JobId) -Property @{"Result"="{`"VMStatus`":`"$($roleInstance.PowerState)`", `"VMName`":`"$($roleInstance.Name)`"}"} -Table $JobsResultTable | Out-Null
		}
		catch 
		{
			throw $_.exception
		}
	}
	else
	{
		Write-Verbose  "VM Name cannot be null."	
	}
}
else
{
	Write-Verbose  "User information not found. Exiting."
}