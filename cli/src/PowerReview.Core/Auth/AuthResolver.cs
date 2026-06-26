using PowerReview.Core.Configuration;
using PowerReview.Core.Models;

namespace PowerReview.Core.Auth;

/// <summary>
/// Resolves the appropriate authentication strategy based on configuration.
/// For "auto" mode, tries Azure CLI first, then falls back to PAT.
/// </summary>
public sealed class AuthResolver
{
    private readonly AuthConfig _authConfig;
    private readonly Func<int, TimeSpan, CancellationToken, Task>? _azCliDelayOverride;

    public AuthResolver(AuthConfig authConfig)
        : this(authConfig, azCliDelayOverride: null)
    {
    }

    /// <summary>
    /// Test/advanced constructor allowing a custom Azure CLI retry-delay seam.
    /// </summary>
    internal AuthResolver(
        AuthConfig authConfig,
        Func<int, TimeSpan, CancellationToken, Task>? azCliDelayOverride)
    {
        _authConfig = authConfig;
        _azCliDelayOverride = azCliDelayOverride;
    }

    /// <summary>
    /// Get an auth header for the given provider type.
    /// </summary>
    public async Task<string> GetAuthHeaderAsync(
        ProviderType providerType,
        CancellationToken cancellationToken = default)
    {
        return providerType switch
        {
            ProviderType.AzDo => await GetAzDoAuthHeaderAsync(cancellationToken),
            ProviderType.GitHub => await GetGitHubAuthHeaderAsync(cancellationToken),
            _ => throw new AuthenticationException($"Unsupported provider type: {providerType}"),
        };
    }

    private async Task<string> GetAzDoAuthHeaderAsync(CancellationToken cancellationToken)
    {
        var config = _authConfig.AzDo;
        var method = config.Method.ToLowerInvariant();

        if (method == "az_cli")
            return await CreateAzCliAuth().GetAuthHeaderAsync(cancellationToken);

        if (method == "pat")
            return await new PatAuth(config.PatEnvVar, ProviderType.AzDo).GetAuthHeaderAsync(cancellationToken);

        // "auto" mode: try az cli first, then PAT
        if (method == "auto")
        {
            try
            {
                return await CreateAzCliAuth().GetAuthHeaderAsync(cancellationToken);
            }
            catch (AuthenticationException azCliError)
            {
                try
                {
                    return await new PatAuth(config.PatEnvVar, ProviderType.AzDo).GetAuthHeaderAsync(cancellationToken);
                }
                catch (AuthenticationException patError)
                {
                    throw new AuthenticationException(
                        $"All authentication methods failed.\n" +
                        $"  Azure CLI: {azCliError.Message}\n" +
                        $"  PAT ({config.PatEnvVar}): {patError.Message}");
                }
            }
        }

        throw new AuthenticationException($"Unknown auth method: {method}. Use 'auto', 'az_cli', or 'pat'.");
    }

    private AzCliAuth CreateAzCliAuth()
    {
        var token = _authConfig.AzDo.Token;
        return new AzCliAuth(
            timeout: TimeSpan.FromSeconds(Math.Max(1, token.AzCliTimeoutSeconds)),
            maxRetries: token.AzCliMaxRetries,
            retryBaseDelay: TimeSpan.FromMilliseconds(Math.Max(0, token.AzCliRetryBaseDelayMs)),
            delayOverride: _azCliDelayOverride);
    }

    private async Task<string> GetGitHubAuthHeaderAsync(CancellationToken cancellationToken)
    {
        var config = _authConfig.GitHub;
        return await new PatAuth(config.PatEnvVar, ProviderType.GitHub).GetAuthHeaderAsync(cancellationToken);
    }
}
