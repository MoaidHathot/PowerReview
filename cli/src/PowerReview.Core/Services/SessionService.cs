using PowerReview.Core.Models;
using PowerReview.Core.Store;

namespace PowerReview.Core.Services;

/// <summary>
/// Manages approval-gated draft operations within a review session.
/// All mutations acquire a file lock, load the session, mutate, save, and release.
/// </summary>
public sealed class SessionService
{
    private readonly SessionStore _store;

    public SessionService(SessionStore store)
    {
        _store = store;
    }

    public (string Id, DraftOperation Operation) CreateDraftComment(string sessionId, CreateDraftOperationRequest request)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);

        var body = request.Body ?? "";
        if (string.IsNullOrWhiteSpace(body))
            throw new SessionServiceException("Comment body cannot be empty.");

        var filePath = request.FilePath ?? "";
        if (!string.IsNullOrEmpty(filePath))
        {
            var normalized = NormalizePath(filePath);
            var fileExists = session.Files.Any(f =>
                NormalizePath(f.Path).Equals(normalized, StringComparison.OrdinalIgnoreCase));

            if (!fileExists)
                throw new SessionServiceException(
                    $"File '{filePath}' is not part of this PR's changed files. " +
                    "Use 'files' command to see the list of changed files.");
        }

        var operation = CreateBaseOperation(DraftOperationType.Comment, request);
        operation.FilePath = filePath;
        operation.LineStart = request.LineStart;
        operation.LineEnd = request.LineEnd;
        operation.ColStart = request.ColStart;
        operation.ColEnd = request.ColEnd;
        operation.Body = body;

        return SaveNewOperation(session, operation);
    }

    public (string Id, DraftOperation Operation) CreateDraftReply(string sessionId, CreateDraftOperationRequest request)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);

        if (!request.ThreadId.HasValue)
            throw new SessionServiceException("Reply operation requires a thread ID.");

        var filePath = request.FilePath ?? "";
        var lineStart = request.LineStart;
        var lineEnd = request.LineEnd;
        var colStart = request.ColStart;
        var colEnd = request.ColEnd;

        var thread = session.Threads.Items.FirstOrDefault(t => t.Id == request.ThreadId.Value);
        if (thread != null)
        {
            if (string.IsNullOrEmpty(filePath))
                filePath = thread.FilePath ?? "";
            lineStart ??= thread.LineStart;
            lineEnd ??= thread.LineEnd;
            colStart ??= thread.ColStart;
            colEnd ??= thread.ColEnd;
        }

        var operation = CreateBaseOperation(DraftOperationType.Reply, request);
        operation.FilePath = filePath;
        operation.LineStart = lineStart;
        operation.LineEnd = lineEnd;
        operation.ColStart = colStart;
        operation.ColEnd = colEnd;
        operation.Body = request.Body ?? "";
        operation.ThreadId = request.ThreadId;
        operation.ParentCommentId = request.ParentCommentId;

        return SaveNewOperation(session, operation);
    }

    public (string Id, DraftOperation Operation) CreateDraftThreadStatusChange(string sessionId, CreateDraftOperationRequest request)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);

        if (!request.ThreadId.HasValue)
            throw new SessionServiceException("Thread status operation requires a thread ID.");
        if (!request.ToThreadStatus.HasValue)
            throw new SessionServiceException("Thread status operation requires a target status.");

        var thread = session.Threads.Items.FirstOrDefault(t => t.Id == request.ThreadId.Value)
            ?? throw new SessionServiceException($"Thread not found: {request.ThreadId.Value}");

        var operation = CreateBaseOperation(DraftOperationType.ThreadStatusChange, request);
        operation.ThreadId = request.ThreadId;
        operation.FromThreadStatus = thread.Status;
        operation.ToThreadStatus = request.ToThreadStatus;
        operation.Note = request.Note;

        return SaveNewOperation(session, operation);
    }

    public (string Id, DraftOperation Operation) CreateDraftCommentReaction(string sessionId, CreateDraftOperationRequest request)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);

        if (!request.ThreadId.HasValue)
            throw new SessionServiceException("Comment reaction operation requires a thread ID.");
        if (!request.CommentId.HasValue)
            throw new SessionServiceException("Comment reaction operation requires a comment ID.");
        if (!request.Reaction.HasValue)
            throw new SessionServiceException("Comment reaction operation requires a reaction.");

        var thread = session.Threads.Items.FirstOrDefault(t => t.Id == request.ThreadId.Value)
            ?? throw new SessionServiceException($"Thread not found: {request.ThreadId.Value}");
        if (!thread.Comments.Any(c => c.Id == request.CommentId.Value && !c.IsDeleted))
            throw new SessionServiceException($"Comment not found: {request.CommentId.Value} in thread {request.ThreadId.Value}");

        var operation = CreateBaseOperation(DraftOperationType.CommentReaction, request);
        operation.ThreadId = request.ThreadId;
        operation.CommentId = request.CommentId;
        operation.Reaction = request.Reaction;
        operation.Note = request.Note;

        return SaveNewOperation(session, operation);
    }

    /// <summary>
    /// Compatibility wrapper for older call sites that create either comments or replies.
    /// </summary>
    public (string Id, DraftOperation Draft) CreateDraft(string sessionId, CreateDraftOperationRequest request)
    {
        return request.ThreadId.HasValue
            ? CreateDraftReply(sessionId, request)
            : CreateDraftComment(sessionId, request);
    }

    public DraftOperation EditDraft(string sessionId, string operationId, string newBody, DraftAuthor? callerAuthor = null)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);
        var operation = GetOperationOrThrow(session, operationId);

        if (!operation.IsComment)
            throw new SessionServiceException($"Cannot edit draft operation {operationId}: operation type is '{operation.OperationType}'");

        if (callerAuthor.HasValue && operation.Author != callerAuthor.Value)
            throw new SessionServiceException(
                $"Cannot edit draft {operationId}: author mismatch (draft author: '{operation.Author}', caller: '{callerAuthor.Value}')");

        if (!operation.CanEdit)
        {
            if (callerAuthor == DraftAuthor.Ai && operation.Status == DraftStatus.Pending)
            {
                operation.Status = DraftStatus.Draft;
            }
            else
            {
                throw new SessionServiceException(
                    $"Cannot edit draft {operationId}: status is '{operation.Status}' (only 'Draft' comment/reply operations can be edited)");
            }
        }

        operation.Body = newBody;
        operation.UpdatedAt = Timestamp();
        _store.Save(session);
        return operation;
    }

    public void DeleteDraft(string sessionId, string operationId, DraftAuthor? callerAuthor = null)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);
        var operation = GetOperationOrThrow(session, operationId);

        if (callerAuthor.HasValue && operation.Author != callerAuthor.Value)
            throw new SessionServiceException(
                $"Cannot delete draft {operationId}: author mismatch (draft author: '{operation.Author}', caller: '{callerAuthor.Value}')");

        if (!operation.CanDelete)
            throw new SessionServiceException(
                $"Cannot delete draft {operationId}: status is '{operation.Status}' (only 'Draft' operations can be deleted)");

        session.DraftOperations.Remove(operationId);
        _store.Save(session);
    }

    public DraftOperation ApproveDraft(string sessionId, string operationId)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);
        var operation = GetOperationOrThrow(session, operationId);

        if (operation.Status != DraftStatus.Draft)
            throw new SessionServiceException(
                $"Cannot approve draft {operationId}: status is '{operation.Status}' (expected 'Draft')");

        operation.Status = DraftStatus.Pending;
        operation.UpdatedAt = Timestamp();
        _store.Save(session);
        return operation;
    }

    public DraftOperation UnapproveDraft(string sessionId, string operationId)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);
        var operation = GetOperationOrThrow(session, operationId);

        if (operation.Status != DraftStatus.Pending)
            throw new SessionServiceException(
                $"Cannot unapprove draft {operationId}: status is '{operation.Status}' (expected 'Pending')");

        operation.Status = DraftStatus.Draft;
        operation.UpdatedAt = Timestamp();
        _store.Save(session);
        return operation;
    }

    public int ApproveAllDrafts(string sessionId)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);
        var now = Timestamp();
        var count = 0;

        foreach (var operation in session.DraftOperations.Values)
        {
            if (operation.Status == DraftStatus.Draft)
            {
                operation.Status = DraftStatus.Pending;
                operation.UpdatedAt = now;
                count++;
            }
        }

        if (count > 0)
            _store.Save(session);

        return count;
    }

    public int DeleteAllDrafts(string sessionId, DraftAuthor? authorFilter = null)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);
        var toDelete = session.DraftOperations
            .Where(kvp => kvp.Value.Status == DraftStatus.Draft)
            .Where(kvp => !authorFilter.HasValue || kvp.Value.Author == authorFilter.Value)
            .Select(kvp => kvp.Key)
            .ToList();

        foreach (var id in toDelete)
        {
            session.DraftOperations.Remove(id);
        }

        if (toDelete.Count > 0)
            _store.Save(session);

        return toDelete.Count;
    }

    public DraftOperation ApproveDraftAction(string sessionId, string actionId) => ApproveDraft(sessionId, actionId);

    public DraftOperation UnapproveDraftAction(string sessionId, string actionId) => UnapproveDraft(sessionId, actionId);

    public void DeleteDraftAction(string sessionId, string actionId, DraftAuthor? callerAuthor = null) => DeleteDraft(sessionId, actionId, callerAuthor);

    public Dictionary<string, DraftOperation> GetDraftActions(string sessionId)
    {
        var session = _store.Load(sessionId);
        return session?.DraftOperations
            .Where(kvp => !kvp.Value.IsComment)
            .ToDictionary(kvp => kvp.Key, kvp => kvp.Value)
            ?? new Dictionary<string, DraftOperation>();
    }

    public (string Id, DraftOperation Draft)? GetDraft(string sessionId, string operationId)
    {
        var session = _store.Load(sessionId);
        if (session == null)
            return null;

        return session.DraftOperations.TryGetValue(operationId, out var operation)
            ? (operationId, operation)
            : null;
    }

    public Dictionary<string, DraftOperation> GetDrafts(string sessionId, string? filePath = null)
    {
        var session = _store.Load(sessionId);
        if (session == null)
            return new Dictionary<string, DraftOperation>();

        var operations = session.DraftOperations.Where(kvp => kvp.Value.IsComment);
        if (filePath != null)
        {
            var normalized = NormalizePath(filePath);
            operations = operations.Where(kvp => NormalizePath(kvp.Value.FilePath) == normalized);
        }

        return operations.ToDictionary(kvp => kvp.Key, kvp => kvp.Value);
    }

    public Dictionary<string, DraftOperation> GetDraftOperations(string sessionId, string? filePath = null)
    {
        var session = _store.Load(sessionId);
        if (session == null)
            return new Dictionary<string, DraftOperation>();

        if (filePath == null)
            return session.DraftOperations;

        var normalized = NormalizePath(filePath);
        return session.DraftOperations
            .Where(kvp => kvp.Value.IsComment && NormalizePath(kvp.Value.FilePath) == normalized)
            .ToDictionary(kvp => kvp.Key, kvp => kvp.Value);
    }

    public Dictionary<string, DraftOperation> GetDraftsByStatus(string sessionId, DraftStatus status)
    {
        var session = _store.Load(sessionId);
        if (session == null)
            return new Dictionary<string, DraftOperation>();

        return session.DraftOperations
            .Where(kvp => kvp.Value.Status == status)
            .ToDictionary(kvp => kvp.Key, kvp => kvp.Value);
    }

    public DraftCounts GetDraftCounts(string sessionId)
    {
        var session = _store.Load(sessionId);
        if (session == null)
            return new DraftCounts();

        var counts = new DraftCounts();
        foreach (var operation in session.DraftOperations.Values)
        {
            counts.Total++;
            switch (operation.Status)
            {
                case DraftStatus.Draft:
                    counts.Draft++;
                    break;
                case DraftStatus.Pending:
                    counts.Pending++;
                    break;
                case DraftStatus.Submitted:
                    counts.Submitted++;
                    break;
            }

            switch (operation.OperationType)
            {
                case DraftOperationType.Comment:
                    counts.Comments++;
                    break;
                case DraftOperationType.Reply:
                    counts.Replies++;
                    break;
                case DraftOperationType.ThreadStatusChange:
                    counts.ThreadStatusChanges++;
                    break;
                case DraftOperationType.CommentReaction:
                    counts.CommentReactions++;
                    break;
            }
        }
        return counts;
    }

    internal void MarkSubmitted(string sessionId, string operationId)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);
        var operation = GetOperationOrThrow(session, operationId);

        operation.Status = DraftStatus.Submitted;
        operation.UpdatedAt = Timestamp();
        _store.Save(session);
    }

    public ReviewSession? LoadSession(string sessionId) => _store.Load(sessionId);

    public string GetSessionPath(string sessionId) => _store.GetSessionPath(sessionId);

    private (string Id, DraftOperation Operation) SaveNewOperation(ReviewSession session, DraftOperation operation)
    {
        var id = Guid.NewGuid().ToString("D");
        session.DraftOperations[id] = operation;
        _store.Save(session);
        return (id, operation);
    }

    private static DraftOperation CreateBaseOperation(DraftOperationType type, CreateDraftOperationRequest request)
    {
        var now = Timestamp();
        return new DraftOperation
        {
            OperationType = type,
            Status = DraftStatus.Draft,
            Author = request.Author ?? DraftAuthor.User,
            AuthorName = request.AuthorName,
            CreatedAt = now,
            UpdatedAt = now,
        };
    }

    private static DraftOperation GetOperationOrThrow(ReviewSession session, string operationId)
    {
        return session.DraftOperations.TryGetValue(operationId, out var operation)
            ? operation
            : throw new SessionServiceException($"Draft operation not found: {operationId}");
    }

    private ReviewSession LoadOrThrow(string sessionId)
    {
        return _store.Load(sessionId)
            ?? throw new SessionServiceException($"Session not found: {sessionId}");
    }

    private static string Timestamp() => DateTime.UtcNow.ToString("o");

    private static string NormalizePath(string path) => path.Replace('\\', '/');
}

