"""Crop-sweep progress must not read past 100%, and 'work left' must be asked.

`done` counts SCAN LINES in the sweep log, so a film measured twice — re-keyed
by croptl_repair, or re-measured after substrip rewrote it — is counted twice.
On 2026-09-10 that put done at 271 against 263 films, which made the ops panel
read 271/263 and, worse, made `films - done` NEGATIVE. A negative "work left"
reads as "nothing to do", which would have permanently disabled the restart
that had just been built to recover a dead sweep.
"""
import importlib.util
import json
import pathlib
import sys
import tempfile
import time
import unittest

SRC = pathlib.Path(__file__).resolve().parent.parent / "scripts/codec_cropwarm.py"
spec = importlib.util.spec_from_file_location("cw", SRC)
cw = importlib.util.module_from_spec(spec)
sys.modules["cw"] = cw
spec.loader.exec_module(cw)


class Progress(unittest.TestCase):
    def setUp(self):
        self.real_log, self.real_running = cw.LOG, cw._running
        self.real_pending = cw.PENDING
        cw._running = lambda: 0
        # No fresh walk by default, so these exercise the fallback.
        cw.PENDING = pathlib.Path(tempfile.mkdtemp()) / "absent.json"

    def tearDown(self):
        cw.LOG, cw._running = self.real_log, self.real_running
        cw.PENDING = self.real_pending

    def _log(self, scans):
        import tempfile
        p = pathlib.Path(tempfile.mkdtemp()) / "sweep.log"
        p.write_text("".join(f"[{i}/{len(scans)}] one aspect (9s)  {n}\n"
                             for i, n in enumerate(scans, 1)))
        cw.LOG = p

    def test_rescans_do_not_push_progress_past_the_film_count(self):
        # Eight films measured twice, as happened tonight.
        self._log([f"f{i}.mkv" for i in range(263)] + [f"f{i}.mkv"
                                                       for i in range(8)])
        d = cw.status_data(total_films=263)
        self.assertEqual(d["done"], 271)          # the raw count is unchanged
        self.assertEqual(d["prog_at"], 263)       # the readout is honest
        self.assertLessEqual(d["prog_at"], d["prog_of"])

    def test_a_partly_measured_library_still_reads_partly(self):
        self._log([f"f{i}.mkv" for i in range(100)])
        d = cw.status_data(total_films=263)
        self.assertEqual((d["prog_at"], d["prog_of"]), (100, 263))

    def test_an_unmeasured_library_reads_zero(self):
        self._log([])
        self.assertEqual(cw.status_data(total_films=263)["prog_at"], 0)


class MeasuredFromAWalk(unittest.TestCase):
    """The clamp stopped the readout exceeding 100%, and in doing so pinned it
    AT 100% while real films sat unmeasured — 264/264 with three unscanned.
    `done` counts scan lines and cannot answer this; only a walk can."""

    def setUp(self):
        self.real_pending, self.real_running = cw.PENDING, cw._running
        self.real_log = cw.LOG
        cw._running = lambda: 0
        cw.PENDING = pathlib.Path(tempfile.mkdtemp()) / "pending.json"
        cw.LOG = pathlib.Path(tempfile.mkdtemp()) / "sweep.log"
        # 271 scan lines for 264 films: seven measured twice.
        cw.LOG.write_text("".join(f"[1/1] one aspect (9s)  f{i}.mkv\n"
                                  for i in range(271)))

    def tearDown(self):
        cw.PENDING, cw._running = self.real_pending, self.real_running
        cw.LOG = self.real_log

    def _walk(self, pending, films, age=0):
        cw.PENDING.write_text(json.dumps(
            {"t": time.time() - age, "pending": pending, "films": films}))

    def test_a_fresh_walk_beats_the_scan_line_count(self):
        self._walk(pending=3, films=264)
        d = cw.status_data(total_films=264)
        self.assertEqual((d["prog_at"], d["prog_of"]), (261, 264))
        self.assertEqual(d["done"], 271)      # raw count still reported

    def test_a_stale_walk_still_counts(self):
        # a stale walk understates (harmless); the scan-line clamp would read
        # "264/264 complete" with three unmeasured — hiding work (9855603)
        self._walk(pending=3, films=264, age=cw.PENDING_TTL + 60)
        self.assertEqual(cw.status_data(total_films=264)["prog_at"], 261)

    def test_no_walk_at_all_falls_back_to_the_clamp(self):
        cw.PENDING.unlink(missing_ok=True)
        self.assertEqual(cw.status_data(total_films=264)["prog_at"], 264)

    def test_films_imported_since_the_walk_show_as_outstanding(self):
        # The measured count stays valid; the denominator grows.
        self._walk(pending=0, films=264)
        d = cw.status_data(total_films=270)
        self.assertEqual((d["prog_at"], d["prog_of"]), (264, 270))

    def test_a_corrupt_cache_does_not_break_the_panel(self):
        cw.PENDING.write_text("{not json")
        self.assertEqual(cw.status_data(total_films=264)["prog_at"], 264)


if __name__ == "__main__":
    unittest.main()
