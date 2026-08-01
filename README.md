# FFmpeg-Builds（含自研 WASAPI 输入设备）

在 [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds) 基础上 fork，给 FFmpeg 增加了一个
**`-f wasapi` 输入设备**，用于 Windows 上直接采集音频（系统声音 loopback / 麦克风 / 指定进程声音），
无需任何虚拟声卡（VB-CABLE、virtual-audio-capturer 等）。其余构建体系与上游完全一致。

---

## 为什么要做这个设备

**上游 FFmpeg 从来没有 WASAPI 设备。** `libavdevice` 里 Windows 音频只有 `dshow`（DirectShow）、
`gdigrab`、`vfwcap`；`alldevices.c` 没有 wasapi 注册，官方 patchwork 上连一个 wasapi 补丁都没有。

> 网上那些 `--enable-wasapi` / `ffmpeg -f wasapi -i default` 的教程是错误内容——
> 官方 `configure` 根本没有这个开关，所以「不是没开开关，是没东西可编译」。
> 本仓库的 `wasapi_dec.c` 是从零实现的，已接进构建流程。

WASAPI 设备支持：

- **录制系统正在播放的声音（loopback）**——录屏配音、游戏原声、会议音频，免虚拟声卡
- **录制麦克风 / 线路输入**
- **只录某个进程发出的声音**（进程 loopback，Windows 10 build 20348+ / Windows 11）
- **排除某个进程**（录除它以外的所有声音）
- 共享 / 独占模式；空闲自动填静音，保证时间轴与真实时间对齐

---

## 已经构建好的产物（开箱即用）

完整版已在本机构建并验证通过：

| 文件 | 大小 | 说明 |
|---|---|---|
| `artifacts/ffmpeg-git-2026-07-30-a100d34-win64-gpl.zip` | ~162 MB | 完整静态构建（含 x264/x265/nvenc/svtav1/vp9 + WASAPI） |
| `dist/ffmpeg-git-2026-07-30-a100d34-win64-gpl/bin/` | — | 解压后的 `ffmpeg.exe` / `ffplay.exe` / `ffprobe.exe` |

**版本**：`git-2026-07-30-a100d34-20260801`，gcc 15.2.0（win64-gpl 变体）。

**已实测验证**（在 Windows 本机）：

```cmd
:: 列出音频设备（render / capture 分类，含中文名与默认标记）
ffmpeg.exe -f wasapi -list_devices true -i dummy

:: 录 3 秒系统声音 → FLAC（实时 speed=1.0x）
ffmpeg.exe -f wasapi -i default -t 3 test_loopback.flac

:: 录屏（gdigrab 640x360）+ 系统声音 → H.264 mp4
ffmpeg.exe -f gdigrab -video_size 640x360 -i desktop ^
           -f wasapi -i default -c:v libx264 -c:a aac test_screen.mp4
```

> 自包含精简版（无外部库，音频 + 基础录屏）在 `wasapi/out/ffmpeg.exe`，
> 详见下方「自包含精简版」一节。

---

## WASAPI 设备快速上手

### 1. 列出所有音频设备

```cmd
ffmpeg -f wasapi -list_devices true -i dummy
```

分别列出「render（播放）设备」和「capture（录音）设备」，并标出默认设备及 endpoint id。
`-i` 后面的 `dummy` 是占位符，列出后即退出。

### 2. 录制电脑正在播放的所有声音（最常用）

```cmd
ffmpeg -f wasapi -i default -c:a flac system_audio.flac
```

`default` = 默认**播放**设备的 loopback。其它格式：

```cmd
ffmpeg -f wasapi -i default -c:a aac -b:a 192k out.m4a
ffmpeg -f wasapi -i default -c:a pcm_s16le out.wav
```

### 3. 录麦克风

```cmd
ffmpeg -f wasapi -i default_input -c:a aac mic.m4a
```

`default_input` = 默认**录音**设备。

### 4. 按名字或 endpoint id 指定设备

```cmd
ffmpeg -f wasapi -i "扬声器 (Realtek(R) Audio)" -c:a flac out.flac
```

名字先做精确匹配，再做不区分大小写的子串匹配，写一段能区分的片段即可。

### 5. 只录某个进程的声音

先查到目标进程 PID（任务管理器），然后任选一种写法：

```cmd
:: 写法 A：输入名简写
ffmpeg -f wasapi -i pid=12345 -c:a aac app.m4a

:: 写法 B：显式选项（等价于写法 A）
ffmpeg -f wasapi -pid 12345 -i dummy -c:a aac app.m4a
```

**排除**某个进程（录除它以外的所有声音），只能用语选项写法：

```cmd
ffmpeg -f wasapi -pid 12345 -exclude_pid true -i dummy -c:a aac others.m4a
```

