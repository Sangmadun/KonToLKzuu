#!/usr/bin/env python3
"""Check a certificate hash in a concatenated Image.gz-dtb payload."""
import sys
import zlib
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit("usage: check_image_hash.py IMAGE.GZ-DTB HASH")
image = Path(sys.argv[1]).read_bytes()
digest = sys.argv[2].encode("ascii")
if image[:2] != b"\x1f\x8b":
    raise SystemExit("image does not start with gzip")
# Image.gz-dtb is gzip-compressed Image followed by an uncompressed DTB.
obj = zlib.decompressobj(16 + zlib.MAX_WBITS)
compressed_image = obj.decompress(image) + obj.flush()
trailing_dtb = obj.unused_data
if digest not in compressed_image and digest not in trailing_dtb:
    raise SystemExit("compat hash missing from exact packaged Image.gz-dtb")
print("compatibility Manager certificate found in exact packaged Image.gz-dtb")
print(f"gzip_image_bytes={len(compressed_image)} trailing_dtb_bytes={len(trailing_dtb)}")
