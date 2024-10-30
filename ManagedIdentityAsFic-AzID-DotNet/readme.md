# Configure an App to Trust a Managed Identity

## Overview
This sample demonstrates how to configure an Azure-hosted application to authenticate securely using a user-assigned managed identity, avoiding the need for direct credential management. You’ll set up Azure Key Vault, manage identities, and securely access secrets with Azure CLI.

Refer to this article for detailed guidance on [Configure an App to trust a Managed Identity](config-guide.md)

---

## Prerequisites
- You need an Azure subscription to create resources and deploy your app. If you don't already have an Azure account, [sign up for a free account](https://azure.microsoft.com/free/) before you continue.
- Permissions to create resources in Azure (Key Vault, App Registration, Managed Identity, Web App)
- If you want to test the cross-tenant scenario, you need a second Azure subscription.
- Install Azure CLI to run the setup script in the next section if needed.

## Environment Setup
To run the full sample, you need to create the following resources:
-  An App Registration. Your app should be multitenant if you are testing cross-tenant auth.
- An App Service or a VM to host the application code on Azure.
- A User-Assigned Managed Identity assigned to the App Service or VM.
- A KeyVault and a secret that the application code will retreive.
- A second KeyVault in a different tenant if you are testing cross-tenant authentication.

The below script can be used to setup the environment:

   ```bash
   # Define variables
   $RESOURCE_GROUP="Resource Group name that this script will create"
   $AZURE_LOCATION="northeurope"
   $VAULT1_NAME="yourKeyVaultName"
   $APP_NAME="yourAppName"
   $SECRET_NAME="mySecret"
   $SUBSCRIPTION1="your first subscription where you are creating the App Registration, and hosting the workload's code"
   $APP_PLAN_NAME="yourAppPlanName"
   $WEBAPP_NAME="yourWebAppName"
   $USER_ASSIGNED_ID_NAME="yourUserAssignedIdentityName"
   $SUBSCRIPTION2="optional second subscription to test cross-tenant auth"
   $VAULT2_NAME="An optional second KeyVault to test in cross-tenant auth"
   
   # First, login to Azure
   az login

   # Make sure you're using the right suscription
   az account set --subscription ${SUBSCRIPTION1}

   # Create a new resource group for this test
   az group create --name $RESOURCE_GROUP --location northeurope

   # Create Key Vault and secret
   az keyvault create --name $VAULT1_NAME --resource-group RESOURCE_GROUP --location $AZURE_LOCATION --enable-rbac-authorization

   az keyvault secret set $VAULT_NAME --name $SECRET_NAME --value "THIS IS the secret!"

   # Register app in Entra ID
   $APP_CLIENT_ID =$(az ad app create --display-name $APP_NAME --query "[].{appId:appId}" -o tsv)
    
    az ad sp create --id $APP_CLIENT_ID 
    $SP_OBJECT_ID=$(az ad sp show --id $APP_CLIENT_ID   --query id --output tsv)

    az ad app permission add --id $APP_CLIENT_ID --api 00000003-0000-0000-c000-000000000000 --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope
    
    az role assignment create --role "Key Vault Secrets User" --assignee $SP_OBJECT_ID --scope /subscriptions/$SUBSCRIPTION1/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$VAULT_NAME


   # Create a Web App to host the application and update the auth redirect URL
    az appservice plan create --name $APP_PLAN_NAME --resource-group $RESOURCE_GROUP --sku FREE

    az webapp create --name $WEBAPP_NAME --resource-group $RESOURCE_GROUP --plan $APP_PLAN_NAME
    
    $WEB_APP_HOST_NAME=$(az webapp show --name $WEB_APP_NAME --resource-group $RESOURCE_GROUP --query defaultHostName -o tsv)

    az ad app update --id $APP_CLIENT_ID --web-redirect-uris "$WEB_APP_HOST_NAME/signin-oidc"

    # Create a managed identity and assign to the Web App
    az identity create    --name $USER_ASSIGNED_ID_NAME    --resource-group $RESOURCE_GROUP     --location northeurope     --subscription "${SUBSCRIPTION1}"

    $USER_ASSIGNED_CLIENT_ID=$(az identity show  --resource-group $RESOURCE_GROUP     --name $USER_ASSIGNED_ID_NAME --query 'clientId'     --output tsv)

    $USER_ASSIGNED_RESOURCE_ID=$(az identity show --name $USER_ASSIGNED_ID_NAME --resource-group HosamRG --query id --output tsv)

    az webapp identity assign --resource-group $RESOURCE_GROUP --name $WEBAPP_NAME --identities $USER_ASSIGNED_RESOURCE_ID

```

## Clone or download sample web application
To obtain the sample application, you can either clone it from GitHub or download it as a .zip file.

To clone the sample, open a command prompt and navigate to where you wish to create the project, and enter the following command:

``` shell
git clone https://github.com/hosamsh/entra-id-samples/ManagedIdentityAsFic-AzID-DotNet.git
```
Download the .zip file. Extract it to a file path where the length of the name is fewer than 260 characters.


## Configure the application
Navigate to the root folder of the sample you have downloaded and directory that contains the ASP.NET Core sample app:

