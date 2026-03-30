using System.Text;
using PowerReview.Core.Models;

namespace PowerReview.Core.Auth;

/// <summary>
/// Authenticates using a Personal Access Token from an environment variable.
/// </summary>
public sealed class PatAuth : IAuthStrategy
{
    private readonly string _envVarName;
    private readonly ProviderType _providerType;

    /// <summary>
    /// Create a PAT auth strategy.
    /// </summary>
    /// <param name="envVarName">The environment variable containing the PAT.</param>
    /// <param name="providerType">The provider type (affects header format).</param>
    public PatAuth(string envVarName, ProviderType providerType)
    {
        _envVarName = envVarName;
        _providerType = providerType;
    }

    public Task<string> GetAuthHeaderAsync(CancellationToken cancellationToken = default)
    {
        var pat = Environment.GetEnvironmentVariable(_envVarName);

        if (string.IsNullOrEmpty(pat))
        {
            throw new AuthenticationException(
                $"PAT not found. Set the '{_envVarName}' environment variable.");
        }

        var header = _providerType switch
        {
            // AzDO uses Basic auth with ":{PAT}" base64-encoded (empty username, PAT as password)
            ProviderType.AzDo => $"Basic {Convert.ToBase64String(Encoding.UTF8.GetBytes($":{pat}"))}",

            // GitHub uses Bearer token
            ProviderType.GitHub => $"Bearer {pat}",

            _ => throw new AuthenticationException($"Unsupported provider type: {_providerType}"),
        };

        return Task.FromResult(header);
    }
}
