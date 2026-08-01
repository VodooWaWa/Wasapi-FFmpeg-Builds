#!/bin/bash
# Build a self-contained, statically linked ffmpeg.exe (+ ffprobe.exe) with the
# WASAPI input device and all native FFmpeg codecs. No external libraries, so it
# runs on any Windows machine with no extra DLLs.
set -e

cd /build/ffmpeg

echo "==> resetting the tree"
git checkout -- . 2>/dev/null || true
rm -f libavdevice/wasapi_dec.c

bash /w/apply-wasapi.sh /build/ffmpeg /w/wasapi_dec.c >/dev/null

echo "==> configure (full clean reconfigure)"
rm -f ffbuild/config.mak ffbuild/config.h
./configure \
    --arch=x86_64 --target-os=mingw32 --cross-prefix=x86_64-w64-mingw32- \
    --enable-gpl --enable-version3 \
    --enable-w32threads \
    --enable-static --disable-shared \
    --disable-debug --disable-doc \
    --disable-ffplay \
    --enable-indev=wasapi \
    --extra-ldflags="-static -static-libgcc" \
    --pkg-config-flags="--static" \
    --extra-version="wasapi" \
    > /tmp/conf.log 2>&1 || { echo "!! configure failed"; tail -40 /tmp/conf.log; exit 1; }

echo "==> verifying wasapi is enabled"
grep -q 'CONFIG_WASAPI_INDEV=yes' ffbuild/config.mak \
    && echo "   CONFIG_WASAPI_INDEV=yes" \
    || { echo "!! wasapi not enabled"; exit 1; }

echo "==> building (this takes a while)"
make -j"$(nproc)" ffmpeg.exe ffprobe.exe > /tmp/make.log 2>&1 || {
    echo "!! build failed"; tail -60 /tmp/make.log; exit 1; }

mkdir -p /w/out
cp ffmpeg.exe ffprobe.exe /w/out/
x86_64-w64-mingw32-strip /w/out/ffmpeg.exe /w/out/ffprobe.exe 2>/dev/null || true

echo "=== BUILD OK ==="
ls -la /w/out/
echo "==> confirming the muxer/indev list contains wasapi"
# quick static check: the string must be present in the binary
if grep -a -q wasapi /w/out/ffmpeg.exe; then
    echo "   'wasapi' present in ffmpeg.exe"
else
    echo "!! 'wasapi' string not found in binary"; exit 1
fi
