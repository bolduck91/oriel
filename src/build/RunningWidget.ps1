# Is the widget we are about to publish over currently running? (ticket 08)
#
# The build deletes dist\Oriel.exe before publishing, deliberately: a
# failed publish must not leave yesterday's binary sitting there for the later
# checks to pass on. Windows locks a running image, so that delete is denied while
# the widget is open — and it is denied *after* the build has already announced
# itself, which makes a one-keystroke problem read like a broken compiler.
#
# So the question is answered up front, and the process table is injectable, which
# is what lets the rule be tested without launching or killing anything real.

Set-StrictMode -Version Latest

# The real process table. Declared once and used as the default for both functions
# below, so there is a single place where "how do we look for it" is decided.
$script:DefaultProbe = { param($name) Get-Process -Name $name -ErrorAction SilentlyContinue }

function ConvertTo-ComparablePath {
    # Neither side of the comparison is canonical: the build composes its path with
    # Join-Path, the process reports whatever it was launched with. Normalise both,
    # and fall back to the raw string rather than throwing on anything exotic.
    param([string] $Path)
    if (-not $Path) { return '' }
    try { return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\').ToLowerInvariant() }
    catch { return $Path.TrimEnd('\').ToLowerInvariant() }
}

<#
.SYNOPSIS
The processes running from exactly this executable.

.PARAMETER Probe
Given a process name, returns candidate processes. Injectable so the matching
rule can be tested without a real widget.

.OUTPUTS
An array — empty when nothing matches.
#>
function Get-RunningWidget {
    param(
        [Parameter(Mandatory = $true)][string] $ExePath,
        [scriptblock] $Probe = $script:DefaultProbe
    )
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    $want = ConvertTo-ComparablePath $ExePath

    $found = @()
    foreach ($p in @(& $Probe $name)) {
        if (-not $p) { continue }
        # Reading .Path on a protected process throws; that is not our business.
        $path = $null
        try { $path = $p.Path } catch { continue }
        if ($path -and (ConvertTo-ComparablePath $path) -eq $want) { $found += $p }
    }
    # Plain output, not the ,$array idiom: wrapping an *empty* result makes it
    # arrive at the caller as one element (an empty array) rather than none, and
    # every caller here wraps in @() anyway.
    $found
}

<#
.SYNOPSIS
Decide what the build should do about a running widget.

.DESCRIPTION
Returns one of three actions:

  proceed  nothing is holding the file
  stopped  it was running, -StopWidget was given, and it is now gone
  blocked  it is running and the build must not continue

Blocking is the default on purpose: building must never terminate a running
application as a side effect the caller did not ask for. "stopped" is only
reported once the process is actually gone — stopping is neither instant nor
guaranteed, and claiming otherwise would hand the build a file that is still
locked.

.OUTPUTS
[pscustomobject] with Action and Message.
#>
function Resolve-WidgetLock {
    param(
        [Parameter(Mandatory = $true)][string] $ExePath,
        [switch] $StopWidget,
        [scriptblock] $Probe   = $script:DefaultProbe,
        [scriptblock] $Stop    = { param($p) Stop-Process -Id $p.Id -Force -ErrorAction Stop },
        [scriptblock] $IsAlive = { param($p) $null -ne (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) },
        [int] $TimeoutMs = 5000,
        [int] $PollMs    = 100
    )

    $running = @(Get-RunningWidget -ExePath $ExePath -Probe $Probe)
    if ($running.Count -eq 0) {
        return [pscustomobject]@{ Action = 'proceed'; Message = '' }
    }

    $ids = ($running | ForEach-Object { $_.Id }) -join ', '

    if (-not $StopWidget) {
        return [pscustomobject]@{
            Action  = 'blocked'
            Message = @(
                "The widget is running (pid $ids) from the executable this build replaces,"
                "and Windows locks a running image."
                ''
                '  Close the widget, or rebuild with -StopWidget to have it closed for you.'
                '  (-Run implies -StopWidget, since it relaunches the widget anyway.)'
            ) -join [Environment]::NewLine
        }
    }

    foreach ($p in $running) {
        try { & $Stop $p }
        catch {
            return [pscustomobject]@{
                Action  = 'blocked'
                Message = "Could not stop the running widget (pid $($p.Id)): $($_.Exception.Message)"
            }
        }
    }

    # Stop-Process returns before the handle is necessarily released, so wait for
    # the process to actually be gone rather than racing the publish against it.
    $deadline = [Environment]::TickCount + $TimeoutMs
    do {
        $stillUp = @($running | Where-Object { & $IsAlive $_ })
        if ($stillUp.Count -eq 0) {
            return [pscustomobject]@{
                Action  = 'stopped'
                Message = "Stopped the running widget (pid $ids)."
            }
        }
        Start-Sleep -Milliseconds $PollMs
    } while ([Environment]::TickCount -lt $deadline)

    [pscustomobject]@{
        Action  = 'blocked'
        Message = "The widget (pid $ids) did not exit within ${TimeoutMs}ms; not building over a locked file."
    }
}

