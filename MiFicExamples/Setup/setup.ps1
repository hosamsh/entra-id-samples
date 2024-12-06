<#
.SYNOPSIS
This script automates the creation and configuration of Azure resources for a web application.

.DESCRIPTION
The script performs the following operations:
1. Logs into the Azure account and sets the specified subscription and tenant.
2. Creates a resource group in the specified location.
3. Provisions a storage account and container.
4. Creates a managed identity for secure access to resources.
5. Deploys an App Service Plan and Web App and assigns the managed identity to the Web App.
6. Registers an application in Azure AD, configures permissions, and creates a service principal.
7. Optionally creates an Azure Key Vault in the same or a different tenant and sets up access roles and a secret.
8. Configures a Federated Identity Credential for the application.
9. Generates `appsettings.json` for use in an ASP.NET Core application.

.NOTE
This script assumes you have sufficient permissions to create resources in the specified Azure subscription and tenant. 
If the script encounters any errors, it will terminate and provide diagnostic information.

.DISCLAIMER
Running this script will incur costs in your Azure subscription based on the resources provisioned (e.g., storage accounts, web apps, Key Vaults).
Ensure you review and understand the script's operations before proceeding.

.PARAMETERS
- TENANT: The Azure AD Tenant ID where the resources will be created.
- SUBSCRIPTION: The Azure Subscription ID under which resources will be provisioned.
- RESOURCE_PREFIX: A prefix for naming Azure resources (optional).
- LOCATION: The Azure region where resources will be created (optional).
- KV_TENANT: The Tenant ID for the Key Vault if it needs to be created in a different tenant.
- KV_SUBSCRIPTION: The Subscription ID for the Key Vault in a different tenant.

.EXAMPLE
.\setup.ps1 -TENANT 638eb391-a880-41f2-991a-274ff9c09f9b -SUBSCRIPTION a01f390d-3622-4cea-b985-2f43f5334f6e -RESOURCE_PREFIX "TPO1" -LOCATION northeurope

.EXAMPLE
.\setup.ps1 -TENANT 638eb391-a880-41f2-991a-274ff9c09f9b -SUBSCRIPTION a01f390d-3622-4cea-b985-2f43f5334f6e -RESOURCE_PREFIX "TPO1" -LOCATION northeurope -KV_TENANT a4604de3-e541-455b-8429-f53850a7c237 -KV_SUBSCRIPTION c8802953-fac5-44d5-a743-95e3f3a46c6f

#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$True, HelpMessage='Entra Tenant ID (Directory ID) that will be used to create the App Registration')]
    [string]$TENANT,

    [Parameter(Mandatory=$True, HelpMessage='Azure Subscription ID that will be used to create the resources. Must be created under the TENANT_ID')]
    [string]$SUBSCRIPTION,

    [Parameter(Mandatory=$False, HelpMessage='A prefix that will be used to name the resources')]
    [string]$RESOURCE_PREFIX,

    [Parameter(Mandatory=$False, HelpMessage='The Azure location where the resources will be created')]
    [string]$LOCATION,

    [Parameter(Mandatory=$True, HelpMessage='A different tenant to create the Key Vault in. Will create it in the same tenant as the other resources if not provided')]
    [string]$KV_TENANT,

    [Parameter(Mandatory=$True, HelpMessage='The subscription to create the keyvault in. Will create it in the same tenant as the other resources if not provided')]
    [string]$KV_SUBSCRIPTION
)

# Prompt user for confirmation
Write-Host "This script will create and configure multiple Azure resources, including:" -ForegroundColor Yellow
Write-Host "1. Resource groups, storage accounts, and containers." -ForegroundColor Cyan
Write-Host "2. Managed identities and App Services." -ForegroundColor Cyan
Write-Host "3. Azure AD applications and permissions." -ForegroundColor Cyan
Write-Host "4. (Optional) Key Vaults and secrets." -ForegroundColor Cyan
Write-Host ""
Write-Host "Note: This script may incur costs in your Azure subscription. Be sure to run the cleanup.ps1 after testing." -ForegroundColor Red
Write-Host ""

$proceed = Read-Host "Do you agree to proceed? (Yes/No)"
if ($proceed -notmatch "^(y|yes)$") {
    Write-Host "Script execution aborted." -ForegroundColor Red
    exit
}

# Proceed with the script execution
Write-Host "Starting the setup process..." -ForegroundColor Green

############## Step 1: Initial Setup ##############
Write-Host "Starting setup process..." -ForegroundColor Green

