"""Tests for adup.py. Run:  python -m unittest release/test_adup.py  (from the dev-tools folder)"""

import base64
import json
import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import adup  # noqa: E402


def k(text):
    return base64.b64decode(text)


class AdupTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.keys = adup.new_keys()
        self.sign, self.pub, self.content = k(self.keys["signing_key"]), k(self.keys["public_key"]), k(self.keys["content_key"])

    def make_zip(self, size):
        path = self.dir / "payload.zip"
        with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as z:
            z.writestr("app/manage.py", "print('hi')")
            z.writestr("version.txt", "1.0.9")
            z.writestr("app/big.bin", os.urandom(size))
        return path

    def pack(self, payload, name="p.adup", version="1.0.9"):
        out = self.dir / name
        adup.pack(payload, out, {"product": "security-reports", "product_name": "Security Reports",
                                 "version": version, "released_at": "2026-11-18T12:00:00Z",
                                 "releases": [{"version": version, "notes": ["گزارش جدید"]}]},
                  self.sign, self.content)
        return out

    def test_roundtrip_small_and_large(self):
        for size in (10, 3 * 1024 * 1024 + 7):
            payload = self.make_zip(size)
            pkg = self.pack(payload)
            out = self.dir / "out.zip"
            h = adup.unpack(pkg, out, self.content, self.pub, product="security-reports")
            self.assertEqual(out.read_bytes(), payload.read_bytes())
            self.assertEqual(h["version"], "1.0.9")
            self.assertEqual(h["releases"][0]["notes"][0], "گزارش جدید")

    def test_nothing_readable(self):
        pkg = self.pack(self.make_zip(10))
        data = pkg.read_bytes()
        for text in (b"security", b"1.0.9", b"manage.py", b"PK\x03\x04", "گزارش".encode()):
            self.assertNotIn(text, data)

    def test_changed_byte_is_refused(self):
        payload = self.make_zip(200000)
        pkg = self.pack(payload)
        data = bytearray(pkg.read_bytes())
        for pos in (30, len(data) // 2, len(data) - 20):
            bad = self.dir / f"bad{pos}.adup"
            changed = bytearray(data)
            changed[pos] ^= 0x01
            bad.write_bytes(changed)
            with self.assertRaises(adup.PackageError):
                adup.unpack(bad, self.dir / "x.zip", self.content, self.pub)
            self.assertFalse((self.dir / "x.zip").exists())

    def test_wrong_keys_and_product(self):
        pkg = self.pack(self.make_zip(10))
        other = adup.new_keys()
        with self.assertRaises(adup.PackageError):
            adup.read_header(pkg, k(other["content_key"]), self.pub)
        with self.assertRaises(adup.PackageError):
            adup.read_header(pkg, self.content, k(other["public_key"]))
        with self.assertRaises(adup.PackageError):
            adup.unpack(pkg, self.dir / "x.zip", self.content, self.pub, product="network-status")

    def test_not_a_package(self):
        f = self.dir / "a.adup"
        f.write_bytes(b"hello world" * 10)
        with self.assertRaises(adup.PackageError):
            adup.read_header(f, self.content, self.pub)

    def test_index(self):
        payload = self.make_zip(10)
        self.pack(payload, "Security-Reports-1.0.9.adup", "1.0.9")
        self.pack(payload, "Security-Reports-1.0.10.adup", "1.0.10")
        (self.dir / "junk.adup").write_bytes(b"junk")
        idx = adup.write_index(self.dir, self.content, self.pub)
        self.assertEqual([v["version"] for v in idx["versions"]], ["1.0.10", "1.0.9"])
        self.assertEqual(json.loads((self.dir / "index.json").read_text(encoding="utf-8"))["product"], "security-reports")

    def test_command_line(self):
        payload = self.make_zip(10)
        env = {"ADUP_SIGNING_KEY": self.keys["signing_key"], "ADUP_PUBLIC_KEY": self.keys["public_key"],
               "ADUP_CONTENT_KEY": self.keys["content_key"]}
        old = dict(os.environ)
        os.environ.update(env)
        try:
            out = self.dir / "c.adup"
            self.assertEqual(adup.main(["pack", "--payload", str(payload), "--out", str(out), "--product", "security-reports",
                                        "--name", "Security Reports", "--version", "1.2.3"]), 0)
            self.assertEqual(adup.main(["inspect", str(out)]), 0)
            self.assertEqual(adup.main(["unpack", str(out), "--out", str(self.dir / "c.zip")]), 0)
            os.environ["ADUP_CONTENT_KEY"] = adup.new_keys()["content_key"]
            self.assertEqual(adup.main(["inspect", str(out)]), 2)
        finally:
            os.environ.clear()
            os.environ.update(old)


if __name__ == "__main__":
    unittest.main()
