#!/bin/sh
# help.t - every subcommand answers --help, from its own header, and DOES
# NOTHING ELSE.
#
# Found 2026-11-15: capture, layout and watch ignored their arguments, so
# `hwdp watch --help` HUPed the session's kanshi and printed nothing, and
# `hwdp capture --help` would have re-captured the desk's profile. And the
# commands that had help printed a hand-typed line range of their header,
# which had drifted (surfaces stopped mid-sentence). So, for every file in
# libexec/cmd (a new command is covered the day it is written):
#   - --help exits 0 with text naming the command, no comment markers left,
#     and nothing written anywhere under the sandbox;
#   - a command that takes no arguments refuses an unknown one, exit 2,
#     before doing any work.
. "$(dirname "$0")/harness_lib"
harness_init help

mkdir -p "$T/drm"
run() {
  env -i PATH="/usr/bin:/bin" HOME="$T/home" XDG_CONFIG_HOME="$T/config" \
    XDG_STATE_HOME="$T/state" XDG_RUNTIME_DIR="$T/run" HWDP_DRM="$T/drm" \
    HWDP_MACHINE_PROVIDERS="$T/no-machine" HWDP_PROVIDER_ROOT="$T/no-user" \
    HWDP_HOOK_ROOT="$T/hooks" HWDP_MACHINE_HOOKS="$T/no-hooks" \
    sh "$HERE/bin/hwdp" "$@"
}
# Sourcing displayset_lib makes the (empty) runtime namespace, idempotently,
# in every command that uses it: that one directory is allowed, nothing in it.
snap() {
  find "$T" -path "$T/snap*" -prune -o -print | grep -v -x "$T/run/hwdp" \
    | sort > "$T/snap.$1"
}

_n=0
for _f in "$HERE"/libexec/cmd/*; do
  _c=${_f##*/}
  snap before
  _o=$(run "$_c" --help 2>&1) || fail "hwdp $_c --help exited $?: $_o"
  snap after
  cmp -s "$T/snap.before" "$T/snap.after" \
    || fail "hwdp $_c --help wrote: $(diff "$T/snap.before" "$T/snap.after")"
  case $(printf '%s\n' "$_o" | head -1) in
    *"hwdp $_c"*) ;;
    *) fail "hwdp $_c --help does not start by naming it: $_o" ;;
  esac
  printf '%s\n' "$_o" | grep -q -E '^#|end of --help|shellcheck' \
    && fail "hwdp $_c --help carries comment syntax: $_o"
  _n=$((_n + 1))
done
[ "$_n" -ge 15 ] || fail "only $_n commands found under libexec/cmd"
pass "--help on all $_n commands: their header, and nothing written"

for _c in capture layout watch shape ui status; do
  snap before
  _o=$(run "$_c" --bogus 2>&1); _rc=$?
  snap after
  [ "$_rc" = 2 ] || fail "hwdp $_c --bogus exited $_rc, not 2: $_o"
  case $_o in *"unknown argument: --bogus"*) ;;
    *) fail "hwdp $_c --bogus must say why: $_o" ;; esac
  cmp -s "$T/snap.before" "$T/snap.after" \
    || fail "hwdp $_c --bogus wrote: $(diff "$T/snap.before" "$T/snap.after")"
done
pass "capture, layout, watch, shape, ui and status refuse an unknown argument"
