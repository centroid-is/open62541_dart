#! /bin/bash
rm -rf open62541_examples
mkdir open62541_examples
cd open62541_examples
cmake ../open62541/ -DUA_BUILD_EXAMPLES=ON -DUA_BUILD_UNIT_TESTS=OFF -DUA_LOGLEVEL=100
cmake --build . -j 12
