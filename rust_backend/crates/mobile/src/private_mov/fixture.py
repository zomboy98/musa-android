"""Create a disposable synthetic encrypted sample; key exists only in memory."""
import sys
import array
import av

av.logging.set_level(av.logging.PANIC)
key = bytearray((i * 13 + 7) & 255 for i in range(16))
try:
    with av.open(sys.argv[1], 'w', format='mp4', options={
        'encryption_scheme': 'cenc-aes-ctr', 'encryption_key': key.hex(),
        'encryption_kid': '25252525252525252525252525252525', 'strict': '-2'
    }) as out:
        stream = out.add_stream('flac', rate=44100)
        stream.layout = 'mono'
        for n in range(12):
            frame = av.AudioFrame(format='s16', layout='mono', samples=4410)
            frame.sample_rate = 44100
            frame.pts = n * 4410
            samples = array.array('h', (((n * 4410 + i) * 47) % 65536 - 32768 for i in range(4410)))
            if sys.byteorder != 'little':
                samples.byteswap()
            frame.planes[0].update(samples.tobytes())
            for packet in stream.encode(frame):
                out.mux(packet)
        for packet in stream.encode(None):
            out.mux(packet)
finally:
    key[:] = bytes(len(key))
