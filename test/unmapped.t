#!/bin/sh
# unmapped.t - the `unmapped` and `mapped` edges, and `hwdp profile`.
#
# A desk that needs a layout profile and has none must be ANNOUNCED, so the
# integrator can remind the user and open the layout tool; one that gets a
# profile must be announced too, so the reminder can be cleared. By the
# user's decision there is no "declined": an unmapped desk is announced again
# at the next login or hotplug for as long as it stays unmapped.
#
#   unmapped  `watch`, after the set holds still HWDP_UNMAPPED_SETTLE seconds
#   mapped    `arrange` / `capture`, when a profile is recorded
#
# Needing one is `hwdp profile --missing`: two or more panels ATTACHED and no
# profile for the set. One panel has nothing to arrange.
. "$(dirname "$0")/harness_lib"
harness_init unmapped

MGR=$HERE/bin/hwdp
mkdir -p "$T/bin" "$T/hooks/unmapped.d" "$T/hooks/mapped.d" "$T/run" \
  "$T/home" "$T/drm" "$T/profiles"

python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' \
  "$T/run/wayland-test" 2>/dev/null || skip "cannot make a unix socket"

for _c in kanshi inotifywait; do
  printf '#!/bin/sh\nexec sleep 3600\n' > "$T/bin/$_c"
  chmod +x "$T/bin/$_c"
done
# wlr-randr DERIVED from the fake DRM tree, so both views agree (hotplug.t).
cat > "$T/bin/wlr-randr" <<EOF
#!/bin/sh
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
for _e in unmapped mapped; do
  cat > "$T/hooks/$_e.d/10-record" <<EOF
#!/bin/sh
echo "\$HWDP_ID \${HWDP_PROFILE:-}" >> "$T/$_e.log"
EOF
  chmod +x "$T/hooks/$_e.d/10-record"
done
: > "$T/wayfire.ini"

panel() {   # <connector> <edid seed>
  mkdir -p "$T/drm/card0-$1"
  printf 'connected\n' > "$T/drm/card0-$1/status"
  printf '%s' "$2" > "$T/drm/card0-$1/edid"
  printf '1920x1080\n' > "$T/drm/card0-$1/modes"
}

# hw: hwdp <args>, sandboxed exactly like the supervisor. With _HWEXEC set it
# EXECs, so `( _HWEXEC=1 hw watch ) &` makes $! the supervisor itself: a
# function backgrounded plainly gives the pid of a wrapper, and killing that
# left the real supervisor running and holding the lock (kanshi.t's lesson).
hw() {
  ${_HWEXEC:+exec} env XDG_RUNTIME_DIR="$T/run" \
    WAYLAND_DISPLAY=wayland-test DISPLAY= \
    HOME="$T/home" XDG_CONFIG_HOME="$T/config" \
    KANSHI_PROFILES="$T/profiles" KANSHI_STICKY="$T/sticky" \
    KANSHI_OUT="$T/kanshi.conf" HWDP_DRM="$T/drm" \
    HWDP_PROVIDER_ROOT="$T/no-providers" \
    HWDP_MACHINE_PROVIDERS="$T/no-providers" \
    HWDP_HOOK_ROOT="$T/hooks" HWDP_MACHINE_HOOKS="$T/no-machine-hooks" \
    WAYFIRE_CONFIG_FILE="$T/wayfire.ini" HWDP_WATCH_DAEMONIZED=1 \
    HWDP_HOTPLUG_POLL=1 HWDP_UNMAPPED_SETTLE=4 \
    PATH="$T/bin:$PATH" "$MGR" "$@"
}
_count() { [ -f "$T/$1.log" ] && wc -l < "$T/$1.log" || echo 0; }
# A stopped supervisor's watchdog `sleep` keeps the lock up to a second after
# the kill (lockfd.t), and a `watch` started into that window takes the NUDGE
# path and exits: the case after it then passes with no supervisor at all.
# Measured here: a planted bug went unseen in exactly that window. So wait for
# the lock, and prove the new supervisor is the one running.
_start() {
  _i=0
  while ! ( flock -n 9 ) 9>"$T/run/hwdp/watch.lock" 2>/dev/null; do
    [ "$_i" -lt 40 ] || fail "the old supervisor never released the lock"
    sleep 0.25; _i=$((_i + 1))
  done
  ( _HWEXEC=1 hw watch ) >"$T/mgr.log" 2>&1 &
  _mgr=$!
  harness_cleanup "kill $_mgr 2>/dev/null"
  sleep 1
  kill -0 "$_mgr" 2>/dev/null \
    || fail "the supervisor did not stay up (a nudge?): $(cat "$T/mgr.log")"
}
_stop() {
  kill "$_mgr" 2>/dev/null; wait "$_mgr" 2>/dev/null || :
  harness_cleanup ""
}

