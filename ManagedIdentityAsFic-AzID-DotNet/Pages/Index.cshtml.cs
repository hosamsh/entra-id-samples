using Azure.Identity;
using Azure.Security.KeyVault.Secrets;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Mvc;

namespace ManagedIdentityAsFic_AzID_DotNet.Pages;

public class IndexModel : PageModel
{
    private readonly IConfiguration _configuration;
    
    public string SecretFromSameTenantUsingMsiFic { get; private set; } = string.Empty;

    public string SecretFromAnotherTenantUsingMsiFic { get; private set; } = string.Empty;


    public IndexModel(IConfiguration configuration)
    {
        _configuration = configuration;
    }

    public async Task OnGetAsync()
    {
        // If the user is authenticated, fetch the secrets
        if (User.Identity == null || !User.Identity.IsAuthenticated)
        {
            // If not authenticated, trigger authentication
            await SignInUserAsync();
        }
        else
        {
            // load the secrets..
            SecretFromSameTenantUsingMsiFic = await GetSecretFromSameTenantUsingMsiFic();
            SecretFromAnotherTenantUsingMsiFic = await GetSecretFromAnotherTenantUsingMsiFic();
        }
    }    

    // This method triggers the OpenID Connect login flow
    private async Task SignInUserAsync()
    {
        // Trigger the OpenID Connect challenge (login flow)
        await HttpContext.ChallengeAsync(OpenIdConnectDefaults.AuthenticationScheme, new AuthenticationProperties
        {
            RedirectUri = Url.Page("/Index"), // Redirect to the same page after login,
            
        });
    }


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
        // we must request the managed identity token with the specified audience for federation to work.
        return (await miCredential.GetTokenAsync(new Azure.Core.TokenRequestContext([$"{audience}/.default"])).ConfigureAwait(false)).Token;
    }
    
    bool IsRunningLocally()
    {
        return HttpContext.Request.Host.Host == "localhost" || HttpContext.Request.Host.Host.StartsWith("127.0.0.") || HttpContext.Request.Host.Host == "::1";
    }
}
