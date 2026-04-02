using PowerReview.Core.Services;

namespace PowerReview.Core.Tests;

public class WorktreeFileServiceTests : IDisposable
{
    private readonly string _tempDir;

    public WorktreeFileServiceTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "powerreview-wfs-tests-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    // ========================================================================
    // ResolveSecurePath
    // ========================================================================

    [Fact]
    public void ResolveSecurePath_SimpleRelative_ReturnsAbsolute()
    {
        var result = WorktreeFileService.ResolveSecurePath(_tempDir, "src/main.cs");

        Assert.NotNull(result);
        Assert.StartsWith(Path.GetFullPath(_tempDir), result);
        Assert.EndsWith("main.cs", result);
    }

    [Fact]
    public void ResolveSecurePath_NestedPath_ReturnsAbsolute()
    {
        var result = WorktreeFileService.ResolveSecurePath(_tempDir, "src/deep/nested/file.txt");

        Assert.NotNull(result);
        Assert.StartsWith(Path.GetFullPath(_tempDir), result);
    }

    [Fact]
    public void ResolveSecurePath_TraversalAttempt_ReturnsNull()
    {
        var result = WorktreeFileService.ResolveSecurePath(_tempDir, "../../etc/passwd");

        Assert.Null(result);
    }

    [Fact]
    public void ResolveSecurePath_TraversalWithBackslash_ReturnsNull()
    {
        var result = WorktreeFileService.ResolveSecurePath(_tempDir, "..\\..\\etc\\passwd");

        Assert.Null(result);
    }

    [Fact]
    public void ResolveSecurePath_TraversalMidPath_ReturnsNull()
    {
        var result = WorktreeFileService.ResolveSecurePath(_tempDir, "src/../../etc/passwd");

        Assert.Null(result);
    }

    [Fact]
    public void ResolveSecurePath_DotPath_ReturnsRoot()
    {
        var result = WorktreeFileService.ResolveSecurePath(_tempDir, ".");

        Assert.NotNull(result);
        // "." resolves to the root itself
        Assert.Equal(Path.GetFullPath(_tempDir), result);
    }

    [Fact]
    public void ResolveSecurePath_ForwardSlashRelative_ReturnsAbsolute()
    {
        var result = WorktreeFileService.ResolveSecurePath(_tempDir, "src/Services/UserService.cs");

        Assert.NotNull(result);
        Assert.StartsWith(Path.GetFullPath(_tempDir), result);
    }

    // ========================================================================
    // ReadFile
    // ========================================================================

    [Fact]
    public void ReadFile_ExistingFile_ReturnsContent()
    {
        var filePath = Path.Combine(_tempDir, "test.txt");
        File.WriteAllText(filePath, "line1\nline2\nline3");

        var result = WorktreeFileService.ReadFile(_tempDir, "test.txt");

        Assert.False(result.IsError);
        Assert.Equal("test.txt", result.Path);
        Assert.Equal("line1\nline2\nline3", result.Content);
        Assert.Equal(3, result.TotalLines);
        Assert.Equal(1, result.Offset);
    }

