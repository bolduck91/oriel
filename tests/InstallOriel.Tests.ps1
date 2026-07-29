# Pester 3.4 tests for the installer entry point (oriel-distribution tickets 02-07).
#
# These are the descendants of the old statusline-patcher tests and keep what those
# asserted: re-running changes nothing, and uninstalling gives the original file back
# byte for byte, over a *table of statusline shapes* — because the shapes are where
# this kind of code actually breaks. The table has grown with what triage introduces:
# nothing declared at all, a declared command pointing somewhere unexpected, a
# non-PowerShell interpreter, and PowerShell that never keeps the JSON.
#
# Everything is driven as a process against a substituted environment — its own home
# directory, its own settings file, its own idea of which interpreters exist — so what
# is asserted is what a user would see: the bytes of their statusline, the contents of
# their settings, and what the installer reported. No real Claude home is touched and
# nothing is left behind outside a temporary directory.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'PesterHelpers.ps1')

$script:Installer = (Resolve-Path (Join-Path $here '..\src\install\Install-Oriel.ps1')).Path
$script:TeePath   = (Resolve-Path (Join-Path $here '..\src\tee\Write-UsageState.ps1')).Path

# ---- the shape table -------------------------------------------------------
#
# Every one of these is a *supported* statusline: PowerShell that reads standard input
# and keeps the parsed JSON in a variable. What varies is the shape of the file around
# that assignment, which is what the insertion and its inverse have to survive.
#
# Every fixture reads standard input, because that is now half the definition: a
# `ConvertFrom-Json` with no lineage back to stdin is somebody else's JSON, and
# anchoring on one produced a silent no-op on a real machine (oriel#1).
$script:Read = "`$raw = [Console]::In.ReadToEnd()"

$script:Shapes = [ordered]@{
    'a blank line after the assignment' = "$script:Read`r`n`$d = `$raw | ConvertFrom-Json`r`n`r`nWrite-Host 'hi'`r`n"
    'no blank line after the assignment' = "$script:Read`r`n`$d = `$raw | ConvertFrom-Json`r`nWrite-Host 'hi'`r`n"
    'the read and the parse on one line, at the very start' = "`$d = [Console]::In.ReadToEnd() | ConvertFrom-Json`r`nWrite-Host 'hi'`r`n"
    'LF-only line endings' = "$script:Read`n`$d = `$raw | ConvertFrom-Json`n`nWrite-Host 'hi'`n"
    'no trailing newline' = "$script:Read`r`n`$d = `$raw | ConvertFrom-Json`r`nWrite-Host 'hi'"
    'the assignment on the last line, no trailing newline' = "$script:Read`r`n`$d = `$raw | ConvertFrom-Json"
    'the assignment wrapped in try/catch' = "$script:Read`r`ntry { `$d = `$raw | ConvertFrom-Json } catch { `$d = `$null }`r`nWrite-Host 'hi'`r`n"
    'a scoped assignment' = "$script:Read`r`n`$script:d = `$raw | ConvertFrom-Json`r`nWrite-Host 'hi'`r`n"
    'ConvertFrom-Json called with an argument' = "$script:Read`r`n`$data = ConvertFrom-Json `$raw`r`nWrite-Host 'hi'`r`n"
    'a comment mentioning ConvertFrom-Json first' = "# we call ConvertFrom-Json below`r`n$script:Read`r`n`$d = `$raw | ConvertFrom-Json`r`nWrite-Host 'hi'`r`n"
    'a pipeline broken across lines' = "$script:Read`r`n`$d = `$raw |`r`n    ConvertFrom-Json`r`nWrite-Host 'hi'`r`n"
    'the read reaching the parse through a reader and a trim' = "`$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput())`r`n`$raw = `$reader.ReadToEnd()`r`n`$text = `$raw.Trim()`r`n`$d = `$text | ConvertFrom-Json`r`nWrite-Host 'hi'`r`n"
    'the payload arriving through $input' = "`$d = `$input | ConvertFrom-Json`r`nWrite-Host 'hi'`r`n"
    'Get-Content reading a bare dash' = "`$raw = Get-Content -Raw -`r`n`$d = `$raw | ConvertFrom-Json`r`nWrite-Host 'hi'`r`n"
}

# ---- a substituted environment ---------------------------------------------

