using PowerReview.Core.Models;
using PowerReview.Core.Services;

namespace PowerReview.Core.Tests;

/// <summary>
/// Tests for the ReplyClassifier service — diffs/classifies new comments
/// against the previous-sync snapshot so the AI/UI can surface "new replies".
/// </summary>
public class ReplyClassifierTests
{
    private const string LocalUserId = "user-local-guid";
    private const string OtherUserId = "user-other-guid";
    private const string OtherUser2Id = "user-other-2-guid";

    private static LocalIdentity LocalIdentity() => new()
    {
        Id = LocalUserId,
        DisplayName = "Local User",
        UniqueName = "local@example.com",
        ResolvedAt = "2026-05-11T00:00:00Z",
    };

    private static Comment Comment(int id, int threadId, string authorId, string body = "body", string updatedAt = "t", int? parentId = null)
    {
        return new Comment
        {
            Id = id,
            ThreadId = threadId,
            Author = new PersonIdentity { Id = authorId, Name = "User-" + authorId },
            Body = body,
            CreatedAt = updatedAt,
            UpdatedAt = updatedAt,
            ParentCommentId = parentId,
        };
    }

    private static CommentThread Thread(int id, params Comment[] comments)
    {
        return new CommentThread
        {
            Id = id,
            Status = ThreadStatus.Active,
            FilePath = "src/file.cs",
            LineStart = 10,
            Comments = comments.ToList(),
        };
    }

    private static DraftOperation AiPublishedDraft(int publishedCommentId, int threadId)
    {
        return new DraftOperation
        {
            OperationType = DraftOperationType.Reply,
            Status = DraftStatus.Submitted,
            Author = DraftAuthor.Ai,
            ThreadId = threadId,
            PublishedThreadId = threadId,
            PublishedCommentId = publishedCommentId,
        };
    }

    [Fact]
    public void FirstSync_NoPreviousSnapshot_SilentPriming_ReturnsNullDeltas()
    {
        // The very first sync after upgrade has an empty PreviousSyncSnapshot.
        // We must NOT treat all existing comments as "new" — that would flood
        // the user with notifications. Instead, return null deltas and let the
        // caller persist the snapshot for next time.
        var threads = new[] { Thread(1, Comment(100, 1, OtherUserId)) };

        var (deltas, snapshot) = ReplyClassifier.Classify(
            threads,
            previousSnapshot: [],
            threadAcks: new Dictionary<string, ThreadAckEntry>(),
            localIdentity: LocalIdentity(),
            draftOperations: []);

        Assert.Null(deltas);
        Assert.Single(snapshot);
        Assert.Equal(1, snapshot[0].ThreadId);
        Assert.Equal(100, snapshot[0].CommentId);
    }

    [Fact]
    public void NewCommentAfterAiReply_BucketsAsReplyToAi()
    {
        // Setup: a thread the AI participated in (via PublishedCommentId), and a
        // brand-new third-party reply lands. Should be `reply_to_ai`.
        var threads = new[]
        {
            Thread(1,
                Comment(100, 1, OtherUserId, "original"),
                Comment(101, 1, LocalUserId, "ai reply"),  // Our AI's published reply
                Comment(102, 1, OtherUserId, "follow up")),  // The new reply we want to detect
        };
        var prev = new List<CommentSnapshotEntry>
        {
            new() { ThreadId = 1, CommentId = 100, UpdatedAt = "t" },
            new() { ThreadId = 1, CommentId = 101, UpdatedAt = "t" },
        };

        var (deltas, _) = ReplyClassifier.Classify(
            threads,
            prev,
            new Dictionary<string, ThreadAckEntry>(),
            LocalIdentity(),
            new[] { AiPublishedDraft(publishedCommentId: 101, threadId: 1) });

        Assert.NotNull(deltas);
        Assert.Single(deltas!.ReplyToAi);
        Assert.Equal(102, deltas.ReplyToAi[0].CommentId);
        Assert.True(deltas.ReplyToAi[0].AiParticipated);
        Assert.Empty(deltas.ReplyToHuman);
        Assert.Empty(deltas.ReplyInOthersThread);
    }

