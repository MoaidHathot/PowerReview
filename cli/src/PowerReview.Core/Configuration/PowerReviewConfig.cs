using System.Text.Json.Serialization;
using PowerReview.Core.Models;

namespace PowerReview.Core.Configuration;

/// <summary>
/// Root configuration for the PowerReview CLI tool.
/// Loaded from $XDG_CONFIG_HOME/PowerReview/powerreview.json.
/// </summary>
public sealed class PowerReviewConfig
{
    [JsonPropertyName("git")]
    public GitConfig Git { get; set; } = new();

    [JsonPropertyName("auth")]
    public AuthConfig Auth { get; set; } = new();

    /// <summary>
    /// Override the default data directory ($XDG_DATA_HOME/PowerReview).
    /// </summary>
    [JsonPropertyName("data_dir")]
    public string? DataDir { get; set; }

    [JsonPropertyName("providers")]
    public ProvidersConfig Providers { get; set; } = new();
}

public sealed class GitConfig
{
    [JsonPropertyName("strategy")]
    public GitStrategy Strategy { get; set; } = GitStrategy.Worktree;

    /// <summary>
    /// Directory used to host review worktrees. Accepts either:
    ///   - a relative path (joined with the repo root, default behavior), or
    ///   - an absolute path (used as the external base; per-PR worktrees go
    ///     under <c>{abs}/{repoId}/{prId}</c> so multiple repos can share it).
    /// </summary>
    [JsonPropertyName("worktree_dir")]
    public string WorktreeDir { get; set; } = ".power-review-worktrees";

    /// <summary>
    /// Base path for clones or worktrees. If null, uses the repo root.
    /// </summary>
    [JsonPropertyName("repo_base_path")]
    public string? RepoBasePath { get; set; }

    /// <summary>
    /// If true, automatically clone the repository when the repo path doesn't exist.
    /// Can also be enabled per-invocation with the --auto-clone CLI flag.
    /// </summary>
    [JsonPropertyName("auto_clone")]
    public bool AutoClone { get; set; }

    /// <summary>
    /// If true, PowerReview always creates a separate linked worktree for a
    /// review even when the main repo is already on the PR's source branch.
    /// This keeps the main repo's branch state untouched by reviews.
    /// Default: <c>false</c> (preserves legacy "reuse main repo" optimisation).
    /// </summary>
    [JsonPropertyName("always_separate_worktree")]
    public bool AlwaysSeparateWorktree { get; set; }

    [JsonPropertyName("cleanup_on_close")]
    public bool CleanupOnClose { get; set; } = true;
}

public sealed class AuthConfig
{
    [JsonPropertyName("azdo")]
    public AzDoAuthConfig AzDo { get; set; } = new();

    [JsonPropertyName("github")]
    public GitHubAuthConfig GitHub { get; set; } = new();
}

public sealed class AzDoAuthConfig
{
    /// <summary>
    /// Authentication method: "auto" tries az_cli first, then PAT.
    /// </summary>
    [JsonPropertyName("method")]
    public string Method { get; set; } = "auto";

    /// <summary>
    /// Environment variable name to read the PAT from.
    /// </summary>
    [JsonPropertyName("pat_env_var")]
    public string PatEnvVar { get; set; } = "AZDO_PAT";

    /// <summary>
    /// Azure CLI access-token acquisition tuning (timeout and retry).
    /// Shared by all Azure DevOps auth strategies.
    /// </summary>
    [JsonPropertyName("token")]
    public TokenAuthConfig Token { get; set; } = new();
}

/// <summary>
/// Tuning for Azure CLI access-token acquisition: how long to wait on the CLI
/// and how many times to retry a transient failure. These exist because the
/// historical hard-coded 15s budget was too low under a cold Azure CLI token
/// cache or heavy concurrency.
/// </summary>
public sealed class TokenAuthConfig
{
    /// <summary>
    /// Maximum time (seconds) to wait for a single Azure CLI token call before
    /// treating it as a timeout. Default: 45.
    /// </summary>
    [JsonPropertyName("az_cli_timeout_seconds")]
    public int AzCliTimeoutSeconds { get; set; } = 45;

    /// <summary>
    /// Number of additional attempts after the first failure when the Azure CLI
    /// token call fails transiently (timeout / non-login error). Total attempts
    /// = AzCliMaxRetries + 1. Set to 0 to disable retries. Default: 2.
    /// </summary>
    [JsonPropertyName("az_cli_max_retries")]
    public int AzCliMaxRetries { get; set; } = 2;

    /// <summary>
    /// Base delay (milliseconds) for exponential backoff between Azure CLI
    /// retries. Attempt N waits roughly BaseDelay * 2^(N-1) plus jitter.
    /// Default: 500.
    /// </summary>
    [JsonPropertyName("az_cli_retry_base_delay_ms")]
    public int AzCliRetryBaseDelayMs { get; set; } = 500;
}

public sealed class GitHubAuthConfig
{
    [JsonPropertyName("pat_env_var")]
    public string PatEnvVar { get; set; } = "GITHUB_TOKEN";
}

public sealed class ProvidersConfig
{
    [JsonPropertyName("azdo")]
    public AzDoProviderConfig AzDo { get; set; } = new();
}

public sealed class AzDoProviderConfig
{
    [JsonPropertyName("api_version")]
    public string ApiVersion { get; set; } = "7.1";
}
