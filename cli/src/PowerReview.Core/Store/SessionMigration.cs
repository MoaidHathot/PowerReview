using PowerReview.Core.Models;

namespace PowerReview.Core.Store;

/// <summary>
/// Handles migration of session files from older schema versions.
/// </summary>
public static class SessionMigration
{
    /// <summary>
    /// Migrate a session to the current version.
    /// </summary>
    public static ReviewSession Migrate(ReviewSession session)
    {
        // v3 -> v4: Add ReviewState for iteration tracking.
        // The ReviewState property has default values (empty lists, null IDs),
        // so existing v3 sessions automatically get a valid empty ReviewState
        // when deserialized. No data transformation needed.
        if (session.Version < 4)
        {
            session.Review ??= new ReviewState();
        }

        // v4 -> v5: Add Proposals and FixWorktree for incoming comment response system.
        // Both properties have default values (empty dictionary, null),
        // so existing v4 sessions automatically get valid defaults when deserialized.
        if (session.Version < 5)
        {
            session.Proposals ??= new Dictionary<string, ProposedFix>();
            // FixWorktree is nullable, defaults to null — no action needed
        }

        // v5 -> v6: Add derived ReviewMetadata for UI and AI-agent context.
        if (session.Version < 6)
        {
            session.Metadata = ReviewMetadata.FromSession(session);
        }

        session.Version = ReviewSession.CurrentVersion;
        session.Metadata = ReviewMetadata.FromSession(session);
        return session;
    }
}
