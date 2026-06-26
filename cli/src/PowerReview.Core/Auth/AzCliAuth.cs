using System.Diagnostics;
using System.Text;

namespace PowerReview.Core.Auth;

/// <summary>
/// Authenticates using the Azure CLI (<c>az account get-access-token</c>).
/// Returns a Bearer token for Azure DevOps.
///
/// The CLI call is bounded by a configurable timeout and retried a configurable
/// number of times on transient failures (timeouts and non-login CLI errors),
/// because under a cold token cache or heavy concurrency a single call can take
/// much longer than the historical hard-coded 15 second budget.
/// </summary>
public sealed class AzCliAuth : IAuthStrategy
{
    /// <summary>
    /// Azure DevOps resource ID for OAuth token scoping.
    /// </summary>
    private const string AzDoResourceId = "499b84ac-1321-427f-aa17-267ca6975798";

    private readonly TimeSpan _timeout;
    private readonly int _maxRetries;
    private readonly TimeSpan _retryBaseDelay;
    private readonly Func<int, TimeSpan, CancellationToken, Task>? _delayOverride;
    private readonly Func<CancellationToken, Task<string>>? _attemptOverride;

    /// <summary>
    /// Create an Azure CLI auth strategy.
    /// </summary>
    /// <param name="timeout">
    /// Maximum time to wait for a single CLI call. Defaults to 45 seconds when null.
    /// </param>
    /// <param name="maxRetries">
    /// Number of additional attempts after the first failure. Total attempts =
    /// <paramref name="maxRetries"/> + 1. Defaults to 2.
    /// </param>
    /// <param name="retryBaseDelay">
    /// Base delay for exponential backoff between retries. Defaults to 500ms when null.
    /// </param>
    /// <param name="delayOverride">
    /// Test seam: replaces the inter-attempt delay. Receives the 1-based attempt
    /// number just completed and the computed delay. When null, a real delay is used.
    /// </param>
    public AzCliAuth(
        TimeSpan? timeout = null,
        int maxRetries = 2,
        TimeSpan? retryBaseDelay = null,
        Func<int, TimeSpan, CancellationToken, Task>? delayOverride = null)
        : this(timeout, maxRetries, retryBaseDelay, delayOverride, attemptOverride: null)
    {
    }

    /// <summary>
    /// Test seam constructor: <paramref name="attemptOverride"/> replaces the real
    /// <c>az</c> invocation (returning a bare token) so the timeout/retry/backoff
    /// policy can be exercised deterministically without the Azure CLI installed.
    /// </summary>
    internal AzCliAuth(
        TimeSpan? timeout,
        int maxRetries,
        TimeSpan? retryBaseDelay,
        Func<int, TimeSpan, CancellationToken, Task>? delayOverride,
        Func<CancellationToken, Task<string>>? attemptOverride)
    {
        _timeout = timeout is { } t && t > TimeSpan.Zero ? t : TimeSpan.FromSeconds(45);
        _maxRetries = Math.Max(0, maxRetries);
        _retryBaseDelay = retryBaseDelay is { } d && d > TimeSpan.Zero ? d : TimeSpan.FromMilliseconds(500);
        _delayOverride = delayOverride;
        _attemptOverride = attemptOverride;
    }

    /// <inheritdoc />
    public async Task<string> GetAuthHeaderAsync(CancellationToken cancellationToken = default)
    {
        var token = await GetTokenAsync(cancellationToken);
        return $"Bearer {token}";
    }

    /// <summary>
    /// Acquire a raw access token, applying the configured timeout and retry policy.
    /// </summary>
    public async Task<string> GetTokenAsync(CancellationToken cancellationToken = default)
    {
        var attempts = _maxRetries + 1;
        AuthenticationException? lastError = null;

        for (var attempt = 1; attempt <= attempts; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();

            try
            {
                return _attemptOverride != null
                    ? await _attemptOverride(cancellationToken)
                    : await RunOnceAsync(cancellationToken);
            }
            catch (AuthenticationException ex) when (ex.IsTransient && attempt < attempts)
            {
                // Transient (timeout or non-login CLI failure): back off and retry.
                lastError = ex;
                var delay = ComputeBackoff(attempt);
                if (_delayOverride != null)
                    await _delayOverride(attempt, delay, cancellationToken);
                else if (delay > TimeSpan.Zero)
                    await Task.Delay(delay, cancellationToken);
            }
        }

        // Exhausted retries on a transient error.
        throw lastError ?? new AuthenticationException("Azure CLI authentication failed.");
    }