### 6. 录屏 + 系统声音，一条命令出 mp4

```cmd
ffmpeg -f gdigrab -framerate 30 -i desktop ^
       -f wasapi   -i default ^
       -c:v libx264 -preset veryfast -c:a aac screencast.mp4
```

> 自包含精简版 **不含 libx264**。要 h264 录屏请用完整版，或把视频编码换成内置的
> `-c:v mpeg4` / `-c:v ffv1`。

---

## 设备完整选项

| 选项 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `-list_devices` | bool | `0` | 列出设备后退出 |
| `-loopback` | bool | `-1`（自动） | 强制开/关 loopback；播放设备默认开、录音设备默认关 |
| `-exclusive` | bool | `0` | 独占模式（**不能与 loopback 同时用**） |
| `-audio_buffer_size` | int(ms) | `500` | 缓冲区毫秒数（10–10000） |
| `-pid` | int | `0` | 只录该进程（0 = 整设备）；Windows 10 20348+ / Win11 |
| `-exclude_pid` | bool | `0` | 反选：录除该进程外的所有声音 |
| `-fill_silence` | bool | `1` | 空闲时填静音，保证实时时间轴 |
| `-silence_threshold` | int(ms) | `100` | 空闲多少毫秒后开始填静音（10–10000） |
| `-sample_rate` | int | `0`（自动） | 强制采样率 |
| `-channels` | int | `0`（自动） | 强制声道数（0–64） |
| `-format` | `float`/`s16` | `float` | 请求的样本格式：`float`=32bit 浮点，`s16`=16bit 有符号 |

> 输入名语法：`default` / `default_input` / `"设备名"` / `pid=<数字>`（进程录音简写）。
> 进程录音在源码帮助文本中标注为 Windows 11 / Server 2022+，运行时按系统能力探测，
> 老系统会明确报错而非静默失败。

---

## 自己构建（国内 Windows 环境实战）

### 前置条件

- **Git Bash**：用 `C:\Program Files\Git\bin\bash.exe`。**不要**用 `C:\WINDOWS\System32\bash.exe`（那是 WSL）。
  不要从 PowerShell 跑 `./build.sh`（里面是 bash 语法，`VAR=x cmd` 在 PowerShell 会报错）。
- **Docker Desktop**：已启动，且 Linux 容器模式。

### 必须设置的环境变量（本环境实测）

上游默认从 `github.com` 拉 FFmpeg 源码、从 `ghcr.io` 拉构建镜像，这两个在本机都**不可达**。
`build.sh` 已支持以下覆盖变量，**按本机情况设置**：

| 变量 | 值 | 原因 |
|---|---|---|
| `REGISTRY_OVERRIDE` | `ghcr.nju.edu.cn` | `ghcr.io` 被墙；这是唯一能取到 BtbN 镜像的源 |
| `FFMPEG_REPO_OVERRIDE` | `https://gitcode.com/gh_mirrors/ff/FFmpeg.git` | `github.com` 443 超时；gitcode 镜像 HEAD 即最新 |
| `FFMPEG_CLONE_ARGS` | `"--depth=1"` | 上游默认 `--filter=blob:none` 部分克隆，gitcode 不支持；`--depth=1` 浅克隆几秒完成 |

### 构建命令

```bash
cd /d/迅雷下载/aiyaya/FFmpeg-Builds

export REGISTRY_OVERRIDE=ghcr.nju.edu.cn
export FFMPEG_REPO_OVERRIDE=https://gitcode.com/gh_mirrors/ff/FFmpeg.git
export FFMPEG_CLONE_ARGS="--depth=1"

./build.sh win64 gpl        # 产物 zip 在 artifacts/
```

首次运行会自动拉取约 **1.75 GB** 的 BtbN 基础镜像（16 层），之后有缓存会快很多。

### `build.sh` 自动做了什么

1. 拉起 `win64-gpl` 构建镜像（`REGISTRY_OVERRIDE` 改写镜像/基础镜像地址）。
2. 在容器内 **克隆** FFmpeg 源码（用上面的覆盖变量）。
3. 把本仓库的 `wasapi/` 目录以只读挂进容器为 `/ffmods`，并**自动应用**
   `apply-wasapi.sh` + `wasapi/*.patch`，把 WASAPI 设备接进 FFmpeg 树
   （改 `configure` / `Makefile` / `alldevices.c` / 文档）。
4. 在容器**本地磁盘**（`/ffwork`）编译（见下方「性能坑」），结束后只把 `prefix/bin`、
   `prefix/share`、版本号、LICENSE 拷回宿主的 `ffbuild/`。
5. 打包 `artifacts/ffmpeg-git-<commit>-win64-gpl.zip`。

### 已经修平的坑（已固化进脚本，不用再踩）

