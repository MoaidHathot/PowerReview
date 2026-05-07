using PowerReview.Core.Models;
using PowerReview.Core.Store;

namespace PowerReview.Core.Services;

/// <summary>
/// Manages draft comment operations within a review session.
/// All mutations acquire a file lock, load the session, mutate, save, and release.
/// </summary>
public sealed class SessionService
{
    private readonly SessionStore _store;

    public SessionService(SessionStore store)
    {
        _store = store;
    }

    /// <summary>
    /// Create a new draft comment and add it to the session.
    /// Validates that file-attached comments reference a file that exists in the PR's changed files,
    /// and that the comment body is not empty.
    /// </summary>
    /// <returns>The created draft's ID and the draft itself.</returns>
    public (string Id, DraftComment Draft) CreateDraft(string sessionId, CreateDraftRequest request)
    {
        using var _ = _store.AcquireLock(sessionId);

        var session = LoadOrThrow(sessionId);

        // Validate body is not empty for non-reply drafts
        var body = request.Body ?? "";
        var isReply = request.ThreadId.HasValue;
        if (string.IsNullOrWhiteSpace(body) && !isReply)
            throw new SessionServiceException("Comment body cannot be empty.");

        // Validate file path exists in the PR's changed files (skip for replies and PR-level comments)
        var filePath = request.FilePath ?? "";
        var lineStart = request.LineStart;
        var lineEnd = request.LineEnd;
        var colStart = request.ColStart;
        var colEnd = request.ColEnd;

        if (isReply)
        {
            var thread = session.Threads.Items.FirstOrDefault(t => t.Id == request.ThreadId!.Value);
            if (thread != null)
            {
                if (string.IsNullOrEmpty(filePath))
                    filePath = thread.FilePath ?? "";
                lineStart ??= thread.LineStart;
                lineEnd ??= thread.LineEnd;
                colStart ??= thread.ColStart;
                colEnd ??= thread.ColEnd;
            }
        }

        if (!string.IsNullOrEmpty(filePath) && !isReply)
        {
            var normalized = NormalizePath(filePath);
            var fileExists = session.Files.Any(f =>
                NormalizePath(f.Path).Equals(normalized, StringComparison.OrdinalIgnoreCase));

            if (!fileExists)
                throw new SessionServiceException(
                    $"File '{filePath}' is not part of this PR's changed files. " +
                    $"Use 'files' command to see the list of changed files.");
        }

        var now = Timestamp();
        var id = Guid.NewGuid().ToString("D");

        var draft = new DraftComment
        {
            FilePath = filePath,
            LineStart = lineStart,
            LineEnd = lineEnd,
            ColStart = colStart,
            ColEnd = colEnd,
            Body = body,
            Status = DraftStatus.Draft,
            Author = request.Author ?? DraftAuthor.User,
            AuthorName = request.AuthorName,
            ThreadId = request.ThreadId,
            ParentCommentId = request.ParentCommentId,
            CreatedAt = now,
            UpdatedAt = now,
        };

        session.Drafts[id] = draft;
        _store.Save(session);

        return (id, draft);
    }

    /// <summary>
    /// Edit the body of an existing draft comment.
    /// Only drafts in the "Draft" status can be edited.
    /// When <paramref name="callerAuthor"/> is specified, enforces that only drafts
    /// with a matching author can be edited (safety guard for MCP/AI callers).
    /// If an AI caller edits a Pending draft, status is reset to Draft (requires re-approval).
    /// </summary>
    public DraftComment EditDraft(string sessionId, string draftId, string newBody, DraftAuthor? callerAuthor = null)
    {
        using var _ = _store.AcquireLock(sessionId);

        var session = LoadOrThrow(sessionId);

        if (!session.Drafts.TryGetValue(draftId, out var draft))
            throw new SessionServiceException($"Draft not found: {draftId}");

        // Author guard: when a caller declares its identity, it can only edit its own drafts
        if (callerAuthor.HasValue && draft.Author != callerAuthor.Value)
            throw new SessionServiceException(
                $"Cannot edit draft {draftId}: author mismatch (draft author: '{draft.Author}', caller: '{callerAuthor.Value}')");

        if (!draft.CanEdit)
        {
            // AI callers editing a Pending draft: reset to Draft (requires re-approval)
            if (callerAuthor == DraftAuthor.Ai && draft.Status == DraftStatus.Pending)
            {
                draft.Status = DraftStatus.Draft;
            }
            else
            {
                throw new SessionServiceException(
                    $"Cannot edit draft {draftId}: status is '{draft.Status}' (only 'Draft' drafts can be edited)");
            }
        }

        draft.Body = newBody;
        draft.UpdatedAt = Timestamp();
        _store.Save(session);

        return draft;
    }

