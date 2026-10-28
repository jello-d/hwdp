#!/bin/sh
# panelid.t - `hwdp id --panels` names each MONITOR, not the desk.
#
# The set id answers "which desk am I at" and deliberately hashes away which
# panel sits on which connector. A consumer storing PER-PANEL state needs the
# other granularity: usher keys a window's remembered slot on the output, and
# in a docking setup the connector name is the least stable thing there is
# while the panel it names is exactly what the slot means.
#
# Pinned here:
#   1. the record is `<connector> <panel-id>`, space separated, one line per
#      CONNECTED panel;
#   2. a panel id is STABLE for a panel and INDEPENDENT of its connector, which
#      is the entire reason the verb exists;
#   3. it is TRUNCATED, so the full 64-hex ingredient never reaches a caller
#      and the set id cannot be rebuilt from panel ids. `hwdp panels` refuses
#      to emit the hash on exactly that ground, and this must not reopen it;
#   4. the set id is UNCHANGED by the flag existing, and the two cannot be
#      derived from each other;
#   5. it answers HEADLESS, like every other member of the panels class;
#   6. nothing connected is EMPTY output at status 0, an answer, not an error;
#   7. an unexpected argument is refused rather than ignored.
. "$(dirname "$0")/harness_lib"
harness_init panelid

MGR=$HERE/bin/hwdp
mkdir -p "$T/drm"

# plant <connector> <status> <mode> <edid>
plant() {
  mkdir -p "$T/drm/card0-$1"
  printf '%s\n' "$2" > "$T/drm/card0-$1/status"
  printf '%s\n' "$3" > "$T/drm/card0-$1/modes"
  printf '%s'   "$4" > "$T/drm/card0-$1/edid"
}

# NO WAYLAND_DISPLAY, NO DISPLAY, and the layout providers pointed at a dead
# path: headless is a property under test, not an accident of the box.
run_id() {
  env -u WAYLAND_DISPLAY -u DISPLAY \
    HOME="$T/home" XDG_CONFIG_HOME="$T/config" \
    HWDP_DRM="$T/drm" \
    HWDP_PROVIDER_ROOT="$T/no-providers" \
    HWDP_MACHINE_PROVIDERS="$T/no-providers" \
    "$MGR" id "$@"
}

plant DP-1      connected    3840x2160 edid-dell
plant eDP-1     connected    2880x1800 edid-laptop
plant HDMI-A-1  disconnected 1920x1080 edid-ghost

out=$(run_id --panels) || fail "id --panels failed headless: $out"

# --- 1 + 5: the record shape, connected only, with no session --------------
_n=$(printf '%s\n' "$out" | grep -c .)
[ "$_n" -eq 2 ] || fail "want 2 connected panels, got $_n: [$out]"
printf '%s\n' "$out" | grep -q 'HDMI' \
  && fail "a DISCONNECTED connector was given a panel id"
printf '%s\n' "$out" | while read -r _line; do
  _f=$(printf '%s\n' "$_line" | wc -w)
  [ "$_f" -eq 2 ] || fail "record must be 2 fields, got $_f: [$_line]"
done
printf '%s\n' "$out" | while read -r _nm _pid; do
  case "$_pid" in
    *[!0-9a-f]*) fail "panel id for $_nm is not hex: $_pid" ;;
  esac
done
pass "headless record: connector + hex panel id, connected only"

_dp=$(printf '%s\n' "$out" | awk '$1 == "DP-1" { print $2 }')
_ed=$(printf '%s\n' "$out" | awk '$1 == "eDP-1" { print $2 }')
[ -n "$_dp" ] && [ -n "$_ed" ] || fail "missing a panel id: [$out]"
[ "$_dp" != "$_ed" ] || fail "two DIFFERENT panels share a panel id"
pass "different panels get different ids"

# --- 3: the ingredient does not leak ---------------------------------------
# A 32-hex-or-longer token would mean the provider's full sha256 was passed
# through, which is what `hwdp panels` exists to refuse.
printf '%s\n' "$out" | grep -qE '[0-9a-f]{32}' \
  && fail "id --panels leaked the full EDID hash; a set id becomes rebuildable"
[ "${#_dp}" -eq 12 ] || fail "panel id should be 12 chars, got ${#_dp}: $_dp"
pass "panel ids are truncated, so no set id can be rebuilt from them"

# --- 2: THE WHOLE POINT. Move the panel to a different connector. ----------
# This is the docking failure the verb exists for: a monitor comes back on
# another port and anything keyed on the connector name has lost it.
_set_before=$(run_id)
rm -rf "$T/drm/card0-DP-1"
plant DP-3 connected 3840x2160 edid-dell
out2=$(run_id --panels) || fail "id --panels failed after a re-plug: $out2"
_moved=$(printf '%s\n' "$out2" | awk '$1 == "DP-3" { print $2 }')
[ "$_moved" = "$_dp" ] \
  || fail "the panel id CHANGED with the connector ($_dp -> $_moved)"
printf '%s\n' "$out2" | grep -q '^DP-1 ' \
  && fail "the old connector is still reported"
pass "a panel keeps its id across a move to another connector"

# --- 4: and the SET id is likewise connector-blind, as it always was -------
_set_after=$(run_id)
[ -n "$_set_before" ] || fail "the set id was empty with two panels connected"
[ "$_set_before" = "$_set_after" ] \
  || fail "the set id moved with a connector: $_set_before -> $_set_after"
# The two granularities must not be confusable: the set id is not any panel id.
[ "$_set_after" != "$_dp" ] && [ "$_set_after" != "$_ed" ] \
  || fail "the set id equals a panel id; the two would be interchangeable"
pass "the set id is unchanged, and is not any panel's id"

# --- the documented AMBIGUITY, verified rather than asserted ---------------
# Two panels of one model with no serial share an EDID, so they share a panel
# id and nothing downstream can tell them apart. The verb's comment claims
# this; a claim about behaviour in a comment is worth exactly as much as the
# check under it.
plant DP-5 connected 3840x2160 edid-dell
out3=$(run_id --panels)
_dupes=$(printf '%s\n' "$out3" | awk '{ print $2 }' | sort | uniq -d | wc -l)
[ "$_dupes" -eq 1 ] \
  || fail "two identical EDIDs should share one panel id; dupes=$_dupes"
pass "identical panels share an id, as documented (EDID cannot separate them)"

# --- 6: nothing connected is an empty ANSWER -------------------------------
for _c in "$T"/drm/card0-*; do printf 'disconnected\n' > "$_c/status"; done
out=$(run_id --panels) || fail "must exit 0 with nothing connected"
[ -z "$out" ] || fail "want empty output with nothing connected, got: [$out]"
pass "nothing connected is empty output at status 0"

# --- 7: an unexpected argument is refused ----------------------------------
run_id --bogus >/dev/null 2>&1 \
  && fail "id accepted an unexpected argument" || :
run_id --help >/dev/null 2>&1 || fail "id --help should succeed"
pass "an unexpected argument is refused, and --help works"
