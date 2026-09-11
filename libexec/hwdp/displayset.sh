# libexec/hwdp/displayset.sh -- the DISPLAY SET view, shared by the subcommands
# that reason about "the monitors on this box" rather than about one output.
# Sourced after (or instead of) probe.sh, which it pulls in itself.
#
# probe.sh answers what the hardware and the compositor report. This file is the
# layer above: where this box keeps its per-display-set state, and the two
# coarsenings every consumer asks for -- the output list in the shape kanshi
# needs, and the panel COUNT bucketed into a workspace shape.
#
# Everything density- or layout-specific stays in the subcommand that owns it
# (cmd/ui owns the density policy, cmd/layout owns the sticky scale), so this
# holds only what more than one of them genuinely needs.

: "${HWDP_LIBEXEC:?displayset.sh: HWDP_LIBEXEC must be set}"
. "$HWDP_LIBEXEC/probe.sh"

_cfg=${XDG_CONFIG_HOME:-$HOME/.config}/kanshi
PROFILES=${KANSHI_PROFILES:-$_cfg/profiles}
STICKY=${KANSHI_STICKY:-$_cfg/auto-scale}
OUT=${KANSHI_OUT:-${XDG_RUNTIME_DIR:-/tmp}/kanshi-autoscale.config}
TAB=$(printf '\t')

# outputs: one TAB record per output we can actually act on --
#   edid \t connector \t res_w \t res_h \t mm_w \t mm_h \t rate \t
#   transform \t pos
#
# A projection of probe_layout, and the FILTER is this layer's policy, not the
# provider's: an output is keyed by its EDID "Make Model Serial" and its sticky
# scale is signed with its physical size, so one missing either is not one we
# can place. The `enabled` test used to be implicit -- a disabled output has no
# current mode, so it fell out by accident -- and is explicit here.
outputs() {
  probe_layout | awk -F"$TAB" -v OFS="$TAB" '
    $1 != "" && $12 == 1 && $3 + 0 > 0 && $5 + 0 > 0 {
      print $1, $2, $3, $4, $5, $6, $7, $8, $10 "," $11
    }'
}

# shape: the workspace SHAPE for the connected set -- a COARSENING of the HWDP
# id to just the panel COUNT, since the grid, names, window rules and wallpaper
# are a function of HOW MANY panels, not which ones. A wall (>=3) is `triple`,
# anything less is `single` (the same >=3 threshold mako uses). Empty with no
# displays at all.
#
# LAYOUT first, PANELS as the fallback: in a session the compositor's view is
# the one to act on (an output you disabled should not count toward the wall),
# but at the greeter or from a TTY there is no compositor and the kernel's view
# is the only truthful answer available. Each context gets the answer it can
# actually act on, rather than the empty string that used to come back headless.
#
# This lives here rather than in cmd/shape because cmd/ui needs the same answer
# in-process; shelling out to a sibling subcommand for it would be worse, and
# a second copy of the >=3 threshold would be worse still.
shape() {
  _sc=$(outputs | grep -c . || true)
  [ "${_sc:-0}" -ge 1 ] || _sc=$(probe_panels | grep -c . || true)
  [ "${_sc:-0}" -ge 1 ] || return 0
  if [ "$_sc" -ge 3 ]; then echo triple; else echo single; fi
}

# panel_width: the width in px of the first display, for density decisions.
# Layout first then panels, exactly as shape does. Prints nothing when no
# display answers, or when the kernel lists a connector with no modes (width 0
# means UNKNOWN, not tiny -- a caller must not read it as a small panel).
panel_width() {
  _pw=$(outputs | head -1 | cut -f3)
  [ -n "$_pw" ] || _pw=$(probe_panels | head -1 | cut -f3)
  [ "${_pw:-0}" -gt 0 ] 2>/dev/null || return 0
  printf '%s' "$_pw"
}
