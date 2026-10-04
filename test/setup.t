#!/bin/sh
# setup.t - the install roundtrip against a scratch PREFIX: install -> assert
# the ~/.local symlinks land -> check -> uninstall -> assert they are gone.
# Nothing outside the scratch dir is touched.
. "$(dirname "$0")/harness_lib"
harness_init setup

PREFIX=$T/local
export PREFIX
# Keep XDG_* under the scratch tree too, so nothing escapes T.
XDG_BIN_HOME=$PREFIX/bin
XDG_DATA_HOME=$PREFIX/share
export XDG_BIN_HOME XDG_DATA_HOME

sh "$HERE/setup.sh" install >/dev/null || fail "install errored"

# EVERY bin/ TOOL IS LINKED INTO THE PAYLOAD, not back at the repo. That is the
# whole of the place-not-link conversion: a departed package installs from
# ~/.cache/tackup/pkgs/hwdp, which is re-cloned on every sweep and wiped on
# demand, so a link into it dangles the moment that happens.
PAY=$XDG_DATA_HOME/hwdp
for _t in "$HERE"/bin/*; do
  _n=$(basename "$_t")
  _l=$XDG_BIN_HOME/$_n
  [ -L "$_l" ] || fail "$_n not linked into PREFIX/bin"
  [ "$(readlink "$_l")" = "$PAY/bin/$_n" ] \
    || fail "$_n links to '$(readlink "$_l")' rather than into the payload at
$PAY/bin/$_n: a link into the source tree is what this conversion removes"
done
[ -d "$PAY" ] && [ ! -L "$PAY" ] \
  || fail "the payload at $PAY is not a real directory"

# AND THE TOOLS STILL FIND THEIR libexec THROUGH IT, which is the invariant the
# payload exists to preserve and the one a reader is most likely to break.
# `bin/hwdp` resolves its own real path and reads a SIBLING tree:
#
#   HWDP_LIBEXEC=$(dirname "$(dirname "$_self")")/libexec
#
# so bin and libexec must sit at that exact relative depth INSIDE the payload.
# Asserted by RUNNING a dispatched subcommand, because the adjacency of two
# directories is not the claim: the claim is that the dispatch resolves.
[ -d "$PAY/libexec/cmd" ] && [ -d "$PAY/lib" ] \
  || fail "no libexec/ + lib/ beside the payload's bin/, so every dispatched
subcommand resolves to nothing"
env -u HWDP_LIBEXEC "$XDG_BIN_HOME/hwdp" shape >/dev/null 2>&1 \
  || fail "hwdp could not dispatch 'shape' through the payload link, so its
self-location does not resolve there"

# NOTHING MAY RESOLVE BACK INTO THE SOURCE TREE. The only assertion that can see
# a half-done conversion: one surviving link re-breaks on the next re-clone.
_leak=
for _d in "$XDG_BIN_HOME" "$XDG_DATA_HOME/man/man1" "$PREFIX/libexec"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    [ -L "$_f" ] || continue
    case "$(readlink -f "$_f" 2>/dev/null)" in
      "$HERE"/*) _leak="$_leak $_f" ;;
    esac
  done
done
[ -z "$_leak" ] || fail "these resolve into the source tree:$_leak"

# the man page landed
[ -e "$XDG_DATA_HOME/man/man1/hwdp.1" ] || fail "man page not installed"

# check runs against the sandbox: put the sandbox bin FIRST on PATH so
# `command -v` resolves the just-linked tools, not whatever the box has. Deps
# may be absent here, so do not gate on RC, only that it reports the tools.
PATH="$XDG_BIN_HOME:$PATH" sh "$HERE/setup.sh" check >"$T/check.out" 2>&1 \
  || true
grep -q '\[OK\].*hwdp present' "$T/check.out" \
  || fail "check did not report the linked tools"

# A tool that DEPARTS in a later version must not leave its link on PATH: the
# collapse to a single `hwdp` command orphaned five of them, dangling, and a
# stale `hwprofile` link could have shadowed the real one elsewhere on PATH.
# install prunes our own debris -- and ONLY ours: a link to somebody else's
# binary, dangling or not, is none of our business.
ln -sfn "$HERE/bin/departed-tool" "$XDG_BIN_HOME/departed-tool"
ln -sfn /nonexistent/other-pkg/bin/theirs "$XDG_BIN_HOME/theirs"
sh "$HERE/setup.sh" install >/dev/null || fail "re-install errored"
[ -L "$XDG_BIN_HOME/departed-tool" ] \
  && fail "install left a dangling link to a departed tool"
[ -L "$XDG_BIN_HOME/theirs" ] \
  || fail "install pruned a link that belongs to another package"
rm -f "$XDG_BIN_HOME/theirs"

# THE STRUCK ROOT IS RETIRED, NOT REPLACED. `~/.local/libexec/<pkg>` is gone as
# a concept: it was a symlink into the clone, so it dangled on every re-clone,
# and the tools resolve their libexec out of the payload now.
#
# THIS CASE USED TO ASSERT A SYMLINK THERE, for a real reason that no longer
# applies: both placement commands NEST rather than replace against a real
# directory, so a prefix that once held a COPY install buried the new link at
# libexec/hwdp/hwdp and the stale tree went on resolving in front of it,
# silently, because the tools find their libexec from their own real path and
# kept working. Found on a live box by check's WARN.
#
# THE STALE TREE STILL HAS TO GO, which is the half worth keeping: left behind
# it is the crumb a mode switch is meant not to leave, and the `rm -rf` that
# clears it runs in BOTH modes so a box takes the retirement on its next install
# rather than waiting for an uninstall that may never come.
rm -rf "$PREFIX/libexec/hwdp"
mkdir -p "$PREFIX/libexec/hwdp/cmd"
: > "$PREFIX/libexec/hwdp/probe_lib"           # a stale file from that install
sh "$HERE/setup.sh" install >/dev/null \
  || fail "re-install over a real dir errored"
[ -e "$PREFIX/libexec/hwdp" ] \
  && fail "install left the struck root at $PREFIX/libexec/hwdp; the payload
carries the libexec tree now, and recreating it puts the dangling-link violation
straight back"
# ...and the tools are unaffected by its absence, which is the point: they never
# read that path, they read a sibling of their own real one.
env -u HWDP_LIBEXEC "$XDG_BIN_HOME/hwdp" shape >/dev/null 2>&1 \
  || fail "hwdp stopped dispatching once the struck root was retired, so
something still depends on a path the conversion removes"

# ...and UNINSTALL clears the same stale tree rather than leaving the crumb a
# mode switch is meant not to leave. Gated on our manifest sitting beside it,
# so a directory this package never installed is never rm -rf'd.
rm -rf "$PREFIX/libexec/hwdp"
mkdir -p "$PREFIX/libexec/hwdp/cmd"
sh "$HERE/setup.sh" uninstall >/dev/null \
  || fail "uninstall over a real dir errored"
[ -e "$PREFIX/libexec/hwdp" ] \
  && fail "uninstall left a stale copy-mode libexec tree"
# A tree with NO manifest beside it is somebody else's: leave it alone.
mkdir -p "$PREFIX/libexec/hwdp/cmd"
rm -f "$PREFIX/libexec/.hwdp-installed"
sh "$HERE/setup.sh" uninstall >/dev/null || fail "uninstall errored"
[ -d "$PREFIX/libexec/hwdp" ] \
  || fail "uninstall removed an unowned directory (no manifest beside it)"
rm -rf "$PREFIX/libexec/hwdp"
sh "$HERE/setup.sh" install >/dev/null || fail "re-install errored"

# COPY mode: what a SHARED/SYSTEM prefix needs, because the clone lives under a
# 0750 home and a symlink from /usr/local into it is unreadable by the greeter
# account that has to follow it. The copy must be a REAL FILE, must resolve its
# own libexec from its new home, and must still prune a departed tool, which
# a copy cannot advertise the way a dangling symlink does, hence the manifest.
# XDG_BIN_HOME/XDG_DATA_HOME are set above and OVERRIDE PREFIX for those dirs,
# so relocating an install means overriding all three. Worth knowing before
# pointing a system install at /usr/local from an environment that exports them.
C=$T/sys
sys() { env HWDP_INSTALL_COPY=1 PREFIX="$C" XDG_BIN_HOME="$C/bin" \
  XDG_DATA_HOME="$C/share" sh "$HERE/setup.sh" "$@"; }
sys install >/dev/null || fail "copy-mode install errored"

# PER COMMAND, not per package: a shared prefix gets only what something
# root-side actually runs. `run-scaled` is a session launcher, so publishing it
# system-side would put a second copy of a user-only tool on PATH, which is the
# shadow the single-copy rule exists to forbid.
[ -e "$C/bin/hwdp" ] || fail "the shared command was not installed"
[ -e "$C/bin/run-scaled" ] \
  && fail "a session tool was installed at the SHARED prefix"
grep -qx hwdp "$C/libexec/.hwdp-installed" \
  || fail "the manifest does not record the shared command"
grep -qx run-scaled "$C/libexec/.hwdp-installed" \
  && fail "the manifest claims a tool the shared prefix never got"

# --- the classification is READABLE from outside, and AGREES with reality ----
# An integrator must know which commands are SHARED before it can decide where
# each goes, and the only honest source is the package. Reading an install
# ARTIFACT instead (a published link) lets a STALE one outrank the package, so
# a command reclassified from shared to user-only loses its correct copy to a
# leftover from the old classification, which is exactly what happened to
# run-scaled on both boxes.
_st=$(sh "$HERE/setup.sh" system-tools) || fail "system-tools exited non-zero"
[ "$_st" = hwdp ] || fail "system-tools said '$_st', want just hwdp"

# The declaration and the shared prefix are two views of one fact, so they must
# not drift: compare what it CLAIMS against what a copy-mode install PLACED.
_placed=$(for _b in "$C"/bin/*; do [ -e "$_b" ] && basename "$_b"; done | sort)
[ "$(printf '%s\n' "$_st" | sort)" = "$_placed" ] \
  || fail "system-tools says '$_st' but the shared prefix holds '$_placed'"

# Honours the env override the classification itself is keyed on.
_st=$(SYSTEM_TOOLS="hwdp run-scaled" sh "$HERE/setup.sh" system-tools)
[ "$(printf '%s\n' "$_st" | grep -c .)" -eq 2 ] \
  || fail "system-tools ignored a SYSTEM_TOOLS override: $_st"

# An earlier over-install is SWEPT, not left to shadow.
: > "$C/bin/run-scaled"; chmod +x "$C/bin/run-scaled"
sys install >/dev/null || fail "re-install errored"
[ -e "$C/bin/run-scaled" ] \
  && fail "an over-installed session tool was left at the shared prefix"
[ -f "$C/bin/hwdp" ] && [ ! -L "$C/bin/hwdp" ] \
  || fail "copy mode left a symlink, not a real file"
[ -f "$C/lib/probe_lib" ] && [ ! -L "$C/lib" ] \
  || fail "copy mode did not copy the lib tree (the cmds cannot source)"
[ -x "$C/libexec/cmd/shape" ] && [ ! -L "$C/libexec" ] \
  || fail "copy mode did not copy the libexec tree"
# Against the SOURCE dispatcher's own advertised list, not a literal count: a
# hardcoded 7 here meant adding a subcommand failed this test with "cannot
# resolve its own libexec", which is a real message pointing at the wrong thing.
# What is actually under test is that the COPY renders the same help the source
# does, so compare the two.
_want=$(sed -n 's/^#   hwdp .*/x/p' "$HERE/bin/hwdp" | wc -l)
[ "$_want" -gt 0 ] || fail "could not read the dispatcher's subcommand list"
[ "$("$C/bin/hwdp" help | grep -c '^  hwdp ')" -eq "$_want" ] \
  || fail "the copied hwdp cannot resolve its own libexec"

