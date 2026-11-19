"""Independently decode and compare every synthetic output PCM sample."""
import sys
import av

count = 0
with av.open(sys.argv[1]) as container:
    for frame in container.decode(audio=0):
        if frame.format.name != 's16' or frame.layout.name != 'mono':
            raise SystemExit('FAIL: unexpected PCM format')
        for value in frame.to_ndarray().reshape(-1):
            expected = ((count * 47) % 65536) - 32768
            if int(value) != expected:
                raise SystemExit(f'FAIL: PCM mismatch at sample {count}')
            count += 1
if count != 12 * 4410:
    raise SystemExit(f'FAIL: decoded sample count {count}')
print(f'PCM exact: PASS ({count} samples)')
