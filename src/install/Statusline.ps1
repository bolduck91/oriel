# The judgement half of the installer: everything that decides *what* to do to a
# user's statusline, expressed as pure text-in / text-out (tickets 02-04).
#
# It is separated from Install-Oriel.ps1 on purpose. That file is the only thing in
# the project that writes to a user's disk; this file cannot, and so the delicate
# part — classifying a statusline, finding the anchor, producing the exact bytes of
# an insertion and its exact inverse — can be reasoned about and tested with strings
# alone. Dot-source it; it has no side effects.
#
# Windows PowerShell 5.1 is the floor for every file here (ADR 0013): the installer
# may be driven by whatever interpreter the machine has, and 5.1 is the only one
# Windows guarantees. No ternaries, no `??`, no 3-argument Join-Path.

Set-StrictMode -Version Latest

# The markers that delimit the managed block. Named for Oriel so a user reading
# their own statusline months later knows what put it there, and stable because
# uninstall finds the block by them.
$script:BeginMark = '# >>> oriel tee (managed block — safe to remove) >>>'
$script:EndMark   = '# <<< oriel tee <<<'

# What a pre-rename install left behind, which migration has to recognise (ticket 07).
$script:LegacyBeginMark = '# >>> claude-usage-widget tee (managed block — safe to remove) >>>'
$script:LegacyEndMark   = '# <<< claude-usage-widget tee <<<'

function Get-DominantNewline {
    <#
    .SYNOPSIS
        The line ending the file already uses, so an insertion does not introduce a
        second convention into someone else's file.
    #>
    param([string] $Text)
    if ($null -ne $Text -and $Text.Contains("`r`n")) { return "`r`n" }
    if ($null -ne $Text -and $Text.Contains("`n")) { return "`n" }
    return "`r`n"
}

# An assignment token: `$d`, `$global:d`, `$script:data`. The negative lookahead on
# `=` keeps `-eq`-style comparisons and `==` typos from reading as assignments.
$script:AssignmentPattern = '\$((?:global:|script:|local:|private:)?[A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)'

# The ways a PowerShell statusline can get hold of what Claude Code pushed on standard
# input. This list is the whole reason the anchor is trustworthy: `ConvertFrom-Json` on
# its own says nothing about *which* JSON is being parsed, and a statusline that reads
# its own settings, a cache or `git` output through ConvertFrom-Json is completely
# ordinary. Anchoring on the first conversion found patched such a line on a real user's
# machine and produced a silent no-op every render (field report, oriel#1).
$script:StdinPatterns = @(
    '\[(?:System\.)?Console\]::In\b',                 # [Console]::In.ReadToEnd()
    '\[(?:System\.)?Console\]::OpenStandardInput\b',   # a StreamReader over it
    '\$input\b',                                       # the automatic pipeline variable
    '\bGet-Content\b[^|;]*(?<![\w.\-])-(?=\s|$)'       # Get-Content -Raw -   (bare `-` is stdin)
)

function script:Test-ReadsStdinDirectly {
    param([string] $Fragment)
    if ([string]::IsNullOrEmpty($Fragment)) { return $false }
    foreach ($pattern in $script:StdinPatterns) {
        if ([regex]::IsMatch($Fragment, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { return $true }
    }
    return $false
}

function Test-ReadsStandardInput {
    <#
    .SYNOPSIS
        Does this script read standard input at all?
    .DESCRIPTION
        Used only to tell two refusals apart: a statusline that never reads the pushed
        JSON is a different problem, with different advice, from one that reads it and
        then throws it away. Comments do not count.
    #>
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    foreach ($line in (script:Split-IntoLines $Text).Texts) {
        if ($line.TrimStart().StartsWith('#')) { continue }
        if (script:Test-ReadsStdinDirectly $line) { return $true }
    }
    return $false
}

function script:Split-IntoLines {
    <#
    .SYNOPSIS
        The file's lines, with the character offset just past each terminator.
    .DESCRIPTION
        Walks the raw text rather than using Get-Content, because the insertion index
        has to be an offset into the exact bytes the user has on disk.
    #>
    param([string] $Text)
    $ends  = New-Object System.Collections.Generic.List[int]      # index past the terminator
    $texts = New-Object System.Collections.Generic.List[string]

    $start = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq "`n") {
            $ends.Add($i + 1)
            $texts.Add($Text.Substring($start, $i + 1 - $start).TrimEnd("`r", "`n"))
            $start = $i + 1
        }
    }
    if ($start -lt $Text.Length) {
        $ends.Add($Text.Length)              # no terminator: the file ends here
        $texts.Add($Text.Substring($start))
    }
    [pscustomobject]@{ Ends = $ends; Texts = $texts }
}

