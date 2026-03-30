using System.CommandLine;
using PowerReview.Cli;
using PowerReview.Cli.Commands;

var services = new ServiceFactory();
var rootCommand = CommandBuilder.Build(services);
var parseResult = rootCommand.Parse(args);
return await parseResult.InvokeAsync();
