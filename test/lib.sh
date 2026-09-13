# test/lib.sh - harness for hwdp's shell tests (test/*.t), sourced by each.
#
# Call `harness_init <name>`: sets HERE (the repo root, so a test reaches bin/ +
# setup.sh), a private scratch dir T (removed on exit), and the pass/fail
# helpers. Everything a test touches is confined to T; nothing outside it is
# written. POSIX sh; run one with `sh test/<name>.t`, all with test/run.
#
# THE SANDBOX IS BUILT IN, not left to each test to remember. harness_init
# repoints HOME and the XDG dirs into $T, so a tool under test that resolves
# its own config path lands in the scratch dir whatever the test does.
#
# That is not belt and braces. mgr.t stubbed a binary on PATH and relied on the
# stub to keep the code under test away from the real config; then `watch`
# changed to call its sibling IN PROCESS, the stub went dead, and the run
# reached the developer's actual ~/.config -- about to write a sticky scale
# into it. The test had not changed; the code's path to $HOME had. Pinning the
# environment here is the only version of this that cannot rot, because a new
# test gets it without knowing it needs it.
#
# A test that genuinely needs the real environment must say so explicitly by
# overriding these AFTER harness_init, which is a thing a reader can see.
harness_init() {   # <name>
  TEST_NAME=$1
  HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
  T=$(mktemp -d)
  trap 'rm -rf "$T"' EXIT INT TERM

  HOME=$T/home
  XDG_CONFIG_HOME=$T/config
  XDG_DATA_HOME=$T/data
  XDG_CACHE_HOME=$T/cache
  XDG_RUNTIME_DIR=$T/run
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" \
    "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR"
  export HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR

  # The machine roots are absolute and outside $T by definition, so they cannot
  # be relocated -- only pointed somewhere harmless. A provider or hook dropped
  # into /etc on the developer's box must never decide a test run.
  HWDP_MACHINE_PROVIDERS=$T/no-machine-providers
  HWDP_MACHINE_HOOKS=$T/no-machine-hooks
  export HWDP_MACHINE_PROVIDERS HWDP_MACHINE_HOOKS
}
pass() { printf 'ok   %s%s\n' "$TEST_NAME" "${1:+ ($1)}"; }
fail() { printf 'FAIL %s: %s\n' "$TEST_NAME" "$1" >&2; exit 1; }
skip() { printf 'skip %s (%s)\n' "$TEST_NAME" "$1"; exit 0; }
