# Atomic JSON write used by the tee to publish current.json.
#
# The state file is read by a live widget while the tee writes it, so it needs a
# guarantee that a reader never sees a half-written file. Write to a PID-scoped
# temp file, then Move-Item -Force — the move is the atomic step.
#
# (config.json is written by the widget itself, in C#, and does not come through
# here — it did before the Avalonia migration, which is why this file used to
# claim both.)
#
# The temp file is also the failure mode: it is created by one statement and
# removed by another, so anything that stops the process in between strands it on
# disk forever. Hence the cleanup below (ticket 09) — on failure for our own temp,
# and on a later write for temps whose session never came back.

# Strict mode is set inside the functions, not here: this file is reached by a
# dot-source from inside the user's statusline, and at file scope the setting would
# land in their scope rather than ours (see the note in Write-UsageState.ps1).

# How long a temp must sit untouched before a later write treats it as abandoned.
# An hour is far longer than any write takes, which is the point: the risk to
# manage is deleting a *live* temp out from under a concurrent session, not
# leaving a dead one around for one more write.
$script:DefaultOrphanTempSeconds = 3600

function Remove-OrphanedTemp {
    <#
    .SYNOPSIS
        Collect temp files stranded by sessions that died mid-write.
    .DESCRIPTION
        Age is the only criterion. The tempting alternative — "delete temps whose
        PID is no longer running" — is wrong in both directions: PIDs are reused,
        so a live unrelated process makes a dead temp look owned, and a recycled
        PID makes a live temp look collectable. Time since last write is the one
        signal that does not lie.

        Best-effort by construction: this is a side effect of a side effect, and
        must never fail the write it accompanies.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][int]    $OlderThanSeconds
    )
    Set-StrictMode -Version Latest
    try {
        $dir  = Split-Path -Parent $Path
        $leaf = Split-Path -Leaf   $Path
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return }

        $cutoff = (Get-Date).AddSeconds(-$OlderThanSeconds)
        # Exactly the shape this writer produces: "<leaf>.<digits>.tmp". A
        # neighbouring file that merely ends in .tmp is somebody else's.
        $pattern = '^' + [regex]::Escape($leaf) + '\.\d+\.tmp$'

        Get-ChildItem -LiteralPath $dir -File -Filter '*.tmp' -ErrorAction Stop |
            Where-Object { $_.Name -match $pattern -and $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
    } catch {
        # A directory we cannot enumerate, a file held open by another session —
        # none of it is worth failing a write over.
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter()][int] $Depth = 5,
        [Parameter()][switch] $Compress,
        [Parameter()][int] $OrphanTempSeconds = $script:DefaultOrphanTempSeconds
    )
    Set-StrictMode -Version Latest
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $json = $Object | ConvertTo-Json -Depth $Depth -Compress:$Compress
    $tmp = "$Path.$PID.tmp"
    try {
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        # -ErrorAction Stop matters more than it looks: Move-Item fails
        # *non-terminating*, so without it a denied move would leave this function
        # returning as though it had written the record. The tee would report
        # success, the state file would still hold the old data, and the temp would
        # be stranded. A failed write must be a failed write.
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
    } catch {
        # Our own mess, and it must not outlive the attempt.
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }

    Remove-OrphanedTemp -Path $Path -OlderThanSeconds $OrphanTempSeconds
}

