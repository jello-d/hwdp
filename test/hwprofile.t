#!/bin/sh
# modules/tests/hwprofile - stub-driven. A fake sysfs tree holds two BT adapters
# (an Intel 8087:0a2b at LMP 0x6 and a Realtek 0b05:1d70 at LMP 0xe) plus a
# stubbed hciconfig/lspci/hostnamectl. Asserts hwprofile picks the OLDER (lower
# LMP) adapter as the loser, records nvidia + chassis + btrfs-root (from a
# stubbed findmnt), that has_capability reads it back, that the value is STICKY
# across a deauthorized (partial) re-run, and that a hand edit survives while an
# adapter-set change (or a root-FS change) recomputes. The box is never touched.
set -eu

. "$(dirname "$0")/lib.sh"
harness_init hwprofile

HW=$HERE/bin/hwprofile
mkdir -p "$T/bin" "$T/sys" "$T/hci/hci0" "$T/hci/hci1" "$T/self"
PROFILE=$T/self/hwprofile

# --- fake sysfs USB: two BT-class (e0/01/01) adapters + a decoy hub ----------
mk_usb() {   # <dir> <vid> <pid> <class> <sub> <proto>
  _d=$T/sys/$1; mkdir -p "$_d"
  printf '%s\n' "$2" > "$_d/idVendor"; printf '%s\n' "$3" > "$_d/idProduct"
  printf '%s\n' "$4" > "$_d/bDeviceClass"
  printf '%s\n' "$5" > "$_d/bDeviceSubClass"
  printf '%s\n' "$6" > "$_d/bDeviceProtocol"
}
mk_usb 1-11 8087 0a2b e0 01 01     # Intel internal (the older adapter)
mk_usb 1-8  0b05 1d70 e0 01 01     # Realtek dongle (the newer adapter)
mk_usb 1-1  0bda 5411 09 00 00     # a hub decoy (must be ignored)

# --- fake /sys/class/bluetooth: two live hci, each pointing at its USB dev ----
ln -s "$T/sys/1-11" "$T/hci/hci0/device"
ln -s "$T/sys/1-8"  "$T/hci/hci1/device"

# --- stubs: hciconfig maps hci name -> LMP; lspci/hostnamectl fixed output ----
cat > "$T/bin/hciconfig" <<EOF
#!/bin/sh
# args: -a <hciN>; LMP per hci, or a forced same-LMP TIE via \$T/hci-tie
for a; do case \$a in
  hci0) echo "  LMP Version:  (0x6)"; exit 0;;
  hci1) if [ -f "$T/hci-tie" ]; then echo "  LMP Version:  (0x6)"
        else echo "  LMP Version:  (0xe)"; fi; exit 0;;
esac; done
EOF
# lspci/hostnamectl are KNOB-driven (like findmnt): a per-case file overrides
# the default, so the ABSENT branches (no NVIDIA card / no chassis) are driven.
cat > "$T/bin/lspci" <<EOF
#!/bin/sh
cat "$T/lspci-out" 2>/dev/null || \\
  echo "b3:00.0 VGA controller [0300]: NVIDIA TU104 [10de:1EB1] (rev a1)"
EOF
cat > "$T/bin/hostnamectl" <<EOF
#!/bin/sh
cat "$T/chassis" 2>/dev/null || echo desktop
EOF
# findmnt: root FS type from a marker (default ext4 => btrfs-root absent); a
# fixed UUID for the fingerprint. Driven per-case by $T/rootfs.
cat > "$T/bin/findmnt" <<EOF
#!/bin/sh
case "\$*" in
  *FSTYPE*) cat "$T/rootfs" 2>/dev/null || echo ext4 ;;
  *UUID*)   echo 1111-2222-3333 ;;
