<#
.SYNOPSIS
Compile the Avalonia widget — a build gate, not a test.

.DESCRIPTION
    pwsh -NoProfile -File tests/Compile-App.ps1

The rest of the suite never touches the UI half. `tests/app` compiles `Core.cs` in
directly and deliberately references no Avalonia, so `Program.cs`, `Skins.cs` and
`Shadow.cs` are not built by anything the suite runs. Without this step a syntax
error in the window code reports SUITE PASSED and a broken `build.ps1`.

This is `build` rather than `publish`: it answers "does the widget still compile?"
in a few seconds, without spending a minute producing a 42MB single-file artefact
that only `build.ps1` needs.

Needs the .NET 8 SDK, found the same way build.ps1 finds it.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'src\app\Oriel.csproj'

. (Join-Path $root 'src\build\DotnetSdk.ps1')

$dotnet = Resolve-DotnetSdk -RequiredMajor 8
if (-not $dotnet) {
    Write-Host 'No .NET 8 (or newer) SDK found — cannot compile the widget.' -ForegroundColor Red
    Write-Host '  Install the SDK: https://dotnet.microsoft.com/download/dotnet/8.0'
    Write-Host '  Already installed somewhere unusual? Point DOTNET_ROOT at it.'
    exit 1
}

& $dotnet build $project --nologo
if ($LASTEXITCODE -ne 0) {
    Write-Host 'WIDGET DID NOT COMPILE' -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host 'WIDGET COMPILES' -ForegroundColor Green
exit 0