    [Fact]
    public void NewCommentAfterHumanReply_BucketsAsReplyToHuman()
    {
        // Thread where local human (no AI draft) participated.
        var threads = new[]
        {
            Thread(1,
                Comment(100, 1, OtherUserId, "original"),
                Comment(101, 1, LocalUserId, "human reply"),
                Comment(102, 1, OtherUserId, "follow up")),
        };
        var prev = new List<CommentSnapshotEntry>
        {
            new() { ThreadId = 1, CommentId = 100, UpdatedAt = "t" },
            new() { ThreadId = 1, CommentId = 101, UpdatedAt = "t" },
        };

        var (deltas, _) = ReplyClassifier.Classify(
            threads, prev, new Dictionary<string, ThreadAckEntry>(),
            LocalIdentity(),
            draftOperations: []);  // No drafts — human posted "directly"

        Assert.NotNull(deltas);
        Assert.Empty(deltas!.ReplyToAi);
        Assert.Single(deltas.ReplyToHuman);
        Assert.Equal(102, deltas.ReplyToHuman[0].CommentId);
        Assert.True(deltas.ReplyToHuman[0].HumanParticipated);
        Assert.False(deltas.ReplyToHuman[0].AiParticipated);
    }

    [Fact]
    public void NewCommentInThirdPartyThread_BucketsAsReplyInOthersThread()
    {
        // Thread where neither local user nor AI participated; an existing
        // third party adds a reply.
        var threads = new[]
        {
            Thread(1,
                Comment(100, 1, OtherUserId, "original"),
                Comment(101, 1, OtherUser2Id, "follow up")),
        };
        var prev = new List<CommentSnapshotEntry>
        {
            new() { ThreadId = 1, CommentId = 100, UpdatedAt = "t" },
        };

        var (deltas, _) = ReplyClassifier.Classify(
            threads, prev, new Dictionary<string, ThreadAckEntry>(),
            LocalIdentity(),
            draftOperations: []);

        Assert.NotNull(deltas);
        Assert.Empty(deltas!.ReplyToAi);
        Assert.Empty(deltas.ReplyToHuman);
        Assert.Single(deltas.ReplyInOthersThread);
        Assert.Equal(101, deltas.ReplyInOthersThread[0].CommentId);
    }

    [Fact]
    public void NewThreadByThirdParty_BucketsAsNewThreadOthers()
    {
        // The whole thread is brand-new and authored by someone else.
        var threads = new[]
        {
            Thread(2, Comment(200, 2, OtherUserId, "brand new topic")),
        };
        // Snapshot has unrelated thread, so thread 2 is "new".
        var prev = new List<CommentSnapshotEntry>
        {
            new() { ThreadId = 1, CommentId = 100, UpdatedAt = "t" },
        };

        var (deltas, _) = ReplyClassifier.Classify(
            threads, prev, new Dictionary<string, ThreadAckEntry>(),
            LocalIdentity(),
            draftOperations: []);

        Assert.NotNull(deltas);
        Assert.Single(deltas!.NewThreadOthers);
        Assert.Equal(200, deltas.NewThreadOthers[0].CommentId);
        Assert.Equal("new", deltas.NewThreadOthers[0].Change);
        Assert.Empty(deltas.ReplyInOthersThread);
    }

    [Fact]
    public void OurOwnPublishedComment_GoesToSelfEcho_NotAnyActionableBucket()
    {
        // Server returns a comment whose id matches one of our PublishedCommentId.
        // It's "our own publish reflected back" — must NOT appear as a new reply.
        var threads = new[]
        {
            Thread(1,
                Comment(100, 1, OtherUserId, "original"),
                Comment(101, 1, LocalUserId, "ai reply just published")),
        };
        var prev = new List<CommentSnapshotEntry>
        {
            new() { ThreadId = 1, CommentId = 100, UpdatedAt = "t" },
        };

        var (deltas, _) = ReplyClassifier.Classify(
            threads, prev, new Dictionary<string, ThreadAckEntry>(),
            LocalIdentity(),
            new[] { AiPublishedDraft(publishedCommentId: 101, threadId: 1) });

        Assert.NotNull(deltas);
        Assert.Empty(deltas!.ReplyToAi);
        Assert.Empty(deltas.ReplyToHuman);
        Assert.Empty(deltas.ReplyInOthersThread);
        Assert.Single(deltas.SelfEcho);
        Assert.Equal(101, deltas.SelfEcho[0].CommentId);
    }

