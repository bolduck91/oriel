# The tee: statusline side-effect that writes the normalized record to the state
# file (ticket 01 / ADR 0002).
#
# Contract:
#   - never-tee-nulls  : if the rate-limit data is absent this render, write
#                        nothing and leave the last-known-good record intact.
#   - last-write-wins  : the newest real record replaces the old one.
#   - atomic           : temp file + Move-Item -Force so the widget never reads
#                        a half-written file.
#   - fail-silent      : the *caller* wraps this in try/catch; it is a side
#                        effect of statusline rendering and must never break the
#                        status line's actual output.
#
# Guardrail (ADR 0002 / ticket 01): this file must never reach the network. It
# only reshapes and persists the JSON Claude Code already pushed on stdin. Do not
# add a call to GET /api/oauth/usage or any other fetch here.

# Nothing at file scope may change how the caller behaves. This file is dot-sourced
# from inside somebody else's statusline, and a bare `.` runs it in THAT script's
# scope — so a `Set-StrictMode -Version Latest` here is not a setting for the tee, it
# is a setting for the rest of the user's statusline. It was one, and it broke their
# rendering: from the managed block down, every read of an optional key threw instead
# of yielding $null, on precisely the accounts with no rate-limit data to show (field
# report, oriel#1). Strict mode now lives inside the functions, where it belongs, and
# the caller's scope is left exactly as it was found.

. (Join-Path $PSScriptRoot 'Normalize.ps1')
. (Join-Path $PSScriptRoot 'AtomicWrite.ps1')

function Write-UsageState {
    <#
    .SYNOPSIS
        Tee the normalized rate-limit record to current.json, atomically, only
        when the data is present.
    .OUTPUTS
        [bool] $true if a record was written, $false if there was nothing real
        to write (never-tee-nulls) — the previous file is left untouched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $StatusJson,

        # ORIEL_STATE_DIR redirects the write. It exists for one caller: the
        # installer's post-patch verification, which triggers a real render to see
        # whether data actually flows (ticket 06). Without it that probe would land
        # its synthetic percentages in the user's real current.json and show them
        # numbers that were never true.
        [Parameter()]
        [string] $StateDir = $(
            if ($env:ORIEL_STATE_DIR) { $env:ORIEL_STATE_DIR } else { Join-Path $HOME '.claude/oriel' }
        ),

        [Parameter()]
        [long] $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    )

    # Inside the function, so it applies to this call and its callees and to nothing
    # else. See the note at the top of the file.
    Set-StrictMode -Version Latest

    $record = ConvertTo-UsageRecord -StatusJson $StatusJson -Now $Now
    if ($null -eq $record) { return $false }   # never-tee-nulls

    # Atomic + PID-scoped temp so a concurrent session's write and the widget's
    # read never tear. (config.json is written by the widget itself, in C#, and
    # does not come through here — it did before the Avalonia migration.)
    Write-JsonAtomic -Object $record -Path (Join-Path $StateDir 'current.json') -Depth 5 -Compress

    return $true
}
