using System.Text.Json;
using System.Text.Json.Serialization;
using PowerReview.Core.Models;
using PowerReview.Core.Services;

namespace PowerReview.Cli.Mcp;

/// <summary>
/// Shared helpers for MCP tool implementations.
/// </summary>
internal static class ToolHelpers
{
    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    /// <summary>
    /// Resolve a PR URL to a session ID.
    /// </summary>
    internal static string ResolveSessionId(string prUrl)
    {
        var parsed = UrlParser.Parse(prUrl)
            ?? throw new ArgumentException($"Could not parse PR URL: {prUrl}");

        return ReviewSession.ComputeId(
            parsed.ProviderType,
            parsed.Organization,
            parsed.Project,
            parsed.Repository,
            parsed.PrId);
    }

    /// <summary>
    /// Serialize an object to JSON using the shared options.
    /// </summary>
    internal static string ToJson<T>(T value)
    {
        return JsonSerializer.Serialize(value, JsonOptions);
    }
}
