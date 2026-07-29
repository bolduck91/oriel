# Pester 3.4-compatible tests for the normalized-record builder (ticket 01).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\src\tee\Normalize.ps1')

# Build a statusline-shaped object the way ConvertFrom-Json would produce it.
function New-StatusJson {
    param($fivePct, $fiveReset, $sevenPct, $sevenReset, [switch]$NoRateLimits, [switch]$NoFive, [switch]$NoSeven)
    if ($NoRateLimits) { return [pscustomobject]@{ model = [pscustomobject]@{ display_name = 'Opus' } } }
    $rl = [pscustomobject]@{}
    if (-not $NoFive)  { $rl | Add-Member five_hour ([pscustomobject]@{ used_percentage = $fivePct;  resets_at = $fiveReset  }) }
    if (-not $NoSeven) { $rl | Add-Member seven_day ([pscustomobject]@{ used_percentage = $sevenPct; resets_at = $sevenReset }) }
    [pscustomobject]@{ rate_limits = $rl }
}

Describe 'ConvertTo-UsageRecord' {

    It 'maps both windows and stamps written_at' {
        $j = New-StatusJson -fivePct 63 -fiveReset 1000000 -sevenPct 15 -sevenReset 2000000
        $r = ConvertTo-UsageRecord -StatusJson $j -Now 12345
        $r.five_hour.used_percentage | Should Be 63
        $r.five_hour.resets_at       | Should Be 1000000
        $r.seven_day.used_percentage | Should Be 15
        $r.seven_day.resets_at       | Should Be 2000000
        $r.written_at                | Should Be 12345
    }

    It 'accepts a genuine 0 used_percentage (0 is present, not absent)' {
        $j = New-StatusJson -fivePct 0 -fiveReset 1000000 -sevenPct 0 -sevenReset 2000000
        $r = ConvertTo-UsageRecord -StatusJson $j -Now 1
        $r.five_hour.used_percentage | Should Be 0
        $r.seven_day.used_percentage | Should Be 0
    }

    It 'returns $null when rate_limits is absent (never-tee-nulls)' {
        $j = New-StatusJson -NoRateLimits
        ConvertTo-UsageRecord -StatusJson $j -Now 1 | Should BeNullOrEmpty
    }

    It 'returns $null when the five_hour window is absent' {
        $j = New-StatusJson -NoFive -sevenPct 15 -sevenReset 2000000
        ConvertTo-UsageRecord -StatusJson $j -Now 1 | Should BeNullOrEmpty
    }

    It 'returns $null when the seven_day window is absent' {
        $j = New-StatusJson -NoSeven -fivePct 63 -fiveReset 1000000
        ConvertTo-UsageRecord -StatusJson $j -Now 1 | Should BeNullOrEmpty
    }

    It 'returns $null when a used_percentage is missing but resets_at present' {
        $j = New-StatusJson -fivePct $null -fiveReset 1000000 -sevenPct 15 -sevenReset 2000000
        ConvertTo-UsageRecord -StatusJson $j -Now 1 | Should BeNullOrEmpty
    }

    It 'returns $null when a resets_at is missing' {
        $j = New-StatusJson -fivePct 63 -fiveReset $null -sevenPct 15 -sevenReset 2000000
        ConvertTo-UsageRecord -StatusJson $j -Now 1 | Should BeNullOrEmpty
    }

    It 'returns $null on a completely null input' {
        ConvertTo-UsageRecord -StatusJson $null -Now 1 | Should BeNullOrEmpty
    }

    It 'coerces string-typed numbers to numeric' {
        $j = New-StatusJson -fivePct '63' -fiveReset '1000000' -sevenPct '15' -sevenReset '2000000'
        $r = ConvertTo-UsageRecord -StatusJson $j -Now 1
        $r.five_hour.used_percentage | Should Be 63
        $r.five_hour.resets_at       | Should Be 1000000
    }
}
