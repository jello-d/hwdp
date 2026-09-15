#!/bin/sh
# slicer.t - wallpaper-slicer cuts slices that TILE the output layout.
#
# The property that matters is continuity: a feature crossing a bezel has to
# line up, which only holds if every slice is cut from ONE global cover rect
# rather than each output being scaled independently. That is easy to get
# subtly wrong and impossible to see in a single-output session, so it is
# tested against a stubbed two-output layout instead of a real wall.
#
# It also pins the thing the move into hwdp was for: the geometry comes from
# `hwdp geometry` and nothing here parses a compositor.
. "$(dirname "$0")/lib.sh"
harness_init slicer

WS=$HERE/bin/wallpaper-slicer
mkdir -p "$T/bin" "$T/out"

_img=
for _c in magick convert vips; do
  command -v "$_c" >/dev/null 2>&1 && { _img=$_c; break; }
done
[ -n "$_img" ] || skip "no image tool (magick/convert/vips)"
_img_real=$(command -v "$_img")

# A COUNTING WRAPPER around the image tool, so "did it recut?" is answered by
# observing the work rather than by a proxy. Both obvious proxies are wrong
# here and both were tried: mtime changes on a cache HIT (touch-on-use is
# deliberate, so the crops age with the last lock and not the last recut), and
# the inode survives a recut (ImageMagick truncates in place). Only the crop
# invocation itself distinguishes the two. Dimension reads go through the same
# binary, so count the calls that carry -crop.
cat > "$T/bin/$_img" <<EOF
#!/bin/sh
for _a in "\$@"; do [ "\$_a" = -crop ] && echo crop >> "$T/crops"; done
exec "$_img_real" "\$@"
EOF
chmod +x "$T/bin/$_img"
: > "$T/crops"
_crops() { awk 'END { print NR }' "$T/crops"; }

# Two 1000x1000 outputs side by side: a 2000x1000 union, so a 2000x1000 source
# needs no scaling and each slice is exactly one half. Round numbers on purpose
# -- a tiling bug should show as a wrong OFFSET, not as a rounding artefact.
cat > "$T/bin/hwdp" <<'EOF'
#!/bin/sh
[ "$1" = geometry ] || exit 1
echo "DP-1 1000 1000 normal 1 0 0 1000 1000 landscape"
echo "DP-2 1000 1000 normal 1 1000 0 1000 1000 landscape"
EOF
chmod +x "$T/bin/hwdp"

# A source with a HARD VERTICAL EDGE at the midpoint: black left, white right.
# If the slices tile, DP-1 is all black and DP-2 all white. If either is cut
# from the wrong offset, the edge lands inside a slice and the means move.
case $_img in
  magick|convert) "$_img" -size 2000x1000 xc:black \
      -fill white -draw "rectangle 1000,0 1999,999" "$T/src.png" ;;
  vips) skip "vips source generation not implemented in this test" ;;
esac
[ -s "$T/src.png" ] || fail "could not build the test source image"

_out=$(PATH="$T/bin:$PATH" "$WS" -o "$T/out" "$T/src.png" 2>&1) \
  || fail "slicer failed on a two-output layout: $_out"

# One TAB-separated NAME<TAB>PATH line per output, in layout order.
[ "$(printf '%s\n' "$_out" | grep -c .)" -eq 2 ] \
  || fail "expected 2 slice lines, got: $_out"
for _o in DP-1 DP-2; do
  printf '%s\n' "$_out" | grep -q "^$_o	" \
    || fail "no slice line for $_o: $_out"
  _p=$(printf '%s\n' "$_out" | sed -n "s/^$_o	//p")
  [ -s "$_p" ] || fail "$_o's slice is missing or empty ($_p)"
done

# THE TILING ASSERTION. Each slice must be its own half of the source, so the
# left one is black and the right one white. A slicer that cover-scaled each
# output independently would put the edge through the middle of BOTH.
_mean() {   # <png> -> mean channel value, 0..1
  case $_img in
    magick|convert) "$_img" "$1" -format '%[fx:mean]' info: ;;
  esac
}
_l=$(_mean "$(printf '%s\n' "$_out" | sed -n 's/^DP-1	//p')")
_r=$(_mean "$(printf '%s\n' "$_out" | sed -n 's/^DP-2	//p')")
awk -v l="$_l" -v r="$_r" 'BEGIN { exit !(l < 0.1 && r > 0.9) }' \
  || fail "slices do not tile: left mean=$_l right mean=$_r (want ~0 and ~1)"

# Dimensions match the outputs, or the compositor letterboxes what it is given.
if [ "$_img" != vips ]; then
  for _o in DP-1 DP-2; do
    _p=$(printf '%s\n' "$_out" | sed -n "s/^$_o	//p")
    _wh=$("$_img" "$_p" -format '%wx%h' info:)
    [ "$_wh" = 1000x1000 ] || fail "$_o's slice is $_wh, not the output size"
  done
fi

# The first run cut one crop per output, and nothing more.
[ "$(_crops)" -eq 2 ] || fail "first run cut $(_crops) crops, want 2"

# A second run with identical inputs must reuse: ZERO new crops. Recutting on
# every display change is exactly what the cache exists to avoid, and a lock
# screen is where the latency would show.
: > "$T/crops"
_out2=$(PATH="$T/bin:$PATH" "$WS" -o "$T/out" "$T/src.png" 2>&1) \
  || fail "second slicer run failed: $_out2"
[ "$(_crops)" -eq 0 ] || fail "identical inputs recut $(_crops) crops"
[ "$_out2" = "$_out" ] || fail "a cache hit changed the mapping"

# ...but a changed input MUST recut, or the cache is just a stale answer with a
# fingerprint on it. Moving a panel down changes the union, hence every crop.
: > "$T/crops"
cat > "$T/bin/hwdp" <<'EOF'
#!/bin/sh
[ "$1" = geometry ] || exit 1
echo "DP-1 1000 1000 normal 1 0 0 1000 1000 landscape"
echo "DP-2 1000 1000 normal 1 1000 400 1000 1000 landscape"
EOF
chmod +x "$T/bin/hwdp"
_out3=$(PATH="$T/bin:$PATH" "$WS" -o "$T/out" "$T/src.png" 2>&1) \
  || fail "slicer failed after a layout change: $_out3"
[ "$(_crops)" -eq 2 ] || fail "a moved panel recut $(_crops) crops, want 2"

# Fewer than two outputs is a REFUSAL with a reason, not an empty success:
# there is nothing to span, and silently producing one full-size "slice" would
# let a caller think it had a spanned wallpaper.
cat > "$T/bin/hwdp" <<'EOF'
#!/bin/sh
[ "$1" = geometry ] || exit 1
echo "eDP-1 2880 1800 normal 1 0 0 2880 1800 landscape"
EOF
chmod +x "$T/bin/hwdp"
_out=$(PATH="$T/bin:$PATH" "$WS" -o "$T/out1" "$T/src.png" 2>&1) \
  && fail "a single output should not slice: $_out"
case $_out in
  *"fewer than 2 outputs"*) ;;
  *) fail "single-output refusal should say why: $_out" ;;
esac

pass "tiling slices, cache reuse, single-output refusal"
