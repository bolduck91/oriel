# Run the whole suite: the xUnit tests over the C# logic that drives the widget,
# then the Pester tests over the PowerShell tee. Non-zero exit if anything fails.
#
# Two languages, one per half (ADR 0008): the widget is C#, the tee stays PowerShell
# because it is the ToS-clean half and had no reason to move.
#
# There are no headless UI smokes any more. The ones that existed constructed the
# retired WPF window, so they tested code nothing runs — which flattered the suite.
# What they were really guarding lives in tests/app/ now: single-instance in
# SingleInstanceTests, preference round-tripping in ConfigTests.
#
# Their loss did leave one hole worth naming: nothing else here compiles the UI half,
# because tests/app links Core.cs alone and references no Avalonia. So the run starts
# by compiling the widget. It does not exercise the window — it only refuses to report
# a green suite over code that no longer builds.
#
# Since ticket 07 that is no longer the whole story: tests/ui does exercise the render
# path — the four skins, the right-click menu, the preference round-trip and the shadow
# geometry — on a headless Avalonia platform. It stays a separate project so tests/app
# can go on running with no Avalonia at all.

Set-StrictMode -Version Latest
$here = $PSScriptRoot
$fail = 0

Write-Host '=== compile the widget (build gate) ===' -ForegroundColor Cyan
& pwsh -NoProfile -File (Join-Path $here 'Compile-App.ps1')
if ($LASTEXITCODE -ne 0) { $fail++; Write-Host 'Widget compile FAILED' -ForegroundColor Red }

Write-Host '=== xUnit core tests (C#) ===' -ForegroundColor Cyan
& pwsh -NoProfile -File (Join-Path $here 'Run-CoreTests.ps1')
if ($LASTEXITCODE -ne 0) { $fail++; Write-Host 'Core tests FAILED' -ForegroundColor Red }

Write-Host '=== xUnit UI tests (C#, headless Avalonia) ===' -ForegroundColor Cyan
& pwsh -NoProfile -File (Join-Path $here 'Run-UiTests.ps1')
if ($LASTEXITCODE -ne 0) { $fail++; Write-Host 'UI tests FAILED' -ForegroundColor Red }

Write-Host '=== Pester unit tests ===' -ForegroundColor Cyan
# A Pester run that dies outright returns nothing rather than a result with failures,
# and under StrictMode reading .FailedCount off that null is a non-terminating error —
# so without this guard a crashed run would report SUITE PASSED.
$unit = Invoke-Pester -Path $here -PassThru
if (-not $unit) {
    $fail++
    Write-Host 'Pester produced no result (the run itself failed)' -ForegroundColor Red
} else {
    if ($unit.FailedCount -gt 0) { $fail += $unit.FailedCount }
    Write-Host ("Pester: Passed={0} Failed={1}" -f $unit.PassedCount, $unit.FailedCount)
}

Write-Host ''
if ($fail -gt 0) { Write-Host "SUITE FAILED ($fail failure groups)" -ForegroundColor Red; exit 1 }
Write-Host 'SUITE PASSED' -ForegroundColor Green
exit 0
