#!/bin/sh
# tools.t - every shipped script PARSES under its own shell (dash for POSIX sh,
# bash for bash scripts), dispatched by shebang. A parse error ships a broken
# command; this is the cheapest guard against it.
. "$(dirname "$0")/harness_lib"
harness_init tools

_checker() {   # <file> -> the -n syntax check for its shebang
  case "$(head -1 "$1")" in
    *bash) bash -n "$1" ;;
    *python*) python3 -m py_compile "$1" ;;
    *) dash -n "$1" 2>/dev/null || sh -n "$1" ;;
  esac
}

# The shared library and every provider count too: a provider is shipped code
# that runs on a display change, and a parse error in one is a silently empty
# probe rather than a loud failure.
# A GLOB THAT MATCHES NOTHING MUST FAIL, NOT SHRINK. `[ -f ]` below skips an
# unexpanded pattern in SILENCE, so a rename that moves a whole group out from
# under its selector removes those files from the check while this test keeps
# passing and merely counts lower. Not hypothetical: these libraries were
# `*.sh` until they became `*_lib`, and the count dropped 21 -> 18 with nothing
# reported. Each group is asserted non-empty by name.
_group_nonempty() {   # <label> <paths...>
  _gl=$1; shift
  for _g in "$@"; do [ -e "$_g" ] && return 0; done
  fail "the $_gl selector matched NOTHING -- it has been renamed out from under
this check, which would otherwise pass while silently checking fewer files"
}
_group_nonempty "sourced library" "$HERE"/libexec/hwdp/*_lib
_group_nonempty "subcommand"      "$HERE"/libexec/hwdp/cmd/*
_group_nonempty "provider"        "$HERE"/libexec/hwdp/providers/*/*
_group_nonempty "bin"             "$HERE"/bin/*

_n=0
for _f in "$HERE"/bin/* "$HERE"/setup.sh "$HERE"/test/run \
          "$HERE"/test/vm/run \
          "$HERE"/libexec/hwdp/*_lib "$HERE"/libexec/hwdp/cmd/* \
          "$HERE"/libexec/hwdp/providers/*/*; do
  [ -f "$_f" ] || continue
  _checker "$_f" || fail "parse error in $(basename "$_f")"
  _n=$((_n + 1))
done

pass "$_n scripts parse"
