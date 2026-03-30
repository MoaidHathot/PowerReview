using System.Diagnostics;
using System.Text;

namespace PowerReview.Core.Auth;

/// <summary>
/// Authenticates using the Azure CLI (az account get-access-token).
/// Returns a Bearer token for Azure DevOps.
/// </summary>
public sealed class AzCliAuth : IAuthStrategy
{
    /// <summary>
    /// Azure DevOps resource ID for OAuth token scoping.
    /// </summary>
    private const string AzDoResourceId = "499b84ac-1321-427f-aa17-267ca6975798";

    public async Task<string> GetAuthHeaderAsync(CancellationToken cancellationToken = default)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "az",
            Arguments = $"account get-access-token --resource {AzDoResourceId} --query accessToken -o tsv",
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
            throw new AuthenticationException(
                "Azure CLI (az) is not installed or not in PATH. " +
                "Install from https://docs.microsoft.com/cli/azure/install-azure-cli");
        }

        var stdout = new StringBuilder();
        var stderr = new StringBuilder();

        var stdoutTask = Task.Run(async () =>
        {
            string? line;
            while ((line = await process.StandardOutput.ReadLineAsync(cancellationToken)) != null)
                stdout.Append(line);
        }, cancellationToken);

        var stderrTask = Task.Run(async () =>
        {
            string? line;
            while ((line = await process.StandardError.ReadLineAsync(cancellationToken)) != null)
                stderr.Append(line);
        }, cancellationToken);

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(TimeSpan.FromSeconds(15));

        try
        {
            await process.WaitForExitAsync(timeoutCts.Token);
            await Task.WhenAll(stdoutTask, stderrTask);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            try { process.Kill(entireProcessTree: true); } catch { /* best effort */ }
            throw new AuthenticationException("Azure CLI authentication timed out after 15 seconds.");
        }

        var stderrText = stderr.ToString();
        var token = stdout.ToString().Trim();

        if (process.ExitCode != 0)
        {
            if (stderrText.Contains("not recognized", StringComparison.OrdinalIgnoreCase) ||
                stderrText.Contains("not found", StringComparison.OrdinalIgnoreCase))
            {
                throw new AuthenticationException(
                    "Azure CLI (az) is not installed or not in PATH.");
            }

            if (stderrText.Contains("az login", StringComparison.OrdinalIgnoreCase) ||
                stderrText.Contains("AADSTS", StringComparison.OrdinalIgnoreCase))
            {
                throw new AuthenticationException(
                    "Azure CLI: not logged in. Run 'az login' first.");
            }

            throw new AuthenticationException(
                $"Azure CLI authentication failed: {stderrText[..Math.Min(stderrText.Length, 200)]}");
        }

        if (string.IsNullOrEmpty(token))
        {
            throw new AuthenticationException(
                "Azure CLI returned an empty access token.");
        }

        return $"Bearer {token}";
    }
}
