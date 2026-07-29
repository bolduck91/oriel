<#
.SYNOPSIS
Oriel's installer: the one place that reads or writes a user's configuration.

.DESCRIPTION
Triage, block insertion, the starter statusline, verification, migration and
uninstall all live here (tickets 02-07). The Inno Setup wizard and the one-line
terminal install are two front ends over this file — there is one implementation of
the risky half, not two that will drift (ADR 0012).

It takes its environment as input rather than reaching for the real one: which
settings file to read, which directory is the user's home, which interpreters exist.
That is what makes the whole feature testable without a machine to install onto, and
it follows the injectable-probe pattern the build already uses to decide whether the
widget is running.

The judgement — classification, anchoring, the exact bytes of an insertion — lives in
Statusline.ps1, which is pure and writes nothing. This file is the side effects.

Windows PowerShell 5.1 is the floor (ADR 0013).

.PARAMETER Action
  install    triage, patch (or write a starter statusline), verify, report
  uninstall  remove the managed block and, optionally, the starter statusline
  triage     report what would happen and show the exact block — writes nothing

.PARAMETER HomeDir
The directory to treat as the user's home. Everything else is derived from it.

.PARAMETER SettingsPath
Claude Code's settings file. Defaults to <HomeDir>/.claude/settings.json.

.PARAMETER TeePath
The Write-UsageState.ps1 the managed block will dot-source. Defaults to the tee
shipped beside this script.

.PARAMETER Interpreters
The PowerShell interpreters available on this machine, best first. Supplied so tests
need no particular machine; probed when omitted.

.PARAMETER KeepStarter
Uninstall only: keep the starter statusline Oriel wrote, with the block removed,
rather than deleting it and handing the settings back.

.PARAMETER Json
Emit a single JSON object instead of prose, for a front end to parse.

.EXAMPLE
  powershell.exe -NoProfile -File Install-Oriel.ps1 -Action install
.EXAMPLE
  powershell.exe -NoProfile -File Install-Oriel.ps1 -Action triage -Json
