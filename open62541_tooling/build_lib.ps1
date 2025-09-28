$PROJECT_ROOT = $pwd
$MBEDTLS_VERSION = "3.6.3"
$MBEDTLS_URL = "https://github.com/Mbed-TLS/mbedtls/archive/refs/tags/v$MBEDTLS_VERSION.tar.gz"

if (-not (Test-Path "mbedtls-$MBEDTLS_VERSION")) {
    Invoke-WebRequest -Uri $MBEDTLS_URL -OutFile "mbedtls-$MBEDTLS_VERSION.tar.gz"
    tar -xzf "mbedtls-$MBEDTLS_VERSION.tar.gz"
}

Set-Location "mbedtls-$MBEDTLS_VERSION"
cmake -B build -S . -DMBEDTLS_FATAL_WARNINGS=OFF -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DBUILD_SHARED_LIBS=OFF
cmake --build build -j 4 --config RelWithDebInfo
$MBEDTLS_LIB = "$PWD\build\library\RelWithDebInfo\mbedtls.lib"
$MBEDX509_LIB = "$PWD\build\library\RelWithDebInfo\mbedx509.lib"
$MBEDCRYPTO_LIB = "$PWD\build\library\RelWithDebInfo\mbedcrypto.lib"
$MBEDTLS_INCLUDE = "$PWD\include"

Set-Location $PROJECT_ROOT

if (-not (Test-Path "open62541")) {
    git submodule update --init --recursive
}

git apply $PROJECT_ROOT\open62541_tooling\SecureZeroMem.patch --directory open62541

$BUILD_DIR = "$PROJECT_ROOT\open62541_build"

cmake --fresh -B $BUILD_DIR -S open62541 -DBUILD_SHARED_LIBS=ON `
    -DUA_ENABLE_INLINABLE_EXPORT=ON `
    -DUA_ENABLE_ENCRYPTION=MBEDTLS `
    -DUA_ENABLE_AMALGAMATION=ON `
    -DMBEDTLS_LIBRARY="$MBEDTLS_LIB" `
    -DMBEDX509_LIBRARY="$MBEDX509_LIB" `
    -DMBEDCRYPTO_LIBRARY="$MBEDCRYPTO_LIB" `
    -DMBEDTLS_INCLUDE_DIRS="$MBEDTLS_INCLUDE" `
    -DUA_MULTITHREADING=0 -DUA_LOGLEVEL=100 `
    -DCMAKE_GENERATOR_PLATFORM=x64

cmake --build $BUILD_DIR -j 4 --config RelWithDebInfo

Copy-Item $BUILD_DIR\bin\RelWithDebInfo\open62541.dll $PROJECT_ROOT\lib\libopen62541.dll
