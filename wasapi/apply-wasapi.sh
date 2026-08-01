#!/bin/bash
# Wire the WASAPI input device into an FFmpeg source tree.
# Usage: apply-wasapi.sh <path-to-ffmpeg-source> <path-to-wasapi_dec.c>
set -e

FFSRC="${1:?usage: apply-wasapi.sh <ffmpeg-src> <wasapi_dec.c>}"
WASAPI_C="${2:?usage: apply-wasapi.sh <ffmpeg-src> <wasapi_dec.c>}"

cd "$FFSRC"

if [[ ! -f configure || ! -d libavdevice ]]; then
    echo "error: $FFSRC does not look like an FFmpeg source tree" >&2
    exit 1
fi

# insert_after <file> <literal-anchor> <text> <marker>
#
# The anchor is matched literally, never as a regex. Anchors are passed through
# ENVIRON rather than -v because awk applies escape processing to -v values:
# gawk turns "\$" into "$" (and warns), mawk keeps it, so a backslash-escaped
# regex silently matches nothing under one implementation and works under the
# other. index() on an ENVIRON string behaves identically everywhere.
insert_after() {
    local file="$1" anchor="$2" text="$3" marker="$4"

    if grep -qF "$marker" "$file"; then
        echo "  [skip] $file already patched"
        return 0
    fi

    if ! grep -qF "$anchor" "$file"; then
        echo "error: anchor '$anchor' not found in $file" >&2
        return 1
    fi

    WASAPI_ANCHOR="$anchor" WASAPI_TEXT="$text" awk '
        { print }
        !done && index($0, ENVIRON["WASAPI_ANCHOR"]) { print ENVIRON["WASAPI_TEXT"]; done = 1 }
    ' "$file" > "$file.wasapi.tmp"

    # Overwrite in place so the original mode (configure must stay executable)
    # and inode are preserved.
    cat "$file.wasapi.tmp" > "$file"
    rm -f "$file.wasapi.tmp"

    if ! grep -qF "$marker" "$file"; then
        echo "error: insertion into $file did not take effect" >&2
        return 1
    fi
    echo "  [ok]   patched $file"
}

echo "==> installing libavdevice/wasapi_dec.c"
cp "$WASAPI_C" libavdevice/wasapi_dec.c

echo "==> registering the demuxer in libavdevice/alldevices.c"
insert_after libavdevice/alldevices.c \
    'extern const FFInputFormat  ff_vfwcap_demuxer;' \
    'extern const FFInputFormat  ff_wasapi_demuxer;' \
    'ff_wasapi_demuxer'

echo "==> adding the build rule to libavdevice/Makefile"
insert_after libavdevice/Makefile \
    'OBJS-$(CONFIG_VFWCAP_INDEV)' \
    'OBJS-$(CONFIG_WASAPI_INDEV)              += wasapi_dec.o' \
    'CONFIG_WASAPI_INDEV'

echo "==> declaring dependencies in configure"
insert_after configure \
    'dshow_indev_extralibs=' \
    'wasapi_indev_deps="IAudioClient"
wasapi_indev_extralibs="-lole32 -loleaut32 -luuid"' \
    'wasapi_indev_deps'

echo "==> adding the IAudioClient probe to configure"
insert_after configure \
    'check_type "dshow.h" IBaseFilter' \
    'check_type "windows.h initguid.h mmdeviceapi.h audioclient.h" IAudioClient' \
    'mmdeviceapi.h'

# The probe above is the only place that defines the IAudioClient config item.
# Verify it really landed inside the win32 section rather than somewhere random.
if ! grep -q 'IAudioClient' configure; then
    echo "error: configure probe was not applied" >&2
    exit 1
fi

