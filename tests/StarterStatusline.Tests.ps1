# Pester 3.4 tests for the starter statusline (oriel-distribution ticket 05).
#
# This is the one file Oriel writes that the user actually *looks* at, so what is
# asserted is what appears in their terminal: the segments, the labels, and the reset
# times. Driven by piping representative payloads at the real script, the way Claude
# Code drives it — the prototype's scenario set is the starting point, including a
# session with no rate-limit data yet and a reset falling today versus later.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Starter = (Resolve-Path (Join-Path $here '..\src\install\starter-statusline.ps1')).Path

# Colour is not the subject here, and comparing escape sequences would make every
# assertion unreadable for no gain.
function script:Remove-Ansi {
    param([string] $Text)
    [regex]::Replace($Text, "$([char]27)\[[0-9;]*m", '')
}

function script:Invoke-Starter {
    <#
    .SYNOPSIS
        Render the starter statusline against a payload, under a named interpreter.
    #>
    param($Payload, [string] $Interpreter = 'pwsh')
    $json = $Payload | ConvertTo-Json -Depth 10 -Compress
    $out = $json | & $Interpreter -NoProfile -File $script:Starter 2>&1
    script:Remove-Ansi (($out | Out-String).TrimEnd())
}

# Noon today and noon four days out, so "does this reset fall today?" is decided by
# the calendar and not by what time the suite happens to run.
function script:NoonUnix {
    param([int] $DaysAhead = 0)
    $noon = (Get-Date).Date.AddDays($DaysAhead).AddHours(12)
    [DateTimeOffset]::new($noon).ToUnixTimeSeconds()
}

function script:New-Payload {
    param([long] $FiveReset, [long] $SevenReset, $Rates = $null)
    $payload = [ordered]@{
        model = [ordered]@{ display_name = 'Opus 5' }
        effort = [ordered]@{ level = 'high' }
        context_window = [ordered]@{ used_percentage = 42 }
        workspace = [ordered]@{ current_dir = 'C:\code\oriel' }
    }
    if ($null -eq $Rates) {
        $Rates = [ordered]@{
            five_hour = [ordered]@{ used_percentage = 12; resets_at = $FiveReset }
            seven_day = [ordered]@{ used_percentage = 34; resets_at = $SevenReset }
        }
    }
    if ($Rates -ne 'omit') { $payload['rate_limits'] = $Rates }
    $payload
}

Describe 'The starter statusline is worth having in its own right' {

    It 'shows the model, the context use with a (ctx) label, and both windows' {
        $out = script:Invoke-Starter (script:New-Payload (script:NoonUnix 0) (script:NoonUnix 4))
        $out | Should Match 'Opus 5'
        $out | Should Match 'high'
        $out | Should Match '42% \(ctx\)'
        $out | Should Match '12% \(5h\)'
        $out | Should Match '34% \(7d\)'
    }

    It 'labels the context percentage so it cannot be read as a window' {
        # The whole point of the label: three percentages on one line, only two of
        # which are rate-limit windows.
        $out = script:Invoke-Starter (script:New-Payload (script:NoonUnix 0) (script:NoonUnix 4))
        ([regex]::Matches($out, '\(ctx\)')).Count | Should Be 1
    }

    It 'puts the working directory on a second line' {
        $out = script:Invoke-Starter (script:New-Payload (script:NoonUnix 0) (script:NoonUnix 4))
        ($out -split "`n")[-1].Trim() | Should Be 'oriel'
    }
}

Describe 'The reset time is adaptive' {

    It 'is a bare clock time when the reset falls today' {
        $out = script:Invoke-Starter (script:New-Payload (script:NoonUnix 0) (script:NoonUnix 0))
        # Both windows reset today, so neither carries a weekday.
        $out | Should Match '12% \(5h\) 12:00'
        $out | Should Match '34% \(7d\) 12:00'
    }

    It 'carries a weekday when the reset falls later' {
        $out = script:Invoke-Starter (script:New-Payload (script:NoonUnix 0) (script:NoonUnix 4))
        $weekday = (Get-Date).Date.AddDays(4).ToString('ddd')
        $out | Should Match ('34% \(7d\) ' + [regex]::Escape($weekday) + ' 12:00')
        # ...and the 5-hour window, resetting today, does not.
        $out | Should Match '12% \(5h\) 12:00'
    }

    It 'returns the 7-day window to a bare time as it comes due' {
        $out = script:Invoke-Starter (script:New-Payload (script:NoonUnix 0) (script:NoonUnix 0))
        $out | Should Not Match '\(7d\) [A-Za-z]'
    }
}

Describe 'The starter statusline survives a thin session' {

    It 'renders without error when there is no rate-limit data yet' {
        $out = script:Invoke-Starter (script:New-Payload 0 0 -Rates 'omit')
        $out | Should Match 'Opus 5'
        $out | Should Match '\(ctx\)'
        $out | Should Not Match '\(5h\)'
        $out | Should Not Match 'Exception'
        $out | Should Not Match 'error'
    }

    It 'renders without error when a window is present but empty' {
        $rates = [ordered]@{ five_hour = [ordered]@{}; seven_day = [ordered]@{} }
        $out = script:Invoke-Starter (script:New-Payload 0 0 -Rates $rates)
        $out | Should Match '\(ctx\)'
        $out | Should Not Match 'Exception'
    }

    It 'emits an empty line rather than an error when the JSON is unparseable' {
        $out = 'not json' | & pwsh -NoProfile -File $script:Starter 2>&1 | Out-String
        (script:Remove-Ansi $out).Trim() | Should Be ''
    }
}

Describe 'The starter statusline runs on the interpreter Windows actually ships' {

    # ADR 0013: PowerShell 7 is not part of Windows. The failure this guards against is
    # total and invisible on any machine that has pwsh — which is every machine this is
    # developed on.
    It 'renders identically under Windows PowerShell 5.1' {
        $ps51 = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue
        if (-not $ps51) { throw 'powershell.exe not found — this guard cannot be honest without it.' }

        $payload = script:New-Payload (script:NoonUnix 0) (script:NoonUnix 4)
        $under7  = script:Invoke-Starter $payload -Interpreter 'pwsh'
        $under51 = script:Invoke-Starter $payload -Interpreter 'powershell.exe'
        $under51 | Should BeExactly $under7
    }
}
