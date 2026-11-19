# Experimental private MOV primitive

This directory is an isolated experiment, not registered or packaged by the app.
`private_mov.c` synchronously decrypts a host-owned MOV into a newly created
FLAC file, decodes packets to detect errors, and reports terminal state after
closing resources. The callback context, paths, and key are caller-owned. The
caller must supply a private per-operation directory and clean it after terminal;
this primitive never unlinks by output name, including on failure.

`mornye_private_mov_fd_v1` is a separate experimental entry point. The host
supplies a stable, immutable regular input snapshot and a fresh 0600 regular
output descriptor with exclusive writes. It must keep descriptors and flags
stable throughout the synchronous call, including callbacks, and prevent any
handle or alias from mutating either inode. The producer borrows the descriptors
and leaves their offsets intact. It reports terminal after releasing custom
AVIO and libav resources. Failed or cancelled calls can leave partial output.

The descriptor ABI caps input and output at 512 MiB, allows up to 32 streams,
limits the stream probe to 5 MiB and analysis to five media seconds, and caps
the processing loop at two million packets. Cancellation is cooperative and
polled during descriptor I/O and packet processing. These limits do not bound
all libav allocations or guarantee a wall-clock deadline. The ABI disables MOV
external data references and rejects libav I/O open requests. A dedicated MOV
fixture that exercises the open rejection remains to be verified. CENC
decryption supplies no source authentication. Verify complete FLAC and source
length independently before publishing. The bridge wipes its temporary hex
buffer, and libav-internal copies have no verified erasure guarantee.
The output directory must be private to the host. A successful return is not
publication or quality validation; the existing transaction must independently
validate the complete staged FLAC. Cancellation is cooperative.

Build manually with `build_android.ps1 -Ndk <ndk> -InstallRoot <per-ABI-install>
-OutputRoot <new-directory>`. The install tree must contain matching headers
and static libraries from the same FFmpeg build. The script records ELF symbol
and dynamic-section reports and rejects libav imports/exports or shared FFmpeg
dependencies for each ABI. No absolute
machine paths are embedded in the app. `fixture.py` creates synthetic CENC data
with an in-memory test key. `test_private_mov.c` exercises that fixture and
`run_android_test.ps1` runs the compiled test on a separately launched emulator.

`experimental-private-mov-loader-test` additionally exposes an Android-only,
unsafe test-host loader. It uses an absolute path to `libmornye_private_mov.so`,
`RTLD_NOW | RTLD_LOCAL`, and retains the handle for the finalizer's lifetime.
It does not establish provenance, check the ELF or register the finalizer: the
trusted test host must verify its build and isolation and control the path and
its parent directories. Do not pass extension/provider input to this loader.
This feature is not a production packaging or registration mechanism. The build
script sets and checks SONAME `libmornye_private_mov.so`; supported build targets
are Android API 24 x86_64, arm64-v8a, and armeabi-v7a.

For the separate descriptor test, build `test_private_mov_fd.c` with the NDK
and `-ldl`. Run it in a fresh emulator directory containing the private
library, `fixture.mp4` from `fixture.py`, and the two derived inputs
`truncated.mp4` and `corrupt-crc.mp4` from `truncate_fixture.py` and
`corrupt_fixture_crc.py`. Pull `fd-ok.flac` and run `verify_pcm.py` to compare
the decoded samples with the generator's independent sample pattern.

The primitive passes the MOV key through libav's in-memory option dictionary;
the local hexadecimal buffer is wiped, but libav's internal allocations and
their erasure have not been audited. The bridge installs a discard callback once
on its statically linked private libav instance; this requires the symbol isolation
in the build script. Coexistence with FFmpegKit must be proven in the same process
before integration. Truncated inputs can produce superficially valid partial output;
the application transaction must enforce complete decoding and quality checks.
The x86_64 test is not proof for ARM runtimes or production cancellation races.
Static FFmpeg LGPL distribution obligations, including relinking and source
availability, remain to be reviewed before shipping. A single x86_64 emulator
fixture is not general CENC format or device parity.
