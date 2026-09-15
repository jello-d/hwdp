#!/bin/sh
# setup.sh - install / uninstall / check / test the HWDP display suite: hardware
# display-profile detection + monitor-set layout/autoscale. The SINGLE entry
# point a consumer or provisioning layer uses.
#
# bin/hwdp is the display-state command, dispatching to libexec/hwdp/cmd/:
#   id shape ui        display-profile queries (these answer HEADLESS)
#   geometry           one line per enabled output (stable contract)
#   layout capture     the kanshi adapter: emit the runtime config / snapshot
#   watch              supervise the layout, fire display-change HOOKS
# The other two commands are hwdp CLIENTS rather than subcommands: each does
# something TO something else, using `hwdp geometry` the way any consumer would.
#   run-scaled        wrap an APPLICATION in a nested gamescope window
#   wallpaper-slicer  cut an IMAGE into per-output slices that tile a layout
#
#   ./setup.sh install     symlink the tools (+ man) into ~/.local
#   ./setup.sh uninstall   remove the symlinks
#   ./setup.sh check       every tool + dependency present; [OK]/[FAIL] markers
#   ./setup.sh test        run the in-repo test suite (test/run)
#   ./setup.sh version     the packaged version
#
# POSIX sh, non-privileged. Honors PREFIX (default ~/.local) + XDG_* so a test
# sandboxes it. `hwdp watch` is autostarted by the compositor, not a systemd
# unit, so there is no `service` verb.
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
# What we last placed in $_bin. In COPY mode an installed file carries no
# marker pointing home, so a departed tool cannot be recognised from its target
# the way a dangling symlink can -- and at a ROOT prefix that would strand a
# root-owned binary nobody can account for. Kept BESIDE the libexec tree, since
# a copying install rm -rf's the tree itself.
_manifest=$_lib/.$PKG-installed
# External runtime deps. HARD (the suite's core needs them) vs SOFT (a feature
# degrades without them): reported distinctly by check.
DEPS_HARD="kanshi wlr-randr awk sha256sum"
DEPS_SOFT="inotifywait gamescope xrandr bc"
# wallpaper-slicer needs ONE of these, not all of them, which a flat list
# cannot say -- hence its own check below.
DEPS_IMAGE="magick convert vips"
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

# WHICH commands belong at a SHARED prefix. Classification is PER COMMAND and
# never per package: the greeter runs `hwdp` for the display id and the
# per-panel sizing, and nothing root-side runs `run-scaled` -- that is a
# session launcher, invoked from a keybind or a menu by the person sitting
# there. Installing it system-side would put a second copy of a user-only tool
# on PATH, which is precisely the shadow the single-copy rule forbids.
SYSTEM_TOOLS=${SYSTEM_TOOLS:-hwdp}

# _wanted_at_prefix <tool>: is this tool wanted at the prefix being installed
# to? Keyed on COPY MODE, which is already defined as "what a shared prefix
# needs", so a symlinking install into a user prefix still gets everything.
_wanted_at_prefix() {
  [ "${HWDP_INSTALL_COPY:-0}" = 1 ] || return 0
  for _w in $SYSTEM_TOOLS; do [ "$1" = "$_w" ] && return 0; done
  return 1
}

# _place <src> <dst>: symlink, or COPY when HWDP_INSTALL_COPY=1.
#
# Copy mode is what a SHARED/SYSTEM prefix needs. The clone this installs from
# lives under a user's home (0750, and ~/.cache is 0700), so a symlink from
# /usr/local into it is unreadable by any other account -- a greeter following
# one gets nothing. A copy can drift from the clone, so a copying install
# RE-COPIES every run; the install sweep runs on every provision.
#
# --remove-destination so replacing a RUNNING binary cannot fail with ETXTBSY:
# the old inode is unlinked and any live process keeps it.
#
# THE CHOWN IS NOT OPTIONAL, and this is vigilance's hard-won lesson rather than
# ours: `cp -a` implies --preserve=all, which carries the SOURCE's ownership
# across even when the copy runs as root. Installing from a clone in a user's
# home therefore produced a system binary owned by the LOGIN USER -- one the
# greeter executes and the unprivileged account can rewrite at will. When root
# is installing, root owns the result.
_place() {
  if [ "${HWDP_INSTALL_COPY:-0}" = 1 ]; then
    cp -a --remove-destination "$1" "$2"
    if [ "$(id -u)" = 0 ]; then chown -R root:root "$2"; fi
  else
    ln -sfn "$1" "$2"
  fi
}

