# Pester 3.4 tests for the build's SDK resolution (ticket 03).
#
# Why this has a test at all: on a machine where `dotnet` on PATH is a *runtime-only*
# install (very common — the Program Files host ships with plenty of apps), a bare
# `dotnet publish` fails with a message that reads like the project is broken.
# Picking the right host is the one piece of real logic in the build, so it gets a seam.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\src\build\DotnetSdk.ps1')

Describe 'Resolve-DotnetSdk' {
    It 'picks the first candidate that has a new-enough SDK' {
        $probe = {
            param($exe)
            switch ($exe) {
                'runtime-only' { @() }
                'has-eight'    { @('8.0.423 [C:\sdk]') }
                default        { @() }
            }
        }
        $r = Resolve-DotnetSdk -Candidate @('runtime-only', 'has-eight') -RequiredMajor 8 -Probe $probe
        $r | Should Be 'has-eight'
    }

    It 'skips a candidate whose SDK is too old' {
        $probe = {
            param($exe)
            switch ($exe) {
                'old' { @('6.0.428 [C:\sdk]') }
                'new' { @('8.0.423 [C:\sdk]') }
            }
        }
        $r = Resolve-DotnetSdk -Candidate @('old', 'new') -RequiredMajor 8 -Probe $probe
        $r | Should Be 'new'
    }

    It 'accepts an SDK newer than the required major' {
        $probe = { param($exe) @('10.0.100 [C:\sdk]') }
        $r = Resolve-DotnetSdk -Candidate @('modern') -RequiredMajor 8 -Probe $probe
        $r | Should Be 'modern'
    }

    It 'returns nothing when no candidate has an SDK' {
        $probe = { param($exe) @() }
        $r = Resolve-DotnetSdk -Candidate @('a', 'b') -RequiredMajor 8 -Probe $probe
        $r | Should BeNullOrEmpty
    }

    It 'ignores a candidate whose probe throws (missing exe)' {
        $probe = {
            param($exe)
            if ($exe -eq 'missing') { throw 'not found' }
            @('8.0.423 [C:\sdk]')
        }
        $r = Resolve-DotnetSdk -Candidate @('missing', 'present') -RequiredMajor 8 -Probe $probe
        $r | Should Be 'present'
    }

    It 'ignores unparseable probe output rather than crashing the build' {
        $probe = {
            param($exe)
            if ($exe -eq 'noisy') { @('', 'Welcome to .NET!') }
            else { @('8.0.423 [C:\sdk]') }
        }
        $r = Resolve-DotnetSdk -Candidate @('noisy', 'good') -RequiredMajor 8 -Probe $probe
        $r | Should Be 'good'
    }
}

Describe 'Build contract' {
    # These guard the ticket-03 promises that live in project settings rather than
    # in code, where a stray edit would break the launch story silently.
    $repo = Resolve-Path (Join-Path $here '..')
    $csproj = Get-Content (Join-Path $repo 'src\app\Oriel.csproj') -Raw

    It 'publishes a self-contained single file, so no runtime install is needed' {
        $csproj | Should Match '<SelfContained>true</SelfContained>'
        $csproj | Should Match '<PublishSingleFile>true</PublishSingleFile>'
    }
    It 'is a GUI binary, so launching shows no console window' {
        $csproj | Should Match '<OutputType>WinExe</OutputType>'
    }
    It 'git-ignores every build artefact' {
        $ignore = Get-Content (Join-Path $repo '.gitignore') -Raw
        $ignore | Should Match '(?m)^bin/$'
        $ignore | Should Match '(?m)^obj/$'
        $ignore | Should Match '(?m)^dist/$'
    }
    It 'has the one documented build command at the repo root' {
        Test-Path (Join-Path $repo 'build.ps1') | Should Be $true
    }
}

Describe 'Get-DotnetCandidate' {
    It 'lists the PATH host before the per-user install' {
        # PATH first so a properly set-up machine uses its own toolchain; the
        # per-user %LOCALAPPDATA% install is the fallback, not the preference.
        $c = Get-DotnetCandidate
        $c.Count | Should BeGreaterThan 1
        $c[0] | Should Be 'dotnet'
        ($c -join ';') | Should Match 'dotnet\.exe'
    }
}
