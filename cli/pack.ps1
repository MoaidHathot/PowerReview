#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds and packs the PowerReview CLI tool as a NuGet package.

.DESCRIPTION
    Cleans, builds in Release mode, and creates the .nupkg file.
    The output package is placed in the ./artifacts directory.

.PARAMETER OutputDir
    Directory for the generated .nupkg file. Defaults to ./artifacts.

.EXAMPLE
    ./pack.ps1
    ./pack.ps1 -OutputDir ./my-packages
#>

param(
    [string]$OutputDir = (Join-Path $PSScriptRoot "artifacts")
)

$ErrorActionPreference = "Stop"

$projectPath = Join-Path $PSScriptRoot "src" "PowerReview.Cli" "PowerReview.Cli.csproj"

if (-not (Test-Path $projectPath)) {
    Write-Error "Project file not found: $projectPath"
    exit 1
}

Write-Host "Cleaning previous build artifacts..." -ForegroundColor Cyan
dotnet clean $projectPath -c Release --nologo -v quiet

Write-Host "Building PowerReview CLI (Release)..." -ForegroundColor Cyan
dotnet build $projectPath -c Release --nologo

if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed."
    exit 1
}

Write-Host "Packing NuGet package..." -ForegroundColor Cyan
dotnet pack $projectPath -c Release --no-build --output $OutputDir --nologo

if ($LASTEXITCODE -ne 0) {
    Write-Error "Pack failed."
    exit 1
}

Write-Host ""
Write-Host "Package created in: $OutputDir" -ForegroundColor Green
Write-Host ""
Write-Host "To push to nuget.org:" -ForegroundColor Yellow
Write-Host "  dotnet nuget push `"$OutputDir\*.nupkg`" --api-key <YOUR_API_KEY> --source https://api.nuget.org/v3/index.json" -ForegroundColor Yellow
