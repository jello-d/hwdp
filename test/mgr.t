#!/bin/sh
# mgr.t - `hwdp watch`'s coalesced settle, against stubs (no compositor).
#
# Two properties, both regressions we have actually been bitten by:
#   1. NO ZOMBIES. The settle used to be a tracked background child cancelled
#      with `kill`, and POSIX sh reaps a background child only on `wait` -- so
#      each burst left a `[kanshi-mgr] <defunct>` and the last settle of a
#      session was never reaped at all. The settle is now detached, so the
#      supervisor must own no children in state Z.
#   2. The burst still COALESCES: many events in, exactly one `changed` pass.
. "$(dirname "$0")/lib.sh"
harness_init mgr

command -v python3 >/dev/null 2>&1 || skip "needs python3 to make a unix socket"
command -v flock >/dev/null 2>&1   || skip "needs flock"

MGR="$HERE/bin/hwdp"
mkdir -p "$T/bin" "$T/hooks/changed.d" "$T/run"
: > "$T/wayfire.ini"

# kanshi-mgr's watchdog TERMs the supervisor the moment the compositor socket
# goes away, so the test needs a REAL unix socket for it to stat.
python3 -c 'import socket,sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$T/run/wayland-test"

# Stubs. pgrep/pkill are stubbed above all so this test can never adopt -- and
# then, at teardown, KILL -- a real kanshi on the developer's own box.
cat > "$T/bin/kanshi" <<'EOF'
#!/bin/sh
exec sleep 300
EOF
cat > "$T/bin/kanshi-autoscale" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$T/bin/pkill" <<'EOF'
#!/bin/sh
exit 0
EOF
# A burst of three events, then hold the stream open like the real -m monitor.
cat > "$T/bin/inotifywait" <<'EOF'
#!/bin/sh
printf 'a\nb\nc\n'
exec sleep 300
EOF
chmod +x "$T/bin"/kanshi "$T/bin"/kanshi-autoscale "$T/bin"/pgrep \
  "$T/bin"/pkill "$T/bin"/inotifywait

cat > "$T/hooks/changed.d/10-record" <<EOF
#!/bin/sh
echo run >> "$T/changed.log"
EOF
chmod +x "$T/hooks/changed.d/10-record"

XDG_RUNTIME_DIR="$T/run" WAYLAND_DISPLAY=wayland-test \
  HWDP_HOOK_ROOT="$T/hooks" HWDP_MACHINE_HOOKS="$T/no-machine-hooks" \
  WAYFIRE_CONFIG_FILE="$T/wayfire.ini" HWDP_WATCH_DAEMONIZED=1 \
  PATH="$T/bin:$PATH" "$MGR" watch >"$T/mgr.log" 2>&1 &
_mgr=$!
trap 'kill "$_mgr" 2>/dev/null; rm -rf "$T"' EXIT INT TERM

_runs() { [ -f "$T/changed.log" ] && wc -l < "$T/changed.log" || echo 0; }

# Startup fires `changed` once by design; the burst adds exactly one more once
# its 0.3s settle elapses. Poll rather than sleep a fixed time.
_i=0
while [ "$_i" -lt 60 ]; do
  [ "$(_runs)" -ge 2 ] && break
  sleep 0.25
  _i=$((_i + 1))
done
sleep 0.75          # let any SECOND, uncoalesced settle land before counting

kill -0 "$_mgr" 2>/dev/null \
  || fail "supervisor died early: $(cat "$T/mgr.log" 2>/dev/null)"

# 1) the supervisor owns no zombies.
_z=$(ps -eo ppid=,state= 2>/dev/null \
     | awk -v p="$_mgr" '$1 == p && $2 ~ /^Z/' | wc -l)
[ "$_z" -eq 0 ] || fail "supervisor left $_z zombie child(ren)"

# 2) the three-event burst coalesced: one startup pass + one burst pass.
_n=$(_runs)
[ "$_n" -eq 2 ] \
  || fail "expected 2 changed passes (startup + coalesced burst), got $_n"

kill "$_mgr" 2>/dev/null
pass "settle detaches (no zombies) + burst coalesces"
