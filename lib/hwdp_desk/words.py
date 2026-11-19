"""hwdp desk: text both views show: the review, an error, a name."""
import re
import textwrap

from .model import REGIONS


def brief(why):
    """One line of WHY for the status line: hwdp's own summary, its last."""
    lines = [ln for ln in (why or "").splitlines() if ln.strip()]
    return lines[-1].strip() if lines else ""


def error_lines(d, width, height):
    """The error dialog's text: D's title, then what hwdp said, its
    `hwdp <cmd>: ` prefixes dropped, a run of the same line said once with
    its count, wrapped to WIDTH, and scrolled from d["top"] when it is
    taller than HEIGHT (which clamps d["top"])."""
    said, runs = [], []
    for ln in d["text"].splitlines():
        ln = re.sub(r"^\s*hwdp [a-z-]+: ", "", ln).strip()
        if not ln:
            continue
        if runs and runs[-1][0] == ln:
            runs[-1][1] += 1
        else:
            runs.append([ln, 1])
    for ln, n in runs:
        ln = ln if n == 1 else "%s (x%d)" % (ln, n)
        said += textwrap.wrap(ln, max(20, width - 6),
                              subsequent_indent="  ") or [""]
    foot = ["", "Enter or Esc closes"]
    room = max(1, height - 4 - len(foot))
    if len(said) > room:
        d["top"] = min(d["top"], len(said) - room)
        shown = said[d["top"]:d["top"] + room]
        foot = ["", "lines %d-%d of %d   arrows scroll   Enter or Esc closes"
                % (d["top"] + 1, d["top"] + len(shown), len(said))]
    else:
        d["top"], shown = 0, said
    return [d["title"], ""] + shown + foot


DEFAULT_WALL = "(default)"


def label_of(app, name):
    for n, lab in app.names:
        if n == name:
            return lab or name
    return name


def full_name(app, name):
    """NAME as the drawing shows it, uncut, with its label when that says
    more: what the line under a drawing spells out."""
    lab = label_of(app, name)
    return name if lab == name else "%s (%s)" % (name, lab)


def covered(app, o, cx, cy):
    """The regions of output O claimed in cell (cx, cy), and whether that
    covers it whole (full, or both halves of one split)."""
    rg = {x.region for x in app.surfaces
          if x.conn == o.conn and (x.cx, x.cy) == (cx, cy)}
    return rg, ("full" in rg or {"top", "bottom"} <= rg
                or {"left", "right"} <= rg)


def review_lines(app):
    """The map as it will be saved, cell by cell, then what is missing from
    it: the Review tab. Pure, so a test reads it without a screen."""
    out = ["grid %dx%d" % app.grid]
    d = app.default
    out.append("default: %s, %s of %s" % (d.name, d.region, app.plabel(d.conn))
               if d else "default: none (a cell nothing claims is a gap)")
    gaps = []
    for cy in range(app.grid[1]):
        for cx in range(app.grid[0]):
            out.append("")
            out.append("cell %d,%d  wallpaper %s" % (
                cx, cy, wall_words(app, (cx, cy))))
            for o in app.desk.on():
                here = sorted((x for x in app.surfaces if x.conn == o.conn
                               and (x.cx, x.cy) == (cx, cy)),
                              key=lambda x: REGIONS.index(x.region))
                rg, whole = covered(app, o, cx, cy)
                txt = "  ".join("%s %s" % (x.region, x.name) for x in here)
                if not whole:
                    if d and d.conn == o.conn:
                        txt += ("  " if txt else "") + "(rest: default)"
                    elif d:
                        txt += ("  " if txt else "") + "(rest: default " \
                            "on %s)" % app.plabel(d.conn)
                    else:
                        gaps.append("cell %d,%d %s" % (cx, cy, o.label))
                        txt += ("  " if txt else "") + "(GAP)"
                out.append("  %-6s %s  %s" % (o.label, o.token(), txt))
    problems = []
    unplaced = [n for n, _ in app.names if app.placed(n) == ([], False)]
    if unplaced:
        problems.append("not placed here: " + ", ".join(unplaced))
    if gaps:
        problems.append("%d gap(s) and no default: %s" %
                        (len(gaps), "; ".join(gaps[:6]) +
                         (" ..." if len(gaps) > 6 else "")))
    return ["NOTES"] + (problems or ["none: every cell is covered"]) + \
        [""] + out


def pick_words(app):
    """What the name picker's choice is for."""
    o, rg = app.vspot()
    if app.pick["mode"] == "place":
        return "Place on cell %d,%d, %s of %s" % (
            app.vcell[0], app.vcell[1], rg, o.label)
    return "The DEFAULT: %s of %s, every cell nothing claims" % (rg, o.label)


def where_words(app, n):
    """Where name N is at this desk, in full: its cells, and DEFAULT."""
    here, dflt = app.placed(n)
    at = "; ".join("cell %d,%d %s %s" % (x.cx, x.cy, x.conn, x.region)
                   for x in here)
    if dflt:
        at = (at + "; " if at else "") + "DEFAULT, %s %s" % (
            app.default.conn, app.default.region)
    return at or "not placed"


def delname_words(app):
    """The question before a name is deleted: (heading, the lines under
    it). Both views ask it in these words."""
    n = app.side_name()
    here, dflt = app.placed(n)
    return "Delete the name %s?" % n, [
        "It goes from EVERY desk's list; here it is %s." %
        ("placed %d time(s)%s" % (len(here), ", and the default"
                                 if dflt else "") if here or dflt
         else "not placed"),
        "A desk elsewhere that places it makes the save refuse."]


def unsplit_words(app):
    """The question before a panel with both halves placed is joined."""
    conn, cx, cy = app.dialog[1]
    here = [x.name for x in app.surfaces
            if (x.conn, x.cx, x.cy) == app.dialog[1]]
    return "Join %s again in cell %d,%d?" % (app.plabel(conn), cx, cy), [
        "Both halves are placed: %s." % ", ".join(here),
        "Joined, they become unplaced here (still in the list)."]


def selection_words(app):
    """The virtual tab's selection IN FULL, what a drawing cuts: the names
    first, then where they sit."""
    sel_o, sel_r = app.vspot()
    n = [full_name(app, x.name) for x in app.at_spot()]
    return "%s  in cell %d,%d  %s %s  %s" % (
        ", ".join(n) if n else "(empty)", app.vcell[0], app.vcell[1],
        sel_o.label, sel_o.token(), sel_r)


def wall_words(app, cell):
    """The wallpaper a cell shows, saying when it is the default's."""
    f, own = app.wall_at(cell)
    if own:
        return f
    return "%s %s" % (DEFAULT_WALL, f) if f else DEFAULT_WALL


def cell_words(app):
    """The selected cell's wallpaper, and the desk's default."""
    d = app.default
    return "wallpaper: %s   default: " % wall_words(app, app.vcell) + (
        "%s, %s of %s" % (full_name(app, d.name), d.region,
                          app.plabel(d.conn)) if d else "none")


def mark_of(app, n):
    """A name's marker: D the default here, N placed here N times, - not
    placed at this desk."""
    here, dflt = app.placed(n)
    return ("D" if dflt else "%d" % len(here) if here else "-"), \
        bool(here or dflt)
