# The clean-room guard (ADR 0012, amended).
#
# The private working material — tickets, specs, research, agent skills, the
# agent-workflow docs, the project instructions that point at them — now shares this
# directory with the code instead of living in a second checkout that had to be copied
# from. That removed a manual copy step, and with it a class of mistake; what it
# introduced is a smaller one with a worse failure mode: a `git add -A` that publishes
# the working material, irreversibly, to a public repository.
#
# Five lines of .gitignore stand between those two outcomes. This is the test that says
# so out loud. It asserts both halves, because they fail differently:
#
#   1. Nothing private is TRACKED — the state that would actually publish.
#   2. The ignore rules still MATCH — an ignore rule for a path that has been renamed
#      away stops matching silently, and reports a clean repository forever.
#
# There is direct prior art for a meta-test over the repository: ShippedScripts and
# NoVacuousAssertions.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'PesterHelpers.ps1')
$script:Root = Split-Path -Parent $here

# Everything on the private side of the line. Kept as one list so the ignore rules and
# the tracked-file check can never disagree about what "private" means.
$script:PrivatePaths = @(
    '.workspace/scratch/some-feature/01-a-ticket.md',
    '.workspace/agents/skills/some-skill/SKILL.md',
    '.workspace/agents/docs/issue-tracker.md',
    '.workspace/CLAUDE.md',
    '.scratch/some-feature/01-a-ticket.md',
    '.agents/skills/some-skill/SKILL.md',
    '.claude/settings.json',
    '.claude/skills/some-skill/SKILL.md',
    'CLAUDE.md'
)

# The same set as patterns, for reading `git ls-files` output.
$script:PrivatePattern = '^(\.workspace/|\.scratch/|\.agents/|\.claude/|CLAUDE\.md$)'

function script:Invoke-Git {
    param([string[]] $Arguments)
    $out = & git -C $script:Root @Arguments 2>&1
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = @($out) }
}

Describe 'The private working material cannot be published from here' {

    It 'is being asked of a real git repository' {
        # A guard that cannot run must not report a clean repository. The whole point of
        # this file is the case where nobody is watching.
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            throw 'git not found — this guard cannot be honest without it.'
        }
        (script:Invoke-Git @('rev-parse', '--is-inside-work-tree')).Ok | Should Be $true
    }

    It 'tracks no private path' {
        $tracked = @((script:Invoke-Git @('ls-files')).Output | Where-Object { $_ -match $script:PrivatePattern })
        if ($tracked.Count -gt 0) {
            throw ((@(
                'These paths are TRACKED in the public repository and must not be:',
                '',
                'They are the private working material (ADR 0012). Committing them publishes',
                'tickets, research notes and working process to a public repository, and',
                'publishing is not reversible.',
                '',
                'Fix: git rm --cached <path> — and check .gitignore still covers it.',
                ''
            ) + $tracked) -join [Environment]::NewLine)
        }
        $tracked.Count | Should Be 0
    }

    It 'ignores every private path, whether or not one happens to exist right now' {
        # check-ignore answers about the RULES, not about the disk, which is what makes
        # this survive a fresh clone that has no .workspace/ in it yet.
        $notIgnored = @()
        foreach ($path in $script:PrivatePaths) {
            if (-not (script:Invoke-Git @('check-ignore', '-q', '--no-index', $path)).Ok) { $notIgnored += $path }
        }
        if ($notIgnored.Count -gt 0) {
            throw ((@(
                'These private paths are NOT covered by .gitignore:',
                '',
                'An ignore rule for a path that was renamed away stops matching in silence,',
                'and this guard would then pass forever while the material sat one `git add`',
                'from being published.',
                ''
            ) + $notIgnored) -join [Environment]::NewLine)
        }
        $notIgnored.Count | Should Be 0
    }

    It 'does not ignore the code it is supposed to be publishing' {
        # The mirror of the rule above. An over-broad pattern — `*.md`, or a bare
        # `claude*` — would satisfy every assertion here by excluding the repository.
        foreach ($path in @('README.md', 'CONTEXT.md', 'src/tee/Write-UsageState.ps1',
                            'src/install/Install-Oriel.ps1', 'tests/CleanRoom.Tests.ps1',
                            'docs/adr/0012-distribution-installer-and-one-liner.md')) {
            (script:Invoke-Git @('check-ignore', '-q', '--no-index', $path)).Ok | Should Be $false
        }
    }

    It 'still ships the whole repository it is guarding' {
        # If the ignore rules ever swallowed the project, every other assertion here
        # would pass. 60-odd files is the shape of this repository; the exact number is
        # not the point, its order of magnitude is.
        $tracked = @((script:Invoke-Git @('ls-files')).Output)
        $tracked.Count | Should BeGreaterThan 50
        ($tracked -contains 'src/tee/Write-UsageState.ps1') | Should Be $true
        ($tracked -contains 'installer/Oriel.iss') | Should Be $true
    }

    It 'detects a private path that IS tracked, when there is one to detect' {
        # The detector, proven on a repository built to fail it — because a matcher that
        # has quietly stopped matching is exactly the failure this file exists to catch.
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('oriel-cleanroom-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $tmp '.scratch') -Force | Out-Null
        try {
            [System.IO.File]::WriteAllText((Join-Path $tmp '.scratch\leak.md'), 'a private ticket')
            & git -C $tmp init -q 2>&1 | Out-Null
            & git -C $tmp add -A 2>&1 | Out-Null
            $tracked = @(& git -C $tmp ls-files | Where-Object { $_ -match $script:PrivatePattern })
            $tracked.Count | Should Be 1
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