function Find-JsonAssignment {
    <#
    .SYNOPSIS
        Locate the assignment that keeps the JSON *pushed on standard input* — the
        definition of a **supported statusline** (ADR 0011) and therefore the anchor
        the **managed block** is inserted after.
    .DESCRIPTION
        Standard input can be read only once, so the block cannot fetch the JSON; it
        can only borrow a variable that already holds it. Finding that variable takes
        two facts, not one: an assignment through `ConvertFrom-Json`, *and* a chain
        back to a read of standard input.

            $raw = [Console]::In.ReadToEnd()
            $d = $raw | ConvertFrom-Json                       <- anchor here
            try { $d = $raw | ConvertFrom-Json } catch { }     <- or here
            $d = ConvertFrom-Json $raw                         <- or here
            $d = [Console]::In.ReadToEnd() | ConvertFrom-Json  <- or here

        The lineage is tracked forward: the variable a read of standard input is
        assigned to is marked, and so is anything later assigned from something
        already marked (`$raw.Trim()`, `-join $lines`). A conversion whose right-hand
        side mentions none of them is somebody else's JSON — settings, a cache, `git`
        output — and is skipped rather than patched.

        A line that pipes the JSON onward without keeping it has no assignment to its
        left and is correctly not found — that statusline cannot be served.

        Comment lines are skipped, so prose about ConvertFrom-Json is not an anchor,
        and so is Oriel's own managed block, which mentions nothing but must never
        anchor a second insertion inside itself.
    .OUTPUTS
        $null when there is nothing to anchor on, otherwise an object carrying the
        variable to reference and the character index the block is inserted at —
        just past the end of the anchor line, including its terminator.
    #>
    param([string] $Text)

    if ([string]::IsNullOrEmpty($Text)) { return $null }

    $lines = script:Split-IntoLines $Text

    # Variables known to hold what arrived on standard input. A hashtable is the set:
    # PowerShell's are case-insensitive, which is what variable names are.
    $carriesStdin = @{}

    $inManagedBlock = $false
    for ($n = 0; $n -lt $lines.Texts.Count; $n++) {
        $line = $lines.Texts[$n]
        $trimmed = $line.TrimStart()

        if ($trimmed.StartsWith($script:BeginMark) -or $trimmed.StartsWith($script:LegacyBeginMark)) { $inManagedBlock = $true }
        if ($inManagedBlock) {
            if ($trimmed.StartsWith($script:EndMark) -or $trimmed.StartsWith($script:LegacyEndMark)) { $inManagedBlock = $false }
            continue
        }
        if ($trimmed.StartsWith('#')) { continue }

        $at = $line.IndexOf('ConvertFrom-Json', [System.StringComparison]::OrdinalIgnoreCase)
        if ($at -lt 0) {
            script:Add-StdinLineage -Line $line -CarriesStdin $carriesStdin
            continue
        }

        # The conversion's logical line: this one, plus any lines above it that ended
        # in a pipe, which is how a broken-across-lines pipeline reaches it.
        $fragment = $line
        $back = $n - 1
        while ($back -ge 0) {
            $previous = $lines.Texts[$back].TrimEnd()
            if (-not $previous.EndsWith('|')) { break }
            $fragment = $previous + ' ' + $fragment
            $back--
        }

        # The assignment is the rightmost one to the left of the conversion. Rightmost,
        # not leftmost, because `try { $d = $raw | ConvertFrom-Json }` has the `try {`
        # in front of it and the target is the nearest one.
        $atInFragment = $fragment.IndexOf('ConvertFrom-Json', [System.StringComparison]::OrdinalIgnoreCase)
        $assignment = script:Find-Assignment $fragment.Substring(0, $atInFragment)
        if ($null -eq $assignment) { continue }   # piped straight through: nothing kept

        # Only the right-hand side is asked about standard input, so a variable that
        # happens to share a name with a marked one cannot vouch for itself.
        if (-not (script:Test-CarriesStdin -Fragment $fragment.Substring($assignment.EndIndex) -CarriesStdin $carriesStdin)) {
            script:Add-StdinLineage -Line $line -CarriesStdin $carriesStdin
            continue
        }

        $hasTerminator = $lines.Ends[$n] -gt 0 -and $Text[$lines.Ends[$n] - 1] -eq "`n"
        return [pscustomobject]@{
            Variable      = $assignment.Variable
            InsertAt      = $lines.Ends[$n]
            HasTerminator = $hasTerminator
        }
    }
    return $null
}

