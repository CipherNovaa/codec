"""The DV progress signal must not go blind during the stage that moves most.

The watcher judges the drain alive on (position, stage, work_bytes). work_bytes
walked OUTDIR/.work only — but the mux writes its output to OUTDIR/*.partial,
so all three components sat still for the whole of stage 5. A healthy 30 MB/s
copy and a wedged one were indistinguishable, in both directions: the stall
alarm could not fire on a real wedge, and would eventually fire on a long
healthy mux. Measured 2026-09-10 22:10: .work unchanged across 25s while the
partial grew at 30 MB/s.
"""
import importlib.util
import os
import pathlib
import sys
import tempfile
import unittest

SRC = pathlib.Path(__file__).resolve().parent.parent / "scripts/codec_dv_normalize.py"
sys.path.insert(0, str(SRC.parent))   # it imports its siblings (codec_paths …)
spec = importlib.util.spec_from_file_location("dvn", SRC)
dvn = importlib.util.module_from_spec(spec)
sys.modules["dvn"] = dvn
spec.loader.exec_module(dvn)

G = 1024 ** 3


class WorkBytes(unittest.TestCase):
    def setUp(self):
        self.out = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.out, ".work", "title"))
        self.real_out, dvn.OUTDIR = dvn.OUTDIR, self.out
        # status_data reads the drain log; an empty one is enough here.
        pathlib.Path(self.out, "dvnorm.log").write_text("")
        self.real_log = getattr(dvn, "LOG", None)

    def tearDown(self):
        dvn.OUTDIR = self.real_out

    def _mk(self, rel, size):
        p = os.path.join(self.out, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.truncate(size)

    def _bytes(self):
        return dvn.status_data()["work_bytes"]

    def test_the_mux_output_counts_as_work_in_flight(self):
        self._mk(".work/title/base.hevc", 28 * G)
        before = self._bytes()
        self._mk("Some.Film.dvnorm.mkv.partial", 21 * G)
        self.assertEqual(self._bytes() - before, 21 * G)

    def test_a_growing_partial_moves_the_watchers_256mb_bucket(self):
        # The signal is work_bytes // 256MB. If a mux at 30 MB/s cannot move
        # that bucket, the drain reads as frozen for the whole stage.
        self._mk(".work/title/base.hevc", 28 * G)
        self._mk("Some.Film.dvnorm.mkv.partial", 21 * G)
        a = self._bytes() // (256 * 1024 ** 2)
        self._mk("Some.Film.dvnorm.mkv.partial", 21 * G + 900 * 1024 ** 2)
        self.assertGreater(self._bytes() // (256 * 1024 ** 2), a)

    def test_finished_titles_in_the_outdir_are_not_counted(self):
        # Only *.partial is in flight. A placed .mkv sitting in OUTDIR is not
        # scratch, and counting it would make work_bytes drift upward forever.
        self._mk(".work/title/base.hevc", 28 * G)
        before = self._bytes()
        self._mk("Already.Done.mkv", 30 * G)
        self.assertEqual(self._bytes(), before)

    def test_an_empty_outdir_is_zero_not_a_crash(self):
        self.assertEqual(self._bytes(), 0)


if __name__ == "__main__":
    unittest.main()
