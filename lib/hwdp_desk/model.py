"""hwdp desk: the desk as data: outputs, where they may go, surfaces."""


QUARTER = ("normal", "90", "180", "270")
ROTATED = ("90", "270", "flipped-90", "flipped-270")
PREVIEW_SECONDS = 15
STEP = 25           # a coarse move, in logical pixels, before any snap
NEAR = 200          # facing edges closer than this are worth a warning


# --- the model ---------------------------------------------------------------

class Output:
    def __init__(self, conn, transform, x, y, lw, lh):
        self.conn = conn
        # What a person reads: the connector live; offline the model number
        # or `laptop`, since conn is then a whole EDID name.
        self.label = conn
        self.transform = transform
        self.x, self.y = x, y
        self.on = True
        # The UNROTATED logical size: a quarter turn swaps it, exactly,
        # because the compositor's truncation applies to each axis alone.
        if transform in ROTATED:
            self.bw, self.bh = lh, lw
        else:
            self.bw, self.bh = lw, lh

    @property
    def w(self):
        return self.bh if self.transform in ROTATED else self.bw

    @property
    def h(self):
        return self.bw if self.transform in ROTATED else self.bh

    def rect(self):
        return (self.x, self.y, self.w, self.h)

    def token(self):
        kind = "B" if self.conn.startswith(("eDP", "LVDS", "DSI")) \
            or self.conn == "@builtin" else "E"
        return kind + ("P" if self.h > self.w else "L")

    def degrees(self):
        t = self.transform.replace("flipped-", "")
        return "0" if t == "normal" else t


def span(a1, a2, b1, b2):
    """Overlap length of two ranges; 0 means they meet, below 0 apart."""
    return min(a2, b2) - max(a1, b1)


def overlaps(a, b):
    return (span(a[0], a[0] + a[2], b[0], b[0] + b[2]) > 0 and
            span(a[1], a[1] + a[3], b[1], b[1] + b[3]) > 0)


def touches(a, b):
    """Share an EDGE (not just a corner), the layout_faults rule."""
    ox = span(a[0], a[0] + a[2], b[0], b[0] + b[2])
    oy = span(a[1], a[1] + a[3], b[1], b[1] + b[3])
    return (ox == 0 and oy > 0) or (oy == 0 and ox > 0)


class Desk:
    def __init__(self, outputs, repack):
        self.outs = outputs
        self.repack = repack            # (old rects, new sizes) -> positions

    def on(self):
        return [o for o in self.outs if o.on]

    def normalise(self):
        on = self.on()
        if not on:
            return
        mx = min(o.x for o in on)
        my = min(o.y for o in on)
        for o in on:
            o.x -= mx
            o.y -= my

    def _relay(self, old):
        """Re-place every output at its CURRENT size, keeping the topology
        the OLD rects describe (layout_repack)."""
        new = {o.conn: (o.w, o.h) for o in self.on()}
        pos = self.repack(old, new)
        for o in self.on():
            if o.conn in pos:
                o.x, o.y = pos[o.conn]
        self.normalise()

    def rotate(self, o):
        old = {p.conn: p.rect() for p in self.on()}
        base = o.transform.replace("flipped-", "")
        i = QUARTER.index(base) if base in QUARTER else 0
        o.transform = QUARTER[(i + 1) % 4]
        self._relay(old)

    def swap(self, a, b):
        """Exchange the PLACES of two outputs, then re-pack at their own
        sizes, so a portrait and a landscape can trade sides."""
        old = {p.conn: p.rect() for p in self.on()}
        old[a.conn], old[b.conn] = old[b.conn], old[a.conn]
        self._relay(old)

    def faults(self):
        """True when the outputs that are on do not form one edge-joined,
        non-overlapping surface. A guide; `hwdp arrange` decides."""
        on = [o.rect() for o in self.on()]
        for i in range(len(on)):
            for j in range(i + 1, len(on)):
                if overlaps(on[i], on[j]):
                    return True
        seen, todo = {0}, [0]
        while todo:
            i = todo.pop()
            for j in range(len(on)):
                if j not in seen and touches(on[i], on[j]):
                    seen.add(j)
                    todo.append(j)
        return len(seen) != len(on)

    def placements(self):
        lines = []
        for o in self.outs:
            if o.on:
                lines.append("%s rotate %s at %d,%d"
                             % (o.conn, o.degrees(), o.x, o.y))
            else:
                lines.append("%s off" % o.conn)
        return lines


# --- move mode ---------------------------------------------------------------

