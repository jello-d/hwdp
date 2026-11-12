#!/bin/sh
# applied.t - `hwdp watch` fires the `changed` hooks only once kanshi has
# APPLIED, at startup and after every settle.
#
# They used to run before the HUP, and at startup the instant kanshi was
# spawned, so on a hotplug the hooks saw the layout the compositor improvised
# rather than the profile: measured on dragonfly (2026-11-12), a re-docked 4K
# was still landscape when the bars hook rebuilt the bars, and they stayed in
# the wrong arrangement with nothing firing after kanshi's rotation landed.
#
# The supervisor runs as the daemon does, its output IN its own log, which is
# where kanshi's verdict lands. The stub kanshi takes a second to say
# "applied", on start and on every HUP, and the hook records how many such
# lines the log held when it ran: each pass must see its own.
. "$(dirname "$0")/harness_lib"
harness_init applied

command -v python3 >/dev/null 2>&1 || skip "needs python3 to make a unix socket"
command -v flock >/dev/null 2>&1   || skip "needs flock"

KA="$HERE/bin/hwdp"
mkdir -p "$T/bin" "$T/hooks/changed.d" "$T/run" "$T/home"
: > "$T/wayfire.ini"
LOG=$T/watch.log
: > "$LOG"

python3 -c 'import socket,sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$T/run/wayland-test"

# A REAL process named kanshi (a script's comm is its basename: the python
# path is the shebang itself, since `env python3` would re-exec and rename
# it), so the supervisor finds it as it finds the real one: by name AND this
# session's environment, which the developer's own kanshi does not share.
# NOT a shell script: the supervisor ignores HUP and children inherit that,
# and a POSIX shell that starts with a signal ignored cannot trap it, where
# real kanshi (C) installs its own handler. Python can, as kanshi does.
cat > "$T/bin/kanshi" <<'STUB'
#!/usr/bin/python3
import signal, sys, time
pending = []
def say():
    print("configuration for profile 'stub' applied", flush=True)
signal.signal(signal.SIGHUP, lambda *a: pending.append(time.time() + 1))
time.sleep(1)
say()
while True:
    time.sleep(0.1)
    while pending and pending[0] <= time.time():
        pending.pop(0)
        say()
STUB
# A burst of three events, then hold the stream open like the real monitor.
cat > "$T/bin/inotifywait" <<'STUB'
#!/bin/sh
sleep 3
printf 'a\nb\nc\n'
exec sleep 300
STUB
chmod +x "$T/bin/kanshi" "$T/bin/inotifywait"

cat > "$T/hooks/changed.d/10-record" <<STUB
#!/bin/sh
grep -c 'applied' "$LOG" >> "$T/order"
STUB
chmod +x "$T/hooks/changed.d/10-record"

XDG_RUNTIME_DIR="$T/run" WAYLAND_DISPLAY=wayland-test DISPLAY= \
  HOME="$T/home" XDG_CONFIG_HOME="$T/config" \
  KANSHI_PROFILES="$T/profiles" KANSHI_STICKY="$T/sticky" \
  KANSHI_OUT="$T/kanshi.conf" HWDP_HOTPLUG_POLL=600 \
  HWDP_PROVIDER_ROOT="$T/no-providers" \
  HWDP_MACHINE_PROVIDERS="$T/no-providers" \
  HWDP_HOOK_ROOT="$T/hooks" HWDP_MACHINE_HOOKS="$T/no-machine-hooks" \
  WAYFIRE_CONFIG_FILE="$T/wayfire.ini" HWDP_WATCH_DAEMONIZED=1 \
  HWDP_WATCH_LOG="$LOG" PATH="$T/bin:$PATH" \
  sh -c 'exec "$1" watch' _ "$KA" >>"$LOG" 2>&1 &
_sv=$!
harness_cleanup "kill $_sv 2>/dev/null; pkill -f '$T/bin/kanshi' 2>/dev/null"

_i=0
while [ "$_i" -lt 60 ]; do
  [ -f "$T/order" ] && [ "$(wc -l < "$T/order")" -ge 2 ] && break
  sleep 0.25
  _i=$((_i + 1))
done
kill "$_sv" 2>/dev/null

[ -s "$T/order" ] || fail "no changed pass ran: $(cat "$LOG")"
_first=$(sed -n 1p "$T/order")
_second=$(sed -n 2p "$T/order")
[ "${_first:-0}" -ge 1 ] \
  || fail "the startup pass ran before kanshi applied (it saw $_first)"
pass "the startup changed pass waits for kanshi to apply"
_why="the settle ran its hooks before kanshi re-applied"
[ "${_second:-0}" -ge 2 ] || fail "$_why (saw ${_second:-none}): $(cat "$LOG")"
grep -q 'said nothing about the reload' "$LOG" \
  && fail "the wait timed out instead of seeing kanshi's verdict: $(cat "$LOG")"
pass "a settle HUPs kanshi, then waits for it to apply, then the hooks"
