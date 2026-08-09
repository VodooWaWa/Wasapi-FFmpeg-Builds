#!/bin/bash

# nv-codec-headers 选择策略（硬化版）：
#   - 现代 FFmpeg（含未带 addin 时的 99999999 哨兵、以及 8.0+）→ 一律用 sdk/12.2（CUDA 12.2，驱动 ≥ R535）
#   - 仅古老版本（FFmpeg 4.x–7.x，即 ffver < 800）→ 回退 sdk/11.1
# 不再依赖「ffbuild_ffver 解析 ADDINS_STR 命中 800/801 → 切到 sdk/13.0」这条脆弱且反向的边界，
# 避免某天 addin 名字带 "8.0/8.1" 或匹配逻辑变动时静默跳到 sdk/13.0（要求驱动 ≥ R610，一夜回到解放前）。

SCRIPT_REPO="https://github.com/FFmpeg/nv-codec-headers.git"
SCRIPT_COMMIT="f8339c06648fb6642aac1261d76e4158dc0b5401"
SCRIPT_BRANCH="sdk/12.2"

SCRIPT_REPO3="https://github.com/FFmpeg/nv-codec-headers.git"
SCRIPT_COMMIT3="afae1834257b919848c5deb21a17c7355616b1ee"
SCRIPT_BRANCH3="sdk/11.1"

ffbuild_enabled() {
    # 仅老版本 FFmpeg（< 4.0.4）不支持 ffnvcodec；现代构建一律启用。
    # 注意：ffbuild_ffver 在未带 addin 时返回哨兵 99999999，这里只做下限判断，
    # 不再依赖上面脆弱的「winarm64 且 ffver<=801 才禁用」分支。
    (( $(ffbuild_ffver) >= 404 )) || return -1
    return 0
}

ffbuild_dockerdl() {
    default_dl ffnvcodec
    # sdk/11.1 仅作老版本 FFmpeg 的回退，按需克隆
    echo "git-mini-clone \"$SCRIPT_REPO3\" \"$SCRIPT_COMMIT3\" ffnvcodec3"
}

ffbuild_dockerbuild() {
    # 现代 FFmpeg（含 99999999 哨兵 / 8.0+）一律用 sdk/12.2；
    # 只有古老版本（ffver < 800，即 4.x–7.x）才回退 sdk/11.1。
    if (( $FFVER < 800 )); then
        cd ffnvcodec3
    else
        cd ffnvcodec
    fi

    make PREFIX="$FFBUILD_PREFIX" DESTDIR="$FFBUILD_DESTDIR" install
}

ffbuild_configure() {
    echo --enable-ffnvcodec --enable-cuda-llvm
}

ffbuild_unconfigure() {
    echo --disable-ffnvcodec --disable-cuda-llvm
}

ffbuild_cflags() {
    return 0
}

ffbuild_ldflags() {
    return 0
}
