using PowerReview.Core.Models;
using PowerReview.Core.Providers.AzureDevOps;

namespace PowerReview.Core.Providers;

/// <summary>
/// Factory for creating provider instances.
/// </summary>
public static class ProviderFactory
{
    /// <summary>
    /// Create a provider instance for the given provider type.
    /// </summary>
    public static IProvider Create(ProviderType providerType, string org, string project, string repo, string authHeader, string apiVersion = "7.1")
    {
        return providerType switch
        {
            ProviderType.AzDo => new AzDoProvider(org, project, repo, authHeader, apiVersion),
            ProviderType.GitHub => throw new NotSupportedException("GitHub provider is not yet implemented."),
            _ => throw new ArgumentException($"Unknown provider type: {providerType}"),
        };
    }
}
