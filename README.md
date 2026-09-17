# hwdp

Hardware display-profile detection, layout, and autoscale. `hwdp` recognises
which monitors are present and lays out / autoscales the workspace for them,
keyed on the **hardware** (an EDID-derived display-profile id), never on a
hostname. It is environment-agnostic: it runs under X11 or a wlroots compositor,
and hardcodes no downstream tool. Everything session-specific is a **hook** or a
pluggable **backend** an integrator fills.

It installs `hwdp`, the display-state command, whose subcommands are
executables under `libexec/hwdp/cmd/`, so adding one is adding a file.

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

`id`, `shape` and `ui` answer **headless** (from a TTY, over ssh, at boot, at
a greeter) because they ask the kernel about panels when no compositor is
there to ask. The rest need a session and say so when they do not have one.

**Mixed DPI is not supported.** One panel, or several of the *same* physical
density. `hwdp ui` emits one value per key because each consumer has one global
config: kitty has a single `font_size`, pixdecor a single compositor-wide
`title_font`, mako a single font. On panels of different density there is no
value that is right for both, and that is a property of those consumers rather
than a gap here. Scaling outputs to a common *logical* density was built and
measured, then dropped: it renders a 27" 4K as a 2194x1234 desktop to match a
1080p monitor, imposing an average on both rather than supporting either. When
`hwdp ui` sees panels more than 25% apart in density it says so on stderr,
names them, and sizes for the **densest** one -- oversized on a coarse panel is
clumsy but readable, where the reverse is microscopic. It still emits a full
set of keys and exits 0, so nothing downstream breaks.

`layout`, `capture` and `watch` are the kanshi adapter and make no apology for
naming it; everything below them is compositor-agnostic.

Two further commands ship alongside it. They are deliberately *not*
subcommands: every subcommand above reads or manages display state and returns,
where these consume that state to do something else. Both read `hwdp geometry`
or `hwdp ui` as ordinary clients, exactly as an integrator's own tool would.

```
run-scaled        magnify one app in a nested gamescope window
wallpaper-slicer  cut one image into per-output crops that tile
```

**`run-scaled`** takes someone else's command line and *becomes* that process,
so its exit status and stdout are the child's. It exists for fixed-layout
applications that cannot scale themselves: a 640x480 program is unusable on a
2880x1800 panel and merely small on 1920x1080, so the magnification comes from
`hwdp ui`'s `MAGNIFY` key rather than from each caller guessing.

**`wallpaper-slicer`** works around the fact that Wayland clients which draw a
wallpaper (swaylock, swaybg, a greeter background) paint the *same* image on
every output and have no spanned mode. It pre-cuts the source into one crop per
output, each crop that output's sub-rectangle of the image cover-scaled over
the whole layout union, so the slices tile and a feature crossing a bezel stays
continuous. Cutting a wallpaper per output is a function of the panel layout,
which is this package's subject, so it lives here rather than in whichever
integrator happens to call it. Needs one of `magick`, `convert` or `vips`.

## Integration seams (the extension points)

hwdp ships mechanisms, not policy. An integrator wires the specifics:

- **Display-change hooks.** `hwdp watch` runs every executable in
  `$HWDP_HOOK_ROOT/<edge>.d/*` (default `~/.config/hwdp/hooks`) and a machine
  root `$HWDP_MACHINE_HOOKS/<edge>.d/*` (default `/etc/hwdp/hooks`), machine
  first then user, fail-soft. Edges: `pre` (before kanshi starts, backgrounded)
  and `changed` (after kanshi is up and on every config-change burst). The
  package ships **no** hooks; drop in a `changed.d/10-...` to re-assert
  compositor runtime state, move notifications, check a greeter stamp, etc.
- **Display probes are providers.** Every tool asks one shared probe layer what
  displays exist, and each platform is a drop-in executable rather than a
  branch in the code. Two classes, because they answer different questions:
  `panels` (what is attached: DRM sysfs, resolves *headless*, at a TTY or a
  greeter) and `layout` (how it is arranged: enabled, position, transform,
  scale, which only a compositor knows). Providers are tried in filename order
  from `$HWDP_PROVIDER_ROOT/<class>/*` (default `~/.config/hwdp/providers`),
  then `$HWDP_MACHINE_PROVIDERS/<class>/*` (default `/etc/hwdp/providers`),
  then the shipped ones; the first to exit 0 with output wins, and one that
  cannot answer here exits non-zero and is skipped. Add hyprland, a KDE
  backend, or a `wlr-output-management` probe that settles on its `done` event
  by dropping in **one file**, the same shape as the hooks above.
- **Geometry backend.** `HWDP_GEOM_BACKEND`, if set and executable, is simply
  the layout provider tried before all the others.

This makes hwdp dual-use: it installs and runs standalone, and it slots under a
provisioning layer (e.g. tackup) that fills the seams.

## License

Apache-2.0.
