# Pester 3.4 tests for the shared atomic writer (ticket 09).
#
# The happy path is covered from the tee's side in WriteUsageState.Tests.ps1.
# What is tested here is the part the tee does not own: that a write cleans up
# after itself, and that temps stranded by dead sessions do not accumulate.
#
# Note on structure: the failure cases mock Move-Item, and a Pester 3 mock lives
# for the whole block it is declared in — not just the It. So each mocked
# scenario gets its own block; sharing one with the hygiene tests would silence
# every real write after it.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\src\tee\AtomicWrite.ps1')
# Get-Thrown — the honest stand-in for Pester 3.4's broken throw assertions, which was
# born here and now lives with the rest of the shared helpers (polish ticket 03).
. (Join-Path $here 'PesterHelpers.ps1')

function New-TestStateDir {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("oriel-atomic-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

# Plant a temp file as if a previous session had died mid-write.
function New-Orphan {
    param([string] $Dir, [string] $Name, [int] $AgeSeconds)
    $p = Join-Path $Dir $Name
    Set-Content -LiteralPath $p -Value '{"half":' -Encoding utf8
    (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddSeconds(-$AgeSeconds)
    return $p
}

Describe 'Write-JsonAtomic temp-file hygiene' {
    BeforeEach {
        $script:dir  = New-TestStateDir
        $script:path = Join-Path $script:dir 'current.json'
    }
    AfterEach {
        if (Test-Path $script:dir) { Remove-Item -Recurse -Force $script:dir }
    }

    It 'collects a stale temp left by an earlier session' {
        New-Orphan -Dir $script:dir -Name 'current.json.99999.tmp' -AgeSeconds 7200 | Out-Null
        Write-JsonAtomic -Object @{ a = 1 } -Path $script:path
        Test-Path (Join-Path $script:dir 'current.json.99999.tmp') | Should Be $false
    }

    It 'leaves a recent temp alone, so a concurrent write is never destroyed' {
        New-Orphan -Dir $script:dir -Name 'current.json.99998.tmp' -AgeSeconds 5 | Out-Null
        Write-JsonAtomic -Object @{ a = 1 } -Path $script:path
        Test-Path (Join-Path $script:dir 'current.json.99998.tmp') | Should Be $true
    }

    It 'collects by age, not by whether the PID is alive (live PID, old file)' {
        # PIDs are reused, so liveness must not protect an old temp.
        #
        # Deliberately NOT this process's own PID: the writer's temp is named
        # "<path>.<PID>.tmp", so planting that exact name would be carried off by
        # the write's own move and prove nothing about the sweep.
        $otherLive = (Get-Process | Where-Object { $_.Id -ne $PID } | Select-Object -First 1).Id
        $otherLive | Should Not BeNullOrEmpty
        New-Orphan -Dir $script:dir -Name "current.json.$otherLive.tmp" -AgeSeconds 7200 | Out-Null
        Write-JsonAtomic -Object @{ a = 1 } -Path $script:path
        Test-Path (Join-Path $script:dir "current.json.$otherLive.tmp") | Should Be $false
    }

    It 'collects by age, not by whether the PID is alive (dead PID, new file)' {
        # The mirror image: a PID owning nothing, but written seconds ago, is an
        # in-flight write from a session whose PID we cannot resolve.
        New-Orphan -Dir $script:dir -Name 'current.json.999999999.tmp' -AgeSeconds 5 | Out-Null
        Write-JsonAtomic -Object @{ a = 1 } -Path $script:path
        Test-Path (Join-Path $script:dir 'current.json.999999999.tmp') | Should Be $true
    }

    It 'only collects temps belonging to the file being written' {
        # current.json and config.json share a directory.
        New-Orphan -Dir $script:dir -Name 'config.json.99999.tmp' -AgeSeconds 7200 | Out-Null
        Write-JsonAtomic -Object @{ a = 1 } -Path $script:path
        Test-Path (Join-Path $script:dir 'config.json.99999.tmp') | Should Be $true
    }

    It 'ignores files that only resemble a temp' {
        New-Orphan -Dir $script:dir -Name 'current.json.backup.tmp' -AgeSeconds 7200 | Out-Null
        New-Orphan -Dir $script:dir -Name 'current.json.tmp'        -AgeSeconds 7200 | Out-Null
        Write-JsonAtomic -Object @{ a = 1 } -Path $script:path
        Test-Path (Join-Path $script:dir 'current.json.backup.tmp') | Should Be $true
        Test-Path (Join-Path $script:dir 'current.json.tmp')        | Should Be $true
    }

    It 'still writes the record when the sweep cannot delete' {
        # The sweep is a side effect of a side effect: if it cannot remove a file,
        # the write it accompanies must still succeed (fail-silent contract).
        $orphan = New-Orphan -Dir $script:dir -Name 'current.json.99999.tmp' -AgeSeconds 7200
        $locked = [System.IO.File]::Open(
            $orphan,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None)
        try {
            $err = Get-Thrown { Write-JsonAtomic -Object @{ a = 42 } -Path $script:path }
            $err | Should Be $null
            (Get-Content -Raw $script:path | ConvertFrom-Json).a | Should Be 42
        } finally {
            $locked.Close()
        }
    }

    It 'leaves no temp behind across repeated writes' {
        Write-JsonAtomic -Object @{ a = 1 } -Path $script:path
        Write-JsonAtomic -Object @{ a = 2 } -Path $script:path
        (Get-Content -Raw $script:path | ConvertFrom-Json).a | Should Be 2
        (Get-ChildItem $script:dir -Filter '*.tmp' | Measure-Object).Count | Should Be 0
    }
}

Describe 'Write-JsonAtomic when the move cannot complete' {
    # A destination held open with no sharing is the one condition that reliably
    # denies the move on Windows — verified rather than assumed, after a
    # read-only destination and a directory-shaped destination both turned out to
    # let the move through.
    #
    # This is also the regression guard for the silent-success bug: Move-Item
    # fails *non-terminating*, so before ticket 09 a denied move returned as
    # though the record had been written. The tee reported success, current.json
    # still held the old data, and the temp was stranded.
    BeforeEach {
        $script:dir  = New-TestStateDir
        $script:path = Join-Path $script:dir 'current.json'
        Set-Content -LiteralPath $script:path -Value '{"old":true}' -Encoding utf8
        $script:held = [System.IO.File]::Open(
            $script:path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None)
    }
    AfterEach {
        if ($script:held) { $script:held.Close() }
        if (Test-Path $script:dir) { Remove-Item -Recurse -Force $script:dir }
    }

    It 'surfaces the failure instead of reporting a silent success' {
        $err = Get-Thrown { Write-JsonAtomic -Object @{ a = 1 } -Path $script:path }
        $err | Should Not BeNullOrEmpty
    }

    It 'removes its own temp rather than stranding it' {
        Get-Thrown { Write-JsonAtomic -Object @{ a = 1 } -Path $script:path } | Out-Null
        (Get-ChildItem $script:dir -Filter '*.tmp' | Measure-Object).Count | Should Be 0
    }

    It 'leaves the previous record untouched' {
        Get-Thrown { Write-JsonAtomic -Object @{ a = 1 } -Path $script:path } | Out-Null
        $script:held.Close()
        (Get-Content -Raw $script:path | ConvertFrom-Json).old | Should Be $true
    }
}
