using PowerReview.Core.Models;
using PowerReview.Core.Store;

namespace PowerReview.Core.Tests;

/// <summary>
/// Concurrency tests for <see cref="SessionStore"/>: parallel writers and readers
/// against the same session file must never surface an unhandled I/O or JSON
/// exception, and must not leave temp files behind. This is the regression guard
/// for the dispatcher's concurrent get_session + sync burst.
/// </summary>
public class SessionStoreConcurrencyTests : IDisposable
{
    private readonly string _tempDir;
    private readonly SessionStore _store;

    public SessionStoreConcurrencyTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "powerreview-store-concurrency-" + Guid.NewGuid().ToString("N")[..8]);
        _store = new SessionStore(_tempDir);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    private static ReviewSession CreateSession(string id, string title = "Test PR")
    {
        var now = DateTime.UtcNow.ToString("o");
        return new ReviewSession
        {
            Id = id,
            Provider = new ProviderInfo
            {
                Type = ProviderType.AzDo,
                Organization = "org",
                Project = "proj",
                Repository = "repo",
            },
            PullRequest = new PullRequestInfo { Id = 42, Title = title },
            CreatedAt = now,
            UpdatedAt = now,
        };
    }

    [Fact]
    public async Task ConcurrentSaveAndLoad_SameSession_NeverThrows()
    {
        const string id = "concurrent-session";
        _store.Save(CreateSession(id));

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var exceptions = new List<Exception>();
        var exLock = new object();

        void Record(Exception ex)
        {
            lock (exLock) exceptions.Add(ex);
        }

        // Many writers + many readers hammering the same file.
        var writers = Enumerable.Range(0, 8).Select(w => Task.Run(() =>
        {
            var i = 0;
            while (!cts.IsCancellationRequested)
            {
                try { _store.Save(CreateSession(id, $"title-{w}-{i++}")); }
                catch (Exception ex) { Record(ex); return; }
            }
        }));

        var readers = Enumerable.Range(0, 8).Select(_ => Task.Run(() =>
        {
            while (!cts.IsCancellationRequested)
            {
                try
                {
                    var loaded = _store.Load(id);
                    // Whenever it exists, it must be fully-formed (not a partial read).
                    if (loaded != null)
                    {
                        Assert.Equal(id, loaded.Id);
                        Assert.Equal(42, loaded.PullRequest.Id);
                    }
                }
                catch (Exception ex) { Record(ex); return; }
            }
        }));

        await Task.WhenAll(writers.Concat(readers));

        Assert.True(exceptions.Count == 0,
            "Concurrent Save/Load threw: " + string.Join(" || ", exceptions.Select(e => $"{e.GetType().Name}: {e.Message} @ {FirstFrame(e)}")));
    }

    private static string FirstFrame(Exception e)
    {
        var line = (e.StackTrace ?? "").Split('\n').FirstOrDefault(l => l.Contains("PowerReview", StringComparison.Ordinal))?.Trim();
        return line ?? "(no frame)";
    }

    [Fact]
    public async Task ConcurrentSaves_DifferentSessions_AllPersist()
    {
        var ids = Enumerable.Range(0, 20).Select(i => $"session-{i}").ToArray();

        await Task.WhenAll(ids.Select(id => Task.Run(() =>
        {
            for (var i = 0; i < 10; i++)
                _store.Save(CreateSession(id, $"{id}-{i}"));
        })));

        foreach (var id in ids)
        {
            var loaded = _store.Load(id);
            Assert.NotNull(loaded);
            Assert.Equal(id, loaded.Id);
        }
    }

    [Fact]
    public async Task ConcurrentSaves_LeaveNoTempFilesBehind()
    {
        const string id = "temp-cleanup-session";

        await Task.WhenAll(Enumerable.Range(0, 16).Select(w => Task.Run(() =>
        {
            for (var i = 0; i < 25; i++)
                _store.Save(CreateSession(id, $"{w}-{i}"));
        })));

        // Give the filesystem a beat, then assert no .tmp residue remains.
        var tmpFiles = Directory.GetFiles(_tempDir, "*.tmp");
        Assert.True(tmpFiles.Length == 0, "Leftover temp files: " + string.Join(", ", tmpFiles));

        // And the final file is loadable.
        Assert.NotNull(_store.Load(id));
    }

    [Fact]
    public void Load_EmptyFile_ReturnsNull()
    {
        Directory.CreateDirectory(_tempDir);
        var path = _store.GetSessionPath("empty-session");
        File.WriteAllText(path, "");

        Assert.Null(_store.Load("empty-session"));
    }

    [Fact]
    public async Task ConcurrentAcquireLock_SerializesWriters()
    {
        const string id = "locked-session";
        _store.Save(CreateSession(id));

        var inCritical = 0;
        var maxConcurrent = 0;

        await Task.WhenAll(Enumerable.Range(0, 12).Select(_ => Task.Run(() =>
        {
            using var alock = _store.AcquireLock(id, TimeSpan.FromSeconds(10));
            var current = Interlocked.Increment(ref inCritical);
            InterlockedMax(ref maxConcurrent, current);
            Thread.Sleep(15);
            Interlocked.Decrement(ref inCritical);
        })));

        Assert.Equal(1, maxConcurrent); // the lock is mutually exclusive
    }

    private static void InterlockedMax(ref int target, int value)
    {
        int snapshot;
        do
        {
            snapshot = Volatile.Read(ref target);
            if (value <= snapshot) return;
        }
        while (Interlocked.CompareExchange(ref target, value, snapshot) != snapshot);
    }
}
