import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile


def ffmpeg(*args, ok=True):
    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y", *args],
        capture_output=True, text=True,
    )
    assert (proc.returncode == 0) == ok, proc.stderr
    return proc.stderr.strip()


def audio(path):
    return json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "a", "-show_streams",
        "-show_format", "-of", "json", str(path),
    ]))


def convert(source, output, *rates, ok=True):
    options = [
        arg for index, rate in enumerate(rates)
        for arg in (f"-b:a:{index}", f"{rate}k")
    ]
    return ffmpeg("-i", str(source), "-map", "0:a", "-c:a", "libopus",
                  "-vbr", "on", "-compression_level", "10", *options,
                  str(output), ok=ok)


def check(path, expected):
    data = audio(path)
    streams = data["streams"]
    assert [item["channels"] for item in streams] == expected
    assert all(item["codec_name"] == "opus" for item in streams)
    ffmpeg("-xerror", "-i", str(path), "-map", "0:a", "-f", "null", "-")
    return {
        "channels": expected,
        "streamBitratesBps": [item.get("bit_rate") for item in streams],
        "containerBitrateBps": int(data["format"]["bit_rate"]),
    }


def ogg_page_duration_evidence(path):
    # Parallel Ogg streams have independent granule clocks. Parse the page
    # framing so a literal "OggS" in a payload cannot look like a page header.
    data = path.read_bytes()
    offset = 0
    end_seconds = []
    while offset < len(data):
        assert data[offset:offset + 4] == b"OggS"
        flags = data[offset + 5]
        granule = struct.unpack_from("<q", data, offset + 6)[0]
        segment_count = data[offset + 26]
        header_end = offset + 27 + segment_count
        if flags & 4:
            end_seconds.append(round(granule / 48000, 3))
        offset = header_end + sum(data[offset + 27:header_end])
    assert offset == len(data)
    assert len(end_seconds) == 2 and abs(end_seconds[0] - end_seconds[1]) > 1
    return end_seconds


def cancel_encoder(source, output):
    proc = subprocess.Popen([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
        "-progress", "pipe:1", "-re", "-i", str(source), "-map", "0:a",
        "-c:a", "libopus", "-b:a:0", "256k", str(output),
    ], stdout=subprocess.PIPE, text=True)
    try:
        assert proc.stdout is not None
        assert proc.stdout.readline(), "encoder exited before reporting progress"
        assert proc.poll() is None
    finally:
        if proc.poll() is None:
            proc.terminate()
        proc.communicate(timeout=10)
    assert proc.returncode != 0
    output.unlink(missing_ok=True)
    assert not output.exists()


with tempfile.TemporaryDirectory(prefix="musa-opus-mono-") as scratch:
    scratch = Path(scratch)
    mono, stereo, mixed, surround = [
        scratch / name for name in ("mono.flac", "stereo.flac", "mixed.mka", "side.flac")
    ]
    ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:d=3", "-c:a", "flac", str(mono))
    ffmpeg("-f", "lavfi", "-i", "sine=frequency=880:d=3",
           "-ac", "2", "-c:a", "flac", str(stereo))
    ffmpeg("-i", str(mono), "-i", str(stereo), "-map", "1:a", "-map", "0:a",
           "-c", "copy", str(mixed))
    ffmpeg("-f", "lavfi", "-i", "anullsrc=r=48000:cl=5.1(side)", "-t", "1",
           "-c:a", "flac", str(surround))

    original = hashlib.sha256(mono.read_bytes()).hexdigest()
    failed = scratch / "failed.partial.opus"
    failure = convert(mono, failed, 320, ok=False)
    assert hashlib.sha256(mono.read_bytes()).hexdigest() == original
    assert "256000" in failure, failure

    report = {"mono320Failure": failure.splitlines()[0]}
    for source, rates, channels in [
        (mono, [256], [1]), (stereo, [320], [2]), (mixed, [320, 256], [2, 1]),
    ]:
        output = scratch / (source.stem + ".partial.opus")
        convert(source, output, *rates)
        report[source.stem] = check(output, channels)

    inconsistent = scratch / "mono-header-stereo-frames.flac"
    stereo_bytes = bytearray(stereo.read_bytes())
    assert stereo_bytes[:4] == b"fLaC"
    stereo_bytes[20] &= 0xF1  # Declare mono in STREAMINFO, leave the frames alone.
    inconsistent.write_bytes(stereo_bytes)
    inconsistent_output = scratch / "inconsistent.partial.opus"
    convert(inconsistent, inconsistent_output, 256)
    report["monoHeaderStereoFrames"] = check(inconsistent_output, [2])

    short = scratch / "short.flac"
    unequal = scratch / "unequal.mka"
    unequal_output = scratch / "unequal.partial.opus"
    ffmpeg("-i", str(mono), "-t", "1", "-c:a", "flac", str(short))
    ffmpeg("-i", str(short), "-i", str(stereo), "-map", "0:a", "-map", "1:a",
           "-c", "copy", str(unequal))
    convert(unequal, unequal_output, 256, 320)
    report["unequal"] = check(unequal_output, [1, 2])
    report["unequal"]["eosGranuleSeconds"] = ogg_page_duration_evidence(unequal_output)

    side_failure = convert(surround, failed, 320, ok=False)
    assert "5.1(side)" in side_failure
    report["surroundFailure"] = side_failure.splitlines()[0]

    missing_probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_streams", str(scratch / "missing.flac")],
        capture_output=True,
    )
    assert missing_probe.returncode != 0
    cancel_encoder(mono, scratch / "cancelled.partial.opus")
    assert hashlib.sha256(mono.read_bytes()).hexdigest() == original
    report["hostCancellation"] = "terminated and joined before staging cleanup"
    print(json.dumps(report, indent=2))
