<#
    .DESCRIPTION
        Sample Runbook that Gets Session Host VM Status based on user principal name in a WVD enabled environment
	.PARAMETER WebHookData
        JSON formated data to be passed from the webhook call.
		Format: {"WebHookName": "web hook name","RequestBody": [{"Secret": "secret value","Upn": "user principal name", "HostPoolName":"hostpool name", "StorageAccountRG":"storage account rg", "StorageAccountName": "storage account name", "SubscriptionId":"Subscription where storage/session hosts are located"}] }

		Example:
		{"WebHookName": "mywebhook","RequestBody": [{"Secret": "123","Upn": "wvduser01@pmcglobal.me", "HostPoolName":"Pool 2016 Persistent Desktop", "StorageAccountRG":"Support-RG", "StorageAccountName": "pmcstorage07", "SubscriptionId":"66bc9830-19b6-4987-94d2-0e487be7aa47"}] }
	.EXAMPLE
		Running from Powershell

		$params = @{"WebHookData"="{`"WebHookName`": `"mywebhook`",`"RequestBody`": [{`"Secret`": `"123`",`"Upn`": `"wvduser01@pmcglobal.me`", `"HostPoolName`":`"Pool 2016 Persistent Desktop`", `"StorageAccountRG`":`"Support-RG`", `"StorageAccountName`": `"pmcstorage07`", `"SubscriptionId`":`"<subscription id>`"}] }"}

		$result = Start-AzAutomationRunbook -Name "Get-SessionHostStatus" `
                                              -Parameters $params `
                                              -AutomationAccountName "pmcAutomation02" `
                                              -ResourceGroupName "automation-accounts" -Wait
	
	.EXAMPLE
		# Executing via WebHook

		$request = "{`"Secret`": `"123`",`"Upn`": `"wvduser01@pmcglobal.me`", `"HostPoolName`":`"Pool 2016 Persistent Desktop`", `"StorageAccountRG`":`"Support-RG`", `"StorageAccountName`": `"pmcstorage07`", `"SubscriptionId`":`"<subscription id>`"}"
		$uri = "https://s1events.azure-automation.net/webhooks?token=BbdRoXVlLu4QnjAAOPRvmx6uQOBSNcqEfXN%2f4IBMiM8%3d"
		$response = Invoke-WebRequest -Method Post -Uri $uri -Body $request
		
    .NOTES
        AUTHOR: Paulo Marques da Costa (MSFT)
        LASTEDIT: 04/30/2019
		RETURNS:
			It outputs a table entity with the following information:
				PartitionKey => Get-SessionHostStatus
				RowKey       => This is the job id that the webhook invocation got as result, this is the Azure Automation Runbook Job ID
				Result       => JSON string as follows:
									{
										"VMStatus":"<vm status info>",
										"VMName":"<Azure VM Name>"
									}
#>

	# WebHookURI : https://s1events.azure-automation.net/webhooks?token=BbdRoXVlLu4QnjAAOPRvmx6uQOBSNcqEfXN%2f4IBMiM8%3d

Import-Module Az.Accounts, Az.Resources, Az.Compute, Microsoft.RDInfra.RDPowershell, AzTable, Az.KeyVault | Out-Null

param
(
	[Parameter(Mandatory=$false)]
    [object] $WebHookData
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = "Stop"

# Functions
function GetSessionHostByUPN
{
    param
    (
        $HostPoolName,
        $TenantName,
        $Upn
    )

    $SessionHost = Get-RdsSessionHost -TenantName $TenantName -HostPoolName $HostPoolName | Where-Object { $_.AssignedUser -eq $UPN }

    return $SessionHost
}

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

	Write-Verbose  "Getting WVD Information"
	$ConfigurationRowKey = "HostPoolInformation"
	$WvdInfo = Get-AzTableRow -PartitionKey $RequestInfo.HostPoolName -RowKey $ConfigurationRowKey -Table $OffPeakTable

	if ($WvdInfo -eq $null)
	{
		Write-Error "Entity with RowKey named $ConfigurationRowKey is missing from table $OffPeakTableName, please make sure it exists with the following columns with the proper values -> WVDTenantAdminAadTenantId, KeyVaultName, KeyVaultSecretName, WVDTenantName, TenantGroupName, UserName, Rdbroker, IsWVDServicePrincipal"
	}

	Write-Verbose  "Building WVD credentials from KeyVault"
	$WVDPrincipalPwd = (Get-AzKeyVaultSecret -VaultName $WvdInfo.KeyVaultName -Name $WvdInfo.KeyVaultSecretName).SecretValue
	$WVDCreds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList($WvdInfo.Username, $WVDPrincipalPwd)

	Write-Verbose  "WVD Authentication"
	if (-Not $WvdInfo.IsWVDServicePrincipal)
	{
		try
		{
			Add-RdsAccount -DeploymentUrl $WvdInfo.RDBroker -Credential $WVDCreds | Out-Null
			Write-Verbose  "Authenticated as standard account for WVD."
		}
		catch
		{
			Write-Error "Failed to authenticate with WVD Tenant with a standard account: $($_.exception.message)" 
		}
	}
	else
	{
		try
		{
			Add-RdsAccount -DeploymentUrl $WvdInfo.RDBroker -TenantId $WvdInfo.WVDTenantAdminAadTenantId -Credential $WVDCreds -ServicePrincipal | Out-Null
			Write-Verbose  "Authenticated as service principal account for WVD."
		}
		catch
		{
			Write-Error "Failed to authenticate with WVD Tenant with the service principal: $($_.exception.message)" 
		}
	}

	Write-Verbose  "Switching RDS Context to the $tenantGroupName context"
	Set-RdsContext -TenantGroupName $WvdInfo.TenantGroupName | Out-Null
	    	
	Write-Verbose  "Getting Session Host by UPN"
	$SessionHost = GetSessionHostByUPN -HostPoolName $RequestInfo.HostPoolName -TenantName $WvdInfo.WVDTenantName -Upn $RequestInfo.Upn 

	if ($SessionHost -ne $null)
	{
		Write-Verbose  "SessionHost Name $SessionHost"

		try
		{
			$VMName = $SessionHost.SessionHostName.Split(".")[0]
			$roleInstance = Get-AzVM -Status -Name $VMName
			Write-Verbose  "SessionHost Status => $($RoleInstance.PowerState)"

			Add-AzTableRow -PartitionKey "Get-SessionHostStatus" -RowKey ($PsPrivateMetaData.JobId) -Property @{"Result"="{`"VMStatus`":`"$($roleInstance.PowerState)`", `"VMName`":`"$VMName`"}"} -Table $JobsResultTable | Out-Null
		}
		catch 
		{
			throw $_.exception
		}
	}
	else
	{
		Write-Verbose  "User $($RequestInfo.Upn) does not have an assigned desktop at host pool $($RequestInfo.HostPoolName)"	
	}
}
else
{
	Write-Verbose  "User information not found. Exiting."
}