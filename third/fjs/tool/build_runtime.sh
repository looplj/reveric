#!/usr/bin/env bash
# Rebuild SwiftPM's local archive when any source/toolchain input differs.
set -euo pipefail
FJS_PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$FJS_PROJECT_ROOT"
# Any Flutter SDK can host the CargoKit build tool; prefer the project FVM link.
if [[ -x "$FJS_PROJECT_ROOT/.fvm/flutter_sdk/bin/dart" ]]; then
  FLUTTER_ROOT="$FJS_PROJECT_ROOT/.fvm/flutter_sdk"
elif [[ -z "${FLUTTER_ROOT:-}" ]] && command -v flutter >/dev/null 2>&1; then
  FLUTTER_ROOT="$(python3 -c 'import os, sys; print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))' "$(command -v flutter)")"
fi
if [[ ! -x "${FLUTTER_ROOT:-}/bin/dart" ]]; then
  echo 'No Flutter SDK found; run fvm install or put flutter on PATH.' >&2
  exit 1
fi
export FLUTTER_ROOT
export PATH="$FLUTTER_ROOT/bin:$PATH"
case "${1:-build}" in
  --key) exec python3 third/fjs/tool/artifact.py key ;;
  --verify) exec python3 third/fjs/tool/artifact.py verify ;;
  --verify-app) exec python3 third/fjs/tool/artifact.py verify-app "${2:?app path required}" ;;
  build) ;;
  *) echo 'usage: build_runtime.sh [--key|--verify|--verify-app APP]' >&2; exit 2 ;;
esac
# Non-Apple plugin builds invoke patched CargoKit directly, using its recipe pin.
if [[ "$(uname -s)" != Darwin ]]; then
  python3 third/fjs/tool/artifact.py key
  echo 'FJS will compile locally with the pinned CargoKit recipe during app build.'
  exit 0
fi
if python3 third/fjs/tool/artifact.py verify; then
  python3 third/fjs/tool/artifact.py prepare-swiftpm
  exit 0
fi
CODEMODE_KEY="$(python3 third/fjs/tool/artifact.py key)"
# The key covers source and toolchain but no worktree path, so worktrees with
# identical FJS inputs share one archive from the machine-level cache.
BINARIES=third/fjs/darwin/fjs/Binaries
ARTIFACTS=(fjs.xcframework.zip fjs.xcframework.zip.checksum reveric-build.json)
CACHE_DIR="${REVERIC_CODEMODE_CACHE:-$HOME/Library/Caches/reveric/codemode}/$CODEMODE_KEY"
if [[ -f "$CACHE_DIR/reveric-build.json" ]]; then
  mkdir -p "$BINARIES"
  for name in "${ARTIFACTS[@]}"; do cp "$CACHE_DIR/$name" "$BINARIES/$name"; done
  if python3 third/fjs/tool/artifact.py verify; then
    python3 third/fjs/tool/artifact.py prepare-swiftpm
    exit 0
  fi
  echo 'Cached FJS archive failed verification; rebuilding from source.' >&2
fi
sh third/fjs/tool/build_fjs_xcframework.sh
python3 third/fjs/tool/artifact.py record "$CODEMODE_KEY"
python3 third/fjs/tool/artifact.py verify
mkdir -p "${CACHE_DIR%/*}"
CACHE_TEMP="$(mktemp -d "${CACHE_DIR%/*}/.tmp.XXXXXX")"
for name in "${ARTIFACTS[@]}"; do cp "$BINARIES/$name" "$CACHE_TEMP/$name"; done
# Another worktree may have stored the same key concurrently; keep the first.
if [[ ! -e "$CACHE_DIR" ]]; then
  mv "$CACHE_TEMP" "$CACHE_DIR" 2>/dev/null || true
fi
rm -rf "$CACHE_TEMP"

python3 third/fjs/tool/artifact.py prepare-swiftpm
