#!/bin/sh
# arrange.t - outputs must share edges EXACTLY, and a switched-off panel must
# keep its profile matching.
#
# Three faults, each measured in a nested wayfire before it was fixed:
#
#   1. The compositor TRUNCATES mode/scale (2880 at 1.75 is 1645 wide). The
#      synthesized layout and `hwdp geometry` ROUNDED (1646), so packed
#      outputs sat a pixel apart, and edge-flipping's adjacency test is an
#      exact equality. The synthesized layout also ignored rotation.
#   2. Nothing checked an AUTHORED layout for gaps, and a 40px gap makes every
#      edge exterior: the pointer flips the workspace instead of crossing.
#   3. `capture` left a switched-off panel OUT of the profile, and kanshi
#      applies a profile only when it names every connected output ("no
#      profile matched"), so the docked-laptop profile never applied.
#   4. An authored profile's positions were only right at the scales it was
#      captured at: change a scale afterwards and the outputs stopped meeting
#      (layout.t's own 2.00 override left a 1080px gap). layout now re-places
#      them from the rects capture records, keeping the arrangement's shape.
. "$(dirname "$0")/harness_lib"
harness_init arrange

KA=$HERE/bin/hwdp
TAB=$(printf '\t')
mkdir -p "$T/bin" "$T/profiles" "$T/drm"

# --- 1. the detector, pure ----------------------------------------------------
_faults() {   # <rects, printf format> -> the raw fault records
  # shellcheck disable=SC2059
  printf "$1" | HWDP_LIB=$HERE/lib sh -c '. "$HWDP_LIB/displayset_lib"
    layout_faults'
}
_is() {   # <label> <rects> <expected kinds, space separated or empty>
  _got=$(_faults "$2" | cut -f1 | tr '\n' ' ' | sed 's/ $//')
  [ "$_got" = "$3" ] || fail "$1: expected '$3', got '$_got'"
}
_is "a portrait beside a CENTRED landscape is sound" \
  'P\t0\t0\t1080\t1920\nL\t1080\t420\t1920\t1080\n' ''
_is "stacked panels are sound" \
  'A\t0\t0\t2880\t1800\nB\t0\t1800\t1920\t1080\n' ''
_is "a chain of three is sound" \
  'A\t0\t0\t9\t9\nB\t9\t0\t9\t9\nC\t18\t0\t9\t9\n' ''
_is "one output is sound" 'A\t0\t0\t1920\t1080\n' ''
_is "a 40px gap is a gap" \
  'P\t0\t0\t1080\t1920\nL\t1120\t420\t1920\t1080\n' 'gap'
_is "ONE pixel is a gap" \
  'A\t0\t0\t9\t9\nB\t9\t0\t9\t9\nC\t19\t0\t9\t9\n' 'gap'
_is "an overlap is an overlap, and not a gap as well" \
  'A\t0\t0\t1920\t1080\nB\t1900\t0\t1920\t1080\n' 'overlap'
_is "meeting at a corner shares no edge" \
  'A\t0\t0\t9\t9\nB\t9\t9\t9\t9\n' 'corner'
_g=$(_faults 'P\t0\t0\t1080\t1920\nL\t1120\t420\t1920\t1080\n')
[ "$_g" = "gap${TAB}L${TAB}P${TAB}40" ] \
  || fail "the gap record must name both outputs and the distance: '$_g'"
pass "the edge-to-edge detector"

# --- 1b. the re-pack, pure ----------------------------------------------------
_rp() {   # <"old A x y w h; new A w h; ..."> -> "name x y;" per output
  printf '%s\n' "$1" | tr ';' '\n' | sed 's/^ *//' | tr ' ' '\t' \
    | HWDP_LIB=$HERE/lib sh -c '. "$HWDP_LIB/displayset_lib"
      layout_repack' | tr '\t\n' ' ;'
}
_rp_is() {   # <label> <records> <expected>
  _got=$(_rp "$2")
  [ "$_got" = "$3" ] || fail "repack, $1: expected '$3', got '$_got'"
}
_rp_is "the neighbour follows a panel that halves" \
  'old A 0 0 2160 3840; old B 2160 0 2160 3840; new A 1080 1920' \
  'A 0 0;B 1080 0;'
