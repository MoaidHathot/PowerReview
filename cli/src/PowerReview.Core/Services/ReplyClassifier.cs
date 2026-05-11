using PowerReview.Core.Models;

namespace PowerReview.Core.Services;

/// <summary>
/// Diffs the previous-sync snapshot of comments against the just-synced thread
/// list and classifies new/edited comments by their relationship to the local
/// user (human) and AI agent.
///
/// Inputs come exclusively from the session — no provider calls — so this is
/// safe to run on every sync without network cost.
///
/// The output is written to <see cref="ThreadsInfo.LastDeltas"/> and consumed by
/// the MCP <c>SyncThreads</c>/<c>GetNewReplies</c> tools and the Lua watcher.
/// </summary>
public static class ReplyClassifier
{
    private const int BodyPreviewMaxChars = 200;

    /// <summary>
    /// Classify the freshly-synced threads against the previous snapshot.
    /// Returns <c>(deltas, nextSnapshot)</c>:
    /// <list type="bullet">
    /// <item><c>deltas</c> is null when the previous snapshot was empty
    /// ("silent priming" — first sync after upgrade); the caller should still
    /// persist <c>nextSnapshot</c> so subsequent syncs can produce real deltas.</item>
    /// <item><c>nextSnapshot</c> is the snapshot to persist for the next sync
    /// (built from <paramref name="freshThreads"/>).</item>
    /// </list>
    /// </summary>
    /// <param name="freshThreads">Threads just returned by the provider.</param>
    /// <param name="previousSnapshot">
    /// The <see cref="ThreadsInfo.PreviousSyncSnapshot"/> persisted from the
    /// last sync. Empty list = no prior snapshot (first sync after upgrade).
    /// </param>
    /// <param name="threadAcks">Per-thread ack watermarks; comments with
    /// <c>id &lt;= through_comment_id</c> are suppressed from deltas.</param>
    /// <param name="localIdentity">Local user identity, if known. May be null for
    /// legacy sessions on the very first sync.</param>
    /// <param name="draftOperations">All draft operations in the session,
    /// used to identify which server comments were published by the AI/user
    /// (via <see cref="DraftOperation.PublishedCommentId"/>).</param>
    public static (ReplyDeltas? Deltas, List<CommentSnapshotEntry> NextSnapshot) Classify(
        IReadOnlyList<CommentThread> freshThreads,
        IReadOnlyList<CommentSnapshotEntry> previousSnapshot,
        IReadOnlyDictionary<string, ThreadAckEntry> threadAcks,
        LocalIdentity? localIdentity,
        IEnumerable<DraftOperation> draftOperations)
    {
        var nextSnapshot = BuildSnapshot(freshThreads);

        // First sync after upgrade — silently prime the snapshot, no deltas.
        // This is the "silent priming" decision: better than treating every
        // existing comment as new, and better than synthesizing acks.
        if (previousSnapshot.Count == 0)
        {
            return (null, nextSnapshot);
        }

        // Build lookups from the previous snapshot for O(1) "was this seen?" checks.
        var prevByCommentId = new Dictionary<int, CommentSnapshotEntry>(previousSnapshot.Count);
        foreach (var entry in previousSnapshot)
        {
            prevByCommentId[entry.CommentId] = entry;
        }

        // Threads that existed in the previous snapshot (regardless of which
        // comments). Used to detect brand-new threads.
        var prevThreadIds = new HashSet<int>();
        foreach (var entry in previousSnapshot)
        {
            prevThreadIds.Add(entry.ThreadId);
        }

        // Index of "this server comment was published by us via a draft" — keyed
        // by published_comment_id. Captures both AI- and user-authored drafts so
        // we can distinguish self-echo from genuine replies.
        var publishedByMe = new Dictionary<int, DraftOperation>();
        foreach (var op in draftOperations)
        {
            if (op.PublishedCommentId.HasValue)
            {
                publishedByMe[op.PublishedCommentId.Value] = op;
            }
        }

        // Per-thread participation flags (computed once per thread, not per comment).
        var aiParticipatedByThread = new Dictionary<int, bool>();
        var humanParticipatedByThread = new Dictionary<int, bool>();
        foreach (var thread in freshThreads)
        {
            bool aiPart = false;
            bool humanPart = false;
            foreach (var c in thread.Comments)
            {
                if (c.IsDeleted) continue;
                var origin = ClassifyAuthor(c, localIdentity, publishedByMe);
                if (origin == AuthorOrigin.AiViaDraft) aiPart = true;
                if (origin == AuthorOrigin.HumanLocal || origin == AuthorOrigin.HumanViaDraft) humanPart = true;
                if (aiPart && humanPart) break;
            }
            aiParticipatedByThread[thread.Id] = aiPart;
            humanParticipatedByThread[thread.Id] = humanPart;
        }

        var deltas = new ReplyDeltas
        {
            ComputedAt = DateTime.UtcNow.ToString("o"),
        };

        foreach (var thread in freshThreads)
        {
            var threadAck = threadAcks.GetValueOrDefault(thread.Id.ToString());
            var ackThrough = threadAck?.ThroughCommentId ?? 0;
            var aiParticipated = aiParticipatedByThread.GetValueOrDefault(thread.Id);
            var humanParticipated = humanParticipatedByThread.GetValueOrDefault(thread.Id);
            var threadIsNew = !prevThreadIds.Contains(thread.Id);

            foreach (var comment in thread.Comments)
            {
                if (comment.IsDeleted) continue;

                // Acked: skip entirely.
                if (comment.Id <= ackThrough) continue;

                var change = DetectChange(comment, prevByCommentId);
                if (change == null) continue; // Unchanged, not a delta.

                var origin = ClassifyAuthor(comment, localIdentity, publishedByMe);
                var entry = BuildDeltaEntry(thread, comment, change, aiParticipated, humanParticipated);

                // Self-echo: our own publish reflected back. Surfaced under
                // SelfEcho but never under the actionable buckets.
                if (origin == AuthorOrigin.AiViaDraft || origin == AuthorOrigin.HumanViaDraft || origin == AuthorOrigin.HumanLocal)
                {
                    deltas.SelfEcho.Add(entry);
                    continue;
                }

                // Authored by someone else — bucket by thread participation.
                if (aiParticipated)
                {
                    deltas.ReplyToAi.Add(entry);
                }
                else if (humanParticipated)
                {
                    deltas.ReplyToHuman.Add(entry);
                }
                else if (threadIsNew && IsThreadOpener(thread, comment))
                {
                    // Brand-new thread by a third party — bucket separately so
                    // the AI/UI can distinguish "new topic" from "reply".
                    deltas.NewThreadOthers.Add(entry);
                }
                else
                {
                    deltas.ReplyInOthersThread.Add(entry);
                }
            }
        }

        return (deltas, nextSnapshot);
    }

