# Pester 3.4 tests for the atomic tee writer (ticket 01 / ADR 0002).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\src\tee\Write-UsageState.ps1')
. (Join-Path $here 'PesterHelpers.ps1')

function New-StatusJson {
    param($fivePct, $fiveReset, $sevenPct, $sevenReset, [switch]$NoRateLimits)
    if ($NoRateLimits) { return [pscustomobject]@{ model = 'x' } }
    [pscustomobject]@{ rate_limits = [pscustomobject]@{
        five_hour = [pscustomobject]@{ used_percentage = $fivePct;  resets_at = $fiveReset  }
        seven_day = [pscustomobject]@{ used_percentage = $sevenPct; resets_at = $sevenReset }
    }}
}

# Two tests below have to run the tee in a *child* process — one to prove it stands
# alone outside this repo, one because $HOME is read-only and forcing it here would
# leak into the rest of the suite. They share all of the scaffolding and differ only
# in which tee they dot-source, what runs before it, and how it is called.
function script:Invoke-TeeInChildProcess {
    param(
        [Parameter(Mandatory = $true)][string] $TeePath,
        [Parameter(Mandatory = $true)][string] $WorkingDir,
        [string] $Prologue  = '',
        [string] $Arguments = ''
    )
    $body = @"
`$ErrorActionPreference = 'Stop'
$Prologue
. '$TeePath'
`$j = [pscustomobject]@{ rate_limits = [pscustomobject]@{
    five_hour = [pscustomobject]@{ used_percentage = 5;  resets_at = 10 }
    seven_day = [pscustomobject]@{ used_percentage = 6;  resets_at = 20 }
}}
Write-UsageState -StatusJson `$j $Arguments -Now 7 | Out-Null
"@
    $file = Join-Path $WorkingDir 'run.ps1'
    Set-Content -LiteralPath $file -Value $body -Encoding utf8
    & pwsh -NoProfile -File $file
    return $LASTEXITCODE
}

Describe 'Write-UsageState' {
    BeforeEach {
        $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) ("oriel-test-" + [guid]::NewGuid().ToString('N'))
    }
    AfterEach {
        if (Test-Path $script:dir) { Remove-Item -Recurse -Force $script:dir }
    }

    It 'writes current.json with the normalized record and returns $true' {
        $ok = Write-UsageState -StatusJson (New-StatusJson 63 1000000 15 2000000) -StateDir $script:dir -Now 999
        $ok | Should Be $true
        $p = Join-Path $script:dir 'current.json'
        Test-Path $p | Should Be $true
        $rec = Get-Content -Raw $p | ConvertFrom-Json
        $rec.five_hour.used_percentage | Should Be 63
        $rec.seven_day.resets_at       | Should Be 2000000
        $rec.written_at                | Should Be 999
    }

    It 'never tees nulls: leaves the previous file intact when rate_limits absent' {
        Write-UsageState -StatusJson (New-StatusJson 40 111 10 222) -StateDir $script:dir -Now 100 | Out-Null
        $before = Get-Content -Raw (Join-Path $script:dir 'current.json')
        $ok = Write-UsageState -StatusJson (New-StatusJson -NoRateLimits) -StateDir $script:dir -Now 200
        $ok | Should Be $false
        $after = Get-Content -Raw (Join-Path $script:dir 'current.json')
        $after | Should Be $before
    }

    It 'creates the state directory if it does not exist' {
        Test-Path $script:dir | Should Be $false
        Write-UsageState -StatusJson (New-StatusJson 1 2 3 4) -StateDir $script:dir -Now 1 | Out-Null
        Test-Path (Join-Path $script:dir 'current.json') | Should Be $true
    }

    It 'leaves no leftover temp file after a successful write' {
        Write-UsageState -StatusJson (New-StatusJson 1 2 3 4) -StateDir $script:dir -Now 1 | Out-Null
        (Get-ChildItem $script:dir -Filter '*.tmp' | Measure-Object).Count | Should Be 0
    }

    It 'overwrites an existing record (last-write-wins)' {
        Write-UsageState -StatusJson (New-StatusJson 10 1 10 1) -StateDir $script:dir -Now 1 | Out-Null
        Write-UsageState -StatusJson (New-StatusJson 90 5 20 5) -StateDir $script:dir -Now 2 | Out-Null
        $rec = Get-Content -Raw (Join-Path $script:dir 'current.json') | ConvertFrom-Json
        $rec.five_hour.used_percentage | Should Be 90
        $rec.written_at | Should Be 2
    }

    It 'writes the exact on-disk bytes the widget contract expects' {
        Write-UsageState -StatusJson (New-StatusJson 63 1000000 15 2000000) -StateDir $script:dir -Now 999 | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:dir 'current.json'))
        # No BOM: the widget reads this file on every poll and must not see one.
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should Be $false
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should BeExactly `
            '{"five_hour":{"used_percentage":63.0,"resets_at":1000000},"seven_day":{"used_percentage":15.0,"resets_at":2000000},"written_at":999}'
    }

    It 'runs with only its own directory present (self-contained)' {
        $isolated = Join-Path ([System.IO.Path]::GetTempPath()) ("oriel-tee-" + [guid]::NewGuid().ToString('N'))
        Copy-Item -Recurse -Path (Join-Path $here '..\src\tee') -Destination $isolated
        try {
            $code = script:Invoke-TeeInChildProcess `
                -TeePath (Join-Path $isolated 'Write-UsageState.ps1') `
                -WorkingDir $isolated `
                -Arguments "-StateDir '$script:dir'"
            $code | Should Be 0
            $rec = Get-Content -Raw (Join-Path $script:dir 'current.json') | ConvertFrom-Json
            $rec.written_at | Should Be 7
        } finally {
            Remove-Item -Recurse -Force $isolated
        }
    }

    It 'defaults to the Oriel state directory in the user home' {
        # The widget looks in ~/.claude/oriel and nowhere else, so the tee's default has
        # to land there or an install that overrides nothing feeds nothing.
        $fakeHome = Join-Path ([System.IO.Path]::GetTempPath()) ("oriel-home-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fakeHome | Out-Null
        try {
            $code = script:Invoke-TeeInChildProcess `
                -TeePath (Resolve-Path (Join-Path $here '..\src\tee\Write-UsageState.ps1')).Path `
                -WorkingDir $fakeHome `
                -Prologue "Set-Variable -Name HOME -Value '$fakeHome' -Force -Scope Global"
            $code | Should Be 0
            Test-Path (Join-Path $fakeHome '.claude/oriel/current.json') | Should Be $true
        } finally {
            Remove-Item -Recurse -Force $fakeHome
        }
    }

    It 'produces valid JSON that round-trips' {
        # Get-Thrown rather than a Pester 3 throw assertion, which passes regardless of
        # outcome under PowerShell 7 (polish ticket 03). The parsed record is checked as
        # well as the parse: "it did not throw" alone would also hold for a file whose
        # JSON is valid but empty.
        Write-UsageState -StatusJson (New-StatusJson 55 1700000000 33 1700600000) -StateDir $script:dir -Now 1700000005 | Out-Null
        $raw = Get-Content -Raw (Join-Path $script:dir 'current.json')
        $err = Get-Thrown { $raw | ConvertFrom-Json }
        $err | Should Be $null
        $rec = $raw | ConvertFrom-Json
        $rec.five_hour.used_percentage | Should Be 55
        $rec.seven_day.resets_at       | Should Be 1700600000
        $rec.written_at                | Should Be 1700000005
    }
}
