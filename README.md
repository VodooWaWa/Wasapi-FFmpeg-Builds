# WASAPI FFmpeg Builds — Windows x64 + ARM64

在 [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds) 基础上 fork，给 FFmpeg 增加了一个
**自研 `-f wasapi` 输入设备**，用于 Windows 上直接采集音频（系统声音 loopback / 麦克风 / 指定进程声音），
无需任何虚拟声卡（VB-CABLE、virtual-audio-capturer 等）。其余构建体系与上游完全一致。

**本仓库通过 GitHub Actions 自动构建**：每次 BtbN 上游更新，自动拉取最新源码、打上 WASAPI 补丁，
分别编译出 **x64（`win64`）** 与 **ARM64（`winarm64`）** 两个 Windows 静态版，并自动发布到 GitHub Releases。

---

## 自动跟随上游（Method B）

> 一句话：**官方仓库一更新，这边最长 6 小时内自动重新构建并发布。**

机制由 `.github/workflows/track-upstream.yml` 实现（这也是本仓库**唯一**的定时器）：

1. 每 6 小时（`cron: 37 */6 * * *`）抓取 BtbN 仓库的 HEAD commit SHA。
2. 与本地记录的 `.github/upstream-sha.txt` 比对。
3. **上游有更新** → 更新记录文件、提交，并触发 `build.yml -f doRelease=true` 重新构建 + 发布。
4. **上游没动** → 不消耗任何构建时长，直接结束。

构建本身（`.github/workflows/build.yml`）**不会**定时全量重编，只在「上游真的变了」时被拉起。
（轮询上游 commit 触发，不用定时器全量重建。）

触发链路：

```
BtbN 推送新 commit
   └─(≤6h)─ track-upstream.yml 检测到 SHA 变化
                └─ 提交新 upstream-sha.txt
                     └─ gh workflow run build.yml -f doRelease=true
                          ├─ build (matrix: win64, winarm64)  ← 拉 BtbN 镜像 + 应用 WASAPI 补丁 + 编译
                          └─ release  ← 两个 zip 打包成一个 GitHub Release
```

---

## 获取二进制

两种途径，都是 CI 产物，**无需本地构建**：

- **GitHub Releases（推荐）**：每次成功构建自动创建一个 Release（tag 形如 `wasapi-<run_number>`），内含：
  - `ffmpeg-N-<commit>-win64-gpl.zip` —— x64
  - `ffmpeg-N-<commit>-winarm64-gpl.zip` —— ARM64
  直接下载解压即可用，含 `ffmpeg.exe` / `ffprobe.exe`。
- **Workflow Artifacts**：单次运行（Actions → 某次 run → Artifacts）里也能单独拿到某架构的 zip。

> 构建需全量编译 FFmpeg，x64 与 ARM64 各需数十分钟，请等 run 跑完再下载。
> 监控：仓库 **Actions** 页查看 `Build WASAPI FFmpeg (Windows)` 运行状态。

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
- 共享 / 独占模式；空闲默认**不填静音**（时间轴在无声段会有缺口，但可避免爆音）。需要连续时间轴时再开 `-fill_silence 1`

---

## WASAPI 设备快速上手

> 以下命令针对**已下载的二进制**（`ffmpeg.exe`），与构建方式无关。

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

**排除**某个进程（录除它以外的所有声音），只能用选项写法：

```cmd
ffmpeg -f wasapi -pid 12345 -exclude_pid true -i dummy -c:a aac others.m4a
```

### 6. 录屏 + 系统声音，一条命令出 mp4

```cmd
ffmpeg -f gdigrab -framerate 30 -i desktop ^
       -f wasapi   -i default ^
       -c:v libx264 -preset veryfast -c:a aac screencast.mp4
```

> 完整版（gpl 变体）含 libx264 等外部库，可出 h264。WASAPI 设备本身仅与 Windows 平台相关。

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
| `-fill_silence` | bool | `0` | 空闲时填静音以保持时间轴连续；**默认关**，因开启后视频静音段会插入硬跳变（爆音）。无声段想要连续时间轴时再开 `1` |
| `-silence_threshold` | int(ms) | `100` | 空闲多少毫秒后开始填静音（10–10000） |
| `-sample_rate` | int | `0`（自动） | 强制采样率 |
| `-channels` | int | `0`（自动） | 强制声道数（0–64） |
| `-format` | `float`/`s16` | `float` | 请求的样本格式：`float`=32bit 浮点，`s16`=16bit 有符号 |

