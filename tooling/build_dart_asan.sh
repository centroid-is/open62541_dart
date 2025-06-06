#! /usr/bin/env bash
set -e


BUILD_DIR="asan_build"

# Download
mkdir $BUILD_DIR
cd $BUILD_DIR 
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="$PATH:$PWD/depot_tools"
mkdir dart-sdk
cd dart-sdk
fetch dart

# Build
cd sdk
export ASAN_OPTIONS="handle_segv=0:detect_leaks=1:detect_stack_use_after_return=0:disable_coredump=0:abort_on_error=1"
export ASAN_SYMBOLIZER_PATH="$PWD/buildtools/mac-arm64/clang/bin/llvm-symbolizer"
./tools/build.py --mode release --arch x64 --sanitizer asan runtime runtime_precompiled create_sdk
