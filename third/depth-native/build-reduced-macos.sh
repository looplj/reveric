#!/usr/bin/env bash
set -euo pipefail
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo 'This CPU runtime build targets macOS arm64.' >&2
  exit 2
fi
depth_root=$(cd "$(dirname "$0")/../.." && pwd)
depth_work="$depth_root/build/depth-native"
depth_reduced="$depth_work/ort-reduced-1.31.0"
depth_source="$depth_reduced/source"
mkdir -p "$depth_reduced"
if [ ! -d "$depth_source/.git" ]; then
  git clone --filter=blob:none --depth 1 --branch v1.31.0 --sparse \
    https://github.com/looplj/onnxruntime.git "$depth_source"
fi
if [ "$(git -C "$depth_source" rev-parse 'HEAD^{tree}')" != 6ebffa882d87ca25e05568f369892e4036124e14 ]; then
  echo 'ONNX Runtime source does not match the pinned v1.31.0 tree.' >&2
  exit 2
fi
git -C "$depth_source" sparse-checkout set cmake include model_package onnxruntime/core \
  onnxruntime/contrib_ops onnxruntime/lora onnxruntime/tool onnxruntime/wasm \
  orttraining/orttraining/training_ops/cpu tools
cp "$depth_root/third/depth-native/required_operators.config" "$depth_reduced/required_operators.config"
depth_python="${DEPTH_BUILD_PYTHON:-$depth_reduced/venv/bin/python}"
if [ ! -x "$depth_python" ]; then
  python3 -m venv "$depth_reduced/venv"
  "$depth_python" -m pip install flatbuffers==25.12.19 packaging==26.3 setuptools==84.2.1
fi
"$depth_python" "$depth_source/tools/ci_build/build.py" \
  --build_dir "$depth_reduced/build" --config MinSizeRel \
  --update --build --parallel 4 --build_shared_lib --enable_lto --no_telemetry \
  --disable_ml_ops --disable_rtti --disable_types float8 optional sparsetensor \
  --include_ops_by_config "$depth_reduced/required_operators.config" \
  --skip_submodule_sync --skip_tests --compile_no_warning_as_error \
  --cmake_generator Ninja \
  --cmake_extra_defines CMAKE_OSX_ARCHITECTURES=arm64 CMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER CMAKE_POLICY_VERSION_MINIMUM=3.5 \
  onnxruntime_BUILD_UNIT_TESTS=OFF
