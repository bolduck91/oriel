<#
.SYNOPSIS
Run the xUnit suite over the widget's UI layer, on a headless Avalonia platform.

.DESCRIPTION
The one command for the tests that cover what renders (ticket 07):

    pwsh -NoProfile -File tests/Run-UiTests.ps1

This is a **second** test project on purpose. `tests/app` deliberately references no
Avalonia, which is what keeps the logic testable with no window and no display;
pulling Avalonia in there to reach the skins would give that up. So the UI half gets
its own project, its own headless platform, and its own runner — see the comment in
Oriel.Ui.Tests.csproj.

Headless means exactly that: a real Avalonia dispatcher and a real visual tree, but
no window ever reaches a screen. It needs no display attached, and it does not care
whether the widget itself is running.

Needs the **.NET 8 SDK**, found the same way build.ps1 finds it. Exits non-zero when
anything fails, so it can gate a commit.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent $PSScriptRoot
$project = Join-Path $PSScriptRoot 'ui\Oriel.Ui.Tests.csproj'

. (Join-Path $root 'src\build\DotnetSdk.ps1')

$dotnet = Resolve-DotnetSdk -RequiredMajor 8
if (-not $dotnet) {
    Write-Host 'No .NET 8 (or newer) SDK found — cannot run the UI tests.' -ForegroundColor Red
    Write-Host '  Install the SDK: https://dotnet.microsoft.com/download/dotnet/8.0'
    Write-Host '  Already installed somewhere unusual? Point DOTNET_ROOT at it.'
    exit 1
}

& $dotnet test $project --nologo
if ($LASTEXITCODE -ne 0) {
    Write-Host 'UI TESTS FAILED' -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host 'UI TESTS PASSED' -ForegroundColor Green
exit 0
