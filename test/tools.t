#!/bin/sh
# tools.t - every shipped script PARSES under its own shell (dash for POSIX sh,
# bash for bash scripts), dispatched by shebang. A parse error ships a broken
# command; this is the cheapest guard against it.
. "$(dirname "$0")/lib.sh"
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
_n=0
for _f in "$HERE"/bin/* "$HERE"/setup.sh "$HERE"/test/run \
          "$HERE"/test/vm/run \
          "$HERE"/libexec/hwdp/*.sh "$HERE"/libexec/hwdp/cmd/* \
          "$HERE"/libexec/hwdp/providers/*/*; do
  [ -f "$_f" ] || continue
  _checker "$_f" || fail "parse error in $(basename "$_f")"
  _n=$((_n + 1))
done

pass "$_n scripts parse"
