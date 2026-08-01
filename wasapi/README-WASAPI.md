# FFmpeg WASAPI 输入设备

给 FFmpeg 增加一个 `-f wasapi` 输入设备，用于在 Windows 上：

- **录制系统输出声音（loopback）** —— 不用装 VB-CABLE / virtual-audio-capturer 等虚拟声卡
- **录制麦克风 / 线路输入**
- **只录某个进程发出的声音**（Windows 10 build 20348+ / Windows 11）
- 支持共享 / 独占模式
- 空闲时自动填充静音，保证录音时间轴与真实时间对齐

> 背景：上游 FFmpeg **从来没有** WASAPI 设备，`libavdevice` 里 Windows 音频只有 DirectShow（dshow）。
> 网上那些 `--enable-wasapi` / `ffmpeg -f wasapi -i default` 的教程是错误内容——官方 configure
> 没有这个开关，patchwork 上连一个 wasapi 补丁都没有。这个设备是本仓库自带的实现。

---

## 文件说明

| 文件 | 作用 |
|---|---|
| `wasapi_dec.c` | 设备本体（C 源码，放进 `libavdevice/`） |
| `apply-wasapi.sh` | 把设备接进任意 FFmpeg 源码树（改 configure / Makefile / alldevices.c / 文档） |
| `patches-out/0001-avdevice-wasapi-add-input-device.patch` | 标准 `git format-patch` 补丁，可直接 `git apply` |
| `build-exe.sh` | 在 mingw 容器里编译自包含 `ffmpeg.exe` |
| `verify-build.sh` / `make-patch.sh` | 开发用：验证编译 / 生成补丁 |
| `out/ffmpeg.exe`, `out/ffprobe.exe` | 编译产物 |

---

## 用法

### 1. 列出所有音频设备

```cmd
ffmpeg -f wasapi -list_devices true -i dummy
```

会分别列出「render（播放）设备」和「capture（录音）设备」，并标出默认设备和它们的 endpoint id。

### 2. 录制电脑正在播放的所有声音（最常用）

```cmd
ffmpeg -f wasapi -i default -c:a flac system_audio.flac
```

`default` = 默认播放设备的 loopback。想存别的格式：

```cmd
ffmpeg -f wasapi -i default -c:a aac -b:a 192k out.m4a
ffmpeg -f wasapi -i default -c:a pcm_s16le out.wav
```

### 3. 录麦克风

```cmd
ffmpeg -f wasapi -i default_input -c:a aac mic.m4a
```

### 4. 指定某个设备（名字或 endpoint id 都行）

```cmd
ffmpeg -f wasapi -i "扬声器 (Realtek(R) Audio)" -c:a flac out.flac
```

名字先做精确匹配，再做不区分大小写的子串匹配，所以写一段能区分的名字即可。

### 5. 只录某个程序的声音（Win10 20348+ / Win11）

先用任务管理器查到目标进程 PID，然后：

```cmd
ffmpeg -f wasapi -i pid=12345 -c:a aac app.m4a
```

或反过来——**排除**某个进程（录除它以外的所有声音）：

```cmd
ffmpeg -f wasapi -pid 12345 -exclude_pid true -i dummy -c:a aac others.m4a
```

### 6. 录屏 + 系统声音（一条命令出 mp4）

```cmd
ffmpeg -f gdigrab -framerate 30 -i desktop ^
       -f wasapi   -i default ^
       -c:v libx264 -preset veryfast -c:a aac screencast.mp4
```

> 注意：`out/` 里这个自包含 exe **不含 libx264**（无外部库）。要 h264 录屏请用下面的
> 「完整版构建」，或把视频编码换成内置的 `-c:v mpeg4` / `-c:v ffv1`。

---

## 全部选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `-list_devices` | false | 列出设备后退出 |
| `-loopback` | auto | 强制开/关 loopback（默认：播放设备开、录音设备关） |
| `-exclusive` | false | 独占模式（不能和 loopback 同时用） |
| `-audio_buffer_size` | 500 | 缓冲区毫秒数 |
| `-pid` | 0 | 只录该进程（0=整设备） |
| `-exclude_pid` | false | 反选：录除该进程外的所有声音 |
| `-fill_silence` | true | 空闲时填静音，保证实时时间轴 |
| `-silence_threshold` | 100 | 空闲多少毫秒后开始填静音 |
| `-sample_rate` | auto | 强制采样率 |
| `-channels` | auto | 强制声道数 |
| `-format` | float | `float`(32bit) 或 `s16`(16bit) |

---

## 重新编译

### A. 自包含版（音频 + 基础录屏，无外部库，开箱即用）

```bash
docker run --rm -v "<本目录>:/w" -v ffwasapi:/build ffwasapi-tc:latest bash /w/build-exe.sh
# 产物在 out/ffmpeg.exe
```

### B. 完整版（x264/x265/nvenc/… 全套编解码，drop-in 替换官方 BtbN 版本）

本设备已接进 BtbN 的 `build.sh`：`build.sh` 在 clone FFmpeg 后会自动
把 `wasapi/` 目录挂进容器并应用 `apply-wasapi.sh` 和 `wasapi/*.patch`。
拉到 BtbN 基础镜像后，在仓库根目录执行：

```bash
./build.sh win64-gpl        # 产物 zip 在 artifacts/
```

出来的就是和官方 BtbN Windows 版功能完全一致、但多了 `-f wasapi` 的 ffmpeg.exe。

---

## 已知限制

- 独占模式（`-exclusive`）下无法 loopback，这是 WASAPI 本身的限制。
- 按进程录音（`pid=`）需要 Windows 10 build 20348 或更新；老系统会明确报错。
- loopback 抓的是设备的最终混音流，采样率/声道随系统混音格式（一般 48kHz 立体声）。
