#! /bin/bash
set -e

PROJECT_ROOT=$(pwd)
BUILD_DIR="open62541_build"
rm -rf $BUILD_DIR
# todo: add -DUA_ENABLE_ENCRYPTION=MBEDTLS
cmake -B $BUILD_DIR $PROJECT_ROOT/open62541/ -DBUILD_SHARED_LIBS=ON -DUA_ENABLE_INLINABLE_EXPORT=ON -DCMAKE_INSTALL_PREFIX=install -DUA_BUILD_EXAMPLES=OFF -DUA_BUILD_UNIT_TESTS=OFF -DUA_ENABLE_AMALGAMATION=ON -DUA_MULTITHREADING=0 -DUA_LOGLEVEL=100
cmake --build $BUILD_DIR -j 12
patch $BUILD_DIR/open62541.h -i $PROJECT_ROOT/remove_bitfields.patch

# Update the flutter project

if command -v nix-env &> /dev/null; then
  dart run ffigen --config ffigen.yaml
else
  dart run ffigen # Bindings
fi
cp $PROJECT_ROOT/$BUILD_DIR/bin/libopen62541.* $PROJECT_ROOT/lib/ # library files
