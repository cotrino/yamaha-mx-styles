import hashlib
import io
import json
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

from catalog_styles import archive_entries, build, clean_name, display_name, midi_metadata, safe_member


def style():
    track = b"\x00\xff\x06\x06Main A\x00\x99\x24\x64\x60\x89\x24\x00\x00\xff\x2f\x00"
    return b"MThd" + struct.pack(">IHHH", 6, 0, 1, 96) + b"MTrk" + struct.pack(">I", len(track)) + track


class CatalogTests(unittest.TestCase):
    def test_metadata_and_running_status(self):
        metadata = midi_metadata(style())
        self.assertEqual(metadata["sections"], [{"name": "Main A", "tick": 0}])
        self.assertEqual(metadata["channels"], [10])
        self.assertEqual(metadata["quarter_notes"], 1)
        with self.assertRaises(ValueError):
            midi_metadata(b"not midi")

    def test_unsafe_paths(self):
        for name in ("../style.sty", "/style.sty", r"C:\style.sty", r"a\..\style.sty"):
            with self.assertRaises(ValueError):
                safe_member(name)
        self.assertEqual(clean_name("CON"), "_CON")
        self.assertNotIn("?", clean_name("What?"))
        self.assertEqual(display_name("Batida\u2560\xe2o"), "Batid\u00e3o")

    def test_recover_truncated_zip(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            archive.writestr("Dance/Style.sty", style())
        data = buffer.getvalue()
        data = data[:data.index(b"PK\x01\x02")]
        issues = []
        entries = list(archive_entries(data, "truncated.zip", issues))
        self.assertEqual(entries, [("Dance/Style.sty", style())])
        self.assertEqual(issues[0]["status"], "recovered-partial-archive")

    def test_build_deduplicates_and_retains_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Original.sty").write_bytes(style())
            with zipfile.ZipFile(root / "Jazz.zip", "w") as archive:
                archive.writestr("Jazz/Duplicate.PRS", style())
                archive.writestr("Jazz/manual.txt", "Supporting file")
                archive.writestr("__MACOSX/._Style.sty", "ignored")
            first = build(root, True)
            self.assertEqual(first["style_count"], 1)
            self.assertEqual(first["duplicates"], 1)
            row = first["styles"][0]
            self.assertEqual(hashlib.sha256((root / row["path"]).read_bytes()).hexdigest(), row["sha256"])
            self.assertTrue((root / "_Sources" / "Originals" / "Original.sty").exists())
            self.assertTrue((root / "_Sources" / "Originals" / "Jazz.zip").exists())
            second = build(root, True)
            self.assertEqual(first, second)
            self.assertEqual(json.loads((root / "catalog.json").read_text())["style_count"], 1)
            self.assertEqual(len(first["supporting_files"]), 1)

    def test_same_names_different_contents_are_distinct(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for folder, payload in (("one", style()), ("two", style() + b"CASM")):
                (root / folder).mkdir()
                (root / folder / "Same.sty").write_bytes(payload)
            result = build(root, True)
            self.assertEqual(result["style_count"], 2)
            self.assertEqual(len({r["path"].lower() for r in result["styles"]}), 2)


if __name__ == "__main__":
    unittest.main()