# _unplace <installed-path> <clone-source>: remove what _place put there. A
# symlink is only ours if it still points at our clone; a copy carries no such
# marker, so copy mode removes by path.
_unplace() {
  if [ "${HWDP_INSTALL_COPY:-0}" = 1 ]; then
    rm -f "$1"
  else
    [ "$(readlink "$1" 2>/dev/null)" = "$2" ] && rm -f "$1" || :
  fi
}

# Reclaim links THIS package left behind. `install` only ever created links for
# the tools that exist now, so a tool that departed in a later version left its
# link on PATH forever, dangling -- five of them survived the collapse to a
# single `hwdp` command, and a stale `hwprofile` link would have SHADOWED the
# real one had ~/.local/bin sorted before ~/bin. Scoped to symlinks that point
# into our own bin/, so another package's binary can never be touched.
_prune_stale() {
  # Symlink mode: ours if it points into our own bin/ and no longer resolves.
  for _l in "$_bin"/*; do
    [ -L "$_l" ] || continue
    _lt=$(readlink "$_l") || continue
    case $_lt in "$_root/bin/"*) ;; *) continue ;; esac
    [ -e "$_lt" ] && continue
    rm -f "$_l" && echo "$PKG: pruned stale link $(basename "$_l")"
  done
  # Either mode: anything we recorded placing that we no longer ship.
  [ -f "$_manifest" ] || return 0
  while IFS= read -r _n; do
    [ -n "$_n" ] && [ ! -e "$_root/bin/$_n" ] || continue
    [ -e "$_bin/$_n" ] || continue
    rm -f "$_bin/$_n" && echo "$PKG: pruned departed $_n"
  done < "$_manifest"
}

# Record what we ACTUALLY placed, so the next install can prune a tool that
# departs. Honours _wanted_at_prefix: at a shared prefix the manifest must not
# claim a session tool we deliberately did not install, or it describes a
# prefix that never existed.
_write_manifest() {
  : > "$_manifest"
  for _t in "$_root"/bin/*; do
    _n=$(basename "$_t")
    _wanted_at_prefix "$_n" && printf '%s\n' "$_n" >> "$_manifest"
  done
  [ "$(id -u)" = 0 ] && chown root:root "$_manifest" || :
}

do_install() {
  mkdir -p "$_bin" "$_lib"
  for _t in "$_root"/bin/*; do
    _n=$(basename "$_t")
    if _wanted_at_prefix "$_n"; then
      _place "$_t" "$_bin/$_n"
    elif [ -e "$_bin/$_n" ] || [ -L "$_bin/$_n" ]; then
      # SWEEP what an earlier over-install left at a shared prefix. A stale
      # shadow is worse than a missing tool: the missing one fails loudly,
      # the shadow quietly does the old thing.
      rm -f "$_bin/$_n"
      echo "$PKG: removed $_bin/$_n (session tool, not shared)"
    fi
  done
  _prune_stale
  # rm first, in BOTH modes, because BOTH placement commands nest instead of
  # replacing when the destination is a real directory. `cp -a` of a directory
  # onto an existing one puts it one level down; `ln -sfn` does exactly the
  # same, which the symlink branch used to miss. That is not hypothetical: a
  # prefix that once held a COPY install keeps a real libexec/<pkg>/ tree, so
  # the next SYMLINK install buried its link at libexec/hwdp/hwdp and left the
  # stale Sep-11 tree resolving in front of it (found on manifold 2026-09-15
  # by check's own WARN, which is the drift-detection earning its keep).
  rm -rf "$_lib/$PKG"
  if [ "${HWDP_INSTALL_COPY:-0}" = 1 ]; then
    cp -a "$_root/libexec/$PKG" "$_lib/$PKG"
    [ "$(id -u)" = 0 ] && chown -R root:root "$_lib/$PKG" || :
  else
    ln -sfn "$_root/libexec/$PKG" "$_lib/$PKG"
  fi
  _man_pages | while IFS= read -r _m; do
    _d=$_man/$(basename "$(dirname "$_m")")
    mkdir -p "$_d"; _place "$_m" "$_d/$(basename "$_m")"; done
  _write_manifest
  if [ "${HWDP_INSTALL_COPY:-0}" = 1 ]; then
    echo "$PKG: COPIED the tools (+ libexec, man) into $PREFIX"
  else
    echo "$PKG: linked the tools (+ libexec, man) into $PREFIX"
  fi
}

do_uninstall() {
  for _t in "$_root"/bin/*; do _unplace "$_bin/$(basename "$_t")" "$_t"; done
  _prune_stale
  # -L BEFORE -d, since a symlink TO a directory satisfies both.
  if [ "${HWDP_INSTALL_COPY:-0}" = 1 ]; then
    rm -rf "$_lib/$PKG"
  elif [ -L "$_lib/$PKG" ]; then
    [ "$(readlink "$_lib/$PKG")" = "$_root/libexec/$PKG" ] \
      && rm -f "$_lib/$PKG" || :
  elif [ -d "$_lib/$PKG" ] && [ -f "$_manifest" ]; then
    # A REAL tree where a symlink belongs: an earlier COPY install at this same
    # prefix. Left behind, it is exactly the crumb a mode switch is supposed
    # not to leave -- and worse, the next symlinking install would nest its
    # link INSIDE it. The manifest beside it is what says this prefix is ours;
    # without that signal we would be rm -rf'ing a directory we never made.
    rm -rf "$_lib/$PKG"
    echo "$PKG: removed a stale copy-mode libexec tree at $_lib/$PKG"
  fi
  _man_pages | while IFS= read -r _m; do
    _unplace "$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")" "$_m"
  done
  rm -f "$_manifest"
  echo "$PKG: removed the install from $PREFIX"
}

do_check() {
  echo "== $PKG (display detect / layout / autoscale) =="
  # Derived from what is SHIPPED, not a hand-kept list: adding a command to
  # bin/ should not also require remembering to name it here, which is how a
  # check comes to pass while a tool it never looked at is missing.
  for _t in $(for _b in "$_root"/bin/*; do basename "$_b"; done); do
    if command -v "$_t" >/dev/null 2>&1; then ok "$_t present"
    else bad "$_t not on PATH"; fi; done
  # Every subcommand the dispatcher advertises must actually be installed --
  # a missing impl is a command that exists until someone runs it.
  for _c in id shape ui geometry layout capture watch; do
    [ -x "$_root/libexec/$PKG/cmd/$_c" ] && ok "cmd $_c present" \
      || bad "cmd $_c missing"; done
  # Drift, not tidiness: a dangling link is a command that exists until it is
  # run, and it can shadow the real tool elsewhere on PATH. `install` prunes.
  _stale=""
  for _l in "$_bin"/*; do
    [ -L "$_l" ] || continue
    _lt=$(readlink "$_l") || continue
    case $_lt in "$_root/bin/"*) ;; *) continue ;; esac
    [ -e "$_lt" ] || _stale="$_stale $(basename "$_l")"; done
  [ -z "$_stale" ] && ok "no stale links in $_bin" \
    || bad "stale links from an older version:$_stale (re-run install)"
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
              "gamescope+bc=run-scaled, xrandr=X11 geometry)"; done
  # ANY of the three will do, so report the one that would be used rather than
  # warning three times about tools the user deliberately does not have.
  _img=
  for _d in $DEPS_IMAGE; do
    command -v "$_d" >/dev/null 2>&1 && { _img=$_d; break; }; done
  [ -n "$_img" ] && ok "image tool $_img present (wallpaper-slicer)" \
    || warn "no image tool ($DEPS_IMAGE); wallpaper-slicer cannot cut slices"
}

_U="usage: setup.sh [install|uninstall|check|test|version]   (PREFIX=... env)"

# The prefix is an ENV var, not a flag, and an extra argument used to be
# ignored in silence: `setup.sh install --prefix /tmp/x` installed to the
# DEFAULT prefix and reported success, so a sandboxed install quietly went to
# the real ~/.local instead. Silent success on a misunderstood command line is
# the failure mode the fail-loud rule exists for.
if [ "$#" -gt 1 ]; then
  echo "setup.sh: unexpected argument '$2' (the prefix is PREFIX=..., not a" \
       "flag)" >&2
  echo "$_U" >&2; exit 2
fi

case "${1:-install}" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  check)     do_check; exit "$RC" ;;
  test)      exec sh "$_root/test/run" ;;
  version)   echo "$PKG $VERSION" ;;
  -h|--help|help) echo "$_U" ;;
  *) echo "setup.sh: unknown command '${1:-}'" >&2; echo "$_U" >&2; exit 2 ;;
esac
