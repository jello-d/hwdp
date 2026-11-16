#!/bin/sh
# settle.t - a display change is never lost between the poller seeing it and
# the settle acting on it.
#
# The poller moves its baseline to the new panel set the moment it reports a
# change, so whatever happens to the pending settle after that, nothing will
# report the change again. Three ways it could be lost, each forced here with
# a settle window widened by HWDP_SETTLE_S (found reading the code, after one
# unexplained hotplug.t failure, 2026-11-15):
#   superseded  a config event inside the window schedules a newer settle
#               WITHOUT re-generation, and the hotplug's stands down: kanshi
#               reloads a config that does not describe the new panel;
#   re-armed    the writers end inside the window and the loop cancels the
#               pending settle before re-arming;
#   SIGPIPE     the reader reopens the FIFO per line, so a writer writing in
#               the gap meets no reader and dies; a burst of config events is
#               the way to provoke it.
# The supervisor's own log (timestamped since 2026-11-15) is how each case
# knows where it stands, and what a failure prints.
. "$(dirname "$0")/harness_lib"
harness_init settle

_real=$(command -v inotifywait) || skip "inotifywait not installed"
MGR=$HERE/bin/hwdp
mkdir -p "$T/bin" "$T/hooks/changed.d" "$T/run" "$T/drm" "$T/cfg"
python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' \
  "$T/run/wayland-test" 2>/dev/null || skip "cannot make a unix socket"