function script:New-Env {
    <#
    .SYNOPSIS
        A throwaway home directory with a .claude in it. Everything the installer
        touches is derived from this one path.
    #>
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("oriel-inst-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root '.claude') -Force | Out-Null
    [pscustomobject]@{
        Home     = $root
        Claude   = Join-Path $root '.claude'
        Settings = Join-Path $root '.claude\settings.json'
        State    = Join-Path $root '.claude\oriel'
    }
}

function script:Remove-Env {
    param($Env)
    if ($null -ne $Env -and (Test-Path -LiteralPath $Env.Home)) {
        Remove-Item -LiteralPath $Env.Home -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function script:Set-Statusline {
    <#
    .SYNOPSIS
        Put a statusline of the given bytes on disk and declare it in settings.
    #>
    param($Env, [string] $Body, [string] $Name = 'statusline.ps1', [string] $Interpreter = 'pwsh')
    $path = Join-Path $Env.Claude $Name
    [System.IO.File]::WriteAllText($path, $Body, [System.Text.UTF8Encoding]::new($false))
    script:Set-Settings $Env ($Interpreter + ' -NoProfile -File "' + $path + '"')
    $path
}

function script:Set-Settings {
    # $Command is deliberately untyped: a [string] parameter coerces $null to the
    # empty string, and "no statusline declared" would silently become "a statusline
    # declared as nothing" — a different population entirely.
    param($Env, $Command, $Extra = $null)
    $settings = [ordered]@{}
    if ($null -ne $Extra) { foreach ($k in $Extra.Keys) { $settings[$k] = $Extra[$k] } }
    if (-not [string]::IsNullOrEmpty($Command)) { $settings['statusLine'] = [ordered]@{ type = 'command'; command = $Command } }
    [System.IO.File]::WriteAllText($Env.Settings, ($settings | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
}

function script:Get-Text {
    param([string] $Path)
    [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($Path))
}

# The installer is run as a process, the way both front ends run it. Verification is
# skipped unless a test is specifically about verification: it starts a real
# statusline process, and the shape-table fixtures are not runnable statuslines.
function script:Invoke-Installer {
    param(
        $Env,
        [string] $Action = 'install',
        [switch] $Verify,
        [switch] $KeepStarter,
        [string[]] $Interpreters = @('pwsh', 'powershell.exe')
    )
    # Not $args: that is the automatic unbound-argument array inside a function.
    $argv = @(
        '-NoProfile', '-File', $script:Installer,
        '-Action', $Action,
        '-HomeDir', $Env.Home,
        '-SettingsPath', $Env.Settings,
        '-TeePath', $script:TeePath,
        '-Interpreters', ($Interpreters -join ','),
        '-Json'
    )
    if (-not $Verify) { $argv += '-SkipVerify' }
    if ($KeepStarter) { $argv += '-KeepStarter' }

    $out = & pwsh @argv 2>&1
    $code = $LASTEXITCODE
    $report = $null
    try { $report = ($out | Out-String) | ConvertFrom-Json } catch { }
    [pscustomobject]@{ ExitCode = $code; Report = $report; Raw = ($out | Out-String) }
}

Describe 'Install-Oriel: the shape table' {

    AfterEach { script:Remove-Env $script:env }

    foreach ($shape in $script:Shapes.Keys) {
        $body = $script:Shapes[$shape]

        It "injects exactly one managed block into a statusline with $shape" {
            $script:env = script:New-Env
            $sl = script:Set-Statusline $script:env $body
            $r = script:Invoke-Installer $script:env
            $r.ExitCode | Should Be 0
            $patched = script:Get-Text $sl
            ([regex]::Matches($patched, 'oriel tee \(managed block')).Count | Should Be 1
            $patched | Should Match 'Write-UsageState -StatusJson'
        }

        It "anchors the block immediately after the assignment for a statusline with $shape" {
            $script:env = script:New-Env
            $sl = script:Set-Statusline $script:env $body
            script:Invoke-Installer $script:env | Out-Null
            $lines = (script:Get-Text $sl) -split "`r?`n"
            $blockAt = [array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -like '*oriel tee (managed block*' })
            # The line above the block is the one the assignment completed on.
            $lines[$blockAt - 1] | Should Match 'ConvertFrom-Json'
        }

        It "is idempotent on a statusline with $shape" {
            $script:env = script:New-Env
            $sl = script:Set-Statusline $script:env $body
            script:Invoke-Installer $script:env | Out-Null
            $once = script:Get-Text $sl
            script:Invoke-Installer $script:env | Out-Null
            script:Get-Text $sl | Should BeExactly $once
        }

        It "uninstalls byte-for-byte from a statusline with $shape" {
            $script:env = script:New-Env
            $sl = script:Set-Statusline $script:env $body
            script:Invoke-Installer $script:env | Out-Null
            script:Invoke-Installer $script:env -Action uninstall | Out-Null
            script:Get-Text $sl | Should BeExactly $body
        }

        It "changes nothing but the block in a statusline with $shape" {
            $script:env = script:New-Env
            $sl = script:Set-Statusline $script:env $body
            script:Invoke-Installer $script:env | Out-Null
            $patched = script:Get-Text $sl
            # Strip the block back out in the test's own terms — not the installer's —
            # and what is left has to be the original bytes.
            $stripped = [regex]::Replace($patched, '# >>> oriel tee.*?# <<< oriel tee <<<\r?\n', '', 'Singleline')
            $stripped = [regex]::Replace($stripped, '\r?\n# >>> oriel tee.*?# <<< oriel tee <<<\z', '', 'Singleline')
            $stripped | Should BeExactly $body
        }
    }
}

Describe 'Install-Oriel: triage' {

    AfterEach { script:Remove-Env $script:env }

    It 'reports the three populations before anything is written' {
        $script:env = script:New-Env
        script:Set-Settings $script:env $null
        (script:Invoke-Installer $script:env -Action triage).Report.verdict | Should Be 'none'

        script:Set-Statusline $script:env $script:Shapes['a blank line after the assignment'] | Out-Null
        (script:Invoke-Installer $script:env -Action triage).Report.verdict | Should Be 'supported'

        script:Set-Settings $script:env 'bash /home/me/statusline.sh'
        (script:Invoke-Installer $script:env -Action triage).Report.verdict | Should Be 'refuse'
    }

    It 'shows the exact text it would insert, and writes nothing while doing so' {
        $script:env = script:New-Env
        $sl = script:Set-Statusline $script:env $script:Shapes['a blank line after the assignment']
        $before = script:Get-Text $sl
        $r = script:Invoke-Installer $script:env -Action triage
        $r.Report.block | Should Match 'Write-UsageState -StatusJson \$d'
        script:Get-Text $sl | Should BeExactly $before
    }

    It 'finds a statusline declared somewhere unexpected, not by convention' {
        $script:env = script:New-Env
        $odd = Join-Path $script:env.Home 'tools\my status line.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $odd) -Force | Out-Null
        [System.IO.File]::WriteAllText($odd, $script:Shapes['a blank line after the assignment'], [System.Text.UTF8Encoding]::new($false))
        script:Set-Settings $script:env ('powershell.exe -NoProfile -File "' + $odd + '"')

        $r = script:Invoke-Installer $script:env
        $r.ExitCode | Should Be 0
        (script:Get-Text $odd) | Should Match 'oriel tee'
    }

    It 'resolves a ~-relative declaration against the home directory it was given' {
        $script:env = script:New-Env
        $sl = Join-Path $script:env.Claude 'statusline.ps1'
        [System.IO.File]::WriteAllText($sl, $script:Shapes['a blank line after the assignment'], [System.Text.UTF8Encoding]::new($false))
        script:Set-Settings $script:env 'pwsh -NoProfile -File "~/.claude/statusline.ps1"'

        $r = script:Invoke-Installer $script:env -Action triage
        $r.Report.verdict | Should Be 'supported'
        $r.Report.statuslinePath | Should Be $sl
    }
}

Describe 'Install-Oriel: refusal is loud and changes nothing' {

    AfterEach { script:Remove-Env $script:env }

    # The three ways a statusline can be one Oriel declines to touch.
    $script:Refusals = [ordered]@{
        'a non-PowerShell interpreter' = @{
            Command = 'node C:\Users\me\.claude\statusline.js'
            Reason  = 'not-powershell'
        }
        'a declared command pointing at nothing' = @{
            Command = 'pwsh -NoProfile -File "C:\nowhere\statusline.ps1"'
            Reason  = 'missing-file'
        }
    }

    foreach ($case in $script:Refusals.Keys) {
        $spec = $script:Refusals[$case]

        It "refuses $case, names the reason, and leaves the disk alone" {
            $script:env = script:New-Env
            script:Set-Settings $script:env $spec.Command
            $settingsBefore = script:Get-Text $script:env.Settings

            $r = script:Invoke-Installer $script:env
            $r.ExitCode | Should Be 2
            $r.Report.verdict | Should Be 'refuse'
            $r.Report.reason | Should Be $spec.Reason
            script:Get-Text $script:env.Settings | Should BeExactly $settingsBefore
            # No statusline written, no state directory, no install record.
            (Test-Path -LiteralPath (Join-Path $script:env.Claude 'statusline.ps1')) | Should Be $false
            (Test-Path -LiteralPath $script:env.State) | Should Be $false
        }
    }

    It 'refuses PowerShell that never keeps the JSON, and leaves the file untouched' {
        $script:env = script:New-Env
        $body = "`$input | ConvertFrom-Json | ForEach-Object { Write-Host `$_.model.display_name }`r`n"
        $sl = script:Set-Statusline $script:env $body

        $r = script:Invoke-Installer $script:env
        $r.ExitCode | Should Be 2
        $r.Report.reason | Should Be 'no-json-assignment'
        script:Get-Text $sl | Should BeExactly $body
    }

    It 'hands the user text to paste into Claude Code' {
        $script:env = script:New-Env
        script:Set-Settings $script:env 'bash ~/.claude/statusline.sh'
        $r = script:Invoke-Installer $script:env
        $r.Report.conversionPrompt | Should Match 'ConvertFrom-Json'
        $r.Report.conversionPrompt | Should Match 'Claude Code settings'
    }

    It 'installs on the next run once the statusline has been converted' {
        $script:env = script:New-Env
        $sl = script:Set-Statusline $script:env "`$raw | ConvertFrom-Json | Out-Host`r`n"
        (script:Invoke-Installer $script:env).ExitCode | Should Be 2

        # The user converts it. No other step.
        [System.IO.File]::WriteAllText($sl, $script:Shapes['a blank line after the assignment'], [System.Text.UTF8Encoding]::new($false))
        (script:Invoke-Installer $script:env).ExitCode | Should Be 0
        script:Get-Text $sl | Should Match 'oriel tee'
    }
}

Describe 'Install-Oriel: the anchor traces back to standard input' {
    # The field report behind all of this (oriel#1): the installer anchored on the FIRST
    # ConvertFrom-Json in the file, which on a real machine was a helper parsing
    # settings.json. The block was inserted after it, borrowed a variable holding
    # settings rather than the payload, and wrote nothing, every render, silently.

    AfterEach { script:Remove-Env $script:env }

    # The reported statusline, reduced to what mattered: a helper that parses settings
    # files, an early return above the real parse, and the payload arriving further down.
    $script:Decoy = @"
function Read-Effort {
    foreach (`$p in @('settings.local.json', 'settings.json')) {
        `$j = Get-Content -LiteralPath `$p -Raw -Encoding UTF8 | ConvertFrom-Json
        if (`$j.effort) { return `$j.effort.level }
    }
    return `$null
}
`$raw = [Console]::In.ReadToEnd()
`$d = `$raw | ConvertFrom-Json
Write-Host 'hi'
"@

    It 'walks past a ConvertFrom-Json that parses JSON from somewhere else' {
        $script:env = script:New-Env
        $sl = script:Set-Statusline $script:env $script:Decoy
        $r = script:Invoke-Installer $script:env
        $r.ExitCode | Should Be 0

        $lines = (script:Get-Text $sl) -split "`r?`n"
        $blockAt = [array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -like '*oriel tee (managed block*' })
        # Directly after the line that parses what came in on standard input — not after
        # the settings parse, which is where the old heuristic put it.
        $lines[$blockAt - 1] | Should Match '\$d = \$raw \| ConvertFrom-Json'
        $lines[$blockAt + 1] | Should Match 'Write-UsageState -StatusJson \$d\b'
    }

    It 'is not fooled by the argument form of the same decoy' {
        # The reporter renamed the decoy variable and switched it off the pipe form to
        # try to steer the old matcher. It patched the same wrong place a second time.
        $script:env = script:New-Env
        $body = "`$cfg = ConvertFrom-Json (Get-Content -Raw 'settings.json')`r`n" +
                "`$raw = [Console]::In.ReadToEnd()`r`n" +
                "`$d = `$raw | ConvertFrom-Json`r`nWrite-Host 'hi'`r`n"
        $sl = script:Set-Statusline $script:env $body
        script:Invoke-Installer $script:env | Out-Null

        $lines = (script:Get-Text $sl) -split "`r?`n"
        $blockAt = [array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -like '*oriel tee (managed block*' })
        $lines[$blockAt - 1] | Should Match '\$d = \$raw \| ConvertFrom-Json'
        # And the decoy line still has what followed it, untouched.
        $lines[1] | Should Match 'ReadToEnd'
    }

    It 'refuses rather than guessing when nothing in the file reads standard input' {
        # "If no unambiguous anchor is found, fail loudly and ask rather than patching a
        # guess." A refusal a user can act on beats a silent no-op they cannot see.
        $script:env = script:New-Env
        $body = "`$cfg = Get-Content -Raw 'settings.json' | ConvertFrom-Json`r`nWrite-Host `$cfg.name`r`n"
        $sl = script:Set-Statusline $script:env $body

        $r = script:Invoke-Installer $script:env
        $r.ExitCode | Should Be 2
        $r.Report.verdict | Should Be 'refuse'
        $r.Report.reason | Should Be 'no-stdin-source'
        $r.Report.message | Should Match 'standard input'
        $r.Report.conversionPrompt | Should Match 'ReadToEnd'
        script:Get-Text $sl | Should BeExactly $body
    }

    It 'still tells apart a statusline that reads the payload and throws it away' {
        $script:env = script:New-Env
        $sl = script:Set-Statusline $script:env "`$input | ConvertFrom-Json | Out-Host`r`n"
        (script:Invoke-Installer $script:env).Report.reason | Should Be 'no-json-assignment'
    }
}

Describe 'Install-Oriel: the block changes nothing the user can see' {
    # The second half of oriel#1, and the more damaging one: the tee set
    # Set-StrictMode -Version Latest at file scope, the block dot-sourced it into the
    # host statusline's scope, and from that line down every read of an absent key threw.
    # It only reproduced when rate_limits was ABSENT — Free accounts, and every session
    # before its first reply — so a complete probe payload passed and proved nothing.

    AfterEach { script:Remove-Env $script:env }

    # Ordinary, correct PowerShell against an optional-key payload, under the settings a
    # careful statusline author would use.
    $script:OptionalKeys = @'
$ErrorActionPreference = 'Stop'
$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.UTF8Encoding]::new($false))
$raw = $reader.ReadToEnd()
try { $d = $raw | ConvertFrom-Json } catch { $d = $null }
try {
    $ctx = $d.context_window
    $pct = 0
    if ($null -ne $ctx) { $pct = $ctx.used_percentage }
    $where = ''
    if ($null -ne $d.workspace) { $where = $d.workspace.current_dir }
    Write-Host ("ok " + $pct + " " + $where)
} catch {
    Write-Host '?'
}
'@

    It 'leaves a statusline that reads optional keys rendering exactly as before' {
        $script:env = script:New-Env
        script:Set-Statusline $script:env $script:OptionalKeys | Out-Null
        $r = script:Invoke-Installer $script:env -Verify
        # Before the fix this failed twice over: the strict mode leaked in, the sparse
        # render printed '?' instead of its normal line, and the install rolled back.
        $r.ExitCode | Should Be 0
        $r.Report.verified | Should Be $true
        $r.Report.verdict | Should Not Be 'rolled-back'
    }

    It 'leaks nothing into the host scope, not even its own functions' {
        # The structural half of the fix: the block dot-sources inside `& { }`, so
        # nothing it defines or sets survives the line. Asked of the scope itself rather
        # than of one symptom, because the next leak will not be StrictMode.
        $script:env = script:New-Env
        $body = @'
$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.UTF8Encoding]::new($false))
$raw = $reader.ReadToEnd()
try { $d = $raw | ConvertFrom-Json } catch { $d = $null }
$leaked = @()
if (Get-Command Write-UsageState -ErrorAction SilentlyContinue) { $leaked += 'Write-UsageState' }
if (Get-Command ConvertTo-UsageRecord -ErrorAction SilentlyContinue) { $leaked += 'ConvertTo-UsageRecord' }
if (Get-Command Write-JsonAtomic -ErrorAction SilentlyContinue) { $leaked += 'Write-JsonAtomic' }
if ($leaked.Count -gt 0) { Write-Host ('leaked: ' + ($leaked -join ',')) } else { Write-Host 'clean' }
'@
        script:Set-Statusline $script:env $body | Out-Null
        $r = script:Invoke-Installer $script:env -Verify
        $r.ExitCode | Should Be 0
        $r.Report.verified | Should Be $true
    }

    It 'takes the block back out when the patch changes what the statusline prints' {
        # A fixture that is deliberately sensitive to its own file: three more lines in
        # it and it says something different. That is a real change to what the user
        # sees, so the install must not stand — the widget is worth less than the bar
        # they look at all day (ADR 0011).
        $script:env = script:New-Env
        $body = @'
$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.UTF8Encoding]::new($false))
$raw = $reader.ReadToEnd()
try { $d = $raw | ConvertFrom-Json } catch { $d = $null }
Write-Host ("lines: " + (Get-Content -LiteralPath $PSCommandPath).Count)
'@
        $sl = script:Set-Statusline $script:env $body

        $r = script:Invoke-Installer $script:env -Verify
        $r.ExitCode | Should Be 3
        $r.Report.verified | Should Be $false
        $r.Report.verdict | Should Be 'rolled-back'
        $r.Report.message | Should Match 'took the patch back out'
        # The file is theirs again, byte for byte, and nothing is left lying beside it.
        script:Get-Text $sl | Should BeExactly $body
        (Test-Path -LiteralPath "$sl.bak") | Should Be $false
    }

    It 'installs anyway when the statusline is not comparable to itself' {
        # A clock, a spinner, a git revision: output that differs between two identical
        # renders cannot be held to a byte-for-byte rule, and a false alarm that blocks
        # an install costs more than a missed one. The check stands down; the install
        # goes through on the strength of the data-flow check alone.
        $script:env = script:New-Env
        $body = @'
$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.UTF8Encoding]::new($false))
$raw = $reader.ReadToEnd()
try { $d = $raw | ConvertFrom-Json } catch { $d = $null }
Write-Host ([guid]::NewGuid().ToString())
'@
        script:Set-Statusline $script:env $body | Out-Null
        $r = script:Invoke-Installer $script:env -Verify
        $r.ExitCode | Should Be 0
        $r.Report.verified | Should Be $true
    }
}

