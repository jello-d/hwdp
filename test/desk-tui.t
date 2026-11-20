#!/bin/sh
# desk-tui.t - the interactive layout tool, driven key by key without a
# screen: its model (rotate, swap, move), and what every key and dialog does.
#
# The curses view only draws, so everything a person decides goes through
# App.key() and App.tick(), and every call out to hwdp goes through one
# object. This drives the first with key codes and replaces the second with
# a recorder, EXCEPT the re-pack, which stays the real shell layout_repack:
# the arithmetic under test is hwdp's own, not a stand-in for it.
. "$(dirname "$0")/harness_lib"
harness_init desk-tui
command -v python3 >/dev/null 2>&1 || skip "python3 not installed"

mkdir -p "$T/stub/cmd" "$T/stub2/cmd" "$T/walls/sub"
: > "$T/walls/b.JPG"; : > "$T/walls/a.png"; : > "$T/walls/.hidden.jpg"
: > "$T/walls/notes.txt"
printf '%s\n' '#!/bin/sh' 'printf "0 0 a.png\n2 1 night sky.png\n"' \
  > "$T/stub2/cmd/surfaces"
chmod +x "$T/stub2/cmd/surfaces"
printf '%s\n' '#!/bin/sh' 'echo "  hwdp surfaces: the REASON" >&2' \
  'echo "hwdp surfaces: --write: NOT written" >&2' 'exit 2' \
  > "$T/stub/cmd/surfaces"
