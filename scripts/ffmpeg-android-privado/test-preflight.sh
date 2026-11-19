#!/usr/bin/env bash
# Synthetic preflight tests only: fake tools; never runs configure or make.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo" "$tmp/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin" "$tmp/existing"
cat > "$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *' cat-file '*) exit 0 ;;
  *' rev-list '*) echo 38b88335f99e76ed89ff3c93f877fdefce736c13 ;;
  *) echo 'unexpected git call' >&2; exit 99 ;;
esac
EOF
cat > "$tmp/bin/make" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == --version ]] && { echo 'GNU Make synthetic'; exit 0; }
echo 'unexpected make call' >&2; exit 99
EOF
chmod +x "$tmp/bin/git" "$tmp/bin/make"
for tool in clang llvm-ar llvm-ranlib llvm-strip llvm-nm llvm-readelf; do
  printf '#!/usr/bin/env bash\nexit 99\n' > "$tmp/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/$tool"
  chmod +x "$tmp/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/$tool"
done
export PATH="$tmp/bin:$PATH" FFMPEG_REPO="$tmp/repo" ANDROID_NDK_HOME="$tmp/ndk"
expect_failure() {
  local message=$1; shift
  if bash "$here/build.sh" "$@" > "$tmp/log" 2>&1; then
    echo "Unexpected success: $message" >&2; exit 1
  fi
  grep -Fq "$message" "$tmp/log" || { cat "$tmp/log" >&2; exit 1; }
}
printf 'Pkg.Revision = 28.2.136763580\n' > "$tmp/ndk/source.properties"
expect_failure 'Expected NDK' "$tmp/new" arm64-v8a
[[ ! -e "$tmp/new" ]]
printf 'Pkg.Revision = 28.2.13676358\nPkg.Revision = 28.2.13676358\n' > "$tmp/ndk/source.properties"
expect_failure 'Expected NDK' "$tmp/new" arm64-v8a
printf 'Pkg.Revision = 28.2.13676358\n' > "$tmp/ndk/source.properties"
expect_failure 'Output already exists' "$tmp/existing" arm64-v8a
expect_failure 'Invalid ABI' "$tmp/new" unsupported
expect_failure 'Output must be outside source checkout' "$tmp/repo/new" arm64-v8a
[[ ! -e "$tmp/repo/new" ]]
echo 'Synthetic preflight tests passed.'
