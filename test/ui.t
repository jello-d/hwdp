#!/bin/sh
# ui.t - `hwdp ui`, the per-display sizing resolver.
#
# It had 77 lines of policy and NOTHING asserting its output. probe.t touches
# one key (the headless CURSOR_SIZE regression) and layout.t writes a `.ui`
# file for layout's own purposes; the resolver's own rules were unpinned.
#
# That is the wrong file to leave untested, because its subtleties are what
# cost the most on real hardware:
#   - six override keys were once hand-pinned to the LODPI set on a hi-res
#     panel, and every one of them made something SMALLER, because three keys
#     are shrink-only and empty is their hi-res answer;
#   - `LOCK_RADIUS=` was written expecting it to force an empty answer, which
#     it does not: an empty override value is indistinguishable from an absent
#     one, so the density default stood and nobody could see why.
# Both are behaviours a reader would guess wrong, which is precisely what a
# test is for.
#
# Pinned here: the KEY SET and its order (consumers parse these lines), the two
# calibrated sets and which keys each leaves empty, the LODPI_MAX_W boundary,
# override precedence per key, empty-is-absent, HWDP_TARGET_PPI selecting the
# set outright, and the mixed-DPI warning going to STDERR while a full key set
# still comes out at status 0.
. "$(dirname "$0")/harness_lib"
harness_init ui

KA="$HERE/bin/hwdp"
TAB=$(printf '\t')
mkdir -p "$T/bin" "$T/home" "$T/user/layout" "$T/machine/layout" "$T/profiles"

# One connected panel of a chosen width, via the DRM (panels) provider, so
# every case below resolves HEADLESS and needs no compositor.
set_panel() {   # <width> [edid]
  rm -rf "$T/drm"; mkdir -p "$T/drm/card1-DP-1"
  printf 'connected\n' > "$T/drm/card1-DP-1/status"
  printf '%s' "${2:-EDID-PANEL-A}" > "$T/drm/card1-DP-1/edid"
  printf '%sx1080\n' "$1" > "$T/drm/card1-DP-1/modes"
}

run() {   # hwdp, headless: no WAYLAND_DISPLAY, no DISPLAY
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    HWDP_DRM="$T/drm" HWDP_PROVIDER_ROOT="$T/user" \
    HWDP_MACHINE_PROVIDERS="$T/machine" \
    KANSHI_PROFILES="$T/profiles" KANSHI_STICKY="$T/sticky" \
    ${HWDP_TARGET_PPI:+HWDP_TARGET_PPI="$HWDP_TARGET_PPI"} \
    KANSHI_OUT="$T/out" sh "$KA" "$@"
}
val() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# --- the KEY SET is a contract: same six keys, same order, every time -------
# Consumers read these lines (term, apply-wayfire-runtime, mako-placement,
# vigilance-lock-argv), and all of them swallow stderr, so a key that stops
# being emitted is a consumer silently keeping its own default.
set_panel 1920
_lo=$(run ui) || fail "ui failed on a 1920 panel: $_lo"
_keys=$(printf '%s\n' "$_lo" | sed 's/=.*//' | tr '\n' ' ')
_want_keys="KITTY_FONT TITLE_FONT MAKO_FONT LOCK_RADIUS CURSOR_SIZE MAGNIFY "
[ "$_keys" = "$_want_keys" ] \
  || fail "the emitted key set/order changed: [$_keys]"
[ "$(printf '%s\n' "$_lo" | grep -c .)" -eq 6 ] \
  || fail "want exactly 6 lines, got: $_lo"
pass "the key set and its order are stable"

# --- lodpi sets every key; hidpi leaves the SHRINK-ONLY ones empty ----------
# This is the asymmetry that produced six bad hand-written pins. KITTY_FONT,
# MAKO_FONT and LOCK_RADIUS exist ONLY to shrink a fixed-pixel default on a
# low-density panel; their hi-res answer is EMPTY, which tells the consumer to
# keep its own config value. TITLE_FONT and CURSOR_SIZE are the opposite --
# always set, so switching back to a hi-res panel RESTORES them rather than
# leaving them shrunk.
for _k in KITTY_FONT TITLE_FONT MAKO_FONT LOCK_RADIUS CURSOR_SIZE MAGNIFY; do
  [ -n "$(val "$_lo" "$_k")" ] || fail "lodpi left $_k empty; it sets all six"
done

set_panel 3840
_hi=$(run ui) || fail "ui failed on a 3840 panel: $_hi"
for _k in KITTY_FONT MAKO_FONT LOCK_RADIUS; do
  [ -z "$(val "$_hi" "$_k")" ] \
    || fail "$_k is SHRINK-ONLY and must be empty on a hi-res panel, got
'$(val "$_hi" "$_k")' -- a consumer would take that as an instruction to
shrink, which is how an 'override' once made every size smaller"
done
for _k in TITLE_FONT CURSOR_SIZE MAGNIFY; do
  [ -n "$(val "$_hi" "$_k")" ] \
    || fail "$_k must ALWAYS be set, or switching back to hi-res leaves the
previous shrunk value in place"
done
pass "hidpi is a no-op for the shrink-only keys, lodpi sets all six"

# --- the bucket boundary is `<`, so LODPI_MAX_W itself is hi-res ------------
set_panel 2559
[ "$(val "$(run ui)" CURSOR_SIZE)" = 32 ] || fail "2559 must bucket lodpi"
set_panel 2560
[ "$(val "$(run ui)" CURSOR_SIZE)" = 48 ] \
  || fail "2560 is LODPI_MAX_W and must bucket HI-res (the test is <, not <=)"
