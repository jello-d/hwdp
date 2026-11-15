#!/bin/sh
# status.t - `hwdp status`: the session's display layer on one screen, a `!`
# line and exit 1 for each kind of problem, and it only READS.
#
# The supervisor is faked the way status finds one: a running process whose
# command line holds `cmd/watch`, named by watch.<pid>.kanshi, which holds
# its kanshi's pid (a plain sleep). kanshi's verdicts and the hook failures
# are planted in the supervisor's log, as kanshi and run_hooks write them.
. "$(dirname "$0")/harness_lib"
harness_init status

KA=$HERE/bin/hwdp
mkdir -p "$T/fake/cmd" "$T/user/layout" "$T/hooks/changed.d" "$T/run/hwdp"
panel() {   # <connector> <w> <h> <edid>: attach one panel
  mkdir -p "$T/drm/card1-$1"
  printf 'connected\n' > "$T/drm/card1-$1/status"
  printf '%s' "$4" > "$T/drm/card1-$1/edid"
  printf '%sx%s\n' "$2" "$3" > "$T/drm/card1-$1/modes"
}
panel eDP-1 2880 1800 EDID-LAPTOP
cat > "$T/user/layout/10-stub" <<'EOF'
#!/bin/sh
# name conn mode_w mode_h mm_w mm_h rate transform scale x y enabled
printf 'Laptop Panel\teDP-1\t2880\t1800\t300\t190\t60\tnormal\t1.5\t0\t0\t1\n'
EOF
chmod +x "$T/user/layout/10-stub"
printf '#!/bin/sh\n' > "$T/hooks/changed.d/20-bars"
chmod +x "$T/hooks/changed.d/20-bars"
LOG=$T/run/hwdp/watch.log

run() {   # [WAYLAND_DISPLAY]: hwdp status, in a session when one is given
  env -i PATH="/usr/bin:/bin" HOME="$T/home" XDG_CONFIG_HOME="$T/config" \
    XDG_STATE_HOME="$T/state" XDG_RUNTIME_DIR="$T/run" HWDP_DRM="$T/drm" \
    HWDP_PROVIDER_ROOT="$T/user" HWDP_MACHINE_PROVIDERS="$T/no-machine" \
    HWDP_HOOK_ROOT="$T/hooks" HWDP_MACHINE_HOOKS="$T/no-hooks" \
    KANSHI_PROFILES="$T/profiles" KANSHI_STICKY="$T/sticky" \
    ${1:+WAYLAND_DISPLAY="$1"} sh "$KA" status
}
has() { printf '%s\n' "$1" | grep -q -E "$2" || fail "$3: $1"; }

# --- headless: what is attached, and nothing per session -------------------
_o=$(run) || fail "headless with nothing wrong must exit 0: $_o"
has "$_o" '^panels +eDP-1 2880x1800 \(attached\)$' "headless panels"
has "$_o" '^session +none here' "headless must say there is no session"
has "$_o" '^layout +none on record; one panel needs none$' "one panel"
has "$_o" '^hooks +changed 1$' "the wired hooks"
pass "headless: the attached panels, and the session lines say none"

# --- in a session, no supervisor -------------------------------------------
_o=$(run wl-test); _rc=$?
[ "$_rc" = 1 ] || fail "no supervisor must exit 1, not $_rc: $_o"
has "$_o" '^! watch +no supervisor is running' "no supervisor"
has "$_o" '^panels +eDP-1 2880x1800 scale 1.5, landscape$' "session panels"
# A pid file naming a live process that is NOT a supervisor (this test's own
# shell) is not one: status asks the process, not the file name.
: > "$T/run/hwdp/watch.$$.kanshi"
_o=$(run wl-test) && fail "a non-supervisor pid read as a supervisor: $_o"
has "$_o" '^! watch +no supervisor is running' "a pid that is not a watch"
rm -f "$T/run/hwdp/watch.$$.kanshi"
pass "in a session with no supervisor: a ! line and exit 1"

# --- a supervisor and its kanshi --------------------------------------------
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$T/fake/cmd/watch"
sh "$T/fake/cmd/watch" & _sp=$!
sleep 300 & _kp=$!
harness_cleanup "kill $_sp $_kp 2>/dev/null"
printf '%s' "$_kp" > "$T/run/hwdp/watch.$_sp.kanshi"
printf "%s\n" "configuration for profile 'hwdp-abc' applied" > "$LOG"
_o=$(run wl-test) || fail "a healthy session must exit 0: $_o"
has "$_o" "^watch +running \\(pid $_sp, since " "the supervisor"
has "$_o" "^kanshi +running \\(pid $_kp\\); applied hwdp-abc$" "the profile"
printf "%s\n" "configuration for profile 'autoscale' applied" >> "$LOG"
has "$(run wl-test)" 'applied the synthesized layout' "the last verdict wins"
pass "a running supervisor and kanshi, and the profile kanshi last applied"

# --- each problem is a ! line and exit 1 ------------------------------------
printf '%s\n' "no profile matched" >> "$LOG"
_o=$(run wl-test); _rc=$?
[ "$_rc" = 1 ] || fail "no profile matched must exit 1: $_o"
has "$_o" '^! kanshi .*no profile matched' "no profile matched"
: > "$LOG"
for _i in 1 2; do
  printf '%s\n' "hwdp watch: hook changed.d/20-bars failed" >> "$LOG"
done
printf '%s\n' "hwdp watch: hook pre.d/10-x is NOT EXECUTABLE, so it did" \
  >> "$LOG"
_o=$(run wl-test); _rc=$?
[ "$_rc" = 1 ] || fail "a failed hook must exit 1: $_o"
has "$_o" '^! hooks +since the supervisor started:$' "failed hooks"
has "$_o" '^ +changed\.d/20-bars failed \(2x\)$' "a failed hook"
has "$_o" '^ +pre\.d/10-x not executable \(1x\)$' "a non-executable hook"
: > "$LOG"
kill "$_kp"; wait "$_kp" 2>/dev/null
_o=$(run wl-test); _rc=$?
[ "$_rc" = 1 ] || fail "a dead kanshi must exit 1: $_o"
has "$_o" '^! kanshi +not running under the supervisor' "a dead kanshi"
panel DP-2 2560 1440 EDID-WIDE
_o=$(run wl-test); _rc=$?
[ "$_rc" = 1 ] || fail "an unmapped desk must exit 1: $_o"
has "$_o" '^! layout +none for this desk, which needs one' "two panels"
pass "no profile matched, failed hooks, a dead kanshi, an unmapped desk"

# --- it only reads ----------------------------------------------------------
snap() {
  find "$T" | grep -v -x -e "$T/before" -e "$T/after" | sort > "$T/$1"
}
snap before
run wl-test >/dev/null; run >/dev/null
snap after
cmp -s "$T/before" "$T/after" \
  || fail "status wrote: $(diff "$T/before" "$T/after")"
pass "it writes nothing"