> 输入名语法：`default` / `default_input` / `"设备名"` / `pid=<数字>`（进程录音简写）。
> 进程录音运行时按系统能力探测，老系统会明确报错而非静默失败。

---

## 已知限制

- 独占模式（`-exclusive`）下**不能** loopback，这是 WASAPI 本身的限制。
- 进程录音（`pid=` / `-pid`）需要 Windows 10 build 20348 或更新；老系统会明确报错。
- loopback 抓的是设备的最终混音流，采样率/声道随系统混音格式（一般 48kHz 立体声）。
- **进程录音的采样率/声道现在会自动探测**：不再硬编码 48kHz/立体声，而是读取音频引擎的真实混音格式（探测失败才回退 48kHz/2ch），避免多余的二次重采样/下混。
- 首包可能打印 `Audio capture glitch detected`，通常是缓冲区预热，无害。

### 进程录音爆音 / 断流排查

实测结论（基于真实录制样本分析）：

- **`fill_silence` 默认已关闭**。开启后，视频里的静音段（对话间隙、场景切换）会被插入「硬静音包」，真实音频↔静音的硬跳变就是爆音/咔哒；纯音不爆、视频爆正是这个原因。需要连续时间轴时再 `-fill_silence 1`。
- 若某台机器用 `pid=` 录音出现**周期性断流 / 一顿一顿**（听感也像爆音）：那多是进程录音在该环境取不到数据（PID 指错、游戏走独占模式、或进程 loopback 不稳定），`fill_silence` 会把断流补成规律静音块。优先改用整设备 loopback：
  ```cmd
  ffmpeg -f wasapi -i "默认播放设备 [Loopback]" -c:a aac out.m4a
  ```
  整设备 loopback 抓的是引擎混合后输出，格式稳定、不爆。代价是会录到系统全部声音。
- 仍可用 `-pid <正确PID>` 精确录音；若爆音/断流，先确认 PID 指向真正在出声的进程（而非启动器/子进程）。

---

## GPU 硬件编码（NVENC）驱动兼容性

本仓库预编译的 ffmpeg 现在把 `nv-codec-headers` **钉在 `sdk/12.2`**（CUDA 12.2 头文件，commit `f8339c0`）。

> **实现位置（重要）**：钉版**不是在 `scripts.d/50-ffnvcodec.sh` 里做的**——那个文件在本 fork 的 `build.sh` 流程中**不会被调用**（它只服务于 BtbN 的基础镜像构建，而本 CI 直接 `pull` BtbN 现成基础镜像 `ghcr.io/btbn/ffmpeg-builds/win64-gpl:latest`）。BtbN 基础镜像自带的是 **NVENC API 13.1**（要求驱动 ≥ R610）。真正的钉版是在 `build.sh` 写入容器的构建脚本里，于 `./configure` **之前**把 sdk/12.2 `git clone` + `make install` 装进容器、覆盖基础镜像的 13.1 头文件，并写 `/nv-codec-headers.version` 标记。

- **兼容性面**：ffmpeg 的 NVENC 编码能力下限对应 **API 12.2**，即 **NVIDIA 驱动 ≥ R535（Windows 536.25+ / Linux 535.86.05+）即可用**，不需要升级到 13.x 要求的 R610。
- **为什么钉 12.2**：BtbN 基础镜像默认已追到 **API 13.1**，要求驱动 ≥ R610；任何驱动低于 610 的机器（老显卡 / 长期未更新的机器）`h264_nvenc` / `hevc_nvenc` 会直接不可用。钉到 12.2 把兼容面铺到绝大多数在役驱动，对 H.264 / HEVC 录制**无任何功能损失**——本仓库不使用 13.x 的新特性，因此不损失任何我们需要的能力。
- **影响范围**：只影响用 `-c:v h264_nvenc` / `hevc_nvenc`（及基于 NVENC 的编码器）录制 / 转码。CPU 编码（`libx264` 等）、`d3d11va` / `dxva2` 等解码不受影响。