#>
[CmdletBinding()]
param(
    [ValidateSet('install', 'uninstall', 'triage')] [string] $Action = 'install',
    [string] $HomeDir,
    [string] $SettingsPath,
    [string] $TeePath,
    [string[]] $Interpreters,
    [switch] $KeepStarter,
    [switch] $SkipVerify,
    [int] $VerifyTimeoutSeconds = 20,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Statusline.ps1')

# Exit codes, so a front end can tell the three outcomes apart without reading prose.
# A refusal is NOT a failure of the installer — it is the installer working — but it
# must never be surfaced as a green checkmark either (ADR 0012), hence its own code.
$script:ExitOk        = 0
$script:ExitError     = 1
$script:ExitRefused   = 2
$script:ExitUnverified = 3

# ---- environment -----------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($HomeDir)) { $HomeDir = $HOME }
$HomeDir = [System.IO.Path]::GetFullPath($HomeDir)

# "Is this the machine we are actually installing onto?" Everything else is injectable
# — the settings file, the home directory, the interpreters — but the per-user Run key
# has no injectable equivalent and is shared by the whole logon session. This is what
# keeps it out of reach of a test that substituted its environment.
$script:IsRealEnvironment = ($HomeDir -eq [System.IO.Path]::GetFullPath($HOME))

$claudeDir = Join-Path $HomeDir '.claude'
if ([string]::IsNullOrWhiteSpace($SettingsPath)) { $SettingsPath = Join-Path $claudeDir 'settings.json' }
$stateDir  = Join-Path $claudeDir 'oriel'
$recordPath = Join-Path $stateDir 'install.json'

if ([string]::IsNullOrWhiteSpace($TeePath)) { $TeePath = Join-Path $PSScriptRoot '..\tee\Write-UsageState.ps1' }
if (Test-Path -LiteralPath $TeePath) { $TeePath = (Resolve-Path -LiteralPath $TeePath).Path }

$starterSource = Join-Path $PSScriptRoot 'starter-statusline.ps1'

# A front end driving this with `-File` can only pass strings, and a string[] bound
# that way arrives as one element however many names are in it. Splitting on commas
# here means "pwsh,powershell.exe" and @('pwsh','powershell.exe') mean the same thing.
if ($null -ne $Interpreters -and $Interpreters.Count -gt 0) {
    $split = @()
    foreach ($i in $Interpreters) { foreach ($part in ($i -split ',')) { if ($part.Trim()) { $split += $part.Trim() } } }
    $Interpreters = $split
}

# The interpreter probe, injectable for the same reason the paths are: a test must be
# able to say "this machine has only powershell.exe" without having such a machine.
if ($null -eq $Interpreters -or $Interpreters.Count -eq 0) {
    $Interpreters = @()
    foreach ($candidate in @('pwsh', 'powershell.exe')) {
        $found = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($found) { $Interpreters += $candidate }
    }
    if ($Interpreters.Count -eq 0) { $Interpreters = @('powershell.exe') }
}

# ---- small file helpers ----------------------------------------------------

# UTF-8 with a BOM, always. 5.1 reads a BOM-less .ps1 as ANSI, and the starter
# statusline's glyphs then do not merely render wrong — the file fails to parse
# (ADR 0013). Set-Content's -Encoding utf8 does not mean the same thing on 5.1 and 7,
# which is precisely why this goes through .NET instead.
$script:Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function script:Read-TextOrNull {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    [System.IO.File]::ReadAllText($Path)
}

# Someone else's statusline is rewritten with whatever encoding it already had: a
# file that arrived without a BOM leaves without one, so "unchanged apart from the
# inserted block" is true of the bytes at the front of the file too.
function script:Write-TextPreservingEncoding {
    param([string] $Path, [string] $Text, [bool] $HadBom)
    $encoding = $script:Utf8NoBom
    if ($HadBom) { $encoding = $script:Utf8Bom }
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function script:Test-HasBom {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function script:Read-JsonOrNull {
    param([string] $Path)
    $raw = script:Read-TextOrNull $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function script:Write-Json {
    param([string] $Path, $Object)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Temp-then-move, the same contract the tee's atomic write keeps: a crash mid-write
    # must never leave a half-written settings file behind.
    $tmp = $Path + '.oriel.tmp'
    [System.IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 20), $script:Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ---- reporting -------------------------------------------------------------

$script:Report = [ordered]@{
    action   = $Action
    verdict  = $null
    reason   = $null
    message  = $null
    statuslinePath = $null
    block    = $null
    conversionPrompt = $null
    starterWritten = $false
    verified = $false
    migrated = @()
    changed  = @()
}

function script:Say {
    param([string] $Text, [string] $Color = 'Gray')
    if (-not $Json) { Write-Host $Text -ForegroundColor $Color }
}

function script:Complete {
    param([int] $Code)
    if ($Json) { Write-Output ([pscustomobject]$script:Report | ConvertTo-Json -Depth 10) }
    exit $Code
}

# ---- migration (ticket 07) -------------------------------------------------

# What a pre-rename install left on disk. Disposable code with a real subject: the
# author's own machine, which the rename deliberately left broken.
$script:LegacyStateDir = Join-Path $claudeDir 'usage-widget'
$script:LegacyRunValue = 'ClaudeUsageWidget'

function script:Invoke-Migration {
    <#
    .SYNOPSIS
        Carry a pre-rename install across, once, silently, doing nothing at all on a
        machine that never had one or has already been migrated.
    #>
    $done = @()

    # 1. The state directory, and with it the accumulated preferences — skin, tint,
    #    blur, accent. Moved rather than copied, so a second run finds nothing.
    if (Test-Path -LiteralPath $script:LegacyStateDir) {
        try {
            if (-not (Test-Path -LiteralPath $stateDir)) {
                Move-Item -LiteralPath $script:LegacyStateDir -Destination $stateDir -Force
                $done += "moved $script:LegacyStateDir to $stateDir (preferences and last-known usage came with it)"
            }
            else {
                $done += script:Merge-LegacyState
            }
        } catch {
            script:Say "Could not migrate the old state directory: $($_.Exception.Message)" 'Yellow'
        }
    }

    # 2. The Run-key value name moved with the rename, so an old registration is
    #    invisible to the widget's own on/off — it would survive forever and keep
    #    starting an executable that no longer exists.
    $removed = script:Remove-LegacyRunKey
    if ($removed) { $done += "removed the old '$script:LegacyRunValue' Start-with-Windows entry" }

    # 3. Old markers in the statusline are replaced by new ones as an ordinary
    #    consequence of installing: Remove-OrielBlock strips both spellings, and the
    #    insertion that follows writes the current one. Nothing to do here.
    $script:Report.migrated = $done
    foreach ($d in $done) { script:Say "Migrated: $d" 'Cyan' }
}

function script:Merge-LegacyState {
    <#
    .SYNOPSIS
        Both directories exist. Resolve them file by file, newest wins.
    .DESCRIPTION
        This case is not hypothetical — it is the author's own machine, and any machine
        that ran a post-rename build before this installer existed. The widget found no
        state directory, created a fresh one with default preferences, and the real
        preferences stayed behind in the old one.

        Neither "the old one wins" nor "the new one wins" is right on its own: the first
        would throw away preferences set since the rename, the second throws away every
        preference set before it. The file's own timestamp distinguishes the two cases
        exactly, and last-write-wins is the contract the tee already keeps.

        Files that lose are left where they are rather than deleted — nothing here is
        worth being clever about, and a path in a message is cheaper than a mistake.
    #>
    $moved = @()
    $left = 0

    foreach ($old in (Get-ChildItem -LiteralPath $script:LegacyStateDir -File)) {
        $new = Join-Path $stateDir $old.Name
        $takeIt = $true
        if (Test-Path -LiteralPath $new) {
            $takeIt = $old.LastWriteTimeUtc -gt (Get-Item -LiteralPath $new).LastWriteTimeUtc
        }
        if ($takeIt) {
            Move-Item -LiteralPath $old.FullName -Destination $new -Force
            $moved += $old.Name
        }
        else { $left++ }
    }

    $report = @()
    if ($moved.Count -gt 0) {
        $report += ("carried " + ($moved -join ', ') + " across from $script:LegacyStateDir (newer than what was here)")
    }
    if ($left -eq 0) {
        Remove-Item -LiteralPath $script:LegacyStateDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($moved.Count -eq 0) { $report += "removed the empty $script:LegacyStateDir" }
    }
    else {
        script:Say "Your current preferences are newer, so they were kept. Older copies from before the rename are still in $script:LegacyStateDir if you want anything back." 'Gray'
        $report += "kept $left newer file(s) already in $stateDir; older copies remain in $script:LegacyStateDir"
    }
    return $report
}

function script:Remove-LegacyRunKey {
    # Registry only exists on Windows, and only the current user's hive is ever
    # touched — the whole install is per-user and never elevates.
    if (-not ($env:OS -eq 'Windows_NT')) { return $false }

    # The registry is the one thing here with no injectable equivalent: there is no
    # "-RunKeyPath" that would make this testable, and HKCU is shared by every process
    # on the machine. So it is bound to the same seam everything else is — a caller who
    # substituted the home directory is by definition not describing this machine, and
    # must not have its Run key edited as a side effect of a test (ticket 02: "touches
    # nothing outside them when they are supplied").
    if (-not $script:IsRealEnvironment) { return $false }
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    try {
        if (-not (Test-Path -LiteralPath $key)) { return $false }
        $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($null -eq $props -or $null -eq $props.PSObject.Properties[$script:LegacyRunValue]) { return $false }
        Remove-ItemProperty -LiteralPath $key -Name $script:LegacyRunValue -ErrorAction Stop
        return $true
    } catch { return $false }
}

# ---- the starter statusline (ticket 05) ------------------------------------

function script:Install-StarterStatusline {
    <#
    .SYNOPSIS
        Write a real statusline for someone who has none, and declare it.
    .DESCRIPTION
        Not a third mechanism: it produces an ordinary **supported statusline** that
        the user then owns and may edit, and the ordinary injection path takes it
        from there (ADR 0011). Copied byte for byte from the copy shipped with Oriel, so the BOM the
        repository guard checks is the BOM that lands on disk.
    .OUTPUTS
        The path written.
    #>
    if (-not (Test-Path -LiteralPath $starterSource)) {
        throw "The starter statusline that ships with Oriel is missing from this install ($starterSource)."
    }

    # `statusline.ps1` is the conventional name and the one a user will look for. If
    # something is already sitting there — declared or not — it is not ours to
    # overwrite, so we take a name of our own instead.
    $target = Join-Path $claudeDir 'statusline.ps1'
    if (Test-Path -LiteralPath $target) { $target = Join-Path $claudeDir 'oriel-statusline.ps1' }

    if (-not (Test-Path -LiteralPath $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }
    Copy-Item -LiteralPath $starterSource -Destination $target -Force
    return $target
}

function script:Get-PreferredInterpreter {
    # pwsh when the machine has it, powershell.exe otherwise: users get the better
    # engine where it exists, and 5.1 is the floor beneath (ADR 0013).
    foreach ($i in $Interpreters) { if ($i.ToLowerInvariant().StartsWith('pwsh')) { return $i } }
    return $Interpreters[0]
}

function script:Set-DeclaredStatusline {
    <#
    .SYNOPSIS
        Point Claude Code's settings at a statusline, preserving every other setting.
    .OUTPUTS
        Whatever `statusLine` held before, so uninstall can put it back.
    #>
    param([string] $ScriptPath)

    $settings = script:Read-JsonOrNull $SettingsPath
    if ($null -eq $settings) { $settings = [pscustomobject]@{} }

    $prior = $null
    $existing = $settings.PSObject.Properties['statusLine']
    if ($null -ne $existing) { $prior = $existing.Value }

    $interpreter = script:Get-PreferredInterpreter
    $command = $interpreter + ' -NoProfile -File "' + $ScriptPath + '"'
    $declaration = [pscustomobject]@{ type = 'command'; command = $command }

    if ($null -ne $existing) { $settings.statusLine = $declaration }
    else { $settings | Add-Member -NotePropertyName 'statusLine' -NotePropertyValue $declaration }

    script:Write-Json -Path $SettingsPath -Object $settings
    return $prior
}

function script:Restore-DeclaredStatusline {
    param($Prior)
    $settings = script:Read-JsonOrNull $SettingsPath
    if ($null -eq $settings) { return }
    $existing = $settings.PSObject.Properties['statusLine']
    if ($null -eq $existing) { return }

    if ($null -eq $Prior) { $settings.PSObject.Properties.Remove('statusLine') }
    else { $settings.statusLine = $Prior }
    script:Write-Json -Path $SettingsPath -Object $settings
}

# ---- the install record ----------------------------------------------------

# What uninstall needs to know and cannot re-derive: which file was patched, whether
# the statusline is one Oriel wrote, and what the settings said before it did.
function script:Save-InstallRecord {
    param([string] $StatuslinePath, [bool] $StarterWritten, $PriorStatusLine)
    script:Write-Json -Path $recordPath -Object ([pscustomobject]@{
        statuslinePath  = $StatuslinePath
        starterWritten  = $StarterWritten
        priorStatusLine = $PriorStatusLine
        installedAt     = (Get-Date).ToString('o')
    })
}

# ---- verification (ticket 06) ----------------------------------------------

function script:Test-DataFlows {
    <#
    .SYNOPSIS
        Trigger a render and wait to see the state file appear, so a success is
        observed rather than assumed.
    .DESCRIPTION
        The managed block is fail-silent by design (ADR 0011), so a wrong guess about
        the shape of someone's statusline produces no error at all — just a widget
        showing dashes forever. This is the countermeasure: it turns a silent failure
        at the user's expense into a loud one at install time.

        The render is pointed at a throwaway state directory via ORIEL_STATE_DIR, so
        the probe payload can never land in the user's real current.json and show
        them numbers that were never true.
    .OUTPUTS
        An object with Ok and Detail.
    #>
    param([string] $Command)

    $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('oriel-verify-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
    $probeFile = Join-Path $probeDir 'current.json'

    try {
        $run = script:Invoke-Statusline -Command $Command -StdIn (script:Get-ProbePayload) -StateDir $probeDir -TimeoutSeconds $VerifyTimeoutSeconds
        if ($null -eq $run.ExitCode) {
            return [pscustomobject]@{ Ok = $false; Detail = "the statusline did not finish within $VerifyTimeoutSeconds seconds" }
        }
        if (Test-Path -LiteralPath $probeFile) {
            return [pscustomobject]@{ Ok = $true; Detail = 'the state file appeared' }
        }
        return [pscustomobject]@{
            Ok = $false
            Detail = "the statusline ran (exit $($run.ExitCode)) but wrote no state file"
        }
    } finally {
        try { Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function script:Get-ProbePayload {
    # Representative, and deliberately complete: the tee's never-tee-nulls rule means
    # a payload without both windows would write nothing and the probe would report a
    # failure that is really our own fault.
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    [pscustomobject]@{
        model = [pscustomobject]@{ display_name = 'Oriel install check' }
        context_window = [pscustomobject]@{ used_percentage = 12 }
        workspace = [pscustomobject]@{ current_dir = $HomeDir }
        rate_limits = [pscustomobject]@{
            five_hour = [pscustomobject]@{ used_percentage = 12; resets_at = ($now + 3600) }
            seven_day = [pscustomobject]@{ used_percentage = 34; resets_at = ($now + 4 * 86400) }
        }
    } | ConvertTo-Json -Depth 10 -Compress
}

function script:Get-SparsePayload {
    <#
    .SYNOPSIS
        The payload with nothing optional in it: a model name and nothing else.
    .DESCRIPTION
        This is the shape that catches damage to the *host* statusline rather than to
        Oriel. `rate_limits` is absent on Free accounts and on every session before its
        first API response, and `context_window` and `workspace` need not be there
        either — so a statusline reading those keys directly is reading keys that may
        not exist, which is ordinary and correct PowerShell. Anything the block leaks
        into that scope (a strict mode, an $ErrorActionPreference) shows up here and
        nowhere else. A complete payload passes cleanly and proves nothing, which is
        how such a leak shipped in v1.0.0 (oriel#1).
    #>
    [pscustomobject]@{ model = [pscustomobject]@{ display_name = 'Oriel install check' } } |
        ConvertTo-Json -Depth 10 -Compress
}

function script:Get-HostOutputBaseline {
    <#
    .SYNOPSIS
        What the user's statusline prints for a sparse payload *before* it is patched —
        the thing the patch is not allowed to change.
    .DESCRIPTION
        Rendered twice, and the baseline is discarded unless the two agree. A statusline
        that prints a clock, a spinner or a git revision is not comparable to itself,
        and holding one to a byte-for-byte rule would fail installs that are perfectly
        fine. Losing the check on those statuslines is the right trade: a false alarm
        that blocks an install costs more than a missed one.
    .OUTPUTS
        The agreed output, or $null when there is nothing dependable to compare against.
    #>
    param([string] $Command)

    $payload = script:Get-SparsePayload
    $first  = script:Invoke-Statusline -Command $Command -StdIn $payload -StateDir (script:New-ProbeDir) -TimeoutSeconds $VerifyTimeoutSeconds
    if ($null -eq $first.ExitCode) { return $null }
    $second = script:Invoke-Statusline -Command $Command -StdIn $payload -StateDir (script:New-ProbeDir) -TimeoutSeconds $VerifyTimeoutSeconds
    if ($null -eq $second.ExitCode) { return $null }
    if ($first.StdOut -ne $second.StdOut) { return $null }
    return $first.StdOut
}

function script:Test-HostOutputUnchanged {
    <#
    .SYNOPSIS
        Render the sparse payload again, now that the block is in, and insist the user's
        statusline still prints exactly what it printed before.
    .OUTPUTS
        An object with Ok and Detail. Ok is $true when there was no baseline to compare.
    #>
    # $Baseline is deliberately untyped: a [string] parameter coerces $null to the empty
    # string, and "there was no dependable baseline" would silently become "it printed
    # nothing" — the difference between skipping the check and failing it.
    param([string] $Command, $Baseline)

    if ($null -eq $Baseline) { return [pscustomobject]@{ Ok = $true; Detail = 'no comparable baseline' } }

    $run = script:Invoke-Statusline -Command $Command -StdIn (script:Get-SparsePayload) -StateDir (script:New-ProbeDir) -TimeoutSeconds $VerifyTimeoutSeconds
    if ($null -eq $run.ExitCode) {
        return [pscustomobject]@{ Ok = $false; Detail = 'with the block in place, your statusline did not finish' }
    }
    if ($run.StdOut -eq $Baseline) { return [pscustomobject]@{ Ok = $true; Detail = 'unchanged' } }

    $detail = 'the block changed what your statusline prints when there is no rate-limit data'
    if ([string]::IsNullOrWhiteSpace($run.StdOut) -and -not [string]::IsNullOrWhiteSpace($Baseline)) {
        $detail = 'with the block in place your statusline printed nothing, where before it printed its normal line'
    }
    if (-not [string]::IsNullOrWhiteSpace($run.StdErr)) { $detail += ' — it reported: ' + ($run.StdErr.Trim() -split "`r?`n")[0] }
    return [pscustomobject]@{ Ok = $false; Detail = $detail }
}

# Every render the installer triggers is pointed at a throwaway directory, so a probe
# payload can never land in the user's real current.json and show them numbers that
# were never true.
function script:New-ProbeDir {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('oriel-verify-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $script:ProbeDirs += $dir
    return $dir
}

$script:ProbeDirs = @()

function script:Remove-ProbeDirs {
    foreach ($dir in $script:ProbeDirs) {
        try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    $script:ProbeDirs = @()
}

function script:Invoke-Statusline {
    <#
    .SYNOPSIS
        Run a declared statusline command with JSON on its standard input, under a
        bounded wait so verification can never hang the installer.
    .OUTPUTS
        ExitCode, StdOut and StdErr. ExitCode is $null when the command could not be
        started or had to be killed — the caller must treat that as "nothing observed",
        never as a pass. StdOut is what the user would see on their status line, which
        is what makes "the patch changed nothing they can see" checkable.
    #>
    param([string] $Command, [string] $StdIn, [string] $StateDir, [int] $TimeoutSeconds)

    $nothing = [pscustomobject]@{ ExitCode = $null; StdOut = ''; StdErr = '' }

    $tokens = Split-CommandLine $Command
    if ($tokens.Count -eq 0) { return $nothing }

    $exe = $tokens[0]
    $rest = @()
    if ($tokens.Count -gt 1) { $rest = $tokens[1..($tokens.Count - 1)] }

    # A bare `foo.ps1` as the whole command runs under PowerShell; make that explicit
    # rather than relying on the shell's file association.
    if ($tokens.Count -eq 1 -and $exe.ToLowerInvariant().EndsWith('.ps1')) {
        $rest = @('-NoProfile', '-File', $exe)
        $exe = script:Get-PreferredInterpreter
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    foreach ($a in $rest) {
        # Re-quote what Split-CommandLine unquoted, or a path with a space arrives as
        # two arguments.
        if ($a.Contains(' ')) { $psi.Arguments += '"' + $a + '" ' } else { $psi.Arguments += $a + ' ' }
    }
    $psi.Arguments = $psi.Arguments.TrimEnd()
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $HomeDir
    # The one hook the tee honours for this: the probe render writes here instead of
    # over the user's real record. It is documented for users too — it is the same hook
    # that makes a statusline safe to test by hand.
    $psi.EnvironmentVariables['ORIEL_STATE_DIR'] = $StateDir

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Write($StdIn)
        $proc.StandardInput.Close()
        # Output is drained rather than ignored: a statusline that prints more than
        # the pipe buffer holds would otherwise block forever on a full pipe and the
        # bounded wait would report a timeout that never happened.
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            return $nothing
        }
        [void]$stdout.Wait(1000)
        [void]$stderr.Wait(1000)
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut   = [string]$stdout.Result
            StdErr   = [string]$stderr.Result
        }
    } catch {
        script:Say "Could not run the statusline: $($_.Exception.Message)" 'Yellow'
        return $nothing
    } finally {
        if ($null -ne $proc) { $proc.Dispose() }
    }
}

# ---- the three actions -----------------------------------------------------

function script:Get-Triage {
    $settings = script:Read-JsonOrNull $SettingsPath
    Get-StatuslineTriage -Settings $settings -HomeDir $HomeDir -ReadScript { param($p) script:Read-TextOrNull $p }
}

function script:Invoke-Triage {
    $triage = script:Get-Triage
    $script:Report.verdict = $triage.Verdict
    $script:Report.reason  = $triage.Reason
    $script:Report.statuslinePath = $triage.ScriptPath

    switch ($triage.Verdict) {
        'none' {
            $script:Report.message = 'You have no statusline. Oriel will write one for you and use it.'
            # Shown so the consent page can display the literal text even in the case
            # where the file it goes into does not exist yet.
            $script:Report.block = New-OrielBlock -TeePath $TeePath -Variable '$d' -Newline "`r`n"
            script:Say $script:Report.message 'Cyan'
            script:Say ''
            script:Say 'It will add exactly this to it:' 'Gray'
            script:Say $script:Report.block 'White'
            script:Complete $script:ExitOk
        }
        'supported' {
            $script:Report.message = "Oriel can install into $($triage.ScriptPath)."
            $script:Report.block = New-OrielBlock -TeePath $TeePath -Variable $triage.Variable -Newline "`r`n"
            script:Say $script:Report.message 'Cyan'
            script:Say ''
            script:Say 'It will add exactly this, and change nothing else:' 'Gray'
            script:Say $script:Report.block 'White'
            script:Complete $script:ExitOk
        }
        default {
            script:Show-Refusal $triage
            script:Complete $script:ExitRefused
        }
    }
}

function script:Show-Refusal {
    param($Triage)
    $script:Report.message = Get-RefusalExplanation -Reason $Triage.Reason -ScriptPath $Triage.ScriptPath -Command $Triage.Command
    $script:Report.conversionPrompt = Get-ConversionPrompt -ScriptPath $Triage.ScriptPath

    script:Say ''
    script:Say 'Oriel did not install. Nothing on your disk was changed.' 'Red'
    script:Say ''
    script:Say $script:Report.message 'Yellow'
    script:Say ''
    script:Say 'Paste this into Claude Code to convert your statusline, then run the installer again:' 'Cyan'
    script:Say ''
    script:Say $script:Report.conversionPrompt 'White'
}

function script:Invoke-Install {
    # Triage FIRST, and migration only once it has passed.
    #
    # The order is load-bearing. Migration moves the state directory and clears the old
    # Run-key value, so running it ahead of triage would make "nothing on your disk was
    # changed" a lie on exactly the machines the message matters most for: a pre-rename
    # install whose statusline Oriel then declines to serve. A refusal must change
    # nothing at all, and that has to include the migration.
    $triage = script:Get-Triage
    $script:Report.verdict = $triage.Verdict
    $script:Report.reason  = $triage.Reason

    if ($triage.Verdict -eq 'refuse') {
        script:Show-Refusal $triage
        script:Complete $script:ExitRefused
    }

    script:Invoke-Migration

    $starterWritten = $false
    $prior = $null
    $statuslinePath = $triage.ScriptPath

    if ($triage.Verdict -eq 'none') {
        $statuslinePath = script:Install-StarterStatusline
        $prior = script:Set-DeclaredStatusline -ScriptPath $statuslinePath
        $starterWritten = $true
        $script:Report.starterWritten = $true
        $script:Report.changed += "wrote a starter statusline at $statuslinePath and declared it in $SettingsPath"
        script:Say "Wrote you a statusline at $statuslinePath" 'Green'
    }

    $script:Report.statuslinePath = $statuslinePath

    # Before touching the file: what does this statusline print when the payload has no
    # rate-limit data in it? That is the population the block is most likely to damage
    # and the only one where the damage shows, so the answer has to be taken while the
    # file is still theirs alone (ticket 06 / oriel#1).
    $baseline = $null
    if (-not $SkipVerify) { $baseline = script:Get-HostOutputBaseline -Command (script:Get-Triage).Command }

    # Patch. Everything around the block is left byte for byte as it was.
    $original = script:Read-TextOrNull $statuslinePath
    if ($null -eq $original) { throw "The statusline vanished between triage and patching: $statuslinePath" }
    $hadBom = script:Test-HasBom $statuslinePath

    $patched = Add-OrielBlock -Text $original -TeePath $TeePath
    if ($null -eq $patched) {
        # Only reachable if the file changed under us between triage and here.
        throw "No place to anchor the managed block in $statuslinePath."
    }

    # Back up once, and never clobber an existing backup: the backup is a safety net
    # for a failed removal, not the method uninstall uses (ADR 0011).
    $backup = $statuslinePath + '.bak'
    $backupCreated = $false
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $statuslinePath -Destination $backup -Force
        $backupCreated = $true
        $script:Report.changed += "backed the original up to $backup"
    }

    script:Write-TextPreservingEncoding -Path $statuslinePath -Text $patched -HadBom $hadBom
    $script:Report.block = New-OrielBlock -TeePath $TeePath -Variable (Find-JsonAssignment $original).Variable -Newline (Get-DominantNewline $original)
    $script:Report.changed += "inserted the managed block into $statuslinePath"
    script:Say "Patched $statuslinePath" 'Green'

    script:Save-InstallRecord -StatuslinePath $statuslinePath -StarterWritten $starterWritten -PriorStatusLine $prior

    if ($SkipVerify) {
        # Never the word "installed" on its own: a success is not something this run is
        # entitled to report, because it observed nothing. The verdict says so too, so a
        # front end reading the report cannot mistake this for the verified path. Neither
        # front end passes this switch; it exists so the shape-table tests do not each
        # start a statusline process.
        $script:Report.verdict = 'unverified'
        $script:Report.verified = $false
        $script:Report.message = 'Patched, but NOT verified: verification was skipped, so nothing here has been observed working.'
        script:Say $script:Report.message 'Yellow'
        script:Complete $script:ExitOk
    }

    # Verify against the command Claude Code will actually run, not against the file
    # we happened to patch — they are the same thing only if the declaration is right.
    $command = (script:Get-Triage).Command
    try {
        $check = script:Test-DataFlows -Command $command

        # Two independent questions, and both have to be answered before the word
        # "installed" is used: does data now flow, and does the user's own statusline
        # still print what it printed before? The second is not a formality — the block
        # is a side effect inside someone else's script, and the way it went wrong in
        # v1.0.0 was invisible to the first check (oriel#1).
        $preserved = [pscustomobject]@{ Ok = $true; Detail = 'not checked' }
        if ($check.Ok) { $preserved = script:Test-HostOutputUnchanged -Command $command -Baseline $baseline }

        $script:Report.verified = ($check.Ok -and $preserved.Ok)

        if ($script:Report.verified) {
            $script:Report.message = 'Installed and verified: Claude Code is now writing usage data for the widget, and your statusline still renders exactly as it did.'
            script:Say ''
            script:Say $script:Report.message 'Green'
            script:Complete $script:ExitOk
        }

        if (-not $preserved.Ok) {
            # This one is not left in place to be looked at. The block is only worth
            # having if it is invisible, and a statusline the user looks at all day is
            # worth more than the widget (ADR 0011) — so it goes back to the file they
            # had, in this same run, before the report is printed.
            script:Write-TextPreservingEncoding -Path $statuslinePath -Text $original -HadBom $hadBom
            # The backup was insurance for exactly this, and it has done its job. Only
            # the one this run made is removed — an older one is not ours to delete.
            if ($backupCreated -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup -Force }
            $script:Report.verdict = 'rolled-back'
            $script:Report.changed += "removed the managed block again from $statuslinePath"
            $script:Report.message = @"
Oriel patched your statusline, saw that the patch changed what your statusline prints,
and TOOK THE PATCH BACK OUT. Your statusline is exactly as it was, and Oriel is not
installed.

  What happened    : $($preserved.Detail)
  What was tested  : a render with no rate-limit data in the payload — the shape a Free
                     account, and any session before its first reply, actually gets
  Your statusline  : $statuslinePath (unchanged)

This is a bug in Oriel, not in your statusline. Please report it with the statusline
you have, at https://github.com/bolduck91/oriel/issues — a statusline that behaves
differently once the block is in is exactly what this check exists to find.
"@
            script:Say ''
            script:Say $script:Report.message 'Red'
            script:Complete $script:ExitUnverified
        }

        # Patched, no data. Say what was changed, where the file was expected, what to try.
        $script:Report.message = @"
Oriel patched your statusline but could not observe it producing data, so this is not
being reported as a successful install.

  What was changed : $statuslinePath
  What happened    : $($check.Detail)
  Expected to see  : $(Join-Path $stateDir 'current.json') after a render

What to try:
  1. Run your statusline by hand and check it does not error.
  2. Look at the block Oriel inserted: it should sit directly after the line that
     parses the JSON your statusline read from standard input, and reference the
     variable that line assigns.
  3. Rate-limit data only exists on Pro/Max accounts and only after the first API
     response of a session — if you have just signed in, wait for a reply and re-run.
  4. To try it by hand without touching your real data, point the tee somewhere else:
       `$env:ORIEL_STATE_DIR = "`$env:TEMP\oriel-probe"
       '{"model":{"display_name":"x"}}' | & <your statusline>
  5. Undo everything with: -Action uninstall
"@
        script:Say ''
        script:Say $script:Report.message 'Red'
        script:Complete $script:ExitUnverified
    } finally {
        script:Remove-ProbeDirs
    }
}

function script:Invoke-Uninstall {
    $record = script:Read-JsonOrNull $recordPath

    $statuslinePath = $null
    $starterWritten = $false
    $prior = $null
    if ($null -ne $record) {
        if ($record.PSObject.Properties['statuslinePath']) { $statuslinePath = $record.statuslinePath }
        if ($record.PSObject.Properties['starterWritten']) { $starterWritten = [bool]$record.starterWritten }
        if ($record.PSObject.Properties['priorStatusLine']) { $prior = $record.priorStatusLine }
    }
    # No record — an install from before records existed, or a half-finished one.
    # Fall back to whatever is declared now.
    if ([string]::IsNullOrWhiteSpace($statuslinePath)) { $statuslinePath = (script:Get-Triage).ScriptPath }

    $script:Report.statuslinePath = $statuslinePath

    if (-not [string]::IsNullOrWhiteSpace($statuslinePath) -and (Test-Path -LiteralPath $statuslinePath)) {
        $text = script:Read-TextOrNull $statuslinePath
        $hadBom = script:Test-HasBom $statuslinePath
        $stripped = Remove-OrielBlock $text

        if ($starterWritten -and -not $KeepStarter) {
            # The settings only go back if Oriel is what put a statusline there.
            script:Restore-DeclaredStatusline -Prior $prior
            Remove-Item -LiteralPath $statuslinePath -Force
            $script:Report.changed += "removed the starter statusline at $statuslinePath and restored your settings"
            script:Say "Removed the statusline Oriel wrote, and put your settings back." 'Green'
        }
        else {
            if ($stripped -ne $text) {
                script:Write-TextPreservingEncoding -Path $statuslinePath -Text $stripped -HadBom $hadBom
                $script:Report.changed += "removed the managed block from $statuslinePath"
                script:Say "Removed Oriel's managed block from $statuslinePath" 'Green'
            }
            else {
                script:Say "No Oriel block found in $statuslinePath — nothing to remove." 'Gray'
            }
            if ($starterWritten) { script:Say 'Kept the statusline Oriel wrote; it is yours now.' 'Gray' }
        }

        # The backup was insurance against a failed removal. The removal succeeded.
        $backup = $statuslinePath + '.bak'
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    }
    else {
        script:Say 'No statusline to clean up.' 'Gray'
    }

    if (Test-Path -LiteralPath $recordPath) { Remove-Item -LiteralPath $recordPath -Force }

    # State and preferences are deliberately left: a reinstall should find the user's
    # skin and position where they left them.
    $script:Report.verdict = 'uninstalled'
    $script:Report.message = 'Oriel removed. Your saved preferences were left in ' + $stateDir + '.'
    script:Say $script:Report.message 'Green'
    script:Complete $script:ExitOk
}

# ---- dispatch --------------------------------------------------------------

try {
    switch ($Action) {
        'triage'    { script:Invoke-Triage }
        'install'   { script:Invoke-Install }
        'uninstall' { script:Invoke-Uninstall }
    }
} catch {
    $script:Report.verdict = 'error'
    $script:Report.message = $_.Exception.Message
    if (-not $Json) { Write-Host "Oriel installer failed: $($_.Exception.Message)" -ForegroundColor Red }
    script:Complete $script:ExitError
}
