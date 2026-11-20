#!/usr/bin/env bash
set -euo pipefail
depth_root=$(cd "$(dirname "$0")/../.." && pwd)
depth_work="$depth_root/build/depth-native"
mkdir -p "$depth_work"
# The NuGet package supplies architecture-independent headers and licenses;
# its binary is only a size reference. The shipped library is built from source.
depth_archive="$depth_work/microsoft.ml.onnxruntime.1.31.0.nupkg"
depth_hash=7e35fdb4f5adb62f01e60798e2e5ed05108f5fbbe1cca03fbcc37903cf7c5e3b
if [ ! -f "$depth_archive" ]; then
  curl -fL --retry 2 --connect-timeout 30 --max-time 900 \
    https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/1.31.0/microsoft.ml.onnxruntime.1.31.0.nupkg \
    -o "$depth_archive.part"
  printf '%s  %s\n' "$depth_hash" "$depth_archive.part" | shasum -a 256 -c -
  mv "$depth_archive.part" "$depth_archive"
fi
printf '%s  %s\n' "$depth_hash" "$depth_archive" | shasum -a 256 -c -
depth_reference="$depth_work/onnxruntime-osx-arm64-1.31.0"
mkdir -p "$depth_reference/include" "$depth_reference/lib"
unzip -qjo "$depth_archive" 'build/native/include/*' -d "$depth_reference/include"
unzip -qo "$depth_archive" LICENSE ThirdPartyNotices.txt -d "$depth_reference"
unzip -p "$depth_archive" runtimes/osx-arm64/native/libonnxruntime.dylib > "$depth_reference/lib/libonnxruntime.1.31.0.dylib"
bash "$depth_root/third/depth-native/build-reduced-macos.sh"
python3 "$depth_root/third/depth-native/package_reduced.py" "$depth_work"
