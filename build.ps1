<#
.SYNOPSIS
Build Oriel into a single self-contained executable.

.DESCRIPTION
The one command a fresh clone needs (ticket 03):

    pwsh -NoProfile -File build.ps1

It publishes `src/app` to `dist/Oriel.exe` — one file, no installer,
no .NET runtime needed on the machine that runs it. The output path is fixed on
purpose: "Start with Windows" registers whatever executable it is launched from,
so a stable path means the registration survives every rebuild.

Building needs the **.NET 8 SDK** (https://dotnet.microsoft.com/download/dotnet/8.0).
Running the result needs nothing at all.

.PARAMETER Run
Launch the freshly published widget when the build succeeds. Implies -StopWidget,
since it is going to relaunch the widget anyway.

.PARAMETER StopWidget
Close a widget that is already running from the output path, instead of refusing
to build over it. Windows locks a running image, so the two cannot both happen.

.PARAMETER Configuration
MSBuild configuration. Release by default; Debug is for diagnosing the app itself.
#>
[CmdletBinding()]
param(
    [switch] $Run,
    [switch] $StopWidget,
    [ValidateSet('Release', 'Debug')] [string] $Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root    = $PSScriptRoot
$project = Join-Path $root 'src\app\Oriel.csproj'
$outDir  = Join-Path $root 'dist'
$exe     = Join-Path $outDir 'Oriel.exe'

. (Join-Path $root 'src\build\DotnetSdk.ps1')
. (Join-Path $root 'src\build\RunningWidget.ps1')

# Before anything else, including announcing the build: the publish replaces $exe,
# and Windows locks a running image. Discovering that at the delete below produces
# an access-denied error underneath a "Building with ..." line, which reads like a
# broken compiler rather than an open application.
$lock = Resolve-WidgetLock -ExePath $exe -StopWidget:($StopWidget -or $Run)
switch ($lock.Action) {
    'proceed' { }
    'stopped' { Write-Host $lock.Message -ForegroundColor Yellow }
    'blocked' {
        Write-Host 'Cannot build: the widget is running.' -ForegroundColor Red
        Write-Host ''
        Write-Host $lock.Message
        exit 1
    }
    # An unrecognised decision must not fall through into a build: the whole point
    # of the guard is that publishing over a locked file is not attempted.
    default { Write-Host "Unknown widget-lock decision '$($lock.Action)'." -ForegroundColor Red; exit 1 }
}

$dotnet = Resolve-DotnetSdk -RequiredMajor 8
if (-not $dotnet) {
    Write-Host 'No .NET 8 (or newer) SDK found.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  A `dotnet` on PATH is often a runtime-only install, which cannot build.'
    Write-Host '  Install the SDK: https://dotnet.microsoft.com/download/dotnet/8.0'
    Write-Host '  Already installed somewhere unusual? Point DOTNET_ROOT at it.'
    exit 1
}

Write-Host "Building with $dotnet" -ForegroundColor Cyan

# Drop the previous executable first. `dotnet publish` overlays its output
# directory, so without this a failed publish can leave yesterday's binary sitting
# in dist/ and every check below would happily pass on it.
if (Test-Path $exe) { Remove-Item $exe -Force }

# Publish settings (self-contained, single-file, win-x64) live in the csproj so a
# plain `dotnet publish` from any tooling produces the same artefact this does.
& $dotnet publish $project -c $Configuration -o $outDir --nologo
if ($LASTEXITCODE -ne 0) { Write-Host 'BUILD FAILED' -ForegroundColor Red; exit $LASTEXITCODE }

if (-not (Test-Path $exe)) {
    Write-Host "Publish reported success but $exe is missing." -ForegroundColor Red
    exit 1
}

$mb = [math]::Round((Get-Item $exe).Length / 1MB, 1)
Write-Host ''
Write-Host "Built $exe ($mb MB)" -ForegroundColor Green
Write-Host '  Double-click it to run — no .NET runtime required.'

if ($Run) {
    Write-Host 'Launching...' -ForegroundColor Cyan
    Start-Process -FilePath $exe
}
