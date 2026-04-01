using PowerReview.Core.Models;
using PowerReview.Core.Services;

namespace PowerReview.Core.Tests;

public class UrlParserTests
{
    [Theory]
    [InlineData(
        "https://dev.azure.com/myorg/myproject/_git/myrepo/pullrequest/123",
        ProviderType.AzDo, "myorg", "myproject", "myrepo", 123)]
    [InlineData(
        "https://dev.azure.com/MyOrg/My%20Project/_git/My%20Repo/pullrequest/456",
        ProviderType.AzDo, "MyOrg", "My Project", "My Repo", 456)]
    [InlineData(
        "dev.azure.com/myorg/myproject/_git/myrepo/pullrequest/789",
        ProviderType.AzDo, "myorg", "myproject", "myrepo", 789)]
    public void Parse_AzDoDevUrl_ReturnsCorrectResult(
        string url, ProviderType expectedType, string org, string project, string repo, int prId)
    {
        var result = UrlParser.Parse(url);

        Assert.NotNull(result);
        Assert.Equal(expectedType, result.ProviderType);
        Assert.Equal(org, result.Organization);
        Assert.Equal(project, result.Project);
        Assert.Equal(repo, result.Repository);
        Assert.Equal(prId, result.PrId);
    }

    [Theory]
    [InlineData(
        "https://myorg.visualstudio.com/myproject/_git/myrepo/pullrequest/42",
        ProviderType.AzDo, "myorg", "myproject", "myrepo", 42)]
    public void Parse_AzDoVisualStudioUrl_ReturnsCorrectResult(
        string url, ProviderType expectedType, string org, string project, string repo, int prId)
    {
        var result = UrlParser.Parse(url);

        Assert.NotNull(result);
        Assert.Equal(expectedType, result.ProviderType);
        Assert.Equal(org, result.Organization);
        Assert.Equal(project, result.Project);
        Assert.Equal(repo, result.Repository);
        Assert.Equal(prId, result.PrId);
    }

    [Theory]
    [InlineData(
        "https://github.com/owner/repo/pull/99",
        ProviderType.GitHub, "owner", "repo", "repo", 99)]
    [InlineData(
        "github.com/my-org/my-repo/pull/1",
        ProviderType.GitHub, "my-org", "my-repo", "my-repo", 1)]
    public void Parse_GitHubUrl_ReturnsCorrectResult(
        string url, ProviderType expectedType, string org, string project, string repo, int prId)
    {
        var result = UrlParser.Parse(url);

        Assert.NotNull(result);
        Assert.Equal(expectedType, result.ProviderType);
        Assert.Equal(org, result.Organization);
        Assert.Equal(project, result.Project);
        Assert.Equal(repo, result.Repository);
        Assert.Equal(prId, result.PrId);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not a url")]
    [InlineData("https://gitlab.com/org/repo/merge_requests/1")]
    [InlineData("https://dev.azure.com/myorg/myproject/_git/myrepo")]
    public void Parse_InvalidUrl_ReturnsNull(string url)
    {
        var result = UrlParser.Parse(url);
        Assert.Null(result);
    }

    [Fact]
    public void Parse_Null_ReturnsNull()
    {
        var result = UrlParser.Parse(null!);
        Assert.Null(result);
    }

    [Fact]
    public void Parse_UrlWithQueryString_IgnoresQueryString()
    {
        var result = UrlParser.Parse("https://dev.azure.com/org/proj/_git/repo/pullrequest/5?_a=overview");

        Assert.NotNull(result);
        Assert.Equal(5, result.PrId);
    }

    [Fact]
    public void Parse_UrlWithFragment_IgnoresFragment()
    {
        var result = UrlParser.Parse("https://dev.azure.com/org/proj/_git/repo/pullrequest/5#fragment");

        Assert.NotNull(result);
        Assert.Equal(5, result.PrId);
    }

    [Theory]
    [InlineData("https://dev.azure.com/org/proj/_git/repo/pullrequest/1", ProviderType.AzDo)]
    [InlineData("https://myorg.visualstudio.com/proj/_git/repo/pullrequest/1", ProviderType.AzDo)]
    [InlineData("https://github.com/owner/repo/pull/1", ProviderType.GitHub)]
    public void DetectProvider_ValidUrl_ReturnsCorrectType(string url, ProviderType expected)
    {
        var result = UrlParser.DetectProvider(url);
        Assert.Equal(expected, result);
    }

    [Theory]
    [InlineData("")]
    [InlineData("https://gitlab.com/org/repo")]
    public void DetectProvider_UnknownUrl_ReturnsNull(string url)
    {
        var result = UrlParser.DetectProvider(url);
        Assert.Null(result);
    }

    // --- BuildCloneUrl ---

    [Fact]
    public void BuildCloneUrl_AzDo_ReturnsCorrectUrl()
    {
        var parsed = new ParsedUrl
        {
            ProviderType = ProviderType.AzDo,
            Organization = "myorg",
            Project = "myproject",
            Repository = "myrepo",
            PrId = 1,
        };

        var url = UrlParser.BuildCloneUrl(parsed);
        Assert.Equal("https://dev.azure.com/myorg/myproject/_git/myrepo", url);
    }

    [Fact]
    public void BuildCloneUrl_GitHub_ReturnsCorrectUrl()
    {
        var parsed = new ParsedUrl
        {
            ProviderType = ProviderType.GitHub,
            Organization = "owner",
            Project = "repo",
            Repository = "repo",
            PrId = 1,
        };

        var url = UrlParser.BuildCloneUrl(parsed);
        Assert.Equal("https://github.com/owner/repo.git", url);
    }

    [Fact]
    public void BuildCloneUrl_AzDo_WithSpacesInProject()
    {
        var parsed = new ParsedUrl
        {
            ProviderType = ProviderType.AzDo,
            Organization = "org",
            Project = "My Project",
            Repository = "My Repo",
            PrId = 42,
        };

        var url = UrlParser.BuildCloneUrl(parsed);
        Assert.Equal("https://dev.azure.com/org/My Project/_git/My Repo", url);
    }

    [Fact]
    public void BuildCloneUrl_RoundTripsWithParse_AzDo()
    {
        var original = "https://dev.azure.com/testorg/testproj/_git/testrepo/pullrequest/123";
        var parsed = UrlParser.Parse(original)!;
        var cloneUrl = UrlParser.BuildCloneUrl(parsed);

        Assert.Equal("https://dev.azure.com/testorg/testproj/_git/testrepo", cloneUrl);
    }

    [Fact]
    public void BuildCloneUrl_RoundTripsWithParse_GitHub()
    {
        var original = "https://github.com/owner/myrepo/pull/42";
        var parsed = UrlParser.Parse(original)!;
        var cloneUrl = UrlParser.BuildCloneUrl(parsed);

        Assert.Equal("https://github.com/owner/myrepo.git", cloneUrl);
    }
}
