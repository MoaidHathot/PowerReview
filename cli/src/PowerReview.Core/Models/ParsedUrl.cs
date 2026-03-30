using System.Text.Json.Serialization;

namespace PowerReview.Core.Models;

/// <summary>
/// Result of parsing a PR URL into its component parts.
/// </summary>
public sealed class ParsedUrl
{
    [JsonPropertyName("provider_type")]
    public ProviderType ProviderType { get; set; }

    [JsonPropertyName("organization")]
    public string Organization { get; set; } = "";

    [JsonPropertyName("project")]
    public string Project { get; set; } = "";

    [JsonPropertyName("repository")]
    public string Repository { get; set; } = "";

    [JsonPropertyName("pr_id")]
    public int PrId { get; set; }
}
