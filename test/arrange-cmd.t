#!/bin/sh
# arrange-cmd.t - `hwdp arrange`: a layout written from placements, each
# output against one already placed, with its OWN alignment along that edge.
#
# The user asked for exactly this: monitors of unequal height lined up at the
# top, the bottom, or the centre, and mixed across edges. So every alignment
# on every side is pinned with its arithmetic, and a mixed desk end to end.
# The written profile must be the same kind capture writes (disable lines,
# rects layout re-places from), and every refusal must write NOTHING.
. "$(dirname "$0")/harness_lib"
harness_init arrange-cmd

KA=$HERE/bin/hwdp
TAB=$(printf '\t')
mkdir -p "$T/bin" "$T/drm" "$T/profiles"

# Laptop 2880x1800, a 4K the stub can rotate (DP-1), a 4K landscape (DP-2).
cat > "$T/bin/wlr-randr" <<'STUB'
#!/bin/sh
_out() {   # <conn> <w> <h> <x> <transform> <enabled>
  cat <<BLK
$1 "Acme MODEL SN-$1 ($1)"
  Make: Acme
  Model: MODEL
  Serial: SN-$1
  Physical size: 600x340 mm
  Enabled: $6
  Modes:
    ${2}x${3} px, 60.000000 Hz (preferred, current)
  Position: $4,0
  Transform: $5
  Scale: 1.000000
BLK
}
_out eDP-1 2880 1800 0 normal "${LAPTOP:-yes}"
_out DP-1 3840 2160 2880 "${DP1_TR:-90}" yes
_out DP-2 3840 2160 5040 normal yes
STUB
chmod +x "$T/bin/wlr-randr"
for _c in eDP-1 DP-1 DP-2; do
  mkdir -p "$T/drm/card1-$_c"
  printf connected > "$T/drm/card1-$_c/status"
  printf 'EDID-%s' "$_c" > "$T/drm/card1-$_c/edid"
done

run() {
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    WAYLAND_DISPLAY="${WL-wayland-test}" \
    HWDP_MACHINE_PROVIDERS="$T/no-machine" HWDP_PROVIDER_ROOT="$T/no-user" \
    HWDP_DRM="$T/drm" XDG_RUNTIME_DIR="$T/run" \
    KANSHI_PROFILES="$T/profiles" KANSHI_STICKY="$T/sticky" \
    KANSHI_OUT="$T/out" LAPTOP="${LAPTOP:-yes}" DP1_TR="${DP1_TR:-90}" \
    sh "$KA" arrange "$@"
}
_id=$(env -i PATH="$T/bin:/usr/bin:/bin" HWDP_DRM="$T/drm" \
  HWDP_MACHINE_PROVIDERS="$T/no-machine" sh "$KA" id --desk)
P=$T/profiles/$_id.conf    # a laptop beside externals: the DESK id

# The position --dry-run reports for one output: "x,y".
_at() {   # <dry-run text> <serial>
  printf '%s\n' "$1" | awk -v s="SN-$2" '$0 ~ s && / at / {
    for (i = 1; i <= NF; i++) if ($i == "at") { print $(i + 1); exit } }'
}
_place() {   # <label> <expected x,y of DP-2> <placement of DP-2>
  _d=$(run --dry-run DP-1 "$3" 'eDP-1 off' 2>&1) \
    || fail "$1: refused: $_d"
  [ "$(_at "$_d" DP-2)" = "$2" ] \
    || fail "$1: DP-2 at $(_at "$_d" DP-2), expected $2"
}

# --- every alignment, beside: the portrait DP-1 is 2160x3840, DP-2 is
# 3840x2160 (1680 shorter). Positions are normalised to a 0,0 top-left.
_place "right-of, top"    2160,0    'DP-2 right-of DP-1 align top'
_place "right-of, center" 2160,840  'DP-2 right-of DP-1 align center'
_place "right-of, bottom" 2160,1680 'DP-2 right-of DP-1 align bottom'
_place "right-of, default is top" 2160,0 'DP-2 right-of DP-1'
_d=$(run --dry-run DP-1 'DP-2 left-of DP-1 align bottom' 'eDP-1 off') \
  || fail "left-of refused"
[ "$(_at "$_d" DP-2)" = 0,1680 ] && [ "$(_at "$_d" DP-1)" = 3840,0 ] \
  || fail "left-of, bottom: DP-2 $(_at "$_d" DP-2), DP-1 $(_at "$_d" DP-1)"
pass "beside a neighbour: top, center, bottom, and left-of"

