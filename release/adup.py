#!/usr/bin/env python3
"""
adup.py - A-Delnaz update package (.adup), format 1.

A .adup file is an update package that cannot be opened or read outside the product:
everything inside it (also the version and the notes) is encrypted, and it is signed,
so a changed or fake package is refused. See docs/UPDATES-AND-LICENSES.md, part 2-1.

    "ADUP" | 0x01 | IV (16 bytes) | ciphertext
    ciphertext = AES-256-CBC + PKCS7 (content key of the product) of:
        header_len (uint32, little-endian) | header (JSON, UTF-8) | signature (64) | payload (zip)
    signature  = Ed25519 (update signing key) over b"ADUP1" + header

Commands (messages are English, like all terminal scripts):
    adup.py keygen                      new keys, printed as JSON (keep them secret!)
    adup.py pack    --payload update.zip --product security-reports --name "Security Reports"
                    --version 1.0.9 [--releases notes.json] [--requirements requirements.txt]
                    [--released-at 2026-11-18T12:00:00Z] --out Security-Reports-1.0.9.adup
    adup.py inspect FILE                shows the header after checking signature and content
    adup.py unpack  FILE --out update.zip
    adup.py index   FOLDER              writes FOLDER/index.json (list of all .adup files)

Keys come from environment variables (or the matching --options):
    ADUP_SIGNING_KEY   private signing key (base64, 32 bytes)       - pack only
    ADUP_PUBLIC_KEY    public key (base64, 32 bytes)                - inspect, unpack, index
    ADUP_CONTENT_KEY   content key of the product (base64, 32 bytes) - all commands

Products copy the reading part (read_header / unpack) into their own code.
Needs the "cryptography" package.
"""

import argparse
import base64
import hashlib
import json
import os
import struct
import sys
from datetime import datetime, timezone
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

MAGIC = b"ADUP"
FORMAT = 1
SIGN_PREFIX = b"ADUP1"
CHUNK = 1024 * 1024
MAX_HEADER = 1024 * 1024


class PackageError(Exception):
    """The file is not a valid package for this product (wrong file, changed, or wrong keys)."""


# ---------------------------------------------------------------
#  Keys
# ---------------------------------------------------------------

def b64key(text, name):
    try:
        raw = base64.b64decode((text or "").strip(), validate=True)
    except ValueError:
        raw = b""
    if len(raw) != 32:
        raise PackageError(f"{name} is missing or not a valid 32-byte base64 key.")
    return raw


def new_keys():
    """New signing key pair and content key, as base64 text."""
    private = Ed25519PrivateKey.generate()
    seed = private.private_bytes_raw()
    public = private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    return {
        "signing_key": base64.b64encode(seed).decode(),
        "public_key": base64.b64encode(public).decode(),
        "content_key": base64.b64encode(os.urandom(32)).decode(),
    }


# ---------------------------------------------------------------
#  Write
# ---------------------------------------------------------------

def file_sha256(path):
    digest, size = hashlib.sha256(), 0
    with open(path, "rb") as f:
        while True:
            block = f.read(CHUNK)
            if not block:
                break
            digest.update(block)
            size += len(block)
    return digest.hexdigest(), size


