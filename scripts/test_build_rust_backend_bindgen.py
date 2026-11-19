#!/usr/bin/env python3
"""Exercise Android bindgen argument construction without running a build."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import unittest


class BindgenArgumentsTest(unittest.TestCase):
    def test_progressive_feature_configuration(self):
        script = Path(__file__).with_name("build_rust_backend.sh").read_text()
        start = script.index('MOBILE_FEATURE_ARGS=()')
        end = script.index('\nif [[ "$PLATFORM" == "android" ]]', start)
        config = script[start:end]
        host = 'cargo build --locked --release -p mornye-mobile "${MOBILE_FEATURE_ARGS[@]}"'
        android = 'cargo build --locked --release -p mornye-mobile --target "$target" "${MOBILE_FEATURE_ARGS[@]}"'
        self.assertIn(host, script)
        self.assertIn(android, script)
        for platform in ("host", "android"):
            for value in (None, "0", "1", "", "true", "2"):
                with self.subTest(platform=platform, value=value):
                    env = os.environ.copy()
                    env.pop("MORNYE_EXPERIMENTAL_PROGRESSIVE_READER", None)
                    if value is not None:
                        env["MORNYE_EXPERIMENTAL_PROGRESSIVE_READER"] = value
                    env["PLATFORM"] = platform
                    command = '''set -eu
cargo() { printf '<%s>\\n' "$@"; }
''' + config + '\ntarget=aarch64-linux-android\n' + host + '\n' + android
                    result = subprocess.run([shutil.which("bash"), "-c", command], env=env,
                                            text=True, capture_output=True)
                    if value in (None, "0", "1"):
                        self.assertEqual(result.returncode, 0, result.stderr)
                        enabled = value == "1" or (value is None and platform == "android")
                        self.assertEqual(result.stdout.count('<experimental-progressive-reader>'),
                                         2 if enabled else 0)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn('must be 0 or 1', result.stderr)

        for platform in ("ios", "desktop"):
            env = os.environ.copy()
            env.update(PLATFORM=platform, MORNYE_EXPERIMENTAL_PROGRESSIVE_READER="1")
            result = subprocess.run([shutil.which("bash"), "-c", config], env=env,
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('supports host or android only', result.stderr)

    def test_host_and_abi_arguments(self):
        script = Path(__file__).with_name("build_rust_backend.sh").read_text()
        start = script.index('  NDK_BIN="$ANDROID_NDK_HOME/')
        end = script.index('\n  for linker in ', start)
        fragment = script[start:end]
        for host in ("linux-x86_64", "darwin-x86_64", "windows-x86_64"):
            with self.subTest(host=host):
                env = os.environ.copy()
                env.update(ANDROID_NDK_HOME="/NDK directory/30.0", NDK_HOST=host)
                setup = '''set -eu
cygpath() { printf '%s' "$2"; }
NDK_CLANG_RESOURCE_DIR="C:/NDK directory/clang/21"
ANDROID_ABIS=(arm64-v8a x86_64 armeabi-v7a)
'''
                output = '''
printf '%s\\n' "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android" "$BINDGEN_EXTRA_CLANG_ARGS_x86_64_linux_android" "$BINDGEN_EXTRA_CLANG_ARGS_armv7_linux_androideabi"
'''
                result = subprocess.run([shutil.which("bash"), "-c", setup + fragment + output],
                                        env=env, check=True, text=True, capture_output=True)
                for line, target in zip(result.stdout.splitlines(),
                                        ("aarch64-linux-android24", "x86_64-linux-android24", "armv7a-linux-androideabi24"), strict=True):
                    args = shlex.split(line)
                    self.assertEqual(args[:2], [f"--sysroot=/NDK directory/30.0/toolchains/llvm/prebuilt/{host}/sysroot", f"--target={target}"])
                    if host == "linux-x86_64":
                        self.assertEqual(args[2:], [f"-resource-dir=/NDK directory/30.0/toolchains/llvm/prebuilt/{host}/lib/clang/21"])
                    elif host == "windows-x86_64":
                        self.assertEqual(args[2:], ["-resource-dir=C:/NDK directory/clang/21"])
                    else:
                        self.assertEqual(args[2:], [])


if __name__ == "__main__":
    unittest.main()