# --- every alignment, above and below: the laptop (2880 wide) under DP-2
# (3840 wide, landscape at 0,0 as the anchor here).
_below() {   # <label> <expected laptop x,y> <align or "">
  _d=$(run --dry-run DP-2 "eDP-1 below DP-2${3:+ align $3}" \
    'DP-1 right-of DP-2') || fail "$1: refused: $_d"
  [ "$(_at "$_d" eDP-1)" = "$2" ] \
    || fail "$1: the laptop at $(_at "$_d" eDP-1), expected $2"
}
_below "below, left"            0,2160   left
_below "below, center"          480,2160 center
_below "below, right"           960,2160 right
_below "below, default is left" 0,2160   ""
_d=$(run --dry-run DP-2 'eDP-1 above DP-2 align right' \
  'DP-1 right-of DP-2') \
  || fail "above refused"
[ "$(_at "$_d" eDP-1)" = 960,0 ] && [ "$(_at "$_d" DP-2)" = 0,1800 ] \
  || fail "above, right: laptop $(_at "$_d" eDP-1), DP-2 $(_at "$_d" DP-2)"
pass "above and below a neighbour: left, center, right"

# --- a MIXED desk: bottom-aligned on one edge, centred on another -------------
_d=$(run --dry-run 'DP-1 rotate 90' 'DP-2 right-of DP-1 align bottom' \
  'eDP-1 below DP-2 align center') || fail "the mixed desk was refused: $_d"
[ "$(_at "$_d" DP-1)" = 0,0 ] && [ "$(_at "$_d" DP-2)" = 2160,1680 ] \
  && [ "$(_at "$_d" eDP-1)" = 2640,3840 ] \
  || fail "mixed desk: $(printf '%s\n' "$_d" | head -3)"
# rotate is explicit here and default elsewhere: unrotated, DP-1 is landscape.
_d=$(run --dry-run 'DP-1 rotate 0' 'DP-2 right-of DP-1' 'eDP-1 off') \
  || fail "rotate 0 refused"
[ "$(_at "$_d" DP-2)" = 3840,0 ] || fail "rotate 0 must make DP-1 3840 wide"
pass "a mixed desk, and rotate changes the size placed against"

# --- EDID names work as well as connectors ------------------------------------
_d=$(run --dry-run '"Acme MODEL SN-DP-2"' \
  'DP-1 left-of "Acme MODEL SN-DP-2" align bottom' \
  '"Acme MODEL SN-eDP-1" off') \
  || fail "EDID names were refused: $_d"
[ "$(_at "$_d" DP-1)" = 0,0 ] && [ "$(_at "$_d" DP-2)" = 2160,1680 ] \
  || fail "EDID names: $(printf '%s\n' "$_d" | head -3)"
pass "outputs named by EDID name, quoted"

# --- writing: the same profile capture writes ---------------------------------
_o=$(run DP-1 'DP-2 right-of DP-1 align center' 'eDP-1 off' 2>"$T/err") \
  || fail "arrange failed to write: $(cat "$T/err")"
[ "$_o" = "$P" ] || fail "stdout must be the profile path, got '$_o'"
grep -q '^profile hwdp-'"$_id"' {$' "$P" || fail "the profile is misnamed"
grep -q '^    output "@builtin" disable$' "$P" \
  || fail "an off built-in must be a disable line, by ROLE: $(cat "$P")"
grep -q '^# hwdp-rect "Acme MODEL SN-DP-2" 2160 840 3840 2160$' "$P" \
  || fail "the rects layout re-places from must be written"
grep -q 'SN-DP-1" mode 3840x2160@60.000Hz transform 90 position 0,0$' "$P" \
  || fail "the rotated output line is wrong: $(grep SN-DP-1 "$P")"
grep -q 'no supervisor is running' "$T/err" \
  || fail "with no supervisor it must say so: $(cat "$T/err")"
grep -q 'SN-DP-2" .*position 2160,840 ' "$T/out" \
  || fail "layout did not pick the written profile up: $(cat "$T/out")"
# An identical re-run is a no-op; a different one keeps a .bak, in the STATE
# dir: the profiles dir may be recorded whole (muster captures it), and a
# backup there would be recorded as a layout.
B=$T/home/.local/state/hwdp/profiles/$_id.conf.bak
_sum=$(cksum < "$P")
run DP-1 'DP-2 right-of DP-1 align center' 'eDP-1 off' >/dev/null 2>&1
[ "$(cksum < "$P")" = "$_sum" ] && [ ! -e "$B" ] \
  || fail "an identical arrange must leave the profile alone"
run DP-1 'DP-2 right-of DP-1 align bottom' 'eDP-1 off' >/dev/null 2>"$T/err"
[ -e "$B" ] && grep -q 'previous profile kept' "$T/err" \
  || fail "a changed arrange must keep a .bak and say so"
