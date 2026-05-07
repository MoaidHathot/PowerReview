using PowerReview.Core.Auth;
using PowerReview.Core.Configuration;
using PowerReview.Core.Models;
using PowerReview.Core.Providers;
using PowerReview.Core.Services;
using PowerReview.Core.Store;

namespace PowerReview.Core.Tests;

/// <summary>
/// Tests for ReviewService lifecycle and local read methods.
/// </summary>
public class ReviewServiceTests : IDisposable
{
    private readonly string _tempDir;
    private readonly string _repoDir;
    private readonly SessionStore _store;
    private readonly SessionService _sessionService;
    private readonly ReviewService _service;
    private readonly PowerReviewConfig _config;

    // A valid AzDo PR URL that maps to a deterministic session ID
    private const string TestPrUrl = "https://dev.azure.com/testorg/testproj/_git/testrepo/pullrequest/42";

    public ReviewServiceTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "powerreview-review-tests-" + Guid.NewGuid().ToString("N")[..8]);
        _repoDir = Path.Combine(_tempDir, "repo");
        _store = new SessionStore(_tempDir);
        _sessionService = new SessionService(_store);
        _config = new PowerReviewConfig();

        // AuthResolver is required by constructor but not used for read-only methods
        var authResolver = new AuthResolver(_config.Auth);
        _service = new ReviewService(_store, _sessionService, _config, authResolver);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
        {
            try
            {
                ResetAttributes(_tempDir);
                Directory.Delete(_tempDir, recursive: true);
            }
            catch (UnauthorizedAccessException)
            {
                // Windows can briefly keep git object files read-only/locked after subprocess tests.
                ResetAttributes(_tempDir);
                Directory.Delete(_tempDir, recursive: true);
            }
        }
    }

    private static void ResetAttributes(string root)
    {
        foreach (var path in Directory.EnumerateFileSystemEntries(root, "*", SearchOption.AllDirectories))
        {
            try { File.SetAttributes(path, FileAttributes.Normal); } catch { }
        }
    }

    /// <summary>
    /// Create and save a session that corresponds to TestPrUrl.
    /// </summary>
    private ReviewSession CreateAndSaveSession()
    {
        var now = DateTime.UtcNow.ToString("o");
        var sessionId = ReviewSession.ComputeId(
            ProviderType.AzDo, "testorg", "testproj", "testrepo", 42);

        var session = new ReviewSession
        {
            Id = sessionId,
            Provider = new ProviderInfo
            {
                Type = ProviderType.AzDo,
                Organization = "testorg",
                Project = "testproj",
                Repository = "testrepo",
            },
            PullRequest = new PullRequestInfo
            {
                Id = 42,
                Url = TestPrUrl,
                Title = "Test PR",
                Description = "Test description",
                TargetBranch = "main",
            },
            Files =
            [
                new() { Path = "src/main.cs", ChangeType = ChangeType.Edit },
                new() { Path = "src/utils.cs", ChangeType = ChangeType.Add },
                new() { Path = "src/old.cs", ChangeType = ChangeType.Delete },
            ],
            Threads = new ThreadsInfo
            {
                SyncedAt = now,
                Items =
                [
                    new()
                    {
                        Id = 101,
                        FilePath = "src/main.cs",
                        LineStart = 10,
                        Status = ThreadStatus.Active,
                        Comments =
                        [
                            new()
                            {
                                Id = 1,
                                Author = new PersonIdentity { Name = "reviewer" },
                                Body = "Fix this",
                            },
                        ],
                    },
                    new()
                    {
                        Id = 102,
                        FilePath = "src/utils.cs",
                        LineStart = 5,
                        Status = ThreadStatus.Fixed,
                        Comments =
                        [
                            new()
                            {
                                Id = 2,
                                Author = new PersonIdentity { Name = "tester" },
                                Body = "Typo",
                            },
                        ],
                    },
                    new()
                    {
                        Id = 103,
                        FilePath = null,
                        Status = ThreadStatus.Active,
                        Comments = [],
                    },
                ],
            },
            CreatedAt = now,
            UpdatedAt = now,
        };

        _store.Save(session);
        return session;
    }

    private async Task<ReviewSession> CreateAndSaveGitBackedSessionAsync()
    {
        Directory.CreateDirectory(_repoDir);

        await RunGitAsync(["init"], _repoDir);
        await RunGitAsync(["config", "user.email", "review@example.test"], _repoDir);
        await RunGitAsync(["config", "user.name", "PowerReview Tests"], _repoDir);
        await RunGitAsync(["checkout", "-B", "main"], _repoDir);

        var srcDir = Path.Combine(_repoDir, "src");
        Directory.CreateDirectory(srcDir);
        await File.WriteAllTextAsync(Path.Combine(srcDir, "main.cs"), "class Main { }\n");
        await RunGitAsync(["add", "src/main.cs"], _repoDir);
        await RunGitAsync(["commit", "-m", "initial"], _repoDir);

        var targetCommit = await RunGitAsync(["rev-parse", "HEAD"], _repoDir);

        await RunGitAsync(["checkout", "-b", "feature/test"], _repoDir);
        await File.WriteAllTextAsync(Path.Combine(srcDir, "main.cs"), "class Main {\n    void Added() { }\n}\n");
        await File.WriteAllTextAsync(Path.Combine(srcDir, "utils.cs"), "class Utils { }\n");
        await RunGitAsync(["add", "src/main.cs", "src/utils.cs"], _repoDir);
        await RunGitAsync(["commit", "-m", "feature"], _repoDir);

        var sourceCommit = await RunGitAsync(["rev-parse", "HEAD"], _repoDir);
        var session = CreateAndSaveSession();
        session.Git.RepoPath = _repoDir;
        session.PullRequest.SourceBranch = "feature/test";
        session.PullRequest.TargetBranch = "refs/heads/main";
        session.Iteration.TargetCommit = targetCommit;
        session.Iteration.SourceCommit = sourceCommit;
        _store.Save(session);

        return session;
    }

    private ReviewService CreateService(FakeProvider provider)
    {
        var config = new PowerReviewConfig();
        config.Auth.AzDo.Method = "pat";
        config.Auth.AzDo.PatEnvVar = "POWERREVIEW_TEST_PAT";
        Environment.SetEnvironmentVariable(config.Auth.AzDo.PatEnvVar, "test-token");

        return new ReviewService(
            _store,
            _sessionService,
            config,
            new AuthResolver(config.Auth),
            providerFactory: (_, _) => provider);
    }

    private static async Task<string> RunGitAsync(string[] args, string workingDirectory)
    {
        var psi = new System.Diagnostics.ProcessStartInfo
        {
            FileName = "git",
            WorkingDirectory = workingDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        foreach (var arg in args)
            psi.ArgumentList.Add(arg);

        using var process = System.Diagnostics.Process.Start(psi)!;
        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();

        var stdout = await stdoutTask;
        var stderr = await stderrTask;
        if (process.ExitCode != 0)
            throw new InvalidOperationException($"git {string.Join(' ', args)} failed: {stderr}");

        return stdout.Trim();
    }

    // ========================================================================
    // OpenAsync
    // ========================================================================

    [Fact]
    public async Task OpenAsync_ExistingSession_RefreshesWithoutGitSetup()
    {
        var existing = CreateAndSaveSession();
        existing.Git.RepoPath = "old-repo";
        existing.Git.WorktreePath = "old-worktree";
        existing.Drafts["draft-1"] = new DraftComment
        {
            FilePath = "src/main.cs",
            Body = "preserve me",
        };
        existing.Vote = VoteValue.Approve;
        existing.Review.ReviewedFiles = ["src/main.cs"];
        existing.Proposals["proposal-1"] = new ProposedFix
        {
            ThreadId = 101,
            Description = "preserve proposal",
            BranchName = "powerreview/fix/thread-101",
        };
        existing.FixWorktree = new FixWorktreeInfo { Path = "fix-worktree", BaseBranch = "feature/test" };
        _store.Save(existing);

        var provider = new FakeProvider
        {
            PullRequest = new PullRequest
            {
                Id = 42,
                Url = TestPrUrl,
                Title = "Refreshed PR",
                Description = "Refreshed description",
                TargetBranch = "main",
            },
            Files = [new ChangedFile { Path = "src/refreshed.cs", ChangeType = ChangeType.Add }],
            Iteration = new IterationMeta { Id = 2, SourceCommit = "new-source", TargetCommit = "new-target" },
            Threads = [new CommentThread { Id = 201, FilePath = "src/refreshed.cs", Status = ThreadStatus.Active }],
        };
        var service = CreateService(provider);

        var result = await service.OpenAsync(TestPrUrl, repoPath: Path.Combine(_tempDir, "not-a-repo"));

        Assert.Equal("refreshed", result.Action);
        Assert.Equal("Refreshed PR", result.Session.PullRequest.Title);
        Assert.Equal("old-repo", result.Session.Git.RepoPath);
        Assert.Equal("old-worktree", result.Session.Git.WorktreePath);
        Assert.True(result.Session.Drafts.ContainsKey("draft-1"));
        Assert.Equal(VoteValue.Approve, result.Session.Vote);
        Assert.Contains("src/main.cs", result.Session.Review.ReviewedFiles);
        Assert.True(result.Session.Proposals.ContainsKey("proposal-1"));
        Assert.Equal("fix-worktree", result.Session.FixWorktree?.Path);
        Assert.Equal(1, provider.GetPullRequestCalls);
        Assert.Equal(1, provider.GetChangedFilesCalls);
        Assert.Equal(1, provider.GetThreadsCalls);
        Assert.Equal(0, provider.CreateThreadCalls);
        Assert.Single(result.Session.Files);
        Assert.Equal("src/refreshed.cs", result.Session.Files[0].Path);
        Assert.Single(result.Session.Threads.Items);
        Assert.Equal(201, result.Session.Threads.Items[0].Id);
    }

    [Fact]
    public async Task OpenAsync_NewSession_ReturnsOpenedAction()
    {
        var provider = new FakeProvider
        {
            PullRequest = new PullRequest
            {
                Id = 42,
                Url = TestPrUrl,
                Title = "New PR",
                Description = "New description",
                TargetBranch = "main",
            },
            Files = [new ChangedFile { Path = "src/new.cs", ChangeType = ChangeType.Add }],
            Iteration = new IterationMeta { Id = 1, SourceCommit = "source", TargetCommit = "target" },
            Threads = [new CommentThread { Id = 301, FilePath = "src/new.cs", Status = ThreadStatus.Active }],
        };
        var service = CreateService(provider);

        var result = await service.OpenAsync(TestPrUrl);

        Assert.Equal("opened", result.Action);
        Assert.Equal("New PR", result.Session.PullRequest.Title);
        Assert.Null(result.Session.Git.RepoPath);
        Assert.Single(result.Session.Files);
        Assert.Equal("src/new.cs", result.Session.Files[0].Path);
    }

    // ========================================================================
    // GetSession
    // ========================================================================

    [Fact]
    public void GetSession_ExistingSession_ReturnsResult()
    {
        CreateAndSaveSession();

        var result = _service.GetSession(TestPrUrl);

        Assert.NotNull(result);
        Assert.Equal("Test PR", result.Session.PullRequest.Title);
        Assert.NotEmpty(result.Path);
    }

    [Fact]
    public void GetSession_NonexistentSession_ReturnsNull()
    {
        var result = _service.GetSession(
            "https://dev.azure.com/noorg/noproj/_git/norepo/pullrequest/999");
        Assert.Null(result);
    }

    [Fact]
    public void GetSession_InvalidUrl_Throws()
    {
        Assert.Throws<ReviewServiceException>(() =>
            _service.GetSession("not-a-valid-url"));
    }

    [Fact]
    public void GetSession_IfModifiedSince_ReturnsNullWhenNotModified()
    {
        var session = CreateAndSaveSession();

        // Use a timestamp far in the future so session is "not modified"
        var result = _service.GetSession(TestPrUrl, ifModifiedSince: "9999-12-31T23:59:59Z");
        Assert.Null(result);
    }

    [Fact]
    public void GetSession_IfModifiedSince_ReturnsSessionWhenModified()
    {
        CreateAndSaveSession();

        // Use a timestamp in the past so session IS modified
        var result = _service.GetSession(TestPrUrl, ifModifiedSince: "2000-01-01T00:00:00Z");
        Assert.NotNull(result);
    }

    [Fact]
    public void GetSession_PathIsAbsolutePath()
    {
        CreateAndSaveSession();

        var result = _service.GetSession(TestPrUrl);
        Assert.NotNull(result);
        Assert.True(Path.IsPathRooted(result.Path), "Session path should be absolute");
    }

    // ========================================================================
    // GetFiles
    // ========================================================================

    [Fact]
    public void GetFiles_ReturnsFileList()
    {
        CreateAndSaveSession();

        var files = _service.GetFiles(TestPrUrl);

        Assert.NotNull(files);
        Assert.Equal(3, files.Count);
    }

    [Fact]
    public void GetFiles_ContainsExpectedFiles()
    {
        CreateAndSaveSession();

        var files = _service.GetFiles(TestPrUrl);

        Assert.NotNull(files);
        Assert.Contains(files, f => f.Path == "src/main.cs");
        Assert.Contains(files, f => f.Path == "src/utils.cs");
        Assert.Contains(files, f => f.Path == "src/old.cs");
    }

    [Fact]
    public void GetFiles_PreservesChangeType()
    {
        CreateAndSaveSession();

        var files = _service.GetFiles(TestPrUrl);

        Assert.NotNull(files);
        var mainFile = files.First(f => f.Path == "src/main.cs");
        Assert.Equal(ChangeType.Edit, mainFile.ChangeType);

        var addedFile = files.First(f => f.Path == "src/utils.cs");
        Assert.Equal(ChangeType.Add, addedFile.ChangeType);
    }

    [Fact]
    public void GetFiles_NonexistentSession_ReturnsNull()
    {
        var files = _service.GetFiles(
            "https://dev.azure.com/noorg/noproj/_git/norepo/pullrequest/999");
        Assert.Null(files);
    }

    // ========================================================================
    // GetFileDiff
    // ========================================================================

    [Fact]
    public void GetFileDiff_ExistingFile_ReturnsChangedFile()
    {
        CreateAndSaveSession();

        var file = _service.GetFileDiff(TestPrUrl, "src/main.cs");

        Assert.NotNull(file);
        Assert.Equal("src/main.cs", file.Path);
        Assert.Equal(ChangeType.Edit, file.ChangeType);
    }

    [Fact]
    public void GetFileDiff_NonexistentFile_ReturnsNull()
    {
        CreateAndSaveSession();

        var file = _service.GetFileDiff(TestPrUrl, "nonexistent.cs");
        Assert.Null(file);
    }

    [Fact]
    public void GetFileDiff_NormalizesBackslashes()
    {
        CreateAndSaveSession();

        var file = _service.GetFileDiff(TestPrUrl, "src\\main.cs");
        Assert.NotNull(file);
        Assert.Equal("src/main.cs", file.Path);
    }

    [Fact]
    public void GetFileDiff_CaseInsensitive()
    {
        CreateAndSaveSession();

        var file = _service.GetFileDiff(TestPrUrl, "SRC/MAIN.CS");
        Assert.NotNull(file);
    }

    [Fact]
    public void GetFileDiff_NonexistentSession_ReturnsNull()
    {
        var file = _service.GetFileDiff(
            "https://dev.azure.com/noorg/noproj/_git/norepo/pullrequest/999", "src/main.cs");
        Assert.Null(file);
    }

    [Fact]
    public async Task GetFileDiffWithPatchAsync_ReturnsUnifiedDiff()
    {
        await CreateAndSaveGitBackedSessionAsync();

        var result = await _service.GetFileDiffWithPatchAsync(TestPrUrl, "src/main.cs");

        Assert.Equal("src/main.cs", result.File.Path);
        Assert.Contains("diff --git", result.Diff);
        Assert.Contains("+    void Added() { }", result.Diff);
    }

    [Fact]
    public async Task GetFileDiffWithPatchAsync_NormalizesBackslashes()
    {
        await CreateAndSaveGitBackedSessionAsync();

        var result = await _service.GetFileDiffWithPatchAsync(TestPrUrl, "src\\main.cs");

        Assert.Equal("src/main.cs", result.File.Path);
        Assert.Contains("diff --git", result.Diff);
    }

    [Fact]
    public async Task GetFileDiffWithPatchAsync_NoLocalRepo_ThrowsHelpfulError()
    {
        CreateAndSaveSession();

        var ex = await Assert.ThrowsAsync<ReviewServiceException>(() =>
            _service.GetFileDiffWithPatchAsync(TestPrUrl, "src/main.cs"));

        Assert.Contains("No local git repository", ex.Message);
    }

    // ========================================================================
    // GetThreads
    // ========================================================================

    [Fact]
    public void GetThreads_ReturnsAllThreads()
    {
        CreateAndSaveSession();

        var threads = _service.GetThreads(TestPrUrl);

        Assert.NotNull(threads);
        Assert.Equal(3, threads.Count);
    }

    [Fact]
    public void GetThreads_FilterByFile()
    {
        CreateAndSaveSession();

        var threads = _service.GetThreads(TestPrUrl, "src/main.cs");

        Assert.NotNull(threads);
        Assert.Single(threads);
        Assert.Equal(101, threads[0].Id);
    }

    [Fact]
    public void GetThreads_FilterByFile_NormalizesBackslashes()
    {
        CreateAndSaveSession();

        var threads = _service.GetThreads(TestPrUrl, "src\\main.cs");

        Assert.NotNull(threads);
        Assert.Single(threads);
    }

    [Fact]
    public void GetThreads_FilterByFile_CaseInsensitive()
    {
        CreateAndSaveSession();

        var threads = _service.GetThreads(TestPrUrl, "SRC/MAIN.CS");

        Assert.NotNull(threads);
        Assert.Single(threads);
    }

    [Fact]
    public void GetThreads_FilterByFile_ExcludesNullFilePaths()
    {
        CreateAndSaveSession();

        // Thread 103 has null FilePath — should only appear unfiltered
        var all = _service.GetThreads(TestPrUrl);
        Assert.NotNull(all);
        Assert.Equal(3, all.Count);

        // Filtering by any specific file should exclude the null-path thread
        var mainThreads = _service.GetThreads(TestPrUrl, "src/main.cs");
        Assert.NotNull(mainThreads);
        Assert.Single(mainThreads);
    }

    [Fact]
    public void GetThreads_NoMatchingFile_ReturnsEmpty()
    {
        CreateAndSaveSession();

        var threads = _service.GetThreads(TestPrUrl, "nonexistent.cs");

        Assert.NotNull(threads);
        Assert.Empty(threads);
    }

    [Fact]
    public void GetThreads_NonexistentSession_ReturnsNull()
    {
        var threads = _service.GetThreads(
            "https://dev.azure.com/noorg/noproj/_git/norepo/pullrequest/999");
        Assert.Null(threads);
    }

    private sealed class FakeProvider : IProvider
    {
        public ProviderType ProviderType => ProviderType.AzDo;

        public PullRequest PullRequest { get; set; } = new();
        public List<ChangedFile> Files { get; set; } = [];
        public IterationMeta Iteration { get; set; } = new();
        public List<CommentThread> Threads { get; set; } = [];
        public int GetPullRequestCalls { get; private set; }
        public int GetChangedFilesCalls { get; private set; }
        public int GetThreadsCalls { get; private set; }
        public int CreateThreadCalls { get; private set; }

        public Task<PullRequest> GetPullRequestAsync(int prId, CancellationToken ct = default)
        {
            GetPullRequestCalls++;
            return Task.FromResult(PullRequest);
        }

        public Task<(List<ChangedFile> Files, IterationMeta Iteration)> GetChangedFilesAsync(int prId, CancellationToken ct = default)
        {
            GetChangedFilesCalls++;
            return Task.FromResult((Files, Iteration));
        }

        public Task<List<CommentThread>> GetThreadsAsync(int prId, CancellationToken ct = default)
        {
            GetThreadsCalls++;
            return Task.FromResult(Threads);
        }

        public Task<CommentThread> CreateThreadAsync(int prId, CreateThreadRequest request, CancellationToken ct = default)
        {
            CreateThreadCalls++;
            return Task.FromResult(new CommentThread
            {
                Id = CreateThreadCalls,
                FilePath = request.FilePath,
                LineStart = request.LineStart,
                LineEnd = request.LineEnd,
                ColStart = request.ColStart,
                ColEnd = request.ColEnd,
                Status = request.Status,
            });
        }

        public Task<Comment> ReplyToThreadAsync(int prId, int threadId, string body, CancellationToken ct = default)
        {
            return Task.FromResult(new Comment { Id = 1, ThreadId = threadId, Body = body });
        }

        public Task<Comment> UpdateCommentAsync(int prId, int threadId, int commentId, string body, CancellationToken ct = default)
        {
            return Task.FromResult(new Comment { Id = commentId, ThreadId = threadId, Body = body });
        }

        public Task DeleteCommentAsync(int prId, int threadId, int commentId, CancellationToken ct = default)
        {
            return Task.CompletedTask;
        }

        public Task SetVoteAsync(int prId, string reviewerId, int vote, CancellationToken ct = default)
        {
            return Task.CompletedTask;
        }

        public Task<string> GetFileContentAsync(string filePath, string branch, CancellationToken ct = default)
        {
            return Task.FromResult("");
        }

        public Task<string> GetCurrentReviewerIdAsync(CancellationToken ct = default)
        {
            return Task.FromResult("reviewer-1");
        }

        public Task<CommentThread> UpdateThreadStatusAsync(int prId, int threadId, ThreadStatus status, CancellationToken ct = default)
        {
            return Task.FromResult(new CommentThread { Id = threadId, Status = status });
        }

        public Task UpdatePullRequestDescriptionAsync(int prId, string description, CancellationToken ct = default)
        {
            return Task.CompletedTask;
        }
    }
}