def pack(payload_path, out_path, header_fields, signing_key, content_key):
    """Writes the .adup file. header_fields: product, version, ... (payload_* are added here)."""
    sha, size = file_sha256(payload_path)
    header = dict(header_fields)
    header["format"] = FORMAT
    header["payload_size"] = size
    header["payload_sha256"] = sha
    header_bytes = json.dumps(header, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    signature = Ed25519PrivateKey.from_private_bytes(signing_key).sign(SIGN_PREFIX + header_bytes)

    iv = os.urandom(16)
    encryptor = Cipher(algorithms.AES(content_key), modes.CBC(iv)).encryptor()
    padder = padding.PKCS7(128).padder()
    tmp = Path(str(out_path) + ".part")
    with open(payload_path, "rb") as src, open(tmp, "wb") as out:
        out.write(MAGIC + bytes([FORMAT]) + iv)

        def put(data):
            out.write(encryptor.update(padder.update(data)))

        put(struct.pack("<I", len(header_bytes)) + header_bytes + signature)
        while True:
            block = src.read(CHUNK)
            if not block:
                break
            put(block)
        out.write(encryptor.update(padder.finalize()) + encryptor.finalize())
    os.replace(tmp, out_path)
    return header


# ---------------------------------------------------------------
#  Read (products copy this part)
# ---------------------------------------------------------------

def _decrypted_blocks(f, content_key):
    """Decrypted content of an open .adup file, block by block (after the magic and IV)."""
    start = f.read(5 + 16)
    if len(start) != 21 or start[:4] != MAGIC:
        raise PackageError("This is not an update package.")
    if start[4] != FORMAT:
        raise PackageError(f"Unknown package format {start[4]}. Update the program first.")
    decryptor = Cipher(algorithms.AES(content_key), modes.CBC(start[5:])).decryptor()
    unpadder = padding.PKCS7(128).unpadder()
    while True:
        block = f.read(CHUNK)
        if not block:
            break
        yield unpadder.update(decryptor.update(block))
    try:
        yield unpadder.update(decryptor.finalize()) + unpadder.finalize()
    except ValueError as exc:
        raise PackageError("The package is damaged or belongs to another product.") from exc


def _open(path, content_key, public_key):
    """Returns (header, generator of the remaining payload bytes, file). Checks the signature."""
    f = open(path, "rb")
    try:
        blocks = _decrypted_blocks(f, content_key)
        buf = b""
        for block in blocks:
            buf += block
            if len(buf) >= 4:
                header_len = struct.unpack("<I", buf[:4])[0]
                if header_len > MAX_HEADER:
                    raise PackageError("The package is damaged or belongs to another product.")
                if len(buf) >= 4 + header_len + 64:
                    break
        else:
            raise PackageError("The package is damaged (too short).")
        header_len = struct.unpack("<I", buf[:4])[0]
        header_bytes = buf[4:4 + header_len]
        signature = buf[4 + header_len:4 + header_len + 64]
        try:
            Ed25519PublicKey.from_public_bytes(public_key).verify(signature, SIGN_PREFIX + header_bytes)
        except InvalidSignature as exc:
            raise PackageError("The signature is not valid: this package was changed or not made by the publisher.") from exc
        header = json.loads(header_bytes.decode("utf-8"))
        rest = buf[4 + header_len + 64:]

        def payload():
            if rest:
                yield rest
            yield from blocks
        return header, payload(), f
    except Exception:
        f.close()
        raise


def read_header(path, content_key, public_key):
    """Header of a package (signature checked; the payload is not read)."""
    header, _, f = _open(path, content_key, public_key)
    f.close()
    return header


def unpack(path, out_path, content_key, public_key, product=None):
    """Checks the package completely and writes the payload (zip). Returns the header."""
    header, payload, f = _open(path, content_key, public_key)
    if product and header.get("product") != product:
        f.close()
        raise PackageError(f"This package is for '{header.get('product')}', not for this program.")
    digest, size = hashlib.sha256(), 0
    tmp = Path(str(out_path) + ".part")
    try:
        with f, open(tmp, "wb") as out:
            for block in payload:
                size += len(block)
                if size > header["payload_size"]:
                    raise PackageError("The package is damaged (too long).")
                digest.update(block)
                out.write(block)
        if size != header["payload_size"] or digest.hexdigest() != header["payload_sha256"]:
            raise PackageError("The package is damaged (content check failed).")
        os.replace(tmp, out_path)
    finally:
        if tmp.exists():
            tmp.unlink()
    return header


# ---------------------------------------------------------------
#  Folder index (for the "web address" source)
# ---------------------------------------------------------------

def version_key(text):
    parts = []
    for p in str(text or "").split("."):
        parts.append(int(p) if p.isdigit() else 0)
    return tuple(parts + [0] * (4 - len(parts)))


def write_index(folder, content_key, public_key):
    folder = Path(folder)
    versions, product = [], None
    for path in sorted(folder.glob("*.adup")):
        try:
            h = read_header(path, content_key, public_key)
        except PackageError as exc:
            print(f"Skipped {path.name}: {exc}", file=sys.stderr)
            continue
        product = product or h.get("product")
        versions.append({"version": h["version"], "file": path.name, "size": path.stat().st_size,
                         "released_at": h.get("released_at", "")})
    versions.sort(key=lambda v: version_key(v["version"]), reverse=True)
    index = {"product": product, "versions": versions}
    (folder / "index.json").write_text(json.dumps(index, ensure_ascii=False, indent=2), encoding="utf-8")
    return index


# ---------------------------------------------------------------
#  Command line
# ---------------------------------------------------------------

def _key(args, name, env):
    return b64key(getattr(args, name) or os.environ.get(env, ""), env)


def main(argv=None):
    p = argparse.ArgumentParser(description="A-Delnaz update package (.adup)")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("keygen", help="new keys (JSON)")

    k = sub.add_parser("pack", help="make a .adup file")
    k.add_argument("--payload", required=True)
    k.add_argument("--out", required=True)
    k.add_argument("--product", required=True, help="short id, for example security-reports")
    k.add_argument("--name", required=True, help="product name, for example \"Security Reports\"")
    k.add_argument("--version", required=True)
    k.add_argument("--released-at", default="")
    k.add_argument("--releases", default="", help="JSON file with the release notes")
    k.add_argument("--requirements", default="", help="requirements.txt (its hash goes into the header)")
    k.add_argument("--signing-key")
    k.add_argument("--content-key")

    for name in ("inspect", "unpack"):
        s = sub.add_parser(name)
        s.add_argument("file")
        s.add_argument("--public-key")
        s.add_argument("--content-key")
        if name == "unpack":
            s.add_argument("--out", required=True)

    i = sub.add_parser("index", help="write index.json for a folder of .adup files")
    i.add_argument("folder")
    i.add_argument("--public-key")
    i.add_argument("--content-key")

    args = p.parse_args(argv)
    try:
        if args.cmd == "keygen":
            print(json.dumps(new_keys(), indent=2))
        elif args.cmd == "pack":
            fields = {
                "product": args.product,
                "product_name": args.name,
                "version": args.version,
                "released_at": args.released_at or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
            if args.releases:
                fields["releases"] = json.loads(Path(args.releases).read_text(encoding="utf-8-sig"))
            if args.requirements:
                lines = sorted({l.strip().lower() for l in Path(args.requirements).read_text(encoding="utf-8-sig").splitlines()
                                if l.strip() and not l.strip().startswith("#")})
                fields["requirements_sha256"] = hashlib.sha256("\n".join(lines).encode()).hexdigest()
            h = pack(args.payload, args.out, fields,
                     _key(args, "signing_key", "ADUP_SIGNING_KEY"), _key(args, "content_key", "ADUP_CONTENT_KEY"))
            print(f"Created {args.out}  ({h['product']} {h['version']}, payload {h['payload_size']:,} bytes)")
        elif args.cmd == "inspect":
            header, payload, f = _open(args.file, _key(args, "content_key", "ADUP_CONTENT_KEY"), _key(args, "public_key", "ADUP_PUBLIC_KEY"))
            with f:
                digest, size = hashlib.sha256(), 0
                for block in payload:
                    digest.update(block)
                    size += len(block)
            ok = size == header["payload_size"] and digest.hexdigest() == header["payload_sha256"]
            print(json.dumps(header, ensure_ascii=False, indent=2))
            print("Signature: valid. Content: " + ("valid." if ok else "DAMAGED."))
            return 0 if ok else 1
        elif args.cmd == "unpack":
            h = unpack(args.file, args.out, _key(args, "content_key", "ADUP_CONTENT_KEY"), _key(args, "public_key", "ADUP_PUBLIC_KEY"))
            print(f"Valid package {h['product']} {h['version']}. Payload written to {args.out}")
        elif args.cmd == "index":
            idx = write_index(args.folder, _key(args, "content_key", "ADUP_CONTENT_KEY"), _key(args, "public_key", "ADUP_PUBLIC_KEY"))
            print(f"index.json: {len(idx['versions'])} version(s)")
        return 0
    except PackageError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
