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

        session.Version = ReviewSession.CurrentVersion;
        return session;
    }
}
