# libexec/hwdp/probe.sh -- the ONE place hwdp learns what displays exist.
# Sourced by the tools in bin/; defines functions and the provider roots, and
# runs nothing on its own. POSIX sh, no bashisms.
#
# TWO CLASSES, because they answer two different questions and only one of them
# needs a compositor:
#
#   panels   WHAT IS ATTACHED -- the kernel's view, from DRM sysfs. Resolves
#            HEADLESS: from a TTY, over ssh, at boot, at the greeter, before any
#            session exists. The HWDP id is built from this class.
#   layout   HOW IT IS ARRANGED -- enabled, position, transform, scale. Only a
#            compositor knows this, so it is session-only by nature.
#
# Asking the layout question when a panel question was meant is what made
# `uiprofile` answer hidpi (cursor 48) on a 1920x1080 panel with no session: the
# probe came back empty and the density test silently fell through to its else.
# Keep the classes straight and that whole family of bug cannot recur.
#
# PROVIDERS, the vigilance model. Each class is served by a DIRECTORY of
# executables tried in filename order; the FIRST that exits 0 with non-empty
# output wins. (A probe wants one answer -- unlike a vigilance hook edge, where
# every entry runs. This is vigilance's `provider`, not its `hook`.) A provider
# that cannot answer here exits non-zero or prints nothing, so the cascade is
# fail-soft and ordering is the whole policy. Roots, MOST SPECIFIC FIRST:
#
#   $HWDP_PROVIDER_ROOT       user     (default ~/.config/hwdp/providers)
#   $HWDP_MACHINE_PROVIDERS   machine  (default /etc/hwdp/providers)
#   $HWDP_LIBEXEC/providers   shipped  (this package)
#
# So an integrator adds a compositor -- hyprland, a pywayland `done`-event
# settle, a KDE backend -- by dropping ONE executable in, exactly as it adds a
# display-change hook to kanshi-mgr. hwdp hardcodes no environment tool.
#
# RECORD FORMATS, TAB separated, one line per output. Providers emit EVERY
# output they can see and never filter; each CONSUMER filters for what it needs
# (display-geometry wants enabled ones, kanshi wants ones with an EDID name and
# a physical size). The two used to filter by accident -- one checked `Enabled:`
# and the other only happened to agree because a disabled output has no current
# mode -- and that coincidence is exactly what this split removes.
#
#   layout  name conn mode_w mode_h mm_w mm_h rate transform scale x y enabled
#           `name` is the EDID "Make Model Serial" kanshi keys outputs on, EMPTY
#           when the provider cannot supply it; `conn` is the connector (DP-2).
#   panels  edid_sha conn native_w native_h
#           `edid_sha` is the sha256 of the connector's raw EDID -- the atom the
#           HWDP id is built from.

HWDP_PROVIDER_ROOT=${HWDP_PROVIDER_ROOT:-\
${XDG_CONFIG_HOME:-$HOME/.config}/hwdp/providers}
HWDP_MACHINE_PROVIDERS=${HWDP_MACHINE_PROVIDERS:-/etc/hwdp/providers}

# probe_run <class>: print the first answering provider's records. Returns 1
# with no output when no provider in any root can answer.
probe_run() {
  _pc=$1
  for _pr in "$HWDP_PROVIDER_ROOT" "$HWDP_MACHINE_PROVIDERS" \
             "${HWDP_LIBEXEC:-}/providers"; do
    [ -n "$_pr" ] && [ -d "$_pr/$_pc" ] || continue
    for _pp in "$_pr/$_pc"/*; do
      [ -f "$_pp" ] && [ -x "$_pp" ] || continue
      _po=$("$_pp" 2>/dev/null) || continue
      [ -n "$_po" ] || continue
      printf '%s\n' "$_po"
      return 0
    done
  done
  return 1
}

# probe_layout: the compositor view. HWDP_GEOM_BACKEND is the documented
# integrator seam and stays exactly that -- it is simply tried BEFORE the
# provider dirs, i.e. it is a provider named by an env var instead of by a
# filename. It emits the layout record like any other provider.
probe_layout() {
  if [ -n "${HWDP_GEOM_BACKEND:-}" ] && [ -x "$HWDP_GEOM_BACKEND" ]; then
    if _po=$("$HWDP_GEOM_BACKEND" 2>/dev/null) && [ -n "$_po" ]; then
      printf '%s\n' "$_po"
      return 0
    fi
  fi
  probe_run layout
}

# probe_panels: the kernel view. Always available on a Linux box with DRM.
probe_panels() { probe_run panels; }

# hwdp_id: the HWDP (hardware display profile id) for the CONNECTED set. Each
# connected connector's raw EDID is hashed, the hashes sorted-unique then hashed
# again, so the id is the same for a monitor set regardless of order or which
# connector each sits on (the EDID carries make/model/serial, so identical
# models still differ and the set still pins WHICH panels). EMPTY -- not the
# hash of nothing -- with nothing connected, so a display-less box yields no
# bogus id. Provision-time code (the greeter) and session code (kanshi, the
# drift check) share this ONE algorithm.
hwdp_id() {
  _hs=$(probe_panels | cut -f1 | sort -u)
  [ -n "$_hs" ] || return 0
  printf '%s\n' "$_hs" | sha256sum | cut -c1-12
}
