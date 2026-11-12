#!/bin/sh
# arrange-tui.t - the interactive layout tool, driven key by key without a
# screen: its model (rotate, swap, move), and what every key and dialog does.
#
# The curses view only draws, so everything a person decides goes through
# App.key() and App.tick(), and every call out to hwdp goes through one
# object. This drives the first with key codes and replaces the second with
# a recorder, EXCEPT the re-pack, which stays the real shell layout_repack:
# the arithmetic under test is hwdp's own, not a stand-in for it.
. "$(dirname "$0")/harness_lib"
harness_init arrange-tui
command -v python3 >/dev/null 2>&1 || skip "python3 not installed"

_out=$(python3 -I - "$HERE" 2>&1 <<'PY'
import curses, importlib.machinery, importlib.util, sys
here = sys.argv[1]
loader = importlib.machinery.SourceFileLoader(
    "tui", here + "/libexec/arrange-tui")
spec = importlib.util.spec_from_loader("tui", loader)
tui = importlib.util.module_from_spec(spec)
loader.exec_module(tui)
real = tui.Hwdp()
real.lib = here + "/lib"

fails = []
def check(label, cond, detail=""):
    if not cond:
        fails.append("%s %s" % (label, detail))

class FakeHw:
    def __init__(self):
        self.calls, self.rc, self.ident = [], {}, False
    def last(self):
        """The newest call, or an empty one: a broken tool must FAIL a
        check, not crash the script before it can report anything."""
        return self.calls[-1] if self.calls else (None, None)
    def repack(self, old, new):
        return real.repack(old, new)
    def arrange(self, mode, placements, progress=None):
        self.calls.append((mode, list(placements)))
        return self.rc.get(mode, 0), "said no" if self.rc.get(mode) else ""
    def identify(self, on):
        self.ident = on
        self.calls.append(("identify", on))
        return on
    surf = ([], "")
    def surfaces(self, desk):
        return self.surf
    def write_surfaces(self, surfaces):
        self.calls.append(("write", [x.key() for x in surfaces]))
        return self.rc.get("write", 0), "said no" if self.rc.get("write") \
            else ""

def desk():
    """A 4K portrait (DP-1, rotated) with a 4K landscape right of it."""
    hw = FakeHw()
    outs = [tui.Output("DP-1", "90", 0, 0, 2160, 3840),
            tui.Output("DP-2", "normal", 2160, 0, 3840, 2160)]
    d = tui.Desk(outs, hw.repack)
    return d, outs, hw

# --- the model ----------------------------------------------------------------
d, (p, l), hw = desk()
d.rotate(p)        # 90 -> 180: landscape now, and DP-2 follows its edge
check("rotate makes the portrait landscape", (p.w, p.h) == (3840, 2160),
      (p.w, p.h))
check("rotate re-packs the neighbour onto the new edge",
      (l.x, l.y) == (3840, 0), (l.x, l.y))
check("a rotated desk is sound", not d.faults())

d, (p, l), hw = desk()
d.swap(p, l)
check("swap trades places at their own sizes",
      (l.x, l.y, p.x, p.y) == (0, 0, 3840, 0), (l.x, l.y, p.x, p.y))

d, (p, l), hw = desk()
tui.step(d, l, 0, 270)
check("a coarse step slides along the edge", (l.x, l.y) == (2160, 270),
      (l.x, l.y))
tui.step(d, l, 0, 1)
check("a fine step is one pixel", l.y == 271, l.y)
for _ in range(40):
    tui.step(d, l, 0, 270)
check("sliding off the end snaps back to touching",
      not d.faults() and tui.touches(l.rect(), p.rect()), l.rect())

d, (p, l), hw = desk()
tui.step(d, l, -480, 0)
check("moving INTO a neighbour jumps to its far side",
      (l.x, p.x) == (0, 3840) and not d.faults(), (l.x, p.x))
check("placements say where everything is",
      d.placements() == ["DP-1 rotate 90 at 3840,0",
                         "DP-2 rotate 0 at 0,0"], d.placements())

def trio(*rects):
    hw = FakeHw()
    outs = [tui.Output("O%d" % i, "normal", *r) for i, r in enumerate(rects)]
    return tui.Desk(outs, hw.repack), outs

# A gap smaller than a step closes FLUSH; only a step from flush gets past.
d, (a_, b_, m_) = trio((0, 0, 1000, 1000), (1010, 0, 1000, 1000),
                       (0, 1000, 2010, 500))
tui.step(d, b_, -tui.STEP, 0)
check("a step into a near neighbour stops flush, not past it",
      b_.x == 1000 and not d.faults(), b_.rect())
tui.step(d, b_, -tui.STEP, 0)
check("only a step taken from flush jumps to the far side",
      b_.x + b_.w == a_.x and not d.faults(), (a_.rect(), b_.rect()))

# The desk that opened a 121px dead strip: the laptop slid under the big
# monitor stops where it is right-aligned with it, on the way past.
d, (big, lap, side) = trio((0, 0, 3840, 2160), (1081, 2160, 2880, 1800),
                           (3961, 320, 1440, 2560))
check("a near miss between facing edges is reported",
      tui.near_misses(d, tui.NEAR) == [("O0", "O2", 121)],
      tui.near_misses(d, tui.NEAR))
seen = []
for _ in range(5):
    tui.step(d, lap, -tui.STEP, 0)
    seen.append(lap.x)
check("a coarse step stops at an alignment it would pass",
      seen == [1056, 1031, 1006, 981, 960], seen)
tui.step(d, side, -tui.STEP, 0)
check("an output left touching nothing comes back flush in one step",
      side.x == 3840 and not d.faults() and not tui.near_misses(d, tui.NEAR),
      side.rect())

# Sliding along an edge stops at centred and end-aligned, then turns the
# corner onto the next side, aligned with the corner it passed.
d, (p, l), hw = desk()
seen = set()
for _ in range(200):
    tui.step(d, l, 0, tui.STEP)
    seen.add(l.y - p.y)
    if l.y >= p.y + p.h:
        break
check("sliding passes through centred and end-aligned",
      {840, 1680} <= seen, sorted(seen)[:12])
check("sliding says what it lines up with",
      tui.contacts(l, [p]) == "below DP-1: rights aligned",
      tui.contacts(l, [p]))

# The view: flush outputs are drawn flush (a rounded start plus a rounded
# width once drew a one-cell gap), and a label wraps before it spills.
sc = 78 / 5280
boxes = [tui.cells(tui.Output(*o), 0, 0, sc, 2) for o in
         (("DP-7", "normal", 0, 0, 3840, 2160),
          ("DP-9", "270", 3840, 225, 1440, 2560),
          ("eDP-1", "normal", 960, 2160, 2880, 1800))]
check("flush outputs are drawn flush",
      boxes[0][0] + boxes[0][2] == boxes[1][0] ==
      boxes[2][0] + boxes[2][2], boxes)
check("a label wraps at a space, and a long word keeps its own line",
      tui.wrap((["at", "3840,225"], ["DP-9", "EP"]), 6)
      == ["at", "3840,225", "DP-9", "EP"],
      tui.wrap((["at", "3840,225"], ["DP-9", "EP"]), 6))

check("past the end it turns the corner, aligned with it",
      l.y == p.y + p.h and l.x + l.w == p.x + p.w and not d.faults(),
      (p.rect(), l.rect()))

# --- the controller -----------------------------------------------------------
def sync(work, finish):
    """The save, on the caller's thread: the controller under test."""
    return {"finish": finish, "res": work()}

def app():
    d, outs, hw = desk()
    a = tui.App(d, hw)
    a.spawn = sync
    return a, outs, hw

a, (p, l), hw = app()
a.key(9, 0)
check("Tab selects the next monitor", a.cur is l)
a.key(curses.KEY_LEFT, 0)
check("an arrow selects the monitor that way", a.cur is p)

a, (p, l), hw = app()
a.key(ord("m"), 0); a.key(curses.KEY_DOWN, 0)
check("move mode: an arrow moves the selection a coarse step",
      (p.x, p.y, l.x, l.y) == (0, tui.STEP, 2160, 0), (p.rect(), l.rect()))
a.key(curses.KEY_SF, 0)
check("move mode: shift+arrow moves one pixel", p.y == tui.STEP + 1, p.y)
a.key(27, 0)
check("Esc in move mode undoes the move", (p.x, p.y) == (0, 0)
      and a.moving is None, (p.x, p.y))
a.key(ord("m"), 0); a.key(curses.KEY_DOWN, 0); a.key(10, 0)
check("Enter in move mode locks the move", a.moving is None
      and p.y == tui.STEP and a.dialog is None, (p.y, a.dialog))
a.key(10, 0)
check("Enter with nothing in progress does nothing",
      a.dialog is None and not a.done and not hw.calls, (a.dialog, hw.calls))

a, (p, l), hw = app()
a.key(ord("q"), 0)
check("q with nothing changed just quits", a.done and a.dialog is None)

a, (p, l), hw = app()
a.key(ord("r"), 0)
a.key(ord("q"), 0)
check("q with changes asks first, save as Enter's answer",
      not a.done and a.dialog == ("quit", ord("s")), a.dialog)
a.key(27, 0)
check("Esc in that dialog keeps editing", a.dialog is None and not a.done)
a.key(ord("s"), 0)
check("s saves through arrange and stays",
      hw.last()[0] is None and not a.done and not a.dirty()
      and a.dialog is None, hw.calls)
a.key(ord("s"), 0)
check("s with nothing changed saves nothing",
      len(hw.calls) == 1 and a.msg == "nothing to save", (hw.calls, a.msg))
a.key(ord("r"), 0); a.key(ord("q"), 0); a.key(10, 0)
check("q then Enter saves and quits", a.done and not a.dirty()
      and len(hw.calls) == 2, hw.calls)

a, (p, l), hw = app()
a.key(ord("r"), 0); a.key(ord("q"), 0); a.key(ord("d"), 0)
check("d in the exit prompt quits without saving",
      a.done and not hw.calls, hw.calls)

a, (p, l), hw = app()
a.key(ord("r"), 0); a.key(27, 0)
check("Esc at the top asks too, with keep editing as Enter's answer",
      a.dialog == ("quit", 27), a.dialog)
a.key(10, 0)
check("so Esc, Enter writes and discards nothing",
      a.dialog is None and not a.done and a.dirty() and not hw.calls,
      hw.calls)
a.key(27, 0); a.key(ord("s"), 0)
check("s in the exit prompt saves and quits", a.done and not a.dirty())

a, (p, l), hw = app()
hw.rc[None] = 2
a.key(ord("r"), 0); a.key(ord("s"), 0)
check("a refused save stays, and says why", not a.done and a.dirty()
      and a.msg == "said no", a.msg)

# A slow save (an integrator's hook) runs BESIDE the screen, which says what
# it is waiting on and takes no key until it lands.
import threading
gate = threading.Event()
class SlowHw(FakeHw):
    def arrange(self, mode, placements, progress=None):
        progress("hwdp arrange: running the mapped hooks")
        gate.wait(5)
        return super().arrange(mode, placements)
d, outs, hw = desk()
hw.__class__ = SlowHw
a = tui.App(d, hw)
a.key(ord("r"), 0); a.key(ord("q"), 0); a.key(ord("s"), 0)
busy = list(a.busy or [])
a.key(ord("q"), 0)
check("a slow save shows what it waits on, and is not done yet",
      not a.done and busy[2].endswith("mapped hooks") and a.dialog is None,
      busy)
gate.set()
a.job["thread"].join(5)
a.tick(0)
check("once it lands, the save finishes and exits",
      a.done and not a.dirty() and a.busy is None, (a.msg, a.busy))

a, (p, l), hw = app()
a.key(ord("r"), 0); a.key(ord("p"), 100.0)
check("p previews through arrange --preview",
      hw.last()[0] == "--preview" and a.dialog[0] == "keep", hw.calls)
a.tick(100.0 + tui.PREVIEW_SECONDS - 1)
check("the countdown has not run out yet", a.dialog is not None)
a.tick(100.0 + tui.PREVIEW_SECONDS)
check("no answer reverts", hw.last()[0] == "--revert"
      and a.dialog is None, hw.calls)

a, (p, l), hw = app()
a.key(ord("r"), 0); a.key(ord("p"), 0); a.key(ord("y"), 1)
check("keeping a preview leaves it live, unsaved", a.live_unsaved
      and a.dialog is None)
a.key(ord("q"), 2); a.key(ord("d"), 2)
check("discarding with a kept preview reverts it first",
      a.done and hw.last()[0] == "--revert", hw.calls)

a, (p, l), hw = app()
hw.rc["--preview"] = 5
a.key(ord("p"), 0)
check("a preview with no supervisor says so", a.dialog is None
      and a.msg == "said no", a.msg)

a, (p, l), hw = app()
a.key(ord("i"), 0)
check("i turns the labels on", a.ident and hw.last() == ("identify", True))
a.key(ord("i"), 0)
check("i again turns them off", not a.ident
      and hw.last() == ("identify", False))

a, (p, l), hw = app()
a.key(ord("o"), 0)
check("o switches one off", not p.on and l.on)
check("its placement says off", "DP-1 off" in a.desk.placements())
a.key(9, 0); a.key(ord("o"), 0)
check("the last one on cannot be switched off", l.on, a.msg)

a, (p, l), hw = app()
a.key(ord("w"), 0); a.key(9, 0); a.key(ord("w"), 0)
check("w, select, w swaps", (l.x, p.x) == (0, 3840) and a.mark is None,
      (l.x, p.x))
a, (p, l), hw = app()
a.key(ord("w"), 0); a.key(10, 0)
check("Enter on the marked monitor itself does nothing",
      a.mark is p and p.x == 0, (a.mark, p.x))
a.key(9, 0); a.key(10, 0)
check("w, select, Enter swaps", (l.x, p.x) == (0, 3840)
      and a.mark is None, (l.x, p.x))
a, (p, l), hw = app()
a.key(ord("w"), 0); a.key(27, 0)
check("Esc drops the mark and asks nothing", a.mark is None
      and a.dialog is None, a.dialog)

# --- naming surfaces ---------------------------------------------------------
def typed(a, text):
    for ch in text:
        a.key(ord(ch), 0)

a, (p, l), hw = app()
a.key(ord("n"), 0)
check("n opens the naming form", a.dialog[0] == "name")
a.key(curses.KEY_RIGHT, 0); a.key(curses.KEY_RIGHT, 0)   # full>top>bottom
a.key(9, 0); a.key(curses.KEY_RIGHT, 0)                   # column 1
a.key(9, 0); a.key(9, 0)                                  # to the name
typed(a, "comms"); a.key(10, 0)
check("the form adds a surface", [x.key() for x in a.surfaces]
      == [("comms", "DP-1", "bottom", 1, 0)], [x.key() for x in a.surfaces])
check("a new surface makes the desk unsaved", a.dirty())
a.key(ord("n"), 0)
a.key(9, 0); a.key(curses.KEY_RIGHT, 0); a.key(9, 0); a.key(9, 0)
typed(a, "comms"); a.key(10, 0)
check("a name used twice is refused in the form",
      a.dialog and "taken" in a.form["err"], a.form)
a.key(curses.KEY_BACKSPACE, 0); typed(a, "x"); a.key(10, 0)
check("all of a monitor over its bottom half is refused",
      a.dialog and "taken" in a.form["err"], a.form)
a.key(27, 0)
a.key(ord("n"), 0); a.key(curses.KEY_RIGHT, 0)            # top
a.key(9, 0); a.key(curses.KEY_RIGHT, 0); a.key(9, 0); a.key(9, 0)
typed(a, "mail"); a.key(10, 0)
check("the opposite half in the same cell is fine", len(a.surfaces) == 2,
      a.form)
a.key(ord("d"), 0); a.key(ord("1"), 0)
check("d then a number removes that surface",
      [x.name for x in a.surfaces] == ["mail"], [x.name for x in a.surfaces])
a.key(ord("s"), 0)
check("saving writes the surfaces, and not an unchanged layout",
      not a.dirty() and hw.last()[0] == "write"
      and not any(c[0] is None for c in hw.calls), hw.calls)

a, (p, l), hw = app()
hw.rc["write"] = 2
a.key(ord("n"), 0); a.key(9, 0); a.key(9, 0); a.key(9, 0)
typed(a, "x"); a.key(10, 0); a.key(ord("s"), 0)
check("a refused surfaces write stays and says so", not a.done
      and a.msg.startswith("surfaces not saved"), a.msg)

d, outs, hw = desk()
hw.surf = (None, "a broken line")
a = tui.App(d, hw)
a.key(ord("n"), 0)
check("a file hwdp refuses is not edited on top of",
      a.dialog is None and "cannot be edited" in a.msg, a.msg)

# The region comes back from `hwdp surfaces`' rect, against the output size.
r = tui.Hwdp()
r._run = lambda *a, **k: (0, "t DP-1 0 0 0 0 2160 1920\n"
                              "b DP-1 1 0 0 1920 2160 1920\n"
                              "f DP-2 0 0 0 0 3840 2160\n"
                              "rt DP-2 2 0 1920 0 1920 2160\n", "")
got, _ = r.surfaces(desk()[0])
check("regions are read back from the rects",
      [(x.name, x.region, x.cx) for x in got] ==
      [("t", "top", 0), ("b", "bottom", 1), ("f", "full", 0),
       ("rt", "right", 2)], [(x.name, x.region) for x in got])

print("\n".join(fails) if fails else "ALL-OK")
PY
)
[ "$_out" = ALL-OK ] || fail "$_out"
pass "model and controller: rotate, swap, move, dialogs, preview, identify"

# --- it refuses to run without a terminal -------------------------------------
if _o=$(python3 "$HERE/libexec/arrange-tui" </dev/null 2>&1); then
  fail "the tool ran with no terminal"
fi
case $_o in
  *"needs a terminal"*) ;;
  *) fail "no terminal: $_o" ;;
esac
pass "without a terminal it says so"