function script:Find-Assignment {
    <#
    .SYNOPSIS
        The rightmost assignment in a fragment: the variable it targets, and where its
        right-hand side begins.
    #>
    param([string] $Fragment)
    # Not $matches: that is an automatic variable, and shadowing it here would make
    # every regex operator downstream in this scope read someone else's captures.
    $found = [regex]::Matches($Fragment, $script:AssignmentPattern)
    if ($found.Count -eq 0) { return $null }
    $last = $found[$found.Count - 1]
    $name = $last.Groups[1].Value
    [pscustomobject]@{
        Variable = '$' + $name                       # as it will be written into the block
        Name     = ($name -replace '^(?:global:|script:|local:|private:)', '')
        EndIndex = $last.Index + $last.Length        # just past the `=`
    }
}

function script:Test-CarriesStdin {
    # Either it reads standard input right here, or it borrows from something that did.
    param([string] $Fragment, $CarriesStdin)
    if (script:Test-ReadsStdinDirectly $Fragment) { return $true }
    foreach ($name in $CarriesStdin.Keys) {
        $pattern = '\$(?:global:|script:|local:|private:)?' + [regex]::Escape($name) + '\b'
        if ([regex]::IsMatch($Fragment, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { return $true }
    }
    return $false
}

function script:Add-StdinLineage {
    # One step of the forward taint: if this line assigns from standard input, or from
    # a variable already carrying it, its target carries it too.
    param([string] $Line, $CarriesStdin)
    $assignment = script:Find-Assignment $Line
    if ($null -eq $assignment) { return }
    if (script:Test-CarriesStdin -Fragment $Line.Substring($assignment.EndIndex) -CarriesStdin $CarriesStdin) {
        $CarriesStdin[$assignment.Name] = $true
    }
}

function New-OrielBlock {
    <#
    .SYNOPSIS
        The exact text of the **managed block**, for a given tee and JSON variable.
    .DESCRIPTION
        Fail-silent by design (ADR 0011): the block is a side effect of someone
        else's statusline and must never break the line it was inserted into. That
        is also why the installer verifies afterwards — a try/catch that swallows a
        wrong guess is invisible without it (ticket 06).

        The dot-source happens inside `& { }`, in a child scope. A bare `.` executes
        the tee in the *caller's* scope, and anything the tee sets at file scope then
        belongs to the user's statusline from this line down — which is not a
        theoretical worry: `Set-StrictMode -Version Latest` leaked that way and turned
        every optional-key read in the host script into a throw, on exactly the
        accounts that have no rate-limit data to show (field report, oriel#1). The tee
        no longer sets it at file scope, and this makes the boundary structural rather
        than a promise: a try/catch cannot help here, because by the time it catches,
        the preference has already been set in a scope that outlives the block.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $TeePath,
        [Parameter(Mandatory = $true)] [string] $Variable,
        [string] $Newline = "`r`n"
    )
    # Built by concatenation rather than a here-string: the block contains a `$`
    # variable and a user-supplied path, and both would be read as substitutions.
    $body = "try { & { . '" + $TeePath + "'; Write-UsageState -StatusJson " + $Variable + " | Out-Null } } catch { }"
    $script:BeginMark + $Newline + $body + $Newline + $script:EndMark
}

function Remove-OrielBlock {
    <#
    .SYNOPSIS
        Strip a previously-inserted **managed block**, including the newlines the
        insertion added — the exact inverse of Add-OrielBlock.
    .DESCRIPTION
        This is what makes installing twice replace rather than stack, and what makes
        uninstalling give the original file back byte for byte. The two insertion
        shapes leave two distinguishable traces:

            mid-file        : <block>\n          -> block plus the newline after it
            appended at EOF : \n<block>          -> block plus the newline before it

        Legacy markers are stripped too, so a pre-rename install uninstalls cleanly
        and migration can re-insert under the new markers (ticket 07). They need their
        OWN inverse, not this one: the retired patcher anchored before an emit comment
        and inserted `<block>\r\n\r\n` there — two newlines, not one. Stripping only one
        leaves a blank line the user never had, on every pre-rename machine, and it
        survives uninstall. The shapes are:

            new, mid-file        : <block>\n
            new, appended at EOF : \n<block>
            legacy, mid-file     : <block>\n\n
            legacy, at EOF       : \n<block>\n
    #>
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $current = [regex]::Escape($script:BeginMark) + '.*?' + [regex]::Escape($script:EndMark)
    $Text = [regex]::Replace($Text, $current + '\r?\n', '', 'Singleline')
    $Text = [regex]::Replace($Text, '\r?\n' + $current + '\z', '', 'Singleline')

    $legacy = [regex]::Escape($script:LegacyBeginMark) + '.*?' + [regex]::Escape($script:LegacyEndMark)
    # The two-newline form first: it is a superset of the one-newline form, so trying
    # the shorter pattern first would eat the block and leave a stray blank line.
    $Text = [regex]::Replace($Text, $legacy + '\r?\n\r?\n', '', 'Singleline')
    $Text = [regex]::Replace($Text, '\r?\n' + $legacy + '(?:\r?\n)?\z', '', 'Singleline')
    $Text = [regex]::Replace($Text, $legacy + '\r?\n', '', 'Singleline')

    return $Text
}

function Add-OrielBlock {
    <#
    .SYNOPSIS
        Insert the **managed block** immediately after the assignment that holds the
        pushed JSON, leaving every other byte of the file alone.
    .DESCRIPTION
        Anchoring on the assignment rather than on an emit comment is what makes this
        work for someone else's file: the comment is a feature of the author's own
        statusline, the assignment is the *definition* of supported (ADR 0011).

        Any existing block is stripped first, so a second install replaces rather
        than stacks. The file's own line ending is used, so a LF-only file stays
        LF-only.
    .OUTPUTS
        $null when there is no anchor — the caller refuses rather than guessing.
    #>
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory = $true)] [string] $TeePath
    )

    $newline = Get-DominantNewline $Text
    $clean = Remove-OrielBlock $Text

    $anchor = Find-JsonAssignment $clean
    if ($null -eq $anchor) { return $null }

    $block = New-OrielBlock -TeePath $TeePath -Variable $anchor.Variable -Newline $newline

    if ($anchor.HasTerminator) {
        # The common shape: slot the block in as whole lines after the anchor's own.
        return $clean.Insert($anchor.InsertAt, $block + $newline)
    }
    # The anchor is the last line and the file has no trailing newline. Adding one
    # after the block would be a byte the user did not have; putting the newline in
    # front keeps the file's ending exactly as it was.
    return $clean + $newline + $block
}

