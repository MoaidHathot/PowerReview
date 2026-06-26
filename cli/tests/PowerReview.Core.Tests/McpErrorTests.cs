using System.Text.Json;
using PowerReview.Cli.Mcp;
using PowerReview.Core.Auth;
using PowerReview.Core.Configuration;
using PowerReview.Core.Git;
using PowerReview.Core.Services;
using PowerReview.Core.Store;

namespace PowerReview.Core.Tests;

/// <summary>
/// Tests for <see cref="McpError"/> classification and for the structured error
/// contract of authenticated MCP tools (the fix for the opaque
/// "An error occurred invoking 'sync_threads'" failure).
/// </summary>
public class McpErrorTests : IDisposable
{
    private readonly string _tempDir;
    private readonly SessionStore _store;
    private readonly ReviewService _reviewService;

    private const string PrUrl = "https://dev.azure.com/testorg/testproj/_git/testrepo/pullrequest/42";

    public McpErrorTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "powerreview-mcperror-tests-" + Guid.NewGuid().ToString("N")[..8]);
        _store = new SessionStore(_tempDir);
        var sessionService = new SessionService(_store);
        var config = new PowerReviewConfig();
        _reviewService = new ReviewService(_store, sessionService, config, new AuthResolver(config.Auth));
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    private static JsonElement Parse(string json) => JsonDocument.Parse(json).RootElement;

    // --- Classification ---

    [Fact]
    public void FromException_TransientAuth_IsAuthTimeoutAndRetryable()
    {
        var json = McpError.FromException(new AuthenticationException("timed out", isTransient: true));
        var root = Parse(json);

        Assert.Equal("auth_timeout", root.GetProperty("category").GetString());
        Assert.True(root.GetProperty("retryable").GetBoolean());
        Assert.Contains("timed out", root.GetProperty("error").GetString());
    }

    [Fact]
    public void FromException_NonTransientAuth_IsAuthAndNotRetryable()
    {
        var json = McpError.FromException(new AuthenticationException("not logged in", isTransient: false));
        var root = Parse(json);

        Assert.Equal("auth", root.GetProperty("category").GetString());
        Assert.False(root.GetProperty("retryable").GetBoolean());
    }

    [Fact]
    public void FromException_NoSessionReviewServiceException_IsNoSession()
    {
        var json = McpError.FromException(new ReviewServiceException("No session found for PR ..."));
        var root = Parse(json);

        Assert.Equal("no_session", root.GetProperty("category").GetString());
    }

    [Fact]
    public void FromException_OtherReviewServiceException_IsValidation()
    {
        var json = McpError.FromException(new ReviewServiceException("Could not parse PR URL: x"));
        var root = Parse(json);

        Assert.Equal("validation", root.GetProperty("category").GetString());
    }

    [Fact]
    public void FromException_IoException_IsIoAndRetryable()
    {
        var json = McpError.FromException(new IOException("file busy"));
        var root = Parse(json);

        Assert.Equal("io", root.GetProperty("category").GetString());
        Assert.True(root.GetProperty("retryable").GetBoolean());
    }

    [Fact]
    public void FromException_GitException_IsGit()
    {
        var json = McpError.FromException(new GitException("git failed"));
        Assert.Equal("git", Parse(json).GetProperty("category").GetString());
    }

    [Fact]
    public void FromException_HttpRequestException_IsRemoteAndRetryable()
    {
        var json = McpError.FromException(new HttpRequestException("503"));
        var root = Parse(json);

        Assert.Equal("remote", root.GetProperty("category").GetString());
        Assert.True(root.GetProperty("retryable").GetBoolean());
    }

    [Fact]
    public void FromException_Cancelled_IsCancelled()
    {
        var json = McpError.FromException(new OperationCanceledException());
        Assert.Equal("cancelled", Parse(json).GetProperty("category").GetString());
    }

    [Fact]
    public void FromException_Unknown_IsUnknownAndNotRetryable()
    {
        var json = McpError.FromException(new InvalidOperationException("weird"));
        var root = Parse(json);

        Assert.Equal("unknown", root.GetProperty("category").GetString());
        Assert.False(root.GetProperty("retryable").GetBoolean());
    }

    // --- Guard helpers ---

    [Fact]
    public async Task GuardAsync_Success_InvokesOnSuccess()
    {
        var json = await McpError.GuardAsync(
            () => Task.FromResult(123),
            v => ToolHelpers.ToJson(new { value = v }));

        Assert.Equal(123, Parse(json).GetProperty("value").GetInt32());
    }

    [Fact]
    public async Task GuardAsync_Throws_ProducesStructuredError()
    {
        var json = await McpError.GuardAsync<int>(
            () => throw new AuthenticationException("nope", isTransient: true),
            _ => "unreachable");

        var root = Parse(json);
        Assert.Equal("auth_timeout", root.GetProperty("category").GetString());
        Assert.True(root.GetProperty("retryable").GetBoolean());
    }

    // --- End-to-end through an actual MCP tool ---

    [Fact]
    public async Task SyncThreads_NoSession_ReturnsStructuredNoSessionError()
    {
        // No session saved -> SyncAsync throws ReviewServiceException("No session found...")
        // BEFORE any auth/remote call. The tool must surface a structured error,
        // not leak the exception.
        var json = await ReviewTools.SyncThreads(_reviewService, PrUrl, CancellationToken.None);
        var root = Parse(json);

        Assert.True(root.TryGetProperty("error", out _));
        Assert.Equal("no_session", root.GetProperty("category").GetString());
        Assert.False(root.GetProperty("retryable").GetBoolean());
        // Must NOT look like a success.
        Assert.False(root.TryGetProperty("synced", out _));
    }

    [Fact]
    public async Task GetIterationDiff_NoSession_ReturnsStructuredError()
    {
        var json = await ReviewTools.GetIterationDiff(_reviewService, PrUrl, "src/x.cs", CancellationToken.None);
        var root = Parse(json);

        Assert.True(root.TryGetProperty("error", out _));
        Assert.Equal("no_session", root.GetProperty("category").GetString());
    }
}
