# The guard for polish ticket 03: no assertion in this suite may use a form that
# passes regardless of outcome.
#
# Pester 3.4's throw assertions are broken under PowerShell 7 — the positive form fails
# on a block that does throw, so the negated form passes on a block that throws too.
# The fix is a few lines; the reason this file exists is that the fix had already been
# written once (avalonia ticket 09) and the broken form was still sitting in another
# test file. Rediscovering it a third time is what this prevents.
#
# The replacement lives in PesterHelpers.ps1 (Get-Thrown) and every test file can reach
# it. This file scans the repo's PowerShell instead of trusting that.
#
# Note on scanning itself: the sweep skips comment lines, so prose about the broken
# form — including these lines — is not a finding, and the failure message quotes what
# it found rather than spelling the form out in source.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'PesterHelpers.ps1')

# Assembled to be read, not to be clever: <Should> <optional Not> <Throw>.
$script:BrokenForm = 'Should\s+(Not\s+)?Throw\b'

function Get-PowerShellSource {
    $root = Split-Path -Parent $here
    Get-ChildItem -Path (Join-Path $root 'tests'), (Join-Path $root 'src') -Recurse -Filter '*.ps1'
}

# A line whose first non-space character is # cannot be an assertion, so prose about
# the broken form is allowed to exist — that is how the reason gets recorded.
function Find-BrokenAssertion {
    param([string] $Path)
    # Callers wrap the result in @(): an empty array unrolls to $null on the way out of a
    # function, and $null.Count is a hard error under the StrictMode Run-AllTests sets.
    $findings = @()
    $n = 0
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $n++
        if ($line.TrimStart().StartsWith('#')) { continue }
        $m = [regex]::Match($line, $script:BrokenForm, 'IgnoreCase')
        if ($m.Success) {
            $findings += [pscustomobject]@{ Line = $n; Text = $line.Trim(); Match = $m.Value }
        }
    }
    return $findings
}

Describe 'The suite contains no assertion that cannot fail' {

    It 'uses no Pester 3 throw assertion anywhere in tests or src' {
        $bad = @()
        foreach ($f in Get-PowerShellSource) {
            foreach ($hit in (Find-BrokenAssertion -Path $f.FullName)) {
                $bad += ("{0}:{1}  {2}" -f $f.Name, $hit.Line, $hit.Text)
            }
        }
        if ($bad.Count -gt 0) {
            $why = @(
                "Found $($bad.Count) assertion(s) using a Pester 3 throw form. It does not work here:",
                "Pester 3.4 under PowerShell 7 fails the positive form even on a block that DOES",
                "throw, so the negated form passes whatever happens — it reads as cover and asserts",
                "nothing. Use Get-Thrown from tests/PesterHelpers.ps1 instead:",
                '    Get-Thrown { Risky } | Should Be $null            # must not throw',
                "    Get-Thrown { Risky } | Should Not BeNullOrEmpty   # must throw",
                ""
            ) + $bad
            throw ($why -join [Environment]::NewLine)
        }
        $bad.Count | Should Be 0
    }

    # The scan is only worth anything if it can see the thing it is looking for. Both
    # halves matter: a sweep that misses the form would report a clean suite for ever,
    # and one that flags prose would make recording the reason impossible.
    It 'detects the broken form when it is present in code' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("oriel-guard-" + [guid]::NewGuid().ToString('N') + '.ps1')
        # Written as parts so this file's own source never carries the literal. The
        # parentheses are load-bearing: PowerShell's comma binds tighter than +, so
        # without them the two lines concatenate into one.
        Set-Content -LiteralPath $tmp -Encoding utf8 -Value @(
            ('{ throw ''boom'' } | ' + 'Should' + ' ' + 'Throw'),
            ('{ 1 + 1 } | ' + 'Should' + ' Not ' + 'Throw')
        )
        try {
            @(Find-BrokenAssertion -Path $tmp).Count | Should Be 2
        } finally {
            Remove-Item -LiteralPath $tmp -Force
        }
    }

    It 'does not flag a comment that merely mentions it' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("oriel-guard-" + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $tmp -Encoding utf8 -Value @(
            ('# ' + 'Should' + ' ' + 'Throw' + ' does not work under PowerShell 7.'),
            ('    #   ' + 'Should' + ' Not ' + 'Throw' + ' therefore passes whatever happens.')
        )
        try {
            @(Find-BrokenAssertion -Path $tmp).Count | Should Be 0
        } finally {
            Remove-Item -LiteralPath $tmp -Force
        }
    }

    # Get-Thrown is the replacement, so the guard is only honest if the replacement
    # itself is known to work — in both directions.
    It 'has a working replacement: Get-Thrown reports a throw' {
        (Get-Thrown { throw 'boom' }) | Should Not BeNullOrEmpty
    }

    It 'has a working replacement: Get-Thrown reports no throw' {
        (Get-Thrown { 1 + 1 }) | Should Be $null
    }
}
