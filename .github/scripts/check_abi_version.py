#!/usr/bin/env python3
"""Verify ReSukiSU ABI marker in vmlinux and gzip+DTB Image.gz-dtb."""
from __future__ import annotations
import gzip
import hashlib
import sys
import zlib
from pathlib import Path

ABI = b"35079"
MARKER = b"ReSukiSU-KERNEL-ABI-" + ABI
STALE = (b"ReSukiSU-KERNEL-ABI-35002", b"11872")

def image_payload(path: Path) -> bytes:
    raw = path.read_bytes()
    dec = zlib.decompressobj(16 + zlib.MAX_WBITS)
    payload = dec.decompress(raw)
    payload += dec.flush()
    if not payload or not dec.unused_data:
        raise SystemExit(f"invalid Image.gz-dtb gzip/member structure: {path}")
    return payload + dec.unused_data

def check(path: Path, data: bytes) -> None:
    if MARKER not in data:
        raise SystemExit(f"ABI marker missing from {path}")
    for stale in STALE:
        if stale in data:
            raise SystemExit(f"stale ABI marker {stale.decode()} found in {path}")
    print(f"ABI {ABI.decode()} verified in {path} ({len(data)} bytes, sha256={hashlib.sha256(data).hexdigest()})")

if len(sys.argv) != 3:
    raise SystemExit("usage: check_abi_version.py VMLINUX IMAGE_GZ_DTB")
vmlinux, image = map(Path, sys.argv[1:])
check(vmlinux, vmlinux.read_bytes())
check(image, image_payload(image))
print("ABI image verification passed")
