#!/bin/sh
# layout-all.t - the runtime kanshi config carries EVERY confirmed desk, the
# attached set's first.
#
# kanshi applies the profile whose outputs are exactly the connected set, and
# re-checks on every hotplug, so with every authored profile in its config it
# switches desks by itself, at once (the user's ask, 2026-11-12). The attached
# set's profile must stay FIRST, since kanshi takes the first match; the rest
# follow profile_for's precedence (a desk named by the @builtin role before a
# plain id); every profile name must be unique, since kanshi refuses the whole
# file otherwise; a panel not attached takes its sticky scale by name; and the
# gap check still judges only the current layout.
. "$(dirname "$0")/harness_lib"
harness_init layout-all

KA=$HERE/bin/hwdp
mkdir -p "$T/bin" "$T/drm" "$T/profiles"

# A laptop (LAPTOP=A, or none) and a dock of two externals (DOCK=yes|no).
cat > "$T/bin/wlr-randr" <<'STUB'
#!/bin/sh
_out() {   # <conn> <make> <model> <serial> <w> <h> <x> <y> <tr>
  cat <<BLK
$1 "$2 $3 $4 ($1)"
  Make: $2
  Model: $3
  Serial: $4
  Physical size: 600x340 mm
  Enabled: yes
  Modes:
    ${5}x${6} px, 60.000000 Hz (preferred, current)
  Position: $7,$8
  Transform: $9
  Scale: 1.000000
BLK
}
[ "${LAPTOP:-A}" = A ] && _out eDP-1 Lenovo X1 SNA 2880 1800 2640 3840 normal
if [ "${DOCK:-yes}" = yes ]; then
  _out DP-1 Acme PORTRAIT SN2 3840 2160 0 0 90
  _out DP-2 Acme WIDE SN3 3840 2160 2160 1680 normal
fi
STUB
chmod +x "$T/bin/wlr-randr"

drm() {   # <LAPTOP> <DOCK>: the kernel's view, matching the stub
  rm -rf "$T/drm"; mkdir -p "$T/drm"
  if [ "$1" = A ]; then
    mkdir -p "$T/drm/card1-eDP-1"
    printf connected > "$T/drm/card1-eDP-1/status"
    printf 'EDID-LAPTOP-A' > "$T/drm/card1-eDP-1/edid"
  fi
  [ "$2" = yes ] || return 0
  for _c in DP-1 DP-2; do
    mkdir -p "$T/drm/card1-$_c"
    printf connected > "$T/drm/card1-$_c/status"
    printf 'EDID-%s' "$_c" > "$T/drm/card1-$_c/edid"
  done
}
run() {
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" \
    WAYLAND_DISPLAY=wayland-test XDG_RUNTIME_DIR="$T/run" \
    HWDP_MACHINE_PROVIDERS="$T/no-machine" HWDP_PROVIDER_ROOT="$T/no-user" \
    HWDP_DRM="$T/drm" KANSHI_PROFILES="$T/profiles" \
    KANSHI_STICKY="$T/sticky" KANSHI_OUT="$T/out" \
    HWDP_SURFACES="$T/surf" HWDP_DESKS="$T/desks" \
    LAPTOP="${LAPTOP:-A}" DOCK="${DOCK:-yes}" sh "$KA" "$@"
}
names() { sed -n 's/^[ \t]*profile \([^ {]*\).*/\1/p' "$T/out"; }

# The desk, laid out from the laptop, filed under the desk id with @builtin.
drm A yes
desk=$(run id --desk)
run arrange DP-1 'DP-2 right-of DP-1 align bottom' \
  'eDP-1 below DP-2 align center' >/dev/null 2>&1 || fail "arrange failed"
[ -f "$T/profiles/$desk.conf" ] || fail "no desk profile to work with"
# Two hand-written walls of a panel never attached here, SHARING a profile
# name, and that panel's scale in the sticky file.
for _id in aaaaaaaaaaaa bbbbbbbbbbbb; do
  printf 'profile wall {\n    output "Acme WALL SN9" mode %s %s\n}\n' \
    3840x2160@60.000Hz 'transform 90 position 0,0' \
    > "$T/profiles/$_id.conf"
done
printf 'Acme WALL SN9\t1.50\t3840x2160@600x340\n' >> "$T/sticky"

# --- undocked: the synthesized profile, then every desk -----------------------
drm A no
DOCK=no run layout >/dev/null 2>"$T/err" || fail "layout undocked failed"
_n=$(names | tr '\n' ' ')
[ "$_n" = "autoscale hwdp-$desk hwdp-aaaaaaaaaaaa hwdp-bbbbbbbbbbbb " ] \
  || fail "want the attached set first, then the desk, then the plain ids,
each once: got '$_n'"
[ "$(names | sort | uniq -d)" = "" ] \
  || fail "two profiles share a name; kanshi refuses the whole config"
grep -q '^    output "Lenovo X1 SNA" mode 2880x1800@60.000Hz' "$T/out" \
  || fail "the desk's built-in role was not filled with this laptop's panel"
grep -v '^ *#' "$T/out" | grep -q '@builtin' \
  && fail "the role reached a kanshi directive: $(cat "$T/out")"
grep -q '"Acme WALL SN9" .* scale 1.50$' "$T/out" \
  || fail "a panel not attached did not take its sticky scale by name"
grep -q 'WARNING' "$T/err" \
  && fail "the gap check judged more than the current layout: $(cat "$T/err")"
pass "undocked: synthesized first, then desk, then plain; unique names"

# --- docked: the desk is current, and not repeated ---------------------------
drm A yes
run layout >/dev/null 2>"$T/err" || fail "layout docked failed"
_n=$(names | tr '\n' ' ')
[ "$_n" = "hwdp-$desk hwdp-aaaaaaaaaaaa hwdp-bbbbbbbbbbbb " ] \
  || fail "docked, the desk must lead and appear once: got '$_n'"
pass "docked: the desk leads, and appears once"

# --- no built-in panel: a desk profile cannot match, so it is left out -------
drm none yes
LAPTOP=none run layout >/dev/null 2>"$T/err" \
  || fail "layout with no built-in failed: $(cat "$T/err")"
names | grep -qx "hwdp-$desk" \
  && fail "a desk profile was emitted on a machine with no built-in panel"
grep -v '^ *#' "$T/out" | grep -q '@builtin' \
  && fail "the role reached a kanshi directive with no built-in"
pass "no built-in: the desk profile is left out"