# Prerequisites: Login and set subscription
try {
    az account set --subscription $SUBSCRIPTION
    Write-Host "User is already signed in..."
}
catch {
    Write-Host "Logging into Azure..." -ForegroundColor Yellow
    Write-Host "Tenant id $TENANT" -ForegroundColor Green
    az login --tenant $TENANT
    Write-Host "Setting subscription $SUBSCRIPTION" -ForegroundColor Green
    az account set --subscription $SUBSCRIPTION
}

$USER_EMAIL = az ad signed-in-user show --query "userPrincipalName" -o tsv
$DOMAIN_NAME = $USER_EMAIL.Split('@')[1]

Write-Host "Welcome: $USER_EMAIL!" -ForegroundColor Cyan
Start-Sleep -Milliseconds 100

if (-not $RESOURCE_PREFIX) {
    $RESOURCE_PREFIX = Read-Host -Prompt "Please enter a prefix to use while naming created resources"
}
if (-not $LOCATION) {
    $LOCATION = Read-Host -Prompt "Please enter the location where the resources will be created"
}

Write-Host "Resource prefix: $RESOURCE_PREFIX"
Write-Host "Location: $LOCATION"

############## Step 2: Create a Resource Group ##############
Write-Host "Creating resource group..." -ForegroundColor Yellow
$RESOURCE_GROUP_NAME = $RESOURCE_PREFIX + "2RG"
az group create --name $RESOURCE_GROUP_NAME --location $LOCATION

############## Step 3: Create Storage Account and Container ##############
Write-Host "Creating storage account..." -ForegroundColor Yellow
$STORAGE_ACCOUNT_NAME = ($RESOURCE_PREFIX + "2SA").ToLower()
az storage account create --name $STORAGE_ACCOUNT_NAME --resource-group $RESOURCE_GROUP_NAME --location $LOCATION --sku Standard_LRS --kind StorageV2

Write-Host "Creating storage container..." -ForegroundColor Yellow
$CONTAINER_NAME = ($RESOURCE_PREFIX + "2Container").ToLower()
az storage container create --name $CONTAINER_NAME --account-name $STORAGE_ACCOUNT_NAME

############## Step 4: Create Managed Identity ##############
Write-Host "Creating managed identity..." -ForegroundColor Yellow
$MANAGED_IDENTITY_NAME = $RESOURCE_PREFIX + "2MI"
az identity create --name $MANAGED_IDENTITY_NAME --resource-group $RESOURCE_GROUP_NAME --location $LOCATION --subscription "${SUBSCRIPTION}"

$USER_ASSIGNED_CLIENT_ID = $(az identity show --resource-group $RESOURCE_GROUP_NAME --name $MANAGED_IDENTITY_NAME --query 'clientId' --output tsv)
$USER_ASSIGNED_RESOURCE_ID = $(az identity show --name $MANAGED_IDENTITY_NAME --resource-group $RESOURCE_GROUP_NAME --query id --output tsv)

############## Step 5: Create Web App and Assign Managed Identity ##############
Write-Host "Creating web app and app service plan..." -ForegroundColor Yellow
$APP_PLAN_NAME = $RESOURCE_PREFIX + "2AppPlan"
$WEB_APP_NAME = $RESOURCE_PREFIX + "2WebApp"

az appservice plan create --name $APP_PLAN_NAME --resource-group $RESOURCE_GROUP_NAME --sku FREE
az webapp create --name $WEB_APP_NAME --resource-group $RESOURCE_GROUP_NAME --plan $APP_PLAN_NAME

$WEB_APP_URL = "https://" + $(az webapp show --name $WEB_APP_NAME --resource-group $RESOURCE_GROUP_NAME --query "hostNames[0]" -o tsv)
az webapp identity assign --resource-group $RESOURCE_GROUP_NAME --name $WEB_APP_NAME --identities $USER_ASSIGNED_RESOURCE_ID

############## Step 6: Create App Registration ##############
Write-Host "Creating App Registration..." -ForegroundColor Yellow
$APP_REG_NAME = $RESOURCE_PREFIX + "2AppReg"
az ad app create --display-name $APP_REG_NAME --sign-in-audience "AzureADMultipleOrgs"
$APP_CLIENT_ID = $(az ad app list --display-name $APP_REG_NAME --query "[].{appId:appId}" -o tsv)

az ad sp create --id $APP_CLIENT_ID
$SP_OBJECT_ID = $(az ad sp show --id $APP_CLIENT_ID --query id -o tsv)

az ad app update --id $APP_CLIENT_ID --web-redirect-uris "$WEB_APP_URL/signin-oidc"