> 若机器是老驱动（如 472 / 512 系列，仍 ≥ R535），钉 12.2 后 NVENC 依旧可用；只有比 R535 更老的驱动才会回退到 CPU 编码或报错。

- **如何一眼确认本包编译用的是哪个 SDK**：运行 `ffmpeg -version`，版本串里带 `-nvh<SDK>-<commit>` 后缀即编译时锁定的 nv-codec-headers 版本。例如 `-nvh12.2-f8339c0` 表示编译用的是 **sdk/12.2（commit f8339c0）**。
  - ⚠️ 注意：`ffmpeg -hide_banner -v verbose ... 2>&1 | findstr "Loaded Nvenc version"` 打印的 **`13.1` 之类是「驱动支持的 NVENC 版本上限」，由本机驱动决定，与编译用的 SDK 无关**——在这台机器上无论编译用 12.2 还是 13.x 都会显示同样的值，不能用它判断 pin 是否生效。真正能区分的是**老驱动（< R610）机器上的 NVENC 初始化成败**：12.2 编译的二进制在该机器上能开 NVENC，13.x 编译的会报 `Driver does not support the required nvenc API version 13.x`。

---

## 本地构建（高级 / 可选）

> 一般情况下**无需**本地构建——Releases 已提供现成二进制。
> 本节仅给想在本地复现 CI 构建、或改补丁的人参考。

**前置**：Git Bash + Docker Desktop（Linux 容器模式）。

CI 里通过 `REPO_OVERRIDE=btbn/ffmpeg-builds` 从 BtbN 名下拉取构建镜像（fork 自己没有这些镜像）。
本地复现可等价设置；其它可覆盖变量：

| 变量 | 说明 |
|---|---|
| `REPO_OVERRIDE` | 构建镜像所在仓库（CI 固定为 `btbn/ffmpeg-builds`） |
| `REGISTRY_OVERRIDE` | 改写镜像 registry（如国内镜像源） |
| `FFMPEG_REPO_OVERRIDE` | 改写 FFmpeg 源码地址（如镜像） |
| `FFMPEG_CLONE_ARGS` | 改写克隆参数（如 `--depth=1`） |

```bash
./build.sh win64 gpl        # x64
./build.sh winarm64 gpl     # ARM64
# 产物 zip 在 artifacts/
```

WASAPI 补丁由 `build.sh` 自动应用（`wasapi/apply-wasapi.sh` + `wasapi/*.patch`），无需手动操作。

---

## 目录结构

```
FFmpeg-Builds/
├── .github/workflows/
│   ├── build.yml            # CI 构建：matrix[win64, winarm64] + 自动 Release
│   └── track-upstream.yml   # 方式 B：每 6h 轮询 BtbN HEAD SHA，变则触发构建
├── build.sh                 # 入口（自动应用 WASAPI 补丁 + 拉 BtbN 镜像）
├── util/vars.sh             # 镜像/仓库地址拼装，支持 REGISTRY_OVERRIDE / REPO_OVERRIDE
├── variants/                # 上游变体定义（win64-gpl / winarm64-gpl 等）
└── wasapi/                  # 自研 WASAPI 设备
    ├── wasapi_dec.c         # 设备本体（C 源码，放进 libavdevice/）
    ├── apply-wasapi.sh      # 把设备接进任意 FFmpeg 源码树
    ├── patches-out/         # 标准 git 补丁（如需走上游流程）
    └── README-WASAPI.md     # 设备专项文档（本文件已涵盖其全部内容）
```

---

## 来源与许可

- 构建体系派生自 [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds)（各脚本各自许可）。
- FFmpeg 本身遵循 LGPL / GPL（依变体而定）。
- 自研 `wasapi_dec.c` 以与 FFmpeg 兼容的许可随本仓库提供；如需走上游补丁流程，
  可用 `wasapi/patches-out/` 下的补丁或 `wasapi/make-patch.sh` 重新生成。