# --- hwdp profile, and what "needs one" means ---------------------------------
panel DP-1 edid-one
hw profile >/dev/null 2>&1 && fail "profile: none exists, must exit 1"
hw profile --missing && fail "one panel needs no profile (--missing must be 1)"
panel DP-2 edid-two
hw profile --missing || fail "two panels and no profile must be --missing 0"
_id=$(hw id)
printf 'profile x {\n}\n' > "$T/profiles/$_id.conf"
[ "$(hw profile)" = "$T/profiles/$_id.conf" ] \
  || fail "profile must print the path when there is one"
hw profile --missing && fail "a desk with a profile is not missing one"
rm -f "$T/profiles/$_id.conf"
mv "$T/drm" "$T/drm.away"; mkdir -p "$T/drm"
if hw profile --missing; then fail "no displays: --missing must not be 0"
else _rc=$?; fi
[ "$_rc" -eq 2 ] || fail "no displays is indeterminate (2), got $_rc"
rm -rf "$T/drm"; mv "$T/drm.away" "$T/drm"
pass "profile: path or 1; --missing 0 needed, 1 not, 2 cannot tell"

# --- at login an unmapped desk is announced, ONCE, after the settle -----------
_start
_i=0
while [ "$_i" -lt 60 ] && [ "$(_count unmapped)" -lt 1 ]; do
  sleep 0.25; _i=$((_i + 1))
done
[ "$(_count unmapped)" -eq 1 ] \
  || fail "an unmapped desk at startup was not announced: $(cat "$T/mgr.log")"
grep -q "^$_id " "$T/unmapped.log" || fail "the hook must get HWDP_ID"
sleep 5
[ "$(_count unmapped)" -eq 1 ] \
  || fail "announced more than once with nothing changing"
pass "an unmapped desk is announced once at startup, with its id"

# --- a burst of hotplugs inside the settle is ONE announcement ----------------
: > "$T/unmapped.log"
# The settle (4s) must exceed the gap between plugs (1s) plus one poll
# interval (1s): a plug is only SEEN at the next poll, so a 2s settle with a
# 1.2s gap fired twice here, a harness timing and not the code.
panel DP-3 edid-three
sleep 1
panel DP-4 edid-four
_i=0
while [ "$_i" -lt 60 ] && [ "$(_count unmapped)" -lt 1 ]; do
  sleep 0.25; _i=$((_i + 1))
done
sleep 5
[ "$(_count unmapped)" -eq 1 ] \
  || fail "two hotplugs inside the settle must announce once, got \
$(_count unmapped)"
grep -q "^$(hw id) " "$T/unmapped.log" \
  || fail "the announcement must name the FINAL desk"
pass "monitors plugged in one at a time are announced once, for the result"

# --- a desk with a profile is never announced ---------------------------------
_stop
: > "$T/unmapped.log"
printf 'profile x {\n}\n' > "$T/profiles/$(hw id).conf"
_start
sleep 6
[ "$(_count unmapped)" -eq 0 ] || fail "a mapped desk was announced"
_stop
rm -f "$T/profiles/"*.conf
pass "a desk that has a profile is not announced"

# --- one panel is never announced ---------------------------------------------
rm -rf "$T/drm"; mkdir -p "$T/drm"; panel DP-1 edid-one
_start
sleep 6
[ "$(_count unmapped)" -eq 0 ] || fail "a single panel was announced"
_stop
pass "one panel has nothing to arrange and is not announced"

# --- recording a profile announces `mapped`, with id and path -----------------
panel DP-2 edid-two
_id=$(hw id)
hw arrange DP-1 'DP-2 right-of DP-1' >/dev/null 2>&1 \
  || fail "arrange failed on the stub desk"
grep -q "^$_id $T/profiles/$_id.conf$" "$T/mapped.log" \
  || fail "arrange must fire mapped with HWDP_ID and HWDP_PROFILE: \
$(cat "$T/mapped.log" 2>/dev/null)"
: > "$T/mapped.log"
hw capture >/dev/null 2>&1 || fail "capture failed on the stub desk"
[ "$(_count mapped)" -eq 1 ] || fail "capture must fire mapped too"
pass "arrange and capture announce mapped, with the id and the profile"