cd ManagedIdentityAsFic-AzID-DotNet
Open the appsettings.json file and replace text between `< >` with your tenant, App, Managed Identity details.

    "TenantId": "<TenantID that both your Entra App and Managed Identity are associated with>",
    "ClientId": "<Your Entra App Client ID>",
    "IsMultiTenant": "true",
    "MsiClientId": "<Your User Assigned Managed Identity Client ID>",
    "CallbackPath": "</signin-oidc>"

Next, update the two KeyVault settings 
  "KeyVaultInTheSameTenant": {
    "TenantId": "<the tenant where the App Reg and Managed Identity are created>",
    "VaultUri": "https://<keyvault-name>.vault.azure.net/",
    "SeretName": "<secret-name>"
  },
  "KeyVaultInAnotherTenant": {
    "TenantId": "<a second tenant to test cross-tenant auth>",
    "VaultUri": "https://<keyvault-name>.vault.azure.net/",
    "SeretName": "<secret-name>"
  }

## Deploy the sample on Azure and run the application
From your shell or command line, navigate to the folder where the sample is created execute the following commands:

``` bash
# Build and publish the application. Use win-x86 as the Free Teir Web App created eariler only supports x86.
dotnet publish --configuration Release --runtime win-x86 --self-contained false --output ./publish

# Compress the published folder to a .zip file
Compress-Archive -Path ./publish/* -DestinationPath ./package -force

# Deploy it to the web app
az webapp deployment source config-zip --resource-group $RESOURCE_GROU_NAME --name $WEB_APP_NAME --src package.zip
```
Now point your browser to the web application's default host. You will be prompted to login. You should see the KeyVault secrets loaded afterwards.

## Inspect the code
The two key functions used to acquire the Managed Identity token and use it for accessing the KeyVault are `GetSecretFromSameTenantUsingMsiFic` and `GetSecretFromAnotherTenantUsingMsiFic`

   ```c#
    public async Task<string> GetSecretFromSameTenantUsingMsiFic()
    {
        if (IsRunningLocally())
        {
            return "This feature is not supported when running the app locally.";
        }        
        try
        {
            var keyVaultUri = _configuration["KeyVaultInTheSameTenant:VaultUri"];
            var secretName = _configuration["KeyVaultSameTenant:SeretName"];
            var keyVaultTenantId = _configuration["KeyVaultInAnotherTenant:ThisTenantId"];
            var clientId = _configuration["AzureAd:ClientId"];
            var msiClientId = _configuration["AzureAd:MsiClientId"];

            string audience = "api://AzureADTokenExchange";

            var miCredential = new ManagedIdentityCredential(msiClientId);

            ClientAssertionCredential assertion = new(
                keyVaultTenantId,
                clientId,
                async (token) => await GetManagedIdentityToken(miCredential, audience));

            if (string.IsNullOrEmpty(keyVaultUri))
            {
                throw new ArgumentNullException(nameof(keyVaultUri), "KeyVault URI cannot be null or empty.");
            }
            // Create a new SecretClient using the assertion
            var secretClient = new SecretClient(new Uri(keyVaultUri), assertion);

            // Retrieve the secret
            KeyVaultSecret secret = await secretClient.GetSecretAsync(secretName);

            return secret.Value;
        }
        catch (Exception ex)
        {
            return $"Error fetching secret from the same tenant: {ex.Message}";
        }
    }

    public async Task<string> GetSecretFromAnotherTenantUsingMsiFic()
    {
        if (IsRunningLocally())
        {
            return "This feature is not supported when running the app locally.";
        }
        
        try
        {
            var keyVaultUri = _configuration["KeyVaultInAnotherTenant:VaultUri"];
            var secretName = _configuration["KeyVaultInAnotherTenant:SeretName"];
            var keyVaultTenantId = _configuration["KeyVaultInAnotherTenant:ThisTenantId"];
            var clientId = _configuration["AzureAd:ClientId"];
            
            var msiClientId = _configuration["AzureAd:MsiClientId"];

            string audience = "api://AzureADTokenExchange";
            var miCredential = new ManagedIdentityCredential(msiClientId);

            ClientAssertionCredential assertion = new(                
                keyVaultTenantId, // note that this value must be the keyvault's tenant id
                clientId,
                async (token) => await GetManagedIdentityToken(miCredential, audience));
            
            if (string.IsNullOrEmpty(keyVaultUri))
            {
                throw new ArgumentNullException(nameof(keyVaultUri), "KeyVault URI cannot be null or empty.");
            }
            // Create a new SecretClient using the assertion
            var secretClient = new SecretClient(new Uri(keyVaultUri), assertion);

            // Retrieve the secret
            KeyVaultSecret secret = await secretClient.GetSecretAsync(secretName);

            return secret.Value;
        }
        catch (Exception ex)
        {
            return $"Error fetching secret from the other tenant: {ex.Message}";
        }
    }
    
    static async Task<string> GetManagedIdentityToken(ManagedIdentityCredential miCredential, string audience)
    {
        return (await miCredential.GetTokenAsync(new Azure.Core.TokenRequestContext([$"{audience}/.default"])).ConfigureAwait(false)).Token;
    }
    
    ```