Describe 'Install-Oriel: the starter statusline' {

    AfterEach { script:Remove-Env $script:env }

    It 'writes one for a user with none, declares it, and patches it' {
        $script:env = script:New-Env
        script:Set-Settings $script:env $null

        $r = script:Invoke-Installer $script:env
        $r.ExitCode | Should Be 0
        $r.Report.starterWritten | Should Be $true

        $starter = Join-Path $script:env.Claude 'statusline.ps1'
        (Test-Path -LiteralPath $starter) | Should Be $true
        $text = script:Get-Text $starter
        $text | Should Match 'oriel tee'
        $text | Should Match '\(ctx\)'

        $settings = Get-Content -Raw $script:env.Settings | ConvertFrom-Json
        $settings.statusLine.command | Should Match ([regex]::Escape($starter))
    }

    It 'carries a UTF-8 BOM onto the user disk' {
        $script:env = script:New-Env
        script:Set-Settings $script:env $null
        script:Invoke-Installer $script:env | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:env.Claude 'statusline.ps1'))
        @($bytes[0], $bytes[1], $bytes[2]) -join ',' | Should Be '239,187,191'
    }

    It 'declares pwsh when the machine has it' {
        $script:env = script:New-Env
        script:Set-Settings $script:env $null
        script:Invoke-Installer $script:env -Interpreters @('pwsh', 'powershell.exe') | Out-Null
        (Get-Content -Raw $script:env.Settings | ConvertFrom-Json).statusLine.command | Should Match '^pwsh '
    }

    It 'declares powershell.exe when that is all there is' {
        $script:env = script:New-Env
        script:Set-Settings $script:env $null
        script:Invoke-Installer $script:env -Interpreters @('powershell.exe') | Out-Null
        (Get-Content -Raw $script:env.Settings | ConvertFrom-Json).statusLine.command | Should Match '^powershell.exe '
    }

    It 'does not overwrite a file already sitting at the conventional name' {
        $script:env = script:New-Env
        $squatter = Join-Path $script:env.Claude 'statusline.ps1'
        [System.IO.File]::WriteAllText($squatter, "# not mine`r`n", [System.Text.UTF8Encoding]::new($false))
        script:Set-Settings $script:env $null

        script:Invoke-Installer $script:env | Out-Null
        script:Get-Text $squatter | Should BeExactly "# not mine`r`n"
        (Test-Path -LiteralPath (Join-Path $script:env.Claude 'oriel-statusline.ps1')) | Should Be $true
    }

    It 'leaves the settings exactly as they were apart from statusLine' {
        $script:env = script:New-Env
        script:Set-Settings $script:env $null -Extra ([ordered]@{ model = 'opus'; theme = 'dark' })
        script:Invoke-Installer $script:env | Out-Null
        $settings = Get-Content -Raw $script:env.Settings | ConvertFrom-Json
        $settings.model | Should Be 'opus'
        $settings.theme | Should Be 'dark'
    }

    It 'discards it on uninstall and hands the settings back' {
        $script:env = script:New-Env
        script:Set-Settings $script:env $null -Extra ([ordered]@{ model = 'opus' })
        script:Invoke-Installer $script:env | Out-Null
        script:Invoke-Installer $script:env -Action uninstall | Out-Null

        (Test-Path -LiteralPath (Join-Path $script:env.Claude 'statusline.ps1')) | Should Be $false
        $settings = Get-Content -Raw $script:env.Settings | ConvertFrom-Json
        $settings.PSObject.Properties['statusLine'] | Should Be $null
        $settings.model | Should Be 'opus'
    }

    It 'keeps it on request, working, with the block gone' {
        $script:env = script:New-Env
        script:Set-Settings $script:env $null
        script:Invoke-Installer $script:env | Out-Null
        script:Invoke-Installer $script:env -Action uninstall -KeepStarter | Out-Null

        $starter = Join-Path $script:env.Claude 'statusline.ps1'
        (Test-Path -LiteralPath $starter) | Should Be $true
        $text = script:Get-Text $starter
        # The marker, not the phrase: the file's own header comment explains what the
        # managed block is, and that sentence is not the block.
        $text | Should Not Match '>>> oriel tee'
        # Still a statusline: the parts that make it worth having survived.
        $text | Should Match '\(ctx\)'
        $text | Should Match 'ConvertFrom-Json'
        # And it still parses.
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should Be 0
    }
}