[ "$(ls -A "$T/profiles")" = "$_id.conf" ] \
  || fail "only profiles may be left in the profiles dir: $(ls -A \
"$T/profiles")"
pass "writes the kind of profile capture does; layout picks it up; .bak"

# --- every refusal is exit 2 and writes NOTHING -------------------------------
_refuse() {   # <label> <stderr fragment> <placement>...
  _l=$1; _e=$2; shift 2
  cp "$P" "$P.before"
  if run "$@" >/dev/null 2>"$T/err"; then
    fail "$_l: accepted"
  else
    _rc=$?
  fi
  [ "$_rc" -eq 2 ] || fail "$_l: exit $_rc, expected 2"
  cmp -s "$P" "$P.before" || fail "$_l: the profile was written anyway"
  grep -qF -- "$_e" "$T/err" || fail "$_l: no '$_e' in: $(cat "$T/err")"
}
_refuse "an output left unplaced" "is switched on but not placed" \
  DP-1 'DP-2 right-of DP-1'
_refuse "two outputs in one space" "OVERLAP" \
  DP-1 'DP-2 right-of DP-1' 'eDP-1 right-of DP-1'
_refuse "an alignment for the wrong side" "align is top, center or bottom" \
  DP-1 'DP-2 right-of DP-1 align left' 'eDP-1 off'
_refuse "an unknown output" "no output named \`DP-9\`" \
  DP-9 'DP-1 off' 'DP-2 off' 'eDP-1 off'
_refuse "an output placed twice" "is placed twice" \
  DP-1 'DP-1 right-of DP-1' 'DP-2 off' 'eDP-1 off'
_refuse "a neighbour placed later" "is not an output placed above it" \
  DP-1 'DP-2 right-of eDP-1' 'eDP-1 below DP-1'
_refuse "a second anchor" "needs a place" DP-1 DP-2 'eDP-1 off'
_refuse "a rotation that is not a quarter turn" "rotate takes 0, 90" \
  'DP-1 rotate 45' 'DP-2 off' 'eDP-1 off'
LAPTOP=no _refuse "a switched-off output placed" "switch it on first" \
  DP-1 'DP-2 right-of DP-1' 'eDP-1 below DP-2'
_refuse "everything off" "nothing is placed" 'DP-1 off' 'DP-2 off' 'eDP-1 off'
pass "every refusal exits 2, says why, and writes nothing"

# --- `at X,Y`: exact positions, for fine placement ---------------------------
# A landscape 500px down the portrait edge: no handy label says that, and the
# interactive helper's fine moves need it.
_d=$(run --dry-run 'DP-1 at 0,0' 'DP-2 at 2160,500' 'eDP-1 off') \
  || fail "an exact, edge-sharing position was refused: $_d"
[ "$(_at "$_d" DP-2)" = 2160,500 ] || fail "at: DP-2 $(_at "$_d" DP-2)"
# Mixed with a relative placement against it, and normalised to 0,0.
_d=$(run --dry-run 'DP-2 at 100,100' 'DP-1 left-of DP-2' \
  'eDP-1 below DP-2 align right') || fail "at mixed with relative: $_d"
[ "$(_at "$_d" DP-1)" = 0,0 ] && [ "$(_at "$_d" DP-2)" = 2160,0 ] \
  || fail "at + left-of: DP-1 $(_at "$_d" DP-1), DP-2 $(_at "$_d" DP-2)"
_refuse "an exact position leaving a gap" "does not touch" \
  'DP-1 at 0,0' 'DP-2 at 2200,0' 'eDP-1 off'
_refuse "an exact position meeting only at a corner" "only at a corner" \
  'DP-1 at 0,0' 'DP-2 at 2160,3840' 'eDP-1 off'
_refuse "a malformed position" "expected \`at X,Y\`" \
  'DP-1 at 0;0' 'DP-2 off' 'eDP-1 off'
pass "exact positions: fine offsets accepted, gaps and corners refused"

# --- a switched-off output not mentioned stays off ----------------------------
_d=$(LAPTOP=no run --dry-run DP-1 'DP-2 right-of DP-1') \
  || fail "an unmentioned switched-off output must not be required"
printf '%s\n' "$_d" | grep -q '^    output "@builtin" disable$' \
  || fail "it must still be written as disable, or kanshi never matches"
pass "a switched-off output nobody mentions stays off, as disable"

# --- no session ---------------------------------------------------------------
if WL= run DP-1 >/dev/null 2>"$T/err"; then
  fail "arrange with no session must not succeed"
else
  _rc=$?
fi
[ "$_rc" -eq 3 ] || fail "no session: exit $_rc, expected 3"
pass "without a session it says so (exit 3)"
