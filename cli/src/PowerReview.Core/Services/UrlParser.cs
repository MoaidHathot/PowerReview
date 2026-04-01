using System.Text.RegularExpressions;
using PowerReview.Core.Models;

namespace PowerReview.Core.Services;

/// <summary>
/// Parses pull request URLs into their component parts.
/// Supports Azure DevOps and GitHub URL formats.
/// </summary>
public static partial class UrlParser
{
    // Azure DevOps patterns:
    // 1. https://dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id}
    // 2. https://{org}.visualstudio.com/{project}/_git/{repo}/pullrequest/{id}
    // 3. Lenient: dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id} (no protocol)

    [GeneratedRegex(
        @"(?:https?://)?dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/]+)/pullrequest/(\d+)",
        RegexOptions.IgnoreCase)]
    private static partial Regex AzDoDevPattern();

    [GeneratedRegex(
        @"(?:https?://)?([^.]+)\.visualstudio\.com/([^/]+)/_git/([^/]+)/pullrequest/(\d+)",
        RegexOptions.IgnoreCase)]
    private static partial Regex AzDoVsPattern();

    // GitHub pattern:
    // https://github.com/{owner}/{repo}/pull/{id}
    [GeneratedRegex(
        @"(?:https?://)?github\.com/([^/]+)/([^/]+)/pull/(\d+)",
        RegexOptions.IgnoreCase)]
    private static partial Regex GitHubPattern();

    /// <summary>
    /// Parse a PR URL into its component parts.
    /// </summary>
    /// <param name="url">The full PR URL.</param>
    /// <returns>Parsed URL components, or null if the URL format is not recognized.</returns>
    public static ParsedUrl? Parse(string url)
    {
        if (string.IsNullOrWhiteSpace(url))
            return null;

        // Strip query string and fragment
        var cleanUrl = url.Split('?', '#')[0];

        // Try Azure DevOps (dev.azure.com)
        var match = AzDoDevPattern().Match(cleanUrl);
        if (match.Success)
        {
            return new ParsedUrl
            {
                ProviderType = ProviderType.AzDo,
                Organization = Uri.UnescapeDataString(match.Groups[1].Value),
                Project = Uri.UnescapeDataString(match.Groups[2].Value),
                Repository = Uri.UnescapeDataString(match.Groups[3].Value),
                PrId = int.Parse(match.Groups[4].Value),
            };
        }

        // Try Azure DevOps (visualstudio.com)
        match = AzDoVsPattern().Match(cleanUrl);
        if (match.Success)
        {
            return new ParsedUrl
            {
                ProviderType = ProviderType.AzDo,
                Organization = Uri.UnescapeDataString(match.Groups[1].Value),
                Project = Uri.UnescapeDataString(match.Groups[2].Value),
                Repository = Uri.UnescapeDataString(match.Groups[3].Value),
                PrId = int.Parse(match.Groups[4].Value),
            };
        }

        // Try GitHub
        match = GitHubPattern().Match(cleanUrl);
        if (match.Success)
        {
            var owner = Uri.UnescapeDataString(match.Groups[1].Value);
            var repo = Uri.UnescapeDataString(match.Groups[2].Value);
            return new ParsedUrl
            {
                ProviderType = ProviderType.GitHub,
                Organization = owner,
                Project = repo,
                Repository = repo,
                PrId = int.Parse(match.Groups[3].Value),
            };
        }

        return null;
    }

    /// <summary>
    /// Detect the provider type from a URL without full parsing.
    /// </summary>
    public static ProviderType? DetectProvider(string url)
    {
        if (string.IsNullOrWhiteSpace(url))
            return null;

        if (url.Contains("dev.azure.com", StringComparison.OrdinalIgnoreCase) ||
            url.Contains(".visualstudio.com", StringComparison.OrdinalIgnoreCase))
            return ProviderType.AzDo;

        if (url.Contains("github.com", StringComparison.OrdinalIgnoreCase))
            return ProviderType.GitHub;

        return null;
    }

    /// <summary>
    /// Build a git clone URL from the parsed PR URL components.
    /// </summary>
    /// <param name="parsed">The parsed PR URL.</param>
    /// <returns>The HTTPS clone URL for the repository.</returns>
    public static string BuildCloneUrl(ParsedUrl parsed)
    {
        return parsed.ProviderType switch
        {
            ProviderType.AzDo => $"https://dev.azure.com/{parsed.Organization}/{parsed.Project}/_git/{parsed.Repository}",
            ProviderType.GitHub => $"https://github.com/{parsed.Organization}/{parsed.Repository}.git",
            _ => throw new ArgumentException($"Unsupported provider type: {parsed.ProviderType}"),
        };
    }
}
