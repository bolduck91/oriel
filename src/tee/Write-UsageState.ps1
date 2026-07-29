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

Set-StrictMode -Version Latest

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

    $record = ConvertTo-UsageRecord -StatusJson $StatusJson -Now $Now
    if ($null -eq $record) { return $false }   # never-tee-nulls

    # Atomic + PID-scoped temp so a concurrent session's write and the widget's
    # read never tear. (config.json is written by the widget itself, in C#, and
    # does not come through here — it did before the Avalonia migration.)
    Write-JsonAtomic -Object $record -Path (Join-Path $StateDir 'current.json') -Depth 5 -Compress

    return $true
}
