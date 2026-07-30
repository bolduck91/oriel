# Cutting a release

Releases are cut by hand — build, package, upload — until the cadence justifies
automating it (ADR 0012). This is the whole process.

## 1. Set the version

`src/app/Oriel.csproj` → `<Version>`. That is the only place a version is written: the
widget reads it back off its own assembly for the update check, and the Inno script
reads it out of the built executable. Nothing else needs editing.

## 2. Build and test

```powershell
pwsh -NoProfile -File build.ps1
pwsh -NoProfile -File tests/Run-AllTests.ps1
```

## 3. Package the installer

```powershell
iscc installer\Oriel.iss
```

Produces `dist\OrielSetup.exe`. Needs [Inno Setup 6](https://jrsoftware.org/isdl.php).

## 4. Verify by hand

**The wizard is the part of this feature that is not automatically tested**, stated
plainly rather than papered over. Everything that touches a user's configuration lives
behind `src/install/Install-Oriel.ps1` and is covered by
`tests/InstallOriel.Tests.ps1`; what is left here is the Inno half, and it is checked
by a person once per release.

On a real machine — ideally one that is not the development machine, and for at least
one release on an account without administrator rights:

- [ ] Double-clicking `OrielSetup.exe` opens the wizard. **No UAC shield appears at any
      point.** (This is the one that matters most: the shield stops exactly the person
      this installer exists to serve.)
- [ ] The default location is filled in and needs no decision. A typed custom path is
      accepted and used.
- [ ] The consent page shows the **literal text** that will be added to the statusline.
- [ ] Going Back or Cancelling from the consent page leaves the statusline, the Claude
      Code settings and the disk unchanged.
- [ ] On a machine with an unsupported statusline, the wizard **surfaces the refusal**,
      the conversion text is readable and selectable, and Next does not proceed.
- [ ] Success is only reported after verification passed. (To exercise the failure path,
      point `statusLine.command` at a PowerShell script that keeps the JSON but exits
      before the block runs — the wizard must report a diagnosis, not a checkmark.)
- [ ] A Start Menu shortcut exists and launches the widget.
- [ ] An Add/Remove Programs entry exists, named Oriel, with the right version.
- [ ] The finish page's "Launch Oriel now" works.
- [ ] Uninstalling from Add/Remove Programs asks whether to keep a starter statusline,
      removes the managed block, and removes the program.
- [ ] Installing twice replaces the block rather than stacking a second one.

And the terminal path, which shares everything below the front end but not the front
end itself:

- [ ] `irm <raw install.ps1 url> | iex` installs widget, tee and statusline patch.
- [ ] No window appears at any point.
- [ ] Answering `n` at the prompt leaves the disk as it was.
- [ ] A refusal prints with its conversion text and leaves nothing behind.
- [ ] The result uninstalls through Add/Remove Programs like the wizard's.

## 5. Publish

### The clean-room line, and what watches it now

Publishing is not reversible, which is why the private working material has never been in
this repository's history (ADR 0012). Since the 2026-07-29 amendment there is **no staging
copy and no second checkout**: the private material sits beside the code in `.workspace/`,
its own git repository with its own private remote, git-ignored here. Releasing involves no
copying, and nothing on this checklist is what stands between working notes and a public
repository.

`tests/CleanRoom.Tests.ps1` is. It runs with the rest of the suite in step 2 and asserts
that nothing private is tracked, that every private path is still covered by `.gitignore`,
and — the half that is easy to forget — that the ignore rules have not grown so broad that
they exclude the project itself. The checklist that used to live here was read by a person
off a console; a check that quietly matches nothing reports a clean repository forever.
Two traps hit while writing that checklist, kept because they are worth knowing when
writing the next such check:

- `Get-ChildItem -Recurse -Include '*.md'` **skips files sitting directly under
  `-Path`** unless the path ends in `\*`. Filter on `.Extension` instead.
- `Select-String -SimpleMatch '\.scratch'` searches for a literal *backslash* followed
  by `.scratch`, so it matches almost nothing. Either drop `-SimpleMatch` and keep the
  regex, or drop the escape.

One thing a test cannot judge is prose. A *link* into `.workspace/` from a published
document would dangle in public, while a sentence *about* the private workspace is
expected and correct — so read what this returns rather than counting it:

```powershell
Get-ChildItem -Recurse -File |
    Where-Object { $_.Extension -in '.md', '.ps1', '.cs', '.iss' -and $_.FullName -notmatch '\\\.workspace\\' } |
    Select-String -Pattern '\]\([^)]*\.workspace|\]\([^)]*\.scratch'
```

### Every time

1. Tag: `git tag v<version> && git push --tags`
2. Create the GitHub release for that tag.
3. Attach `dist\OrielSetup.exe` — the asset **must** be named `OrielSetup.exe`, because
   the one-line install looks it up by that name.
4. Paste the changelog.

The widget's update check reads `tag_name` from the latest release, so the tag has to
be a readable version (`v1.2.3` or `1.2.3`). A tag it cannot parse is treated as no
news at all and nobody is told anything.

## Note on signing

The installer is unsigned, which is an accepted launch compromise rather than a
permanent position (ADR 0012). Every downloader will see SmartScreen's "Windows
protected your PC" screen, so the README documents the two clicks past it. Revisiting
this means pricing and eligibility work, not code.
