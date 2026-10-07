"""Exercise the asset gate with synthetic files, not App Store screenshots."""

import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

spec = importlib.util.spec_from_file_location("duo_screenshots", Path(__file__).resolve().parents[1] / "check_iphone_duo_screenshots.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def png(path, width, height, alpha=False):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    channels = 4 if alpha else 3
    row = b"\x00" + b"\xff" * width * channels
    path.write_bytes(b"\x89PNG\r\n\x1a\n"
                     + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6 if alpha else 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(row * height)) + chunk(b"IEND", b""))


class ScreenshotGateTests(unittest.TestCase):
    def test_empty_directory_does_not_claim_readiness(self):
        with tempfile.TemporaryDirectory() as directory:
            errors, count = checker.check_directory(Path(directory))
            self.assertEqual(count, 0)
            self.assertTrue(errors)

    def test_real_png_headers_for_both_displays_are_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            png(root / "outer.png", 1398, 2034)
            png(root / "inner-landscape.png", 2853, 2007)
            self.assertEqual(checker.check_directory(root, require_both=True), ([], 2))

    def test_alpha_and_wrong_dimensions_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            png(root / "wrong-size.png", 400, 600)
            png(root / "transparent.png", 1398, 2034, alpha=True)
            errors, _ = checker.check_directory(root)
            self.assertTrue(any("dimensions" in error for error in errors))
            self.assertTrue(any("alpha" in error for error in errors))

    def test_both_displays_are_optional_and_locales_are_checked_separately(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for locale in ["en-US", "zh-Hans"]:
                (root / locale).mkdir()
                png(root / locale / "outer.png", 2034, 1398)
            self.assertEqual(checker.check_directory(root), ([], 2))
            errors, _ = checker.check_directory(root, require_both=True)
            self.assertEqual(len(errors), 2)

    def test_excess_assets_and_unreadable_images_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for index in range(11):
                (root / f"{index}.png").write_bytes(b"not an image")
            errors, _ = checker.check_directory(root)
            self.assertTrue(any("at most 10" in error for error in errors))
            self.assertTrue(any("cannot inspect" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
