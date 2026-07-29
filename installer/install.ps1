<#
.SYNOPSIS
Install Oriel from a terminal, in one line.

.DESCRIPTION
    irm https://raw.githubusercontent.com/bolduck91/oriel/main/installer/install.ps1 | iex

This is the terminal front end. It downloads the SAME OrielSetup.exe the download page
offers, runs it without a window, and takes the same consent here in the console. There
is one implementation of the risky half and two front ends over it (ADR 0012), so what
you end up with is identical either way: the same install, the same documentation, the
same uninstall through Add/Remove Programs.

You are reading this because you fetched it before running it, which is the point. It
downloads one file, from one host, and runs it. It asks before changing your statusline
and shows you the exact text it would add. Nothing here needs administrator rights, and
nothing elevates.

.PARAMETER Version
A specific release tag. Defaults to the latest.

.PARAMETER Yes
Skip the consent prompt. For scripted installs where the operator has already read what
this does — the consent text is still printed.

.PARAMETER Dir
Install somewhere other than %LOCALAPPDATA%\Programs\Oriel.
#>
[CmdletBinding()]
param(
    [string] $Version = 'latest',
    [switch] $Yes,
    [string] $Dir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Repo = 'bolduck91/oriel'
$SetupName = 'OrielSetup.exe'

function Write-Step { param([string] $Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Bad  { param([string] $Text) Write-Host $Text -ForegroundColor Red }

# TLS 1.2 is not the default on Windows PowerShell 5.1, and the download fails with a
# connection error rather than anything that names the cause.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

if ($env:OS -ne 'Windows_NT') {
    Write-Bad 'Oriel is a Windows desktop widget; there is nothing here for this platform.'
    exit 1
}

# ---- fetch the same installer the download page offers ---------------------

Write-Step 'Finding the latest release'
$api = if ($Version -eq 'latest') {
    "https://api.github.com/repos/$Repo/releases/latest"
} else {
    "https://api.github.com/repos/$Repo/releases/tags/$Version"
}

try {
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'oriel-install' }
} catch {
    Write-Bad "Could not reach the release host: $($_.Exception.Message)"
    exit 1
}

$asset = $release.assets | Where-Object { $_.name -eq $SetupName } | Select-Object -First 1
if (-not $asset) {
    Write-Bad "Release $($release.tag_name) has no $SetupName to download."
    exit 1
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("oriel-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$setup = Join-Path $tmp $SetupName

try {
    Write-Step "Downloading $($release.tag_name)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $setup -UseBasicParsing

    # ---- lay down Oriel's own files, and nothing of the user's --------------
    #
    # /SKIPCONFIG runs the real installer — the same one the download page offers, with
    # its Start Menu shortcut and its Add/Remove Programs entry — but stops before the
    # step that reads or writes the user's configuration. That is what lets the consent
    # below be taken from the actual entry point at the actual version, rather than from
    # a second copy fetched separately that could drift from it.
    #
    # Nothing of the user's is touched at this point: this writes only into Oriel's own
    # install directory. If the consent below is declined, or triage refuses, the whole
    # thing is rolled back through the uninstaller before this script exits.

    Write-Step 'Installing files'
    $silentArgs = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SKIPCONFIG')
    if ($Dir) { $silentArgs += "/DIR=$Dir" }

    $proc = Start-Process -FilePath $setup -ArgumentList $silentArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Bad "The installer exited with code $($proc.ExitCode)."
        exit $proc.ExitCode
    }

    $installed = $Dir
    if (-not $installed) { $installed = Join-Path $env:LOCALAPPDATA 'Programs\Oriel' }
    $entry = Join-Path $installed 'install\Install-Oriel.ps1'
    $tee   = Join-Path $installed 'tee\Write-UsageState.ps1'
    $uninstaller = Get-ChildItem -LiteralPath $installed -Filter 'unins*.exe' -ErrorAction SilentlyContinue |
                   Select-Object -First 1

    function Undo-Everything {
        # Roll back to before this script ran. Only ever called while the user's own
        # configuration is still untouched.
        if ($uninstaller) {
            Start-Process -FilePath $uninstaller.FullName -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait
        }
    }

    if (-not (Test-Path -LiteralPath $entry)) {
        Write-Bad 'The installer did not put the expected files in place.'
        Undo-Everything
        exit 1
    }

    # ---- consent, in the console -------------------------------------------
    #
    # The wizard shows the block on a page; here it goes to the terminal. Same text,
    # same refusal, same right to say no with nothing changed.

    Write-Step 'Checking what would change'
    $report = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry `
        -Action triage -TeePath $tee -Json | Out-String
    $triage = $null
    try { $triage = $report | ConvertFrom-Json } catch { }

    if ($null -eq $triage) {
        Write-Bad 'Could not read your Claude Code settings.'
        Undo-Everything
        exit 1
    }

    if ($triage.verdict -eq 'refuse') {
        # A refusal is a way forward, not a dead end: it comes with the text to paste.
        Write-Host ''
        Write-Bad 'Oriel did not install. Nothing on your disk was changed.'
        Write-Host ''
        Write-Host $triage.message -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Paste this into Claude Code to convert your statusline, then run this again:' -ForegroundColor Cyan
        Write-Host ''
        Write-Host $triage.conversionPrompt
        Undo-Everything
        exit 2
    }

    Write-Host ''
    Write-Host $triage.message -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'It will add exactly this to your statusline, and change nothing else:' -ForegroundColor Gray
    Write-Host ''
    Write-Host $triage.block
    Write-Host ''
    Write-Host 'Oriel also checks once at startup whether a newer version exists. It downloads' -ForegroundColor Gray
    Write-Host 'nothing, and you can switch the check off from the widget''s right-click menu.' -ForegroundColor Gray
    Write-Host ''

    if (-not $Yes) {
        $answer = Read-Host 'Install Oriel? [y/N]'
        if ($answer -notmatch '^(y|yes)$') {
            Write-Host 'Nothing was changed.' -ForegroundColor Gray
            Undo-Everything
            exit 0
        }
    }

    # ---- the half that touches the user's configuration --------------------
    #
    # Exactly what the wizard runs from its own post-install step: triage, patch or
    # starter statusline, then verification. Success is not printed unless it says so.

    Write-Step 'Setting up your statusline'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action install -TeePath $tee
    $installExit = $LASTEXITCODE
    if ($installExit -eq 2) { Undo-Everything; exit 2 }
    if ($installExit -ne 0) { exit $installExit }

    Write-Host ''
    Write-Host "Oriel is installed at $installed" -ForegroundColor Green
    Write-Host '  Start it from the Start Menu, or:' -ForegroundColor Gray
    Write-Host "    & '$installed\Oriel.exe'"
    Write-Host '  Uninstall it from Add/Remove Programs, like any other program.' -ForegroundColor Gray
}
finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
