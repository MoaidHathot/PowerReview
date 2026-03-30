using PowerReview.Core.Models;

namespace PowerReview.Core.Auth;

/// <summary>
/// Strategy for obtaining an authentication header for a provider.
/// </summary>
public interface IAuthStrategy
{
    /// <summary>
    /// Get the Authorization header value (e.g. "Bearer xxx" or "Basic xxx").
    /// </summary>
    Task<string> GetAuthHeaderAsync(CancellationToken cancellationToken = default);
}