# ---- reading what the user actually declared -------------------------------

function Split-CommandLine {
    <#
    .SYNOPSIS
        Split a `statusLine.command` into tokens, honouring double quotes.
    .DESCRIPTION
        The declared command is a shell string, not a path — it may name an
        interpreter, carry flags, and quote a path containing spaces. Assuming the
        path by convention is exactly what only ever worked for the author.
    #>
    param([string] $Command)
    $tokens = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Command)) { return $tokens.ToArray() }

    $current = New-Object System.Text.StringBuilder
    $inQuote = $false
    $quoteChar = ' '
    foreach ($c in $Command.ToCharArray()) {
        if ($inQuote) {
            if ($c -eq $quoteChar) { $inQuote = $false } else { [void]$current.Append($c) }
        }
        elseif ($c -eq '"' -or $c -eq "'") { $inQuote = $true; $quoteChar = $c }
        elseif ($c -eq ' ' -or $c -eq "`t") {
            if ($current.Length -gt 0) { [void]$tokens.Add($current.ToString()); [void]$current.Clear() }
        }
        else { [void]$current.Append($c) }
    }
    if ($current.Length -gt 0) { [void]$tokens.Add($current.ToString()) }
    return $tokens.ToArray()
}

$script:PowerShellHosts = @('pwsh', 'pwsh.exe', 'powershell', 'powershell.exe', 'windowspowershell')

