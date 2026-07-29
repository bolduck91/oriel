# Normalized-record builder for Oriel (ticket 01 / ADR 0002).
#
# Turns the full statusline JSON Claude Code pipes on stdin into the small,
# widget-owned normalized record, or returns $null when the data isn't there.
# The $null return is the enforcement point for the "never-tee-nulls" guarantee
# (ADR 0002): if rate_limits or either window is absent this render, the caller
# writes nothing and the last-known-good record stays intact.
#
# Pure and side-effect-free by design so it can be unit-tested without touching
# the filesystem. The atomic write lives alongside it in Write-UsageState.ps1.

Set-StrictMode -Version Latest

# Read a property by name, returning $null if it's absent. Needed because
# Set-StrictMode -Version Latest throws on references to non-existent properties,
# and an absent window/field is exactly the "write nothing" case we must tolerate.
function script:Get-Prop {
    param($object, [string]$name)
    if ($null -eq $object) { return $null }
    $prop = $object.PSObject.Properties[$name]
    if ($null -eq $prop) { return $null }
    $prop.Value
}

# Return the numeric value only when the property is genuinely present.
# A real 0 must survive (0% used is a fact, not a missing datum); $null / '' /
# absent must fail. Returns $null to signal "absent".
function script:Get-PresentNumber {
    param($value)
    if ($null -eq $value) { return $null }
    if ($value -is [string] -and $value.Trim() -eq '') { return $null }
    $out = 0.0
    if ([double]::TryParse([string]$value, [ref]$out)) { return $out }
    return $null
}

# Pull one window ({ used_percentage, resets_at }) from the rate_limits node.
# Returns $null if the window, its used_percentage, or its resets_at is absent.
function script:Get-Window {
    param($window)
    if ($null -eq $window) { return $null }
    $pct   = script:Get-PresentNumber (script:Get-Prop $window 'used_percentage')
    $reset = script:Get-PresentNumber (script:Get-Prop $window 'resets_at')
    if ($null -eq $pct -or $null -eq $reset) { return $null }
    [pscustomobject]@{
        used_percentage = $pct
        resets_at       = [long]$reset
    }
}

function ConvertTo-UsageRecord {
    <#
    .SYNOPSIS
        Build the normalized widget record from statusline JSON, or $null if the
        rate-limit data isn't present this render.
    .PARAMETER StatusJson
        The object produced by piping Claude Code's statusline JSON through
        ConvertFrom-Json.
    .PARAMETER Now
        Unix-epoch seconds to stamp as written_at (injected for testability).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $StatusJson,

        [Parameter(Mandatory = $true)]
        [long] $Now
    )

    if ($null -eq $StatusJson) { return $null }

    # rate_limits is absent until the first API response of a session and only
    # exists for Pro/Max accounts — treat any missing piece as "write nothing".
    $rl = $StatusJson.PSObject.Properties['rate_limits']
    if ($null -eq $rl -or $null -eq $rl.Value) { return $null }

    $five  = script:Get-Window (script:Get-Prop $rl.Value 'five_hour')
    $seven = script:Get-Window (script:Get-Prop $rl.Value 'seven_day')
    if ($null -eq $five -or $null -eq $seven) { return $null }

    [pscustomobject]@{
        five_hour  = $five
        seven_day  = $seven
        written_at = $Now
    }
}