_rp_is "a centred landscape stays centred" \
  'old P 0 0 1080 1920; old L 1080 420 1920 1080; new L 1280 720' \
  'P 0 0;L 1080 600;'
_rp_is "a bottom-aligned panel stays bottom-aligned" \
  'old P 0 0 1080 1920; old L 1080 840 1920 1080; new L 1280 720' \
  'P 0 0;L 1080 1200;'
_rp_is "a panel left of the first, and the origin moves to it" \
  'old A 2880 0 3840 2160; old B 0 0 2880 1800; new B 1645 1028' \
  'A 1645 0;B 0 0;'
_rp_is "a laptop centred BELOW a 4K that scales" \
  'old E 0 0 3840 2160; old B 1097 2160 1645 1028; new E 2194 1234' \
  'E 0 0;B 274 1234;'
_rp_is "unchanged sizes change nothing" \
  'old A 0 0 2160 3840; old B 2160 0 2160 3840' \
  'A 0 0;B 2160 0;'
pass "the re-pack keeps the shape and the alignment"

# --- 2. the logical size truncates, and rotates -------------------------------
_ls() {   # <w> <h> <transform> <scale> -> "LWxLH"
  HWDP_LIB=$HERE/lib sh -c '. "$HWDP_LIB/probe_lib"
    awk -v w="$1" -v h="$2" -v t="$3" -v s="$4" "$HWDP_AWK_LOGICAL"'"'"'
      BEGIN { lsize(w, h, t, s); printf "%dx%d", LW, LH }'"'" _ "$@"
}
[ "$(_ls 2880 1800 normal 1.75)" = 1645x1028 ] \
  || fail "2880x1800 at 1.75 must truncate to 1645x1028: $(_ls 2880 1800 \
normal 1.75)"
[ "$(_ls 2560 1440 normal 1.5)" = 1706x960 ] \
  || fail "2560 at 1.5 must truncate to 1706"
[ "$(_ls 3840 2160 90 1)" = 2160x3840 ] || fail "a 90 rotation must swap"
[ "$(_ls 3840 2160 flipped-270 2)" = 1080x1920 ] \
  || fail "flipped-270 must swap, then scale"
pass "the logical size truncates like the compositor, after rotation"

# --- a desk, driven by stubs -----------------------------------------------
# eDP-1 2880x1800 (the laptop), DP-1 3840x2160. $DESK picks the arrangement:
#   packed   DP-1 starts where eDP-1 ends, at 1.75: x = 1645
#   gap      DP-1 40px further right
#   lidoff   eDP-1 attached but switched OFF, DP-1 alone at 0,0
cat > "$T/bin/wlr-randr" <<'EOF'
#!/bin/sh
_edp_en=yes; _dp_x=1645
case ${DESK:-packed} in
  gap)    _dp_x=1685 ;;
  lidoff) _edp_en=no; _dp_x=0 ;;
esac
cat <<BLK
eDP-1 "Acme Corp LAPTOP SN0001 (eDP-1)"
  Make: Acme Corp
  Model: LAPTOP
  Serial: SN0001
  Physical size: 300x190 mm
  Enabled: $_edp_en
  Modes:
    2880x1800 px, 60.000000 Hz (preferred, current)
  Position: 0,0
  Transform: ${EDP_TR:-normal}
  Scale: 1.750000
DP-1 "Dell Inc. AW2725Q DDD444 (DP-1)"
  Make: Dell Inc.
  Model: AW2725Q
  Serial: DDD444
  Physical size: 590x330 mm
  Enabled: yes
  Modes:
    3840x2160 px, 60.000000 Hz (preferred, current)
  Position: $_dp_x,0
  Transform: ${DP_TR:-normal}
  Scale: 1.000000
