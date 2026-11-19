#!/usr/bin/env bash
# Experimental only. Run on Linux CI with GNU make and the Linux Android NDK.
set -euo pipefail
export LC_ALL=C TZ=UTC
commit=38b88335f99e76ed89ff3c93f877fdefce736c13
repo=${FFMPEG_REPO:?Set FFMPEG_REPO to the local FFmpeg Git checkout}
ndk=${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to Android NDK 28.2.13676358}
out=${1:?Usage: build.sh NEW_OUTPUT_DIRECTORY [arm64-v8a|armeabi-v7a|x86_64|all]}
abi=${2:-all}
jobs=${JOBS:-2}
for tool in git make perl tar sha256sum awk sed grep find sort xargs; do
  command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
done
make_version=$(make --version)
[[ $make_version == 'GNU Make'* ]] || { echo 'GNU Make required' >&2; exit 1; }
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid JOBS' >&2; exit 1; }
[[ $abi == all || $abi == arm64-v8a || $abi == armeabi-v7a || $abi == x86_64 ]] || { echo 'Invalid ABI' >&2; exit 1; }
git -C "$repo" cat-file -e "$commit^{commit}"
[[ $(git -C "$repo" rev-list -n 1 n8.1.2) == "$commit" ]] || { echo 'Unexpected release tag' >&2; exit 1; }
revision=$(awk -F= '/^[[:space:]]*Pkg[.]Revision[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' "$ndk/source.properties")
[[ $revision == 28.2.13676358 ]] || { echo 'Expected NDK 28.2.13676358' >&2; exit 1; }
bin="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin"
for tool in clang llvm-ar llvm-ranlib llvm-strip llvm-nm llvm-readelf; do
  [[ -x "$bin/$tool" ]] || { echo "Missing NDK tool: $tool" >&2; exit 1; }
done
[[ ! -e "$out" ]] || { echo 'Output already exists; refusing to overwrite' >&2; exit 1; }
repo=$(cd "$repo" && pwd -P)
[[ -d $(dirname "$out") ]] || { echo 'Output parent must already exist' >&2; exit 1; }
out_parent=$(cd "$(dirname "$out")" && pwd -P)
case "$out_parent/" in "$repo/"*) echo 'Output must be outside source checkout' >&2; exit 1;; esac
out="$out_parent/$(basename "$out")"
mkdir "$out"
out=$(cd "$out" && pwd -P)
ndk=$(cd "$ndk" && pwd -P)
bin="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin"
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(git -C "$repo" show -s --format=%ct "$commit")
[[ $SOURCE_DATE_EPOCH =~ ^[0-9]+$ ]] || { echo 'Invalid commit timestamp' >&2; exit 1; }
{
  printf 'SOURCE_DATE_EPOCH=%s\n' "$SOURCE_DATE_EPOCH"
  git --version
  make --version
  perl --version
  "$bin/clang" --version
  "$bin/llvm-ar" --version
  "$bin/llvm-readelf" --version
} > "$out/tool-versions.txt"
git -C "$repo" archive --format=tar --output="$out/source.tar" "$commit"
mkdir "$out/source"
tar -xf "$out/source.tar" -C "$out/source"
(cd "$out" && sha256sum source.tar > source.tar.sha256)
printf '%s\n' "$commit" > "$out/source-commit.txt"
cp "$ndk/source.properties" "$out/ndk-source.properties"

build_one() {
  local name=$1 arch target machine
  case "$name" in
    arm64-v8a) arch=aarch64; target=aarch64-linux-android24; machine=AArch64 ;;
    armeabi-v7a) arch=arm; target=armv7a-linux-androideabi24; machine=ARM ;;
    x86_64) arch=x86_64; target=x86_64-linux-android24; machine='Advanced Micro Devices X86-64' ;;
  esac
  local work="$out/build/$name" prefix="$out/install/$name"
  mkdir -p "$work" "$prefix"
  (
    cd "$work"
    "$out/source/configure" --prefix="$prefix" --target-os=android --arch="$arch" \
      --enable-cross-compile --cc="$bin/clang" --ar="$bin/llvm-ar" \
      --ranlib="$bin/llvm-ranlib" --nm="$bin/llvm-nm" --strip="$bin/llvm-strip" \
      --extra-cflags="--target=$target" --extra-ldflags="--target=$target" \
      --disable-autodetect --disable-everything --disable-programs --disable-doc \
      --disable-network --disable-shared --enable-static --enable-pic --disable-x86asm \
      --disable-debug --enable-protocol=file --enable-demuxer=mov --enable-muxer=flac \
      --enable-decoder=flac --enable-encoder=flac
    make -j"$jobs"
    make install
  )
  for flag in CONFIG_MOV_DEMUXER CONFIG_FLAC_MUXER CONFIG_FLAC_DECODER CONFIG_FLAC_ENCODER CONFIG_FILE_PROTOCOL; do
    grep -qx "#define $flag 1" "$work/config_components.h" || { echo "Missing required feature: $flag" >&2; exit 1; }
  done
  for header in libavformat/avformat.h libavcodec/avcodec.h libavutil/avconfig.h; do
    [[ -s "$prefix/include/$header" ]] || { echo "Missing header: $header" >&2; exit 1; }
  done
  for lib in avformat avcodec avutil; do
    archive="$prefix/lib/lib$lib.a"
    [[ -s "$archive" ]] || { echo "Missing archive: $lib" >&2; exit 1; }
    "$bin/llvm-readelf" -h "$archive" > "$work/$lib-elf-headers.txt"
    awk -v expected="$machine" '
      /Machine:/ { sub(/^.*Machine:[[:space:]]*/, ""); count++; if ($0 != expected) bad=1 }
      END { if (!count || bad) exit 1 }
    ' "$work/$lib-elf-headers.txt" || { echo "Unexpected object architecture: $name $lib" >&2; exit 1; }
  done
  "$bin/llvm-nm" -g --defined-only "$prefix/lib/libavformat.a" > "$work/avformat-symbols.txt"
  for symbol in ff_mov_demuxer ff_flac_muxer; do
    grep -Eq "[[:space:]]${symbol}$" "$work/avformat-symbols.txt" || { echo "Missing symbol: $symbol" >&2; exit 1; }
  done
  (cd "$prefix" && find include lib -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
}
if [[ $abi == all ]]; then
  for name in arm64-v8a armeabi-v7a x86_64; do build_one "$name"; done
else
  build_one "$abi"
fi
echo 'Experimental artifacts generated; ABI, isolation, function and licensing still require verification.'
