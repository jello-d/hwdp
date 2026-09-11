#!/bin/sh
# setup.sh - install / uninstall / check / test the HWDP display suite: hardware
# display-profile detection + monitor-set layout/autoscale. The SINGLE entry
# point a consumer or provisioning layer uses.
#
# The tools, in bin/:
#   hwprofile        detect hardware/substrate capabilities into a sticky,
#                    fingerprinted profile (a reader gates on it, not hostname)
#   kanshi-autoscale pick/synthesize the kanshi layout for the connected set +
#                    fill each output's scale from panel DPI; hwdp/shape/ui
#   kanshi-mgr       own kanshi's lifecycle in a session; fire display-change
#                    HOOKS an integrator drops in (it hardcodes no downstream)
#   display-geometry one line per enabled output; wlr-randr / xrandr / a plugged
#                    backend (HWDP_GEOM_BACKEND)
#   run-scaled       magnify one app via a nested gamescope window
#
#   ./setup.sh install     symlink the tools (+ man) into ~/.local
#   ./setup.sh uninstall   remove the symlinks
#   ./setup.sh check       every tool + dependency present; [OK]/[FAIL] markers
#   ./setup.sh test        run the in-repo test suite (test/run)
#   ./setup.sh version     the packaged version
#
# POSIX sh, non-privileged. Honors PREFIX (default ~/.local) + XDG_* so a test
# sandboxes it. kanshi-mgr is autostarted by the compositor, not a systemd unit,
# so there is no `service` verb.
set -eu

PKG=hwdp
VERSION=0.1.0
_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# HOME is not guaranteed in every context this runs from (a provisioner, a
# service, cloud-init's runcmd), and under `set -eu` an unset HOME aborts before
# the first message. Derive it rather than assume it.
if [ -z "${HOME:-}" ]; then
  HOME=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)
  if [ -z "$HOME" ]; then
    echo "$PKG: HOME unset and not derivable from passwd" >&2; exit 1
  fi
  export HOME
fi

PREFIX=${PREFIX:-$HOME/.local}
_bin=${XDG_BIN_HOME:-$PREFIX/bin}
_shr=${XDG_DATA_HOME:-$PREFIX/share}
_man=$_shr/man
# The shared probe library and its providers. Linked as ONE directory symlink
# (not file by file) so a provider added upstream appears without a re-install,
# which is what `head`-tracked packaging expects. The tools find it from their
# own real path anyway; this is for anyone who wants it at a predictable place.
_lib=$PREFIX/libexec
# External runtime deps. HARD (the suite's core needs them) vs SOFT (a feature
# degrades without them): reported distinctly by check.
DEPS_HARD="kanshi wlr-randr awk sha256sum"
DEPS_SOFT="inotifywait gamescope xrandr"
RC=0

# marker contract: plain [OK]/[FAIL]/[WARN] an integrator styles in its palette;
# self-coloured at a terminal, plain when piped or under NO_COLOR.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _G=$(printf '\033[32m'); _R=$(printf '\033[31m')
  _Y=$(printf '\033[33m'); _O=$(printf '\033[0m')
else _G=; _R=; _Y=; _O=; fi
ok()   { printf '  %s[OK]%s   %s\n' "$_G" "$_O" "$1"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$_R" "$_O" "$1"; RC=1; }
warn() { printf '  %s[WARN]%s %s\n' "$_Y" "$_O" "$1"; }

_man_pages() { for _m in "$_root"/man/man*/*.[0-9]; do
  [ -e "$_m" ] && printf '%s\n' "$_m"; done; }

do_install() {
  mkdir -p "$_bin" "$_lib"
  for _t in "$_root"/bin/*; do ln -sfn "$_t" "$_bin/$(basename "$_t")"; done
  ln -sfn "$_root/libexec/$PKG" "$_lib/$PKG"
  _man_pages | while IFS= read -r _m; do
    _d=$_man/$(basename "$(dirname "$_m")")
    mkdir -p "$_d"; ln -sfn "$_m" "$_d/$(basename "$_m")"; done
  echo "$PKG: linked the tools (+ libexec, man) into $PREFIX"
}

do_uninstall() {
  for _t in "$_root"/bin/*; do _l=$_bin/$(basename "$_t")
    [ "$(readlink "$_l" 2>/dev/null)" = "$_t" ] && rm -f "$_l" || :; done
  [ "$(readlink "$_lib/$PKG" 2>/dev/null)" = "$_root/libexec/$PKG" ] \
    && rm -f "$_lib/$PKG" || :
  _man_pages | while IFS= read -r _m; do
    _l=$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")
    [ "$(readlink "$_l" 2>/dev/null)" = "$_m" ] && rm -f "$_l" || :; done
  echo "$PKG: removed the ~/.local symlinks"
}

do_check() {
  echo "== $PKG (display detect / layout / autoscale) =="
  for _t in "$_root"/bin/*; do _n=$(basename "$_t")
    if command -v "$_n" >/dev/null 2>&1; then ok "$_n present"
    else bad "$_n not on PATH"; fi; done
  # The shared probe and its providers: the tools resolve libexec from their own
  # real path, so a missing library is a broken install, while a missing PREFIX
  # symlink is only an inconvenience -- hence bad vs warn.
  [ -f "$_root/libexec/$PKG/probe.sh" ] && ok "libexec/probe.sh present" \
    || bad "libexec/probe.sh missing"
  [ "$(readlink "$_lib/$PKG" 2>/dev/null)" = "$_root/libexec/$PKG" ] \
    && ok "libexec linked into $PREFIX" \
    || warn "libexec not linked at $_lib/$PKG (tools still resolve it)"
  for _c in layout panels; do
    _n=0
    for _p in "$_root/libexec/$PKG/providers/$_c"/*; do
      [ -x "$_p" ] && _n=$((_n + 1)); done
    [ "$_n" -ge 1 ] && ok "$_c providers ($_n)" \
      || bad "no $_c providers installed"; done
  for _d in $DEPS_HARD; do
    command -v "$_d" >/dev/null 2>&1 && ok "dep $_d present" \
      || warn "dep $_d absent (core feature will not work)"; done
  for _d in $DEPS_SOFT; do
    command -v "$_d" >/dev/null 2>&1 && ok "dep $_d present" \
      || warn "dep $_d absent (a feature degrades: inotify=auto-reapply," \
              "gamescope=run-scaled, xrandr=X11 geometry)"; done
}

_U="usage: setup.sh [install|uninstall|check|test|version]"
case "${1:-install}" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  check)     do_check; exit "$RC" ;;
  test)      exec sh "$_root/test/run" ;;
  version)   echo "$PKG $VERSION" ;;
  -h|--help|help) echo "$_U" ;;
  *) echo "setup.sh: unknown command '${1:-}'" >&2; echo "$_U" >&2; exit 2 ;;
esac
