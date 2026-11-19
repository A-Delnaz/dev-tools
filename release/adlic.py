#!/usr/bin/env python3
"""
adlic.py - A-Delnaz licence file (.adlic), format 1.  See docs/UPDATES-AND-LICENSES.md, parts 1-2 and 2-3.

A licence belongs to ONE installation: it is encrypted with a key made from that installation's
install code, so it opens nowhere else, and it is signed with the licence key of the key store,
so it cannot be changed or made by anybody else.

    "ADLC" | 0x01 | IV (16 bytes) | ciphertext
    key        = HKDF-SHA256(ikm = licence secret of the product, salt = install code, info = "adlic-v1")
    ciphertext = AES-256-CBC + PKCS7 of:  body_len (uint32, little-endian) | body (JSON, UTF-8) | signature (64)
    signature  = Ed25519 (licence signing key) over b"ADLC1" + body

Install code: 120 random bits as 24 Crockford base32 characters + 1 check character,
shown as XXXXX-XXXXX-XXXXX-XXXXX-XXXXX. Typing errors (O/0, I/L/1, spaces, dashes) are tolerated.

Commands (messages are English, like all terminal scripts):
    adlic.py install-code                                   a new install code (for tests)
    adlic.py issue  --store KEYSTORE --keys update-keys.json --install-code CODE --licensee "Company"
                    [--alias "Other name"]... [--type full|trial] [--modules "*" | "ca,dns"]
                    [--module-until ca=2027-03-21]... [--use-until DATE|never] [--updates-until DATE|never]
                    [--support-until DATE|never] [--max-activations 2] --out FILE.adlic
    adlic.py wizard --store KEYSTORE --keys update-keys.json [--out-dir FOLDER]   asks everything
    adlic.py read   FILE --keys update-keys.json --install-code CODE              checks and shows a licence

Dates are Gregorian (YYYY-MM-DD). "never" = no end. The passphrase can come from ADKEYS_PASSPHRASE.
Products copy the reading part (normalize_code, check_code, read_license) into their own code.
Needs the "cryptography" package.
"""

import argparse
import base64
import json
import os
import secrets
import struct
import sys
import uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, padding
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

MAGIC = b"ADLC"
FORMAT = 1
SIGN_PREFIX = b"ADLC1"
MAX_BODY = 64 * 1024
ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"     # Crockford base32 (no I, L, O, U)


class LicenceError(Exception):
    """The file is not a valid licence for this installation (other installation, changed, or wrong keys)."""


# ---------------------------------------------------------------
#  Install code
# ---------------------------------------------------------------

def _check_char(chars):
    return ALPHABET[sum((i + 1) * ALPHABET.index(c) for i, c in enumerate(chars)) % 32]


def new_install_code():
    data = "".join(secrets.choice(ALPHABET) for _ in range(24))
    raw = data + _check_char(data)
    return "-".join(raw[i:i + 5] for i in range(0, 25, 5))


def normalize_code(text):
    """Upper case, without spaces and dashes; O->0, I/L->1. Returns the 25 characters or ''."""
    raw = "".join(str(text or "").upper().split()).replace("-", "")
    raw = raw.replace("O", "0").replace("I", "1").replace("L", "1")
    if len(raw) != 25 or any(c not in ALPHABET for c in raw):
        return ""
    return raw


def check_code(text):
    """True when the install code is complete and its check character is right."""
    raw = normalize_code(text)
    return bool(raw) and _check_char(raw[:24]) == raw[24]


def format_code(text):
    raw = normalize_code(text)
    return "-".join(raw[i:i + 5] for i in range(0, 25, 5)) if raw else ""


# ---------------------------------------------------------------
#  Keys
# ---------------------------------------------------------------

def b64key(text, name):
    try:
        raw = base64.b64decode((text or "").strip(), validate=True)
    except ValueError:
        raw = b""
    if len(raw) != 32:
        raise LicenceError(f"{name} is missing or not a valid 32-byte base64 key.")
    return raw


def file_key(secret, install_code):
    raw = normalize_code(install_code)
    if not raw:
        raise LicenceError("The install code is not valid.")
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=raw.encode(), info=b"adlic-v1").derive(secret)


# ---------------------------------------------------------------
#  Write
# ---------------------------------------------------------------