pass "the density boundary is exclusive at LODPI_MAX_W"

# --- an override wins PER KEY, leaving the rest on the calibrated set -------
set_panel 3840
_id=$(run id) || fail "could not resolve an id for the override fixture"
[ -n "$_id" ] || fail "empty id; the override path cannot be exercised"
printf 'KITTY_FONT=10\nCURSOR_SIZE=64\n' > "$T/profiles/$_id.ui"
_ov=$(run ui) || fail "ui failed with an override: $_ov"
[ "$(val "$_ov" KITTY_FONT)" = 10 ] \
  || fail "override did not win for KITTY_FONT"
[ "$(val "$_ov" CURSOR_SIZE)" = 64 ] \
  || fail "override did not win for CURSOR_SIZE"
[ "$(val "$_ov" TITLE_FONT)" = "$(val "$_hi" TITLE_FONT)" ] \
  || fail "an unlisted key must keep the calibrated value"
[ -z "$(val "$_ov" MAKO_FONT)" ] \
  || fail "an unlisted shrink-only key must stay empty"
pass "an override wins per key and leaves the rest on the set"

# --- AN EMPTY OVERRIDE VALUE IS THE SAME AS AN ABSENT ONE ------------------
# Each key is applied only when non-empty, so `KEY=` cannot force an empty
# answer -- it is simply ignored. Worth pinning because it reads like the
# obvious way to say "use the consumer's own default", and silently is not.
set_panel 1920
printf 'LOCK_RADIUS=\nCURSOR_SIZE=\n' > "$T/profiles/$_id.ui"
_empty=$(run ui) || fail "ui failed with empty override values: $_empty"
[ "$(val "$_empty" LOCK_RADIUS)" = "$(val "$_lo" LOCK_RADIUS)" ] \
  || fail "an EMPTY override value cleared LOCK_RADIUS; it must be ignored,
leaving the density default -- writing 'KEY=' to mean 'use the default' is a
trap, and this test exists so the trap stays documented rather than surprising"
[ "$(val "$_empty" CURSOR_SIZE)" = "$(val "$_lo" CURSOR_SIZE)" ] \
  || fail "an EMPTY override value cleared CURSOR_SIZE"
rm -f "$T/profiles/$_id.ui"
pass "an empty override value is ignored, not honoured as empty"

# --- HWDP_TARGET_PPI selects the SET outright, ignoring panel width --------
# With a target set, every output is scaled toward one logical density, so the
# width of any one panel stops being the question. Below LODPI_MAX_PPI takes
# the lodpi calibration, at or above takes hidpi -- on the SAME panel.
set_panel 1920
_t_hi=$(HWDP_TARGET_PPI=200 run ui) || fail "ui failed with a hi target"
[ "$(val "$_t_hi" CURSOR_SIZE)" = 48 ] \
  || fail "a hi HWDP_TARGET_PPI must take the hidpi set on a narrow panel"
[ -z "$(val "$_t_hi" KITTY_FONT)" ] \
  || fail "a hi target must leave the shrink-only keys empty"
set_panel 3840
_t_lo=$(HWDP_TARGET_PPI=90 run ui) || fail "ui failed with a lo target"
[ "$(val "$_t_lo" CURSOR_SIZE)" = 32 ] \
  || fail "a lo HWDP_TARGET_PPI must take the lodpi set on a WIDE panel"
pass "HWDP_TARGET_PPI selects the calibrated set, overriding panel width"

# --- mixed DPI warns on STDERR and still answers ---------------------------
# Two panels more than 25% apart in physical density. There is nowhere to put
# a per-output value (every consumer has one global config), so it sizes for
# the densest, SAYS so, and still exits 0 with a full key set: a consumer that
# swallows stderr must still get six usable numbers.
cat > "$T/user/layout/10-stub" <<'EOF'
#!/bin/sh
# name conn mode_w mode_h mm_w mm_h rate transform scale x y enabled
printf 'DP-1\tc1\t3840\t2160\t600\t340\t60\tnormal\t1\t0\t0\t1\n'
printf 'DP-2\tc2\t1920\t1080\t530\t300\t60\tnormal\t1\t1920\t0\t1\n'
EOF
chmod +x "$T/user/layout/10-stub"
_err=$T/mixed.err
_mx=$(run ui 2>"$_err") || fail "ui must still answer on a mixed desk: $_mx"
grep -q "MIXED DPI" "$_err" || fail "no mixed-DPI warning: $(cat "$_err")"
grep -q "HWDP_TARGET_PPI" "$_err" \
  || fail "the warning must name the lever that fixes it"
[ "$(printf '%s\n' "$_mx" | grep -c .)" -eq 6 ] \
  || fail "a mixed desk must still emit all six keys, got: $_mx"
# Sized for the DENSEST panel (3840 wide => hi-res), not the coarsest.
[ "$(val "$_mx" CURSOR_SIZE)" = 48 ] \
  || fail "mixed DPI must size for the densest panel"
pass "mixed DPI warns on stderr and still answers with a full key set"

# --- a target SUPPRESSES the warning, because it removes the difference ----
_err2=$T/mixed2.err
HWDP_TARGET_PPI=110 run ui 2>"$_err2" >/dev/null \
  || fail "ui failed with a target on a mixed desk"
grep -q "MIXED DPI" "$_err2" \
  && fail "with HWDP_TARGET_PPI set the panels are scaled to ONE density, so
the mixed-DPI warning is stale advice and must not fire"
pass "HWDP_TARGET_PPI suppresses the mixed-DPI warning"
