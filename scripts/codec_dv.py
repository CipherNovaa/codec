#!/usr/bin/env python3
"""codec_dv — an interactive terminal app to browse, compare, and import Dolby
Vision (and HDR) titles for codec. It reuses codec_dv_normalize.py as its engine
(the same ffprobe-truth probe + the hub's real cast-lane check + the normalize
pipeline), and wraps it in a navigable, self-documenting TUI.

Design goals (so it's still obvious in 3 years):
  • Every key is shown in the footer, and `?` opens full help.
  • The right pane always explains the highlighted title — including a CASTABILITY
    checklist that shows WHY a file does or doesn't cast Dolby Vision.
  • Nothing destructive happens without a confirmation and a dry-run plan first.

Run:  codec_dv               → browse codec's whole library
      codec_dv <path> …      → browse a drive/folder/file (drag-and-drop friendly)
"""
import os
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import codec_dv_normalize as engine   # the probe/normalize engine

from rich.text import Text
from rich.table import Table as RTable
from textual import work, on
from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import (DataTable, Static, Footer, Header, ProgressBar,
                             Input, Label)


# ── castability: the "checkboxes" — why a file does/doesn't cast DV ───────────
STD_FPS = (23.976, 24.0, 25.0, 29.97, 30.0, 47.952, 48.0, 50.0, 59.94, 60.0)


def _std_fps(fps):
    return any(abs(fps - s) < 0.06 for s in STD_FPS)


def castability(p):
    """(checks, verdict, style) — checks is a list of (label, state, note) where
    state is True (pass), False (fail) or None (not applicable)."""
    dv = p["dv"]
    lane_dv = p["lane"] == "dv"
    has_dv = dv is not None
    checks = [
        ("HEVC video", (p["codec"] or "").lower() == "hevc", p["codec"] or "—"),
        ("10-bit", p["depth"] >= 10, p["pix"] or ""),
        ("HDR (PQ / HLG)", p["trc"] in ("smpte2084", "arib-std-b67"), p["trc"] or "—"),
        ("Dolby Vision RPU", has_dv, (dv["profile"] if dv else "no RPU")),
        ("single-layer", (dv["layers"] == "single") if has_dv else None,
         "" if not dv else ("BL only" if dv["layers"] == "single" else "has EL")),
        ("profile 8.x", str(dv["profile"]).startswith("8") if has_dv else None,
         dv["profile"] if dv else ""),
        ("regular keyframe GOP", lane_dv if has_dv else None,
         "irregular → normalize" if (has_dv and not lane_dv) else ""),
        # #60: an unparseable/empty r_frame_rate yields fps 0.0. That's UNKNOWN,
        # not "non-standard" — report it as N/A (None) rather than a hard fail.
        ("standard frame rate",
         (_std_fps(p["fps"]) if p["fps"] > 0 else None),
         (f"{p['fps']} fps" if p["fps"] > 0 else "unknown")),
    ]
    if lane_dv:
        return checks, "✅  CASTS DOLBY VISION — no encoding needed", "b green"
    # Only a KNOWN non-standard fps is a hard "won't normalize" reject; an unknown
    # fps (0.0) must not masquerade as one (it falsely rejected castable titles).
    if has_dv and p["fps"] > 0 and not _std_fps(p["fps"]):
        return checks, "✖  Can't cast DV — non-standard fps (won't normalize)", "b red"
    if has_dv:
        return checks, "⚠  NEEDS NORMALIZE — DV present but GOP is irregular", "b yellow"
    return checks, "—  Not a Dolby Vision title (HDR10 / SDR)", "dim"


def quality_key(p):
    """Rank for 'best-quality DV': DV-castable first, then bitrate, then size, then
    resolution height. Higher tuple sorts as the winner."""
    return (1 if p["lane"] == "dv" else 0, p["mbps"], p["sizeGB"], p["h"])


