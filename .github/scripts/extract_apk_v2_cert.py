#!/usr/bin/env python3
import hashlib
import struct
import sys

APK = sys.argv[1]
data = open(APK, "rb").read()

def u32(off):
    return struct.unpack_from("<I", data, off)[0]
def u64(off):
    return struct.unpack_from("<Q", data, off)[0]

eocd = data.rfind(b"PK\x05\x06")
if eocd < 0:
    raise SystemExit("APK EOCD not found")
cd_offset = u32(eocd + 16)
footer = cd_offset - 24
if data[footer + 8:footer + 24] != b"APK Sig Block 42":
    raise SystemExit("APK Signing Block footer not found")
block_size = u64(footer)
block_start = cd_offset - block_size - 8
if data[block_start:block_start + 8] != struct.pack("<Q", block_size):
    raise SystemExit("APK Signing Block header mismatch")

pos = block_start + 8
end = footer
v2 = None
while pos < end:
    pair_len = u64(pos)
    pos += 8
    pair_id = u32(pos)
    value = data[pos + 4:pos + pair_len]
    pos += pair_len
    if pair_id == 0x7109871A:
        v2 = value
        break
if v2 is None:
    raise SystemExit("APK v2 signing pair not found")

# signed-data: length-prefixed signers -> signer -> signed-data -> digests,
# certificates, additional attributes. Certificates are length-prefixed DER.
def read_lp(buf, off):
    n = u32_from(buf, off)
    return buf[off + 4:off + 4 + n], off + 4 + n
def u32_from(buf, off):
    return struct.unpack_from("<I", buf, off)[0]

signers, off = read_lp(v2, 0)
signer, _ = read_lp(signers, 0)
signed_data, off = read_lp(signer, 0)
digests, off = read_lp(signed_data, 0)
certs, off = read_lp(signed_data, off)
cert, _ = read_lp(certs, 0)
print(f"{len(cert)} {hashlib.sha256(cert).hexdigest()}")