    [Fact]
    public void HumanIdentityMatch_WithoutDraft_GoesToSelfEcho()
    {
        // Local human posted directly via the AzDO web UI (not via PowerReview),
        // so there's no PublishedCommentId — but the author id matches the
        // LocalIdentity. Should still be self-echo.
        var threads = new[]
        {
            Thread(1,
                Comment(100, 1, OtherUserId, "original"),
                Comment(101, 1, LocalUserId, "I posted this from the web UI")),
        };
        var prev = new List<CommentSnapshotEntry>
        {
            new() { ThreadId = 1, CommentId = 100, UpdatedAt = "t" },
        };

        var (deltas, _) = ReplyClassifier.Classify(
            threads, prev, new Dictionary<string, ThreadAckEntry>(),
            LocalIdentity(),
            draftOperations: []);

        Assert.NotNull(deltas);
        Assert.Empty(deltas!.ReplyToAi);
        Assert.Empty(deltas.ReplyToHuman);
        Assert.Single(deltas.SelfEcho);
    }

    [Fact]
    public void EditedComment_WithDifferentUpdatedAt_IsClassifiedAsEdited()
    {
        var threads = new[]
        {
            Thread(1,
                Comment(100, 1, OtherUserId, "original")),
        };
        var prev = new List<CommentSnapshotEntry>
        {
            // Same comment id, but the snapshot recorded an older updated_at.
            new() { ThreadId = 1, CommentId = 100, UpdatedAt = "2026-05-10T10:00:00Z" },
        };

        var (deltas, _) = ReplyClassifier.Classify(
            threads, prev, new Dictionary<string, ThreadAckEntry>(),
            LocalIdentity(),
            draftOperations: []);

        Assert.NotNull(deltas);
        // Single comment thread, third party => new_thread_others bucket
        // (because thread id 1 is not in prev's distinct thread set... wait, it IS).
        // Actually since prev has thread 1, the thread isn't "new", so it lands
        // in reply_in_others_thread.
        Assert.Single(deltas!.ReplyInOthersThread);
        Assert.Equal("edited", deltas.ReplyInOthersThread[0].Change);
    }

    [Fact]
    public void AckedComment_IsSuppressed()
    {
        var threads = new[]
        {
            Thread(1,
                Comment(100, 1, OtherUserId),
                Comment(101, 1, LocalUserId),
                Comment(102, 1, OtherUserId),
                Comment(103, 1, OtherUserId)),  // <- the new one
        };
        var prev = new List<CommentSnapshotEntry>
        {
            new() { ThreadId = 1, CommentId = 100, UpdatedAt = "t" },
            new() { ThreadId = 1, CommentId = 101, UpdatedAt = "t" },
            new() { ThreadId = 1, CommentId = 102, UpdatedAt = "t" },
        };
        // Ack everything up through comment 103, which should suppress the new comment too.
        var acks = new Dictionary<string, ThreadAckEntry>
        {
            ["1"] = new ThreadAckEntry { ThroughCommentId = 103 },
        };

        var (deltas, _) = ReplyClassifier.Classify(
            threads, prev, acks, LocalIdentity(),
            new[] { AiPublishedDraft(publishedCommentId: 101, threadId: 1) });

        Assert.NotNull(deltas);
        Assert.Empty(deltas!.ReplyToAi);
        Assert.Empty(deltas.ReplyToHuman);
        Assert.Empty(deltas.ReplyInOthersThread);
        Assert.Empty(deltas.NewThreadOthers);
    }

