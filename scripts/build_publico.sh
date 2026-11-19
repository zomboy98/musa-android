#!/usr/bin/env bash
# Public beta build: MUSA as a bare player, without any bundled add-on.
# Usage: scripts/build_publico.sh [extra flutter build apk args]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$ROOT/assets/bundled_extensions"
STASH="$(mktemp -d)"

restore() {
  if compgen -G "$STASH/*.sflx" >/dev/null; then
    mv "$STASH"/*.sflx "$ASSETS/"
  fi
  git -C "$ROOT" checkout -- assets/bundled_extensions/manifest.json
  rmdir "$STASH" 2>/dev/null || true
}
trap restore EXIT

cd "$ROOT"
mv "$ASSETS"/*.sflx "$STASH/"
printf '{"extensions": []}\n' >"$ASSETS/manifest.json"

flutter build apk --release --split-per-abi \
  --dart-define=MUSA_PUBLIC=true "$@"

for apk in build/app/outputs/flutter-apk/*-release.apk; do
  if unzip -l "$apk" | grep -q '\.sflx'; then
    echo "ERROR: $apk still packages add-ons" >&2
    exit 1
  fi
done
echo "Public build ready without bundled add-ons."
