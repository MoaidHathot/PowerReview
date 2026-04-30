using System.Text.Json;
using PowerReview.Core.Configuration;
using PowerReview.Core.Models;

namespace PowerReview.Core.Tests;

public class ConfigDeserializationTests
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    [Fact]
    public void Deserialize_FullConfig_AllPropertiesBound()
    {
        var json = """
        {
          "git": {
            "strategy": "Worktree",
            "repo_base_path": "C:\\Repos\\MyProject",
            "worktree_dir": ".my-worktrees",
            "cleanup_on_close": false,
            "auto_clone": true
          },
          "auth": {
            "azdo": {
              "method": "az_cli",
              "pat_env_var": "MY_PAT"
            },
            "github": {
              "pat_env_var": "GH_TOKEN"
            }
          },
          "data_dir": "D:\\Data\\PowerReview",
          "providers": {
            "azdo": {
              "api_version": "7.2"
            }
          }
        }
        """;

        var config = JsonSerializer.Deserialize<PowerReviewConfig>(json, JsonOptions)!;

        Assert.Equal(GitStrategy.Worktree, config.Git.Strategy);
        Assert.Equal("C:\\Repos\\MyProject", config.Git.RepoBasePath);
        Assert.Equal(".my-worktrees", config.Git.WorktreeDir);
        Assert.False(config.Git.CleanupOnClose);
        Assert.True(config.Git.AutoClone);
        Assert.Equal("az_cli", config.Auth.AzDo.Method);
        Assert.Equal("MY_PAT", config.Auth.AzDo.PatEnvVar);
        Assert.Equal("GH_TOKEN", config.Auth.GitHub.PatEnvVar);
        Assert.Equal("D:\\Data\\PowerReview", config.DataDir);
        Assert.Equal("7.2", config.Providers.AzDo.ApiVersion);
    }

    [Fact]
    public void Deserialize_RepoBasePath_Bound()
    {
        var json = """
        {
          "git": {
            "repo_base_path": "/home/user/repos/my-project"
          }
        }
        """;

        var config = JsonSerializer.Deserialize<PowerReviewConfig>(json, JsonOptions)!;

        Assert.Equal("/home/user/repos/my-project", config.Git.RepoBasePath);
    }

    [Fact]
    public void Deserialize_RepoBasePath_NullWhenOmitted()
    {
        var json = """
        {
          "git": {
            "strategy": "Worktree"
          }
        }
        """;

        var config = JsonSerializer.Deserialize<PowerReviewConfig>(json, JsonOptions)!;

        Assert.Null(config.Git.RepoBasePath);
    }

    [Fact]
    public void Deserialize_EmptyJson_ReturnsDefaults()
    {
        var json = "{}";

        var config = JsonSerializer.Deserialize<PowerReviewConfig>(json, JsonOptions)!;

        Assert.Equal(GitStrategy.Worktree, config.Git.Strategy);
        Assert.Equal(".power-review-worktrees", config.Git.WorktreeDir);
        Assert.True(config.Git.CleanupOnClose);
        Assert.False(config.Git.AutoClone);
        Assert.Null(config.Git.RepoBasePath);
        Assert.Null(config.DataDir);
        Assert.Equal("auto", config.Auth.AzDo.Method);
        Assert.Equal("AZDO_PAT", config.Auth.AzDo.PatEnvVar);
        Assert.Equal("GITHUB_TOKEN", config.Auth.GitHub.PatEnvVar);
        Assert.Equal("7.1", config.Providers.AzDo.ApiVersion);
    }

    [Fact]
    public void Deserialize_CloneStrategy_Bound()
    {
        var json = """
        {
          "git": {
            "strategy": "Clone"
          }
        }
        """;

        var config = JsonSerializer.Deserialize<PowerReviewConfig>(json, JsonOptions)!;

        Assert.Equal(GitStrategy.Clone, config.Git.Strategy);
    }

    [Fact]
    public void Deserialize_CwdStrategy_Bound()
    {
        var json = """
        {
          "git": {
            "strategy": "Cwd"
          }
        }
        """;

        var config = JsonSerializer.Deserialize<PowerReviewConfig>(json, JsonOptions)!;

        Assert.Equal(GitStrategy.Cwd, config.Git.Strategy);
    }

    [Fact]
    public void RoundTrip_RepoBasePath_Preserved()
    {
        var config = new PowerReviewConfig();
        config.Git.RepoBasePath = "P:\\Work\\MyRepo";

        var json = JsonSerializer.Serialize(config, JsonOptions);
        var deserialized = JsonSerializer.Deserialize<PowerReviewConfig>(json, JsonOptions)!;

        Assert.Equal("P:\\Work\\MyRepo", deserialized.Git.RepoBasePath);
    }

    [Fact]
    public void Serialize_RepoBasePath_OmittedWhenNull()
    {
        var config = new PowerReviewConfig();

        var json = JsonSerializer.Serialize(config, JsonOptions);

        Assert.DoesNotContain("repo_base_path", json);
    }

    [Fact]
    public void Deserialize_AutoClone_True()
    {
        var json = """
        {
          "git": {
            "auto_clone": true
          }
        }
        """;

        var config = JsonSerializer.Deserialize<PowerReviewConfig>(json, JsonOptions)!;

        Assert.True(config.Git.AutoClone);
    }

    [Fact]
    public void Deserialize_AutoClone_FalseByDefault()
    {
        var json = """
        {
          "git": {}
        }
        """;

        var config = JsonSerializer.Deserialize<PowerReviewConfig>(json, JsonOptions)!;

        Assert.False(config.Git.AutoClone);
    }

    [Fact]
    public void Deserialize_AlwaysSeparateWorktree_True()
    {
        var json = """
        {
          "git": {
            "always_separate_worktree": true
          }
        }
        """;

        var config = JsonSerializer.Deserialize<PowerReviewConfig>(json, JsonOptions)!;

        Assert.True(config.Git.AlwaysSeparateWorktree);
    }

    [Fact]
    public void Deserialize_AlwaysSeparateWorktree_FalseByDefault()
    {
        var json = """
        {
          "git": {}
        }
        """;

        var config = JsonSerializer.Deserialize<PowerReviewConfig>(json, JsonOptions)!;

        Assert.False(config.Git.AlwaysSeparateWorktree);
    }

    [Fact]
    public void Deserialize_AbsoluteWorktreeDir_Bound()
    {
        var json = """
        {
          "git": {
            "worktree_dir": "P:\\Work\\PowerReview\\Sessions"
          }
        }
        """;

        var config = JsonSerializer.Deserialize<PowerReviewConfig>(json, JsonOptions)!;

        Assert.Equal("P:\\Work\\PowerReview\\Sessions", config.Git.WorktreeDir);
    }
}