BLK
EOF
chmod +x "$T/bin/wlr-randr"
for _c in eDP-1 DP-1; do
  mkdir -p "$T/drm/card1-$_c"
  printf connected > "$T/drm/card1-$_c/status"
  printf 'EDID-%s' "$_c" > "$T/drm/card1-$_c/edid"
done

run() {
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    WAYLAND_DISPLAY=wayland-test HWDP_MACHINE_PROVIDERS="$T/no-machine" \
    HWDP_PROVIDER_ROOT="$T/no-user" \
    KANSHI_PROFILES="$T/profiles" KANSHI_STICKY="$T/sticky" \
    KANSHI_OUT="$T/out" HWDP_DRM="$T/drm" XDG_RUNTIME_DIR="$T/run" \
    DESK="${DESK:-packed}" EDP_TR="${EDP_TR:-normal}" \
    sh "$KA" "$@"
}
_id=$(run id)
[ -n "$_id" ] || fail "no hwdp id from the stub desk"

# --- 3. geometry publishes the compositor's width -----------------------------
_lw=$(run geometry --now | awk '$1 == "eDP-1" { print $8 }')
[ "$_lw" = 1645 ] || fail "geometry LOG_W for 2880 at 1.75 must be 1645: $_lw"
pass "geometry's LOG_W is the compositor's, truncated"

# --- 4. the synthesized layout packs in the compositor's arithmetic ---------
# The sticky scale is what layout injects; sign it the way resolve() does.
printf 'Acme Corp LAPTOP SN0001\t1.75\t2880x1800@300x190\n' > "$T/sticky"
run layout >/dev/null 2>"$T/layout.err" || fail "layout failed"
_x=$(sed -n 's/.*AW2725Q DDD444" .* position \([0-9]*\),0 .*/\1/p' "$T/out")
[ "$_x" = 1645 ] || fail "the synthesized DP-1 must start at 1645, got '$_x'"
grep -q WARNING "$T/layout.err" \
  && fail "a packed synthesized layout must not warn: $(cat "$T/layout.err")"
# A ROTATED first output: the laptop panel at 90 is 1800/1.75 = 1028 wide, so
# DP-1 starts there. The old arithmetic used the MODE width and rounded, 1646,
# which overlaps the rotated panel's neighbour by 618px.
EDP_TR=90 run layout >/dev/null 2>&1 || fail "layout failed (rotated)"
_x=$(sed -n 's/.*AW2725Q DDD444" .* position \([0-9]*\),0 .*/\1/p' "$T/out")
[ "$_x" = 1028 ] || fail "after a rotated 2880x1800 at 1.75, DP-1 must start \
at 1028, got '$_x'"
pass "the synthesized layout packs exactly, scaled and rotated"

# --- 5. capture refuses a gap, and writes nothing -----------------------------
if DESK=gap run capture >"$T/cap.out" 2>"$T/cap.err"; then
  fail "capture accepted a 40px gap"
fi
[ -e "$T/profiles/$_id.conf" ] && fail "a refused capture still wrote a profile"
grep -q 'DP-1 does not touch eDP-1: 40px' "$T/cap.err" \
  || fail "the refusal must name both outputs and the gap: $(cat "$T/cap.err")"
pass "capture refuses a gap, says where, and writes nothing"

# --- 6. capture keeps a switched-off panel, as `disable` ----------------------
_p=$(DESK=lidoff run capture) || fail "capture failed with the lid off"
grep -q '^    output "Acme Corp LAPTOP SN0001" disable$' "$_p" \
  || fail "the switched-off panel must be a disable line: $(cat "$_p")"