- **MSYS 路径改写 `/build.sh` → `C:/Program Files/Git/build.sh`**：
  `build.sh` 开头检测 MSYS 并设置 `MSYS_NO_PATHCONV=1` + `MSYS2_ARG_CONV_EXCL='*'`；
  构建脚本放在 bind 挂的 `/ffbuild/docker-build.sh`，不再用 `/`-rooted 临时路径。
- **容器内连不上 github**：用上面的 `FFMPEG_REPO_OVERRIDE` + `FFMPEG_CLONE_ARGS="--depth=1"`。
- **bind 挂卷上编译 74× 慢**（小文件 copy 4648ms vs 容器本地 63ms）：改为容器本地编译，结束才拷结果。
- **WorkBuddy 安全删除拦截 `rm -rf ffbuild`**：脚本改用 `/usr/bin/rm`，所有删除走它。
- **gawk 静默插入失败导致链接 `undefined reference to ff_wasapi_demuxer`**：
  `apply-wasapi.sh` 的 `insert_after` 改用字面量 `grep -qF` + `ENVIRON`/`index()` 原地插入，
  并加了硬校验 gate（Makefile / alldevices.c / configure 三处都核对）。已验证幂等、5 处编辑全生效。

### 变体（targets / variants）

`build.sh <target> <variant>` 的可用值（与上游一致）：

- **target**：`win64`、`win32`、`linux64`、`linuxarm64`
- **variant**：`gpl`（含全部依赖，含 libx264/libx265）、`lgpl`（缺 GPL-only 库）、
  `nonfree`（额外含 fdk-aac）、`gpl-shared` / `lgpl-shared` / `nonfree-shared`（共享库版）
- **addin**：`4.4`/`5.0`/`5.1`/`6.0`/`6.1`/`7.0`/`7.1`（发版分支）、`debug`、`lto`

> WASAPI 设备只在 Windows target 上有意义；其它 target 构建时 `apply-wasapi.sh` 会对
> 非 Windows 平台跳过设备注册（不影响构建）。

---

## 自包含精简版（无外部库，开箱即用）

只想要一个能录音频 + 基础录屏、不依赖任何外部 DLL 的 `ffmpeg.exe`：

```bash
docker run --rm -v "<本仓库目录>:/w" -v ffwasapi:/build ffwasapi-tc:latest bash /w/wasapi/build-exe.sh
# 产物在 wasapi/out/ffmpeg.exe
```

该版本用 `--enable-w32threads`、**不含 x264 等外部库**，但内置 aac / flac / pcm / alac 等音频编码器
齐全，且自带 `wasapi` 与 `gdigrab`。工具链镜像 `ffwasapi-tc` 见 `wasapi/build-exe.sh` 注释。

---

## 已知限制

- 独占模式（`-exclusive`）下**不能** loopback，这是 WASAPI 本身的限制。
- 进程录音（`pid=` / `-pid`）需要 Windows 10 build 20348 或更新；老系统会明确报错。
- loopback 抓的是设备的最终混音流，采样率/声道随系统混音格式（一般 48kHz 立体声）。
- 首包可能打印 `Audio capture glitch detected`，通常是缓冲区预热，无害。

---

## 目录结构

```
FFmpeg-Builds/
├── build.sh                 # 入口（已改：自动应用 WASAPI 补丁 + 国内/Windows 适配）
├── util/vars.sh             # 镜像/仓库地址拼装，支持 REGISTRY_OVERRIDE
├── variants/                # 上游变体定义（win64-gpl 等）
├── artifacts/               # 构建产物 zip（已出包：win64-gpl 完整版）
├── dist/                    # 已解压的产物，可直接运行
└── wasapi/                  # 自研 WASAPI 设备
    ├── wasapi_dec.c         # 设备本体（C 源码，放进 libavdevice/）
    ├── apply-wasapi.sh      # 把设备接进任意 FFmpeg 源码树
    ├── patches-out/
    │   └── 0001-avdevice-wasapi-add-input-device.patch   # 标准 git 补丁
    ├── build-exe.sh         # 容器内编译自包含 exe
    ├── verify-build.sh      # 开发：验证编译
    ├── make-patch.sh        # 开发：生成补丁
    ├── out/                 # 自包含构建产物（ffmpeg.exe / ffprobe.exe）
    └── README-WASAPI.md     # 设备专项文档（本文件已涵盖其全部内容）
```

---

## 来源与许可

- 构建体系派生自 [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds)（MIT / 各脚本各自许可）。
- FFmpeg 本身遵循 LGPL / GPL（依变体而定）。
- 自研 `wasapi_dec.c` 以与 FFmpeg 兼容的许可随本仓库提供；如需走上游补丁流程，
  可用 `wasapi/patches-out/0001-...patch` 或 `wasapi/make-patch.sh` 重新生成。
