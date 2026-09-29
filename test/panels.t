#!/bin/sh
# panels.t - `hwdp panels` publishes what is ATTACHED, headless.
#
# The counterpart to geometry, and the pair is the package's central split:
# panels asks the KERNEL what is plugged in (so it answers with no compositor),
# geometry asks a COMPOSITOR how it is arranged (so it cannot). A provisioning
# layer sizing something drawn BEFORE any session -- a boot menu, a greeter --
# needs the first, and until this verb existed it had to either parse DRM itself
# (a fifth copy of a parser this repo has killed four of) or ask geometry and
# get a failure.
#
# Pinned here:
#   1. the record is `<connector> <native_w> <native_h>`, space-separated, one
#      line per CONNECTED panel, in provider order;
#   2. it answers with NO session at all -- that is the entire point;
#   3. the EDID hash is NOT emitted. The provider record leads with one, but it
#      is an id INGREDIENT and `hwdp id` is the published way to ask for
#      identity; leaking it invites a caller to build a second, subtly
#      different id from it;
#   4. nothing connected is EMPTY output at status 0 -- an answer, not an
#      error, so a caller can tell "no panels" from "the probe broke".
. "$(dirname "$0")/harness_lib"
harness_init panels

MGR=$HERE/bin/hwdp
mkdir -p "$T/drm"

# Two connected panels and one disconnected, so "connected only" is proved
# rather than assumed.
for _spec in "card0-DP-1:connected:3840x2160:edid-dell" \
             "card0-eDP-1:connected:2880x1800:edid-laptop" \
             "card0-HDMI-A-1:disconnected:1920x1080:edid-ghost"; do
  _c=${_spec%%:*}; _rest=${_spec#*:}
  _st=${_rest%%:*}; _rest=${_rest#*:}
  _mode=${_rest%%:*}; _edid=${_rest#*:}
  mkdir -p "$T/drm/$_c"
  printf '%s\n' "$_st"   > "$T/drm/$_c/status"
  printf '%s\n' "$_mode" > "$T/drm/$_c/modes"
  printf '%s'   "$_edid" > "$T/drm/$_c/edid"
done

# NO WAYLAND_DISPLAY, NO DISPLAY: headless is the case under test. The layout
# providers are pointed at a dead path too, so nothing can answer for geometry.
run_panels() {
  env -u WAYLAND_DISPLAY -u DISPLAY \
    HOME="$T/home" XDG_CONFIG_HOME="$T/config" \
    HWDP_DRM="$T/drm" \
    HWDP_PROVIDER_ROOT="$T/no-providers" \
    HWDP_MACHINE_PROVIDERS="$T/no-providers" \
    "$MGR" panels "$@"
}

out=$(run_panels) || fail "panels failed headless: $out"
[ -n "$out" ] || fail "panels produced nothing with two panels connected"

# --- 1 + 2: the record shape, connected only -------------------------------
_n=$(printf '%s\n' "$out" | grep -c .)
[ "$_n" -eq 2 ] || fail "want 2 connected panels, got $_n: [$out]"
printf '%s\n' "$out" | grep -q '^DP-1 3840 2160$' \
  || fail "DP-1 record wrong: [$out]"
printf '%s\n' "$out" | grep -q '^eDP-1 2880 1800$' \
  || fail "eDP-1 record wrong: [$out]"
printf '%s\n' "$out" | grep -q 'HDMI' \
  && fail "a DISCONNECTED connector was reported as attached"
printf '%s\n' "$out" | while read -r _line; do
  _f=$(printf '%s\n' "$_line" | wc -w)
  [ "$_f" -eq 3 ] || fail "record must be 3 fields, got $_f: [$_line]"
done
pass "headless record: connector + native w/h, connected only"

# --- 3: identity is NOT leaked ---------------------------------------------
# The provider's first field is a sha256 of the EDID. A 64-hex-char token in
# this output means the record was passed through rather than projected.
printf '%s\n' "$out" | grep -qE '[0-9a-f]{32}' \
  && fail "panels leaked the EDID hash; 'hwdp id' is the identity interface"
# And the values are numeric, so a caller can do arithmetic without parsing.
printf '%s\n' "$out" | while read -r _nm _w _h; do
  case "$_w$_h" in *[!0-9]*) fail "non-numeric size for $_nm: $_w $_h" ;; esac
done
pass "no EDID hash in the output, and the sizes are numeric"

# --- geometry, the counterpart, MUST fail here -- that is why panels exists --
if run_geo=$(env -u WAYLAND_DISPLAY -u DISPLAY HOME="$T/home" \
    HWDP_DRM="$T/drm" HWDP_PROVIDER_ROOT="$T/no-providers" \
    HWDP_MACHINE_PROVIDERS="$T/no-providers" "$MGR" geometry 2>&1); then
  fail "geometry answered headless; the panels/geometry split is not real"
fi
pass "geometry cannot answer headless, which is the reason for this verb"

# --- 4: nothing connected is an empty ANSWER, not an error ------------------
printf 'disconnected\n' > "$T/drm/card0-DP-1/status"
printf 'disconnected\n' > "$T/drm/card0-eDP-1/status"
out=$(run_panels) || fail "panels must exit 0 with nothing connected"
[ -z "$out" ] || fail "want empty output with nothing connected, got: [$out]"
pass "nothing connected is empty output at status 0"

# --- an unexpected argument is refused, not ignored -------------------------
run_panels --bogus >/dev/null 2>&1 \
  && fail "panels accepted an unexpected argument" || :
pass "an unexpected argument is refused"
