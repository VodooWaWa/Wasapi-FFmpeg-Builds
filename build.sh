#!/bin/bash
set -xe
shopt -s globstar
cd "$(dirname "$0")"

# --- Git Bash / MSYS host compatibility -------------------------------------
# MSYS rewrites lone POSIX paths (e.g. the "/build.sh" argument) into Windows
# paths before handing them to native binaries such as docker.exe, which turns
# every container-side path into garbage like "C:/Program Files/Git/build.sh".
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) IS_MSYS=1 ;;
    *)                    IS_MSYS=0 ;;
esac

if [[ $IS_MSYS == 1 ]]; then
    export MSYS_NO_PATHCONV=1
    export MSYS2_ARG_CONV_EXCL='*'
fi

# Multi-GB build trees must not go through a recycle-bin/trash wrapper: it is
# slow, fills the bin, and fails outright on container-created files.
if [[ -x /usr/bin/rm ]]; then RM=/usr/bin/rm; else RM=rm; fi

source util/vars.sh

source "variants/${TARGET}-${VARIANT}.sh"

for addin in ${ADDINS[*]}; do
    source "addins/${addin}.sh"
done

if [[ $IS_MSYS == 1 ]]; then
    # id -u on Git Bash returns the Windows RID (e.g. 197609). Passing it to
    # the container would run as a user that does not exist inside the image;
    # Docker Desktop handles bind mount ownership on its own anyway.
    UIDARGS=()
elif docker info -f "{{println .SecurityOptions}}" | grep rootless >/dev/null 2>&1; then
    UIDARGS=()
else
    UIDARGS=( -u "$(id -u):$(id -g)" )
fi

"$RM" -rf ffbuild
mkdir ffbuild

FFMPEG_REPO="${FFMPEG_REPO:-https://github.com/FFmpeg/FFmpeg.git}"
FFMPEG_REPO="${FFMPEG_REPO_OVERRIDE:-$FFMPEG_REPO}"
GIT_BRANCH="${GIT_BRANCH:-master}"
GIT_BRANCH="${GIT_BRANCH_OVERRIDE:-$GIT_BRANCH}"

# Mirrors that do not implement partial clone silently fall back to a full
# history download; FFMPEG_CLONE_ARGS="--depth=1" is the fast way out.
CLONE_ARGS="${FFMPEG_CLONE_ARGS:---filter=blob:none}"

# Where the compile actually happens inside the container. On Docker Desktop
# the /ffbuild bind mount is a Windows drive share and far too slow to compile
# on, so use the container filesystem and copy the results out at the end.
if [[ $IS_MSYS == 1 ]]; then
    WORKDIR_CT="/ffwork"
else
    WORKDIR_CT="/ffbuild"
fi

if [[ $IS_MSYS == 1 ]]; then
    # MSYS /tmp lives in the Windows temp dir, which the Linux docker daemon
    # cannot resolve. Put the script inside ffbuild, which is mounted already.
    BUILD_SCRIPT="$PWD/ffbuild/docker-build.sh"
    BUILD_SCRIPT_CT="/ffbuild/docker-build.sh"
    BUILD_SCRIPT_MOUNT=()
else
    BUILD_SCRIPT="$(mktemp)"
    BUILD_SCRIPT_CT="/build.sh"
    BUILD_SCRIPT_MOUNT=( -v "$BUILD_SCRIPT":/build.sh )
    trap "$RM -f -- '$BUILD_SCRIPT'" EXIT
fi

