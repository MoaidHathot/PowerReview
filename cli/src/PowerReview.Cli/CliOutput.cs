using System.Text.Json;
using System.Text.Json.Serialization;

namespace PowerReview.Cli;

/// <summary>
/// Shared JSON serialization options and output helpers for CLI commands.
/// All CLI output goes to stdout as JSON. Errors go to stderr.
/// </summary>
internal static class CliOutput
{
    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    /// <summary>
    /// Write a result object as JSON to stdout.
    /// </summary>
    internal static void WriteJson<T>(T value)
    {
        var json = JsonSerializer.Serialize(value, JsonOptions);
        Console.WriteLine(json);
    }

    /// <summary>
    /// Write an error message to stderr and return exit code 1.
    /// </summary>
    internal static int WriteError(string message)
    {
        var error = new { error = message };
        var json = JsonSerializer.Serialize(error, JsonOptions);
        Console.Error.WriteLine(json);
        return 1;
    }

    /// <summary>
    /// Write a usage error to stderr and return exit code 2.
    /// </summary>
    internal static int WriteUsageError(string message)
    {
        var error = new { error = message };
        var json = JsonSerializer.Serialize(error, JsonOptions);
        Console.Error.WriteLine(json);
        return 2;
    }
}
