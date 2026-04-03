#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds and packs the PowerReview CLI tool as a NuGet package.

.DESCRIPTION
    Cleans, builds in Release mode, and creates the .nupkg file.
    The output package is placed in the ./artifacts directory.
    Optionally pushes the package to nuget.org.

.PARAMETER OutputDir
    Directory for the generated .nupkg file. Defaults to ./artifacts.

.PARAMETER Push
    Push the package to nuget.org after packing.

.EXAMPLE
    ./pack.ps1
    ./pack.ps1 -OutputDir ./my-packages
    ./pack.ps1 -Push
#>

param(
    [string]$OutputDir = (Join-Path $PSScriptRoot "artifacts"),
    [switch]$Push
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

if ($Push) {
    Write-Host ""
    Write-Host "Pushing to nuget.org..." -ForegroundColor Cyan
    $package = Get-ChildItem -Path $OutputDir -Filter "*.nupkg" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $package) {
        Write-Error "No .nupkg file found in $OutputDir"
        exit 1
    }
    dotnet nuget push $package.FullName --source https://api.nuget.org/v3/index.json --api-key $env:NUGET_API_KEY --skip-duplicate
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Push failed."
        exit 1
    }
    Write-Host ""
    Write-Host "Package pushed: $($package.Name)" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "To push to nuget.org:" -ForegroundColor Yellow
    Write-Host "  ./pack.ps1 -Push" -ForegroundColor Yellow
}