function Resolve-DeclaredStatusline {
    <#
    .SYNOPSIS
        Work out which script file a `statusLine.command` actually runs, and under
        which interpreter.
    .OUTPUTS
        An object with Interpreter (may be $null when the script is invoked
        directly), ScriptPath (may be $null when the command runs no .ps1) and
        IsPowerShell.
    #>
    param(
        [string] $Command,
        [string] $HomeDir
    )

    $tokens = Split-CommandLine $Command
    if ($tokens.Count -eq 0) {
        return [pscustomobject]@{ Interpreter = $null; ScriptPath = $null; IsPowerShell = $false }
    }

    $first = $tokens[0]
    $firstLeaf = [System.IO.Path]::GetFileName($first)
    if ([string]::IsNullOrEmpty($firstLeaf)) { $firstLeaf = $first }

    $isPowerShellHost = $script:PowerShellHosts -contains $firstLeaf.ToLowerInvariant()

    $scriptPath = $null
    foreach ($t in $tokens) {
        if ($t.ToLowerInvariant().EndsWith('.ps1')) { $scriptPath = $t; break }
    }

    if ($null -ne $scriptPath) { $scriptPath = Expand-UserPath -Path $scriptPath -HomeDir $HomeDir }

    [pscustomobject]@{
        Interpreter  = $first
        ScriptPath   = $scriptPath
        # A .ps1 invoked with no interpreter still runs under PowerShell; a .ps1
        # named on a bash or node command line does not.
        IsPowerShell = $isPowerShellHost -or ($null -ne $scriptPath -and $tokens.Count -eq 1)
    }
}

function Expand-UserPath {
    <#
    .SYNOPSIS
        Turn `~/...`, `%VAR%` and `$HOME/...` into a real path against the home
        directory the caller supplied — never the process's own.
    .DESCRIPTION
        The whole feature is testable without a machine to install onto because the
        home directory is an input (ticket 02). Reaching for $HOME here would undo
        that in one line.
    #>
    param(
        [string] $Path,
        [string] $HomeDir
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }

    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -match '^~[\\/]') { $expanded = Join-Path $HomeDir $expanded.Substring(2) }
    elseif ($expanded -eq '~') { $expanded = $HomeDir }
    $expanded = $expanded.Replace('$HOME', $HomeDir).Replace('${HOME}', $HomeDir)

    if (-not [System.IO.Path]::IsPathRooted($expanded)) { $expanded = Join-Path $HomeDir $expanded }
    # GetFullPath normalises separators and `..`, so two spellings of one file cannot
    # read as two files.
    try { return [System.IO.Path]::GetFullPath($expanded) } catch { return $expanded }
}

# ---- triage ----------------------------------------------------------------

function Get-StatuslineTriage {
    <#
    .SYNOPSIS
        Which of the three populations the user is in (ADR 0011), decided before
        anything is written.
    .DESCRIPTION
        | What the user has              | Verdict     |
        |--------------------------------|-------------|
        | No statusline declared         | `none`      |
        | A **supported statusline**     | `supported` |
        | Anything else                  | `refuse`    |

        Takes the settings object and the statusline's text as input rather than
        reading either, so every branch is reachable from a string in a test.
    .PARAMETER Settings
        The parsed settings object, or $null when there is no settings file.
    .PARAMETER ReadScript
        Called with a resolved path; returns the script's text, or $null if it does
        not exist. Injected so triage does no I/O of its own.
    .OUTPUTS
        Verdict, Reason (refusals only), ScriptPath, Variable (supported only).
    #>
    param(
        $Settings,
        [Parameter(Mandatory = $true)] [string] $HomeDir,
        [Parameter(Mandatory = $true)] [scriptblock] $ReadScript
    )

    $command = script:Get-DeclaredCommand $Settings
    if ([string]::IsNullOrWhiteSpace($command)) {
        return [pscustomobject]@{
            Verdict = 'none'; Reason = $null; ScriptPath = $null; Variable = $null; Command = $null
        }
    }

    $resolved = Resolve-DeclaredStatusline -Command $command -HomeDir $HomeDir

    if (-not $resolved.IsPowerShell -or $null -eq $resolved.ScriptPath) {
        return [pscustomobject]@{
            Verdict = 'refuse'
            Reason  = 'not-powershell'
            ScriptPath = $resolved.ScriptPath
            Variable = $null
            Command = $command
        }
    }

    $text = & $ReadScript $resolved.ScriptPath
    if ($null -eq $text) {
        return [pscustomobject]@{
            Verdict = 'refuse'
            Reason  = 'missing-file'
            ScriptPath = $resolved.ScriptPath
            Variable = $null
            Command = $command
        }
    }

    $anchor = Find-JsonAssignment $text
    if ($null -eq $anchor) {
        # Two different problems, and they want different advice: a statusline that
        # never reads what Claude Code pushed, and one that reads it but keeps nothing.
        # Refusing loudly is the point — the alternative is patching a guess, which is
        # what produced a silent no-op on a real machine (oriel#1).
        $reason = 'no-json-assignment'
        if (-not (Test-ReadsStandardInput $text)) { $reason = 'no-stdin-source' }
        return [pscustomobject]@{
            Verdict = 'refuse'
            Reason  = $reason
            ScriptPath = $resolved.ScriptPath
            Variable = $null
            Command = $command
        }
    }

    [pscustomobject]@{
        Verdict = 'supported'
        Reason  = $null
        ScriptPath = $resolved.ScriptPath
        Variable = $anchor.Variable
        Command = $command
    }
}

