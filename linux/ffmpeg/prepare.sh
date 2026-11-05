#!/bin/bash
# Stage the pinned FFmpeg 8.1 GPL shared build used by Linux encoding and probing.
# Playback keeps MDK's own libffmpeg. These binaries live in <bundle>/ffmpeg and
# find their libraries through DT_RPATH $ORIGIN/../lib, away from the app's lib/.
set -euo pipefail
cd "$(dirname "$0")"

release="autobuild-2026-11-05-12-48"
archive_name="ffmpeg-n8.1.3-34-ga35157abb9-linux64-gpl-shared-8.1.tar.xz"
sha="58af63f28ad3e1838fd03a298219761e85dc28dde7fcf652b4e3f85d4ea6ea3c"
url="https://github.com/BtbN/FFmpeg-Builds/releases/download/${release}/${archive_name}"
stamp_value="${release}:${sha}"
root_name="${archive_name%.tar.xz}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to verify the FFmpeg archive" >&2
  exit 1
fi

refresh_notices() {
  mkdir -p bundle/licenses
  cp -a licenses/. bundle/licenses/
  cat > bundle/SOURCE <<EOF
FFmpeg n8.1.3 GPL shared build for Linux x86_64.
Archive: ${archive_name}
Release: https://github.com/BtbN/FFmpeg-Builds/releases/tag/${release}
SHA256: ${sha}
The build targets glibc 2.28 or newer. License texts are the FFmpeg GPLv2 and GPLv3 copies.
EOF
}

bundle_ready() {
  [[ -x bundle/bin/ffmpeg && -x bundle/bin/ffprobe && -e bundle/lib/libavcodec.so.62 && -f .cache/stamp ]] \
    && [[ "$(cat .cache/stamp)" == "$stamp_value" ]]
}

if bundle_ready; then
  refresh_notices
  echo "Bundled FFmpeg is ready"
  exit 0
fi

verify_sha() {
  python3 - "$1" "$2" <<'PY'
import hashlib
import sys

path, expected = sys.argv[1], sys.argv[2]
digest = hashlib.sha256()
with open(path, "rb") as archive:
    for chunk in iter(lambda: archive.read(1024 * 1024), b""):
        digest.update(chunk)
actual = digest.hexdigest()
if actual != expected:
    sys.exit(f"{path}: sha256 {actual} != {expected}")
PY
}

mkdir -p .cache
archive=".cache/${archive_name}"
if [[ ! -f "$archive" ]] || ! verify_sha "$archive" "$sha"; then
  echo "Downloading ${archive_name}"
  curl --fail --location --retry 3 -o "${archive}.part" "$url"
  mv "${archive}.part" "$archive"
  verify_sha "$archive" "$sha"
fi

staging="$(mktemp -d "${TMPDIR:-/tmp}/reveric-ffmpeg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
tar -xJf "$archive" -C "$staging"
root="$staging/$root_name"
if [[ ! -x "$root/bin/ffmpeg" || ! -x "$root/bin/ffprobe" || ! -d "$root/lib" ]]; then
  echo "FFmpeg archive is missing bin/ffmpeg, bin/ffprobe, or lib/" >&2
  exit 1
fi

rm -rf bundle
mkdir -p bundle/bin bundle/lib
cp -a "$root/bin/ffmpeg" "$root/bin/ffprobe" bundle/bin/
chmod 755 bundle/bin/ffmpeg bundle/bin/ffprobe
find "$root/lib" -maxdepth 1 \( -type f -o -type l \) -exec cp -a {} bundle/lib/ \;
for soname in \
  libavdevice.so.62 \
  libavfilter.so.11 \
  libavformat.so.62 \
  libavcodec.so.62 \
  libswresample.so.6 \
  libswscale.so.9 \
  libavutil.so.60
do
  if [[ ! -e "bundle/lib/$soname" ]]; then
    echo "FFmpeg archive is missing $soname" >&2
    exit 1
  fi
done
refresh_notices
printf '%s\n' "$stamp_value" > .cache/stamp
echo "Bundled FFmpeg is ready"
