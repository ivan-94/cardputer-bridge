#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
xcode_developer_dir="${XCODE_DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
build_dir="$project_root/artifacts/build/host"
sdk_path=$(DEVELOPER_DIR="$xcode_developer_dir" xcrun --sdk macosx --show-sdk-path)

cmake -S "$project_root" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_COMPILER="$xcode_developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++" \
  -DCMAKE_OSX_SYSROOT="$sdk_path"
cmake --build "$build_dir"
