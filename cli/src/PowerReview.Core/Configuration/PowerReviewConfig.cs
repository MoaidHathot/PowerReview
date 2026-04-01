using System.Text.Json.Serialization;
using PowerReview.Core.Models;

namespace PowerReview.Core.Configuration;

/// <summary>
/// Root configuration for the PowerReview CLI tool.
/// Loaded from $XDG_CONFIG_HOME/PowerReview/config.json.
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