    /// <summary>
    /// Build a <see cref="ThreadsInfo.PreviousSyncSnapshot"/> from a thread list.
    /// Public so callers can persist a snapshot manually (e.g. when classification was skipped).
    /// </summary>
    public static List<CommentSnapshotEntry> BuildSnapshot(IReadOnlyList<CommentThread> threads)
    {
        var snapshot = new List<CommentSnapshotEntry>();
        foreach (var thread in threads)
        {
            foreach (var comment in thread.Comments)
            {
                if (comment.IsDeleted) continue;
                snapshot.Add(new CommentSnapshotEntry
                {
                    ThreadId = thread.Id,
                    CommentId = comment.Id,
                    UpdatedAt = comment.UpdatedAt,
                });
            }
        }
        return snapshot;
    }

    private enum AuthorOrigin
    {
        /// <summary>Authored by AI and submitted via a PowerReview draft (definitive match via PublishedCommentId).</summary>
        AiViaDraft,

        /// <summary>Authored by the local user via a PowerReview draft (definitive match via PublishedCommentId).</summary>
        HumanViaDraft,

        /// <summary>Authored by the local user but not via a tracked draft (id-matched against LocalIdentity).</summary>
        HumanLocal,

        /// <summary>Authored by someone other than the local user.</summary>
        Other,
    }

    private static AuthorOrigin ClassifyAuthor(
        Comment comment,
        LocalIdentity? localIdentity,
        IReadOnlyDictionary<int, DraftOperation> publishedByMe)
    {
        // Definitive: this is the published image of one of our drafts.
        if (publishedByMe.TryGetValue(comment.Id, out var op))
        {
            return op.Author == DraftAuthor.Ai ? AuthorOrigin.AiViaDraft : AuthorOrigin.HumanViaDraft;
        }

        // Heuristic: same provider id as the local user.
        if (localIdentity != null
            && !string.IsNullOrEmpty(localIdentity.Id)
            && string.Equals(comment.Author?.Id, localIdentity.Id, StringComparison.OrdinalIgnoreCase))
        {
            return AuthorOrigin.HumanLocal;
        }

        return AuthorOrigin.Other;
    }

    /// <summary>"new" if the comment id wasn't in the previous snapshot, "edited" if it was but updated_at changed, null otherwise.</summary>
    private static string? DetectChange(Comment comment, IReadOnlyDictionary<int, CommentSnapshotEntry> prevByCommentId)
    {
        if (!prevByCommentId.TryGetValue(comment.Id, out var prev))
        {
            return "new";
        }

        if (!string.Equals(prev.UpdatedAt ?? "", comment.UpdatedAt ?? "", StringComparison.Ordinal))
        {
            return "edited";
        }

        return null;
    }

    private static DeltaComment BuildDeltaEntry(
        CommentThread thread,
        Comment comment,
        string change,
        bool aiParticipated,
        bool humanParticipated)
    {
        return new DeltaComment
        {
            ThreadId = thread.Id,
            CommentId = comment.Id,
            ParentCommentId = comment.ParentCommentId,
            Change = change,
            FilePath = thread.FilePath,
            LineStart = thread.LineStart,
            LineEnd = thread.LineEnd,
            Author = comment.Author ?? new PersonIdentity(),
            CreatedAt = comment.CreatedAt,
            UpdatedAt = comment.UpdatedAt,
            BodyPreview = BuildBodyPreview(comment.Body),
            AiParticipated = aiParticipated,
            HumanParticipated = humanParticipated,
        };
    }

    private static string BuildBodyPreview(string? body)
    {
        if (string.IsNullOrEmpty(body)) return "";
        var single = body.Replace("\r", " ").Replace("\n", " ").Trim();
        return single.Length <= BodyPreviewMaxChars
            ? single
            : single[..BodyPreviewMaxChars] + "…";
    }

    /// <summary>
    /// Heuristic for "this comment is the thread opener". The provider sends
    /// thread comments in chronological order with the opener first; we use
    /// that ordering rather than relying on parent_comment_id which is not
    /// always set for openers.
    /// </summary>
    private static bool IsThreadOpener(CommentThread thread, Comment comment)
    {
        return thread.Comments.Count > 0 && thread.Comments[0].Id == comment.Id;
    }
}
