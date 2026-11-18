"""Tests for keys.py. Run:  python -m unittest discover release  (from the dev-tools folder)"""

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
import keys  # noqa: E402

PASS = "a long test passphrase"


class KeyStoreTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.store = self.dir / "usb" / "a-delnaz.adkeys"
        keys.create_store(self.store, PASS)

    def test_unlock_and_wrong_passphrase(self):
        private = keys.unlock(self.store, PASS)
        self.assertEqual(set(private), {"update", "license"})
        with self.assertRaises(keys.KeyError_):
            keys.unlock(self.store, "wrong passphrase!!")
        text = self.store.read_text(encoding="utf-8")
        for raw in private.values():
            self.assertNotIn(base64.b64encode(raw).decode(), text)

    def test_never_overwritten_and_short_passphrase(self):
        with self.assertRaises(keys.KeyError_):
            keys.create_store(self.store, PASS)
        with self.assertRaises(keys.KeyError_):
            keys.create_store(self.dir / "other.adkeys", "short")

    def test_product_file_is_kept(self):
        out = self.dir / "update-keys.json"
        first, made = keys.product_keys(self.store, "security-reports", out)
        self.assertTrue(made)
        second, made = keys.product_keys(self.store, "security-reports", out)
        self.assertFalse(made)
        self.assertEqual(first["content_key"], second["content_key"])
        other = self.dir / "other.adkeys"
        keys.create_store(other, PASS)
        with self.assertRaises(keys.KeyError_):
            keys.product_keys(other, "security-reports", out)

    def test_signed_package_matches_product_file(self):
        out = self.dir / "update-keys.json"
        product, _ = keys.product_keys(self.store, "security-reports", out)
        signing = keys.unlock(self.store, PASS)["update"]
        payload = self.dir / "p.zip"
        with zipfile.ZipFile(payload, "w") as z:
            z.writestr("version.txt", "1.0.0")
        pkg = self.dir / "p.adup"
        content = base64.b64decode(product["content_key"])
        adup.pack(payload, pkg, {"product": "security-reports", "version": "1.0.0"}, signing, content)
        h = adup.read_header(pkg, content, base64.b64decode(product["public_key"]))
        self.assertEqual(h["version"], "1.0.0")

    def test_command_line(self):
        os.environ["ADKEYS_PASSPHRASE"] = PASS
        try:
            self.assertEqual(keys.main(["check", "--store", str(self.store)]), 0)
            self.assertEqual(keys.main(["product", "--store", str(self.store), "--product", "x", "--out", str(self.dir / "k.json")]), 0)
            self.assertEqual(json.loads((self.dir / "k.json").read_text())["product"], "x")
            os.environ["ADKEYS_PASSPHRASE"] = "wrong passphrase!!"
            self.assertEqual(keys.main(["secret", "--store", str(self.store), "--name", "update"]), 2)
        finally:
            del os.environ["ADKEYS_PASSPHRASE"]


if __name__ == "__main__":
    unittest.main()
