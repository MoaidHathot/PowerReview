namespace PowerReview.Core.Services;

/// <summary>
/// Provides secure file system operations scoped to a working directory root.
/// Prevents path traversal and restricts access to the worktree boundary.
/// </summary>
public sealed class WorktreeFileService
{
    /// <summary>
    /// Resolves a relative path against a root directory, ensuring the result
    /// stays within the root boundary. Returns null if the path escapes the root.
    /// </summary>
    public static string? ResolveSecurePath(string rootPath, string relativePath)
    {
        // Normalize backslashes to forward slashes so Windows-style paths
        // are handled correctly on all platforms (Linux treats \ as literal).
        relativePath = relativePath.Replace('\\', '/');

        // Normalize the root path to an absolute path with trailing separator
        var normalizedRoot = Path.GetFullPath(rootPath);
        if (!normalizedRoot.EndsWith(Path.DirectorySeparatorChar))
            normalizedRoot += Path.DirectorySeparatorChar;

        // Combine and resolve to absolute
        var combined = Path.Combine(normalizedRoot, relativePath);
        var resolved = Path.GetFullPath(combined);

        // Check that the resolved path starts with the root
        if (!resolved.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase)
            && !resolved.Equals(normalizedRoot.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase))
        {
            return null; // Path traversal attempt
        }

