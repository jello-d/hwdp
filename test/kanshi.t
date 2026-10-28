#!/bin/sh
# kanshi.t - the supervisor touches only ITS OWN session's kanshi, and notices
# when that kanshi dies even with no event to wake it.
#
# THE PROCESS TABLE IS GLOBAL. `watch` used to find kanshi by name alone, so a
# supervisor in ANY session adopted whatever kanshi the box was running, HUPed
# it on every nudge, and KILLED it at teardown. Found live: this package's own
# suite, run on a desktop, SIGTERMed the session's kanshi (exit 0, it catches
# TERM) and the outputs went unmanaged. hotplug.t and lockfd.t stubbed kanshi
# and pkill but not pgrep; mgr.t had warned about exactly this in a comment.
#
# THE DECOYS ARE REAL PROCESSES NAMED kanshi (a script's comm is its own
# basename), so the real pgrep finds them and nothing here is stubbed away. A
# test that stubs pgrep cannot see this class at all.
#
# AND THE DEATH: the liveness check ran only when an event arrived, so a kanshi
# that died in a quiet hour stayed dead for the hour. The hotplug poller now
# announces it. Here inotifywait emits nothing, so the poller is the only
# thing that can wake the loop.
. "$(dirname "$0")/harness_lib"
harness_init kanshi

MGR=$HERE/bin/hwdp
mkdir -p "$T/bin" "$T/hooks/changed.d" "$T/drm" "$T/decoy" "$T/other"
command -v flock >/dev/null 2>&1 || skip "flock not installed"

python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' \
  "$T/run/wayland-test" 2>/dev/null || skip "cannot make a unix socket"

# A kanshi stand-in that records every HUP it receives: <log>.
_mk_kanshi() {
  cat > "$1" <<EOF
#!/bin/sh
trap 'echo hup >> "$2"' HUP
while :; do sleep 0.2; done
EOF
  chmod +x "$1"
}
_mk_kanshi "$T/decoy/kanshi" "$T/foreign.hups"
_mk_kanshi "$T/bin/kanshi" "$T/ours.hups"
printf '#!/bin/sh\nexec sleep 3600\n' > "$T/bin/inotifywait"
chmod +x "$T/bin/inotifywait"
: > "$T/wayfire.ini"

# A FOREIGN kanshi: same name, same uid, a different session.
XDG_RUNTIME_DIR="$T/other" WAYLAND_DISPLAY=wayland-test \
  "$T/decoy/kanshi" &
_foreign=$!
_pids=$_foreign
# Re-armed as each process starts, so the trap always names every pid.
_arm() { harness_cleanup "kill $_pids 2>/dev/null"; }
_arm

_wait_for() {   # <seconds> <command...>: poll until the command succeeds
  _n=$(($1 * 4)); shift
  while [ "$_n" -gt 0 ]; do
    "$@" && return 0
    sleep 0.25; _n=$((_n - 1))
  done
  return 1
}
_alive() { [ -n "$(ps -o pid= -p "$1" 2>/dev/null)" ]; }
_has() { [ -s "$1" ]; }
_wait_for 5 _alive "$_foreign" || fail "the foreign decoy did not start"

# EXECs, so call it in a subshell: `( _env cmd ) &` makes $! the command's
# own pid. A plain function call backgrounded gives the pid of a wrapper
# subshell, and killing that orphaned the real process (measured: one leaked
# decoy per run, and a TERM check that watched the wrapper exit).
_env() {
  exec env XDG_RUNTIME_DIR="$T/run" WAYLAND_DISPLAY=wayland-test DISPLAY= \
    KANSHI_PROFILES="$T/profiles" KANSHI_STICKY="$T/sticky" \
    KANSHI_OUT="$T/kanshi.conf" HWDP_DRM="$T/drm" \
    HWDP_PROVIDER_ROOT="$T/no-providers" \
    HWDP_HOOK_ROOT="$T/hooks" WAYFIRE_CONFIG_FILE="$T/wayfire.ini" \
    PATH="$T/bin:$PATH" "$@"
}

# --- 1. a NUDGE reloads our session's kanshi and nobody else's ---------------
# Hold the lock so `hwdp watch` takes the nudge path, with one kanshi in our
# session beside the foreign one. The positive half is what keeps this honest:
# a filter that matched nothing would pass the negative half alone.
mkdir -p "$T/run/hwdp"
# ONE process holds it: `flock FILE sleep` forks, and killing flock would
# leave its sleep holding the lock into the supervisor test below.
( flock 9 && exec sleep 30 ) 9>"$T/run/hwdp/watch.lock" &
_holder=$!
_pids="$_pids $_holder"
_arm
( _env "$T/bin/kanshi" ) &
_ours=$!
_pids="$_pids $_ours"
_arm
_wait_for 5 _alive "$_ours" || fail "our decoy did not start"
sleep 0.3
( _env "$MGR" watch ) >"$T/nudge.log" 2>&1 || fail "the nudge failed"
_wait_for 5 _has "$T/ours.hups" \
  || fail "a nudge did not reload this session's kanshi"
sleep 1    # the nudge's delayed second shot
[ -s "$T/foreign.hups" ] && fail "a nudge HUPed another session's kanshi"
kill "$_ours" "$_holder" 2>/dev/null
wait "$_ours" "$_holder" 2>/dev/null || :
pass "a nudge reloads this session's kanshi and no other"

# --- 2. a supervisor neither adopts nor kills a stranger ---------------------
( _env HWDP_WATCH_DAEMONIZED=1 HWDP_HOTPLUG_POLL=1 \
  "$MGR" watch ) >"$T/mgr.log" 2>&1 &
_mgr=$!
_pids="$_pids $_mgr"
_arm
_pidf=
_found() {
  for _f in "$T"/run/hwdp/watch.*.kanshi; do
    [ -s "$_f" ] && { _pidf=$_f; return 0; }
  done
  return 1
}
_wait_for 15 _found \
  || fail "the supervisor never recorded a kanshi: $(cat "$T/mgr.log")"
_k1=$(cat "$_pidf")
[ "$_k1" != "$_foreign" ] \
  || fail "the supervisor adopted another session's kanshi"
_pids="$_pids $_k1"
_arm

# --- 3. a kanshi that dies with NO event is restarted -------------------------
kill "$_k1"
_restarted() {
  _k=$(cat "$_pidf" 2>/dev/null)
  [ -n "$_k" ] && [ "$_k" != "$_k1" ] && _alive "$_k"
}
_wait_for 10 _restarted \
  || fail "a dead kanshi was not restarted: $(cat "$T/mgr.log")"
grep -q 'kanshi gone, restarting' "$T/mgr.log" \
  || fail "the restart was not logged"
_k2=$(cat "$_pidf")
_pids="$_pids $_k2"
_arm

kill "$_mgr"
_gone() { ! _alive "$_mgr"; }
_wait_for 10 _gone || fail "the supervisor did not exit on TERM"
_alive "$_foreign" \
  || fail "the supervisor's teardown killed another session's kanshi"
[ -s "$T/foreign.hups" ] \
  && fail "the supervisor HUPed another session's kanshi"
pass "a supervisor leaves a stranger's kanshi alone, restarts its own"