    [Fact]
    public void ReadFile_FileInSubdirectory_ReturnsContent()
    {
        var dir = Path.Combine(_tempDir, "src");
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "main.cs"), "using System;\nclass Main {}");

        var result = WorktreeFileService.ReadFile(_tempDir, "src/main.cs");

        Assert.False(result.IsError);
        Assert.Equal("src/main.cs", result.Path);
        Assert.Contains("using System;", result.Content);
    }

    [Fact]
    public void ReadFile_NonexistentFile_ReturnsError()
    {
        var result = WorktreeFileService.ReadFile(_tempDir, "does-not-exist.txt");

        Assert.True(result.IsError);
        Assert.Contains("File not found", result.ErrorMessage);
    }

    [Fact]
    public void ReadFile_PathTraversal_ReturnsError()
    {
        var result = WorktreeFileService.ReadFile(_tempDir, "../../etc/passwd");

        Assert.True(result.IsError);
        Assert.Contains("Path traversal", result.ErrorMessage);
    }

    [Fact]
    public void ReadFile_WithOffset_ReturnsFromLine()
    {
        var filePath = Path.Combine(_tempDir, "lines.txt");
        File.WriteAllText(filePath, "line1\nline2\nline3\nline4\nline5");

        var result = WorktreeFileService.ReadFile(_tempDir, "lines.txt", offset: 3);

        Assert.False(result.IsError);
        Assert.Equal("line3\nline4\nline5", result.Content);
        Assert.Equal(5, result.TotalLines);
        Assert.Equal(3, result.Offset);
    }

    [Fact]
    public void ReadFile_WithLimit_ReturnsLimitedLines()
    {
        var filePath = Path.Combine(_tempDir, "lines.txt");
        File.WriteAllText(filePath, "line1\nline2\nline3\nline4\nline5");

        var result = WorktreeFileService.ReadFile(_tempDir, "lines.txt", offset: 1, limit: 2);

        Assert.False(result.IsError);
        Assert.Equal("line1\nline2", result.Content);
        Assert.Equal(5, result.TotalLines);
        Assert.Equal(2, result.Limit);
    }

    [Fact]
    public void ReadFile_WithOffsetAndLimit_ReturnsSlice()
    {
        var filePath = Path.Combine(_tempDir, "lines.txt");
        File.WriteAllText(filePath, "line1\nline2\nline3\nline4\nline5");

        var result = WorktreeFileService.ReadFile(_tempDir, "lines.txt", offset: 2, limit: 3);

        Assert.False(result.IsError);
        Assert.Equal("line2\nline3\nline4", result.Content);
        Assert.Equal(5, result.TotalLines);
        Assert.Equal(2, result.Offset);
        Assert.Equal(3, result.Limit);
    }

    [Fact]
    public void ReadFile_OffsetBeyondEnd_ReturnsEmpty()
    {
        var filePath = Path.Combine(_tempDir, "lines.txt");
        File.WriteAllText(filePath, "line1\nline2");

        var result = WorktreeFileService.ReadFile(_tempDir, "lines.txt", offset: 100);

        Assert.False(result.IsError);
        Assert.Equal("", result.Content);
        Assert.Equal(2, result.TotalLines);
    }

    [Fact]
    public void ReadFile_LimitExceedsRemaining_ClampsToAvailable()
    {
        var filePath = Path.Combine(_tempDir, "lines.txt");
        File.WriteAllText(filePath, "line1\nline2\nline3");

        var result = WorktreeFileService.ReadFile(_tempDir, "lines.txt", offset: 2, limit: 100);

        Assert.False(result.IsError);
        Assert.Equal("line2\nline3", result.Content);
        Assert.Equal(3, result.TotalLines);
    }

    [Fact]
    public void ReadFile_BinaryFile_ReturnsError()
    {
        var filePath = Path.Combine(_tempDir, "binary.bin");
        var content = new byte[] { 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00, 0x57, 0x6F, 0x72, 0x6C, 0x64 };
        File.WriteAllBytes(filePath, content);

        var result = WorktreeFileService.ReadFile(_tempDir, "binary.bin");

        Assert.True(result.IsError);
        Assert.Contains("binary file", result.ErrorMessage);
    }

    [Fact]
    public void ReadFile_EmptyFile_ReturnsEmpty()
    {
        var filePath = Path.Combine(_tempDir, "empty.txt");
        File.WriteAllText(filePath, "");

        var result = WorktreeFileService.ReadFile(_tempDir, "empty.txt");

        Assert.False(result.IsError);
        Assert.Equal(0, result.TotalLines);
    }

    [Fact]
    public void ReadFile_BackslashPath_NormalizesToForwardSlash()
    {
        var dir = Path.Combine(_tempDir, "src");
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "file.cs"), "content");

        var result = WorktreeFileService.ReadFile(_tempDir, "src\\file.cs");

        Assert.False(result.IsError);
        Assert.Equal("src/file.cs", result.Path);
    }

    // ========================================================================
    // ListFiles
    // ========================================================================

    [Fact]
    public void ListFiles_RootDirectory_ReturnsEntries()
    {
        // Create some files and directories
        Directory.CreateDirectory(Path.Combine(_tempDir, "src"));
        Directory.CreateDirectory(Path.Combine(_tempDir, "tests"));
        File.WriteAllText(Path.Combine(_tempDir, "README.md"), "# Hello");
        File.WriteAllText(Path.Combine(_tempDir, "src", "main.cs"), "code");

        var result = WorktreeFileService.ListFiles(_tempDir);

        Assert.False(result.IsError);
        Assert.Equal(".", result.BasePath);

        var dirs = result.Entries.Where(e => e.Type == "directory").ToList();
        var files = result.Entries.Where(e => e.Type == "file").ToList();

        Assert.Contains(dirs, d => d.Name == "src");
        Assert.Contains(dirs, d => d.Name == "tests");
        Assert.Contains(files, f => f.Name == "README.md");
    }

    [Fact]
    public void ListFiles_Subdirectory_ReturnsSubdirEntries()
    {
        var srcDir = Path.Combine(_tempDir, "src");
        Directory.CreateDirectory(srcDir);
        File.WriteAllText(Path.Combine(srcDir, "main.cs"), "code");
        File.WriteAllText(Path.Combine(srcDir, "utils.cs"), "utils");

        var result = WorktreeFileService.ListFiles(_tempDir, directory: "src");

        Assert.False(result.IsError);
        Assert.Equal("src", result.BasePath);

        var files = result.Entries.Where(e => e.Type == "file").ToList();
        Assert.Equal(2, files.Count);
        Assert.Contains(files, f => f.Name == "main.cs");
        Assert.Contains(files, f => f.Name == "utils.cs");
    }

    [Fact]
    public void ListFiles_WithPattern_FiltersFiles()
    {
        File.WriteAllText(Path.Combine(_tempDir, "main.cs"), "code");
        File.WriteAllText(Path.Combine(_tempDir, "utils.cs"), "utils");
        File.WriteAllText(Path.Combine(_tempDir, "readme.md"), "docs");

        var result = WorktreeFileService.ListFiles(_tempDir, pattern: "*.cs");

        Assert.False(result.IsError);
        var files = result.Entries.Where(e => e.Type == "file").ToList();
        Assert.Equal(2, files.Count);
        Assert.All(files, f => Assert.EndsWith(".cs", f.Name));
    }

    [Fact]
    public void ListFiles_Recursive_ListsAllFiles()
    {
        var srcDir = Path.Combine(_tempDir, "src");
        var deepDir = Path.Combine(srcDir, "deep");
        Directory.CreateDirectory(deepDir);
        File.WriteAllText(Path.Combine(_tempDir, "root.txt"), "root");
        File.WriteAllText(Path.Combine(srcDir, "main.cs"), "code");
        File.WriteAllText(Path.Combine(deepDir, "nested.cs"), "nested");

        var result = WorktreeFileService.ListFiles(_tempDir, recursive: true);

        Assert.False(result.IsError);
        Assert.True(result.Entries.Count >= 3);
        Assert.Contains(result.Entries, e => e.Path == "root.txt");
        Assert.Contains(result.Entries, e => e.Path == "src/main.cs");
        Assert.Contains(result.Entries, e => e.Path == "src/deep/nested.cs");
    }

    [Fact]
    public void ListFiles_RecursiveWithPattern_FiltersRecursively()
    {
        var srcDir = Path.Combine(_tempDir, "src");
        Directory.CreateDirectory(srcDir);
        File.WriteAllText(Path.Combine(_tempDir, "readme.md"), "docs");
        File.WriteAllText(Path.Combine(srcDir, "main.cs"), "code");
        File.WriteAllText(Path.Combine(srcDir, "test.txt"), "text");

        var result = WorktreeFileService.ListFiles(_tempDir, pattern: "*.cs", recursive: true);

        Assert.False(result.IsError);
        Assert.Single(result.Entries);
        Assert.Equal("src/main.cs", result.Entries[0].Path);
    }

    [Fact]
    public void ListFiles_SkipsGitDirectory()
    {
        var gitDir = Path.Combine(_tempDir, ".git");
        Directory.CreateDirectory(gitDir);
        File.WriteAllText(Path.Combine(gitDir, "config"), "git config");
        File.WriteAllText(Path.Combine(_tempDir, "main.cs"), "code");

        // Non-recursive should skip hidden dirs
        var result = WorktreeFileService.ListFiles(_tempDir);
        Assert.False(result.IsError);
        Assert.DoesNotContain(result.Entries, e => e.Name == ".git");

        // Recursive should skip .git contents
        var recursiveResult = WorktreeFileService.ListFiles(_tempDir, recursive: true);
        Assert.False(recursiveResult.IsError);
        Assert.DoesNotContain(recursiveResult.Entries, e => e.Path.Contains(".git"));
    }

    [Fact]
    public void ListFiles_NonexistentDirectory_ReturnsError()
    {
        var result = WorktreeFileService.ListFiles(_tempDir, directory: "nonexistent");

        Assert.True(result.IsError);
        Assert.Contains("Directory not found", result.ErrorMessage);
    }

    [Fact]
    public void ListFiles_PathTraversal_ReturnsError()
    {
        var result = WorktreeFileService.ListFiles(_tempDir, directory: "../../etc");

        Assert.True(result.IsError);
        Assert.Contains("Path traversal", result.ErrorMessage);
    }

    [Fact]
    public void ListFiles_EmptyDirectory_ReturnsEmpty()
    {
        var emptyDir = Path.Combine(_tempDir, "empty");
        Directory.CreateDirectory(emptyDir);

        var result = WorktreeFileService.ListFiles(_tempDir, directory: "empty");

        Assert.False(result.IsError);
        Assert.Empty(result.Entries);
    }

    [Fact]
    public void ListFiles_NonRecursive_OnlyShowsDirectChildren()
    {
        var srcDir = Path.Combine(_tempDir, "src");
        var deepDir = Path.Combine(srcDir, "deep");
        Directory.CreateDirectory(deepDir);
        File.WriteAllText(Path.Combine(srcDir, "main.cs"), "code");
        File.WriteAllText(Path.Combine(deepDir, "nested.cs"), "nested");

        var result = WorktreeFileService.ListFiles(_tempDir, directory: "src");

        Assert.False(result.IsError);
        // Should show "deep" directory and "main.cs" file, but NOT "nested.cs"
        Assert.Contains(result.Entries, e => e.Name == "deep" && e.Type == "directory");
        Assert.Contains(result.Entries, e => e.Name == "main.cs" && e.Type == "file");
        Assert.DoesNotContain(result.Entries, e => e.Name == "nested.cs");
    }

    [Fact]
    public void ListFiles_RecursiveInSubdirectory_ListsFromSubdir()
    {
        var srcDir = Path.Combine(_tempDir, "src");
        var deepDir = Path.Combine(srcDir, "deep");
        Directory.CreateDirectory(deepDir);
        File.WriteAllText(Path.Combine(srcDir, "main.cs"), "code");
        File.WriteAllText(Path.Combine(deepDir, "nested.cs"), "nested");
        File.WriteAllText(Path.Combine(_tempDir, "root.txt"), "root");

        var result = WorktreeFileService.ListFiles(_tempDir, directory: "src", recursive: true);

        Assert.False(result.IsError);
        Assert.Equal("src", result.BasePath);
        // Should list files within src/ recursively
        Assert.Contains(result.Entries, e => e.Path == "src/main.cs");
        Assert.Contains(result.Entries, e => e.Path == "src/deep/nested.cs");
        // Should NOT include root.txt
        Assert.DoesNotContain(result.Entries, e => e.Path == "root.txt");
    }

    // ========================================================================
    // NormalizePath
    // ========================================================================

    [Theory]
    [InlineData("src\\main.cs", "src/main.cs")]
    [InlineData("src/main.cs", "src/main.cs")]
    [InlineData("src\\deep\\nested\\file.txt", "src/deep/nested/file.txt")]
    public void NormalizePath_ConvertsBackslashes(string input, string expected)
    {
        var result = WorktreeFileService.NormalizePath(input);
        Assert.Equal(expected, result);
    }
}
