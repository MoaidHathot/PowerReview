namespace PowerReview.Core.Auth;

/// <summary>
/// Exception thrown when authentication fails.
/// </summary>
public class AuthenticationException : Exception
{
    /// <summary>
    /// Whether the failure is transient (e.g. a timeout or a transient CLI error)
    /// and therefore worth retrying. Failures that need human action — not logged
    /// in, CLI not installed, missing PAT — are non-transient.
    /// </summary>
    public bool IsTransient { get; }

    public AuthenticationException(string message) : this(message, isTransient: false) { }

    public AuthenticationException(string message, bool isTransient) : base(message)
    {
        IsTransient = isTransient;
    }

    public AuthenticationException(string message, Exception inner) : this(message, inner, isTransient: false) { }

    public AuthenticationException(string message, Exception inner, bool isTransient) : base(message, inner)
    {
        IsTransient = isTransient;
    }
}