    /// <summary>
    /// Delete a draft comment from the session.
    /// Only drafts in the "Draft" status can be deleted.
    /// When <paramref name="callerAuthor"/> is specified, enforces that only drafts
    /// with a matching author can be deleted (safety guard for MCP/AI callers).
    /// </summary>
    public void DeleteDraft(string sessionId, string draftId, DraftAuthor? callerAuthor = null)
    {
        using var _ = _store.AcquireLock(sessionId);

        var session = LoadOrThrow(sessionId);

        if (!session.Drafts.TryGetValue(draftId, out var draft))
            throw new SessionServiceException($"Draft not found: {draftId}");

        // Author guard: when a caller declares its identity, it can only delete its own drafts
        if (callerAuthor.HasValue && draft.Author != callerAuthor.Value)
            throw new SessionServiceException(
                $"Cannot delete draft {draftId}: author mismatch (draft author: '{draft.Author}', caller: '{callerAuthor.Value}')");

        if (!draft.CanDelete)
            throw new SessionServiceException(
                $"Cannot delete draft {draftId}: status is '{draft.Status}' (only 'Draft' drafts can be deleted)");

        session.Drafts.Remove(draftId);
        _store.Save(session);
    }

    /// <summary>
    /// Approve a draft comment, transitioning it from "Draft" to "Pending".
    /// Pending drafts are ready for submission to the remote provider.
    /// </summary>
    public DraftComment ApproveDraft(string sessionId, string draftId)
    {
        using var _ = _store.AcquireLock(sessionId);

        var session = LoadOrThrow(sessionId);

        if (!session.Drafts.TryGetValue(draftId, out var draft))
            throw new SessionServiceException($"Draft not found: {draftId}");

        if (draft.Status != DraftStatus.Draft)
            throw new SessionServiceException(
                $"Cannot approve draft {draftId}: status is '{draft.Status}' (expected 'Draft')");

        draft.Status = DraftStatus.Pending;
        draft.UpdatedAt = Timestamp();
        _store.Save(session);

        return draft;
    }

    /// <summary>
    /// Unapprove a draft comment, transitioning it from "Pending" back to "Draft".
    /// This re-enables editing and deletion.
    /// </summary>
    public DraftComment UnapproveDraft(string sessionId, string draftId)
    {
        using var _ = _store.AcquireLock(sessionId);

        var session = LoadOrThrow(sessionId);

        if (!session.Drafts.TryGetValue(draftId, out var draft))
            throw new SessionServiceException($"Draft not found: {draftId}");

        if (draft.Status != DraftStatus.Pending)
            throw new SessionServiceException(
                $"Cannot unapprove draft {draftId}: status is '{draft.Status}' (expected 'Pending')");

        draft.Status = DraftStatus.Draft;
        draft.UpdatedAt = Timestamp();
        _store.Save(session);

        return draft;
    }

    /// <summary>
    /// Approve all drafts in "Draft" status, transitioning them to "Pending".
    /// Silently skips drafts that are already Pending or Submitted.
    /// </summary>
    /// <returns>The number of drafts that were approved.</returns>
    public int ApproveAllDrafts(string sessionId)
    {
        using var _ = _store.AcquireLock(sessionId);

        var session = LoadOrThrow(sessionId);
        var now = Timestamp();
        var count = 0;

        foreach (var draft in session.Drafts.Values)
        {
            if (draft.Status == DraftStatus.Draft)
            {
                draft.Status = DraftStatus.Pending;
                draft.UpdatedAt = now;
                count++;
            }
        }

        if (count > 0)
            _store.Save(session);

        return count;
    }

    /// <summary>
    /// Delete all drafts matching the given author filter.
    /// Only drafts in "Draft" status can be deleted.
    /// If authorFilter is null, deletes all deletable drafts regardless of author.
    /// </summary>
    /// <returns>The number of drafts that were deleted.</returns>
    public int DeleteAllDrafts(string sessionId, DraftAuthor? authorFilter = null)
    {
        using var lck = _store.AcquireLock(sessionId);

        var session = LoadOrThrow(sessionId);
        var toDelete = new List<string>();

        foreach (var (id, draft) in session.Drafts)
        {
            if (draft.Status != DraftStatus.Draft)
                continue;

            if (authorFilter.HasValue && draft.Author != authorFilter.Value)
                continue;

            toDelete.Add(id);
        }

        foreach (var id in toDelete)
        {
            session.Drafts.Remove(id);
        }

        if (toDelete.Count > 0)
            _store.Save(session);

        return toDelete.Count;
    }

