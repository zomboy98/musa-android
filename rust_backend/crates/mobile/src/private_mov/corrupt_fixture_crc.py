"""Flip the final FLAC frame CRC byte of the synthetic one-track CENC MOV."""
import struct
import sys
from pathlib import Path

data = bytearray(Path(sys.argv[1]).read_bytes())
offset = 0
while offset + 8 <= len(data):
    size, kind = struct.unpack_from(">I4s", data, offset)
    if size < 8 or offset + size > len(data):
        raise SystemExit("unsupported atom")
    if kind == b"mdat":
        if size == 8:
            raise SystemExit("media atom empty")
        # AES-CTR preserves a bit flip at this position after decryption.
        data[offset + size - 1] ^= 1
        Path(sys.argv[2]).write_bytes(data)
        break
    offset += size
else:
    raise SystemExit("media atom missing")
