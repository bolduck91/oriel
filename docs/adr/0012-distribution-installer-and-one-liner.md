# Distribution: a public repo, an Inno Setup installer, and our own one-liner

Until now Oriel was installed by cloning the repo and running a script, which only
works for its author. It ships instead as **a signed-in-the-future `OrielSetup.exe`
from a public GitHub repo**, plus a one-line PowerShell install for people who prefer
a terminal. Both drive the same code.

**The repo is published clean-room**: a new public repo (`bolduck91/oriel`, MIT)
whose first commit is the initial release, with the private workspace — tickets,
research, prototypes — left behind. The history is not sensitive so much as it is
*working material*, and publishing is not reversible. Code, `docs/` and `CONTEXT.md`
cross over; the handful of ADR links into the old workspace become plain references.

## Amendment, 2026-07-29: one working directory, two repositories

Clean-room publication was a decision about **the initial publication of pre-launch
history**, and that has happened. It was read afterwards as a standing arrangement —
two live checkouts of the same code, private material in one of them, changes copied
across by hand to publish. Fixing oriel#1 is what priced that reading: eleven files
hand-copied, eleven files hand-verified against the pre-fix versions, and the leak
checks in `docs/releasing.md` read by a person off a console. None of it was hard and
all of it was a chance to publish the wrong bytes or to miss that the two copies had
diverged. Merges land on the public side now, so the private copy could go stale
without anything saying so.

So there is one working directory: the public clone. The private material lives inside
it in `.workspace/`, **its own git repository with its own private remote**, ignored by
the public one. The properties that mattered are kept and the copy step is gone:

- `git ls-files` in the public repository cannot see the private material, which is the
  same guarantee the staging copy gave — enforced now by `tests/CleanRoom.Tests.ps1`
  rather than by remembering to run a checklist.
- The pre-launch history stays unpublished: it is still in the original private
  repository, which is now an archive and not a working copy.
- Tickets and code are separate histories, deliberately. A ticket is working material
  and does not belong in a public log.

What it costs, stated plainly: a careless `git add -A` in the public repository could
publish `.workspace/` irreversibly. Five lines of `.gitignore` prevent it and a test
asserts both that nothing private is tracked *and* that those five lines still match
something — because an ignore rule for a path that has been renamed away fails silently
and reports a clean repository forever.

## The exe alone was never an installation

The widget reads the state file; the state file is written by the tee; the tee only
exists once a statusline has been patched. So "download the exe and run it" produced
a widget that shows dashes forever — not a lightweight install, a trap. Whatever
ships must install **widget + tee + statusline patch** or it has not installed
anything.

## Inno Setup, because the valuable part is not the plumbing

The part of this that is ours — the **triage**, the consent screen that shows the
user exactly what will be changed in their statusline, the post-install verification
— is specific and delicate. Everything else (an uninstaller, the Add/Remove Programs
entry, shortcuts, a directory page) is twenty-year-old solved Windows plumbing. Inno
Setup provides the second for free and calls into our own code for the first. Writing
a bespoke installer in Avalonia would have bought a prettier consent screen at the
price of hand-rolling an uninstaller, which is exactly the component whose bugs are
unreachable once a user has run it.

Install is **per-user**, into `%LOCALAPPDATA%\Programs\Oriel`, with a custom-path
field for anyone who wants elsewhere. Per-user needs no elevation, and so never shows
the UAC shield — the screen that stops the non-technical user this installer exists
to serve. It also matches the app, which keeps its state and preferences in the
user's profile and registers startup per-user.

## Considered and rejected: winget

The conventional Windows answer is to publish `setup.exe` and let `winget install`
be the one-liner. It is strictly better on the merits — no remote code executed
unread, `winget upgrade` for free, uninstall through the same uninstaller — and a
winget manifest is exactly this design with Microsoft's implementation of the silent
install. It was rejected **only for now**, because publication goes through a
reviewed pull request against `microsoft/winget-pkgs` and the first release should
not wait on someone else's queue. Nothing here forecloses it: the manifest would
point at the same `OrielSetup.exe`.

So the one-liner is ours (`irm … | iex`), and it downloads that same installer and
drives it silently, taking consent in the terminal. **There is one implementation of
the risky half and two front ends** — not two installers that will drift.

## Consequences

- **No code signing at launch.** SmartScreen will show "Windows protected your PC" to
  every downloader, and the README must document the two clicks rather than pretend
  otherwise. This costs exactly the audience the installer was built for, and is
  accepted as a launch compromise, not a permanent position.
- **Update checking is now Oriel's problem**, since winget is not carrying it. The
  widget asks the GitHub releases API at startup and surfaces "a new version exists";
  it downloads nothing and replaces nothing. This is the first time any part of this
  project touches the network — a project whose tee carries an explicit never-reach-
  the-network guardrail (ADR 0002) — so it is announced during install and can be
  turned off. The guardrail it must not weaken is the one about Anthropic's API; a
  version check against GitHub is a different thing, but the distinction is only
  obvious to someone who reads this paragraph.
- **Releases are cut by hand** — `build.ps1`, then Inno, then upload — until the
  cadence justifies automating it.