    /// <summary>
    /// Create a draft action to change a remote thread status after user approval.
    /// </summary>
    public (string Id, DraftAction Action) CreateDraftThreadStatusChange(string sessionId, CreateDraftActionRequest request)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);

        if (!request.ToThreadStatus.HasValue)
            throw new SessionServiceException("Thread status action requires a target status.");

        var thread = session.Threads.Items.FirstOrDefault(t => t.Id == request.ThreadId)
            ?? throw new SessionServiceException($"Thread not found: {request.ThreadId}");

        var now = Timestamp();
        var id = Guid.NewGuid().ToString("D");
        var action = new DraftAction
        {
            ActionType = DraftActionType.ThreadStatusChange,
            Status = DraftStatus.Draft,
            Author = request.Author ?? DraftAuthor.User,
            AuthorName = request.AuthorName,
            ThreadId = request.ThreadId,
            FromThreadStatus = thread.Status,
            ToThreadStatus = request.ToThreadStatus,
            Note = request.Note,
            CreatedAt = now,
            UpdatedAt = now,
        };

        session.DraftActions[id] = action;
        _store.Save(session);
        return (id, action);
    }

    /// <summary>
    /// Create a draft action to react to a remote comment after user approval.
    /// </summary>
    public (string Id, DraftAction Action) CreateDraftCommentReaction(string sessionId, CreateDraftActionRequest request)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);

        if (!request.CommentId.HasValue)
            throw new SessionServiceException("Comment reaction action requires a comment ID.");
        if (!request.Reaction.HasValue)
            throw new SessionServiceException("Comment reaction action requires a reaction.");

        var thread = session.Threads.Items.FirstOrDefault(t => t.Id == request.ThreadId)
            ?? throw new SessionServiceException($"Thread not found: {request.ThreadId}");
        if (!thread.Comments.Any(c => c.Id == request.CommentId.Value && !c.IsDeleted))
            throw new SessionServiceException($"Comment not found: {request.CommentId.Value} in thread {request.ThreadId}");

        var now = Timestamp();
        var id = Guid.NewGuid().ToString("D");
        var action = new DraftAction
        {
            ActionType = DraftActionType.CommentReaction,
            Status = DraftStatus.Draft,
            Author = request.Author ?? DraftAuthor.User,
            AuthorName = request.AuthorName,
            ThreadId = request.ThreadId,
            CommentId = request.CommentId,
            Reaction = request.Reaction,
            Note = request.Note,
            CreatedAt = now,
            UpdatedAt = now,
        };

        session.DraftActions[id] = action;
        _store.Save(session);
        return (id, action);
    }

    public DraftAction ApproveDraftAction(string sessionId, string actionId)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);

        if (!session.DraftActions.TryGetValue(actionId, out var action))
            throw new SessionServiceException($"Draft action not found: {actionId}");
        if (action.Status != DraftStatus.Draft)
            throw new SessionServiceException(
                $"Cannot approve draft action {actionId}: status is '{action.Status}' (expected 'Draft')");

        action.Status = DraftStatus.Pending;
        action.UpdatedAt = Timestamp();
        _store.Save(session);
        return action;
    }

    public DraftAction UnapproveDraftAction(string sessionId, string actionId)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);

        if (!session.DraftActions.TryGetValue(actionId, out var action))
            throw new SessionServiceException($"Draft action not found: {actionId}");
        if (action.Status != DraftStatus.Pending)
            throw new SessionServiceException(
                $"Cannot unapprove draft action {actionId}: status is '{action.Status}' (expected 'Pending')");

        action.Status = DraftStatus.Draft;
        action.UpdatedAt = Timestamp();
        _store.Save(session);
        return action;
    }

    public void DeleteDraftAction(string sessionId, string actionId, DraftAuthor? callerAuthor = null)
    {
        using var _ = _store.AcquireLock(sessionId);
        var session = LoadOrThrow(sessionId);

        if (!session.DraftActions.TryGetValue(actionId, out var action))
            throw new SessionServiceException($"Draft action not found: {actionId}");
        if (callerAuthor.HasValue && action.Author != callerAuthor.Value)
            throw new SessionServiceException(
                $"Cannot delete draft action {actionId}: author mismatch (action author: '{action.Author}', caller: '{callerAuthor.Value}')");
        if (!action.CanDelete)
            throw new SessionServiceException(
                $"Cannot delete draft action {actionId}: status is '{action.Status}' (only 'Draft' actions can be deleted)");

        session.DraftActions.Remove(actionId);
        _store.Save(session);
    }

    public Dictionary<string, DraftAction> GetDraftActions(string sessionId)
    {
        var session = _store.Load(sessionId);
        return session?.DraftActions ?? new Dictionary<string, DraftAction>();
    }

    /// <summary>
    /// Get a specific draft by ID.
    /// </summary>
    public (string Id, DraftComment Draft)? GetDraft(string sessionId, string draftId)
    {
        var session = _store.Load(sessionId);
        if (session == null)
            return null;

        return session.Drafts.TryGetValue(draftId, out var draft)
            ? (draftId, draft)
            : null;
    }

    /// <summary>
    /// Get all drafts in the session, optionally filtered by file path.
    /// </summary>
    public Dictionary<string, DraftComment> GetDrafts(string sessionId, string? filePath = null)
    {
        var session = _store.Load(sessionId);
        if (session == null)
            return new Dictionary<string, DraftComment>();

        if (filePath == null)
            return session.Drafts;

        var normalized = NormalizePath(filePath);
        return session.Drafts
            .Where(kvp => NormalizePath(kvp.Value.FilePath) == normalized)
            .ToDictionary(kvp => kvp.Key, kvp => kvp.Value);
    }

    /// <summary>
    /// Get all drafts with a specific status.
    /// </summary>
    public Dictionary<string, DraftComment> GetDraftsByStatus(string sessionId, DraftStatus status)
    {
        var session = _store.Load(sessionId);
        if (session == null)
            return new Dictionary<string, DraftComment>();

        return session.Drafts
            .Where(kvp => kvp.Value.Status == status)
            .ToDictionary(kvp => kvp.Key, kvp => kvp.Value);
    }

    /// <summary>
    /// Get counts of drafts by status.
    /// </summary>
    public DraftCounts GetDraftCounts(string sessionId)
    {
        var session = _store.Load(sessionId);
        if (session == null)
            return new DraftCounts();

        var counts = new DraftCounts();
        foreach (var draft in session.Drafts.Values)
        {
            counts.Total++;
            switch (draft.Status)
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
        }
        return counts;
    }

    /// <summary>
    /// Mark a draft as submitted. Internal use only — called during the submission flow.
    /// No status guard: assumes caller has already verified the draft is Pending.
    /// </summary>
    internal void MarkSubmitted(string sessionId, string draftId)
    {
        using var _ = _store.AcquireLock(sessionId);

        var session = LoadOrThrow(sessionId);

        if (!session.Drafts.TryGetValue(draftId, out var draft))
            throw new SessionServiceException($"Draft not found: {draftId}");

        draft.Status = DraftStatus.Submitted;
        draft.UpdatedAt = Timestamp();
        _store.Save(session);
    }

    internal void MarkActionSubmitted(string sessionId, string actionId)
    {
        using var _ = _store.AcquireLock(sessionId);

        var session = LoadOrThrow(sessionId);

        if (!session.DraftActions.TryGetValue(actionId, out var action))
            throw new SessionServiceException($"Draft action not found: {actionId}");

        action.Status = DraftStatus.Submitted;
        action.UpdatedAt = Timestamp();
        _store.Save(session);
    }

    /// <summary>
    /// Load the full session. For read-only access by other services.
    /// </summary>
    public ReviewSession? LoadSession(string sessionId) => _store.Load(sessionId);

    /// <summary>
    /// Get the file path to a session. Useful for file-watching clients.
    /// </summary>
    public string GetSessionPath(string sessionId) => _store.GetSessionPath(sessionId);

    private ReviewSession LoadOrThrow(string sessionId)
    {
        var session = _store.Load(sessionId)
            ?? throw new SessionServiceException($"Session not found: {sessionId}");
        return session;
    }

    private static string Timestamp() => DateTime.UtcNow.ToString("o");

    private static string NormalizePath(string path) => path.Replace('\\', '/');
}

