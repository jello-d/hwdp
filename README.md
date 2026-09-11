# hwdp

Hardware display-profile detection, layout, and autoscale. `hwdp` recognises
which monitors are present and lays out / autoscales the workspace for them,
keyed on the **hardware** (an EDID-derived display-profile id), never on a
hostname. It is environment-agnostic: it runs under X11 or a wlroots compositor,
and hardcodes no downstream tool. Everything session-specific is a **hook** or a
pluggable **backend** an integrator fills.

It is a suite of four tools installed on `PATH`; there is no eponymous `hwdp`
command.

## Tools

- **kanshi-autoscale** — pick or synthesize the kanshi layout for the connected
  monitor set and fill each output's scale from panel DPI. Subcommands: `hwdp`,
  `shape`, `uiprofile`, `capture`.
- **kanshi-mgr** — own kanshi's lifecycle in a session and fire display-change
  hooks. It knows nothing of any specific compositor tool.
- **display-geometry** — one line per enabled output, from `wlr-randr`,
  `xrandr`, or a plugged-in backend.
- **run-scaled** — magnify one application via a nested gamescope window.

## Install

    ./setup.sh install      # symlink the tools (+ man) into ~/.local
    ./setup.sh check        # tools + deps present; [OK]/[FAIL] markers
    ./setup.sh uninstall
    ./setup.sh test         # the in-repo suite (also: sh test/run)

Honors `PREFIX` (default `~/.local`) and the `XDG_*` vars. Runtime deps:
`kanshi` and `wlr-randr` (core), `awk`/`sha256sum`; and, degrading softly,
`inotify-tools` (auto-reapply), `gamescope` (run-scaled), `xrandr` (X11).

## Integration seams (the extension points)

hwdp ships mechanisms, not policy. An integrator wires the specifics:

- **Display-change hooks.** `kanshi-mgr` runs every executable in
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
