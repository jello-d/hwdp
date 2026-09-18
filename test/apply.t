#!/bin/sh
# apply.t - `hwdp apply` fires the changed edge on demand.
#
# The verb exists because the hooks are otherwise driven only by DISPLAY events,
# while the answers hwdp gives also depend on things no display event announces
# (a per-rig <id>.ui override, the calibrated sizing). A consumer that caches
# its answer to a file then serves the stale one forever. Observed live:
# deleting an override left mako on the old font for over an hour.
#
# What is pinned here:
#   1. it runs the changed hooks, machine root BEFORE user root;
#   2. it does NOT run `pre` -- that is a startup ORDERING edge, and firing it
#      at an arbitrary moment asserts an invariant with nothing to order
#      against;
#   3. a failing hook does not stop the others (fail-soft, as on every edge)
#      but DOES make the overall status non-zero, so a provisioning run that
#      wires this in cannot read a half-done reaction as success;
#   4. no hooks wired is a legitimate no-op that SAYS so, rather than exiting
#      silently -- "did nothing" and "found nothing to do" look identical from
#      outside and only one is a problem;
#   5. hooks run with fd 9 CLOSED, the same rule the supervisor needs. apply
#      holds no lock, so this is about the SHARED runner keeping one behaviour:
#      the rule is invisible at the call site and a second copy would sooner or
#      later be written without it.
. "$(dirname "$0")/lib.sh"
harness_init apply

MGR=$HERE/bin/hwdp
mkdir -p "$T/user/changed.d" "$T/user/pre.d" "$T/machine/changed.d"

# Ordering: machine root first, then user, each sorted by name.
for _spec in "machine/changed.d/10-m:m10" "user/changed.d/10-u:u10" \
             "user/changed.d/90-u:u90"; do
  _p=${_spec%:*}; _tag=${_spec#*:}
  cat > "$T/$_p" <<EOF
#!/bin/sh
echo $_tag >> "$T/order"
EOF
  chmod +x "$T/$_p"
done

# A `pre` hook that must NOT run.
cat > "$T/user/pre.d/10-pre" <<EOF
#!/bin/sh
echo PRE-RAN >> "$T/order"
EOF
chmod +x "$T/user/pre.d/10-pre"

# fd 9 probe: records whether it inherited an open fd 9.
cat > "$T/user/changed.d/50-fd" <<EOF
#!/bin/sh
if [ -e /proc/self/fd/9 ]; then echo "FD9-OPEN" >> "$T/fd"
else echo "fd9-closed" >> "$T/fd"; fi
EOF
chmod +x "$T/user/changed.d/50-fd"

run_apply() {   # runs with fd 9 HELD open by this shell, as the supervisor does
  HWDP_HOOK_ROOT="$T/user" HWDP_MACHINE_HOOKS="$T/machine" \
    "$MGR" apply "$@" 9>"$T/lockfile"
}

# --- 1 + 2 + 5: fires changed, in order, not pre, with fd 9 closed ----------
out=$(run_apply 2>&1) || fail "apply failed with all hooks passing: $out"
order=$(tr '\n' ' ' < "$T/order" | sed 's/ $//')
[ "$order" = "m10 u10 u90" ] \
  || fail "wrong hook order/set: got '$order', want 'm10 u10 u90'"
grep -q PRE-RAN "$T/order" && fail "apply ran the pre edge; it must not"
[ "$(cat "$T/fd")" = "fd9-closed" ] \
  || fail "hook inherited an open fd 9: $(cat "$T/fd")"
case $out in *"4 hook"*) ;;
  *) fail "did not report the hook count: $out" ;; esac
pass "fires changed only, machine-first, with fd 9 closed"

# --- 3: fail-soft per hook, but non-zero overall ----------------------------
: > "$T/order"
cat > "$T/user/changed.d/20-boom" <<'EOF'
#!/bin/sh
exit 7
EOF
chmod +x "$T/user/changed.d/20-boom"
if err=$(run_apply 2>&1); then
  fail "a failing hook must make apply non-zero; it exited 0: $err"
fi
case $err in *20-boom*) ;;
  *) fail "the failing hook was not named: $err" ;; esac
order=$(tr '\n' ' ' < "$T/order" | sed 's/ $//')
[ "$order" = "m10 u10 u90" ] \
  || fail "a failing hook stopped the others: got '$order'"
pass "a failing hook is named and counted, and never stops the rest"

# --- 4: nothing wired is a no-op that says so ------------------------------
mkdir -p "$T/empty"
out=$(HWDP_HOOK_ROOT="$T/empty" HWDP_MACHINE_HOOKS="$T/empty" "$MGR" apply) \
  || fail "apply must succeed with no hooks wired"
case $out in *"nothing to do"*) ;;
  *) fail "no-hooks case must say so, got: '$out'" ;; esac
out=$(HWDP_HOOK_ROOT="$T/empty" HWDP_MACHINE_HOOKS="$T/empty" "$MGR" apply -q)
[ -z "$out" ] || fail "-q must be silent, got: '$out'"
pass "no hooks wired is a stated no-op, and -q is silent"

# --- a non-executable hook is skipped, not run and not counted -------------
: > "$T/order"
rm -f "$T/user/changed.d/20-boom"
cat > "$T/user/changed.d/40-noexec" <<EOF
#!/bin/sh
echo NOEXEC-RAN >> "$T/order"
EOF
chmod 644 "$T/user/changed.d/40-noexec"
out=$(run_apply 2>&1) || fail "apply failed: $out"
grep -q NOEXEC-RAN "$T/order" && fail "ran a non-executable hook"
case $out in *"4 hook"*) ;;
  *) fail "non-executable hook must not be counted, got: $out" ;; esac
pass "a non-executable hook is skipped and not counted"
