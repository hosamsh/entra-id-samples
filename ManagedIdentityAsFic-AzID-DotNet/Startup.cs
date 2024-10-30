using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.IdentityModel.Tokens;

public class Startup
{
    public IConfiguration Configuration { get; }

    public Startup(IConfiguration configuration)
    {
        Configuration = configuration;
    }

    // This method gets called by the runtime. Use this method to add services to the container.
    public void ConfigureServices(IServiceCollection services)
    {
        services.AddRazorPages();
        services.AddHttpClient();

        // // Register the authentication services, including OpenID Connect and cookies
        // services.AddAuthentication(OpenIdConnectDefaults.AuthenticationScheme)
        //         .AddMicrosoftIdentityWebApp(Configuration.GetSection("AzureAd"));

        // // Register IHttpContextAccessor
        // services.AddHttpContextAccessor();

        // Add OpenID Connect and Cookie Authentication
        services.AddAuthentication(options =>
        {
            // Set the default authentication scheme to cookies
            options.DefaultScheme = CookieAuthenticationDefaults.AuthenticationScheme;
            options.DefaultSignInScheme = CookieAuthenticationDefaults.AuthenticationScheme;
            options.DefaultChallengeScheme = OpenIdConnectDefaults.AuthenticationScheme;  // Use OIDC for challenge
            
        })
        .AddCookie() // Add Cookie Authentication
        .AddOpenIdConnect(OpenIdConnectDefaults.AuthenticationScheme, options =>
        {
            if (Configuration["AzureAd:IsMulti"] == "true")
            {
                options.Authority = $"{Configuration["AzureAd:Instance"]}/common";
            }
            else
            {
                options.Authority = $"{Configuration["AzureAd:Instance"]}/{Configuration["AzureAd:TenantId"]}";
            }
            options.ClientId = Configuration["AzureAd:ClientId"];
            //options.ClientSecret = Configuration["AzureAd:ClientSecret"];
            options.ResponseType =  "code id_token";
            options.SaveTokens = true;  // Make sure tokens are saved            
            options.Scope.Add("openid");
            options.Scope.Add("profile");
            //options.Scope.Add("api://89a3c92c-7393-4866-ab92-61f13864a7b1/.default");
            options.CallbackPath = Configuration["AzureAd:CallbackPath"];
            options.SignInScheme = "Cookies";
            options.GetClaimsFromUserInfoEndpoint = true;
             options.RequireHttpsMetadata = false;
             options.TokenValidationParameters = new TokenValidationParameters
            {
                ValidateIssuer = false
            };
                     
        });

        services.AddHttpContextAccessor(); // For accessing HttpContext later    
    }

    // This method gets called by the runtime. Use this method to configure the HTTP request pipeline.
    public void Configure(IApplicationBuilder app, IWebHostEnvironment env)
    {
        if (env.IsDevelopment())
        {
            app.UseDeveloperExceptionPage();
        }
        else
        {
            app.UseHsts();
        }


        app.UseHttpsRedirection();
        app.UseStaticFiles();

        app.UseRouting();
        
        app.UseAuthentication();  // Ensure the authentication middleware is added
        app.UseAuthorization();

        app.UseEndpoints(endpoints =>
        {
            endpoints.MapRazorPages();
        });
    }



}