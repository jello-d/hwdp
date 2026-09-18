# hooks.sh -- the display-change HOOK layer, shared by the tools that fire it.
#
# hwdp ships MECHANISM and no policy: it defines the EDGES and runs whatever the
# integrator drops into them, and it ships no hook itself (the vigilance model).
# Sourced, never executed. Two consumers today:
#
#   cmd/watch   fires `pre` and `changed` as the display layout comes up and
#               changes -- the normal path, driven by real display events;
#   cmd/apply   fires `changed` on demand, for a change that produced no
#               display event at all (see that file for why one is needed).
#
# ONE implementation, because two would drift: the reason this is a file rather
# than a copy in each tool is that the fd-9 rule below is invisible at the call
# site and a second copy would sooner or later be written without it.
#
# The edges:
#   pre       fired once, backgrounded, BEFORE kanshi starts (so "on created"
#             window rules can land before autostart apps map their first
#             window)
#   changed   fired after kanshi is up AND after every config-change burst
#
# Hooks live in <root>/<edge>.d/* (executable), machine root first then user,
# each sorted by name, fail-soft. Hooks are expected IDEMPOTENT: the startup
# pass, a config-change burst and an on-demand `hwdp apply` are the same call,
# so a hook that cannot be run twice is a broken hook.
HWDP_HOOK_ROOT=${HWDP_HOOK_ROOT:-${XDG_CONFIG_HOME:-$HOME/.config}/hwdp/hooks}
HWDP_MACHINE_HOOKS=${HWDP_MACHINE_HOOKS:-/etc/hwdp/hooks}

# Hooks run with fd 9 CLOSED, and that is load-bearing rather than tidiness.
#
# fd 9 holds the supervisor's flock, and a file descriptor survives exec -- so
# every hook, and everything a hook spawns, inherits it. A hook that starts a
# LONG-LIVED process therefore hands that process a share of the lock, and the
# lock then outlives the supervisor: when the supervisor dies, waybar (started
# via the bars hook) still holds fd 9, `flock -n` keeps failing, and every
# subsequent `hwdp watch` silently takes the NUDGE path. Display management can
# never restart, and it reports success while doing nothing.
#
# Seen exactly that way: a box with no supervisor, no kanshi, and `fuser` on the
# lockfile naming two waybar processes. The bug was always latent -- it needed a
# hook that outlives its own invocation, and the bars hook is the first.
#
# Closing an fd that was never opened is a no-op (verified under dash and sh),
# so this is correct for `hwdp apply` too, which holds no lock.
#
# HWDP_HOOK_TAG names the caller in a failure message, so "which tool ran this
# hook" survives into the log. It is cosmetic; the fd rule is not.
#
# FAIL-SOFT, BUT COUNTED. A failing hook never stops the others -- one broken
# integration must not take down the rest of the display reaction -- so the
# function's own status cannot carry that news. It sets HWDP_HOOK_FAILURES
# instead, and a caller that needs to report overall success reads it. The loop
# deliberately runs in THIS shell (no pipe, no subshell) or the count would be
# lost on return, which is the classic way a counter like this silently reads 0.
run_hooks() {   # <edge>; sets HWDP_HOOK_FAILURES
  _edge=$1
  HWDP_HOOK_FAILURES=0
  for _root in "$HWDP_MACHINE_HOOKS" "$HWDP_HOOK_ROOT"; do
    [ -d "$_root/$_edge.d" ] || continue
    for _h in "$_root/$_edge.d"/*; do
      [ -f "$_h" ] && [ -x "$_h" ] || continue
      "$_h" 9>&- || {
        HWDP_HOOK_FAILURES=$((HWDP_HOOK_FAILURES + 1))
        echo "${HWDP_HOOK_TAG:-hwdp}: hook $_edge.d/$(basename "$_h")" \
             "failed" >&2
      }
    done
  done
  return 0
}

# Count the executable hooks on an edge, so a caller can report "ran N" and, in
# particular, distinguish "ran nothing because nothing is wired" from "ran".
# A wired-but-empty edge is a legitimate state (the package ships no hooks), so
# this is information, never an error.
count_hooks() {   # <edge>
  _edge=$1; _n=0
  for _root in "$HWDP_MACHINE_HOOKS" "$HWDP_HOOK_ROOT"; do
    [ -d "$_root/$_edge.d" ] || continue
    for _h in "$_root/$_edge.d"/*; do
      [ -f "$_h" ] && [ -x "$_h" ] && _n=$((_n + 1))
    done
  done
  echo "$_n"
}
