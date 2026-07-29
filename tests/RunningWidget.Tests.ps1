# Pester 3.4 tests for the build's running-widget guard (ticket 08).
#
# Why this has a seam at all: the widget runs from the executable the build is
# about to replace, and Windows locks a running image. The build deletes that
# executable on purpose — so a failed publish cannot leave yesterday's binary for
# the later checks to pass on — which means "is it running?" has to be answered
# before any build work, not discovered at the delete.
#
# The process table is injectable so the rule can be tested without launching or
# killing anything real.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\src\build\RunningWidget.ps1')

function New-FakeProcess {
    param([int] $Id, [string] $Path)
    [pscustomobject]@{ Id = $Id; Path = $Path }
}

$Exe = 'D:\repo\dist\Oriel.exe'

Describe 'Get-RunningWidget' {
    It 'finds a process running from the executable being built' {
        $probe = { param($name) @(New-FakeProcess 100 'D:\repo\dist\Oriel.exe') }
        $found = Get-RunningWidget -ExePath $Exe -Probe $probe
        @($found).Count | Should Be 1
        @($found)[0].Id | Should Be 100
    }

    It 'matches regardless of case and separator differences' {
        # The build composes its path with Join-Path; the process reports whatever
        # it was launched with. Neither is canonical, so neither can be trusted raw.
        $probe = { param($name) @(New-FakeProcess 101 'd:\REPO\dist\..\dist\Oriel.EXE') }
        $found = Get-RunningWidget -ExePath $Exe -Probe $probe
        @($found).Count | Should Be 1
    }

    It 'ignores a same-named widget running from a different location' {
        # A second clone, or a copy the user keeps elsewhere, holds no lock on the
        # file this build is about to replace — so it is none of the build's business.
        $probe = { param($name) @(New-FakeProcess 102 'C:\elsewhere\dist\Oriel.exe') }
        $found = Get-RunningWidget -ExePath $Exe -Probe $probe
        @($found).Count | Should Be 0
    }

    It 'returns an empty collection when nothing is running' {
        $probe = { param($name) @() }
        @(Get-RunningWidget -ExePath $Exe -Probe $probe).Count | Should Be 0
    }

    It 'tolerates a process whose path cannot be read' {
        # Reading .Path on a protected process throws. One of those must not take
        # the build down before it starts.
        $hostile = [pscustomobject]@{ Id = 4 }
        $hostile | Add-Member -MemberType ScriptProperty -Name Path -Value { throw 'Access is denied' }
        $probe = { param($name) @($hostile, (New-FakeProcess 103 'D:\repo\dist\Oriel.exe')) }
        $found = Get-RunningWidget -ExePath $Exe -Probe $probe
        @($found).Count | Should Be 1
        @($found)[0].Id | Should Be 103
    }

    It 'probes by process name rather than scanning every process' {
        $seen = $null
        $probe = { param($name) $script:seen = $name; @() }
        Get-RunningWidget -ExePath $Exe -Probe $probe | Out-Null
        $script:seen | Should Be 'Oriel'
    }
}

Describe 'Resolve-WidgetLock' {
    $running = { param($name) @(New-FakeProcess 200 'D:\repo\dist\Oriel.exe') }
    $idle    = { param($name) @() }

    It 'proceeds when the widget is not running' {
        $d = Resolve-WidgetLock -ExePath $Exe -Probe $idle
        $d.Action | Should Be 'proceed'
    }

    It 'blocks when the widget is running and stopping was not asked for' {
        $d = Resolve-WidgetLock -ExePath $Exe -Probe $running
        $d.Action | Should Be 'blocked'
    }

    It 'names the remedy in the message it blocks with' {
        # The whole point of the ticket: the old failure said "access denied" and
        # pointed nowhere near the fix.
        $d = Resolve-WidgetLock -ExePath $Exe -Probe $running
        $d.Message | Should Match '-StopWidget'
        $d.Message | Should Match '(?i)running'
    }

    It 'reports which process is holding the file' {
        $d = Resolve-WidgetLock -ExePath $Exe -Probe $running
        $d.Message | Should Match '200'
    }

    It 'stops the widget when asked, and proceeds' {
        $script:stopped = @()
        $stop = { param($p) $script:stopped += $p.Id }
        $gone = { param($p) $false }   # already dead once stopped
        $d = Resolve-WidgetLock -ExePath $Exe -Probe $running -StopWidget -Stop $stop -IsAlive $gone
        $d.Action     | Should Be 'stopped'
        $script:stopped | Should Be 200
    }

    It 'stops every matching process, not just the first' {
        $two = { param($name) @(
            (New-FakeProcess 201 'D:\repo\dist\Oriel.exe'),
            (New-FakeProcess 202 'D:\repo\dist\Oriel.exe')) }
        $script:stopped = @()
        $stop = { param($p) $script:stopped += $p.Id }
        $gone = { param($p) $false }
        $d = Resolve-WidgetLock -ExePath $Exe -Probe $two -StopWidget -Stop $stop -IsAlive $gone
        $d.Action | Should Be 'stopped'
        ($script:stopped -join ',') | Should Be '201,202'
    }

    It 'blocks rather than pretending, when the process will not die' {
        # Stopping is not instant and is not guaranteed. Returning "stopped" here
        # would hand the build a file that is still locked.
        $stop  = { param($p) }
        $alive = { param($p) $true }
        $d = Resolve-WidgetLock -ExePath $Exe -Probe $running -StopWidget -Stop $stop -IsAlive $alive -TimeoutMs 300 -PollMs 50
        $d.Action | Should Be 'blocked'
    }

    It 'blocks rather than crashing when stopping throws' {
        $stop  = { param($p) throw 'Access is denied' }
        $alive = { param($p) $true }
        $d = Resolve-WidgetLock -ExePath $Exe -Probe $running -StopWidget -Stop $stop -IsAlive $alive -TimeoutMs 300 -PollMs 50
        $d.Action  | Should Be 'blocked'
        $d.Message | Should Match '(?i)access is denied'
    }
}