/// <summary>
/// Request to create a new draft comment.
/// </summary>
public sealed class CreateDraftRequest
{
    public string? FilePath { get; set; }
    public int? LineStart { get; set; }
    public int? LineEnd { get; set; }
    public int? ColStart { get; set; }
    public int? ColEnd { get; set; }
    public string? Body { get; set; }
    public DraftAuthor? Author { get; set; }
    public string? AuthorName { get; set; }

    /// <summary>
    /// If set, this draft is a reply to an existing remote thread.
    /// </summary>
    public int? ThreadId { get; set; }
    public int? ParentCommentId { get; set; }
}

/// <summary>
/// Request to create a non-comment draft action.
/// </summary>
public sealed class CreateDraftActionRequest
{
    public int ThreadId { get; set; }
    public int? CommentId { get; set; }
    public ThreadStatus? ToThreadStatus { get; set; }
    public CommentReaction? Reaction { get; set; }
    public string? Note { get; set; }
    public DraftAuthor? Author { get; set; }
    public string? AuthorName { get; set; }
}

/// <summary>
/// Draft count summary by status.
/// </summary>
public sealed class DraftCounts
{
    public int Draft { get; set; }
    public int Pending { get; set; }
    public int Submitted { get; set; }
    public int Total { get; set; }
}

/// <summary>
/// Exception thrown by SessionService for business logic errors.
/// </summary>
public sealed class SessionServiceException : Exception
{
    public SessionServiceException(string message) : base(message) { }
    public SessionServiceException(string message, Exception inner) : base(message, inner) { }
}
