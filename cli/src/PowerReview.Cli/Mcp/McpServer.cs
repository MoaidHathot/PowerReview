using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using ModelContextProtocol.Server;
using PowerReview.Core.Auth;
using PowerReview.Core.Configuration;
using PowerReview.Core.Services;
using PowerReview.Core.Store;

namespace PowerReview.Cli.Mcp;

/// <summary>
/// Starts the PowerReview MCP server over stdio.
/// Registers all services in DI and discovers MCP tools from this assembly.
/// </summary>
internal static class McpServer
{
    internal static async Task RunAsync(string[] args)
    {
        var builder = Host.CreateApplicationBuilder(args);

        // All logs go to stderr (stdout is reserved for MCP JSON-RPC)
        builder.Logging.AddConsole(options =>
        {
            options.LogToStandardErrorThreshold = LogLevel.Trace;
        });

        // Register PowerReview services in DI
        var config = ConfigLoader.Load();
        builder.Services.AddSingleton(config);
        builder.Services.AddSingleton<SessionStore>();
        builder.Services.AddSingleton<SessionService>();
        builder.Services.AddSingleton(new AuthResolver(config.Auth));
        builder.Services.AddSingleton<ReviewService>();

        // Register MCP server with stdio transport and tool discovery
        builder.Services
            .AddMcpServer(options =>
            {
                options.ServerInfo = new()
                {
                    Name = "PowerReview",
                    Version = "0.1.0",
                };
            })
            .WithStdioServerTransport()
            .WithToolsFromAssembly();

        await builder.Build().RunAsync();
    }
}
