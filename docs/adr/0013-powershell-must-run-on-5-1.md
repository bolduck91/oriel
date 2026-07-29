# PowerShell Oriel writes must run on 5.1, and must carry a UTF-8 BOM

Every `.ps1` Oriel puts on a user's disk — the **tee** and the **starter statusline**
— must run under **Windows PowerShell 5.1** and must be saved **with a UTF-8 BOM**.

**Why 5.1 and not just `pwsh`:** PowerShell 7 is not part of Windows. Windows ships
5.1 only. And in the injection case the tee does not get to choose its host at all —
it runs inside whatever interpreter the user's own statusline was already declared
with, which may well be 5.1. The tee was verified against it: it writes a byte-identical
normalized record under `PSVersion 5.1.26100.8875`.

**Why the BOM, which is the part that will get "cleaned up" one day:** 5.1 reads a
`.ps1` without a BOM as ANSI, not UTF-8. The starter statusline contains non-ASCII
glyphs (`█ ░ ◯ ◕`), so without a BOM those bytes are mis-decoded and the file does not
merely render wrong — **it fails to parse**:

```
Jeton inattendu « â—• » dans l'expression ou l'instruction.
```

Adding the BOM makes the same file parse and render correctly under both 5.1 and 7.
The failure is total, silent from the user's side (a statusline that emits nothing),
and invisible on any machine that has PowerShell 7 — which is every machine this is
developed on. That combination is why it is written down and guarded by a test rather
than left as a comment.

The starter statusline is declared with `pwsh` when it is present and `powershell.exe`
otherwise, so users get the better engine when they have it. That is a preference;
5.1 compatibility is the floor beneath it.
