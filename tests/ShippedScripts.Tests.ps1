# The repository-wide guard for ADR 0013 (oriel-distribution ticket 05).
#
# Every .ps1 Oriel puts on a user's disk must carry a UTF-8 BOM and must parse under
# Windows PowerShell 5.1. This is the only thing standing between that decision and a
# future cleanup that silently breaks every user without PowerShell 7.
#
# Why it has to be a test and not a comment: 5.1 reads a BOM-less .ps1 as ANSI, so the
# starter statusline's glyphs (█ ░ ◯ ◕) are mis-decoded and the file does not render
# wrong — it FAILS TO PARSE. The failure is total, silent from the user's side (a
# statusline that emits nothing), and invisible on every machine this is developed on,
# because those all have pwsh. Nothing about that combination is catchable by eye.
#
# There is direct prior art for a meta-test over the repository: NoVacuousAssertions.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'PesterHelpers.ps1')
$script:Root = Split-Path -Parent $here

# What lands on a user's disk. The tee is dot-sourced by the managed block inside the
# user's own statusline; the installer half is copied into the install directory and is
# what the uninstaller runs. The build helpers and the tests are neither, and are not
# listed.
$script:WrittenDirs = @(
    (Join-Path $script:Root 'src\tee'),
    (Join-Path $script:Root 'src\install')
)

# The one-line install is fetched and piped straight into the interpreter — it is never
# written to disk, so it is held to the 5.1 rule and deliberately NOT to the BOM one: a
# leading U+FEFF arriving as the first character of a string handed to Invoke-Expression
# is a parse error, so a BOM here would break the very path it is meant to protect.
$script:PipedDirs = @(
    (Join-Path $script:Root 'installer')
)

function script:Get-Scripts {
    param([string[]] $Dirs)
    $found = @()
    foreach ($dir in $Dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $found += Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.ps1' -File
    }
    return $found
}

function script:Get-ShippedScripts { script:Get-Scripts -Dirs $script:WrittenDirs }
function script:Get-AllPowerShell  { script:Get-Scripts -Dirs ($script:WrittenDirs + $script:PipedDirs) }

function script:Test-HasBom {
    param([string] $Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

# Parsing is delegated to the 5.1 engine itself rather than to this process's parser.
# The two disagree on exactly the thing that matters: PowerShell 7 decodes a BOM-less
# file as UTF-8 and parses it happily, which is why the bug survived to become an ADR.
function script:Test-ParsesUnder51 {
    param([string] $Path)
    $probe = @'
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($env:ORIEL_PARSE_TARGET, [ref]$null, [ref]$errors)
if ($errors.Count -gt 0) { $errors[0].Message; exit 1 }
exit 0
'@
    $previous = $env:ORIEL_PARSE_TARGET
    $env:ORIEL_PARSE_TARGET = $Path
    try {
        $out = & powershell.exe -NoProfile -NonInteractive -Command $probe 2>&1
        [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Detail = ($out | Out-String).Trim() }
    } finally {
        $env:ORIEL_PARSE_TARGET = $previous
    }
}

Describe 'Every script Oriel writes to a user disk' {

    It 'finds the scripts it is supposed to be guarding' {
        # A guard that silently stops matching anything reports a clean repository
        # forever. Both halves must be present.
        # Not `Should Contain`: in Pester 3.4 that asserts a FILE contains text, and
        # would read every name here as a path.
        $names = @(script:Get-ShippedScripts | ForEach-Object { $_.Name })
        ($names -contains 'Write-UsageState.ps1') | Should Be $true
        ($names -contains 'starter-statusline.ps1') | Should Be $true
    }

    It 'carries a UTF-8 BOM' {
        $bad = @()
        foreach ($f in script:Get-ShippedScripts) {
            if (-not (script:Test-HasBom $f.FullName)) { $bad += $f.FullName }
        }
        if ($bad.Count -gt 0) {
            throw ((@(
                "These files ship to a user's disk without a UTF-8 BOM (ADR 0013).",
                "Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI. Non-ASCII bytes are then",
                "mis-decoded and the file fails to PARSE — silently, and only on machines without",
                "PowerShell 7, which is no machine this is developed on.",
                "Fix: rewrite with [System.Text.UTF8Encoding]::new(`$true).",
                ""
            ) + $bad) -join [Environment]::NewLine)
        }
        $bad.Count | Should Be 0
    }

    It 'is not given a BOM where a BOM would break it' {
        # The mirror of the rule above, and the reason the two lists are separate: the
        # one-line install is piped into Invoke-Expression, where a leading U+FEFF is a
        # parse error rather than an invisible header.
        foreach ($f in (script:Get-Scripts -Dirs $script:PipedDirs)) {
            script:Test-HasBom $f.FullName | Should Be $false
        }
    }

    It 'parses under Windows PowerShell 5.1' {
        $ps51 = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue
        if (-not $ps51) { throw 'powershell.exe not found — this guard cannot be honest without it.' }

        $bad = @()
        foreach ($f in script:Get-AllPowerShell) {
            $result = script:Test-ParsesUnder51 $f.FullName
            if (-not $result.Ok) { $bad += ("{0}: {1}" -f $f.Name, $result.Detail) }
        }
        if ($bad.Count -gt 0) {
            throw ((@("These files do not parse under Windows PowerShell 5.1 (ADR 0013):", "") + $bad) -join [Environment]::NewLine)
        }
        $bad.Count | Should Be 0
    }

    # The guard is only worth anything if it can see the thing it is looking for.
    It 'detects a missing BOM when there is one to detect' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("oriel-bom-" + [guid]::NewGuid().ToString('N') + '.ps1')
        [System.IO.File]::WriteAllText($tmp, "Write-Host 'hi'", [System.Text.UTF8Encoding]::new($false))
        try { script:Test-HasBom $tmp | Should Be $false } finally { Remove-Item -LiteralPath $tmp -Force }
    }

    It 'detects a 5.1 parse failure when there is one to detect' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("oriel-parse-" + [guid]::NewGuid().ToString('N') + '.ps1')
        # Valid on 7, a parse error on 5.1: the null-coalescing operator arrived in 7.
        [System.IO.File]::WriteAllText($tmp, "`$x = `$null`r`n`$y = `$x ?? 'fallback'`r`n", [System.Text.UTF8Encoding]::new($true))
        try { (script:Test-ParsesUnder51 $tmp).Ok | Should Be $false } finally { Remove-Item -LiteralPath $tmp -Force }
    }
}
