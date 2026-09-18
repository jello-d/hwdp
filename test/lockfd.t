#!/bin/sh
# lockfd.t - a hook must not inherit the supervisor's LOCK.
#
# `hwdp watch` guarantees a single supervisor with an flock on fd 9. File
# descriptors survive exec, so every hook -- and everything a hook spawns --
# inherits that fd and with it a share of the lock. A hook that starts a
# LONG-LIVED process therefore leaves the lock HELD after the supervisor is
# gone: `flock -n` keeps failing, every later `hwdp watch` silently takes the
# NUDGE path, and display management can never restart while reporting success.
#
# Found on a live box: no supervisor, no kanshi, and `fuser` on the lockfile
# naming two waybar processes as the holders. The bug was always latent -- it
# needed a hook that outlives its own invocation, and the bars hook (wb, which
# leaves waybar running) is the first one to do that.
#
# Its own file because the assertion requires KILLING the supervisor, which
# every other supervisor test needs alive.
. "$(dirname "$0")/lib.sh"
harness_init lockfd

MGR=$HERE/bin/hwdp
mkdir -p "$T/bin" "$T/hooks/changed.d" "$T/run" "$T/home" "$T/drm"

python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' \
  "$T/run/wayland-test" 2>/dev/null || skip "cannot make a unix socket"

for _c in kanshi inotifywait; do
  printf '#!/bin/sh\nexec sleep 3600\n' > "$T/bin/$_c"
  chmod +x "$T/bin/$_c"
done
printf '#!/bin/sh\nexit 0\n' > "$T/bin/pkill"; chmod +x "$T/bin/pkill"

mkdir -p "$T/drm/card0-DP-1"
printf 'connected\n' > "$T/drm/card0-DP-1/status"
printf 'edid-one' > "$T/drm/card0-DP-1/edid"
printf '1920x1080\n' > "$T/drm/card0-DP-1/modes"
: > "$T/wayfire.ini"

# The hook under test: it leaves something running behind it, exactly as the
# bars hook leaves waybar.
cat > "$T/hooks/changed.d/10-longlived" <<EOF
#!/bin/sh
sleep 300 &
echo \$! > "$T/longlived.pid"
EOF
chmod +x "$T/hooks/changed.d/10-longlived"

XDG_RUNTIME_DIR="$T/run" WAYLAND_DISPLAY=wayland-test DISPLAY= \
  HOME="$T/home" XDG_CONFIG_HOME="$T/config" \
  KANSHI_PROFILES="$T/profiles" KANSHI_STICKY="$T/sticky" \
  KANSHI_OUT="$T/kanshi.conf" HWDP_DRM="$T/drm" \
  HWDP_PROVIDER_ROOT="$T/no-providers" \
  HWDP_MACHINE_PROVIDERS="$T/no-providers" \
  HWDP_HOOK_ROOT="$T/hooks" HWDP_MACHINE_HOOKS="$T/no-machine-hooks" \
  WAYFIRE_CONFIG_FILE="$T/wayfire.ini" HWDP_WATCH_DAEMONIZED=1 \
  HWDP_HOTPLUG_POLL=0 \
  PATH="$T/bin:$PATH" "$MGR" watch >"$T/mgr.log" 2>&1 &
_mgr=$!
trap 'kill "$_mgr" 2>/dev/null; rm -rf "$T"' EXIT INT TERM

# The startup `changed` pass is enough to run the hook; no hotplug needed.
_i=0
while [ "$_i" -lt 60 ]; do
  [ -s "$T/longlived.pid" ] && break
  sleep 0.25; _i=$((_i + 1))
done
_lp=$(cat "$T/longlived.pid" 2>/dev/null)
[ -n "$_lp" ] \
  || fail "the hook never ran: $(cat "$T/mgr.log" 2>/dev/null)"
kill -0 "$_mgr" 2>/dev/null \
  || fail "supervisor died early: $(cat "$T/mgr.log" 2>/dev/null)"

# Take the supervisor away, leaving the hook's orphan behind.
kill "$_mgr" 2>/dev/null
_i=0
while [ "$_i" -lt 40 ]; do
  kill -0 "$_mgr" 2>/dev/null || break
  sleep 0.25; _i=$((_i + 1))
done

kill -0 "$_lp" 2>/dev/null \
  || fail "the orphan died with the supervisor; the test proves nothing"

# THE ASSERTION. The orphan is alive and must NOT be holding the lock, so a
# fresh flock has to succeed. If it does not, no new supervisor could start.
if ( flock -n 9 ) 9>"$T/run/hwdp-watch.lock"; then
  kill "$_lp" 2>/dev/null
  pass "a hook's orphan does not inherit the supervisor's lock"
else
  # Name the holder: the first version of this failed with the ORPHAN clean and
  # a lone `sleep` holding it -- the watchdog's, which outlives the subshell
  # cleanup kills. Without this the failure says "a hook inherited it" and
  # sends you after the wrong process.
  echo "--- holders:" >&2
  fuser -v "$T/run/hwdp-watch.lock" 2>&1 | sed 's/^/    /' >&2
  kill "$_lp" 2>/dev/null
  fail "a hook's orphan inherited the lock; no new supervisor could ever start"
fi
