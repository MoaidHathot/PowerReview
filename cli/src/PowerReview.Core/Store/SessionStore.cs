using System.Text.Json;
using PowerReview.Core.Configuration;
using PowerReview.Core.Models;

namespace PowerReview.Core.Store;

/// <summary>
/// Persists and retrieves review sessions as JSON files on disk.
/// Thread-safe via file locking for concurrent access from multiple tools.
/// </summary>
public sealed class SessionStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = true,
    };

    private readonly string _sessionsDir;

    public SessionStore(PowerReviewConfig config)
    {
        _sessionsDir = ConfigLoader.GetSessionsDir(config);
    }

    public SessionStore(string sessionsDir)
    {
        _sessionsDir = sessionsDir;
    }

    /// <summary>
    /// Get the full path to a session file.
    /// </summary>
    public string GetSessionPath(string sessionId)
    {
        return Path.Combine(_sessionsDir, $"{sessionId}.json");
    }

    /// <summary>
    /// Save a session to disk with an atomic write.
    /// Updates the session's updated_at timestamp.
    /// </summary>
    public void Save(ReviewSession session)
    {
        session.UpdatedAt = DateTime.UtcNow.ToString("o");

        Directory.CreateDirectory(_sessionsDir);

        var path = GetSessionPath(session.Id);
        var tmpPath = path + ".tmp";

        var json = JsonSerializer.Serialize(session, JsonOptions);

        // Atomic write: write to temp file, then rename
        File.WriteAllText(tmpPath, json);

        try
        {
            File.Move(tmpPath, path, overwrite: true);
        }
        catch
        {
            // Cleanup temp file on failure
            try { File.Delete(tmpPath); } catch { /* best effort */ }
            throw;
        }
    }

    /// <summary>
    /// Load a session from disk by ID.
    /// </summary>
    /// <returns>The session, or null if not found.</returns>
    public ReviewSession? Load(string sessionId)
    {
        var path = GetSessionPath(sessionId);
        if (!File.Exists(path))
            return null;

        var json = File.ReadAllText(path);
        if (string.IsNullOrWhiteSpace(json))
            return null;

        var session = JsonSerializer.Deserialize<ReviewSession>(json, JsonOptions);
        if (session == null)
            return null;

        // Run migration if needed
        if (session.Version < ReviewSession.CurrentVersion)
        {
            session = SessionMigration.Migrate(session);
            Save(session); // Persist migrated version
        }

        return session;
    }

    /// <summary>
    /// Delete a session file.
    /// </summary>
    /// <returns>True if the file was deleted, false if it didn't exist.</returns>
    public bool Delete(string sessionId)
    {
        var path = GetSessionPath(sessionId);
        if (!File.Exists(path))
            return false;

        File.Delete(path);
        return true;
    }

    /// <summary>
    /// List all saved sessions with summary information.
    /// </summary>
    public List<SessionSummary> List()
    {
        if (!Directory.Exists(_sessionsDir))
            return [];

        var summaries = new List<SessionSummary>();

        foreach (var file in Directory.GetFiles(_sessionsDir, "*.json"))
        {
            try
            {
                var json = File.ReadAllText(file);
                var session = JsonSerializer.Deserialize<ReviewSession>(json, JsonOptions);
                if (session == null) continue;

                summaries.Add(new SessionSummary
                {
                    Id = session.Id,
                    PrId = session.PullRequest.Id,
                    PrTitle = session.PullRequest.Title,
                    PrUrl = session.PullRequest.Url,
                    PrStatus = session.PullRequest.Status,
                    ProviderType = session.Provider.Type,
                    Organization = session.Provider.Organization,
                    Project = session.Provider.Project,
                    Repository = session.Provider.Repository,
                    DraftCount = session.Drafts.Count,
                    CreatedAt = session.CreatedAt,
                    UpdatedAt = session.UpdatedAt,
                });
            }
            catch
            {
                // Skip malformed session files
            }
        }

        // Sort by most recently updated first
        summaries.Sort((a, b) => string.Compare(b.UpdatedAt, a.UpdatedAt, StringComparison.Ordinal));
        return summaries;
    }

    /// <summary>
    /// Delete all session files.
    /// </summary>
    /// <returns>Number of files deleted.</returns>
    public int Clean()
    {
        if (!Directory.Exists(_sessionsDir))
            return 0;

        var files = Directory.GetFiles(_sessionsDir, "*.json");
        foreach (var file in files)
        {
            try { File.Delete(file); } catch { /* best effort */ }
        }
        return files.Length;
    }

    /// <summary>
    /// Acquire a file lock on a session for concurrent access.
    /// Use with 'using' statement.
    /// </summary>
    public SessionFileLock AcquireLock(string sessionId, TimeSpan? timeout = null)
    {
        return SessionFileLock.Acquire(
            Path.Combine(_sessionsDir, $"{sessionId}.lock"),
            timeout ?? TimeSpan.FromSeconds(5));
    }
}

/// <summary>
/// Summary of a session for listing purposes.
/// </summary>
public sealed class SessionSummary
{
    public string Id { get; set; } = "";
    public int PrId { get; set; }
    public string PrTitle { get; set; } = "";
    public string PrUrl { get; set; } = "";
    public PullRequestStatus PrStatus { get; set; }
    public ProviderType ProviderType { get; set; }
    public string Organization { get; set; } = "";
    public string Project { get; set; } = "";
    public string Repository { get; set; } = "";
    public int DraftCount { get; set; }
    public string CreatedAt { get; set; } = "";
    public string UpdatedAt { get; set; } = "";
}

/// <summary>
/// File-based lock for concurrent session access.
/// </summary>
public sealed class SessionFileLock : IDisposable
{
    private FileStream? _lockStream;
    private readonly string _lockPath;

    private SessionFileLock(string lockPath, FileStream lockStream)
    {
        _lockPath = lockPath;
        _lockStream = lockStream;
    }

    public static SessionFileLock Acquire(string lockPath, TimeSpan timeout)
    {
        var dir = Path.GetDirectoryName(lockPath);
        if (dir != null) Directory.CreateDirectory(dir);

        var deadline = DateTime.UtcNow + timeout;
        while (true)
        {
            try
            {
                var stream = new FileStream(
                    lockPath,
                    FileMode.OpenOrCreate,
                    FileAccess.ReadWrite,
                    FileShare.None,
                    bufferSize: 1,
                    FileOptions.DeleteOnClose);

                return new SessionFileLock(lockPath, stream);
            }
            catch (IOException) when (DateTime.UtcNow < deadline)
            {
                Thread.Sleep(50);
            }
        }
    }

    public void Dispose()
    {
        if (_lockStream != null)
        {
            _lockStream.Dispose();
            _lockStream = null;
        }
    }
}