    [Fact]
    public void DeletedComments_AreIgnored()
    {
        var threads = new[]
        {
            Thread(1,
                Comment(100, 1, OtherUserId),
                new Comment
                {
                    Id = 101,
                    ThreadId = 1,
                    Author = new PersonIdentity { Id = OtherUserId },
                    IsDeleted = true,  // <-- deleted comment
                    UpdatedAt = "t",
                }),
        };
        var prev = new List<CommentSnapshotEntry>
        {
            new() { ThreadId = 1, CommentId = 100, UpdatedAt = "t" },
        };

        var (deltas, snapshot) = ReplyClassifier.Classify(
            threads, prev, new Dictionary<string, ThreadAckEntry>(),
            LocalIdentity(), draftOperations: []);

        Assert.NotNull(deltas);
        Assert.Empty(deltas!.ReplyInOthersThread);
        // Deleted comment should also be excluded from the next-sync snapshot.
        Assert.Single(snapshot);
        Assert.Equal(100, snapshot[0].CommentId);
    }

    [Fact]
    public void NoLocalIdentity_StillClassifiesViaPublishedCommentId()
    {
        // Legacy session without a LocalIdentity should still recognize our
        // own published comments via PublishedCommentId.
        var threads = new[]
        {
            Thread(1,
                Comment(100, 1, OtherUserId),
                Comment(101, 1, "some-author-we-dont-know"),  // Author id unknown to classifier
                Comment(102, 1, OtherUserId)),  // The actual reply
        };
        var prev = new List<CommentSnapshotEntry>
        {
            new() { ThreadId = 1, CommentId = 100, UpdatedAt = "t" },
            new() { ThreadId = 1, CommentId = 101, UpdatedAt = "t" },
        };

        var (deltas, _) = ReplyClassifier.Classify(
            threads, prev, new Dictionary<string, ThreadAckEntry>(),
            localIdentity: null,  // <-- no identity
            new[] { AiPublishedDraft(publishedCommentId: 101, threadId: 1) });

        Assert.NotNull(deltas);
        Assert.Single(deltas!.ReplyToAi);
        Assert.Equal(102, deltas.ReplyToAi[0].CommentId);
    }

    [Fact]
    public void BodyPreview_IsTruncatedAndSingleLine()
    {
        var longBody = new string('a', 300) + "\nsecond line";
        var threads = new[]
        {
            Thread(1, Comment(100, 1, OtherUserId, longBody)),
        };
        var prev = new List<CommentSnapshotEntry>(); // empty -> silent prime

        // Force a non-priming run by seeding a different comment in prev.
        prev = new List<CommentSnapshotEntry>
        {
            new() { ThreadId = 99, CommentId = 999, UpdatedAt = "t" },
        };

        var (deltas, _) = ReplyClassifier.Classify(
            threads, prev, new Dictionary<string, ThreadAckEntry>(),
            LocalIdentity(), draftOperations: []);

        Assert.NotNull(deltas);
        Assert.Single(deltas!.NewThreadOthers);
        var preview = deltas.NewThreadOthers[0].BodyPreview;
        Assert.True(preview.Length <= 201, $"Preview length {preview.Length} should be capped");
        Assert.DoesNotContain('\n', preview);
    }

    [Fact]
    public void BuildSnapshot_IncludesAllNonDeletedComments()
    {
        var threads = new[]
        {
            Thread(1,
                Comment(100, 1, OtherUserId),
                Comment(101, 1, OtherUserId),
                new Comment { Id = 102, ThreadId = 1, IsDeleted = true, Author = new PersonIdentity() }),
            Thread(2, Comment(200, 2, OtherUserId)),
        };

        var snapshot = ReplyClassifier.BuildSnapshot(threads);

        Assert.Equal(3, snapshot.Count);
        Assert.Contains(snapshot, e => e.CommentId == 100);
        Assert.Contains(snapshot, e => e.CommentId == 101);
        Assert.Contains(snapshot, e => e.CommentId == 200);
        Assert.DoesNotContain(snapshot, e => e.CommentId == 102);
    }
}
