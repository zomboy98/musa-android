"""Remove bytes inside the media-data atom while retaining the MOV metadata."""
import struct
import sys
from pathlib import Path

data = Path(sys.argv[1]).read_bytes()
offset = 0
while offset + 8 <= len(data):
    size, kind = struct.unpack_from('>I4s', data, offset)
    if size < 8 or offset + size > len(data):
        raise SystemExit('unsupported atom')
    if kind == b'mdat':
        if size <= 4104:
            raise SystemExit('media atom too small')
        cut = 4096
        result = bytearray(data[:offset + size - cut] + data[offset + size:])
        struct.pack_into('>I', result, offset, size - cut)
        Path(sys.argv[2]).write_bytes(result)
        break
    offset += size
else:
    raise SystemExit('media atom missing')
