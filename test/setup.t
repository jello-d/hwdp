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

sh "$HERE/setup.sh" uninstall >/dev/null || fail "uninstall errored"
for _t in "$HERE"/bin/*; do
  _n=$(basename "$_t")
  [ -e "$XDG_BIN_HOME/$_n" ] && fail "$_n still present after uninstall" || :
done
[ -e "$XDG_DATA_HOME/man/man1/hwdp.1" ] && fail "man page not removed" || :

pass "install/check/uninstall roundtrip"