def valid_spots(mover, others):
    """Every position along every other output's edges where the mover
    touches it, as (along-axis range) generators: (side, fixed, lo, hi)."""
    w, h = mover.w, mover.h
    for n in others:
        nx, ny, nw, nh = n.rect()
        yield ("x", nx + nw, ny - h + 1, ny + nh - 1)     # right of n
        yield ("x", nx - w, ny - h + 1, ny + nh - 1)      # left of n
        yield ("y", ny + nh, nx - w + 1, nx + nw - 1)     # below n
        yield ("y", ny - h, nx - w + 1, nx + nw - 1)      # above n


def nearest_valid(mover, others, cx, cy):
    """The touching, non-overlapping position nearest (cx, cy)."""
    best = None
    for axis, fixed, lo, hi in valid_spots(mover, others):
        if axis == "x":
            x, y = fixed, min(max(cy, lo), hi)
        else:
            x, y = min(max(cx, lo), hi), fixed
        r = (x, y, mover.w, mover.h)
        if any(overlaps(r, n.rect()) for n in others):
            continue
        d = (x - cx) ** 2 + (y - cy) ** 2
        if best is None or d < best[0]:
            best = (d, x, y)
    return None if best is None else best[1:]


def axis(o, ax):
    """An output's (start, length) along one axis."""
    return (o.x, o.w) if ax == "x" else (o.y, o.h)


