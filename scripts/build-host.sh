#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
build_dir="$project_root/artifacts/build/host"

if command -v xcrun >/dev/null 2>&1; then
  if [ -n "${XCODE_DEVELOPER_DIR:-}" ]; then
    xcode_developer_dir="$XCODE_DEVELOPER_DIR"
  elif [ -d /Applications/Xcode-beta.app/Contents/Developer ]; then
    xcode_developer_dir=/Applications/Xcode-beta.app/Contents/Developer
  else
    xcode_developer_dir=$(xcode-select -p)
  fi
  sdk_path=$(DEVELOPER_DIR="$xcode_developer_dir" xcrun --sdk macosx --show-sdk-path)
  cmake -S "$project_root" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_CXX_COMPILER="$xcode_developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++" \
    -DCMAKE_OSX_SYSROOT="$sdk_path"
else
  cmake -S "$project_root" -B "$build_dir" -DCMAKE_BUILD_TYPE=Debug
fi
cmake --build "$build_dir"