esac
EOF
chmod +x "$T/bin"/*

run() {
  env -i PATH="$T/bin:/usr/bin:/bin" \
    HWPROFILE="$PROFILE" SYSUSB="$T/sys" BTCLASS="$T/hci" \
    sh "$HW" "$@"
}
# Read the resolved value straight from the profile file (the reader that stays
# in the integrator's framework is not this package's; the profile IS the
# contract). Prints the value; non-zero when the cap is absent OR empty -- the
# same present/absent semantics an integrator's has-capability reader honours.
cap() {   # <cap>
  _v=$(awk -F'\t' -v c="$1" '$1==c{print $2; f=1} END{exit !f}' \
    "$PROFILE" 2>/dev/null) || return 1
  [ -n "$_v" ] || return 1
  printf '%s' "$_v"
}

# --- 0. an early PARTIAL measurement must not poison later recovery -----------
# Stash the Intel hci OUTSIDE $BTCLASS (a rename inside it still matches hci*),
# so only the Realtek is live: hwprofile sees 2 adapters in the USB set but 1
# readable -> partial -> stores an EMPTY loser. Bringing the Intel back must let
# a re-run RECOVER the loser, not inherit the blank (the non-empty guard).
mv "$T/hci/hci0" "$T/hci0.stash"
run >/dev/null 2>&1 || fail "partial-first run exited non-zero"
cap bt-older-adapter >/dev/null 2>&1 && fail "partial run should read absent"
mv "$T/hci0.stash" "$T/hci/hci0"
run >/dev/null 2>&1 || fail "recovery run exited non-zero"
[ "$(cap bt-older-adapter)" = "8087:0a2b" ] || fail "poisoned: no recovery"

# --- 1. full detection: older (Intel, LMP 0x6) is the loser ------------------
run >/dev/null 2>&1 || fail "hwprofile exited non-zero"
[ -f "$PROFILE" ] || fail "no profile written"
[ "$(cap bt-older-adapter)" = "8087:0a2b" ] || fail "loser is not the Intel"
[ "$(cap nvidia-gpu)" = "nvidia" ] || fail "nvidia-gpu not detected"
[ "$(cap chassis)" = "desktop" ]  || fail "chassis not desktop"

# --- 2. has_capability is false for an absent capability ---------------------
cap smartcard >/dev/null 2>&1 && fail "absent capability read true"

# --- 2a. nvidia-gpu ABSENT branch: lspci with no NVIDIA line -> absent, then
#         re-detects when the card returns (the fingerprint-changed recompute).
: > "$T/lspci-out"                        # lspci emits no VGA/3D NVIDIA id
run >/dev/null 2>&1 || fail "nvidia-absent run exited non-zero"
cap nvidia-gpu >/dev/null 2>&1 && fail "nvidia-gpu true with no NVIDIA card"
rm -f "$T/lspci-out"                      # NVIDIA card back
run >/dev/null 2>&1 || fail "nvidia-restore run exited non-zero"
[ "$(cap nvidia-gpu)" = nvidia ] || fail "nvidia-gpu not re-detected"

# --- 2b. chassis ABSENT branch: hostnamectl prints nothing -> absent, then
#         re-detects when the type returns. --------------------------------
: > "$T/chassis"                          # hostnamectl yields no chassis type
run >/dev/null 2>&1 || fail "chassis-absent run exited non-zero"
cap chassis >/dev/null 2>&1 && fail "chassis true with no chassis type"
rm -f "$T/chassis"                        # desktop back
run >/dev/null 2>&1 || fail "chassis-restore run exited non-zero"
[ "$(cap chassis)" = desktop ] || fail "chassis not re-detected"

# --- 2c. two adapters at the SAME LMP: a TIE has no loser (absent) + warns.
#         Fresh profile so no stored loser masks the tie; both hci still live.
touch "$T/hci-tie"                        # force hci1 to also report LMP 0x6
rm -f "$PROFILE"
err=$(run 2>&1 >/dev/null) || fail "tie run exited non-zero"
cap bt-older-adapter >/dev/null 2>&1 && fail "a same-LMP tie must have no loser"
printf '%s\n' "$err" | grep -qi 'tie at LMP' \
  || fail "tie not reported on stderr"
rm -f "$T/hci-tie"                        # restore the distinct-LMP mapping
run >/dev/null 2>&1 || fail "post-tie restore run exited non-zero"
[ "$(cap bt-older-adapter)" = "8087:0a2b" ] \
  || fail "loser not re-detected after the tie cleared"

# --- 3. sticky across a partial (deauthorized) view: drop the Intel hci and
#        its USB interface probing, but keep it in the USB set. The loser must
#        still resolve to the Intel from the stored value, not recompute. ------
rm -rf "$T/hci/hci0"                     # Intel no longer live (deauthorized)
run >/dev/null 2>&1 || fail "partial re-run exited non-zero"
[ "$(cap bt-older-adapter)" = "8087:0a2b" ] \
  || fail "sticky loser lost on partial view"

# --- 4. hand edit survives while the fingerprint is unchanged ----------------
tmp=$(mktemp)
awk -F'\t' 'BEGIN{OFS="\t"} $1=="bt-older-adapter"{$2="dead:beef"} {print}' \
  "$PROFILE" > "$tmp" && mv "$tmp" "$PROFILE"
run >/dev/null 2>&1 || fail "re-run after hand edit exited non-zero"
[ "$(cap bt-older-adapter)" = "dead:beef" ] || fail "hand edit not honoured"

# --- 5. adapter-set change recomputes: drop one adapter -> <2 -> absent -------
rm -rf "$T/sys/1-11"                      # only the dongle remains in the set
run >/dev/null 2>&1 || fail "single-adapter re-run exited non-zero"
cap bt-older-adapter >/dev/null 2>&1 && fail "loser lingered with one adapter"

# --- 6. btrfs-root: substrate cap, present iff the root FS is btrfs -----------
echo btrfs > "$T/rootfs"
run >/dev/null 2>&1 || fail "btrfs-root run exited non-zero"
[ "$(cap btrfs-root)" = btrfs ] || fail "btrfs-root not seen on a btrfs root"
echo ext4 > "$T/rootfs"   # root FS changed, so btrfs-root recomputes to absent
run >/dev/null 2>&1 || fail "non-btrfs run exited non-zero"
cap btrfs-root >/dev/null 2>&1 && fail "btrfs-root true on a non-btrfs root"

pass
