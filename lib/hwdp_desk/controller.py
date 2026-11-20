"""hwdp desk: what a key means: the App both views drive."""
import curses
import threading

from .model import (
    HALVES, NEW_GRID, PREVIEW_SECONDS, SPLITS, SPLIT_OF, STEP, Surface,
    clashes, contacts, drag_spot, nearest_valid, step)
from .words import DEFAULT_WALL, brief


# --- the controller: what a key means ---------------------------------------

ARROWS = {curses.KEY_LEFT: (-1, 0), curses.KEY_RIGHT: (1, 0),
          curses.KEY_UP: (0, -1), curses.KEY_DOWN: (0, 1),
          ord("h"): (-1, 0), ord("l"): (1, 0),
          ord("k"): (0, -1), ord("j"): (0, 1)}
FINE = {curses.KEY_SLEFT: (-1, 0), curses.KEY_SRIGHT: (1, 0),
        curses.KEY_SR: (0, -1), curses.KEY_SF: (0, 1),
        ord("H"): (-1, 0), ord("L"): (1, 0),
        ord("K"): (0, -1), ord("J"): (0, 1)}
ESC = 27
ENTER = (10, 13, curses.KEY_ENTER)
ARR_PENDING = "an arrangement is open: Enter commits it, Esc cancels it"

# The same keys as a toolkit names them (X keysym names, which GTK reports),
# so a graphical view hands App.key exactly what the terminal does and one
# controller means one set of keys. A printable key is its character.
KEYSYMS = {"Left": curses.KEY_LEFT, "Right": curses.KEY_RIGHT,
           "Up": curses.KEY_UP, "Down": curses.KEY_DOWN,
           "shift+Left": curses.KEY_SLEFT, "shift+Right": curses.KEY_SRIGHT,
           "shift+Up": curses.KEY_SR, "shift+Down": curses.KEY_SF,
           "Tab": 9, "ISO_Left_Tab": curses.KEY_BTAB,
           "shift+Tab": curses.KEY_BTAB, "Return": 10, "KP_Enter": 10,
           "Escape": ESC, "BackSpace": curses.KEY_BACKSPACE,
           "Page_Down": curses.KEY_NPAGE, "Page_Up": curses.KEY_PPAGE,
           "space": ord(" ")}


def key_code(name, char, shift=False):
    """The App.key code for a key a toolkit reports by NAME (its keysym)
    and CHAR (what it types, or ""), else None."""
    if shift and "shift+" + name in KEYSYMS:
        return KEYSYMS["shift+" + name]
    if name in KEYSYMS:
        return KEYSYMS[name]
    if len(char) == 1 and char.isprintable():
        return ord(char)
    return None


