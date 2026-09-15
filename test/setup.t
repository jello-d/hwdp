#!/bin/sh
# setup.t - the install roundtrip against a scratch PREFIX: install -> assert
# the ~/.local symlinks land -> check -> uninstall -> assert they are gone.
# Nothing outside the scratch dir is touched.
. "$(dirname "$0")/lib.sh"
harness_init setup

PREFIX=$T/local
export PREFIX
# Keep XDG_* under the scratch tree too, so nothing escapes T.
XDG_BIN_HOME=$PREFIX/bin
XDG_DATA_HOME=$PREFIX/share
export XDG_BIN_HOME XDG_DATA_HOME

sh "$HERE/setup.sh" install >/dev/null || fail "install errored"

# every bin/ tool is linked into PREFIX/bin, pointing back at the repo
for _t in "$HERE"/bin/*; do
  _n=$(basename "$_t")
  _l=$XDG_BIN_HOME/$_n
  [ -L "$_l" ] || fail "$_n not linked into PREFIX/bin"
  [ "$(readlink "$_l")" = "$_t" ] || fail "$_n link does not point at the repo"
done

# the man page landed
[ -e "$XDG_DATA_HOME/man/man1/hwdp.1" ] || fail "man page not installed"

# check runs against the sandbox: put the sandbox bin FIRST on PATH so
# `command -v` resolves the just-linked tools, not whatever the box has. Deps
# may be absent here, so do not gate on RC -- only that it reports the tools.
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

# A prefix that once held a COPY install keeps a REAL libexec/<pkg>/ directory,
# and both placement commands NEST rather than replace against one: `cp -a`
# puts the tree a level down, and `ln -sfn` buries the link at
# libexec/hwdp/hwdp. The symlink branch used to miss this, so the stale tree
# went on resolving in front of the new link -- silently, because the tools
# find their libexec from their own real path and kept working. Found on a live
# box by check's WARN; pinned here so it cannot come back.
rm -rf "$PREFIX/libexec/hwdp"
mkdir -p "$PREFIX/libexec/hwdp/cmd"
: > "$PREFIX/libexec/hwdp/probe.sh"           # a stale file from that install
sh "$HERE/setup.sh" install >/dev/null \
  || fail "re-install over a real dir errored"
[ -L "$PREFIX/libexec/hwdp" ] \
  || fail "libexec/hwdp is not a symlink; the install nested under a stale dir"
[ -e "$PREFIX/libexec/hwdp/hwdp" ] \
  && fail "the link was nested one level down (libexec/hwdp/hwdp)"
[ -e "$PREFIX/libexec/hwdp/probe.sh" ] \
  || fail "the linked libexec does not resolve probe.sh"

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
# own libexec from its new home, and must still prune a departed tool -- which
# a copy cannot advertise the way a dangling symlink does, hence the manifest.
# XDG_BIN_HOME/XDG_DATA_HOME are set above and OVERRIDE PREFIX for those dirs,
# so relocating an install means overriding all three. Worth knowing before
# pointing a system install at /usr/local from an environment that exports them.
C=$T/sys
sys() { env HWDP_INSTALL_COPY=1 PREFIX="$C" XDG_BIN_HOME="$C/bin" \
  XDG_DATA_HOME="$C/share" sh "$HERE/setup.sh" "$@"; }
sys install >/dev/null || fail "copy-mode install errored"

# PER COMMAND, not per package: a shared prefix gets only what something
# root-side actually runs. `run-scaled` is a session launcher -- publishing it
# system-side would put a second copy of a user-only tool on PATH, which is the
# shadow the single-copy rule exists to forbid.
[ -e "$C/bin/hwdp" ] || fail "the shared command was not installed"
[ -e "$C/bin/run-scaled" ] \
  && fail "a session tool was installed at the SHARED prefix"
grep -qx hwdp "$C/libexec/.hwdp-installed" \
  || fail "the manifest does not record the shared command"
grep -qx run-scaled "$C/libexec/.hwdp-installed" \
  && fail "the manifest claims a tool the shared prefix never got"

# An earlier over-install is SWEPT, not left to shadow.
: > "$C/bin/run-scaled"; chmod +x "$C/bin/run-scaled"
sys install >/dev/null || fail "re-install errored"
[ -e "$C/bin/run-scaled" ] \
  && fail "an over-installed session tool was left at the shared prefix"
[ -f "$C/bin/hwdp" ] && [ ! -L "$C/bin/hwdp" ] \
  || fail "copy mode left a symlink, not a real file"
[ -f "$C/libexec/hwdp/probe.sh" ] && [ ! -L "$C/libexec/hwdp" ] \
  || fail "copy mode did not copy the libexec tree"
[ "$("$C/bin/hwdp" help | grep -c '^  hwdp ')" -eq 7 ] \
  || fail "the copied hwdp cannot resolve its own libexec"

printf 'hwdp\nrun-scaled\ndeparted\n' > "$C/libexec/.hwdp-installed"
: > "$C/bin/departed"
sys install >/dev/null || fail "copy-mode re-install errored"
[ -e "$C/bin/departed" ] && fail "copy mode kept a departed tool"
[ -f "$C/bin/hwdp" ] || fail "copy-mode re-install lost hwdp"

sys uninstall >/dev/null || fail "copy-mode uninstall errored"
[ -e "$C/bin/hwdp" ] && fail "copy-mode uninstall left the binary"
[ -e "$C/libexec/hwdp" ] && fail "copy-mode uninstall left the libexec tree"

sh "$HERE/setup.sh" uninstall >/dev/null || fail "uninstall errored"
for _t in "$HERE"/bin/*; do
  _n=$(basename "$_t")
  [ -e "$XDG_BIN_HOME/$_n" ] && fail "$_n still present after uninstall" || :
done
[ -e "$XDG_DATA_HOME/man/man1/hwdp.1" ] && fail "man page not removed" || :

pass "install/check/uninstall roundtrip"