cat <<EOF >"$BUILD_SCRIPT"
    set -xe
    WORK="$WORKDIR_CT"
    # Clear the bind-mount contents WITHOUT removing the mountpoint itself.
    # On rootful GitHub-hosted runners the container runs as a non-root uid
    # (-u $(id -u):$(id -g)), and "rm -rf /ffbuild" would try to rmdir the
    # mountpoint, which needs write permission on "/" and fails with
    # "Permission denied". Removing only the contents keeps ownership on the
    # host consistent so the later host-side cleanup works too.
    mkdir -p "\$WORK"
    find "\$WORK" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    mkdir -p "\$WORK"
    cd "\$WORK"

    git clone $CLONE_ARGS --branch='$GIT_BRANCH' '$FFMPEG_REPO' ffmpeg
    cd ffmpeg

    if [[ -f /ffmods/apply-wasapi.sh ]]; then
        bash /ffmods/apply-wasapi.sh "\$WORK/ffmpeg" /ffmods/wasapi_dec.c
    fi

    for p in /ffmods/*.patch; do
        [[ -f "\$p" ]] || continue
        echo "Applying \$p"
        git apply "\$p"
    done

    # --- Pin nv-codec-headers to sdk/12.2 (override BtbN base image's 13.1) ---
    # this fork's scripts.d/50-ffnvcodec.sh is NOT invoked by build.sh (it only
    # runs during BtbN base-image builds, which our CI does not perform), so the
    # nv-codec-headers ffmpeg compiles against comes from the BtbN base image
    # (NVENC API 13.1, needs driver >= R610). To actually pin 12.2 we vendor the
    # sdk/12.2 source in ./nvh-sdk12.2 (no network needed in CI), bind-mount it in
    # as /nvh_src, copy to a container-local dir and install it before ./configure.
    # We copy first so the 'make' step does not write ffnvcodec.pc back into the
    # bind-mounted repo directory.
    rm -rf /nvh_build
    cp -a /nvh_src /nvh_build
    make -C /nvh_build install PREFIX=/nvh12
    echo "12.2-f8339c0" > /nv-codec-headers.version
    export PKG_CONFIG_PATH=/nvh12/lib/pkgconfig:\$PKG_CONFIG_PATH
    NVH_CFLAGS=-I/nvh12/include

    NVH_VER=""
    [[ -f /nv-codec-headers.version ]] && NVH_VER="\$(cat /nv-codec-headers.version)"
    ./configure --prefix="\$WORK/prefix" --pkg-config-flags="--static" \$FFBUILD_TARGET_FLAGS \$FF_CONFIGURE \
        --extra-cflags="\$NVH_CFLAGS \$FF_CFLAGS" --extra-cxxflags="\$FF_CXXFLAGS" --extra-libs="\$FF_LIBS" \
        --extra-ldflags="\$FF_LDFLAGS" --extra-ldexeflags="\$FF_LDEXEFLAGS" \
        --cc="\$CC" --cxx="\$CXX" --ar="\$AR" --ranlib="\$RANLIB" --nm="\$NM" \
        --extra-version="\$(date +%Y%m%d)\${NVH_VER:+-nvh\$NVH_VER}" || { cat ffbuild/config.log; exit 1; }
    make -j\$(nproc) V=1
    make install install-doc

    # When building outside the bind mount (Docker Desktop bind mounts are ~70x
    # slower for small files), publish only what packaging needs, in one pass.
    if [[ "\$WORK" != "/ffbuild" ]]; then
        rm -rf /ffbuild/prefix /ffbuild/ffmpeg
        mkdir -p /ffbuild/prefix /ffbuild/ffmpeg
        cp -a "\$WORK"/prefix/bin /ffbuild/prefix/
        cp -a "\$WORK"/prefix/share /ffbuild/prefix/
        "\$WORK"/ffmpeg/ffbuild/version.sh "\$WORK"/ffmpeg > /ffbuild/BUILD_VERSION
        for f in COPYING.GPLv3 COPYING.GPLv2 COPYING.LGPLv3 COPYING.LGPLv2.1; do
            if [[ -f "\$WORK/ffmpeg/\$f" ]]; then cp "\$WORK/ffmpeg/\$f" /ffbuild/ffmpeg/; fi
        done
    fi
EOF

[[ -t 1 ]] && TTY_ARG="-t" || TTY_ARG=""

# Local FFmpeg modifications (out of tree devices, patches) live in ./wasapi
FFMODS_ARGS=()
[[ -d "$PWD/wasapi" ]] && FFMODS_ARGS=( -v "$PWD/wasapi":/ffmods )

# nv-codec-headers sdk/12.2 is vendored in ./nvh-sdk12.2 (no network needed in CI).
# Bind-mount it into the container as /nvh_src; docker-build.sh copies it to a
# container-local dir and installs it before ./configure. The base image ships
# 13.1 (needs driver >= R610); this pins 12.2 (driver >= R535).
NVH_SRC_DIR="$PWD/nvh-sdk12.2"
NVH_MOUNT_ARGS=( -v "$NVH_SRC_DIR":/nvh_src )

docker run --rm -i $TTY_ARG "${UIDARGS[@]}" -v "$PWD/ffbuild":/ffbuild "${FFMODS_ARGS[@]}" "${NVH_MOUNT_ARGS[@]}" "${BUILD_SCRIPT_MOUNT[@]}" "$IMAGE" bash "$BUILD_SCRIPT_CT"

if [[ -n "$FFBUILD_OUTPUT_DIR" ]]; then
    mkdir -p "$FFBUILD_OUTPUT_DIR"
    package_variant ffbuild/prefix "$FFBUILD_OUTPUT_DIR"
    [[ -n "$LICENSE_FILE" ]] && cp "ffbuild/ffmpeg/$LICENSE_FILE" "$FFBUILD_OUTPUT_DIR/LICENSE.txt"
    "$RM" -rf ffbuild
    exit 0
fi

mkdir -p artifacts
ARTIFACTS_PATH="$PWD/artifacts"
# version.sh needs the git tree, which stays inside the container when the
# build ran outside the bind mount; the container writes BUILD_VERSION instead.
if [[ -f ffbuild/BUILD_VERSION ]]; then
    FF_VERSION="$(cat ffbuild/BUILD_VERSION)"
else
    FF_VERSION="$(./ffbuild/ffmpeg/ffbuild/version.sh ffbuild/ffmpeg)"
fi
BUILD_NAME="ffmpeg-${FF_VERSION}-${TARGET}-${VARIANT}${ADDINS_STR:+-}${ADDINS_STR}"

mkdir -p "ffbuild/pkgroot/$BUILD_NAME"
package_variant ffbuild/prefix "ffbuild/pkgroot/$BUILD_NAME"

[[ -n "$LICENSE_FILE" ]] && cp "ffbuild/ffmpeg/$LICENSE_FILE" "ffbuild/pkgroot/$BUILD_NAME/LICENSE.txt"

cd ffbuild/pkgroot
if [[ "${TARGET}" == win* ]]; then
    OUTPUT_FNAME="${BUILD_NAME}.zip"
    docker run --rm -i $TTY_ARG "${UIDARGS[@]}" -v "${ARTIFACTS_PATH}":/out -v "${PWD}/${BUILD_NAME}":"/${BUILD_NAME}" -w / "$IMAGE" zip -9 -r "/out/${OUTPUT_FNAME}" "$BUILD_NAME"
else
    OUTPUT_FNAME="${BUILD_NAME}.tar.xz"
    docker run --rm -i $TTY_ARG "${UIDARGS[@]}" -v "${ARTIFACTS_PATH}":/out -v "${PWD}/${BUILD_NAME}":"/${BUILD_NAME}" -w / "$IMAGE" tar -I "xz -T0" -cf "/out/${OUTPUT_FNAME}" "$BUILD_NAME"
fi
cd -

"$RM" -rf ffbuild

if [[ -n "$GITHUB_ACTIONS" ]]; then
    echo "build_name=${BUILD_NAME}" >> "$GITHUB_OUTPUT"
    echo "${OUTPUT_FNAME}" > "${ARTIFACTS_PATH}/${TARGET}-${VARIANT}${ADDINS_STR:+-}${ADDINS_STR}.txt"
fi
