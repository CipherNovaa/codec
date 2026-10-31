"""A film still being written is not a film to measure.

The import rsyncs --inplace straight to the final name, so a half-transferred
title is a perfectly ordinary-looking file in a library root. At 04:51 on
2026-09-11 the pending list held Expendables (2010) at 45.96G with an mtime of
0 seconds ago while rsync was still pulling it. Measuring that costs a decode
and yields a timeline keyed to a size and mtime about to change — orphaned the
instant the transfer completes.
"""
import importlib.util
import os
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


class FakeServe:
    def __init__(self, warm):
        self.warm = set(warm)

    def _timeline_path(self, p):
        return pathlib.Path("/nonexistent") if p not in self.warm else \
            pathlib.Path(__file__)          # an existing path = "measured"


class Settle(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def _film(self, name, age_s):
        p = os.path.join(self.d, name)
        open(p, "wb").close()
        os.utime(p, (time.time() - age_s, time.time() - age_s))
        return p

    def test_a_file_being_written_right_now_is_skipped(self):
        landing = self._film("landing.mkv", 0)
        self.assertEqual(cw._unmeasured([landing], FakeServe([])), [])

    def test_a_settled_film_is_measured(self):
        settled = self._film("settled.mkv", cw.SETTLE_S + 60)
        self.assertEqual(cw._unmeasured([settled], FakeServe([])), [settled])

    def test_an_already_measured_film_is_not_repeated(self):
        f = self._film("done.mkv", cw.SETTLE_S + 60)
        self.assertEqual(cw._unmeasured([f], FakeServe([f])), [])

    def test_a_vanished_file_does_not_crash_the_sweep(self):
        self.assertEqual(cw._unmeasured(["/nonexistent/gone.mkv"],
                                        FakeServe([])), [])

    def test_the_count_and_the_sweep_cannot_disagree(self):
        # --pending-json and the sweep share this helper on purpose: a count
        # that included a file the sweep will skip would have the watcher start
        # a sweep that does nothing, once an hour, forever.
        landing = self._film("landing.mkv", 1)
        settled = self._film("settled.mkv", cw.SETTLE_S + 60)
        got = cw._unmeasured([landing, settled], FakeServe([]))
        self.assertEqual(got, [settled])
        self.assertEqual(len(got), 1)


if __name__ == "__main__":
    unittest.main()