printf '#!/bin/sh\nexec sleep 3600\n' > "$T/bin/kanshi"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/pkill"
chmod +x "$T/bin/kanshi" "$T/bin/pkill"
cat > "$T/bin/wlr-randr" <<EOF
_x=0
for _d in "$T"/drm/card0-*/; do
  [ -d "\$_d" ] || continue
  _n=\$(basename "\$_d"); _n=\${_n#card0-}
  _m=\$(head -1 "\$_d/modes" 2>/dev/null)
  _w=\${_m%%x*}; _h=\${_m##*x}
  _s=\$(cksum < "\$_d/edid" | cut -d' ' -f1)
  echo "\$_n \"Acme Inc. PANEL \$_s (\$_n)\""
  echo "  Make: Acme Inc."
  echo "  Model: PANEL"
  echo "  Serial: \$_s"
  echo "  Physical size: 530x300 mm"
  echo "  Enabled: yes"
  echo "  Modes:"
  echo "    \${_w}x\${_h} px, 60.000000 Hz (current)"
  echo "  Position: \${_x},0"
  echo "  Transform: normal"
  echo "  Scale: 1.000000"
  _x=\$((_x + _w))
done
EOF
chmod +x "$T/bin/wlr-randr"
printf '#!/bin/sh\necho changed >> "%s/changed.log"\n' "$T" \
  > "$T/hooks/changed.d/10-record"
chmod +x "$T/hooks/changed.d/10-record"
panel() {   # <connector> <edid> <WxH>
  mkdir -p "$T/drm/card0-$1"
  printf 'connected\n' > "$T/drm/card0-$1/status"
  printf '%s' "$2" > "$T/drm/card0-$1/edid"
  printf '%s\n' "$3" > "$T/drm/card0-$1/modes"
}
panel DP-1 edid-one 1920x1080
: > "$T/cfg/wayfire.ini"
LOG=$T/mgr.log

sup() {   # <settle seconds> [poll seconds]: a supervisor; sets _sup
  XDG_RUNTIME_DIR="$T/run" WAYLAND_DISPLAY=wayland-test DISPLAY= \
    HOME="$T/home" XDG_CONFIG_HOME="$T/config" \
    KANSHI_PROFILES="$T/profiles" KANSHI_STICKY="$T/sticky" \
    KANSHI_OUT="$T/kanshi.conf" HWDP_DRM="$T/drm" \
    HWDP_PROVIDER_ROOT="$T/no-providers" \
    HWDP_MACHINE_PROVIDERS="$T/no-providers" \
    HWDP_HOOK_ROOT="$T/hooks" HWDP_MACHINE_HOOKS="$T/no-machine-hooks" \
    WAYFIRE_CONFIG_FILE="$T/cfg/wayfire.ini" HWDP_WATCH_DAEMONIZED=1 \
    HWDP_HOTPLUG_POLL="${2:-1}" HWDP_SETTLE_S="$1" \
    PATH="$T/bin:$PATH" "$MGR" watch >>"$LOG" 2>&1 &
  _sup=$!
  harness_cleanup "kill $_sup 2>/dev/null"
}
await() {   # <ERE> <seconds> [count]: wait for the log to say it (count times)
  _i=0
  while [ "$_i" -lt $(($2 * 20)) ]; do
    [ "$(grep -c -E "$1" "$LOG" 2>/dev/null)" -ge "${3:-1}" ] && return 0
    sleep 0.05; _i=$((_i + 1))
  done
  return 1
}
in_config() { grep -q "$1" "$T/kanshi.conf" 2>/dev/null; }
# stop: the supervisor, and then its LOCK must come free. Anything of the
# supervisor's still holding fd 9 makes the next one a mere nudger (an
# orphaned `sleep` did, 2026-11-15). Its own teardown takes one 50ms tick at
# most (measured), so 0.5s is generous; past that, name the holder.
stop() {
  kill "$_sup" 2>/dev/null; wait "$_sup" 2>/dev/null
  _i=0
  until flock -n "$T/run/hwdp/watch.lock" true 2>/dev/null; do
    _i=$((_i + 1))
    [ "$_i" -lt 10 ] && { sleep 0.05; continue; }
    _h=$(for _p in $(fuser "$T/run/hwdp/watch.lock" 2>/dev/null); do
      ps -o pid=,ppid=,args= -p "$_p"; done)
    fail "the lock is still held 0.5s after the supervisor stopped: $_h"
  done
  : > "$LOG"
}

# --- superseded: a config event inside the hotplug's settle window ----------
sup 2
await 'watching .*watcher [0-9]+' 10 || fail "never armed: $(cat "$LOG")"
panel DP-2 edid-two 2560x1440
await 'display set changed' 10 || fail "the plug was not seen: $(cat "$LOG")"
printf 'x\n' >> "$T/cfg/wayfire.ini"
await 'settle [0-9]+ runs' 10 || fail "no settle ran: $(cat "$LOG")"
sleep 1
in_config 2560 || fail "a config event inside the window dropped the \
re-generation; kanshi.conf: $(cat "$T/kanshi.conf"); log: $(cat "$LOG")"
stop
pass "a config event during a hotplug's settle keeps the re-generation"

# --- re-armed: the writers end inside the window -----------------------------
sup 3
await 'watching .*watcher [0-9]+' 10 || fail "never armed: $(cat "$LOG")"
# A killed watcher is a zombie until the loop reaps it, and the poller (which
# asks `kill -0`) runs on meanwhile; the next event is what reaps it, so the
# writers end with THAT event's settle pending.
_w=$(sed -n 's/.*watcher \([0-9][0-9]*\),.*/\1/p' "$LOG" | tail -1)
kill "$_w"
panel DP-3 edid-three 1280x1024
await 'display set changed' 10 || fail "the plug was not seen: $(cat "$LOG")"
await 'writers ended' 10 || fail "the writers did not end: $(cat "$LOG")"
await 'watching .*watcher [0-9]+' 10 2 || fail "no re-arm: $(cat "$LOG")"
sleep 5
in_config 1280 || fail "a re-arm inside the window lost the hotplug; \
kanshi.conf: $(cat "$T/kanshi.conf"); log: $(cat "$LOG")"
stop
pass "writers ending during a hotplug's settle do not lose it"

# --- SIGPIPE: a burst of config events ---------------------------------------
sup 0.3
await 'watching .*watcher [0-9]+' 10 || fail "never armed: $(cat "$LOG")"
# Probabilistic by nature (the reader must be between lines when a write
# lands), so five rounds: the per-line reopen died in about one in three
# single rounds of 200.
_r=0
while [ "$_r" -lt 5 ]; do
  _n=0
  while [ "$_n" -lt 300 ]; do printf 'x\n' >> "$T/cfg/wayfire.ini"
    _n=$((_n + 1)); done
  sleep 0.5; _r=$((_r + 1))
done
sleep 2
grep -q 'writers ended' "$LOG" && fail "a burst of config events ended the \
writers: $(grep 'writers ended' "$LOG")"
stop
pass "five bursts of 300 config events do not kill the writers"

# --- the lock: nothing outlives the supervisor holding it -------------------
# Stopped just after it arms, the poller is at the start of a 5s sleep: a
# `sleep` that inherited fd 9 is orphaned holding the lock for ~5s, which
# stop() reports with the holder.
sup 0.3 5
await 'watching .*watcher [0-9]+' 10 || fail "never armed: $(cat "$LOG")"
sleep 0.2
stop
pass "the lock is free the moment the supervisor is gone"