class App:
    def __init__(self, desk, hw):
        self.desk, self.hw = desk, hw
        self.sel = 0
        self.mark = None          # the output marked for a swap
        # The output SELECTED to move, and where EVERY output was when it
        # was: a step re-normalises the desk, so the mover's old (x, y)
        # alone would mean another place once it has passed an edge.
        self.moving = None        # (output, [(x, y) per output])
        self.saved = desk.placements()
        self.live_unsaved = False  # a preview was KEPT but not saved
        self.dialog = None        # (kind, its deadline or default)
        self.msg = ""
        self.ident = False
        self.done = False
        self.form = None          # the name form, while it is up
        self.busy = None          # [what, since, latest line] while saving
        self.job = None           # the save running beside the screen
        self.tab = 0              # TABS: physical, virtual, review
        self.side = 0             # the sidebar's selected name
        self.vcell = [0, 0]       # the virtual tab's selected cell
        self.vpanel = 0           # ... panel in it (index into desk.on())
        self.vhalf = 0            # ... and half of it, when it is split
        self.rscroll = 0          # the review tab's first line
        self.pick = None          # the picker, while it is up
        surf, default, why = hw.surfaces(desk)
        # Files `hwdp surfaces` refuses are NOT edited on top of: rewriting
        # them from what the tool could read would drop what it could not.
        self.names_blocked = brief(why) if surf is None else ""
        self.surfaces = surf or []
        self.default = default
        # {(panel, cx, cy): split}: written ones, then any a placed half
        # implies (a file from before splits were written).
        self.splits = {(c, x, y): w for c, x, y, w in hw.splits()}
        for x in self.surfaces:
            if x.region in SPLIT_OF:
                self.splits.setdefault((x.conn, x.cx, x.cy),
                                       SPLIT_OF[x.region])
        self.grid = hw.grid() or NEW_GRID
        self.names = hw.names()
        self.walls = dict(hw.wallpapers())   # {(cx, cy): file}
        # What a cell shows when the desk sets nothing there: the
        # integrator's, read only, never saved as the desk's own.
        self.wall_defaults = dict(hw.default_wallpapers())
        self.wpick = None                    # the wallpaper picker, if up
        self.arr = None                      # an ARRANGEMENT being drafted
        self._mark_saved()

    def plabel(self, conn):
        """A stored panel name as a person reads it."""
        for o in self.desk.outs:
            if o.conn == conn:
                return o.label
        return conn

    def _mark_saved(self):
        self.saved_surfaces = self._surface_keys()
        self.saved_default = self.default.key() if self.default else None
        self.saved_grid = self.grid
        self.saved_splits = sorted(self.splits.items())
        self.saved_names = [list(n) for n in self.names]
        self.saved_walls = dict(self.walls)

    @property
    def cur(self):
        return self.desk.outs[self.sel]

    def _surface_keys(self):
        return sorted(x.key() for x in self.surfaces)

    def desk_dirty(self):
        return (self._surface_keys() != self.saved_surfaces
                or self.walls != self.saved_walls
                or self.grid != self.saved_grid
                or sorted(self.splits.items()) != self.saved_splits
                or (self.default.key() if self.default else None)
                != self.saved_default)

    def dirty(self):
        return (self.desk.placements() != self.saved or self.live_unsaved
                or self.desk_dirty() or self.names != self.saved_names)

    # Dialogs first: while one is up, it owns the keyboard. Then what is
    # the same on every tab (switching, the sidebar, save, quit), then the
    # tab's own keys.
    def key(self, k, now):
        if self.busy:
            return                # a save owns the screen until it lands
        if self.dialog:
            return self._dialog_key(k, now)
        if self.moving and (k in ARROWS or k in FINE):
            return self._move(k)
        if self.arr is not None:
            if self.tab == 2:
                return self._arrange_key(k, now)
            if k in (ord("q"), ord("s")):
                self.msg = ARR_PENDING
                return
        tab = {ord("1"): 0, ord("2"): 1, ord("3"): 2, ord("4"): 3,
               curses.KEY_F1: 0, curses.KEY_F2: 1, curses.KEY_F3: 2,
               curses.KEY_F4: 3}.get(k)
        if tab is not None:
            self.tab, self.msg = tab, ""
            return
        common = {ord("q"): self._quit, ord("s"): self._save_here}.get(k)
        if common:
            return common(now)
        if k == ESC:
            return self._escape(now)
        if self.tab == 1:
            return self._surfaces_key(k, now)
        if self.tab == 2:
            return self._virtual_key(k, now)
        if self.tab == 3:
            if k in ARROWS:
                self.rscroll = max(0, self.rscroll + ARROWS[k][1] * 3)
            elif k in (curses.KEY_NPAGE, ord(" ")):
                self.rscroll += 15
            elif k == curses.KEY_PPAGE:
                self.rscroll = max(0, self.rscroll - 15)
            return
        if k in ARROWS or k in (9, curses.KEY_BTAB):
            return self._select(k)
        action = {ord("r"): self._rotate, ord("w"): self._swap,
                  ord("m"): self._move_mode, ord("o"): self._toggle_on,
                  ord("i"): self._identify, ord("p"): self._preview}.get(k)
        if action:
            return action(now)
        if k in ENTER:
            return self._commit(now)

    def tick(self, now):
        self._landed()
        if self.dialog and self.dialog[0] == "keep" and now >= self.dialog[1]:
            self._revert("no answer: reverted")

    def _select(self, k):
        if self.moving:             # Tab puts the selected one down
            self._move_mode(0)
        n = len(self.desk.outs)
        if k == 9:
            self.sel = (self.sel + 1) % n
            return
        if k == curses.KEY_BTAB:
            self.sel = (self.sel - 1) % n
            return
        dx, dy = ARROWS[k]
        c = self.cur
        cx, cy = c.x + c.w / 2, c.y + c.h / 2
        best = None
        for i, o in enumerate(self.desk.outs):
            if o is c or not o.on:
                continue
            ox, oy = o.x + o.w / 2 - cx, o.y + o.h / 2 - cy
            ahead = ox * dx + oy * dy
            if ahead <= 0:
                continue
            d = ahead + 2 * abs(ox * dy + oy * dx)
            if best is None or d < best[0]:
                best = (d, i)
        if best:
            self.sel = best[1]

    def _rotate(self, now):
        if self.cur.on:
            self.desk.rotate(self.cur)
            self.msg = "%s rotated" % self.cur.label

    def _swap(self, now):
        c = self.cur
        if not c.on:
            self.msg = "%s is off" % c.label
        elif self.mark is None or self.mark is c:
            self.mark = None if self.mark is c else c
            self.msg = ("%s marked: select another and press w or Enter"
                        % c.label) if self.mark else ""
        else:
            self.desk.swap(self.mark, c)
            self.msg = "swapped %s and %s" % (self.mark.label, c.label)
            self.mark = None

    def _move_mode(self, now):
        """In and out of SELECTED: the highlighted monitor taken to move
        (the arrows step it, a drag carries it), or put down where it is."""
        if self.moving:
            o = self.moving[0]
            self.moving = None
            self.msg = "%s placed at %d,%d" % (o.label, o.x, o.y)
        elif self.cur.on:
            self._take(self.cur)
            self.msg = ("moving %s: arrows step, shift+arrow one pixel,"
                        " Enter places it, Esc undoes" % self.cur.label)

    def _take(self, o):
        self.moving = (o, [(n.x, n.y) for n in self.desk.outs])

    def _move(self, k):
        o = self.moving[0]
        if k in FINE:
            dx, dy = FINE[k]
        else:
            dx, dy = ARROWS[k]
            dx, dy = dx * STEP, dy * STEP
        step(self.desk, o, dx, dy, snap=k not in FINE)
        self.msg = "%s %d,%d  %s" % (
            o.conn, o.x, o.y,
            contacts(o, [n for n in self.desk.on() if n is not o]))

    # --- the pointer: a monitor highlighted, grabbed, dragged, dropped ----
    # A drag SELECTS the monitor, as Enter does, and it STAYS selected when
    # the button is let go, so the arrows fine-tune where the drag left it;
    # Enter, or a click elsewhere, puts it down, and Esc undoes it all.
    def highlight(self, i):
        """Highlight output I (a click), putting down a monitor selected
        to move first; False when a dialog or a save has the screen."""
        if self.busy or self.dialog:
            return False
        if self.moving and self.moving[0] is not self.desk.outs[i]:
            self._move_mode(0)
        self.sel = i
        return True

    def grab(self, i):
        """Highlight output I and select it to drag; False if it cannot
        move (it is off, or a dialog or a save has the screen)."""
        if not self.highlight(i) or not self.desk.outs[i].on:
            return False
        if not self.moving:
            self._take(self.desk.outs[i])
        return True

    def release(self):
        """A click on nothing: put down whatever was selected."""
        if self.moving and not (self.busy or self.dialog):
            self._move_mode(0)

    def drag_to(self, x, y, reach):
        """The grabbed output follows (X, Y), its top-left in logical
        pixels, wherever it can touch another; alignments within REACH
        pull it in. NOT normalised until the drop, so the drawing's frame
        holds still under the pointer."""
        if not self.moving:
            return
        o = self.moving[0]
        spot = drag_spot(self.desk, o, round(x), round(y), reach)
        if spot:
            o.x, o.y = spot
        self.msg = "%s %d,%d  %s" % (
            o.label, o.x, o.y,
            contacts(o, [n for n in self.desk.on() if n is not o]))

    def drop(self):
        """The button let go: normalised, and still selected."""
        if not self.moving:
            return
        self.desk.normalise()
        o = self.moving[0]
        self.msg = "%s %d,%d  %s  (arrows nudge it, Enter places it)" % (
            o.label, o.x, o.y,
            contacts(o, [n for n in self.desk.on() if n is not o]))

    def _toggle_on(self, now):
        c = self.cur
        if c.on and len(self.desk.on()) == 1:
            self.msg = "the last monitor on cannot be switched off"
            return
        c.on = not c.on
        if c.on:
            spot = nearest_valid(c, [o for o in self.desk.on()
                                     if o is not c], c.x, c.y)
            if spot:
                c.x, c.y = spot
        self.desk.normalise()
        self.msg = "%s switched %s" % (c.label, "on" if c.on else "off")

    def _identify(self, now):
        if getattr(self.hw, "offline", False):
            self.msg = "%s is not attached: no monitors to label" \
                % self.hw.name
            return
        self.ident = self.hw.identify(not self.ident)
        if not self.ident:
            self.msg = "labels off"

    def _preview(self, now):
        if getattr(self.hw, "offline", False):
            self.msg = "%s is not attached: a preview needs its panels" \
                % self.hw.name
            return
        if self.desk.faults():
            self.msg = "the monitors must meet edge to edge first"
            return
        rc, why = self.hw.arrange("--preview", self.desk.placements())
        if rc == 0:
            self.dialog = ("keep", now + PREVIEW_SECONDS)
        else:
            self.fail("Not previewed", why or "preview failed (%d)" % rc)

    def _revert(self, why):
        self.hw.arrange("--revert", [])
        self.live_unsaved = False
        self.dialog = None
        self.msg = why

    def _save(self, now, then_exit):
        """The layout, the names, the desk; done only if all landed. It runs
        BESIDE the screen, which says what it is waiting on: a save fires
        the integrator's hooks, and those can take seconds.

        THE NAMES GO IN TWO STEPS around the desk, because a desk may only
        place listed names and the list may not drop a placed one: first the
        new list PLUS anything removed that the saved desk still places,
        then the desk, then the new list alone."""
        self.dialog = None
        place = self.desk.placements()
        layout = place != self.saved or self.live_unsaved
        desk = (self.grid, list(self.surfaces), self.default,
                sorted(k + (w,) for k, w in self.splits.items())) \
            if self.desk_dirty() else None
        names = [list(n) for n in self.names]
        keep = [n for n in self.saved_names
                if n[0] not in {m[0] for m in names}]
        names_changed = names != self.saved_names
        walls = dict(self.walls) if self.walls != self.saved_walls else None
        self.busy = ["saving", now, ""]

        def said(line):
            self.busy[2] = line

        def step(what, call, *args):
            self.busy[0] = what
            rc, why = call(*args)
            if rc == 0:
                return ""
            why = why or "exit %d" % rc
            # A reason of several lines starts on its own line, so each is
            # read as one (and loses its `hwdp <cmd>:` prefix in the dialog).
            return "%s:%s%s" % (what, "\n" if "\n" in why else " ", why)

        def work():
            if layout:
                self.busy[0] = "saving the layout"
                rc, why = self.hw.arrange(None, place, progress=said)
                if rc != 0:
                    return why or "not saved (%d)" % rc, "none"
            if names_changed:
                why = step("saving names", self.hw.write_names, names + keep)
                if why:
                    return why, "layout"
            if desk is not None:
                why = step("saving the desk", self.hw.write_desk, *desk)
                if why:
                    return why, "layout"
            if walls is not None:
                why = step("saving the wallpapers", self.hw.write_wallpapers,
                           walls)
                if why:
                    return why, "layout"
            if keep:
                # Deleting a name was asked and answered: it comes off any
                # OTHER desk that places it too, attached or not.
                why = step("removing names", self.hw.write_names, names,
                           True)
                if why:
                    return why, "desk"
            return step("applying it to this session", self.hw.apply), "all"

        def finish(res):
            why, upto = res
            if upto != "none":
                self.saved, self.live_unsaved = place, False
            if upto in ("desk", "all"):
                self._mark_saved()
                if upto == "desk":           # the list still holds `keep`
                    self.saved_names = names + keep
            if why:
                # Saved whole and only the apply failed: say THAT, since
                # "Not saved" would send someone to redo a save that stands.
                self.fail("Saved, but not applied" if upto == "all"
                          else "Not saved", why)
            else:
                self.msg = "saved"
            self.done = then_exit and not why
        self.job = self.spawn(work, finish)
        self._landed()

    @staticmethod
    def spawn(work, finish):
        """Run WORK on a thread; the screen calls FINISH with its answer
        once it lands (see _landed). A test swaps in a synchronous one."""
        job = {"finish": finish}

        def run():
            try:
                job["res"] = work()
            except Exception as e:      # said on screen, never swallowed
                job["res"] = ("save failed: %s" % e, None)
        job["thread"] = threading.Thread(target=run, daemon=True)
        job["thread"].start()
        return job

    def _landed(self):
        if self.job and "res" in self.job:
            job, self.job, self.busy = self.job, None, None
            job["finish"](job["res"])

    # --- the sidebar: the global surface names --------------------------
    def _blocked(self):
        if self.names_blocked:
            self.msg = ("surfaces cannot be edited: " + self.names_blocked +
                        " (see hwdp surfaces --check)")
        return bool(self.names_blocked)

    def side_name(self):
        return self.names[self.side][0] if self.names else None

    def _surfaces_key(self, k, now):
        """The SURFACES tab: the names, edited here and nowhere else."""
        if k in (curses.KEY_DOWN, ord("j")):
            return self._side_down(now)
        if k in (curses.KEY_UP, ord("k")):
            return self._side_up(now)
        act = {ord("a"): self._name_add, ord("e"): self._name_edit,
               ord("D"): self._name_delete}.get(k)
        if act:
            return act(now)

    def _side_down(self, now):
        if self.names:
            self.side = (self.side + 1) % len(self.names)

    def _side_up(self, now):
        if self.names:
            self.side = (self.side - 1) % len(self.names)

    def placed(self, name):
        """Where NAME is at this desk: its surfaces, and whether it is the
        default (the sidebar's marker reads this)."""
        here = [x for x in self.surfaces if x.name == name]
        return here, bool(self.default and self.default.name == name)

    def _name_add(self, now):
        if not self._blocked():
            self.form = {"field": 0, "name": "", "label": "", "err": "",
                         "edit": None}
            self.dialog = ("name", None)

    def _name_edit(self, now):
        if self._blocked() or not self.names:
            return
        n, lab = self.names[self.side]
        self.form = {"field": 1, "name": n, "label": lab, "err": "",
                     "edit": self.side}
        self.dialog = ("name", None)

    def _name_delete(self, now):
        if not self._blocked() and self.names:
            self.dialog = ("delname", None)

    def _form_key(self, k):
        """The name form: a NAME (the machine key: letters, digits, - and _;
        fixed once made, since other desks may place it) and a LABEL (what
        a workspace name shows; spaces allowed)."""
        f = self.form
        if k == ESC:
            self.form, self.dialog = None, None
        elif k in ENTER:
            self._form_done()
        elif k in (9, curses.KEY_DOWN, curses.KEY_BTAB, curses.KEY_UP):
            f["field"] = 1 if f["edit"] is not None else 1 - f["field"]
        elif k in (curses.KEY_BACKSPACE, 127, 8):
            fld = "name" if f["field"] == 0 else "label"
            f[fld] = f[fld][:-1]
        elif 32 <= k < 127:
            c = chr(k)
            if f["field"] == 0 and (c.isalnum() or c in "_-"):
                f["name"] += c
            elif f["field"] == 1:
                f["label"] += c

    def _form_done(self):
        f = self.form
        label = f["label"].strip() or f["name"]
        if f["edit"] is not None:
            self.names[f["edit"]][1] = label
            self.msg = "%s is labelled %s" % (f["name"], label)
        elif not f["name"]:
            f["err"] = "give it a name"
            return
        elif any(n == f["name"] for n, _ in self.names):
            f["err"] = "%s is already a name" % f["name"]
            return
        else:
            self.names.append([f["name"], label])
            self.side = len(self.names) - 1
            self.msg = "%s added; place it in the virtual tab" % f["name"]
        self.form, self.dialog = None, None

    def form_submit(self, name, label):
        """The name form, filled in whole (a view with entry fields): the
        same rules as typing it, but a character typing would have refused
        is SAID, never dropped. The form stays up, saying why, until it is
        right or cancelled."""
        f = self.form
        if f["edit"] is None:
            bad = sorted({c for c in name if not (c.isascii() and (
                c.isalnum() or c in "_-"))})
            if bad:
                f["err"] = "a name is letters, digits, - and _ (not %s)" % \
                    " ".join(bad)
                return
            f["name"] = name
        bad = sorted({c for c in label if not 32 <= ord(c) < 127})
        if bad:
            f["err"] = "a label is plain ASCII (not %s)" % " ".join(bad)
            return
        f["label"] = label
        self._form_done()

    def _name_gone(self):
        """Delete the selected name, and its places at THIS desk with it.
        Another desk placing it makes the save refuse, naming that desk."""
        n = self.names.pop(self.side)[0]
        self.surfaces = [x for x in self.surfaces if x.name != n]
        if self.default and self.default.name == n:
            self.default = None
        self.side = max(0, min(self.side, len(self.names) - 1))
        self.dialog, self.msg = None, "%s deleted" % n

    # --- the virtual tab: surfaces on the grid --------------------------
    def split_at(self, o, cx, cy):
        """How output O is cut in cell (cx, cy): None (whole) or a SPLITS
        word."""
        return self.splits.get((o.conn, cx, cy))

    def vstops(self):
        """Every stop Tab walks in the selected cell, in order: each panel
        whole, or each of its halves when it is split there."""
        return [(o, rg) for o in self.desk.on()
                for rg in HALVES[self.split_at(o, *self.vcell)]]

    def vspot(self):
        """(output, region) selected in the virtual tab, or (None, "full")
        when no output is on. The half is clamped, so a panel split in one
        cell and whole in the next is still a valid selection."""
        on = self.desk.on()
        if not on:
            return None, "full"
        self.vpanel %= len(on)
        o = on[self.vpanel]
        hs = HALVES[self.split_at(o, *self.vcell)]
        self.vhalf = min(self.vhalf, len(hs) - 1)
        return o, hs[self.vhalf]

    def _vtab(self, step):
        """Tab to the next stop (a whole panel, or a half), across panels."""
        stops = self.vstops()
        if not stops:
            return
        here = stops.index(self.vspot())
        o, rg = stops[(here + step) % len(stops)]
        on = self.desk.on()
        self.vpanel = on.index(o)
        self.vhalf = HALVES[self.split_at(o, *self.vcell)].index(rg)

    def select_spot(self, cx, cy, o, region):
        """Select output O's REGION in cell (cx, cy), as the arrows and Tab
        would (a view's click). A region the cell's cut does not have
        selects the panel's first stop there; no O selects the cell alone,
        keeping the panel."""
        on = self.desk.on()
        if (o is not None and o not in on) or not (
                0 <= cx < self.grid[0] and 0 <= cy < self.grid[1]):
            return
        self.vcell = [cx, cy]
        if o is None:
            return
        self.vpanel = on.index(o)
        hs = HALVES[self.split_at(o, cx, cy)]
        self.vhalf = hs.index(region) if region in hs else 0

    def place(self, name):
        """Put NAME on the selected spot (a view's drop): what the picker
        does with its choice."""
        self._vplace(name)

    def at_spot(self):
        """The surfaces that overlap the selected spot."""
        o, rg = self.vspot()
        probe = Surface("", o.conn if o else "", rg, *self.vcell)
        return [x for x in self.surfaces if clashes(probe, x)]

    def wall_at(self, cell):
        """(file, the desk's own?) the cell shows: its own, else the
        integrator's default, else (None, False)."""
        cell = tuple(cell)
        if cell in self.walls:
            return self.walls[cell], True
        return self.wall_defaults.get(cell), False

    def _virtual_key(self, k, now):
        if k in FINE:
            dx, dy = FINE[k]
            return self._shift(dx, dy)
        if k in ARROWS:
            dx, dy = ARROWS[k]
            self.vcell = [min(max(self.vcell[0] + dx, 0), self.grid[0] - 1),
                          min(max(self.vcell[1] + dy, 0), self.grid[1] - 1)]
            return
        if k in (9, curses.KEY_BTAB):
            return self._vtab(1 if k == 9 else -1)
        act = {ord("g"): self._vsplit, ord("x"): self._vclear,
               ord("b"): self._wpick_open,
               ord("f"): lambda now: self._pick("default"),
               ord("F"): self._vnodefault,
               ord("t"): lambda now: self._transpose(),
               ord("A"): lambda now: self.arrange(),
               ord("+"): lambda now: self._regrid(1, 0),
               ord("-"): lambda now: self._regrid(-1, 0),
               ord("]"): lambda now: self._regrid(0, 1),
               ord("["): lambda now: self._regrid(0, -1)}.get(k)
        if act:
            return act(now)
        if k in ENTER:
            return self._pick("place")

    # --- the picker: which name goes on the selected spot -----------------
    def _pick(self, mode):
        """Open the picker over the names. PLACE puts the choice on the
        selected spot; DEFAULT makes it the default there. It starts on what
        is there now, so Enter twice changes nothing."""
        if self._blocked():
            return
        if not self.names:
            self.msg = "no names yet: tab 2 adds them"
            return
        if self.vspot()[0] is None:
            return
        here = [x.name for x in self.at_spot()] if mode == "place" else \
            [self.default.name] if self.default else []
        names = [n for n, _ in self.names]
        self.pick = {"mode": mode, "filter": "",
                     "sel": names.index(here[0]) if here else 0}
        self.dialog = ("pick", None)

    def pick_list(self):
        """The names the picker shows: those whose name or label holds what
        has been typed, in the list's order."""
        f = self.pick["filter"].lower()
        return [(n, lab) for n, lab in self.names
                if f in n.lower() or f in lab.lower()]

    def _pick_key(self, k, now):
        pk, shown = self.pick, self.pick_list()
        if k == ESC:
            self.pick, self.dialog = None, None
        elif k in ENTER:
            if shown:
                n = shown[min(pk["sel"], len(shown) - 1)][0]
                self.pick, self.dialog = None, None
                (self._vplace if pk["mode"] == "place" else
                 self._vdefault)(n)
        elif k == curses.KEY_DOWN:
            pk["sel"] = min(pk["sel"] + 1, max(0, len(shown) - 1))
        elif k == curses.KEY_UP:
            pk["sel"] = max(pk["sel"] - 1, 0)
        elif k in (curses.KEY_BACKSPACE, 127, 8):
            pk["filter"], pk["sel"] = pk["filter"][:-1], 0
        elif 32 < k < 127:
            pk["filter"], pk["sel"] = pk["filter"] + chr(k), 0

    # --- the wallpaper picker: which image the selected cell shows -------
    def _wpick_open(self, now):
        """Open the picker over the wallpaper directory for the selected
        CELL (a wallpaper is per workspace, not per panel). It starts on the
        cell's own choice; "(default)" leaves the cell to its default."""
        if self._blocked():
            return
        imgs = self.hw.wallpaper_images()
        if not imgs:
            self.msg = "no images in the wallpaper directory"
            return
        cur = self.walls.get(tuple(self.vcell))
        self.wpick = {"filter": "", "images": imgs,
                      "sel": imgs.index(cur) + 1 if cur in imgs else 0}
        self.dialog = ("wpick", None)

    def wpick_list(self):
        """What the picker shows: "(default)" first, then the images whose
        name holds what has been typed."""
        f = self.wpick["filter"].lower()
        return ([DEFAULT_WALL] if not f else []) + \
            [n for n in self.wpick["images"] if f in n.lower()]

    def _wpick_key(self, k, now):
        wp, shown = self.wpick, self.wpick_list()
        if k == ESC:
            self.wpick, self.dialog = None, None
        elif k in ENTER:
            if shown:
                n = shown[min(wp["sel"], len(shown) - 1)]
                self.wpick, self.dialog = None, None
                cell = tuple(self.vcell)
                if n == DEFAULT_WALL:
                    self.walls.pop(cell, None)
                    self.msg = "cell %d,%d: the default wallpaper" % cell
                else:
                    self.walls[cell] = n
                    self.msg = "cell %d,%d: %s" % (cell + (n,))
        elif k == curses.KEY_DOWN:
            wp["sel"] = min(wp["sel"] + 1, max(0, len(shown) - 1))
        elif k == curses.KEY_UP:
            wp["sel"] = max(wp["sel"] - 1, 0)
        elif k in (curses.KEY_BACKSPACE, 127, 8):
            wp["filter"], wp["sel"] = wp["filter"][:-1], 0
        elif 32 < k < 127:
            wp["filter"], wp["sel"] = wp["filter"] + chr(k), 0

    def _vsplit(self, now):
        """Cut the selected panel in THIS cell, or join it again: whole,
        top-bottom, left-right, whole. What is placed moves where it has
        exactly one home (whole to the first half, top to left, one half
        back to whole); joining a panel with BOTH halves placed asks first,
        and unplaces them, since keeping either would be a guess."""
        o, _ = self.vspot()
        if self._blocked() or o is None:
            return
        k = (o.conn,) + tuple(self.vcell)
        nxt = SPLITS[(SPLITS.index(self.splits.get(k)) + 1) % len(SPLITS)]
        here = [x for x in self.surfaces if (x.conn, x.cx, x.cy) == k]
        if nxt is None and len(here) > 1:
            self.dialog = ("unsplit", k)
            return
        self._resplit(k, nxt, here)

    def _resplit(self, k, nxt, here):
        old = HALVES[self.splits.get(k)]
        new = HALVES[nxt]
        for x in here:
            x.region = new[min(old.index(x.region), len(new) - 1)] \
                if x.region in old else new[0]
        if nxt:
            self.splits[k] = nxt
        else:
            self.splits.pop(k, None)
        self.vhalf = 0
        self.msg = "%s, cell %d %d: %s" % (
            self.plabel(k[0]), k[1], k[2], nxt or "whole")

    def _unsplit_key(self, k):
        cell = self.dialog[1]
        if k in (ord("y"),):
            gone = [x for x in self.surfaces
                    if (x.conn, x.cx, x.cy) == cell]
            self.surfaces = [x for x in self.surfaces if x not in gone]
            self._resplit(cell, None, [])
            self.msg += "; unplaced " + ", ".join(x.name for x in gone)
            self.dialog = None
        elif k in (ESC, ord("n")) or k in ENTER:
            self.dialog = None      # Enter keeps it: unplacing is asked

    def _vplace(self, n):
        """Put name N HERE. A name is in one place per desk, so it MOVES if
        it was elsewhere; whatever overlapped this spot goes."""
        o, rg = self.vspot()
        if self._blocked() or o is None or n is None:
            return
        gone = [x.name for x in self.at_spot() if x.name != n]
        self.surfaces = [x for x in self.surfaces
                         if x.name != n and x.name not in gone]
        # SAID, not done quietly: a name is in one place per desk, so the
        # default's own name placed in a cell stops being the default, and
        # that once took a desk's default away unnoticed (2026-11-14).
        was_default = bool(self.default and self.default.name == n)
        if was_default:
            self.default = None
        self.surfaces.append(Surface(n, o.conn, rg, *self.vcell))
        self.msg = "%s: %s of %s, cell %d %d%s%s" % (
            n, rg, o.conn, self.vcell[0], self.vcell[1],
            ("  (replaced %s)" % ", ".join(gone)) if gone else "",
            "  (no longer the default: this desk has none now)"
            if was_default else "")

    def _vclear(self, now):
        gone = self.at_spot()
        if not self._blocked() and gone:
            self.surfaces = [x for x in self.surfaces if x not in gone]
            self.msg = "cleared " + ", ".join(x.name for x in gone)

    def _vdefault(self, n):
        """Name N becomes the DEFAULT on this panel and region: where every
        cell no surface claims falls. Not also a surface."""
        o, rg = self.vspot()
        if self._blocked() or o is None or n is None:
            return
        cells = sorted((x.cx, x.cy) for x in self.surfaces if x.name == n)
        self.surfaces = [x for x in self.surfaces if x.name != n]
        self.default = Surface(n, o.conn, rg, None, None)
        self.msg = "%s is the default: %s of %s%s" % (
            n, rg, o.label, "  (taken out of cell %s)" % ", ".join(
                "%d,%d" % c for c in cells) if cells else "")

    def _vnodefault(self, now):
        if self.default:
            self.default, self.msg = None, "no default"

    def _regrid(self, dw, dh):
        """Grow or shrink the grid. Shrinking REFUSES while the column or
        row going away holds a surface: clear it first, nothing silently."""
        w, h = self.grid[0] + dw, self.grid[1] + dh
        if w < 1 or h < 1:
            return
        lost = [x.name for x in self.surfaces if x.cx >= w or x.cy >= h]
        if lost:
            self.msg = "not shrinking: %s would fall off the grid" % \
                ", ".join(lost)
            return
        self.grid = (w, h)
        self.vcell = [min(self.vcell[0], w - 1), min(self.vcell[1], h - 1)]
        self.msg = "grid %dx%d" % self.grid
        # A wallpaper never blocks a shrink, unlike a surface: it is a look,
        # not a place something lives. It goes, and is said.
        gone = sorted(c for c in self.walls if c[0] >= w or c[1] >= h)
        for c in gone:
            del self.walls[c]
        if gone:
            self.msg += "; dropped the wallpaper of " + ", ".join(
                "cell %d,%d" % c for c in gone)

    # --- moving workspaces: a column or a row, or the whole grid turned ----
    # What MOVES with a cell is everything it holds: its surfaces, its cuts,
    # and the wallpaper it SHOWS (a default one becomes the desk's own where
    # it lands, unless that place's own default is the same image), so what
    # is seen is what moves. The desk's default surface has no cell.
    def _relocate(self, where, grid):
        """Move every cell C to WHERE(C), the grid becoming GRID. WHERE
        answers None for a cell that is GONE: what it held is unplaced."""
        if self._blocked():
            return False
        self.surfaces = [x for x in self.surfaces
                         if where((x.cx, x.cy)) is not None]
        for x in self.surfaces:
            x.cx, x.cy = where((x.cx, x.cy))
        self.splits = {(c,) + where((cx, cy)): w
                       for (c, cx, cy), w in self.splits.items()
                       if where((cx, cy)) is not None}
        shown = {}
        for cx in range(self.grid[0]):
            for cy in range(self.grid[1]):
                f, _own = self.wall_at((cx, cy))
                if f and where((cx, cy)) is not None:
                    shown[where((cx, cy))] = f
        self.grid = grid
        self.walls = {c: f for c, f in shown.items()
                      if self.wall_defaults.get(c) != f}
        return True

    def _shift(self, dx, dy):
        """The selected cell's column one place left or right (DX), or its
        row one up or down (DY): it trades places with its neighbour."""
        cx, cy = self.vcell
        if dx:
            nx = cx + dx
            if not 0 <= nx < self.grid[0]:
                return
            swap = {cx: nx, nx: cx}
            if self._relocate(lambda c: (swap.get(c[0], c[0]), c[1]),
                              self.grid):
                self.vcell = [nx, cy]
                self.msg = "column %d moved %s" % (
                    cx, "right" if dx > 0 else "left")
        else:
            ny = cy + dy
            if not 0 <= ny < self.grid[1]:
                return
            swap = {cy: ny, ny: cy}
            if self._relocate(lambda c: (c[0], swap.get(c[1], c[1])),
                              self.grid):
                self.vcell = [cx, ny]
                self.msg = "row %d moved %s" % (cy, "down" if dy > 0 else "up")

    def _transpose(self):
        """Columns become rows: cell (x, y) goes to (y, x), the grid W x H
        to H x W."""
        w, h = self.grid
        if self._relocate(lambda c: (c[1], c[0]), (h, w)):
            self.vcell = [self.vcell[1], self.vcell[0]]
            self.msg = "grid transposed: %dx%d" % (h, w)

    # --- ARRANGE: the cells laid out freely, a grid only when committed ----
    # Every cell becomes a TILE on an open lattice (one empty ring round it
    # to drop into); a tile moves by a shift+arrow or a drag and always
    # lands on a lattice place, SWAPPING with a tile already there. A draft
    # may be any shape. COMMIT evens it out: shifted to 0,0, every row and
    # column holding no tile dropped, the bounding box the grid, a hole in
    # it a new empty workspace. Esc throws the draft away; while one is open
    # nothing is saved or quit, so it can be neither lost nor half-saved.
    def arrange(self):
        if self._blocked():
            return
        at = {(cx, cy): (cx, cy) for cx in range(self.grid[0])
              for cy in range(self.grid[1])}
        self.arr = {"at": at, "sel": tuple(self.vcell), "gone": []}
        self.msg = ("arranging: shift+arrows or a drag move a workspace,"
                    " d deletes one, Enter commits, Esc cancels")

    def arr_extent(self):
        """(x0, y0, x1, y1) of the lattice drawn: the tiles and one ring."""
        at = self.arr["at"]
        xs = [p[0] for p in at] or [0]
        ys = [p[1] for p in at] or [0]
        return min(xs) - 1, min(ys) - 1, max(xs) + 1, max(ys) + 1

    def arr_put(self, src, dst):
        """The tile at SRC to DST (a lattice place in the extent), swapping
        with one there; the selection follows it."""
        at = self.arr["at"]
        x0, y0, x1, y1 = self.arr_extent()
        if src not in at or not (x0 <= dst[0] <= x1 and y0 <= dst[1] <= y1):
            return
        tile = at.pop(src)
        if dst in at:
            at[src] = at.pop(dst)
        at[dst] = tile
        self.arr["sel"] = dst
        self.msg = "workspace %d,%d to %d,%d" % (tile + dst)

    def _arrange_key(self, k, now):
        sel = self.arr["sel"]
        if k == ESC:
            self.arr = None
            self.msg = "arrangement cancelled"
        elif k in ENTER:
            self._arrange_commit()
        elif k in ARROWS:
            dx, dy = ARROWS[k]
            x0, y0, x1, y1 = self.arr_extent()
            self.arr["sel"] = (min(max(sel[0] + dx, x0), x1),
                               min(max(sel[1] + dy, y0), y1))
        elif k in FINE:
            dx, dy = FINE[k]
            self.arr_put(sel, (sel[0] + dx, sel[1] + dy))
        elif k == ord("d"):
            self.arr_delete(sel)
        else:
            self.msg = ("arranging: shift+arrows move, d deletes, Enter"
                        " commits, Esc cancels")

    def tile_holds(self, cell):
        """What a cell holds that deleting it would lose: its surfaces'
        names, and its own wallpaper."""
        names = [x.name for x in self.surfaces if (x.cx, x.cy) == cell]
        return names, self.walls.get(cell)

    def arr_delete(self, pos):
        """Delete the tile at POS: at once when it holds nothing, else
        after asking (its surfaces are unplaced when it goes)."""
        if pos not in self.arr["at"]:
            return
        names, wall = self.tile_holds(self.arr["at"][pos])
        if names or wall:
            self.dialog = ("deltile", pos)
        else:
            self._tile_gone(pos)

    def _tile_gone(self, pos):
        cell = self.arr["at"].pop(pos)
        self.arr["gone"].append(cell)
        self.dialog = None
        self.msg = "workspace %d,%d deleted (when committed)" % cell

    def _arrange_commit(self):
        at = self.arr["at"]
        if not at:
            self.msg = "a desk needs at least one workspace"
            return
        xs = sorted({p[0] for p in at})
        ys = sorted({p[1] for p in at})
        new = {cell: (xs.index(p[0]), ys.index(p[1]))
               for p, cell in at.items()}
        sel = new.get(at.get(self.arr["sel"]), (0, 0))
        gone = len(self.arr["gone"])
        if self._relocate(new.get, (len(xs), len(ys))):
            self.arr = None
            self.vcell = list(sel)
            self.msg = "arranged: grid %dx%d" % self.grid + (
                ", %d workspace(s) deleted" % gone if gone else "")

    def _save_here(self, now):
        if self.dirty():
            self._save(now, False)
        else:
            self.msg = "nothing to save"

    def _commit(self, now):
        """Enter: a marked swap is made with the highlighted monitor (and
        is nothing on the marked one itself); otherwise in and out of
        SELECTED, as m."""
        if self.mark and not self.moving:
            if self.mark is not self.cur:
                self._swap(now)
        else:
            self._move_mode(now)

    def _quit(self, now, default=ord("s")):
        """Leave, at once when nothing is unsaved; otherwise ask. DEFAULT
        is the answer Enter picks: save from q (leaving was asked for),
        keep editing from Esc (a back-out key never writes or discards)."""
        if self.dirty():
            self.dialog = ("quit", default)
        else:
            self.done = True

    def _escape(self, now):
        if self.moving:
            for n, (x, y) in zip(self.desk.outs, self.moving[1]):
                n.x, n.y = x, y
            self.moving = None
            self.msg = "move undone"
        elif self.mark:
            self.mark, self.msg = None, ""
        else:
            self._quit(now, ESC)

    def fail(self, title, why):
        """A failure, in a dialog sized to what it says: the reasons come
        before hwdp's one-line summary, and the status line has room for
        neither (it showed "...the result would be bro", 2026-11-18)."""
        self.dialog = ("error", {"title": title, "text": why, "top": 0})
        self.msg = "%s: %s" % (title.lower(), brief(why))

    def _dialog_key(self, k, now):
        kind = self.dialog[0]
        if kind == "wpick":
            return self._wpick_key(k, now)
        if kind == "error":
            d = self.dialog[1]
            if k in ENTER or k in (ESC, ord("q")):
                self.dialog = None
            elif k in (curses.KEY_DOWN, ord("j")):
                d["top"] += 1
            elif k in (curses.KEY_UP, ord("k")):
                d["top"] = max(0, d["top"] - 1)
            elif k == curses.KEY_NPAGE:
                d["top"] += 10
            elif k == curses.KEY_PPAGE:
                d["top"] = max(0, d["top"] - 10)
            return
        if kind == "name":
            return self._form_key(k)
        if kind == "pick":
            return self._pick_key(k, now)
        if kind == "unsplit":
            return self._unsplit_key(k)
        if kind == "deltile":
            if k == ord("y"):
                self._tile_gone(self.dialog[1])
            elif k in (ESC, ord("n")) or k in ENTER:
                self.dialog = None      # Enter keeps it: deleting is asked
            return
        if kind == "delname":
            if k in (ord("y"), ord("D")):
                self._name_gone()
            elif k in (ESC, ord("n")) or k in ENTER:
                self.dialog = None      # Enter keeps it: deleting is asked
            return
        if kind == "quit":
            if k in ENTER:
                k = self.dialog[1]
            if k == ord("s"):
                self._save(now, True)
            elif k == ord("d"):
                if self.live_unsaved:
                    self.hw.arrange("--revert", [])
                self.done = True
            elif k == ESC:
                self.dialog = None
        elif kind == "keep":
            if k in (ord("y"), ord("k")) or k in ENTER:
                self.live_unsaved = True
                self.dialog = None
                self.msg = "kept live; s saves it"
            elif k in (ESC, ord("n")):
                self._revert("reverted")
