# Oriel injects into a statusline, and never wraps one

The **tee** needs the JSON Claude Code pushes to the statusline. There are only two
ways to be handed it: **inject** a **managed block** into the user's statusline
script, or **wrap** — point `statusLine.command` at Oriel and have Oriel invoke the
user's original command. Oriel injects, and declines the users it cannot inject for.

**The deciding fact: wrapping puts Oriel on the critical path of a script it did not
write.** Injected, an Oriel that breaks degrades to "the widget has no data" — the
statusline still renders, because the block is fail-silent and the user's script is
untouched around it. Wrapped, an Oriel that breaks degrades to "the statusline is
gone", because Claude Code is calling a program that is no longer there. An unsigned
single-file .NET binary is a routine antivirus false-positive, so "no longer there"
is a real scenario, not a hypothetical one. The failure modes are not the same size,
and the thing at risk is something the user looks at all day.

The measured cost seals it: a statusline render already costs ~580 ms, almost all of
it process start (`powershell.exe` 584 ms median, `pwsh` 629 ms, five runs each).
Wrapping would add a second process of that order to every render.

## Why injection cannot be made universal

**Standard input can only be read once.** If the managed block reads it, the user's
script finds it empty and their statusline breaks — caused by us, which is the exact
outcome the decision above exists to avoid. So the block cannot fetch the JSON
itself; it can only borrow a variable that already holds it.

That is what makes a statusline **supported**: it is written in PowerShell, and it
keeps the pushed JSON in a variable (in practice, an assignment through
`ConvertFrom-Json`) that the block can be inserted after. A bash, Node or Python
statusline cannot be served this way at all; nor can a PowerShell one that pipes the
JSON straight through without keeping it.

## Three populations, two served

| What the user has | What Oriel does |
|---|---|
| No statusline | Writes a **starter statusline**, then injects into it |
| A **supported statusline** | Injects; their file is otherwise unchanged, byte for byte |
| Anything else | **Refuses**, and offers text to paste into Claude Code to convert it |

Writing a starter statusline is not a third mechanism — it produces an ordinary
supported statusline and then takes the ordinary path, so there is one injector and
one uninstaller. And it carries none of the risk above: there is nothing on the
critical path to displace when the path is empty.

## Consequences

- **Refusal must be loud.** The managed block is wrapped in `try/catch` by design, so
  a wrong guess about the shape fails *silently* and leaves a widget that shows
  nothing forever. The installer therefore verifies after patching — it triggers a
  render and waits for the state file to appear — and reports a diagnosis rather than
  declaring success it has not observed.
- **Uninstall removes the block, never the file.** Restoring the pre-install backup
  wholesale would destroy months of unrelated edits the user made to their own
  statusline. The backup stays a safety net for a failed removal, not the method.
- Supporting foreign statuslines is not closed forever — it is closed until someone
  finds a way to hand the tee its JSON without standing between Claude Code and the
  user's script.
