#!/bin/sh
# arrange.t - outputs must share edges EXACTLY.
#
# One fault, measured in a nested wayfire before it was fixed:
#
#   1. The compositor TRUNCATES mode/scale (2880 at 1.75 is 1645 wide). The
#      synthesized layout and `hwdp geometry` ROUNDED (1646), so packed
#      outputs sat a pixel apart, and edge-flipping's adjacency test is an
#      exact equality. The synthesized layout also ignored rotation.
. "$(dirname "$0")/harness_lib"
harness_init arrange

KA=$HERE/bin/hwdp
TAB=$(printf '\t')
mkdir -p "$T/bin" "$T/profiles" "$T/drm"

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

