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

**The variable must be the one holding what arrived on standard input, and that has
to be established rather than assumed.** `ConvertFrom-Json` says nothing about which
JSON is being parsed: a statusline that reads its own settings, a cache or `git`
output through it is completely ordinary, and one shipped that way to a real user
(oriel#1) — v1.0.0 anchored on the first conversion in the file, borrowed a variable
holding `settings.json`, and wrote nothing on every render, silently and forever. So
the anchor is found by lineage: locate the read of standard input, follow the
variable it lands in through any intermediate assignments, and anchor only on a
conversion whose right-hand side traces back to it. Where no such anchor exists, the
answer is a refusal, not a guess — a refusal is visible and comes with a way forward,
and a wrong guess is neither.

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
- **Nothing the block does may escape the block.** The injected line runs inside the
  user's script, so anything it leaves in that scope configures the rest of *their*
  file. `Set-StrictMode -Version Latest` at the top of the tee escaped exactly that way
  in v1.0.0: dot-sourced with a bare `.`, it turned every optional-key read below the
  block into a throw, and the affected population was precisely the one with no
  rate-limit data to show — Free accounts, and every session before its first reply
  (oriel#1). The tee therefore sets nothing at file scope, and the block dot-sources
  inside `& { }` so the boundary is structural rather than a promise. The `try/catch`
  is no defence here: by the time it catches, the preference is already set in a scope
  that outlives the block.
- **Verification asks two questions, not one.** Data flowing is necessary and not
  sufficient: the second question is whether the user's statusline still prints what it
  printed before, asked with a payload that has *no* rate-limit data in it — the shape
  where a leak like the one above shows. A complete payload passes cleanly and proves
  nothing. When the answer is no, the block comes straight back out in the same run: an
  Oriel that is not installed costs the user nothing, and a broken status line costs
  them all day.
- **Uninstall removes the block, never the file.** Restoring the pre-install backup
  wholesale would destroy months of unrelated edits the user made to their own
  statusline. The backup stays a safety net for a failed removal, not the method.
- Supporting foreign statuslines is not closed forever — it is closed until someone
  finds a way to hand the tee its JSON without standing between Claude Code and the
  user's script.