# ── the compare screen ───────────────────────────────────────────────────────
class CompareScreen(ModalScreen):
    BINDINGS = [("escape,q,c", "app.pop_screen", "close")]

    def __init__(self, items):
        super().__init__()
        self.items = items                       # [(name, p), …]

    def compose(self) -> ComposeResult:
        winner = max(self.items, key=lambda it: quality_key(it[1]))[0]
        t = RTable(title="COMPARE — winner = best-quality Dolby Vision",
                   expand=True, show_lines=True)
        t.add_column("field", style="dim", no_wrap=True)
        for name, p in self.items:
            head = name[:30] + ("  ★ KEEP" if name == winner else "")
            t.add_column(head, style=("b green" if name == winner else ""))

        def row(label, fn):
            t.add_row(label, *[fn(p) for _, p in self.items])

        row("cast lane", lambda p: str(p["lane"]).upper())
        row("Dolby Vision", lambda p: (f"profile {p['dv']['profile']}" if p["dv"] else "—"))
        row("resolution", lambda p: f"{p['w']}×{p['h']} ({p['res']})")
        row("bit depth", lambda p: f"{p['depth']}-bit")
        row("fps", lambda p: str(p["fps"]))
        row("bitrate", lambda p: f"{p['mbps']} Mb/s")
        row("size", lambda p: f"{p['sizeGB']} GB")
        row("HDR10", lambda p: (f"{p['max_nits']}nit CLL{p['maxcll']}"
                                if p["mastering"] else "—"))
        row("HDR10+", lambda p: "yes" if p["hdr10plus"] else "—")
        row("audio", lambda p: p["audio_short"])
        yield Vertical(Static(t), Static("  [dim]esc / c to close[/]"), id="cmpbox")


# ── the help screen ──────────────────────────────────────────────────────────
HELP = """[b]codec_dv — Dolby Vision library tool[/b]

[b]What it does[/b]
  Reads every title with ffprobe (real file metadata, never the filename) and
  asks the hub how it would actually cast. The right pane's CASTABILITY list
  shows WHY each file does or doesn't cast Dolby Vision.

[b]Status column[/b]
  [green]✓ dv[/green]  casts Dolby Vision natively — nothing to do
  [yellow]⚠[/yellow]      DV present but serves as HDR10 — needs normalize
  [dim]·[/dim]      not a Dolby Vision title (HDR10 / SDR)

[b]Keys[/b]
  ↑ ↓ / j k     move          /           filter (dv, 4k, atmos, needs-norm…)
  s             cycle sort     space       select / deselect a title
  c             compare selected (winner = best-quality DV)
  n             normalize the highlighted title (→ verified copy in _dvnorm)
  i             import selected → place into a library root (dry-run first)
  o             open another path / drag files in
  r             rescan          ?  this help          q  quit

[b]What happens to files[/b]
  normalize → a VERIFIED COPY in /mnt/Movies3/_dvnorm; your original is never
              touched. import → actually MOVES DV-ready titles into the library.
"""


class HelpScreen(ModalScreen):
    BINDINGS = [("escape,q,question_mark", "app.pop_screen", "close")]

    def compose(self) -> ComposeResult:
        yield Vertical(Static(HELP), Static("  [dim]esc to close[/]"), id="helpbox")


# ── open-path prompt ─────────────────────────────────────────────────────────
class OpenPath(ModalScreen):
    BINDINGS = [("escape", "app.pop_screen", "cancel")]

    def compose(self) -> ComposeResult:
        yield Vertical(
            Label("Open path(s) — type or DRAG files/folders here, then Enter:"),
            Input(placeholder="/mnt/Movies3/NEWDV   (space-separate several)",
                  id="pathin"),
            Static("  [dim]esc to cancel[/]"), id="openbox")

    def on_input_submitted(self, ev: Input.Submitted) -> None:
        import shlex
        try:
            paths = [p for p in shlex.split(ev.value) if p]
        except ValueError:
            paths = [ev.value]
        self.app.pop_screen()
        if paths:
            self.app.load_dirs(paths)


