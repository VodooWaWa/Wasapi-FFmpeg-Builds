#!/bin/bash
# Recompile cleanly and emit a git-format patch of the whole WASAPI device.
set -e

cd /build/ffmpeg

echo "==> resetting the tree"
git checkout -- . 2>/dev/null || true
rm -f libavdevice/wasapi_dec.c

bash /w/apply-wasapi.sh /build/ffmpeg /w/wasapi_dec.c >/dev/null

echo "==> recompiling (must be warning free)"
rm -f libavdevice/wasapi_dec.o
make libavdevice/wasapi_dec.o 2>&1 | tee /tmp/cc.log
if grep -qi warning /tmp/cc.log; then
    echo "!! warnings remain"; exit 1
fi
[[ -f libavdevice/wasapi_dec.o ]] || { echo "!! object missing"; exit 1; }
echo "=== CLEAN COMPILE OK ==="

echo "==> generating patch"
git add -A libavdevice/wasapi_dec.c
git -c user.name=wasapi -c user.email=wasapi@local commit -q -am \
    "avdevice/wasapi: add WASAPI audio capture input device

Adds a WASAPI input device for Windows supporting:
 - loopback capture of render endpoints (record system audio without a
   virtual sound card)
 - normal capture endpoints (microphone / line in)
 - shared and exclusive mode
 - per-process capture on Windows 10 build 20348+ (pid=)
 - silence padding while an endpoint is idle

Usage:
  ffmpeg -f wasapi -list_devices true -i dummy
  ffmpeg -f wasapi -i default -c:a flac out.flac
  ffmpeg -f wasapi -i pid=1234 -c:a aac app.m4a"

mkdir -p /w/patches-out
git format-patch -1 --stdout > /w/patches-out/0001-avdevice-wasapi-add-input-device.patch
echo "==> wrote /w/patches-out/0001-avdevice-wasapi-add-input-device.patch"
wc -l /w/patches-out/0001-avdevice-wasapi-add-input-device.patch