def make_license(body, signing_key, secret):
    """The bytes of a .adlic file. body must contain install_code."""
    body = dict(body)
    body["format"] = FORMAT
    body["install_code"] = format_code(body.get("install_code"))
    if not check_code(body["install_code"]):
        raise LicenceError("The install code is not valid (check the characters).")
    data = json.dumps(body, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    signature = Ed25519PrivateKey.from_private_bytes(signing_key).sign(SIGN_PREFIX + data)
    plain = struct.pack("<I", len(data)) + data + signature
    iv = os.urandom(16)
    padder = padding.PKCS7(128).padder()
    enc = Cipher(algorithms.AES(file_key(secret, body["install_code"])), modes.CBC(iv)).encryptor()
    return MAGIC + bytes([FORMAT]) + iv + enc.update(padder.update(plain) + padder.finalize()) + enc.finalize()


# ---------------------------------------------------------------
#  Read (products copy this part)
# ---------------------------------------------------------------

def read_license(data, secret, public_key, install_code, product=None):
    """Checks a licence (bytes of the file) for this installation. Returns its body."""
    if len(data) < 5 + 16 + 16 or data[:4] != MAGIC:
        raise LicenceError("This is not a licence file.")
    if data[4] != FORMAT:
        raise LicenceError(f"Unknown licence format {data[4]}. Update the program first.")
    if (len(data) - 21) % 16 or len(data) > MAX_BODY * 2:
        raise LicenceError("The licence file is damaged.")
    try:
        dec = Cipher(algorithms.AES(file_key(secret, install_code)), modes.CBC(data[5:21])).decryptor()
        unpadder = padding.PKCS7(128).unpadder()
        plain = unpadder.update(dec.update(data[21:]) + dec.finalize()) + unpadder.finalize()
        size = struct.unpack("<I", plain[:4])[0]
        if size > MAX_BODY or len(plain) != 4 + size + 64:
            raise ValueError
        body_bytes, signature = plain[4:4 + size], plain[4 + size:]
    except (ValueError, struct.error) as exc:
        raise LicenceError("This licence was made for another installation (other install code), or it is damaged.") from exc
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(signature, SIGN_PREFIX + body_bytes)
    except InvalidSignature as exc:
        raise LicenceError("The signature is not valid: this licence was changed or not made by the publisher.") from exc
    body = json.loads(body_bytes.decode("utf-8"))
    if normalize_code(body.get("install_code")) != normalize_code(install_code):
        raise LicenceError("This licence was made for another installation (other install code).")
    if product and body.get("product") != product:
        raise LicenceError(f"This licence is for '{body.get('product')}', not for this program.")
    return body


def parse_day(text):
    """'YYYY-MM-DD' -> date, empty / None / 'never' -> None"""
    if text in (None, "", "never"):
        return None
    return date.fromisoformat(str(text)[:10])


# ---------------------------------------------------------------
#  Command line
# ---------------------------------------------------------------

def _utf8_console():
    """Windows consoles (also on GitHub) use an old code page: Persian text would crash print()."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def _product_keys(path):
    data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    if not data.get("license_public_key") or not data.get("license_secret"):
        raise LicenceError(f"{path} has no licence keys yet: run dev.cmd option K in this project once.")
    return data


def _day_arg(text, name):
    try:
        return None if text in (None, "", "never") else date.fromisoformat(text).isoformat()
    except ValueError as exc:
        raise LicenceError(f"{name}: '{text}' is not a date (YYYY-MM-DD) or 'never'.") from exc


def build_body(product, install_code, licensee, aliases=(), kind="full", modules="*", module_until=(),
               use_until=None, updates_until=None, support_until=None, max_activations=1, note=""):
    mods = {}
    for m in [x.strip() for x in str(modules or "*").split(",") if x.strip()]:
        mods[m] = None
    for item in module_until:
        name, _, day = item.partition("=")
        mods[name.strip()] = _day_arg(day.strip(), f"module {name}")
    if kind not in ("full", "trial"):
        raise LicenceError("type must be 'full' or 'trial'.")
    if kind == "trial" and not _day_arg(use_until, "use until"):
        raise LicenceError("A trial licence needs an end date (use until), not 'never'.")
    return {
        "license_id": str(uuid.uuid4()),
        "product": product,
        "licensee": {"name": licensee.strip(), "aliases": [a.strip() for a in aliases if a.strip()]},
        "install_code": format_code(install_code),
        "type": kind,
        "modules": mods or {"*": None},
        "use_until": _day_arg(use_until, "use until"),
        "updates_until": _day_arg(updates_until, "updates until"),
        "support_until": _day_arg(support_until, "support until"),
        "max_activations": int(max_activations),
        "issued_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "note": note,
    }


def _signing_key(store):
    sys.path.insert(0, str(Path(__file__).parent))
    import keys  # same folder
    passphrase = keys._passphrase()
    try:
        return keys.unlock(store, passphrase)["license"]
    except keys.KeyError_ as exc:
        raise LicenceError(str(exc)) from exc


def _write(path, body, store, prod):
    data = make_license(body, _signing_key(store), b64key(prod["license_secret"], "license_secret"))
    # check it again exactly as the product will
    read_license(data, b64key(prod["license_secret"], "license_secret"), b64key(prod["license_public_key"], "license_public_key"),
                 body["install_code"], product=prod["product"])
    Path(path).write_bytes(data)
    return path


def _ask(question, default=""):
    hint = f" [{default}]" if default else ""
    answer = input(f"{question}{hint}: ").strip()
    return answer or default


def wizard(store, keys_file, out_dir):
    prod = _product_keys(keys_file)
    print(f"New licence for '{prod['product']}'. Dates are YYYY-MM-DD, or 'never'.")
    while True:
        code = _ask("Install code of the customer (from its licence page)")
        if check_code(code):
            break
        print("  This install code is not valid (a character is wrong or missing). Try again.")
    licensee = _ask("Customer (company name, as it should appear)")
    aliases = [a for a in _ask("Other spellings of the name, separated by ;", "").split(";") if a.strip()]
    kind = _ask("Type: full or trial", "full").lower()
    today = date.today()
    if kind == "trial":
        days = int(_ask("Trial days", "30"))
        use_until = (today + timedelta(days=days)).isoformat()
        updates_until = support_until = use_until
    else:
        use_until = _ask("Use until", "never")
        updates_until = _ask("Updates until", (today + timedelta(days=365)).isoformat())
        support_until = _ask("Support until", updates_until)
    modules = _ask("Modules: * = all, or a list like ca,dns", "*")
    max_act = _ask("Installations allowed for this customer", "2")
    body = build_body(prod["product"], code, licensee, aliases, kind, modules, (), use_until, updates_until,
                      support_until, max_act)
    safe = "".join(c if c.isalnum() or c in "-_" else "-" for c in licensee)[:40].strip("-") or "licence"
    out = Path(out_dir) / f"{prod['product']}-{safe}-{normalize_code(code)[:5]}.adlic"
    _write(out, body, store, prod)
    print(f"Licence written: {out}")
    print("Send this file to the customer. They load it on the licence page of the program.")
    return out


def main(argv=None):
    _utf8_console()
    p = argparse.ArgumentParser(description="A-Delnaz licence file (.adlic)")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("install-code")
    i = sub.add_parser("issue")
    i.add_argument("--store", required=True)
    i.add_argument("--keys", required=True)
    i.add_argument("--install-code", required=True)
    i.add_argument("--licensee", required=True)
    i.add_argument("--alias", action="append", default=[])
    i.add_argument("--type", default="full", choices=("full", "trial"))
    i.add_argument("--modules", default="*")
    i.add_argument("--module-until", action="append", default=[])
    i.add_argument("--use-until", default="never")
    i.add_argument("--updates-until", default="never")
    i.add_argument("--support-until", default="never")
    i.add_argument("--max-activations", default="1")
    i.add_argument("--note", default="")
    i.add_argument("--out", required=True)
    w = sub.add_parser("wizard")
    w.add_argument("--store", required=True)
    w.add_argument("--keys", required=True)
    w.add_argument("--out-dir", default=".")
    r = sub.add_parser("read")
    r.add_argument("file")
    r.add_argument("--keys", required=True)
    r.add_argument("--install-code", required=True)
    args = p.parse_args(argv)
    try:
        if args.cmd == "install-code":
            print(new_install_code())
        elif args.cmd == "issue":
            prod = _product_keys(args.keys)
            body = build_body(prod["product"], args.install_code, args.licensee, args.alias, args.type, args.modules,
                              args.module_until, args.use_until, args.updates_until, args.support_until,
                              args.max_activations, args.note)
            _write(args.out, body, args.store, prod)
            print(f"Licence written: {args.out}")
        elif args.cmd == "wizard":
            wizard(args.store, args.keys, args.out_dir)
        elif args.cmd == "read":
            prod = _product_keys(args.keys)
            body = read_license(Path(args.file).read_bytes(), b64key(prod["license_secret"], "license_secret"),
                                b64key(prod["license_public_key"], "license_public_key"), args.install_code, prod["product"])
            print(json.dumps(body, ensure_ascii=False, indent=2))
            print("Signature: valid. Install code: matches.")
        return 0
    except LicenceError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
