using PowerReview.Cli;
using PowerReview.Cli.Commands;
using PowerReview.Cli.Mcp;

// Intercept "mcp" subcommand early — it uses a different hosting model
// (Microsoft.Extensions.Hosting + MCP stdio transport) instead of System.CommandLine.
if (args.Length > 0 && args[0].Equals("mcp", StringComparison.OrdinalIgnoreCase))
{
    await McpServer.RunAsync(args);
    return 0;
}

var services = new ServiceFactory();
var rootCommand = CommandBuilder.Build(services);
var parseResult = rootCommand.Parse(args);
return await parseResult.InvokeAsync();