chmod +x "$T/stub/cmd/surfaces"
_out=$(python3 -I - "$HERE" "$T" 2>&1 <<'PY'
import curses, importlib.machinery, importlib.util, sys
here = sys.argv[1]
loader = importlib.machinery.SourceFileLoader(
    "tui", here + "/libexec/desk-tui")
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
    surf = ([], None, "")
    gridv = None
    namesv = [["comms", "Comms"], ["mail", "Mail"]]
    def surfaces(self, desk):
        return self.surf
    splitv = []
    def splits(self):
        return list(self.splitv)
    def grid(self):
        return self.gridv
    def names(self):
        return [list(n) for n in self.namesv]
    def write_desk(self, grid, surfaces, default, splits=()):
        self.calls.append(("write", grid, [x.key() for x in surfaces],
                           default.key() if default else None))
        self.wsplits = list(splits)
        return self.rc.get("write", 0), "said no" if self.rc.get("write") \
            else ""
    wallsv = {}
    imagesv = ["aurora.jpg", "bubbles.jpg", "night sky.png"]
    def wallpapers(self):
        return dict(self.wallsv)
    defaultsv = {}
    def default_wallpapers(self):
        return dict(self.defaultsv)
    def wallpaper_images(self):
        return list(self.imagesv)
    def write_wallpapers(self, walls):
        self.calls.append(("walls", dict(walls)))
        return self.rc.get("walls", 0), "said no" if self.rc.get("walls") \
            else ""
    unplaced = None
    def write_names(self, names, unplace=False):
        if unplace:
            self.unplaced = [list(x) for x in names]
        self.calls.append(("names", [list(n) for n in names]))
        return self.rc.get("names", 0), "said no" if self.rc.get("names") \
            else ""
    def apply(self):
        self.calls.append(("apply",))
        return self.rc.get("apply", 0), "a hook failed" \
            if self.rc.get("apply") else ""

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
check("Enter with nothing in progress SELECTS the monitor to move",
      a.moving and a.moving[0] is p and a.dialog is None and not hw.calls,
      (a.moving, a.dialog, hw.calls))
a.key(10, 0)
check("and Enter again puts it down", a.moving is None and p.y == tui.STEP,
      (a.moving, p.y))
before = [o.rect() for o in (p, l)]
a.sel = 1
a.key(10, 0)
for _ in range(60):
    a.key(curses.KEY_LEFT, 0)
a.key(27, 0)
check("Esc after a move past the left edge puts back the WHOLE desk",
      [o.rect() for o in (p, l)] == before, [o.rect() for o in (p, l)])

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
check("s saves through arrange, applies it, and stays",
      [c[0] for c in hw.calls] == [None, "apply"] and not a.done
      and not a.dirty()
      and a.dialog is None, hw.calls)
a.key(ord("s"), 0)
check("s with nothing changed saves nothing",
      len(hw.calls) == 2 and a.msg == "nothing to save", (hw.calls, a.msg))
a.key(ord("r"), 0); a.key(ord("q"), 0); a.key(10, 0)
check("q then Enter saves and quits", a.done and not a.dirty()
      and len(hw.calls) == 4, hw.calls)

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
check("a refused save stays, and says why in a dialog",
      not a.done and a.dirty() and a.dialog and a.dialog[0] == "error"
      and a.dialog[1]["text"] == "said no"
      and a.msg == "not saved: said no", (a.dialog, a.msg))
a.key(10, 0)
check("Enter closes the error, the changes still unsaved",
      a.dialog is None and a.dirty(), a.dialog)

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
check("a preview with no supervisor says so, in a dialog",
      a.dialog and a.dialog[0] == "error"
      and a.dialog[1]["title"] == "Not previewed"
      and a.msg == "not previewed: said no", (a.dialog, a.msg))
a.key(27, 0)
check("Esc closes it", a.dialog is None, a.dialog)

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

# --- tab 2, Surfaces: the names, edited here and nowhere else ----------------
def typed(a, text):
    for ch in text:
        a.key(ord(ch), 0)

a, (p, l), hw = app()
a.key(ord("a"), 0)
check("outside tab 2 the name keys do nothing", a.dialog is None
      and len(a.names) == 2, a.dialog)
a.key(ord("2"), 0)
check("2 is the surfaces tab, on the first name",
      a.tab == 1 and a.side_name() == "comms", (a.tab, a.side_name()))
a.key(curses.KEY_DOWN, 0)
check("down moves through the names", a.side_name() == "mail")
a.key(ord("a"), 0)
check("a opens the name form", a.dialog[0] == "name")
typed(a, "chat"); a.key(9, 0); typed(a, "Chat Room"); a.key(10, 0)
check("the form adds a name with its label",
      a.names[-1] == ["chat", "Chat Room"] and a.side_name() == "chat"
      and a.dirty(), a.names)
a.key(ord("a"), 0); typed(a, "chat"); a.key(10, 0)
check("a name that exists is refused in the form",
      a.dialog and "already" in a.form["err"], a.form)
a.key(27, 0)
a.key(ord("e"), 0)
check("e edits the label only", a.form["field"] == 1
      and a.form["name"] == "chat", a.form)
a.key(curses.KEY_BACKSPACE, 0); typed(a, "ms"); a.key(10, 0)
check("the label is changed", a.names[-1] == ["chat", "Chat Rooms"],
      a.names)

# --- tab 3, Virtual: placing names through the picker -------------------------
a, (p, l), hw = app()
a.key(ord("3"), 0)
check("3 is the virtual tab, a 3x3 for a desk with no grid",
      a.tab == 2 and a.grid == (3, 3), (a.tab, a.grid))
a.key(10, 0)
check("Enter opens the picker over the names", a.dialog[0] == "pick"
      and [n for n, _ in a.pick_list()] == ["comms", "mail"], a.dialog)
a.key(27, 0)
check("Esc closes the picker and places nothing",
      a.dialog is None and a.surfaces == [])
a.key(10, 0); a.key(10, 0)
check("Enter in the picker places the chosen name on the spot",
      [x.key() for x in a.surfaces] == [("comms", "DP-1", "full", 0, 0)],
      [x.key() for x in a.surfaces])
a.key(10, 0)
check("the picker starts on what is there now", a.pick_list()[
      a.pick["sel"]][0] == "comms", a.pick)
a.key(27, 0)

# --- splits: g cuts the selected panel in THIS cell; Tab walks the halves -----
K = lambda: sorted(x.key() for x in a.surfaces)
a.key(ord("g"), 0)
check("g cuts the panel top-bottom here, and the whole surface moves to "
      "the top half", a.splits == {("DP-1", 0, 0): "top-bottom"}
      and K() == [("comms", "DP-1", "top", 0, 0)]
      and "top-bottom" in a.msg, (a.splits, K(), a.msg))
check("the cut is this cell's alone", a.split_at(p, 1, 0) is None)
check("Tab stops: each half of the cut panel, then the next panel whole",
      [(o.conn, rg) for o, rg in a.vstops()] ==
      [("DP-1", "top"), ("DP-1", "bottom"), ("DP-2", "full")],
      a.vstops())
a.key(9, 0)
check("Tab goes to the bottom half", a.vspot() == (p, "bottom"))
a.key(10, 0); a.key(curses.KEY_DOWN, 0); a.key(10, 0)
check("each half holds its own surface", K() == [
      ("comms", "DP-1", "top", 0, 0), ("mail", "DP-1", "bottom", 0, 0)], K())
a.key(9, 0)
check("Tab goes on to the next panel", a.vspot() == (l, "full"))
a.key(9, 0)
check("and wraps round to the first half", a.vspot() == (p, "top"))
a.key(curses.KEY_BTAB, 0)
check("Shift-Tab walks back", a.vspot() == (l, "full"))
a.key(curses.KEY_BTAB, 0)
check("back into the last half", a.vspot() == (p, "bottom"))
a.key(ord("g"), 0)
check("g again is left-right: top goes left, bottom right",
      a.splits == {("DP-1", 0, 0): "left-right"} and K() == [
      ("comms", "DP-1", "left", 0, 0), ("mail", "DP-1", "right", 0, 0)],
      (a.splits, K()))
a.key(ord("g"), 0)
check("joining two placed halves asks first, changing nothing yet",
      a.dialog and a.dialog[0] == "unsplit" and len(a.surfaces) == 2
      and a.splits == {("DP-1", 0, 0): "left-right"}, a.dialog)
a.key(10, 0)
check("Enter keeps the split", a.dialog is None and len(a.surfaces) == 2
      and a.splits == {("DP-1", 0, 0): "left-right"})
a.key(ord("g"), 0); a.key(ord("y"), 0)
check("y joins it and unplaces both, saying which",
      a.splits == {} and a.surfaces == [] and "unplaced comms, mail"
      in a.msg, (a.splits, K(), a.msg))
a.key(ord("g"), 0)
check("a split with nothing in it is kept, and is a change to save",
      a.splits == {("DP-1", 0, 0): "top-bottom"} and a.surfaces == []
      and a.desk_dirty(), a.splits)
a.key(9, 0); a.key(10, 0); a.key(10, 0)          # comms on the bottom
a.key(ord("g"), 0); a.key(ord("g"), 0)           # left-right, then whole
check("joining with ONE half placed moves it to the whole panel, unasked",
      a.dialog is None and a.splits == {}
      and K() == [("comms", "DP-1", "full", 0, 0)], (a.dialog, K()))
a.key(curses.KEY_RIGHT, 0); a.key(10, 0); typed(a, "comm")
check("typing filters the picker", [n for n, _ in a.pick_list()]
      == ["comms"], a.pick_list())
a.key(10, 0)
check("a name is in one place per desk: placing it again MOVES it",
      K() == [("comms", "DP-1", "full", 1, 0)], K())
a.key(10, 0); typed(a, "mail"); a.key(10, 0)
check("a name placed over another replaces it, and says so",
      K() == [("mail", "DP-1", "full", 1, 0)] and "replaced comms" in a.msg,
      (K(), a.msg))
a.key(ord("x"), 0)
check("x clears the spot", a.surfaces == [])
a.key(9, 0); a.key(ord("f"), 0)
check("f opens the picker for the default", a.pick["mode"] == "default")
a.key(10, 0)
check("the picked name becomes the default on that panel and region",
      a.default and a.default.key() == ("comms", "DP-2", "full", None,
                                        None), a.default and a.default.key())
a.key(10, 0); a.key(10, 0)
check("placing the default's name makes it a surface, not both",
      a.default is None and a.surfaces[0].name == "comms")
a.key(ord("+"), 0)
check("+ adds a column", a.grid == (4, 3), a.grid)
a.key(curses.KEY_RIGHT, 0); a.key(curses.KEY_RIGHT, 0)       # the new column
a.key(10, 0); a.key(10, 0); a.key(ord("-"), 0)
check("shrinking refuses while the column holds a surface",
      a.grid == (4, 3) and "fall off" in a.msg, (a.grid, a.msg))

# --- saving: names around the desk, in two steps ------------------------------
a, (p, l), hw = app()
a.key(ord("3"), 0); a.key(10, 0); a.key(10, 0)              # comms placed
a.key(ord("2"), 0); a.key(curses.KEY_DOWN, 0)
a.key(ord("D"), 0); a.key(ord("y"), 0)                      # mail deleted
a.key(ord("a"), 0); typed(a, "chat"); a.key(10, 0)          # chat added
a.key(ord("s"), 0)
kinds = [c[0] for c in hw.calls]
check("names, then the desk, then the names again without the deleted one",
      kinds == ["names", "write", "names", "apply"]
      and ["mail", "Mail"] in hw.calls[0][1]
      and ["mail", "Mail"] not in hw.calls[2][1]
      and ["chat", "chat"] in hw.calls[2][1] and not a.dirty(), hw.calls)
check("the names step that drops a deleted name takes it off other desks",
      hw.unplaced is not None and ["mail", "Mail"] not in hw.unplaced,
      hw.unplaced)
check("the desk save carries the grid and the surfaces",
      hw.calls[1][1:] == ((3, 3), [("comms", "DP-1", "full", 0, 0)], None),
      hw.calls[1])

a, (p, l), hw = app()
a.key(ord("3"), 0); a.key(ord("g"), 0); a.key(ord("s"), 0)
check("a split is saved even with nothing in it",
      hw.wsplits == [("DP-1", 0, 0, "top-bottom")] and not a.dirty(),
      getattr(hw, "wsplits", None))

# Loading: written splits come in; a half with no split line implies one.
d, outs, hw = desk()
hw.splitv = [("DP-2", 1, 1, "left-right")]
hw.surf = ([tui.Surface("comms", "DP-1", "bottom", 0, 0)], None, "")
a = tui.App(d, hw)
check("splits load, written and implied",
      a.splits == {("DP-2", 1, 1): "left-right",
                   ("DP-1", 0, 0): "top-bottom"} and not a.dirty(),
      a.splits)

a, (p, l), hw = app()
hw.rc["write"] = 2
a.key(ord("3"), 0); a.key(10, 0); a.key(10, 0); a.key(ord("s"), 0)
check("a refused desk write applies nothing",
      ("apply",) not in hw.calls, hw.calls)
check("a refused desk write stays and says so, in a dialog",
      not a.done and a.dirty() and a.dialog and a.dialog[0] == "error"
      and a.dialog[1]["text"] == "saving the desk: said no", a.dialog)

# The dialog's text: what hwdp said, all of it, the REASON included (the
# status line once showed only "...the result would be bro", 2026-11-18).
said = "\n".join(
    ["  hwdp surfaces: line %d of the new BL.conf: surface `s%d` is "
     "defined twice" % (20 + i, i) for i in range(30)]
    + ["hwdp surfaces: --write: no switched-on output named `eDP-1`"] * 3
    + ["hwdp surfaces: --write: NOT written, the result would be broken"])
d_ = {"title": "Not saved", "text": said, "top": 0}
lines = tui.error_lines(d_, 72, 20)
check("the error dialog leads with its title", lines[0] == "Not saved",
      lines[:2])
check("the reasons are there, without the `hwdp surfaces:` prefix",
      lines[2].startswith("line 20 of the new BL.conf: surface `s0`")
      and not any("hwdp surfaces:" in x for x in lines), lines[2:4])
check("every line fits the width it is given",
      all(len(x) <= 72 for x in lines), max(map(len, lines)))
check("a taller text scrolls, and says where it is",
      len(lines) <= 20 and "arrows scroll" in lines[-1], lines[-1])
d_["top"] = 999
end = tui.error_lines(d_, 72, 20)
check("scrolled to the end: the summary is the last line shown",
      "NOT written, the result would be broken" in end[-3]
      and "no switched-on output named `eDP-1` (x3)" in end[-4], end[-5:])
check("scrolling stops at the end", d_["top"] < 999, d_["top"])
short = tui.error_lines({"title": "Not saved", "text": "said no",
                         "top": 0}, 72, 20)
check("a short error is shown whole, with no scroll line",
      short == ["Not saved", "", "said no", "", "Enter or Esc closes"],
      short)

# A save at the desk is APPLIED, so the grid and names reach the session
# (a 4x3 save stayed 3x3 on screen, 2026-11-18); a failed apply is said as
# exactly that, the save standing.
a, (p, l), hw = app()
a.key(ord("3"), 0); a.key(10, 0); a.key(10, 0); a.key(ord("s"), 0)
check("a save at the desk is applied, last",
      hw.calls[-1] == ("apply",) and not a.dirty() and a.msg == "saved",
      (hw.calls, a.msg))
a, (p, l), hw = app()
hw.rc["apply"] = 1
a.key(ord("3"), 0); a.key(10, 0); a.key(10, 0); a.key(ord("s"), 0)
check("a failed apply: saved, and says it was not applied",
      not a.dirty() and a.dialog and a.dialog[0] == "error"
      and a.dialog[1]["title"] == "Saved, but not applied"
      and "a hook failed" in a.dialog[1]["text"], (a.dialog, a.msg))
off = tui.OfflineHwdp.__new__(tui.OfflineHwdp)
check("a desk away from its panels is never applied",
      off.apply() == (0, ""), off.apply())

d, outs, hw = desk()
hw.surf = (None, None, "a broken line")
a = tui.App(d, hw)
a.key(ord("2"), 0); a.key(ord("a"), 0)
check("files hwdp refuses are not edited on top of",
      a.dialog is None and "cannot be edited" in a.msg, a.msg)

# The region and the default come back from `hwdp surfaces --map`.
r = tui.Hwdp()
r._run = lambda *a, **k: (0,
    "t DP-1 0 0 0 0 2160 1920 p1 0 0 1 0.5\n"
    "b DP-1 1 0 0 1920 2160 1920 p1 0 0.5 1 0.5\n"
    "rt DP-2 2 0 1920 0 1920 2160 p2 0.5 0 0.5 1\n"
    "else DP-2 * * 0 0 3840 2160 p2 0 0 1 1\n", "")
got, dflt, _ = r.surfaces(desk()[0])
check("regions are read back from the fractions",
      [(x.name, x.region, x.cx) for x in got] ==
      [("t", "top", 0), ("b", "bottom", 1), ("rt", "right", 2)]
      and dflt.key() == ("else", "DP-2", "full", None, None),
      ([(x.name, x.region) for x in got], dflt and dflt.key()))

# Splits come back from `hwdp surfaces --splits`, connector first.
r = tui.Hwdp()
r._run = lambda *a, **k: (0, "DP-1 0 1 top-bottom\nDP-2 2 0 left-right\n",
                          "")
check("splits are read back per panel and cell", r.splits() ==
      [("DP-1", 0, 1, "top-bottom"), ("DP-2", 2, 0, "left-right")],
      r.splits())

# The review: gaps are named with no default, and gone with one.
a, (p, l), hw = app()
a.key(ord("3"), 0); a.key(10, 0); a.key(10, 0)
rv = tui.review_lines(a)
check("the review names the gaps when there is no default",
      any("gap(s) and no default" in x for x in rv)
      and any("not placed here: mail" in x for x in rv), rv[:4])
a.key(9, 0); a.key(ord("f"), 0); typed(a, "mail"); a.key(10, 0)
rv = tui.review_lines(a)
check("with a default the review has no gaps",
      not any("gap(s)" in x for x in rv), rv[:4])
a.key(ord("1"), 0); a.key(ord("r"), 0)
check("1 returns to the physical tab, whose keys still work",
      a.tab == 0 and "rotated" in a.msg, (a.tab, a.msg))

# --- the view: a drawing cuts, the line under it does not ----------------
# A miniature too small for a name shows it cut ("pers" three times on a
# laptop at 80x24); the line under the drawing says the selection in full.
# Drawn by the real render() into a screen that keeps text.
class Scr:
    def __init__(s, w, h):
        s.w, s.h = w, h
        s.g = [[" "] * w for _ in range(h)]
    def getmaxyx(s):
        return s.h, s.w
    def erase(s):
        s.g = [[" "] * s.w for _ in range(s.h)]
    def addstr(s, y, x, t, a=0):
        for i, c in enumerate(t):
            if 0 <= x + i < s.w:
                s.g[y][x + i] = c
    def text(s):
        return "\n".join("".join(r) for r in s.g)
    def __getattr__(s, n):
        return lambda *a, **k: None
curses.color_pair = lambda n: 0
NAMES = [["calendar", "Calendar"], ["personal-main", "Personal Main"],
         ["personal-agents", ""], ["personal-overflow", "Overflow"]]
def shown(outs, surf, grid, tab, w, h, cell=(0, 0)):
    hw = FakeHw()
    hw.namesv, hw.surf, hw.gridv = NAMES, (surf, None, ""), grid
    app = tui.App(tui.Desk(outs, hw.repack), hw)
    app.tab, app.vcell = tab, list(cell)
    scr = Scr(w, h)
    tui.render(scr, app, 0.0)
    return scr.text()
lap = [tui.Output("eDP-1", "normal", 0, 0, 2880, 1800)]
three = [tui.Surface(n, "eDP-1", "full", i, 0)
         for i, n in enumerate(["personal-main", "personal-agents",
                                "personal-overflow"])]
out = shown(lap, three, [3, 3], 2, 80, 24, (2, 0))
draw = "\n".join(r[tui.SIDE_W + 1:] for r in out.split("\n")[2:8])
check("a narrow miniature is drawn, cut to fit", "|pers|" in draw, draw)
check("the line under it names the selection in full, with its label",
      "| personal-overflow (Overflow)  in cell 2,0" in out,
      out)
out = shown(lap, three, [3, 3], 2, 80, 24, (1, 0))
check("a name with no label is not given an empty one",
      "| personal-agents  in cell 1,0" in out, out)
desk3 = [tui.Output("DP-9", "normal", 320, 225, 2560, 1440),
         tui.Output("DP-7", "270", 2880, 0, 2160, 3840),
         tui.Output("eDP-1", "normal", 0, 1665, 2880, 1800)]
out = shown(desk3, [], [2, 2], 0, 60, 18)
# A split shows in the drawing even with nothing in it: the line between
# the halves and a dot in each empty one; two side by side labels keep the
# line between them instead of running into one word. Cropped to the
# drawing, right of the sidebar and above the selection line.
def drawn(splits, surf):
    hw = FakeHw()
    hw.namesv, hw.surf, hw.gridv, hw.splitv = NAMES, (surf, None, ""), \
        [1, 1], splits
    app = tui.App(tui.Desk(lap, hw.repack), hw)
    app.tab = 2
    scr = Scr(120, 40)
    tui.render(scr, app, 0.0)
    rows = scr.text().split("\n")
    end = next(i for i, r in enumerate(rows) if " in cell " in r)
    return [r[tui.SIDE_W + 1:] for r in rows[2:end]]
g = drawn([("eDP-1", 0, 0, "top-bottom")], [])
check("an empty top-bottom split draws its line and a dot in each half",
      any("|" + "-" * 10 in r for r in g)
      and sum(r.count(".") for r in g) == 2, "\n".join(g))
g = drawn([("eDP-1", 0, 0, "left-right")],
          [tui.Surface("personal-main", "eDP-1", "left", 0, 0),
           tui.Surface("personal-agents", "eDP-1", "right", 0, 0)])
lab = [r for r in g if "personal" in r]
check("left and right labels keep the cut between them",
      lab and "|personal-agents" in lab[0].replace(" ", "")
      and sum(r.count(".") for r in g) == 0, "\n".join(g))
rows = shown(lap, three, [3, 3], 2, 80, 24).split("\n")
check("the active tab is marked when there is no colour",
      "[3 Virtual]" in rows[0], rows[0])
check("the sidebar rule leaves a blank row under the menu bar",
      rows[1][tui.SIDE_W] == " " and rows[2][tui.SIDE_W] != " ", rows[:3])
hw = FakeHw()
hw.namesv, hw.surf, hw.gridv = NAMES, (three, None, ""), [3, 3]
app = tui.App(tui.Desk(lap, hw.repack), hw)
app.key(ord("r"), 0)
scr = Scr(80, 24)
tui.render(scr, app, 0.0)
top = scr.text().split("\n")[0]
check("unsaved changes are flagged at the right of the bar",
      top.rstrip().endswith(" unsaved") and len(top.rstrip()) >= 75, top)
check("the physical tab says the selected panel in full",
      "DP-9 EL 2560x1440 at 320,225  rotate 0" in out, out)

# Drawn: the dialog fits an 80x24 screen and carries the reason.
hw = FakeHw()
hw.rc["write"] = 2
hw.namesv, hw.surf, hw.gridv = NAMES, (three, None, ""), [3, 3]
app = tui.App(tui.Desk(lap, hw.repack), hw)
app.fail("Not saved", said)
scr = Scr(80, 24)
tui.render(scr, app, 0.0)
shown = scr.text()
check("the drawn error dialog shows the first reason",
      "line 20 of the new BL.conf" in shown, shown)
check("and fits the screen",
      all(len(r) <= 80 for r in shown.split("\n")), "too wide")

# --- wallpapers: one per workspace, `b` in the virtual tab -------------------
d, outs, hw = desk()                 # (`app` is a drawn App by this point)
a = tui.App(d, hw)
a.spawn = sync
a.key(ord("3"), 0); a.key(ord("b"), 0)
check("b opens the wallpaper picker on the selected cell",
      a.dialog == ("wpick", None) and a.wpick_list()[0] == "(default)"
      and a.wpick["sel"] == 0, (a.dialog, a.wpick))
for ch in "bub":
    a.key(ord(ch), 0)
a.key(10, 0)
check("typing filters and Enter sets the cell",
      a.walls == {(0, 0): "bubbles.jpg"} and a.dirty() and a.dialog is None,
      (a.walls, a.msg))
a.key(curses.KEY_RIGHT, 0); a.key(ord("b"), 0); a.key(27, 0)
check("Esc in the picker changes nothing",
      a.walls == {(0, 0): "bubbles.jpg"} and a.dialog is None, a.walls)
a.key(ord("s"), 0)
kinds = [c[0] for c in hw.calls]
check("a save writes the wallpapers after the desk",
      "walls" in kinds and kinds.index("walls") > kinds.index("write")
      and hw.calls[kinds.index("walls")][1] == {(0, 0): "bubbles.jpg"}
      and not a.dirty(), hw.calls)
a.key(curses.KEY_LEFT, 0); a.key(ord("b"), 0)
check("the picker starts on the cell's own wallpaper",
      a.wpick_list()[a.wpick["sel"]] == "bubbles.jpg", a.wpick)
a.key(curses.KEY_UP, 0); a.key(curses.KEY_UP, 0); a.key(10, 0)
check("(default) clears the cell", a.walls == {} and a.dirty(), a.walls)

d, outs, hw = desk()
hw.wallsv = {(0, 0): "aurora.jpg", (2, 1): "night sky.png"}
hw.gridv = (3, 2)
a = tui.App(d, hw)
check("the wallpapers load, and a fresh desk is not dirty",
      a.walls == hw.wallsv and not a.dirty(), a.walls)
check("the review tab says each cell's wallpaper",
      "cell 0,0  wallpaper aurora.jpg" in tui.review_lines(a)
      and "cell 1,0  wallpaper (default)" in tui.review_lines(a),
      tui.review_lines(a)[:6])
a.key(ord("3"), 0); a.key(ord("-"), 0)
check("a shrink drops the wallpapers that fall off, and says so",
      a.walls == {(0, 0): "aurora.jpg"} and a.grid == (2, 2)
      and "dropped the wallpaper of cell 2,1" in a.msg, (a.walls, a.msg))
hw.imagesv = []
a.key(ord("b"), 0)
check("no images: says so, opens nothing",
      a.dialog is None and "no images" in a.msg, a.msg)

# The REAL Hwdp: the images are the files in the wallpaper directory with an
# image suffix, hidden ones and directories left out; --wallpapers is read
# as `X Y FILE`, a name with spaces whole.
import os
os.environ["HWDP_WALLPAPER_DIR"] = sys.argv[2] + "/walls"
real2 = tui.Hwdp()
check("the images are the image files there, by name",
      real2.wallpaper_images() == ["a.png", "b.JPG"],
      real2.wallpaper_images())
real2.libexec = sys.argv[2] + "/stub2"
check("--wallpapers is read cell by cell, spaces kept",
      real2.wallpapers() == {(0, 0): "a.png", (2, 1): "night sky.png"},
      real2.wallpapers())

# The REAL Hwdp keeps all of what hwdp said: the reason comes before the
# summary, and keeping only the last line is how the reason was lost.
stub = tui.Hwdp()
stub.libexec = sys.argv[2] + "/stub"
rc, _, why = stub._surf("--write", stdin="")
check("Hwdp keeps the whole complaint, reason first",
      rc == 2 and "the REASON" in why and why.endswith("NOT written"), why)

# --- the integrator's DEFAULT wallpapers, and moving workspaces -------------
def gridapp(defaults, walls, grid=(3, 2)):
    d, (p, l), hw = desk()
    hw.gridv, hw.wallsv, hw.defaultsv = list(grid), dict(walls), dict(defaults)
    hw.namesv = [["comms", "Comms"], ["mail", "Mail"], ["code", "Code"]]
    hw.surf = ([tui.Surface("comms", "DP-1", "top", 0, 0),
                tui.Surface("mail", "DP-2", "full", 1, 0),
                tui.Surface("code", "DP-1", "full", 2, 1)], None, "")
    hw.splitv = [("DP-1", 0, 0, "top-bottom")]
    a = tui.App(d, hw)
    a.spawn, a.tab = sync, 2
    return a, hw
a, hw = gridapp({(0, 0): "d00.jpg", (1, 0): "d10.jpg"}, {(1, 0): "own.jpg"})
check("a cell the desk sets nothing in shows the integrator's default",
      a.wall_at((0, 0)) == ("d00.jpg", False), a.wall_at((0, 0)))
check("the desk's own wins over the default",
      a.wall_at((1, 0)) == ("own.jpg", True), a.wall_at((1, 0)))
check("and the words say which is the default's",
      "wallpaper: (default) d00.jpg" in tui.cell_words(a), tui.cell_words(a))
a.key(curses.KEY_SLEFT, 0)
check("a column cannot move off the grid's edge",
      a.surfaces[0].cx == 0 and a.vcell == [0, 0], a.vcell)
a.key(curses.KEY_SRIGHT, 0)
cells = {x.name: (x.cx, x.cy) for x in a.surfaces}
check("shift+Right trades the column with its neighbour, surfaces and all",
      cells == {"comms": (1, 0), "mail": (0, 0), "code": (2, 1)}, cells)
check("its cut goes with it", list(a.splits) == [("DP-1", 1, 0)], a.splits)
check("the wallpaper SHOWN goes with it, a default becoming the desk's own",
      a.walls == {(0, 0): "own.jpg", (1, 0): "d00.jpg"}, a.walls)
check("and the selection follows", a.vcell == [1, 0] and "moved right"
      in a.msg, (a.vcell, a.msg))
a.key(curses.KEY_SF, 0)
cells = {x.name: (x.cx, x.cy) for x in a.surfaces}
check("shift+Down trades the row",
      cells == {"comms": (1, 1), "mail": (0, 1), "code": (2, 0)}
      and a.vcell == [1, 1], (cells, a.vcell))
a, hw = gridapp({}, {(2, 1): "x.jpg"})
a.vcell = [2, 1]
a.key(ord("t"), 0)
cells = {x.name: (x.cx, x.cy) for x in a.surfaces}
check("t turns the grid: (x, y) to (y, x), W x H to H x W",
      a.grid == (2, 3) and cells == {"comms": (0, 0), "mail": (0, 1),
                                     "code": (1, 2)}
      and a.walls == {(1, 2): "x.jpg"} and a.vcell == [1, 2],
      (a.grid, cells, a.walls, a.vcell))
a.key(ord("t"), 0)
check("and back again", a.grid == (3, 2) and a.walls == {(2, 1): "x.jpg"},
      (a.grid, a.walls))
a, hw = gridapp({(0, 0): "same.jpg", (1, 0): "same.jpg"}, {})
a.key(curses.KEY_SRIGHT, 0)
check("a default that matches the new place's own default stays a default",
      a.walls == {}, a.walls)
a.key(ord("s"), 0)
wrote = [c for c in hw.calls if c[0] == "write"]
check("and a move is saved like any change, the surfaces where they went",
      wrote and ("comms", "DP-1", "top", 1, 0) in wrote[0][2]
      and not any(c[0] == "walls" for c in hw.calls), hw.calls)
a, hw = gridapp({}, {})
a.names_blocked = "broken"
a.key(curses.KEY_SRIGHT, 0)
check("a desk whose files cannot be edited moves nothing",
      a.surfaces[0].cx == 0 and "cannot be edited" in a.msg, a.msg)

# A name is in one place per desk, and moving it between being a surface
# and being the default is SAID: the default's name placed in a cell once
# took a desk's default away with nothing on the screen (2026-11-14).
a, hw = gridapp({}, {})
a.vcell = [1, 1]
a.key(ord("f"), 0)
a.pick["sel"] = [n for n, _ in a.names].index("comms")
a.key(10, 0)
check("making a placed name the default says where it was taken from",
      a.default and a.default.name == "comms"
      and "taken out of cell 0,0" in a.msg, a.msg)
a.vcell = [2, 0]
a.key(10, 0)
a.pick["sel"] = [n for n, _ in a.names].index("comms")
a.key(10, 0)
check("placing the default's name in a cell says the desk lost its default",
      a.default is None and "no longer the default" in a.msg, a.msg)

# `hwdp surfaces --names`, as the tool reads it: `name: label`, the first
# colon dividing, and the older `name label` still read.
check("a names line is name: label, the label whole",
      tui.name_label("eng-ops: Engineering: Operations")
      == ("eng-ops", "Engineering: Operations"))
check("and the older form still reads",
      tui.name_label("work-comms Work Comms") == ("work-comms", "Work Comms")
      and tui.name_label("x Has: A colon") == ("x", "Has: A colon"))
check("and a line that is neither is nothing",
      tui.name_label("lonely") == (None, None))

# --- ARRANGE: tiles laid out freely, evened out into a grid on commit -------
def placed(a):
    return {x.name: (x.cx, x.cy) for x in a.surfaces}
a, hw = gridapp({}, {(1, 0): "own.jpg"})
a.key(ord("A"), 0)
check("A opens an arrangement of every cell", a.arr is not None
      and len(a.arr["at"]) == 6, a.arr)
check("its lattice has a ring to drop into",
      a.arr_extent() == (-1, -1, 3, 2), a.arr_extent())
a.key(ord("q"), 0); a.key(ord("1"), 0)
check("q and the tab keys do nothing while it is open",
      not a.done and a.tab == 2 and a.arr is not None, (a.done, a.tab))
# The user's case: column 1 made into a row of its own below the rest.
a.arr_put((1, 1), (1, 2))
a.arr_put((1, 0), (0, 2))
a.key(10, 0)
check("committed: the bounding box is the grid, the holes new workspaces",
      a.arr is None and a.grid == (3, 3), (a.arr, a.grid))
check("what the column held went with it, into the row",
      placed(a) == {"comms": (0, 0), "mail": (0, 2), "code": (2, 1)}
      and a.walls == {(0, 2): "own.jpg"}, (placed(a), a.walls))
a, hw = gridapp({}, {})
a.key(ord("A"), 0)
# Column 1 carried out to the ring on the right: an EMPTY column is left
# inside the layout (0, then nothing, then 2 and 3), and it must go.
a.arr_put((1, 0), (3, 0)); a.arr_put((1, 1), (3, 1))
a.key(10, 0)
check("a column left with no tile is dropped, even inside the layout",
      a.grid == (3, 2) and placed(a) == {"comms": (0, 0), "mail": (2, 0),
                                         "code": (1, 1)}, (a.grid, placed(a)))
a, hw = gridapp({}, {})
a.key(ord("A"), 0)
a.arr_put((2, 0), (-1, 0)); a.arr_put((2, 1), (-1, 1))
a.key(10, 0)
check("and a layout reaching left of 0 is shifted back to 0,0",
      a.grid == (3, 2) and placed(a) == {"comms": (1, 0), "mail": (2, 0),
                                         "code": (0, 1)}, (a.grid, placed(a)))
a, hw = gridapp({}, {})
a.key(ord("A"), 0)
a.arr_put((0, 0), (1, 0))
check("a drop on a tile swaps the two", a.arr["at"][(1, 0)] == (0, 0)
      and a.arr["at"][(0, 0)] == (1, 0), a.arr["at"])
a.arr["sel"] = (0, 1)
a.key(ord("d"), 0)
check("an empty tile is deleted at once", (0, 1) not in a.arr["at"]
      and a.dialog is None and (0, 1) in a.arr["gone"], a.arr["gone"])
a.arr["sel"] = (0, 0)                          # mail's cell, moved here
a.key(ord("d"), 0)
check("one that holds something asks first", a.dialog
      and a.dialog[0] == "deltile"
      and "mail" in " ".join(tui.deltile_words(a)[1]), a.dialog)
a.key(10, 0)
check("Enter keeps it", a.dialog is None and (0, 0) in a.arr["at"])
a.key(ord("d"), 0); a.key(ord("y"), 0)
a.key(10, 0)
check("committed, a deleted tile's surfaces are unplaced",
      "mail" not in placed(a) and a.arr is None, placed(a))
a, hw = gridapp({}, {(1, 0): "own.jpg"})
before = (a.grid, placed(a), dict(a.walls))
a.key(ord("A"), 0)
a.arr_put((1, 0), (3, 2))
a.key(27, 0)
check("Esc throws the draft away", a.arr is None
      and (a.grid, placed(a), a.walls) == before, (a.grid, placed(a)))
a.key(ord("A"), 0)
a.tab = 0
a.key(ord("s"), 0)
check("save is refused while an arrangement is open",
      not any(c[0] in ("write", "walls") for c in hw.calls)
      and "arrangement is open" in a.msg, a.msg)
a.tab = 2
scr = Scr(80, 24)
tui.render(scr, a, 0.0)
check("the terminal draws the arrangement, its tiles titled by cell",
      "1,0" in scr.text() and "mail" in scr.text()
      and "S-arrows move it" in scr.text(), scr.text())

print("\n".join(fails) if fails else "ALL-OK")
PY
)
[ "$_out" = ALL-OK ] || fail "$_out"
pass "model, controller and view: drawings cut, the selection in full"

# --- it refuses to run without a terminal -------------------------------------
if _o=$(python3 "$HERE/libexec/desk-tui" </dev/null 2>&1); then
  fail "the tool ran with no terminal"
fi
case $_o in
  *"needs a terminal"*) ;;
  *) fail "no terminal: $_o" ;;
esac
pass "without a terminal it says so"
