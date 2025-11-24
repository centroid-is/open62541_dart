#! /bin/sh
set -e

PROJECT_ROOT=$(pwd)
OPEN62541_DIR="$PROJECT_ROOT/third_party/open62541"

patch $OPEN62541_DIR/open62541.h -o $OPEN62541_DIR/open62541_modified.h -i $PROJECT_ROOT/open62541_tooling/remove_bitfields.patch