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
        // Future migrations go here.
        // For v3 (initial .NET version), we just ensure the version is set.
        // If we ever need to read v2 Lua sessions, add migration logic here.

        session.Version = ReviewSession.CurrentVersion;
        return session;
    }
}