# enable idtoken issuance
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$SP_OBJECT_ID" --headers 'Content-Type=application/json' --body '{\""web\"":{\""implicitGrantSettings\"": {\""EnableIdTokenIssuance\"": true}}}'

# include the email claim in the ID token to support oidc authentication
az ad app update --set optionalClaims.idToken=@optional-claims-manifest.json --id $APP_CLIENT_ID

az ad app permission add --id $APP_CLIENT_ID --api "00000003-0000-0000-c000-000000000000" --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope
az ad app permission grant --id $APP_CLIENT_ID --api 00000003-0000-0000-c000-000000000000 --scope "User.Read"

az role assignment create --assignee $SP_OBJECT_ID --role "Storage Blob Data Contributor" --scope "/subscriptions/$SUBSCRIPTION/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"

############## Step 7: Key Vault Creation ##############
if (-not $KV_TENANT -or -not $KV_SUBSCRIPTION) {
    Write-Host "You have not provided a different subscription for keyvault. Will create it in the default subscription" -ForegroundColor Yellow

    #### 4. Create a key vault
    Write-Host "Creating Key Vault..." -ForegroundColor Yellow
    $KEYVAULT_NAME = $RESOURCE_PREFIX + "2KV"
    az keyvault create --name $KEYVAULT_NAME --resource-group $RESOURCE_GROUP_NAME --location $LOCATION --enable-rbac-authorization

    Write-Host "Assigning Key Vault admin role..." -ForegroundColor Yellow
    Start-Sleep -Milliseconds 500
    $KEYVAULT_RESOURCE_ID=$(az keyvault show --resource-group $RESOURCE_GROUP_NAME --name $KEYVAULT_NAME --query id --output tsv)
    az role assignment create --assignee "${USER_EMAIL}" --role "Key Vault Secrets Officer" --scope "${KEYVAULT_RESOURCE_ID}"

    az role assignment create --assignee $SP_OBJECT_ID --role "Key Vault Secrets User" --scope "/subscriptions/$SUBSCRIPTION/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.KeyVault/vaults/$KEYVAULT_NAME"

    Write-Host "Creating a secret in Key Vault..." -ForegroundColor Yellow
    $SECRET_NAME = $RESOURCE_PREFIX + "2SECRET"
    az keyvault secret set --vault-name $KEYVAULT_NAME --name $SECRET_NAME --value "This is a secret!"
}
else {
    Write-Host "Now creating a Key Vault in another tenant.. Please be ready to login to the other tenant." -ForegroundColor Yellow

    Start-Sleep -Milliseconds 500
    ## loging into the other tenant
    try {
        az account set --subscription $KV_SUBSCRIPTION
        Write-Host "User is already signed into the keyvault tenant..."
    }
    catch {
        Write-Host "Logging into Azure..." -ForegroundColor Yellow
        Write-Host "Key vault Tenant id $KV_TENANT" -ForegroundColor Green
        az login --tenant $KV_TENANT 
        Write-Host "setting subscription $KV_SUBSCRIPTION" -ForegroundColor Green
        az account set --subscription $KV_SUBSCRIPTION
    }

    $USER_EMAIL2 = az ad signed-in-user show --query "userPrincipalName" -o tsv
    $DOMAIN_NAME2 = $USER_EMAIL.Split('@')[1]

    Write-Host "$USER_EMAIL2 logged in successfully to $DOMAIN_NAME2!" -ForegroundColor Cyan
    Start-Sleep -Milliseconds 100

    
    #### 2. Create a resource group in the other tenant
    Write-Host "Creating resource group..." -ForegroundColor Yellow
    az group create --name $RESOURCE_GROUP_NAME --location $LOCATION

    #### 4. Create a key vault
    Write-Host "Creating Key Vault..." -ForegroundColor Yellow
    $KEYVAULT_NAME = $RESOURCE_PREFIX + "2KV"
    az keyvault create --name $KEYVAULT_NAME --resource-group $RESOURCE_GROUP_NAME --location $LOCATION --enable-rbac-authorization

    Write-Host "Assigning Key Vault admin role..." -ForegroundColor Yellow
    Start-Sleep -Milliseconds 500
    $KEYVAULT_RESOURCE_ID=$(az keyvault show --resource-group $RESOURCE_GROUP_NAME --name $KEYVAULT_NAME --query id --output tsv)
    az role assignment create --assignee "${USER_EMAIL2}" --role "Key Vault Secrets Officer" --scope "${KEYVAULT_RESOURCE_ID}"

    Write-Host "Creating a secret in the remote Key Vault..." -ForegroundColor Yellow
    $SECRET_NAME = $RESOURCE_PREFIX + "2SECRET"
    az keyvault secret set --vault-name $KEYVAULT_NAME --name $SECRET_NAME --value "This is a secret!"
}

