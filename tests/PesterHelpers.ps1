# Shared helpers for the Pester suite. Dot-source from any *.Tests.ps1:
#
#     . (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'PesterHelpers.ps1')
#
# Not named *.Tests.ps1 on purpose — Invoke-Pester discovers by that suffix, and this
# file holds no tests.
#
# WHY THIS EXISTS. Pester 3.4's throw assertions do not work under PowerShell 7:
# `{ throw 'boom' } | Should Throw` FAILS, reporting that the expression did not throw.
# The corollary is the dangerous half — the negated form therefore PASSES whatever
# happens, including when the thing under test throws. An assertion that cannot fail is
# worse than no assertion, because it reads in the suite as cover.
#
# `Get-Thrown` asserts the same thing honestly: it runs the block and hands back the
# error record, or $null when nothing was thrown. Both directions then go through an
# assertion that can actually fail:
#
#     Get-Thrown { Risky }         | Should Be $null           # must not throw
#     Get-Thrown { Risky }         | Should Not BeNullOrEmpty   # must throw
#
# This was written twice before it was put somewhere shared (avalonia ticket 09, then
# polish ticket 03). NoVacuousAssertions.Tests.ps1 is the guard that keeps the broken
# form from coming back a third time.

function Get-Thrown {
    <#
    .SYNOPSIS
    Run a script block and return the error it threw, or $null if it completed.
    #>
    param([Parameter(Mandatory = $true)][scriptblock] $Action)
    # The block's own output is discarded rather than emitted: a helper that returned
    # "the error, or whatever the block printed" makes `| Should Be $null` fail on a
    # block that succeeded but wrote something. Only the error is news here.
    try { $null = & $Action; return $null } catch { return $_ }
}
