"""Tests for adlic.py. Run:  python -m unittest discover release  (from the dev-tools folder)"""

import base64
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import adlic  # noqa: E402
import keys  # noqa: E402

PASS = "a long test passphrase"


class InstallCodeTests(unittest.TestCase):
    def test_new_codes_are_valid_and_different(self):
        codes = {adlic.new_install_code() for _ in range(200)}
        self.assertEqual(len(codes), 200)
        for c in codes:
            self.assertRegex(c, r"^[0-9A-Z]{5}(-[0-9A-Z]{5}){4}$")
            self.assertTrue(adlic.check_code(c))

    def test_typing_errors(self):
        c = adlic.new_install_code()
        self.assertTrue(adlic.check_code(c.lower().replace("-", " ")))
        self.assertTrue(adlic.check_code(c.replace("0", "O").replace("1", "I")))
        wrong = list(adlic.normalize_code(c))
        wrong[3] = "7" if wrong[3] != "7" else "8"
        self.assertFalse(adlic.check_code("".join(wrong)))   # one wrong character is found
        self.assertFalse(adlic.check_code(c[:-2]))           # too short


class LicenceTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.store = self.dir / "a-delnaz.adkeys"
        keys.create_store(self.store, PASS)
        self.keyfile = self.dir / "update-keys.json"
        self.prod, _ = keys.product_keys(self.store, "domainator", self.keyfile)
        self.secret = base64.b64decode(self.prod["license_secret"])
        self.public = base64.b64decode(self.prod["license_public_key"])
        self.signing = keys.unlock(self.store, PASS)["license"]
        self.code = adlic.new_install_code()

    def body(self, **kw):
        args = dict(product="domainator", install_code=self.code, licensee="شرکت پرستیژلند", aliases=["Prestige Land"],
                    kind="full", modules="ca,dns", module_until=["dns=2027-03-21"], use_until="never",
                    updates_until="2027-11-19", support_until="2027-11-19", max_activations=2)
        args.update(kw)
        return adlic.build_body(**args)

    def test_roundtrip(self):
        data = adlic.make_license(self.body(), self.signing, self.secret)
        b = adlic.read_license(data, self.secret, self.public, self.code.lower(), product="domainator")
        self.assertEqual(b["licensee"]["name"], "شرکت پرستیژلند")
        self.assertEqual(b["modules"], {"ca": None, "dns": "2027-03-21"})
        self.assertIsNone(b["use_until"])
        self.assertEqual(adlic.parse_day(b["updates_until"]).year, 2027)

    def test_not_readable(self):
        data = adlic.make_license(self.body(), self.signing, self.secret)
        for text in (b"domainator", b"2027", "پرستیژ".encode(), b"Prestige", self.code.encode()):
            self.assertNotIn(text, data)

    def test_other_installation(self):
        data = adlic.make_license(self.body(), self.signing, self.secret)
        with self.assertRaisesRegex(adlic.LicenceError, "another installation"):
            adlic.read_license(data, self.secret, self.public, adlic.new_install_code())

    def test_changed_or_forged(self):
        data = bytearray(adlic.make_license(self.body(), self.signing, self.secret))
        for pos in (25, len(data) // 2, len(data) - 3):
            bad = bytearray(data)
            bad[pos] ^= 1
            with self.assertRaises(adlic.LicenceError):
                adlic.read_license(bytes(bad), self.secret, self.public, self.code)
        # Forger knows the product secret (it is inside the program) but not the licence signing key
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        forged = adlic.make_license(self.body(modules="*"), Ed25519PrivateKey.generate().private_bytes_raw(), self.secret)
        with self.assertRaisesRegex(adlic.LicenceError, "signature"):
            adlic.read_license(forged, self.secret, self.public, self.code)

    def test_other_product_and_rules(self):
        data = adlic.make_license(self.body(), self.signing, self.secret)
        with self.assertRaisesRegex(adlic.LicenceError, "is for"):
            adlic.read_license(data, self.secret, self.public, self.code, product="security-reports")
        with self.assertRaises(adlic.LicenceError):
            self.body(kind="trial")                       # trial needs an end date
        with self.assertRaises(adlic.LicenceError):
            adlic.make_license(self.body(install_code="ABCDE-12345"), self.signing, self.secret)
        with self.assertRaises(adlic.LicenceError):
            self.body(updates_until="1405/08/28")         # Persian date is not accepted here

    def test_command_line(self):
        os.environ["ADKEYS_PASSPHRASE"] = PASS
        try:
            out = self.dir / "c.adlic"
            self.assertEqual(adlic.main(["issue", "--store", str(self.store), "--keys", str(self.keyfile),
                                         "--install-code", self.code, "--licensee", "Test Co", "--type", "trial",
                                         "--use-until", "2026-12-31", "--out", str(out)]), 0)
            self.assertEqual(adlic.main(["read", str(out), "--keys", str(self.keyfile), "--install-code", self.code]), 0)
            self.assertEqual(adlic.main(["read", str(out), "--keys", str(self.keyfile),
                                         "--install-code", adlic.new_install_code()]), 2)
        finally:
            del os.environ["ADKEYS_PASSPHRASE"]

    def test_wizard(self):
        import builtins
        answers = iter([self.code, "Test Co", "", "trial", "14", "*", "1"])
        old = builtins.input
        builtins.input = lambda prompt="": next(answers)
        os.environ["ADKEYS_PASSPHRASE"] = PASS
        try:
            out = adlic.wizard(self.store, self.keyfile, self.dir)
        finally:
            builtins.input = old
            del os.environ["ADKEYS_PASSPHRASE"]
        b = adlic.read_license(out.read_bytes(), self.secret, self.public, self.code)
        self.assertEqual(b["type"], "trial")
        self.assertIsNotNone(b["use_until"])


if __name__ == "__main__":
    unittest.main()
