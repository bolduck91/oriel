# Freshness model: show last-known, live countdown, drain colour when stale

The widget always renders the **last-known** numbers rather than blanking when no
new data arrives. Freshness is handled by splitting the data into its two halves:

- **The countdown is never stale.** `resets_at` is an absolute instant, so the
  widget ticks it off its own clock and it stays correct whether or not new writes
  arrive. At zero it shows `resets: due` — never a negative timer, never a
  fabricated 0%.
- **Only the `used_percentage` can go stale.** When `written_at` is older than the
  freshness threshold, the percentages (number + their ring/arc) **drain to a
  neutral grey**; everything else — layout, border, countdown — is untouched.

Deliberately **no added chrome**: no timestamp/"6m ago" text, no overlay or frost
over the whole pill, no liveness indicator dot. Several such treatments were
prototyped and rejected as either text-crutches or over-designed; the accepted
signal is the stale datum quietly losing its colour, nothing more.

## Consequences

- This is intentionally minimal because staleness is a **rare edge**: the project's
  premise is that the user is in an active session whenever they look, so the
  frozen state is off-hours only. The bar was "honest and zero-ornament," not
  "prominent." Revisiting for a stronger treatment later is left open.
- The **freshness threshold** (how old `written_at` must be to count as stale) is a
  tunable; default on the order of a couple of minutes, comfortably longer than a
  normal between-turn gap so a pause to read output never flips it to stale.