def snaps(mover, others, ax):
    """The positions along AX where the mover lines up with another output:
    flush against either of its edges, or aligned with its start, end or
    centre. A coarse step stops at the first of these it would pass."""
    size = axis(mover, ax)[1]
    found = set()
    for n in others:
        a, ln = axis(n, ax)
        found.update((a - size, a + ln, a, a + ln - size,
                      a + (ln - size) // 2))
    return found


def at(mover, ax, v):
    """The mover's rect with its AX position replaced by V."""
    return (v, mover.y, mover.w, mover.h) if ax == "x" else \
        (mover.x, v, mover.w, mover.h)


def turn_corner(mover, others, ax, d):
    """Sliding along a neighbour's edge and off its end: the place on that
    neighbour's next side, aligned with the corner just passed (moving down
    the right side of n lands below n, right edges aligned). None when no
    neighbour it was sliding along has such a place free."""
    pa = "y" if ax == "x" else "x"         # the axis it is beside n on
    for n in others:
        if not touches(mover.rect(), n.rect()):
            continue
        ms, ml = axis(mover, pa)
        ns, nl = axis(n, pa)
        if ms == ns + nl:                  # mover after n on that axis
            p = ns + nl - ml
        elif ms + ml == ns:                # mover before n
            p = ns
        else:
            continue                       # touching along AX, not beside
        a, ln = axis(n, ax)
        v = a + ln if d > 0 else a - axis(mover, ax)[1]
        r = (v, p, mover.w, mover.h) if ax == "x" else \
            (p, v, mover.w, mover.h)
        if touches(r, n.rect()) and \
                not any(overlaps(r, o.rect()) for o in others):
            return r[0], r[1]
    return None


def step(desk, mover, dx, dy, snap=True):
    """Move one step along one axis. A coarse step (SNAP) stops early at the
    first alignment it would pass, so a monitor goes FLUSH before anything
    else. A step into a neighbour stops flush against it; only one taken
    from flush jumps to that neighbour's far side (how a monitor gets past
    another). Sliding off the end of a neighbour's edge turns the corner
    onto its next side. A step that would touch nothing goes nowhere."""
    others = [o for o in desk.on() if o is not mover]
    if not others:
        return
    ax = "x" if dx else "y"
    d = dx or dy
    cur = axis(mover, ax)[0]
    v = cur + d
    if snap:
        sign = 1 if d > 0 else -1
        ahead = [s for s in snaps(mover, others, ax)
                 if 0 < (s - cur) * sign <= abs(d)]
        if ahead:
            v = min(ahead, key=lambda s: abs(s - cur))
    hit = [n for n in others if overlaps(at(mover, ax, v), n.rect())]
    if hit:
        # The nearest thing in the way: flush against it, or past it when
        # already flush (the first step into it moved nothing yet).
        flush = [(a - axis(mover, ax)[1]) if d > 0 else (a + ln)
                 for a, ln in (axis(n, ax) for n in hit)]
        stop = min(flush, key=lambda s: abs(s - cur))
        if stop != cur:
            v = stop
        else:
            n = hit[flush.index(stop)]
            a, ln = axis(n, ax)
            v = a + ln if d > 0 else a - axis(mover, ax)[1]
    r = at(mover, ax, v)
    spot = (r[0], r[1])
    if any(overlaps(r, n.rect()) for n in others):
        spot = nearest_valid(mover, others, r[0], r[1])
    elif not any(touches(r, n.rect()) for n in others):
        # Adrift already (something it touched moved away): the nearest
        # place it touches anything, so one key brings it back flush.
        adrift = not any(touches(mover.rect(), n.rect()) for n in others)
        spot = nearest_valid(mover, others, r[0], r[1]) if adrift else \
            turn_corner(mover, others, ax, d)
    if spot is None:
        return
    mover.x, mover.y = spot
    desk.normalise()


def contacts(mover, others):
    """In words, what the mover is flush against and how it lines up, so
    a snap is visible as well as made."""
    said = []
    for n in others:
        if not touches(mover.rect(), n.rect()):
            continue
        if mover.x == n.x + n.w or mover.x + mover.w == n.x:
            side = "right of" if mover.x == n.x + n.w else "left of"
            ax, ends = "y", ("tops", "bottoms")
        else:
            side = "below" if mover.y == n.y + n.h else "above"
            ax, ends = "x", ("lefts", "rights")
        (ms, ml), (ns, nl) = axis(mover, ax), axis(n, ax)
        how = [e + " aligned" for e, hit in
               zip(ends, (ms == ns, ms + ml == ns + nl)) if hit]
        if not how and abs(2 * ms + ml - 2 * ns - nl) <= 1:
            how = ["centred"]
        said.append("%s %s: %s" % (side, n.label, " and ".join(how)
                                   or "offset %+d" % (ms - ns)))
    return "  ".join(said) or "touching nothing"


def near_misses(desk, reach):
    """Facing edges of two outputs that are on, apart by less than REACH and
    overlapping along the edge: valid (each touches something) but a strip
    the pointer cannot cross, which reads as a broken edge. A guide."""
    on = desk.on()
    found = []
    for i, a in enumerate(on):
        for b in on[i + 1:]:
            for ax, pa in (("x", "y"), ("y", "x")):
                (s1, l1), (s2, l2) = axis(a, ax), axis(b, ax)
                g = max(s2 - (s1 + l1), s1 - (s2 + l2))
                (p1, q1), (p2, q2) = axis(a, pa), axis(b, pa)
                if 0 < g < reach and span(p1, p1 + q1, p2, p2 + q2) > 0:
                    found.append((a.label, b.label, g))
    return found


# --- surfaces: named parts of a monitor --------------------------------------

# What the wallpaper picker lists: the images the wallpaper plugin draws.
IMAGE_SUFFIXES = (".jpg", ".jpeg", ".png", ".webp")

REGIONS = ("full", "top", "bottom", "left", "right")
# A panel's SPLIT in one cell: whole (None), or the two halves it is cut
# into. `g` cycles them in this order; Tab walks the halves.
SPLITS = (None, "top-bottom", "left-right")
HALVES = {None: ("full",), "top-bottom": ("top", "bottom"),
          "left-right": ("left", "right")}
SPLIT_OF = {"top": "top-bottom", "bottom": "top-bottom",
            "left": "left-right", "right": "left-right"}
# `hwdp surfaces --map` gives a region as fractions of its panel.
REGION_OF = {(0, 0, 1, 1): "full", (0, 0, 1, 0.5): "top",
             (0, 0.5, 1, 0.5): "bottom", (0, 0, 0.5, 1): "left",
             (0.5, 0, 0.5, 1): "right"}
NEW_GRID = (3, 3)       # a desk that sets no grid starts here (the user's)


class Surface:
    def __init__(self, name, conn, region, cx, cy):
        self.name, self.conn, self.region = name, conn, region
        self.cx, self.cy = cx, cy

    def key(self):
        return (self.name, self.conn, self.region, self.cx, self.cy)


def clashes(a, b):
    """The same part of one monitor in one cell; opposite halves do not.
    The writer decides; this only answers the form at once."""
    if (a.conn, a.cx, a.cy) != (b.conn, b.cx, b.cy):
        return False
    pair = {a.region, b.region}
    return not (pair == {"top", "bottom"} or pair == {"left", "right"})


def region_rect(region, w, h):
    """Where a region sits inside a w x h output (halves, as hwdp does)."""
    return {"full": (0, 0, w, h), "top": (0, 0, w, h // 2),
            "bottom": (0, h // 2, w, h - h // 2),
            "left": (0, 0, w // 2, h),
            "right": (w // 2, 0, w - w // 2, h)}[region]
