using System.Text.Json;
using PowerReview.Core.Auth;
using PowerReview.Core.Git;
using PowerReview.Core.Services;

namespace PowerReview.Cli.Mcp;

/// <summary>
/// Converts exceptions thrown by MCP tool bodies into a structured, stable JSON
/// error payload instead of letting them escape as an opaque
/// "An error occurred invoking '&lt;tool&gt;'" from the MCP host.
///
/// The payload always includes:
/// <list type="bullet">
///   <item><c>error</c> — a human-readable message;</item>
///   <item><c>category</c> — a machine-readable class (see <see cref="ErrorCategory"/>);</item>
///   <item><c>retryable</c> — whether the caller can reasonably retry.</item>
/// </list>
/// This lets dispatchers/agents react (e.g. retry on a transient auth timeout,
/// or surface a clear "run az login" to the user) rather than guessing.
/// </summary>
internal static class McpError
{
    internal static class ErrorCategory
    {
        public const string Auth = "auth";
        public const string AuthTimeout = "auth_timeout";
        public const string NoSession = "no_session";
        public const string NotFound = "not_found";
        public const string Validation = "validation";
        public const string Io = "io";
        public const string Git = "git";
        public const string Cancelled = "cancelled";
        public const string Remote = "remote";
        public const string Unknown = "unknown";
    }

    /// <summary>
    /// Run an async tool body and translate any failure into a structured error
    /// JSON string. Successful results are serialized by <paramref name="onSuccess"/>.
    /// </summary>
    public static async Task<string> GuardAsync<T>(
        Func<Task<T>> action,
        Func<T, string> onSuccess)
    {
        try
        {
            return onSuccess(await action());
        }
        catch (Exception ex)
        {
            return FromException(ex);
        }
    }

    /// <summary>Run a synchronous tool body with the same guarantees.</summary>
    public static string Guard<T>(Func<T> action, Func<T, string> onSuccess)
    {
        try
        {
            return onSuccess(action());
        }
        catch (Exception ex)
        {
            return FromException(ex);
        }
    }

    /// <summary>
    /// Classify an exception and serialize it to the structured error payload.
    /// </summary>
    public static string FromException(Exception ex)
    {
        var (category, retryable, message) = Classify(ex);
        return ToolHelpers.ToJson(new
        {
            error = message,
            category,
            retryable,
        });
    }

    private static (string Category, bool Retryable, string Message) Classify(Exception ex)
    {
        switch (ex)
        {
            case AuthenticationException auth:
                // A timed-out / transient auth failure is retryable; a "not logged
                // in" or "az not installed" failure is not.
                return auth.IsTransient
                    ? (ErrorCategory.AuthTimeout, true, auth.Message)
                    : (ErrorCategory.Auth, false, auth.Message);

            case ReviewServiceException rse:
                // "No session found ..." is a common, distinct case worth flagging.
                return rse.Message.Contains("No session found", StringComparison.OrdinalIgnoreCase)
                    ? (ErrorCategory.NoSession, false, rse.Message)
                    : (ErrorCategory.Validation, false, rse.Message);

            case GitException git:
                return (ErrorCategory.Git, false, git.Message);

            case OperationCanceledException:
                return (ErrorCategory.Cancelled, true, "The operation was cancelled.");

            case FileNotFoundException:
            case DirectoryNotFoundException:
                return (ErrorCategory.NotFound, true, ex.Message);

            case UnauthorizedAccessException:
            case IOException:
                // Concurrent session-file access or a mid-write read — transient.
                return (ErrorCategory.Io, true, ex.Message);

            case JsonException:
                return (ErrorCategory.Io, true, $"Failed to read or parse local session data: {ex.Message}");

            case HttpRequestException http:
                return (ErrorCategory.Remote, true, $"Remote provider request failed: {http.Message}");

            case ArgumentException arg:
                return (ErrorCategory.Validation, false, arg.Message);

            default:
                return (ErrorCategory.Unknown, false, ex.Message);
        }
    }
}
