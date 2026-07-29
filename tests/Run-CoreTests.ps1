<#
.SYNOPSIS
Run the xUnit suite over the widget's C# logic core.

.DESCRIPTION
The one command for the tests that cover what actually runs (ticket 04):

    pwsh -NoProfile -File tests/Run-CoreTests.ps1

`tests/app` compiles `src/app/Core.cs` in directly rather than referencing the app
project, so this needs no window, no screen and no Avalonia — see the comment in
Oriel.Core.Tests.csproj for why.

Needs the **.NET 8 SDK**, found the same way build.ps1 finds it. Exits non-zero when
anything fails, so it can gate a commit.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent $PSScriptRoot
$project = Join-Path $PSScriptRoot 'app\Oriel.Core.Tests.csproj'

. (Join-Path $root 'src\build\DotnetSdk.ps1')

$dotnet = Resolve-DotnetSdk -RequiredMajor 8
if (-not $dotnet) {
    Write-Host 'No .NET 8 (or newer) SDK found — cannot run the core tests.' -ForegroundColor Red
    Write-Host '  Install the SDK: https://dotnet.microsoft.com/download/dotnet/8.0'
    Write-Host '  Already installed somewhere unusual? Point DOTNET_ROOT at it.'
    exit 1
}

& $dotnet test $project --nologo
if ($LASTEXITCODE -ne 0) {
    Write-Host 'CORE TESTS FAILED' -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host 'CORE TESTS PASSED' -ForegroundColor Green
exit 0