# `statusLine` is an object with a `command`, but a bare string has been seen in the
# wild and costs one line to accept.
function script:Get-DeclaredCommand {
    param($Settings)
    if ($null -eq $Settings) { return $null }
    $prop = $Settings.PSObject.Properties['statusLine']
    if ($null -eq $prop -or $null -eq $prop.Value) { return $null }
    if ($prop.Value -is [string]) { return $prop.Value }
    $command = $prop.Value.PSObject.Properties['command']
    if ($null -eq $command) { return $null }
    return $command.Value
}

function Get-RefusalExplanation {
    <#
    .SYNOPSIS
        Plain English for why Oriel declined, in the user's terms rather than ours.
    #>
    param([string] $Reason, [string] $ScriptPath, [string] $Command)
    switch ($Reason) {
        'not-powershell' {
            "Your statusline is not a PowerShell script. Oriel's tee has to read the JSON " +
            "Claude Code pushes to your statusline, and it can only do that from inside a " +
            "PowerShell one.`r`n  Declared command: $Command"
        }
        'missing-file' {
            "Your settings declare a statusline at a path that does not exist, so there is " +
            "nothing to install into.`r`n  Declared command: $Command`r`n  Resolved to: $ScriptPath"
        }
        'no-json-assignment' {
            "Your statusline is PowerShell, but it never keeps the JSON Claude Code pushes " +
            "it in a variable — it reads standard input and passes it straight on. Standard " +
            "input can only be read once, so Oriel has nothing to borrow.`r`n  Statusline: $ScriptPath"
        }
        'no-stdin-source' {
            "Your statusline is PowerShell, but Oriel cannot see where it reads what Claude " +
            "Code pushes to it. It looks for a read of standard input — [Console]::In, " +
            "OpenStandardInput, `$input, or Get-Content with a bare dash — and then for the " +
            "line that parses it. Rather than patch a line it guessed at, Oriel has stopped " +
            "and changed nothing: a wrong guess here is silent, and would leave the widget " +
            "showing dashes forever.`r`n  Statusline: $ScriptPath"
        }
        default { "Oriel cannot install into this statusline." }
    }
}

function Get-ConversionPrompt {
    <#
    .SYNOPSIS
        Ready-made text the user pastes into Claude Code to convert their statusline
        into a **supported** one, so a refusal is a way forward and not a dead end.
    #>
    param([string] $ScriptPath)
    $target = $ScriptPath
    if ([string]::IsNullOrWhiteSpace($target)) { $target = '<your statusline script>' }
    @"
My Claude Code statusline is at:
  $target

Please rewrite it as a Windows PowerShell script that:
  1. reads all of standard input once, into a variable, e.g.
       `$raw = [Console]::In.ReadToEnd()
  2. assigns the parsed JSON to a variable on one line, from that variable, e.g.
       `$d = `$raw | ConvertFrom-Json
     (both halves matter — a tool needs a variable that still holds the JSON, because
     standard input can only be read once, and it has to be able to see that the JSON
     came from standard input rather than from a settings file or a cache);
  3. produces exactly the same output my current statusline produces;
  4. runs under Windows PowerShell 5.1 and is saved with a UTF-8 BOM.

Then update statusLine.command in my Claude Code settings to run it with
  pwsh -NoProfile -File "<the new path>"
(or powershell.exe if pwsh is not installed).
"@
}
