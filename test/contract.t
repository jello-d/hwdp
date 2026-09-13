#!/bin/sh
# contract.t - the PROVIDER contract, asserted against the shipped providers.
#
# The whole design is drop-in providers: an integrator adds a compositor by
# adding a file, and probe.sh takes the first that answers. That only holds if
# every provider agrees on the RECORD, and nothing checked it. A provider that
# drifts a field -- or a new one written against a stale reading of the docs --
# surfaces as an empty or subtly wrong probe, which in this package has meant
# a blank bar or a confidently wrong cursor size rather than an error.
#
# So this pins the two things a provider author has to get right:
#   the SHAPE of a record (field count, and which fields are numbers)
#   the ABSTAIN contract (cannot answer here = non-zero OR silent, never a
#   partial record, because probe.sh treats any output as the answer)
. "$(dirname "$0")/lib.sh"
harness_init contract

P=$HERE/libexec/hwdp/providers
TAB=$(printf '\t')
mkdir -p "$T/bin" "$T/drm/card1-DP-2"

# --- layout: 12 fields ------------------------------------------------------
# name conn mode_w mode_h mm_w mm_h rate transform scale x y enabled
cat > "$T/bin/wlr-randr" <<'EOF'
#!/bin/sh
cat <<'OUT'
DP-2 "Dell Inc. U2515H ABC123 (DP-2)"
  Make: Dell Inc.
  Model: U2515H
  Serial: ABC123
  Physical size: 553x311 mm
  Enabled: yes
  Modes:
    2560x1440 px, 59.951000 Hz (preferred, current)
  Position: 0,0
  Transform: normal
  Scale: 1.000000
OUT
EOF
cat > "$T/bin/xrandr" <<'EOF'
#!/bin/sh
echo "Screen 0: minimum 320 x 200, current 1920 x 1080, maximum 16384 x 16384"
echo "DP-2 connected primary 1920x1080+0+0 (normal left inverted) 527mm x 296mm"
EOF
chmod +x "$T/bin/wlr-randr" "$T/bin/xrandr"

_fields() { awk -F"$TAB" 'NR==1{print NF}'; }

_out=$(PATH="$T/bin:$PATH" WAYLAND_DISPLAY=wayland-test \
  "$P/layout/10-wlr-randr")
[ -n "$_out" ] || fail "the wlr-randr provider answered nothing"
_n=$(printf '%s\n' "$_out" | _fields)
[ "$_n" -eq 12 ] || fail "wlr-randr provider emits $_n fields, the layout \
record is 12"

_out=$(PATH="$T/bin:$PATH" DISPLAY=:0 "$P/layout/20-xrandr")
[ -n "$_out" ] || fail "the xrandr provider answered nothing"
_n=$(printf '%s\n' "$_out" | _fields)
[ "$_n" -eq 12 ] || fail "xrandr provider emits $_n fields, the layout \
record is 12"

# The fields consumers do arithmetic on must be numeric in EVERY provider, or
# the consumer silently computes with a string. display-geometry divides by
# scale and compares mode_w; the kanshi adapter signs a sticky scale with the
# physical size.
printf '%s\n' "$_out" | awk -F"$TAB" '
  { for (i = 3; i <= 6; i++) if ($i !~ /^[0-9]+$/) exit 1
    if ($9 !~ /^[0-9.]+$/) exit 1
    if ($10 !~ /^-?[0-9]+$/ || $11 !~ /^-?[0-9]+$/) exit 1
    if ($12 !~ /^[01]$/) exit 1 }' \
  || fail "xrandr provider emitted a non-numeric value in a numeric field"

# --- panels: 4 fields -------------------------------------------------------
# edid_sha conn native_w native_h
printf 'connected\n' > "$T/drm/card1-DP-2/status"
printf 'EDID-BYTES-HERE' > "$T/drm/card1-DP-2/edid"
printf '2560x1440\n1920x1080\n' > "$T/drm/card1-DP-2/modes"
_out=$(HWDP_DRM="$T/drm" "$P/panels/10-drm-sysfs")
[ -n "$_out" ] || fail "the drm-sysfs provider answered nothing"
_n=$(printf '%s\n' "$_out" | _fields)
[ "$_n" -eq 4 ] || fail "drm-sysfs provider emits $_n fields, the panels \
record is 4"
printf '%s\n' "$_out" | awk -F"$TAB" '
  { if ($1 !~ /^[0-9a-f]{64}$/) exit 1     # a sha256, the id is built on it
    if ($3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/) exit 1 }' \
  || fail "drm-sysfs provider emitted a malformed sha or size"

# --- abstain: non-zero OR silent, never a partial record --------------------
# probe.sh takes ANY non-empty output as the answer and stops, so a provider
# that half-answers in an environment it does not serve would shadow the one
# that could.
_out=$(env -u WAYLAND_DISPLAY PATH="$T/bin:$PATH" "$P/layout/10-wlr-randr" \
  2>/dev/null) && _rc=0 || _rc=$?
[ "$_rc" -ne 0 ] || [ -z "$_out" ] \
  || fail "wlr-randr provider answered with no WAYLAND_DISPLAY: $_out"

_out=$(env -u DISPLAY PATH="$T/bin:$PATH" "$P/layout/20-xrandr" 2>/dev/null) \
  && _rc=0 || _rc=$?
[ "$_rc" -ne 0 ] || [ -z "$_out" ] \
  || fail "xrandr provider answered with no DISPLAY: $_out"

# A DRM tree with nothing connected is an abstention, not an empty-ish record.
mkdir -p "$T/drm-none/card1-DP-9"
printf 'disconnected\n' > "$T/drm-none/card1-DP-9/status"
_out=$(HWDP_DRM="$T/drm-none" "$P/panels/10-drm-sysfs" 2>/dev/null)
[ -z "$_out" ] || fail "drm-sysfs answered for a disconnected connector: $_out"

# --- every shipped provider is executable and parses ------------------------
# A provider that is not executable is skipped in silence by probe.sh, which
# looks identical to one that abstained.
_count=0
for _p in "$P"/*/*; do
  [ -f "$_p" ] || continue
  _count=$((_count + 1))
  [ -x "$_p" ] || fail "provider $_p is not executable (probe.sh would skip \
it silently)"
done
[ "$_count" -ge 3 ] || fail "expected at least 3 shipped providers, found \
$_count"

pass "$_count providers: record shape + numeric fields + abstain contract"