Describe 'Install-Oriel: uninstall' {

    AfterEach { script:Remove-Env $script:env }

    It 'does not restore the file from the backup, so later edits survive' {
        $script:env = script:New-Env
        $sl = script:Set-Statusline $script:env $script:Shapes['a blank line after the assignment']
        script:Invoke-Installer $script:env | Out-Null

        # Months pass; the user edits their own statusline around our block.
        $edited = (script:Get-Text $sl) + "Write-Host 'mine'`r`n"
        [System.IO.File]::WriteAllText($sl, $edited, [System.Text.UTF8Encoding]::new($false))

        script:Invoke-Installer $script:env -Action uninstall | Out-Null
        $after = script:Get-Text $sl
        $after | Should Match "Write-Host 'mine'"
        $after | Should Not Match 'oriel tee'
    }

    It 'leaves a statusline it never patched completely alone' {
        $script:env = script:New-Env
        $body = $script:Shapes['a blank line after the assignment']
        $sl = script:Set-Statusline $script:env $body
        script:Invoke-Installer $script:env -Action uninstall | Out-Null
        script:Get-Text $sl | Should BeExactly $body
    }

    It 'backs the original up once and never clobbers the backup' {
        $script:env = script:New-Env
        $body = $script:Shapes['a blank line after the assignment']
        $sl = script:Set-Statusline $script:env $body
        script:Invoke-Installer $script:env | Out-Null
        script:Get-Text "$sl.bak" | Should BeExactly $body
        script:Invoke-Installer $script:env | Out-Null
        script:Get-Text "$sl.bak" | Should BeExactly $body
    }
}