# ── the main app ─────────────────────────────────────────────────────────────
class CodecDV(App):
    CSS = """
    Screen { layout: vertical; }
    #body { height: 1fr; }
    #list { width: 3fr; }
    #detail { width: 2fr; padding: 0 1; border-left: solid $panel; }
    #scanbar { height: 1; padding: 0 1; display: none; }
    #scanbar.busy { display: block; }
    DataTable { height: 1fr; }
    #filterbar { height: 3; display: none; border-top: solid $panel; }
    #filterbar.busy { display: block; }
    ModalScreen { align: center middle; }
    #cmpbox, #helpbox, #openbox {
        width: 90%; max-width: 120; height: auto; max-height: 90%;
        background: $surface; border: round $primary; padding: 1 2;
    }
    """
    BINDINGS = [
        ("slash", "filter", "filter"),
        ("s", "sort", "sort"),
        ("space", "select", "select"),
        ("c", "compare", "compare"),
        ("n", "normalize", "normalize"),
        ("i", "import_sel", "import"),
        ("o", "open", "open path"),
        ("r", "rescan", "rescan"),
        ("question_mark", "help", "help"),
        ("q", "quit", "quit"),
    ]
    SORTS = ("title", "size", "lane", "bitrate")

    def __init__(self, dirs):
        super().__init__()
        self.dirs = dirs
        self.rows = []                 # master list of (name, p)
        self.view = []                 # filtered/sorted view currently shown
        self.selected = set()          # main paths selected
        self.sort_i = 0
        self.filter_s = ""

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Horizontal(id="body"):
            with Vertical(id="list"):
                yield ProgressBar(id="scanbar", show_eta=False)
                yield DataTable(id="table", cursor_type="row", zebra_stripes=True)
                with Vertical(id="filterbar"):
                    yield Input(placeholder="filter: dv · 4k · atmos · needs-norm · <text>",
                                id="filterin")
            yield Static("", id="detail")
        yield Footer()

    def on_mount(self) -> None:
        try:
            self.theme = "textual-ansi"     # inherit the terminal's own palette
        except Exception:
            pass
        self.title = "codec_dv"
        dt = self.query_one("#table", DataTable)
        dt.add_column("", key="sel", width=2)
        dt.add_column("ST", key="st", width=2)
        dt.add_column("LANE", key="lane", width=5)
        dt.add_column("DV", key="dv", width=6)
        dt.add_column("RES", key="res", width=6)
        dt.add_column("BIT", key="bit", width=5)
        dt.add_column("SIZE", key="size", width=7)
        dt.add_column("AUDIO", key="audio", width=17)
        dt.add_column("TITLE", key="title")
        self.load_dirs(self.dirs)

    # ── loading / scanning ──────────────────────────────────────────────────
    def load_dirs(self, dirs):
        self.dirs = dirs
        self.rows = []
        self.selected.clear()
        self.query_one("#table", DataTable).clear()
        self.scan(dirs)

    @work(thread=True, exclusive=True)
    def scan(self, dirs) -> None:
        titles = engine.discover_titles(dirs)
        self.call_from_thread(self._scan_begin, len(titles), dirs)
        rows = []
        done = 0
        with ThreadPoolExecutor(max_workers=8) as ex:
            futs = {ex.submit(engine.probe_title, m): (n, m) for n, m in titles}
            for fut in futs:
                n, m = futs[fut]
                try:
                    rows.append((n, fut.result()))
                except Exception:
                    pass
                done += 1
                self.call_from_thread(self._scan_tick, done)
        self.call_from_thread(self._scan_done, rows)

    def _scan_begin(self, total, dirs):
        src = ", ".join(dirs) if dirs else "codec library"
        self.sub_title = f"scanning {total} title(s) — {src}"
        bar = self.query_one("#scanbar", ProgressBar)
        bar.add_class("busy")
        bar.total = max(total, 1)
        bar.progress = 0

    def _scan_tick(self, done):
        self.query_one("#scanbar", ProgressBar).progress = done

    def _scan_done(self, rows):
        self.rows = rows
        self.query_one("#scanbar", ProgressBar).remove_class("busy")
        n_dv = sum(1 for _, p in rows if p["lane"] == "dv")
        n_norm = sum(1 for _, p in rows if p["needs_norm"])
        tot = sum(p["sizeGB"] for _, p in rows)
        self.sub_title = (f"{len(rows)} titles · {n_dv} DV-ready · "
                          f"{n_norm} need-normalize · {tot:.0f} GB")
        self._repaint()

    # ── painting the table ──────────────────────────────────────────────────
    def _passes(self, name, p):
        f = self.filter_s.strip().lower()
        if not f:
            return True
        for tok in f.split():
            if tok in ("dv", "dolby") and p["lane"] != "dv":
                return False
            elif tok in ("norm", "needs-norm", "needsnorm") and not p["needs_norm"]:
                return False
            elif tok in ("4k", "uhd") and p["res"] != "4K":
                return False
            elif tok == "atmos" and not any(a["atmos"] for a in p["audio"]):
                return False
            elif tok in ("hdr10+", "hdr10plus") and not p["hdr10plus"]:
                return False
            elif tok in ("sdr", "hdr10", "hdr") and tok not in (p["hdr"].lower()):
                return False
            elif tok not in ("dv", "dolby", "norm", "needs-norm", "needsnorm", "4k",
                             "uhd", "atmos", "hdr10+", "hdr10plus", "sdr", "hdr10", "hdr") \
                    and tok not in name.lower():
                return False
        return True

    def _repaint(self):
        view = [(n, p) for n, p in self.rows if self._passes(n, p)]
        skey = self.SORTS[self.sort_i]
        if skey == "title":
            view.sort(key=lambda r: r[0].lower())
        elif skey == "size":
            view.sort(key=lambda r: -r[1]["sizeGB"])
        elif skey == "bitrate":
            view.sort(key=lambda r: -r[1]["mbps"])
        else:  # lane — DV-ready first, then needs-norm, then rest
            view.sort(key=lambda r: (0 if r[1]["needs_norm"] else 1 if r[1]["lane"] == "dv"
                                     else 2, r[0].lower()))
        self.view = view
        dt = self.query_one("#table", DataTable)
        dt.clear()
        for name, p in view:
            if p["lane"] == "dv":
                st, sty = "✓", "green"
            elif p["needs_norm"]:
                st, sty = "⚠", "yellow"
            else:
                st, sty = "·", "dim"
            sel = "▣" if p["main"] in self.selected else "▢"
            dt.add_row(
                Text(sel, style="b" if p["main"] in self.selected else "dim"),
                Text(st, style=sty),
                Text(str(p["lane"]), style=sty),
                Text(p["dv"]["profile"] if p["dv"] else "—"),
                p["res"], f"{p['depth']}b", f"{p['sizeGB']:.1f}G",
                p["audio_short"][:16], Text(name),
                key=p["main"])
        self.sub_title = (f"{len(view)}/{len(self.rows)} shown · sort:{skey}"
                          + (f" · filter:{self.filter_s}" if self.filter_s else "")
                          + (f" · {len(self.selected)} selected" if self.selected else ""))
        if view:
            self._show_detail(view[0][1])

    # ── detail pane ─────────────────────────────────────────────────────────
    @on(DataTable.RowHighlighted)
    def _row_hi(self, ev: DataTable.RowHighlighted):
        p = next((p for n, p in self.view if p["main"] == ev.row_key.value), None)
        if p:
            self._show_detail(p)

    def _show_detail(self, p):
        checks, verdict, vstyle = castability(p)
        t = Text()
        name = os.path.basename(os.path.dirname(p["main"])) or os.path.basename(p["main"])
        t.append(name + "\n", style="b")
        total = int(p["dur"])
        hms = f"{total // 3600}:{(total % 3600) // 60:02d}:{total % 60:02d}"
        t.append(f"{p['sizeGB']} GB · {hms} · ~{p['mbps']} Mb/s\n\n", style="dim")
        t.append(f"{p['codec'].upper()} {p['vprofile']} · {p['depth']}-bit · "
                 f"{p['w']}×{p['h']} ({p['res']}) · {p['fps']} fps\n")
        t.append(f"{p['primaries']} / {p['trc']} / {p['matrix']}\n", style="dim")
        if p["dv"]:
            d = p["dv"]
            t.append(f"DV profile {d['profile']} · level {d['level']} · "
                     f"{d['layers']}-layer\n", style="cyan")
        h10 = []
        if p["mastering"]:
            h10.append(f"mastering {p['max_nits']}nit")
        if p["maxcll"] is not None:
            h10.append(f"MaxCLL {p['maxcll']} / FALL {p['maxfall']}")
        if p["hdr10plus"]:
            h10.append("HDR10+ dynamic")
        if h10:
            t.append("  ·  ".join(h10) + "\n", style="dim")
        t.append("\nCASTABILITY\n", style="b")
        for label, state, note in checks:
            mark, mstyle = ("✓", "green") if state else \
                ("–", "dim") if state is None else ("✗", "red")
            t.append("  ")
            t.append(mark, style=mstyle)
            t.append("  " + label.ljust(21))
            if note:
                t.append(note, style="dim")
            t.append("\n")
        t.append("\n")
        t.append(verdict + "\n", style=vstyle)
        t.append("\naudio\n", style="b")
        for i, a in enumerate(p["audio"], 1):
            ex = " Atmos" if a["atmos"] else " DTS:X" if a["dtsx"] else ""
            lang = f" [{a['lang']}]" if a["lang"] else ""
            t.append(f"  {i}. {a['codec']} {a['layout']}{ex}{lang}\n")
        if p["subs"]:
            t.append(f"subs: {len(p['subs'])} — "
                     + ", ".join((s['lang'] or s['codec']) for s in p['subs'][:8])
                     + "\n", style="dim")
        self.query_one("#detail", Static).update(t)

    # ── actions ─────────────────────────────────────────────────────────────
    def action_filter(self):
        bar = self.query_one("#filterbar")
        bar.add_class("busy")
        self.query_one("#filterin", Input).focus()

    @on(Input.Submitted, "#filterin")
    def _filter_submit(self, ev: Input.Submitted):
        self.filter_s = ev.value
        self.query_one("#filterbar").remove_class("busy")
        self.query_one("#table", DataTable).focus()
        self._repaint()

    def action_sort(self):
        self.sort_i = (self.sort_i + 1) % len(self.SORTS)
        self._repaint()

    def _cursor_p(self):
        dt = self.query_one("#table", DataTable)
        if not self.view:
            return None
        try:
            key = dt.coordinate_to_cell_key(dt.cursor_coordinate).row_key.value
        except Exception:
            return None
        return next((p for n, p in self.view if p["main"] == key), None)

    def action_select(self):
        p = self._cursor_p()
        if not p:
            return
        if p["main"] in self.selected:
            self.selected.discard(p["main"])
        else:
            self.selected.add(p["main"])
        self._repaint()

    def _sel_items(self):
        got = [(n, p) for n, p in self.rows if p["main"] in self.selected]
        if not got:
            p = self._cursor_p()
            if p:
                got = [(next(n for n, q in self.rows if q is p), p)]
        return got

    def action_compare(self):
        items = self._sel_items()
        if len(items) >= 2:
            self.push_screen(CompareScreen(items))
        else:
            self.notify("Select 2+ titles first (space), then compare.",
                        severity="warning")

    def action_normalize(self):
        p = self._cursor_p()
        if not p:
            return
        if not p["needs_norm"]:
            self.notify("This title doesn't need normalizing "
                        f"(lane={p['lane']}).", severity="information")
            return
        self.notify(f"Would normalize → verified copy in {engine.OUTDIR}. "
                    "Run the encode from a shell with the drives mounted:\n"
                    f"codec_dv_normalize.py --one \"{p['main']}\"", timeout=8)

    def action_import_sel(self):
        items = self._sel_items()
        if not items:
            self.notify("Select titles (space) to import.", severity="warning")
            return
        self.notify(f"{len(items)} title(s) queued. Import (with a dry-run first) "
                    "from a shell:\ncodec_dv_normalize.py --import <dir> --dest <libroot>",
                    timeout=8)

    def action_open(self):
        self.push_screen(OpenPath())

    def action_rescan(self):
        self.load_dirs(self.dirs)

    def action_help(self):
        self.push_screen(HelpScreen())


def main():
    dirs = [os.path.abspath(a) for a in sys.argv[1:]] or list(engine.ROOTS)
    CodecDV(dirs).run()


if __name__ == "__main__":
    main()
