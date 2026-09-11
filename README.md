# hwdp

Hardware display-profile detection, layout, and autoscale. `hwdp` recognises
which monitors are present and lays out / autoscales the workspace for them,
keyed on the **hardware** (an EDID-derived display-profile id), never on a
hostname. It is environment-agnostic: it runs under X11 or a wlroots compositor,
and hardcodes no downstream tool. Everything session-specific is a **hook** or a
pluggable **backend** an integrator fills.

It installs `hwdp`, the display-state command, whose subcommands are
executables under `libexec/hwdp/cmd/` — adding one is adding a file.

## Commands

```
hwdp id         the display-profile id for the connected monitor set
hwdp shape      the workspace shape: single | triple
hwdp ui         per-display UI sizing, as shell-sourceable KEY=VALUE
hwdp geometry   one line per enabled output (a stable contract)
hwdp layout     emit the runtime kanshi config, print its path
hwdp capture    snapshot the current arrangement into a profile
hwdp watch      supervise the layout; fire display-change hooks
```

**`run-scaled`** is the one other command, and deliberately not a subcommand:
everything above reads or manages display state and returns, where `run-scaled`
takes someone else's command line and *becomes* that process. It magnifies a
single application via a nested gamescope window, and consumes `hwdp geometry`
as a client, exactly like any other integrator tool would.

`id`, `shape` and `ui` answer **headless** — from a TTY, over ssh, at boot, at
a greeter — because they ask the kernel about panels when no compositor is
there to ask. The rest need a session and say so when they do not have one.

`layout`, `capture` and `watch` are the kanshi adapter and make no apology for
naming it; everything below them is compositor-agnostic.

## Integration seams (the extension points)

hwdp ships mechanisms, not policy. An integrator wires the specifics:

- **Display-change hooks.** `hwdp watch` runs every executable in
  `$HWDP_HOOK_ROOT/<edge>.d/*` (default `~/.config/hwdp/hooks`) and a machine
  root `$HWDP_MACHINE_HOOKS/<edge>.d/*` (default `/etc/hwdp/hooks`), machine
  first then user, fail-soft. Edges: `pre` (before kanshi starts, backgrounded)
  and `changed` (after kanshi is up and on every config-change burst). The
  package ships **no** hooks — drop in a `changed.d/10-...` to re-assert
  compositor runtime state, move notifications, check a greeter stamp, etc.
- **Display probes are providers.** Every tool asks one shared probe layer what
  displays exist, and each platform is a drop-in executable rather than a
  branch in the code. Two classes, because they answer different questions:
  `panels` (what is attached — DRM sysfs, resolves *headless*, at a TTY or a
  greeter) and `layout` (how it is arranged — enabled, position, transform,
  scale, which only a compositor knows). Providers are tried in filename order
  from `$HWDP_PROVIDER_ROOT/<class>/*` (default `~/.config/hwdp/providers`),
  then `$HWDP_MACHINE_PROVIDERS/<class>/*` (default `/etc/hwdp/providers`),
  then the shipped ones; the first to exit 0 with output wins, and one that
  cannot answer here exits non-zero and is skipped. Add hyprland, a KDE
  backend, or a `wlr-output-management` probe that settles on its `done` event
  by dropping in **one file** — same shape as the hooks above.
- **Geometry backend.** `HWDP_GEOM_BACKEND`, if set and executable, is simply
  the layout provider tried before all the others.

This makes hwdp dual-use: it installs and runs standalone, and it slots under a
provisioning layer (e.g. tackup) that fills the seams.

## License

Apache-2.0.