Describe 'Install-Oriel: migration from the pre-rename install' {

    AfterEach { script:Remove-Env $script:env }

    It 'moves the old state directory and the preferences in it' {
        $script:env = script:New-Env
        $legacy = Join-Path $script:env.Claude 'usage-widget'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $legacy 'config.json'), '{"skin":"inline","tint":90}')
        script:Set-Statusline $script:env $script:Shapes['a blank line after the assignment'] | Out-Null

        script:Invoke-Installer $script:env | Out-Null

        (Test-Path -LiteralPath $legacy) | Should Be $false
        $cfg = Get-Content -Raw (Join-Path $script:env.State 'config.json') | ConvertFrom-Json
        $cfg.skin | Should Be 'inline'
        $cfg.tint | Should Be 90
    }

    It 'replaces old markers with new ones, and the result uninstalls cleanly' {
        $script:env = script:New-Env
        $body = $script:Shapes['a blank line after the assignment']
        # The old patcher's EOF shape, exactly: a newline BEFORE the block as well as
        # after it. Getting that wrong makes the fixture a file no user ever had, and
        # the assertion stops meaning anything about real machines.
        $old = $body + "`r`n" +
               "# >>> claude-usage-widget tee (managed block — safe to remove) >>>`r`n" +
               "try { . 'C:\old\Write-UsageState.ps1'; Write-UsageState -StatusJson `$d | Out-Null } catch { }`r`n" +
               "# <<< claude-usage-widget tee <<<`r`n"
        $sl = script:Set-Statusline $script:env $old

        script:Invoke-Installer $script:env | Out-Null
        $patched = script:Get-Text $sl
        $patched | Should Not Match 'claude-usage-widget'
        ([regex]::Matches($patched, 'oriel tee \(managed block')).Count | Should Be 1

        script:Invoke-Installer $script:env -Action uninstall | Out-Null
        script:Get-Text $sl | Should BeExactly $body
    }

    It 'carries older preferences across when the new directory holds only newer ones' {
        # The author's own machine: a post-rename build found no state directory and
        # created a fresh one with defaults, leaving the real preferences behind.
        $script:env = script:New-Env
        $legacy = Join-Path $script:env.Claude 'usage-widget'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        New-Item -ItemType Directory -Path $script:env.State -Force | Out-Null

        # config.json exists in both; the legacy one is the newer of the two.
        [System.IO.File]::WriteAllText((Join-Path $script:env.State 'config.json'), '{"tint":75}')
        [System.IO.File]::WriteAllText((Join-Path $legacy 'config.json'), '{"tint":60}')
        (Get-Item (Join-Path $legacy 'config.json')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(1)
        # current.json exists only in the legacy directory.
        [System.IO.File]::WriteAllText((Join-Path $legacy 'current.json'), '{"old":true}')

        script:Set-Statusline $script:env $script:Shapes['a blank line after the assignment'] | Out-Null
        script:Invoke-Installer $script:env | Out-Null

        (Get-Content -Raw (Join-Path $script:env.State 'config.json') | ConvertFrom-Json).tint | Should Be 60
        (Test-Path -LiteralPath (Join-Path $script:env.State 'current.json')) | Should Be $true
        (Test-Path -LiteralPath $legacy) | Should Be $false
    }

    It 'keeps preferences set since the rename, and does not throw the old ones away' {
        $script:env = script:New-Env
        $legacy = Join-Path $script:env.Claude 'usage-widget'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        New-Item -ItemType Directory -Path $script:env.State -Force | Out-Null

        [System.IO.File]::WriteAllText((Join-Path $legacy 'config.json'), '{"tint":60}')
        (Get-Item (Join-Path $legacy 'config.json')).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-1)
        [System.IO.File]::WriteAllText((Join-Path $script:env.State 'config.json'), '{"tint":90}')

        script:Set-Statusline $script:env $script:Shapes['a blank line after the assignment'] | Out-Null
        script:Invoke-Installer $script:env | Out-Null

        (Get-Content -Raw (Join-Path $script:env.State 'config.json') | ConvertFrom-Json).tint | Should Be 90
        # The loser is left where it is rather than deleted.
        (Test-Path -LiteralPath (Join-Path $legacy 'config.json')) | Should Be $true
    }

    It 'removes a legacy block byte-for-byte, including the blank line it left behind' {
        # The retired patcher anchored before an emit comment and inserted the block
        # followed by TWO newlines. Stripping one leaves a blank line the user never
        # had — on every pre-rename machine, surviving uninstall. The fixture is built
        # the way the old patcher actually built it, not the way the new one does.
        $script:env = script:New-Env
        $body = "`$raw = 'x'`r`n`$d = `$raw | ConvertFrom-Json`r`n`r`n# --- Emit`r`nWrite-Host 'hi'`r`n"
        $legacyBlock = "# >>> claude-usage-widget tee (managed block — safe to remove) >>>`r`n" +
                       "try { . 'C:\old\Write-UsageState.ps1'; Write-UsageState -StatusJson `$d | Out-Null } catch { }`r`n" +
                       "# <<< claude-usage-widget tee <<<"
        $at = $body.IndexOf('# --- Emit')
        $preRename = $body.Insert($at, $legacyBlock + "`r`n`r`n")
        $sl = script:Set-Statusline $script:env $preRename

        script:Invoke-Installer $script:env | Out-Null
        script:Invoke-Installer $script:env -Action uninstall | Out-Null

        # Back to the file as it was before the old patcher ever touched it.
        script:Get-Text $sl | Should BeExactly $body
    }

    It 'does not migrate anything when triage refuses' {
        # "A refusal changes nothing at all" has to include the migration — otherwise
        # the message is a lie on exactly the machines it matters most for.
        $script:env = script:New-Env
        $legacy = Join-Path $script:env.Claude 'usage-widget'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $legacy 'config.json'), '{"tint":60}')
        script:Set-Settings $script:env 'bash ~/.claude/statusline.sh'

        $r = script:Invoke-Installer $script:env
        $r.ExitCode | Should Be 2
        (Test-Path -LiteralPath (Join-Path $legacy 'config.json')) | Should Be $true
        (Test-Path -LiteralPath $script:env.State) | Should Be $false
        @($r.Report.migrated).Count | Should Be 0
    }

    It 'does nothing on a machine that never had the old install' {
        $script:env = script:New-Env
        script:Set-Statusline $script:env $script:Shapes['a blank line after the assignment'] | Out-Null
        $r = script:Invoke-Installer $script:env
        @($r.Report.migrated).Count | Should Be 0
    }

    It 'does nothing on the second run' {
        $script:env = script:New-Env
        $legacy = Join-Path $script:env.Claude 'usage-widget'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $legacy 'config.json'), '{"skin":"inline"}')
        script:Set-Statusline $script:env $script:Shapes['a blank line after the assignment'] | Out-Null

        @((script:Invoke-Installer $script:env).Report.migrated).Count | Should BeGreaterThan 0
        @((script:Invoke-Installer $script:env).Report.migrated).Count | Should Be 0
    }
}

