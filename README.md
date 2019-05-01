# Sample concept Runbooks for WVD Persisent Desktops Scaling Script scenario

These are sample runbooks that would be used in conjunction with a web application that can trigger the actions described in the runbooks and coordinate user interface between these actions.

## Pre-requisites

* Azure Automation Account
* Powershell modules
  * Az.Accounts
  * Az.Resources
  * Az.Compute
  * Microsoft.RDInfra.RDPowershell
  * AzTable
  * Az.KeyVault
* Azure Key Vault 
* Storage Account General Purpose v2
* WVD Tenant Administrator Password
* A configured WVD Tenant and a Persistent Desktop Hostpool with Session Hosts
  
  >Note: for more information on how to use Az module within Azure automation please refer to [Az module support in Azure Automation](https://docs.microsoft.com/en-us/azure/automation/az-modules)

## High Level Configuration Steps

1. Create/Configure Azure Key Vault as follows
    * Create a Secret:
        * Name = Friendly Name of the WVD Tenant Admin (this name is referenced later in the table so it can be located)
        * Value = User password
    * Policy
        * You need to explicitly add the Service Principal that is executing your RunBooks (this can be located under the Connections configuration of the Automation Account)
1. Create a Storage Account General Purpose v2
1. Create a table named **WVDOffPeakInfo** within the storage account (you can use [Azure Storage Explorer](https://azure.microsoft.com/en-us/features/storage-explorer/) to have a nice UI to perform this operation)
1. Add a new row to the table with the following information, these are the properties your row must have and everything in **bold** is a mandatory value that cannot be changed, *italic* properties means table default system properties:

    | Property Name             | Type     | Sample Value                           | Description                                                                                       |
    |---------------------------|----------|----------------------------------------|---------------------------------------------------------------------------------------------------|
    | *PartitionKey*            | String   | HostPool01                             | WVD host pool name                                                                                |
    | *RowKey*                  | String   | **HostPoolInformation**                | This value must not be changed, the runbooks needs to find "HostPoolInformation"                  |
    | *TimeStamp*               | DateTime | <system timestamp>                     | Automatic generated value whenever you change the row                                             |
    | IsServicePrincipal        | Boolean  | false                                  | This boolean value indicates if the WVD Tenant Admin user is a service principal or not           |
    | KeyVaultName              | String   | YourKeyVault                           | Azure Key Vault name which holds the secret for the WVD Tenant Admin password                     |
    | KeyVaultSecretName        | String   | MyWVDAdminName                         | This is the name that will be located within Azure Key Vault to get the WVD Tenant Admin password |
    | RdBroker                  | String   | **https://rdbroker.wvd.microsoft.com** | This the WVD Service Broker URL, it must not be changed                                           |
    | TenantGroupName           | String   | My Tenant Group                        | WVD Tenant Group, usually companies will have only one, this is where the Hostpools are created.  |
    | Username                  | String   | wvdtenantadmin@contoso.com             | User Principal Name of the WVD Tenant Admin                                                       |
    | WVDTenantAdminAadTenantId | String   | 33323848-588d-48ac-a69c-be8b5100c86b   | Azure AD Tenant ID where the WVD Tenant Admin account exists                                      |
    | WVDTenantName             | String   | ContosoTenant                          | Name of the WVD Tenant                                                                            |

1. Create your Azure Automation Account
1. Add all required PS module to your Automation Account, start with Az.Accounts since all other modules depends on it.
1. Create a runbook for each of the PS1 files within this repo, for naming convention, name each runbook as the file name (do not add the .ps1)
1. Add one webwook for each runbook, for naming conventions, name each runbook as the runbook name (remove the '-'). **Important**, copy each URI and store it safely since they will never be displayed again)

>Note: Another table will be automatically created called **WVDRunBookJobs**, which will hold job return objects that can be later consumed by an application to help it make decisions.