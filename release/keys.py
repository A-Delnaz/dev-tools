#!/usr/bin/env python3
"""
keys.py - the key store of A-Delnaz (one file, kept on a USB stick, locked with a passphrase).

The store holds the two private keys (see docs/UPDATES-AND-LICENSES.md, part 1-3):
    update signing key   signs .adup update packages (also stored in GitHub secrets)
    licence signing key  signs .adlic licence files   (never leaves the USB stick)
Their public keys are stored unlocked, so a product key file can be made without the passphrase.

Commands (messages are English, like all terminal scripts):
    keys.py init    --store E:\\keys\\a-delnaz.adkeys        new store (asks a new passphrase twice)
    keys.py product --store ... --product security-reports --out update-keys.json
                    writes the key file of a product: public update key + a new content key
                    (an existing file is kept: its content key must never change)
    keys.py secret  --store ... --name update            prints a private key (asks the passphrase)
    keys.py check   --store ...                          asks the passphrase and checks it

The passphrase can also come from the environment variable ADKEYS_PASSPHRASE (for scripts).
Needs the "cryptography" package.
"""

import argparse
import base64
import getpass
import json
import os
import sys
from pathlib import Path

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

FORMAT = 1
KEY_NAMES = ("update", "license")
SCRYPT_N, SCRYPT_R, SCRYPT_P = 2 ** 15, 8, 1


class KeyError_(Exception):
    pass


def b64(raw):
    return base64.b64encode(raw).decode()


def _derive(passphrase, salt, n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P):
    return Scrypt(salt=salt, length=32, n=n, r=r, p=p).derive(passphrase.encode("utf-8"))


def _new_pair():
    private = Ed25519PrivateKey.generate()
    return private.private_bytes_raw(), private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)


def create_store(path, passphrase):
    path = Path(path)
    if path.is_dir():
        path = path / "a-delnaz.adkeys"
    if path.exists():
        raise KeyError_(f"{path} already exists. A key store is never overwritten.")
    if len(passphrase) < 10:
        raise KeyError_("The passphrase must have at least 10 characters.")
    private, public = {}, {}
    for name in KEY_NAMES:
        private[name], public[name] = _new_pair()
    salt, nonce = os.urandom(16), os.urandom(12)
    secret = json.dumps({k: b64(v) for k, v in private.items()}).encode()
    data = {
        "format": FORMAT,
        "public": {k: b64(v) for k, v in public.items()},
        "kdf": {"name": "scrypt", "salt": b64(salt), "n": SCRYPT_N, "r": SCRYPT_R, "p": SCRYPT_P},
        "nonce": b64(nonce),
        "secret": b64(AESGCM(_derive(passphrase, salt)).encrypt(nonce, secret, b"adkeys1")),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".part")
    tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
    os.replace(tmp, path)
    return data["public"]


def read_store(path):
    path = Path(path)
    if path.is_dir():
        raise KeyError_(f"{path} is a folder. Give the key store FILE, for example {path / 'a-delnaz.adkeys'}")
    if not path.exists():
        raise KeyError_(f"Key store not found: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("format") != FORMAT:
            raise ValueError
        return data
    except ValueError as exc:
        raise KeyError_(f"{path} is not a key store.") from exc


def unlock(path, passphrase):
    """The private keys (dict of raw bytes). Wrong passphrase -> KeyError_."""
    data = read_store(path)
    kdf = data["kdf"]
    key = _derive(passphrase, base64.b64decode(kdf["salt"]), kdf["n"], kdf["r"], kdf["p"])
    try:
        secret = AESGCM(key).decrypt(base64.b64decode(data["nonce"]), base64.b64decode(data["secret"]), b"adkeys1")
    except InvalidTag as exc:
        raise KeyError_("Wrong passphrase.") from exc
    return {k: base64.b64decode(v) for k, v in json.loads(secret).items()}


def product_keys(store, product, out):
    """
    Writes the key file of a product: update keys and licence keys.
    An existing file is kept (its content key and licence secret must never change);
    keys that are missing in it (for example the licence keys of an older file) are added.
    Returns (data, "created" | "updated" | "kept").
    """
    out = Path(out)
    public = read_store(store)["public"]
    if out.exists():
        data = json.loads(out.read_text(encoding="utf-8"))
        if data.get("public_key") != public["update"]:
            raise KeyError_(f"{out} was made with another key store. Use that store, or ask for help.")
        if data.get("license_public_key") and data["license_public_key"] != public["license"]:
            raise KeyError_(f"The licence key in {out} belongs to another key store.")
        if data.get("license_public_key") and data.get("license_secret"):
            return data, "kept"
        data["license_public_key"] = public["license"]
        data["license_secret"] = b64(os.urandom(32))
        state = "updated"
    else:
        data = {"product": product, "public_key": public["update"], "content_key": b64(os.urandom(32)),
                "license_public_key": public["license"], "license_secret": b64(os.urandom(32))}
        state = "created"
    data["_comment"] = ("Keys of the update packages (.adup) and licence files (.adlic). Public: safe in the "
                        "repository. Made by dev.cmd option K. Never change the content key or the licence secret "
                        "of a released product.")
    ordered = {k: data[k] for k in ("_comment", "product", "public_key", "content_key", "license_public_key", "license_secret")}
    ordered.update({k: v for k, v in data.items() if k not in ordered})
    out.write_text(json.dumps(ordered, indent=2) + "\n", encoding="utf-8")
    return ordered, state


def _passphrase(confirm=False):
    env = os.environ.get("ADKEYS_PASSPHRASE")
    if env:
        return env
    first = getpass.getpass("Passphrase of the key store: ")
    if confirm:
        if getpass.getpass("Type it again: ") != first:
            raise KeyError_("The two passphrases are not the same.")
    return first


def _utf8_console():
    """Windows consoles (also on GitHub) use an old code page: Persian text would crash print()."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def main(argv=None):
    _utf8_console()
    p = argparse.ArgumentParser(description="A-Delnaz key store")
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("init", "product", "secret", "check"):
        s = sub.add_parser(name)
        s.add_argument("--store", required=True)
        if name == "product":
            s.add_argument("--product", required=True)
            s.add_argument("--out", required=True)
        if name == "secret":
            s.add_argument("--name", choices=KEY_NAMES, required=True)
    args = p.parse_args(argv)
    try:
        if args.cmd == "init":
            print("A new key store is made. Choose a passphrase you will not forget:", file=sys.stderr)
            print("without it the keys can never be used again (there is no recovery).", file=sys.stderr)
            create_store(args.store, _passphrase(confirm=True))
            print(f"Key store created: {args.store}", file=sys.stderr)
            print("Make a backup copy of this file on a second USB stick now.", file=sys.stderr)
        elif args.cmd == "product":
            data, state = product_keys(args.store, args.product, args.out)
            print({"created": "Created ", "updated": "Added the licence keys to ", "kept": "Kept existing "}[state] + args.out, file=sys.stderr)
        elif args.cmd == "secret":
            print(b64(unlock(args.store, _passphrase())[args.name]))
        elif args.cmd == "check":
            unlock(args.store, _passphrase())
            print("Passphrase is correct.", file=sys.stderr)
        return 0
    except KeyError_ as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