grep -q 'AW2725Q DDD444" mode' "$_p" || fail "the enabled panel went missing"
# layout must keep the disable line WITHOUT a scale, even in a session where
# the panel is still enabled (the sticky has a scale for it).
run layout >/dev/null 2>&1 || fail "layout failed on the captured profile"
grep -q 'LAPTOP SN0001" disable$' "$T/out" \
  || fail "layout must keep the disable line as written: $(cat "$T/out")"
pass "a switched-off panel is captured as disable, and layout keeps it"

# --- 7. layout WARNS on a gapped authored profile, and still writes it --------
cat > "$T/profiles/$_id.conf" <<EOF
profile hwdp-$_id {
    output "Acme Corp LAPTOP SN0001" mode 2880x1800@60.000Hz position 0,0
    output "Dell Inc. AW2725Q DDD444" mode 3840x2160@60.000Hz position 1700,0
}
EOF
run layout >/dev/null 2>"$T/layout.err" || fail "layout must not refuse a gap"
grep -q 'WARNING: .*AW2725Q DDD444 does not touch .*LAPTOP SN0001: 55px' \
  "$T/layout.err" || fail "no gap warning: $(cat "$T/layout.err")"
[ -s "$T/out" ] || fail "a gapped profile must still produce a config"
pass "layout warns on a gap the injected scale opened, and still writes"

# --- 8. a scale change after capture RE-PLACES the outputs -----------------
# Capture at the stub's live scales (the laptop at 1.75, 1645 wide, the 4K
# beside it at x=1645), then move the laptop's sticky scale to 1.25 (2304
# wide). The 4K must follow to x=2304 rather than be left overlapping it.
printf 'Acme Corp LAPTOP SN0001\t1.75\t2880x1800@300x190\n' > "$T/sticky"
_p=$(run capture 2>/dev/null) || fail "capture failed on the packed desk"
grep -q '^# hwdp-rect "Acme Corp LAPTOP SN0001" 0 0 1645 1028$' "$_p" \
  || fail "capture must record each output's rect: $(grep hwdp-rect "$_p")"
grep -q '^# hwdp-rect "Dell Inc. AW2725Q DDD444" 1645 0 3840 2160$' "$_p" \
  || fail "capture must record the second rect too"
run layout >/dev/null 2>"$T/layout.err" || fail "layout failed (same scales)"
grep -q 're-placed' "$T/layout.err" \
  && fail "unchanged scales must leave the authored layout alone"
grep -q 'DDD444" .*position 1645,0' "$T/out" \
  || fail "unchanged scales must keep the authored position"
printf 'Acme Corp LAPTOP SN0001\t1.25\t2880x1800@300x190\n' > "$T/sticky"
run layout >/dev/null 2>"$T/layout.err" || fail "layout failed (rescaled)"
grep -q 'DDD444" .*position 2304,0' "$T/out" \
  || fail "the 4K must follow the rescaled laptop to 2304: $(grep DDD444 \
"$T/out")"
grep -q 're-placed the authored layout' "$T/layout.err" \
  || fail "a re-place must say so: $(cat "$T/layout.err")"
grep -q WARNING "$T/layout.err" \
  && fail "a re-placed layout must not warn: $(cat "$T/layout.err")"
# A position moved BY HAND wins: leave it, say why, and let the check speak.
sed 's/\(DDD444" .*position \)1645,0/\11700,0/' "$_p" > "$_p.new"
mv "$_p.new" "$_p"
run layout >/dev/null 2>"$T/layout.err" || fail "layout failed (hand edit)"
grep -q 'left as written: .*DDD444 was moved by hand' "$T/layout.err" \
  || fail "a hand-moved position must stop the re-place: $(cat \
"$T/layout.err")"
grep -q 'DDD444" .*position 1700,0' "$T/out" \
  || fail "the hand-moved position must survive"
grep -q WARNING "$T/layout.err" \
  || fail "the hand-moved layout overlaps at 1.25, and must be warned about"
pass "a scale change re-places the outputs; a hand edit is left alone"