############## Step 8: Create Federated Identity Credential ##############
Write-Host "Creating the Federated Identity Credential..." -ForegroundColor Yellow
Write-Host "Creating the Federated Identity Credential" -ForegroundColor Yellow

# Switch back to the original subscription
az account set --subscription $SUBSCRIPTION

$MANAGED_IDENTITY_PRINCIPAL_ID = $(az identity show --name $MANAGED_IDENTITY_NAME --resource-group $RESOURCE_GROUP_NAME --query "principalId" -o tsv)


# Define the JSON content as a PowerShell object
$jsonContent = @{
    name        = $RESOURCE_PREFIX + "2MiFic"
    issuer      = "https://login.microsoftonline.com/$Tenant/v2.0"
    subject     = "$MANAGED_IDENTITY_PRINCIPAL_ID"
    description = "Sample using Managed Identity as a federated identity credential (FIC)"
    audiences   = @("api://AzureADTokenExchange")
}

$jsonString = $jsonContent | ConvertTo-Json -Depth 2
$outputFilePath = "fic-credential-config.json"
Set-Content -Path $outputFilePath -Value $jsonString
Write-Host "JSON file generated successfully at: $outputFilePath" -ForegroundColor Green

az ad app federated-credential create --id $APP_CLIENT_ID --parameters fic-credential-config.json


############## Step 9: Generate appsettings.json ##############
Write-Host "Generating appsettings.json..." -ForegroundColor Yellow

# make sure the KV_TENANT is set
$KV_TENANT = $KV_TENANT ?? $TENANT

$appsettings = @{
    AzureAd = @{
        Instance = "https://login.microsoftonline.com/"
        Domain = "$DOMAIN_NAME"
        TenantId = "$TENANT"
        ClientId = "$APP_CLIENT_ID"
        CallbackPath = "/signin-oidc"
        ClientCredentials = @(
            @{
                SourceType = "SignedAssertionFromManagedIdentity"
                ManagedIdentityClientId = "$USER_ASSIGNED_CLIENT_ID"
                TokenExchangeUrl = "api://AzureADTokenExchange"
            }
        )
    }
    DownstreamApis = @{
        MicrosoftGraph = @{
            BaseUrl = "https://graph.microsoft.com/v1.0"
            RequestAppToken = $false
            Scopes = @("User.Read")
        }
    }
    AzureStorageConfig = @{
        AccountName = "$STORAGE_ACCOUNT_NAME"
        ContainerName = "$CONTAINER_NAME"
    }
    KeyVault = @{
        TenantId = "$KV_TENANT"
        Uri = "https://$KEYVAULT_NAME.vault.azure.net/"
        SecretName="$SECRET_NAME"
    }
    Logging = @{
        LogLevel = @{
            Default = "Information"
            Microsoft = "Warning"
            "Microsoft.Hosting.Lifetime" = "Information"
        }
    }
    AllowedHosts = "*"    
    MetadataOnly = @{
        WebAppName = "$WEB_APP_NAME"
        WebAppUrl = "$WEB_APP_URL"
        $APP_REG_NAME = "$APP_REG_NAME"
        StorageAccountName = "$STORAGE_ACCOUNT_NAME"
        ContainerName = "$CONTAINER_NAME"
        ManagedIdentityName = "$MANAGED_IDENTITY_NAME"
        FicIssuer = "https://login.microsoftonline.com/$Tenant/v2.0"
        KeyVaultTenantAdminConsentUrl = "https://login.microsoftonline.com/$KV_Tenant/adminconsent?client_id=$APP_CLIENT_ID"        
    }
}
$appsettingsJson = $appsettings | ConvertTo-Json -Depth 3
Set-Content -Path "..\appsettings.json" -Value $appsettingsJson
Write-Host $appsettingsJson -ForegroundColor Green
Write-Host "appsettings.json generated successfully!" -ForegroundColor Green

Write-Host "Setup complete!" -ForegroundColor Green


############## Step :10 build the code and deploy the app ##############
#dotnet publish --configuration Release --runtime win-x86 --self-contained false --output ./publish
#Compress-Archive -Path ./publish/* -DestinationPath ./package -force
#az webapp deployment source config-zip --resource-group $RESOURCE_GROUP_NAME --name $WEB_APP_NAME --src package.zip
# https://login.microsoftonline.com/{target_tenant_id}/adminconsent?client_id={your_app_id}&redirect_uri={redirect_uri}