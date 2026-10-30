#!/bin/sh
# identify.t - `hwdp identify`: label every monitor through a PROVIDER.
#
# The drawing is a provider (the shipped one is GTK layer shell, proven on a
# nested compositor by screenshot, which a suite cannot do), so this pins the
# contract around it: which provider runs, what it is told, that the pid a
# caller holds IS the overlay (the layout tool kills it to toggle it off, and
# a wrapper's pid would leave the labels up), and the refusals.
. "$(dirname "$0")/harness_lib"
harness_init identify

KA=$HERE/bin/hwdp
mkdir -p "$T/bin" "$T/user/identify" "$T/user/layout"

# Two outputs: a rotated 4K and a laptop panel, so the token and the size in
# a label are both exercised.
cat > "$T/user/layout/10-stub" <<'EOF'
#!/bin/sh
printf 'Acme A SN1\tDP-1\t3840\t2160\t600\t340\t60\t90\t1\t0\t0\t1\n'
printf 'Acme B SN2\teDP-1\t2880\t1800\t300\t190\t60\tnormal\t2\t2160\t0\t1\n'
EOF
chmod +x "$T/user/layout/10-stub"

# A stand-in provider: records how it was called, then stays up like an
# overlay until it is told to stop.
cat > "$T/user/identify/50-record" <<EOF
#!/bin/sh
[ "\$1" = probe ] && exit \${REC_PROBE:-0}
echo "\$\$" > "$T/rec.pid"
echo "\$*" > "$T/rec.args"
cat > "$T/rec.labels"
trap 'exit 0' TERM
_n=0   # a ceiling, so a regression that orphans it cannot hang the suite
while [ "\$_n" -lt 50 ]; do sleep 0.2; _n=\$((_n + 1)); done
EOF
# An earlier one that cannot run here: it must be skipped, not fatal.
cat > "$T/user/identify/10-cannot" <<'EOF'
#!/bin/sh
[ "$1" = probe ] && exit 1
echo "a provider whose probe failed was run anyway" >&2
exit 9
EOF
chmod +x "$T/user/identify/50-record" "$T/user/identify/10-cannot"

# EXECs, so `( run ... ) &` makes $! the provider (see the unmapped.t note).
run() {
  exec env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    WAYLAND_DISPLAY="${WL-wayland-test}" XDG_RUNTIME_DIR="$T/run" \
    HWDP_PROVIDER_ROOT="$T/user" HWDP_MACHINE_PROVIDERS="$T/no-machine" \
    REC_PROBE="${REC_PROBE:-0}" sh "$KA" identify "$@"
}
mkdir -p "$T/run"

# --- the provider that runs, what it is told, and whose pid it is -----------
# Its output goes nowhere: an orphaned provider (the no-exec regression) must
# not hold the suite's own stdout open, which hung a plant run here.
( run --seconds 7 --parent 4242 ) >/dev/null 2>&1 &
_pid=$!
harness_cleanup "kill $_pid 2>/dev/null"
_i=0
while [ "$_i" -lt 40 ] && [ ! -s "$T/rec.labels" ]; do
  sleep 0.25; _i=$((_i + 1))
done
[ -s "$T/rec.labels" ] || fail "the provider never ran"
[ "$(cat "$T/rec.pid")" = "$_pid" ] \
  || fail "the caller's pid must BE the provider (exec), got a wrapper"
[ "$(cat "$T/rec.args")" = "show --seconds 7 --parent 4242" ] \
  || fail "the provider was called as: $(cat "$T/rec.args")"
grep -qx '0 0 2160 3840 DP-1  EP  2160x3840' "$T/rec.labels" \
  || fail "the rotated label is wrong: $(cat "$T/rec.labels")"
grep -qx '2160 0 1440 900 eDP-1  BL  1440x900' "$T/rec.labels" \
  || fail "the scaled built-in label is wrong: $(cat "$T/rec.labels")"
kill "$_pid"; wait "$_pid" 2>/dev/null || :
ls "$T/run/hwdp/".identify.* >/dev/null 2>&1 \
  && fail "the label file was left behind"
pass "the first provider that can run is exec'd, told the labels and args"

# --- no provider can run: say so --------------------------------------------
if ( REC_PROBE=1 run ) >/dev/null 2>"$T/err"; then fail "ran with no provider"
else _rc=$?; fi
[ "$_rc" -eq 4 ] || fail "no provider: exit $_rc, expected 4"
grep -q 'no identify provider can run here' "$T/err" \
  || fail "no provider: $(cat "$T/err")"
pass "no provider that can run is exit 4, said plainly"

# --- refusals ---------------------------------------------------------------
( run --seconds soon ) >/dev/null 2>&1 && fail "a non-numeric --seconds"
( run --colour pink ) >/dev/null 2>&1 && fail "an unknown argument"
rm -f "$T/user/layout/10-stub"
if ( WL= run ) >/dev/null 2>"$T/err"; then fail "ran with no session"
else _rc=$?; fi
[ "$_rc" -eq 3 ] || fail "no session: exit $_rc, expected 3"
pass "bad arguments refused; no session is exit 3"