    private TimeSpan ComputeBackoff(int attempt)
    {
        // Exponential backoff with full jitter, capped at 10s.
        var exponential = _retryBaseDelay.TotalMilliseconds * Math.Pow(2, attempt - 1);
        var capped = Math.Min(exponential, 10_000);
        var jittered = Random.Shared.NextDouble() * capped;
        return TimeSpan.FromMilliseconds(jittered);
    }

    private async Task<string> RunOnceAsync(CancellationToken cancellationToken)
    {
        var azArgs = $"account get-access-token --resource {AzDoResourceId} --query accessToken -o tsv";
        var isWindows = OperatingSystem.IsWindows();

        var psi = new ProcessStartInfo
        {
            // On Windows, 'az' is actually 'az.cmd' which cannot be started directly
            // with UseShellExecute=false. We must invoke it through cmd.exe.
            FileName = isWindows ? "cmd.exe" : "az",
            Arguments = isWindows ? $"/c az {azArgs}" : azArgs,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        using var process = new Process { StartInfo = psi };

        try
        {
            process.Start();
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // Missing executable is not transient — fail fast.
            throw new AuthenticationException(
                "Azure CLI (az) is not installed or not in PATH. " +
                "Install from https://learn.microsoft.com/cli/azure/install-azure-cli",
                isTransient: false);
        }

        var stdout = new StringBuilder();
        var stderr = new StringBuilder();

        // Use a linked CTS so a timeout cancels the readers too, and so that an
        // OperationCanceledException can be attributed to either the timeout or
        // the caller's cancellation.
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(_timeout);
        var token = timeoutCts.Token;

        var stdoutTask = ReadStreamAsync(process.StandardOutput, stdout, token);
        var stderrTask = ReadStreamAsync(process.StandardError, stderr, token);

        try
        {
            await process.WaitForExitAsync(token);
            await Task.WhenAll(stdoutTask, stderrTask);
        }
        catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            TryKill(process);
            // Drain readers without throwing so a kill doesn't surface a confusing
            // secondary cancellation exception.
            await SwallowAsync(stdoutTask);
            await SwallowAsync(stderrTask);
            throw new AuthenticationException(
                $"Azure CLI authentication timed out after {_timeout.TotalSeconds:0} seconds.",
                isTransient: true);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            TryKill(process);
            await SwallowAsync(stdoutTask);
            await SwallowAsync(stderrTask);
            throw; // genuine caller cancellation — propagate
        }

        var stderrText = stderr.ToString();
        var stdoutText = stdout.ToString().Trim();

        if (process.ExitCode != 0)
        {
            if (stderrText.Contains("not recognized", StringComparison.OrdinalIgnoreCase) ||
                stderrText.Contains("not found", StringComparison.OrdinalIgnoreCase))
            {
                throw new AuthenticationException(
                    "Azure CLI (az) is not installed or not in PATH.",
                    isTransient: false);
            }

            if (stderrText.Contains("az login", StringComparison.OrdinalIgnoreCase) ||
                stderrText.Contains("AADSTS", StringComparison.OrdinalIgnoreCase))
            {
                // Needs interactive login — retrying won't help.
                throw new AuthenticationException(
                    "Azure CLI: not logged in. Run 'az login' first.",
                    isTransient: false);
            }

            // Unknown CLI failure — treat as transient so it gets retried.
            var detail = stderrText.Length == 0 ? "(no stderr)" : stderrText[..Math.Min(stderrText.Length, 200)];
            throw new AuthenticationException(
                $"Azure CLI authentication failed: {detail}",
                isTransient: true);
        }

        return ValidateToken(stdoutText);
    }

    /// <summary>
    /// Validate the CLI's stdout (a bare access token). An empty token despite a
    /// success exit code is treated as transient (e.g. the process was killed
    /// between exit and flush, or a partial pipe read).
    /// </summary>
    internal static string ValidateToken(string stdout)
    {
        if (string.IsNullOrEmpty(stdout))
        {
            throw new AuthenticationException(
                "Azure CLI returned an empty access token.",
                isTransient: true);
        }

        return stdout;
    }

    private static Task ReadStreamAsync(StreamReader reader, StringBuilder sink, CancellationToken ct)
    {
        return Task.Run(async () =>
        {
            try
            {
                string? line;
                while ((line = await reader.ReadLineAsync(ct)) != null)
                    sink.Append(line);
            }
            catch (OperationCanceledException)
            {
                // Reader cancelled due to timeout/kill — caller handles the timeout.
            }
            catch (IOException)
            {
                // Pipe broken because the process was killed — ignore.
            }
        }, ct);
    }

    private static async Task SwallowAsync(Task task)
    {
        try { await task; } catch { /* best effort drain */ }
    }

    private static void TryKill(Process process)
    {
        try { process.Kill(entireProcessTree: true); } catch { /* best effort */ }
    }
}