public class CreateDraftOperationRequest
{
    public string? FilePath { get; set; }
    public int? LineStart { get; set; }
    public int? LineEnd { get; set; }
    public int? ColStart { get; set; }
    public int? ColEnd { get; set; }
    public string? Body { get; set; }
    public DraftAuthor? Author { get; set; }
    public string? AuthorName { get; set; }
    public int? ThreadId { get; set; }
    public int? ParentCommentId { get; set; }
    public int? CommentId { get; set; }
    public ThreadStatus? ToThreadStatus { get; set; }
    public CommentReaction? Reaction { get; set; }
    public string? Note { get; set; }
}

public sealed class DraftCounts
{
    public int Draft { get; set; }
    public int Pending { get; set; }
    public int Submitted { get; set; }
    public int Total { get; set; }
    public int Comments { get; set; }
    public int Replies { get; set; }
    public int ThreadStatusChanges { get; set; }
    public int CommentReactions { get; set; }
}

public static class DraftMetadataCompatibilityExtensions
{
    public static int ActionsTotal(this DraftMetadata metadata) => metadata.ThreadStatusChanges + metadata.CommentReactions;

    public static int ActionsPending(this DraftMetadata metadata) => 0;
}

public sealed class SessionServiceException : Exception
{
    public SessionServiceException(string message) : base(message) { }
    public SessionServiceException(string message, Exception inner) : base(message, inner) { }
}
