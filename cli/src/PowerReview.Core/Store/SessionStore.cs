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

    /// <summary>
    /// Number of times a transient file-system error (a read racing a concurrent
    /// atomic replace, or a temp/rename collision) is retried before giving up.
    /// </summary>
    private const int TransientIoRetries = 5;

    private const int TransientIoDelayMs = 25;

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
    ///
    /// Writers to the same session are serialized with a dedicated write-lock
    /// file (distinct from the public <see cref="AcquireLock"/>, so callers that
    /// already hold that lock don't deadlock). Serializing is required because on
    /// Windows two concurrent <c>File.Move(overwrite:true)</c> calls targeting the
    /// same destination throw <see cref="UnauthorizedAccessException"/>. The temp
    /// file name is also unique per write, and the rename is retried on transient
    /// sharing errors (a concurrent reader momentarily holding the destination).
    /// </summary>
    public void Save(ReviewSession session)
    {
        session.NormalizeDraftOperations();
        session.UpdatedAt = DateTime.UtcNow.ToString("o");
        session.Metadata = ReviewMetadata.FromSession(session);

        Directory.CreateDirectory(_sessionsDir);

        var path = GetSessionPath(session.Id);
        // Unique temp name: avoids collisions between concurrent writers that
        // would otherwise share "{path}.tmp".
        var tmpPath = $"{path}.{Guid.NewGuid():N}.tmp";

        var json = JsonSerializer.Serialize(session, JsonOptions);

        File.WriteAllText(tmpPath, json);

        try
        {
            // Serialize the replace against other writers of the same session.
            using var writeLock = SessionFileLock.Acquire(GetWriteLockPath(session.Id), TimeSpan.FromSeconds(10));
            MoveWithRetry(tmpPath, path);
        }
        catch
        {
            // Cleanup temp file on failure
            try { File.Delete(tmpPath); } catch { /* best effort */ }
            throw;
        }
    }

    private string GetWriteLockPath(string sessionId)
        => Path.Combine(_sessionsDir, $"{sessionId}.wlock");

    /// <summary>
    /// Load a session from disk by ID.
    ///
    /// Reads are resilient to a concurrent <see cref="Save"/> replacing the file:
    /// a transient sharing error or a partial/!valid JSON read (possible only in
    /// a narrow window on some platforms) is retried briefly before failing. A
    /// file that disappears between existence check and read is treated as
    /// "not found".
    /// </summary>
    /// <returns>The session, or null if not found.</returns>
    public ReviewSession? Load(string sessionId)
    {
        var path = GetSessionPath(sessionId);

        var (found, session) = ReadWithRetry(path);
        if (!found || session == null)
            return null;

        // Run migration if needed
        if (session.Version < ReviewSession.CurrentVersion)
        {
            session = SessionMigration.Migrate(session);
            Save(session); // Persist migrated version
        }
        else
        {
            session.Metadata = ReviewMetadata.FromSession(session);
        }

        return session;
    }

    /// <summary>
    /// Read and deserialize a session file, retrying transient I/O and parse
    /// failures that can occur when the file is concurrently replaced.
    /// </summary>
    /// <returns>
    /// (found, session). <c>found=false</c> means the file does not exist.
    /// <c>found=true, session=null</c> means the file existed but was empty.
    /// </returns>
    private static (bool Found, ReviewSession? Session) ReadWithRetry(string path)
    {
        Exception? lastTransient = null;

        for (var attempt = 0; attempt <= TransientIoRetries; attempt++)
        {
            try
            {
                var json = ReadAllTextShared(path);
                if (json == null)
                    return (false, null);
                if (string.IsNullOrWhiteSpace(json))
                    return (true, null);

                var session = JsonSerializer.Deserialize<ReviewSession>(json, JsonOptions);
                return (true, session);
            }
            catch (FileNotFoundException)
            {
                // Deleted between open attempts (TOCTOU) — treat as not found.
                return (false, null);
            }
            catch (DirectoryNotFoundException)
            {
                return (false, null);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
            {
                // Likely racing a concurrent atomic replace; back off and retry.
                lastTransient = ex;
                if (attempt < TransientIoRetries)
                    Thread.Sleep(TransientIoDelayMs);
            }
        }

        // Exhausted retries — surface the last transient error.
        throw lastTransient ?? new IOException($"Failed to read session file: {path}");
    }

    /// <summary>
    /// Read a file using sharing flags that tolerate a concurrent writer
    /// replacing or deleting it (<see cref="FileShare.ReadWrite"/> +
    /// <see cref="FileShare.Delete"/>). Returns null if the file does not exist.
    /// This avoids the Windows sharing conflict between <c>File.ReadAllText</c>
    /// and a concurrent <c>File.Move(overwrite:true)</c>.
    /// </summary>
    private static string? ReadAllTextShared(string path)
    {
        FileStream stream;
        try
        {
            stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
        }
        catch (FileNotFoundException)
        {
            return null;
        }
        catch (DirectoryNotFoundException)
        {
            return null;
        }

        using (stream)
        using (var reader = new StreamReader(stream))
        {
            return reader.ReadToEnd();
        }
    }

    private static void MoveWithRetry(string sourcePath, string destPath)
    {
        Exception? last = null;
        for (var attempt = 0; attempt <= TransientIoRetries; attempt++)
        {
            try
            {
                ReplaceOrMove(sourcePath, destPath);
                return;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // Destination momentarily held open by a concurrent reader, or a
                // transient sharing conflict. Wait briefly and try again.
                last = ex;
                if (attempt < TransientIoRetries)
                    Thread.Sleep(TransientIoDelayMs);
            }
        }

        throw last ?? new IOException($"Failed to move session file into place: {destPath}");
    }

    /// <summary>
    /// Atomically put <paramref name="sourcePath"/> in place at
    /// <paramref name="destPath"/>. When the destination already exists, use
    /// <see cref="File.Replace(string, string, string?)"/> which (via the Win32
    /// <c>ReplaceFile</c> API) can replace a file even while readers have it open
    /// — unlike <see cref="File.Move(string, string, bool)"/>, which fails with
    /// ACCESS_DENIED on Windows if the target is open. Falls back to a move when
    /// the destination doesn't exist yet.
    /// </summary>
    private static void ReplaceOrMove(string sourcePath, string destPath)
    {
        if (!File.Exists(destPath))
        {
            try
            {
                File.Move(sourcePath, destPath, overwrite: false);
                return;
            }
            catch (IOException) when (File.Exists(destPath))
            {
                // Another writer created it first; fall through to Replace.
            }
        }

        // ReplaceFile requires the destination to exist and replaces it in place,
        // tolerating readers that opened it with FILE_SHARE_DELETE.
        File.Replace(sourcePath, destPath, destinationBackupFileName: null, ignoreMetadataErrors: true);
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
                    DraftCount = session.DraftOperations.Count,
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
            catch (Exception ex) when ((ex is IOException or UnauthorizedAccessException) && DateTime.UtcNow < deadline)
            {
                // Held by another process, or momentarily mid-delete (DeleteOnClose
                // can briefly surface as UnauthorizedAccess on Windows). Retry until
                // the deadline.
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