        return resolved;
    }

    /// <summary>
    /// Reads the content of a text file within the working directory.
    /// Supports optional line offset and limit for reading subsets of large files.
    /// </summary>
    /// <param name="rootPath">The working directory root.</param>
    /// <param name="relativePath">Relative file path within the root.</param>
    /// <param name="offset">1-indexed line number to start from (default: 1).</param>
    /// <param name="limit">Maximum number of lines to return (default: null = all).</param>
    /// <returns>A result containing the file content and metadata.</returns>
    public static ReadFileResult ReadFile(string rootPath, string relativePath, int offset = 1, int? limit = null)
    {
        var resolvedPath = ResolveSecurePath(rootPath, relativePath);
        if (resolvedPath == null)
            return ReadFileResult.Error("Path traversal detected: the file path escapes the working directory.");

        if (!File.Exists(resolvedPath))
            return ReadFileResult.Error($"File not found: '{relativePath}'");

        // Check for binary content (null bytes in the first 8KB)
        if (IsBinaryFile(resolvedPath))
            return ReadFileResult.Error($"Cannot read binary file: '{relativePath}'");

        var allLines = File.ReadAllLines(resolvedPath);
        var totalLines = allLines.Length;

        // Clamp offset to valid range
        if (offset < 1) offset = 1;
        if (offset > totalLines)
        {
            return new ReadFileResult
            {
                Path = NormalizePath(relativePath),
                Content = "",
                TotalLines = totalLines,
                Offset = offset,
                Limit = limit,
            };
        }

        var startIndex = offset - 1; // Convert to 0-indexed
        var count = limit.HasValue
            ? Math.Min(limit.Value, totalLines - startIndex)
            : totalLines - startIndex;

        var selectedLines = allLines.AsSpan(startIndex, count);
        var content = string.Join('\n', selectedLines.ToArray());

        return new ReadFileResult
        {
            Path = NormalizePath(relativePath),
            Content = content,
            TotalLines = totalLines,
            Offset = offset,
            Limit = limit,
        };
    }

    /// <summary>
    /// Lists files and directories within the working directory.
    /// </summary>
    /// <param name="rootPath">The working directory root.</param>
    /// <param name="directory">Optional subdirectory relative to root (null = root).</param>
    /// <param name="pattern">Optional glob pattern to filter files (e.g., "*.cs").</param>
    /// <param name="recursive">Whether to list recursively.</param>
    /// <returns>A result containing the directory entries.</returns>
    public static ListFilesResult ListFiles(string rootPath, string? directory = null, string? pattern = null, bool recursive = false)
    {
        var targetPath = rootPath;
        if (!string.IsNullOrEmpty(directory))
        {
            var resolved = ResolveSecurePath(rootPath, directory);
            if (resolved == null)
                return ListFilesResult.Error("Path traversal detected: the directory path escapes the working directory.");
            targetPath = resolved;
        }

        if (!Directory.Exists(targetPath))
            return ListFilesResult.Error($"Directory not found: '{directory ?? "."}'");

        var normalizedRoot = Path.GetFullPath(rootPath);
        var basePath = directory != null ? NormalizePath(directory) : ".";
        var entries = new List<FileEntry>();

        if (recursive)
        {
            // Recursive: list all files, skip .git directories
            var searchPattern = pattern ?? "*";
            try
            {
                foreach (var filePath in Directory.EnumerateFiles(targetPath, searchPattern, SearchOption.AllDirectories))
                {
                    // Skip .git directory contents
                    var relativePath = Path.GetRelativePath(normalizedRoot, filePath);
                    var normalizedRelative = NormalizePath(relativePath);
                    if (IsVcsPath(normalizedRelative))
                        continue;

                    entries.Add(new FileEntry
                    {
                        Name = Path.GetFileName(filePath),
                        Type = "file",
                        Path = normalizedRelative,
                    });
                }
            }
            catch (UnauthorizedAccessException)
            {
                // Skip directories we can't access
            }
        }
        else
        {
            // Immediate children only
            try
            {
                // List directories first
                foreach (var dirPath in Directory.EnumerateDirectories(targetPath))
                {
                    var dirName = Path.GetFileName(dirPath);
                    if (dirName.StartsWith('.'))
                        continue; // Skip hidden directories like .git

                    var relativePath = Path.GetRelativePath(normalizedRoot, dirPath);
                    entries.Add(new FileEntry
                    {
                        Name = dirName,
                        Type = "directory",
                        Path = NormalizePath(relativePath),
                    });
                }

                // Then list files
                var searchPattern = pattern ?? "*";
                foreach (var filePath in Directory.EnumerateFiles(targetPath, searchPattern))
                {
                    var fileName = Path.GetFileName(filePath);
                    var relativePath = Path.GetRelativePath(normalizedRoot, filePath);
                    entries.Add(new FileEntry
                    {
                        Name = fileName,
                        Type = "file",
                        Path = NormalizePath(relativePath),
                    });
                }
            }
            catch (UnauthorizedAccessException)
            {
                // Skip directories we can't access
            }
        }

        return new ListFilesResult
        {
            BasePath = basePath,
            Entries = entries,
        };
    }

    // --- Helpers ---

    private static bool IsBinaryFile(string filePath)
    {
        const int bufferSize = 8192;
        try
        {
            using var stream = File.OpenRead(filePath);
            var buffer = new byte[Math.Min(bufferSize, stream.Length)];
            var bytesRead = stream.Read(buffer, 0, buffer.Length);
            return Array.IndexOf(buffer, (byte)0, 0, bytesRead) >= 0;
        }
        catch
        {
            return false; // If we can't read it, let the caller handle the error
        }
    }

    private static bool IsVcsPath(string normalizedPath)
    {
        return normalizedPath.StartsWith(".git/", StringComparison.OrdinalIgnoreCase)
            || normalizedPath.Contains("/.git/", StringComparison.OrdinalIgnoreCase)
            || normalizedPath.Equals(".git", StringComparison.OrdinalIgnoreCase);
    }

    internal static string NormalizePath(string path)
    {
        return path.Replace('\\', '/');
    }
}

// --- Result types ---

/// <summary>
/// Result of a file read operation.
/// </summary>
public sealed class ReadFileResult
{
    public string? Path { get; set; }
    public string? Content { get; set; }
    public int TotalLines { get; set; }
    public int Offset { get; set; }
    public int? Limit { get; set; }
    public string? ErrorMessage { get; set; }

    public bool IsError => ErrorMessage != null;

    public static ReadFileResult Error(string message) => new() { ErrorMessage = message };
}

/// <summary>
/// Result of a directory listing operation.
/// </summary>
public sealed class ListFilesResult
{
    public string BasePath { get; set; } = ".";
    public List<FileEntry> Entries { get; set; } = [];
    public string? ErrorMessage { get; set; }

    public bool IsError => ErrorMessage != null;

    public static ListFilesResult Error(string message) => new() { ErrorMessage = message };
}

/// <summary>
/// A single file or directory entry in a listing result.
/// </summary>
public sealed class FileEntry
{
    /// <summary>File or directory name (without path).</summary>
    public string Name { get; set; } = "";

    /// <summary>"file" or "directory".</summary>
    public string Type { get; set; } = "file";

    /// <summary>Path relative to the repository root.</summary>
    public string Path { get; set; } = "";
}
