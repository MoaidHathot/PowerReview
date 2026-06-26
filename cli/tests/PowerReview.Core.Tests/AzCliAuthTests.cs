using PowerReview.Core.Auth;

namespace PowerReview.Core.Tests;

/// <summary>
/// Tests for <see cref="AzCliAuth"/> timeout/retry policy and token validation.
/// The real <c>az</c> invocation is replaced by a test seam so the policy is
/// exercised deterministically without the Azure CLI installed.
/// </summary>
public class AzCliAuthTests
{
    // No real delays in tests.
    private static readonly Func<int, TimeSpan, CancellationToken, Task> NoDelay =
        (_, _, _) => Task.CompletedTask;

    private static AzCliAuth CreateWithAttempts(
        int maxRetries,
        Func<CancellationToken, Task<string>> attempt)
    {
        return new AzCliAuth(
            timeout: TimeSpan.FromSeconds(5),
            maxRetries: maxRetries,
            retryBaseDelay: TimeSpan.FromMilliseconds(1),
            delayOverride: NoDelay,
            attemptOverride: attempt);
    }

    [Fact]
    public async Task GetToken_SucceedsFirstTry_NoRetry()
    {
        var calls = 0;
        var auth = CreateWithAttempts(maxRetries: 2, attempt: _ =>
        {
            Interlocked.Increment(ref calls);
            return Task.FromResult("tok");
        });

        var token = await auth.GetTokenAsync();

        Assert.Equal("tok", token);
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task GetToken_TransientThenSuccess_Retries()
    {
        var calls = 0;
        var auth = CreateWithAttempts(maxRetries: 3, attempt: _ =>
        {
            var n = Interlocked.Increment(ref calls);
            if (n < 3)
                throw new AuthenticationException("timed out", isTransient: true);
            return Task.FromResult("tok");
        });

        var token = await auth.GetTokenAsync();

        Assert.Equal("tok", token);
        Assert.Equal(3, calls); // 2 transient failures + 1 success
    }

    [Fact]
    public async Task GetToken_AllTransientFailures_ExhaustsRetriesThenThrows()
    {
        var calls = 0;
        var auth = CreateWithAttempts(maxRetries: 2, attempt: _ =>
        {
            Interlocked.Increment(ref calls);
            throw new AuthenticationException("timed out", isTransient: true);
        });

        var ex = await Assert.ThrowsAsync<AuthenticationException>(() => auth.GetTokenAsync());

        Assert.True(ex.IsTransient);
        Assert.Equal(3, calls); // maxRetries(2) + 1
    }

    [Fact]
    public async Task GetToken_NonTransientFailure_DoesNotRetry()
    {
        var calls = 0;
        var auth = CreateWithAttempts(maxRetries: 5, attempt: _ =>
        {
            Interlocked.Increment(ref calls);
            throw new AuthenticationException("not logged in", isTransient: false);
        });

        var ex = await Assert.ThrowsAsync<AuthenticationException>(() => auth.GetTokenAsync());

        Assert.False(ex.IsTransient);
        Assert.Equal(1, calls); // no retries for non-transient
    }

    [Fact]
    public async Task GetToken_ZeroRetries_SingleAttempt()
    {
        var calls = 0;
        var auth = CreateWithAttempts(maxRetries: 0, attempt: _ =>
        {
            Interlocked.Increment(ref calls);
            throw new AuthenticationException("timed out", isTransient: true);
        });

        await Assert.ThrowsAsync<AuthenticationException>(() => auth.GetTokenAsync());
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task GetAuthHeader_WrapsTokenAsBearer()
    {
        var auth = CreateWithAttempts(maxRetries: 0, attempt: _ => Task.FromResult("abc123"));

        var header = await auth.GetAuthHeaderAsync();

        Assert.Equal("Bearer abc123", header);
    }

    [Fact]
    public async Task GetToken_RespectsCallerCancellation()
    {
        using var cts = new CancellationTokenSource();
        var auth = CreateWithAttempts(maxRetries: 5, attempt: _ =>
        {
            cts.Cancel();
            throw new AuthenticationException("timed out", isTransient: true);
        });

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => auth.GetTokenAsync(cts.Token));
    }

    // --- Token validation ---

    [Fact]
    public void ValidateToken_NonEmpty_ReturnsToken()
    {
        Assert.Equal("abc", AzCliAuth.ValidateToken("abc"));
    }

    [Fact]
    public void ValidateToken_Empty_ThrowsTransient()
    {
        var ex = Assert.Throws<AuthenticationException>(() => AzCliAuth.ValidateToken(""));
        Assert.True(ex.IsTransient);
    }
}