Describe 'Install-Oriel: nothing reports success until data flows' {

    AfterEach { script:Remove-Env $script:env }

    # A real, runnable statusline — the verification tests need one, because
    # verification runs the declared command for real.
    $script:Runnable = @'
$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.UTF8Encoding]::new($false))
$raw = $reader.ReadToEnd()
try { $d = $raw | ConvertFrom-Json } catch { $d = $null }
Write-Host "ok"
'@

    It 'reports success only after the state file has appeared' {
        $script:env = script:New-Env
        script:Set-Statusline $script:env $script:Runnable | Out-Null
        $r = script:Invoke-Installer $script:env -Verify
        $r.ExitCode | Should Be 0
        $r.Report.verified | Should Be $true
    }

    It 'verifies the starter statusline the same way' {
        $script:env = script:New-Env
        script:Set-Settings $script:env $null
        $r = script:Invoke-Installer $script:env -Verify
        $r.ExitCode | Should Be 0
        $r.Report.verified | Should Be $true
    }

    It 'reports a diagnosis, not success, when the patch produces no state file' {
        $script:env = script:New-Env
        # Keeps the JSON — so it is supported and gets patched — but exits before the
        # block can run. Exactly the silent failure the try/catch would otherwise hide.
        $body = @'
$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.UTF8Encoding]::new($false))
$raw = $reader.ReadToEnd()
exit 0
$d = $raw | ConvertFrom-Json
'@
        script:Set-Statusline $script:env $body | Out-Null
        $r = script:Invoke-Installer $script:env -Verify
        $r.ExitCode | Should Be 3
        $r.Report.verified | Should Be $false
        $r.Report.message | Should Match 'could not observe'
        $r.Report.message | Should Match 'uninstall'
    }

    It 'leaves the real state file alone while verifying' {
        $script:env = script:New-Env
        New-Item -ItemType Directory -Path $script:env.State -Force | Out-Null
        $real = Join-Path $script:env.State 'current.json'
        [System.IO.File]::WriteAllText($real, '{"mine":true}')
        script:Set-Statusline $script:env $script:Runnable | Out-Null

        script:Invoke-Installer $script:env -Verify | Out-Null
        script:Get-Text $real | Should BeExactly '{"mine":true}'
    }
}