printf 'hwdp\nrun-scaled\ndeparted\n' > "$C/libexec/.hwdp-installed"
: > "$C/bin/departed"
sys install >/dev/null || fail "copy-mode re-install errored"
[ -e "$C/bin/departed" ] && fail "copy mode kept a departed tool"
[ -f "$C/bin/hwdp" ] || fail "copy-mode re-install lost hwdp"

sys uninstall >/dev/null || fail "copy-mode uninstall errored"
[ -e "$C/bin/hwdp" ] && fail "copy-mode uninstall left the binary"
[ -e "$C/libexec" ] && fail "copy-mode uninstall left the libexec tree"
[ -e "$C/lib" ] && fail "copy-mode uninstall left the lib tree"

sh "$HERE/setup.sh" uninstall >/dev/null || fail "uninstall errored"
for _t in "$HERE"/bin/*; do
  _n=$(basename "$_t")
  [ -e "$XDG_BIN_HOME/$_n" ] && fail "$_n still present after uninstall" || :
done
[ -e "$XDG_DATA_HOME/man/man1/hwdp.1" ] && fail "man page not removed" || :
# AND THE PAYLOAD GOES WITH IT. It is the only directory this install creates,
# so leaving it behind makes uninstall a half-measure and the next install a
# swap against a tree nobody owns. Added because the proof that the other three
# assertions bite showed this one had none: deleting the payload removal from
# setup.sh left the test green.
[ -e "$PAY" ] && fail "uninstall left the payload at $PAY" || :

pass "install/check/uninstall roundtrip"

# --- the `paths` CONTRACT VERB -----------------------------------------------
# Part of the package contract: one declaration feeds the install audit, the
# stale-path sweep, uninstall saying what it kept, and discoverability. Pinned
# because four consumers reading it is exactly the shape where a silently
# dropped key degrades each of them differently.
_pv=$(sh "$HERE/setup.sh" paths) || fail "paths verb failed"
for _k in bin payload man state config runtime profiles; do
  printf '%s\n' "$_pv" | grep -q "^$_k$(printf '\t')" \
    || fail "paths omits the '$_k' root; a consumer of this verb then guesses"
done
printf '%s\n' "$_pv" | while IFS= read -r _l; do
  case $_l in
    *"$(printf '\t')"/*) ;;
    *) fail "paths line is not 'key<TAB>/absolute/path': [$_l]" ;;
  esac
done

# COPY MODE OWNS DIFFERENT ROOTS, and the payload is the one that differs most:
# a copying install places its tree AT the prefix, so there is no separate
# payload directory and naming one would send an audit at a path that has never
# existed.
_pu=$(sh "$HERE/setup.sh" paths | sed -n 's/^payload\t//p')
_pc=$(HWDP_INSTALL_COPY=1 PREFIX=/opt/hwdp sh "$HERE/setup.sh" paths \
      | sed -n 's/^payload\t//p')
[ "$_pc" = /opt/hwdp ] \
  || fail "copy mode must declare the prefix itself as the payload, got '$_pc'"
[ "$_pu" != "$_pc" ] || fail "the two modes declared the same payload root"
pass "the paths verb declares every root, and differs by mode"

# --- check AUDITS this rig's UI override, and only ever WARNS ----------------
# Both findings describe a deliberate human choice that `install` cannot fix,
# so they must not FAIL: a check reporting what apply can never clear goes
# permanently red, which is a lesson this fleet has already paid for once.
#
# They exist because six override keys were once hand-pinned to the lodpi set
# on a 4K, and every one made something smaller. Two shapes are detectable
# without knowing the human's intent, and these are they.
sh "$HERE/setup.sh" install >/dev/null || fail "reinstall for the audit failed"
_prof=$T/profiles; mkdir -p "$_prof"
_id=$(sh "$HERE/bin/hwdp" id 2>/dev/null) || _id=
if [ -z "$_id" ]; then
  note "no displays here, so the override audit cannot be exercised"
else
  aud() { KANSHI_PROFILES="$_prof" sh "$HERE/setup.sh" check 2>&1; }

  # No override: both audits report OK, nothing invented.
  rm -f "$_prof/$_id.ui"
  aud | grep -q "no UI override for this rig" \
    || fail "check did not report the absence of an override"

  # A pin EQUAL to what the set already gives. Changes nothing today and
  # FREEZES the key against a future retune, so nothing ever looks wrong
  # enough to catch it: the worst kind, and TITLE_FONT was exactly this.
  _cal=$(KANSHI_PROFILES=$T/nope sh "$HERE/bin/hwdp" ui 2>/dev/null \
         | sed -n 's/^TITLE_FONT=//p')
  printf 'TITLE_FONT=%s\n' "$_cal" > "$_prof/$_id.ui"
  aud | grep -q "pins TITLE_FONT to the value the calibrated set" \
    || fail "check missed a redundant pin (equal to the calibrated value)"

  # A SHRINK-ONLY key pinned where the set says EMPTY. Empty means "keep your
  # own config value", so pinning one makes that thing SMALLER.
  _bare=$(KANSHI_PROFILES=$T/nope sh "$HERE/bin/hwdp" ui 2>/dev/null)
  if [ -z "$(printf '%s\n' "$_bare" | sed -n 's/^KITTY_FONT=//p')" ]; then
    printf 'KITTY_FONT=10\n' > "$_prof/$_id.ui"
    aud | grep -q "SHRINK-ONLY" \
      || fail "check missed a shrink-only key pinned on a hi-res rig"
    # ...and it is a WARN, so the overall status stays clean.
    KANSHI_PROFILES="$_prof" sh "$HERE/setup.sh" check >/dev/null 2>&1 \
      || fail "a shrink-only pin made check FAIL; it must only WARN, or the
sweep goes permanently red over a choice apply cannot change"
  else
    note "this rig resolves lodpi, so the shrink-only case is not applicable"
  fi

  # A legitimate pin trips neither audit.
  printf 'CURSOR_SIZE=64\n' > "$_prof/$_id.ui"
  aud | grep -q "no redundant pins" \
    || fail "a legitimate pin was reported as redundant"
  aud | grep -q "pins no shrink-only key" \
    || fail "a legitimate pin was reported as a shrink-only pin"
  rm -f "$_prof/$_id.ui"
  pass "check audits the UI override and only warns"
fi
