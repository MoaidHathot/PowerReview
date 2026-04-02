using System.Runtime.InteropServices;
using System.Text.Json;

namespace PowerReview.Core.Configuration;

/// <summary>
/// Loads and manages the PowerReview configuration file.
/// </summary>
public static class ConfigLoader
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    /// <summary>
    /// Get the config directory path following XDG conventions.
    /// $XDG_CONFIG_HOME/PowerReview or platform-specific fallback.
    /// </summary>
    public static string GetConfigDir()
    {
        var xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        if (!string.IsNullOrEmpty(xdg))
            return Path.Combine(xdg, "PowerReview");

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "PowerReview");

        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".config", "PowerReview");
    }

    /// <summary>
    /// Get the config file path.
    /// </summary>
    public static string GetConfigFilePath()
    {
        return Path.Combine(GetConfigDir(), "powerreview.json");
    }

    /// <summary>
    /// Get the data directory path following XDG conventions.
    /// Respects config.data_dir override if set.
    /// </summary>
    public static string GetDataDir(PowerReviewConfig? config = null)
    {
        if (!string.IsNullOrEmpty(config?.DataDir))
            return config.DataDir;

        var xdg = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
        if (!string.IsNullOrEmpty(xdg))
            return Path.Combine(xdg, "PowerReview");

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "PowerReview");

        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".local", "share", "PowerReview");
    }

    /// <summary>
    /// Get the sessions directory path.
    /// </summary>
    public static string GetSessionsDir(PowerReviewConfig? config = null)
    {
        return Path.Combine(GetDataDir(config), "sessions");
    }

    /// <summary>
    /// Load the configuration from disk. Returns defaults if the file doesn't exist.
    /// </summary>
    public static PowerReviewConfig Load()
    {
        var path = GetConfigFilePath();
        if (!File.Exists(path))
            return new PowerReviewConfig();

        try
        {
            var json = File.ReadAllText(path);
            return JsonSerializer.Deserialize<PowerReviewConfig>(json, JsonOptions)
                ?? new PowerReviewConfig();
        }
        catch (JsonException)
        {
            // If the config file is malformed, return defaults rather than crashing
            return new PowerReviewConfig();
        }
    }

    /// <summary>
    /// Save the configuration to disk, creating the directory if needed.
    /// </summary>
    public static void Save(PowerReviewConfig config)
    {
        var path = GetConfigFilePath();
        var dir = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(dir);

        var json = JsonSerializer.Serialize(config, JsonOptions);
        File.WriteAllText(path, json);
    }
}
