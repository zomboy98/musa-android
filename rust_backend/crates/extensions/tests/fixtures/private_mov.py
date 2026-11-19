"""Owned synthetic CENC fixture only. Keys arrive on stdin, never argv/files.

Requires the installed PyAV test dependency. This is not a production finalizer.
The child exposes only exit status; raw libav diagnostics are never forwarded.
"""
import sys
import av

av.logging.set_level(av.logging.PANIC)

def main():
    key = bytearray(sys.stdin.buffer.read(17))
    if len(key) != 16:
        return 2
    try:
        if sys.argv[1] == 'create':
            options = {'encryption_scheme': 'cenc-aes-ctr',
                       'encryption_key': key.hex(),
                       'encryption_kid': bytes([37] * 16).hex(), 'strict': '-2'}
            with av.open(sys.argv[2], 'w', format='mp4', options=options) as out:
                stream = out.add_stream('flac', rate=44100)
                frame = av.AudioFrame(format='s16', layout='mono', samples=4410)
                frame.sample_rate = 44100
                frame.planes[0].update(bytes(frame.planes[0].buffer_size))
                for packet in stream.encode(frame):
                    out.mux(packet)
                for packet in stream.encode(None):
                    out.mux(packet)
        elif sys.argv[1] == 'decrypt':
            with av.open(sys.argv[2], options={'decryption_key': key.hex()}) as src, \
                    av.open(sys.argv[3], 'w', format='flac') as dst:
                stream = dst.add_stream_from_template(src.streams.audio[0])
                for packet in src.demux(src.streams.audio[0]):
                    if packet.dts is None:
                        continue
                    packet.stream = stream
                    dst.mux(packet)
        else:
            return 2
        return 0
    except Exception:
        return 3
    finally:
        key[:] = bytes(len(key))

sys.exit(main())