echo "==> documenting the device in doc/indevs.texi"
if ! grep -q '@section wasapi' doc/indevs.texi; then
    DOC=$(cat <<'TEXI'

@section wasapi

Windows Audio Session API (WASAPI) input device.

Unlike @code{dshow}, this device can record what a playback endpoint is
@emph{outputting} (loopback capture), which is the usual way to record system
audio without installing a virtual sound card.

The input name selects the endpoint:

@table @option
@item default
@itemx default_output
The default playback device, captured in loopback mode. This is the default.
@item default_input
The default recording device, for example a microphone.
@item @var{name}
A device name as printed by @option{-list_devices}, matched exactly first and
then case insensitively as a substring. Endpoint ids are accepted as well.
@item pid=@var{number}
Capture only the audio produced by the given process and its children.
Requires Windows 10 build 20348 or newer.
@end table

@subsection Options

@table @option
@item -list_devices @var{true}
List the available endpoints and exit.

@item -loopback @var{bool}
Force loopback capture on or off. By default it is enabled for playback
endpoints and disabled for recording endpoints.

@item -exclusive @var{bool}
Open the endpoint in exclusive mode. Cannot be combined with loopback.

@item -audio_buffer_size @var{milliseconds}
Size of the capture buffer, 500 by default.

@item -pid @var{number}
Capture a single process. Equivalent to the @code{pid=} input name.

@item -exclude_pid @var{bool}
Invert @option{-pid}, capturing everything except the given process.

@item -fill_silence @var{bool}
Emit digital silence while the endpoint is idle so that the recording keeps
running in real time. Enabled by default; a loopback endpoint delivers no data
at all when nothing is playing.

@item -silence_threshold @var{milliseconds}
How long the endpoint has to stay idle before silence is inserted, 100 by
default.

@item -sample_rate @var{rate}
@itemx -channels @var{count}
@itemx -format @var{float|s16}
Request a specific format instead of the shared mode mix format.
@end table

@subsection Examples

@itemize
@item List the endpoints:
@example
ffmpeg -f wasapi -list_devices true -i dummy
@end example

@item Record everything the computer plays:
@example
ffmpeg -f wasapi -i default -c:a flac out.flac
@end example

@item Record a microphone:
@example
ffmpeg -f wasapi -i default_input -c:a aac mic.m4a
@end example

@item Record only what one process plays:
@example
ffmpeg -f wasapi -i pid=12345 -c:a aac app.m4a
@end example
@end itemize
TEXI
)
    if grep -q '@section xcbgrab' doc/indevs.texi; then
        WASAPI_TEXT="$DOC" awk '
            !done && index($0, "@section xcbgrab") { print ENVIRON["WASAPI_TEXT"]; print ""; done = 1 }
            { print }
        ' doc/indevs.texi > doc/indevs.texi.tmp &&
            cat doc/indevs.texi.tmp > doc/indevs.texi && rm -f doc/indevs.texi.tmp
    else
        printf '%s\n' "$DOC" >> doc/indevs.texi
    fi
    echo "  [ok]   patched doc/indevs.texi"
else
    echo "  [skip] doc/indevs.texi already patched"
fi

# Final gate. A missing build rule only surfaces as an "undefined reference to
# ff_wasapi_demuxer" link error after a full compile, so check every edit here.
echo "==> verifying"
fail=0
check() {
    if grep -qF "$2" "$1"; then
        echo "  [ok]   $1 contains $2"
    else
        echo "  [FAIL] $1 is missing $2" >&2
        fail=1
    fi
}
[[ -f libavdevice/wasapi_dec.c ]] || { echo "  [FAIL] libavdevice/wasapi_dec.c missing" >&2; fail=1; }
check libavdevice/Makefile      'wasapi_dec.o'
check libavdevice/alldevices.c  'ff_wasapi_demuxer'
check configure                 'wasapi_indev_deps'
check configure                 'wasapi_indev_extralibs'
check configure                 'IAudioClient'
[[ -x configure ]] || { echo "  [FAIL] configure lost its executable bit" >&2; fail=1; }

if [[ $fail != 0 ]]; then
    echo "error: WASAPI integration is incomplete, aborting" >&2
    exit 1
fi

echo
echo "WASAPI input device applied successfully."
