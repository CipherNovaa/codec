"""The title key must be container-agnostic.

_title_key answers "is this the same title?" for lines written by six different
stages. It was .mkv-only, so every .mp4 in the queue (46 of them on 2026-09-10)
fell back to returning the whole log LINE — which carries a timestamp and a
per-stage prefix, so one title produced a different key on every line. Two
consequences, both silent: a finished .mp4 could not cancel its own [todo]
entry (counted as pending forever), and `current` named the PREVIOUS film for
the whole of an .mp4 title's multi-hour encode.
"""
import importlib.util
import pathlib
import sys
import unittest

SRC = pathlib.Path(__file__).resolve().parent.parent / "scripts/codec_dv_normalize.py"
sys.path.insert(0, str(SRC.parent))   # it imports its siblings (codec_paths …)
spec = importlib.util.spec_from_file_location("dvn", SRC)
dvn = importlib.util.module_from_spec(spec)
sys.modules["dvn"] = dvn
spec.loader.exec_module(dvn)

K = dvn._title_key

# Real lines, copied from /mnt/Movies7/_dvnorm/dvnorm.log.
MP4 = "Zombieland.Double.Tap.2019.UHD.BluRay.2160p.DDP.7.1.DV.HDR.x265-BHDStudio.mp4"
MKV = "Zombieland.2009.4K.HDR.DV.2160p.BDRemux Ita Eng x265-NAHOM.mkv"


class TitleKey(unittest.TestCase):
    def test_every_stage_agrees_on_one_mp4_title(self):
        lines = [
            f"20:39:02 [1/6] extract video ES … /mnt/Movies2/{MP4}",
            f"   [todo] /mnt/Movies2/{MP4}",
            f"22:10:44 ✅ DONE {MP4}",
            f"22:10:45 ↪ placed DV into library; original → /mnt/Movies6/_dvnorm-trash/{MP4}",
        ]
        self.assertEqual({K(l) for l in lines}, {MP4})

    def test_mkv_title_with_spaces_still_works(self):
        lines = [f"20:39:00 ✅ DONE {MKV}", f"   [todo] /mnt/Movies/{MKV}"]
        self.assertEqual({K(l) for l in lines}, {MKV})

    def test_done_cancels_todo_for_every_accepted_container(self):
        # This is the accounting that decides prog_of. If the key differs, the
        # title is pending forever and the drain never reports itself finished.
        for ext in (".mkv", ".mp4", ".m4v", ".mov", ".ts"):
            name = f"Some Film (2019) 2160p{ext}"
            with self.subTest(ext=ext):
                self.assertEqual(K(f"   [todo] /mnt/Movies3/{name}"),
                                 K(f"12:00:00 ✅ DONE {name}"))

    def test_key_set_covers_everything_the_scanner_accepts(self):
        # A container the scanner will hand us but the key extractor does not
        # know is exactly the bug this file exists for.
        for e in dvn.VIDEO_EXTS:
            self.assertIn(e.lstrip("."), dvn._SRC_EXT)

    def test_an_audio_tag_is_not_mistaken_for_a_container(self):
        name = "Some Film 2019 TrueHD.7.1 DTS x265.mkv"
        self.assertEqual(K(f"12:00:00 ✅ DONE {name}"), name)


if __name__ == "__main__":
    unittest.main()
