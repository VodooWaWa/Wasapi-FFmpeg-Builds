#!/bin/bash
# Quick cross-compile check for the WASAPI input device.
# Runs inside a Debian container with a mingw-w64 toolchain.
set -e

export DEBIAN_FRONTEND=noninteractive

if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    echo "==> installing toolchain"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        gcc-mingw-w64-x86-64 gcc git make pkg-config ca-certificates >/dev/null
fi

cd /build

if [[ ! -d ffmpeg ]]; then
    echo "==> cloning FFmpeg"
    git clone --depth 1 --filter=blob:none https://github.com/FFmpeg/FFmpeg.git ffmpeg
fi

cd ffmpeg
echo "==> resetting the tree"
git checkout -- . 2>/dev/null || true
rm -f libavdevice/wasapi_dec.c

bash /w/apply-wasapi.sh /build/ffmpeg /w/wasapi_dec.c

if [[ ! -f ffbuild/config.mak || -n "$RECONF" ]]; then
    echo "==> configure"
    ./configure \
        --arch=x86_64 --target-os=mingw32 --cross-prefix=x86_64-w64-mingw32- \
        --disable-everything --disable-doc --disable-programs --disable-network \
        --disable-autodetect --disable-x86asm --disable-asm --disable-pthreads \
        --enable-indev=wasapi > /tmp/conf.log 2>&1 || {
            echo "!! configure failed"; tail -40 /tmp/conf.log; exit 1; }
fi

echo "==> configure results for wasapi:"
grep -i wasapi ffbuild/config.h ffbuild/config.mak || echo "  (nothing found -- device not enabled!)"

echo "==> compiling libavdevice/wasapi_dec.o"
make libavdevice/wasapi_dec.o 2>&1 | tail -60

if [[ -f libavdevice/wasapi_dec.o ]]; then
    echo "=== COMPILE OK ==="
    x86_64-w64-mingw32-nm libavdevice/wasapi_dec.o | grep -i " T \| U " | head -30
else
    echo "=== COMPILE FAILED ==="
    exit 1
fi
