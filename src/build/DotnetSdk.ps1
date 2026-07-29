# Finding a .NET SDK host to build with (ticket 03).
#
# `dotnet` on PATH is not necessarily an SDK. The Program Files host that ships
# alongside a runtime answers `--list-sdks` with nothing, and `dotnet publish`
# against it fails with a message about the project rather than about the missing
# SDK. So we probe explicitly and say the true thing when nothing is found.

Set-StrictMode -Version Latest

<#
.SYNOPSIS
Candidate `dotnet` hosts, in preference order.

.DESCRIPTION
PATH first — a machine with a properly installed SDK should build with its own
toolchain. The per-user %LOCALAPPDATA% install (what `dotnet-install.ps1` and the
VS Code .NET extension drop) is the fallback: real, but invisible to PATH.
#>
function Get-DotnetCandidate {
    $candidates = @('dotnet')
    foreach ($root in @($env:DOTNET_ROOT, (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'), "$env:ProgramFiles\dotnet")) {
        if ($root) { $candidates += (Join-Path $root 'dotnet.exe') }
    }
    , ($candidates | Select-Object -Unique)
}

<#
.SYNOPSIS
The first candidate host that actually has an SDK of at least $RequiredMajor.

.PARAMETER Probe
Given a host path, returns its `--list-sdks` lines. Injectable so the selection
rule can be tested without a real toolchain on the box.

.OUTPUTS
The host path, or nothing when no candidate qualifies.
#>
function Resolve-DotnetSdk {
    param(
        [string[]] $Candidate = (Get-DotnetCandidate),
        [int] $RequiredMajor = 8,
        [scriptblock] $Probe = { param($exe) & $exe --list-sdks 2>$null }
    )

    foreach ($exe in $Candidate) {
        $lines = $null
        try { $lines = & $Probe $exe } catch { continue }
        foreach ($line in @($lines)) {
            # "8.0.423 [C:\Users\me\AppData\Local\Microsoft\dotnet\sdk]"
            if ("$line" -match '^\s*(\d+)\.') {
                if ([int]$Matches[1] -ge $RequiredMajor) { return $exe }
            }
        }
    }
}
