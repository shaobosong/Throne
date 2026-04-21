# 在 Linux 上交叉构建 Throne for Windows x64

本文档记录如何在 Linux 主机上，使用 [msvc-wine](https://github.com/mstorsjo/msvc-wine) 工具链
交叉编译出与官方 GitHub Actions 一致的 Windows x64 发布产物：

- `Throne.exe` —— C++/Qt GUI 主程序（静态 Qt）
- `Throne.pdb` —— 调试符号
- `ThroneCore.exe` —— Go 核心（sing-box + xray-core + tailscale 等）
- `updater.exe` —— 自动更新器（下载自 `throneproj/updater`）
- `libcronet.dll` —— Chromium 网络栈（下载自 `SagerNet/cronet-go`）
- `Throne-<version>-windows64.zip` —— 便携包
- `Throne-<version>-windows64-installer.exe` —— NSIS 安装包

整个流程**不需要一台 Windows 机器**，也**不需要 GitHub Actions**，在一台 Linux
机器上端到端即可完成。

---

## 1. 目录 & 名词

| 名称 | 路径 | 说明 |
|------|------|------|
| `PROJECT_DIR` | `/root/freedom/Throne` | Throne 源码仓库 |
| `MSVC_WINE_ROOT` | `/root/freedom/msvc-wine` | msvc-wine 源码树（`use-msvc-x64.sh`、`setup-local-msvc.sh` 等） |
| `MSVC_WINE_BIN` | `/data/msvc-wine/msvc/bin/x64` | msvc-wine 生成的 wrapper（`cl`、`link`、`lib`、`rc`、`mt`、`dumpbin` 等） |
| `WINEPREFIX` | `/data/msvc-wine/wineprefix` | 为 MSVC 专门准备的 wine 前缀 |
| `BUILD_DIR` | `$PROJECT_DIR/build-windows` | CMake 构建目录 |
| `DEPS_DIR` | `$BUILD_DIR/_deps_cache` | 构建依赖缓存（Qt、OpenSSL、Go SDK、protoc…） |
| `DEPLOY_DIR` | `$PROJECT_DIR/deployment` | 最终产物输出目录 |
| `DEST` | `$DEPLOY_DIR/windows-amd64` | 便携目录，打 zip / installer 前所有文件就位于此 |

以下命令行示例均以上述路径为准，若你的部署路径不同，可在调用脚本时用对应环境变量覆盖。

---

## 2. 依赖安装

### 2.1 系统包

Debian / Ubuntu：

```bash
sudo apt update
sudo apt install -y \
    wine wine64 \
    cmake ninja-build \
    curl unzip p7zip-full \
    python3 \
    nsis \
    zip \
    qt6-base-dev-tools qt6-l10n-tools   # 作为 host shim 使用
```

> `qt6-base-dev-tools` 提供 `/usr/lib/qt6/libexec/{moc,uic,rcc,qhelpgenerator}`，
> `qt6-l10n-tools` 提供 `/usr/lib/qt6/bin/{lrelease,lupdate,lconvert,qdbuscpp2xml,qdbusxml2cpp}`。
> 这些是 host 侧的 Qt 工具，用来替换 `throneproj/buildqt` 预编译包里
> 因缺少 `icuuc.dll` 而无法在 wine 下运行的同名 Windows 工具。详见 §6。

### 2.2 binfmt_misc（让 Linux 内核透明把 PE 交给 wine）

CMake 会在 configure 阶段直接 `exec` Qt 的 host 工具（`moc.exe` / `uic.exe` 等），
这些是 Windows PE。必须让内核通过 binfmt_misc 自动路由到 wine：

```bash
# 需要 root
echo ':wine:M::MZ::/usr/bin/wine:' > /proc/sys/fs/binfmt_misc/register
```

检查：

```bash
ls /proc/sys/fs/binfmt_misc/wine   # 应存在
```

`script/build_windows_msvc_wine.sh` 会在启动时检测并尝试自动注册，但前提是脚本
以 root 运行；否则只会打印警告。

### 2.3 msvc-wine 工具链（一次性）

```bash
git clone https://github.com/mstorsjo/msvc-wine /root/freedom/msvc-wine
# 该脚本会把 MSVC 安装到 /data/msvc-wine/
/root/freedom/msvc-wine/setup-local-msvc.sh
```

完成后应存在：

```
/data/msvc-wine/msvc/bin/x64/cl
/data/msvc-wine/msvc/bin/x64/link
/data/msvc-wine/msvc/bin/x64/rc
/data/msvc-wine/wineprefix/
```

---

## 3. 三个脚本的关系

```
┌─────────────────────────────────────────────────────────────────┐
│ script/build_windows_msvc_wine.sh                               │
│   ├─ 下载 Qt 6.11.0 x64 (throneproj/buildqt)                    │
│   ├─ 下载 OpenSSL x64 (throneproj/env_windows_legacy)           │
│   ├─ 给 ICU 依赖的 Qt 工具打 host shim                          │
│   ├─ 检查/注册 binfmt_misc                                      │
│   ├─ source use-msvc-x64.sh                                     │
│   └─ cmake -G Ninja + ninja  -> build-windows/Throne.exe        │
└─────────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────┐
│ script/pack_windows_msvc_wine.sh                                │
│   ├─ 清空 / 创建 deployment/windows-amd64/                      │
│   ├─ 拷贝 Throne.exe / Throne.pdb                               │
│   ├─ 调用 build_go_windows_msvc_wine.sh                         │──┐
│   ├─ 探测是否动态 Qt -> 跑 windeployqt (静态时跳过)             │  │
│   ├─ 拷贝 OpenSSL / MSVC 运行时 DLL (若存在)                    │  │
│   ├─ 生成 Throne-<ver>-windows64.zip                            │  │
│   └─ 调用 makensis -> Throne-<ver>-windows64-installer.exe      │  │
└─────────────────────────────────────────────────────────────────┘  │
                                                                     │
┌────────────────────────────────────────────────────────────────────▼
│ script/build_go_windows_msvc_wine.sh
│   ├─ 下载 Go SDK 1.25.9 到 DEPS_DIR
│   ├─ 下载 protoc 25.1 到 DEPS_DIR
│   ├─ go install protoc-gen-go / protoc-gen-go-grpc 到 DEPS_DIR/gopath
│   ├─ protoc 生成 libcore.proto 绑定
│   ├─ GOOS=windows GOARCH=amd64 go build -> $DEST/ThroneCore.exe
│   ├─ curl 下载 libcronet.dll
│   └─ curl 下载 updater.exe
└──────────────────────────────────────────────────────────────────
```

---

## 4. 一键构建（最小命令序列）

```bash
cd /root/freedom/Throne

# 1) 编译 Throne.exe（第一次会下载 Qt/OpenSSL，约 400 MB）
./script/build_windows_msvc_wine.sh

# 2) 打包（内部自动调用 Go 构建；第一次会下载 Go SDK + 一堆 Go module）
INPUT_VERSION=1.2.3 ./script/pack_windows_msvc_wine.sh
```

完成后产物：

```
deployment/
├─ windows-amd64/                     # 便携目录展开态
│   ├─ Throne.exe       (~53 MB)
│   ├─ Throne.pdb       (~109 MB)
│   ├─ ThroneCore.exe   (~63 MB)
│   ├─ updater.exe      (~617 KB)
│   └─ libcronet.dll    (~9.4 MB)
├─ Throne-1.2.3-windows64.zip          (~72 MB)
└─ Throne-1.2.3-windows64-installer.exe (~41 MB)
```

---

## 5. 各脚本的环境变量

### 5.1 `script/build_windows_msvc_wine.sh`

| 变量 | 默认值 | 含义 |
|------|--------|------|
| `MSVC_WINE_ROOT` | `/root/freedom/msvc-wine` | msvc-wine 源码树 |
| `MSVC_WINE_BIN` | `/data/msvc-wine/msvc/bin/x64` | wrapper 目录 |
| `QT_VERSION` | `6.11.0` | Qt 版本（需 throneproj/buildqt 有对应 release） |
| `QT_ARCH` | `x64` | `throneproj/buildqt` 里的 arch 名 |
| `BUILD_DIR` | `$PROJECT_DIR/build-windows` | CMake 构建目录 |
| `DEPS_DIR` | `$BUILD_DIR/_deps_cache` | 依赖缓存 |
| `INPUT_VERSION` | `dev` | 注入 `NKR_VERSION` 宏 |
| `BUILD_TYPE` | `RelWithDebInfo` | CMake 构建类型 |

### 5.2 `script/build_go_windows_msvc_wine.sh`

| 变量 | 默认值 | 含义 |
|------|--------|------|
| `DEPS_DIR` | `$PROJECT_DIR/build-windows/_deps_cache` | 与 build 脚本共用缓存 |
| `DEST` | `$PROJECT_DIR/deployment/windows-amd64` | 输出目录 |
| `GO_VERSION` | `1.25.9` | Go SDK 版本（需 ≥ `core/server/go.mod` 要求的 1.25） |
| `PROTOC_VERSION` | `25.1` | protobuf 版本 |
| `GOARCH` | `amd64` | 目标架构 |
| `SKIP_UPDATER` | `0` | 设 `1` 不下载 `updater.exe` |
| `SKIP_CRONET` | `0` | 设 `1` 不下载 `libcronet.dll` |

### 5.3 `script/pack_windows_msvc_wine.sh`

| 变量 | 默认值 | 含义 |
|------|--------|------|
| `BUILD_DIR` | `$PROJECT_DIR/build-windows` | 必须已有 `Throne.exe` |
| `QT_VERSION` / `QT_ARCH` | `6.11.0` / `x64` | 用于 windeployqt 定位 |
| `DEPS_DIR` | `$BUILD_DIR/_deps_cache` | 依赖缓存 |
| `DEPLOY_DIR` | `$PROJECT_DIR/deployment` | 输出根目录 |
| `DEST_SUFFIX` | `windows-amd64` | `$DEPLOY_DIR/<DEST_SUFFIX>` 是便携目录 |
| `INPUT_VERSION` | `dev` | zip / installer 文件名里的版本号 |
| `SKIP_INSTALLER` | `0` | 设 `1` 只打 zip，不跑 NSIS |
| `SKIP_GO` | `0` | 设 `1` 跳过 Go 构建，退回占位逻辑 |
| `SKIP_CORE_STUBS` | `0` | 设 `1` 时 Go 产物缺失也不创建占位（NSIS 会失败） |
| `MSVC_WINE_ROOT` | `/root/freedom/msvc-wine` | 用于寻找 dumpbin |

---

## 6. 关键设计决策与踩坑记录

### 6.1 为什么用 throneproj/buildqt 的预编译 Qt？

- 官方 CI 用的就是它，确保产物二进制一致性。
- 它是**静态构建**的 Qt，`Throne.exe` 不依赖任何 `Qt6*.dll`，发行体积小。
- 但它**缺 `icuuc.dll`**，导致 `uic.exe / rcc.exe / lrelease.exe / lupdate.exe /
  lconvert.exe / qhelpgenerator.exe / qdbus*.exe` 在 wine 下都以 exit 53
  (DLL not found) 失败。`moc.exe` / `qmake.exe` 不依赖 icuuc，可以正常用。

### 6.2 host Qt shim

解决上面 ICU 问题的方案：脚本在解包后，把坏掉的 `.exe` 直接覆盖为一段 shell 脚本：

```bash
#!/usr/bin/env bash
exec /usr/lib/qt6/libexec/uic "$@"
```

之所以可行，是因为这些工具的输入/输出是文本或二进制格式，**与宿主机器字节序无关**，
用 host 的 Qt 6.8.2 版产物做 host shim，交叉 Qt 6.11.0 的 build
可以正常吃它们的输出。`.qm` 文件 linguist 工具向后兼容。

涉及目录：

- 从 `/usr/lib/qt6/libexec/` 取：`uic / rcc / moc / qhelpgenerator`
- 从 `/usr/lib/qt6/bin/` 取：`lrelease / lupdate / lconvert / qdbuscpp2xml / qdbusxml2cpp`

### 6.3 binfmt_misc 必须注册

CMake 执行这些 shim 时也要能透明路由到 host Qt 二进制（shim 是 `#!/usr/bin/env bash`
脚本，会被 shebang 处理，OK）。但遇到真正的 PE —— 例如 `spb-protoc.exe`（`myproto.cmake`
里 cross 编译出来的 host 工具）、`windeployqt.exe`、原版 `moc.exe` —— 就必须靠 binfmt_misc。

如果 `wine` 不是 `/usr/bin/wine`，把上面的路径替换一下即可。

### 6.4 7z 解包不保留执行位

Qt / OpenSSL 的 7z 解包后所有 `.exe` / `.dll` 都是 644。脚本会：

```bash
find "$QT_ROOT" \( -name '*.exe' -o -name '*.dll' \) -exec chmod +x {} +
```

### 6.5 静态 Qt → 不跑 windeployqt

pack 脚本用 `dumpbin /imports Throne.exe` 探测，只在看到 `Qt6*.dll` 的 import
时才调用 `windeployqt.exe`；否则直接跳过（静态 Qt 调 windeployqt 会报
"does not seem to be a Qt executable"）。

### 6.6 Go 版本要求

`core/server/go.mod` 声明 `go 1.25`，系统 Debian 的 `go1.24.4` 不够。
`build_go_windows_msvc_wine.sh` 会把 `go1.25.9` 下载到 `DEPS_DIR/go-1.25.9/`
并**仅在脚本内部生效**（通过 `export GOROOT / PATH`），不污染系统。

### 6.7 OpenSSL runtime DLL

`throneproj/env_windows_legacy` 发布的 OpenSSL 包**只有 `.lib`，没有运行时 DLL**。
官方 CI 也没有把 OpenSSL DLL 打进发行包 —— 所以我们保持一致。
如果目标 Windows 上要做 TLS，Qt Network 会在运行时寻找 `libcrypto-1_1-x64.dll`
/ `libssl-1_1-x64.dll`；自行下载并与 `Throne.exe` 同目录部署即可。
pack 脚本在检测到缺失时只打印提示信息。

### 6.8 NSIS 与缺失产物

`script/windows_installer.nsi` 硬引用了：

```
.\deployment\windows-amd64\Throne.exe
.\deployment\windows-amd64\ThroneCore.exe
.\deployment\windows-amd64\updater.exe
```

三个都必须存在文件，否则 `makensis` 会报错。默认 pack 脚本会自动跑 Go
构建补齐真实产物；若 `SKIP_GO=1`，脚本会创建 0 字节占位文件以让 NSIS 成功
运行（除非 `SKIP_CORE_STUBS=1`）。注意：0 字节 `ThroneCore.exe` 在真实
Windows 上无法启动，此时 installer 只作冒烟用途。

### 6.9 wine 噪音警告

`wine32 is missing / multiarch ...` 等启动警告在仅 x64 的场景下无害，
脚本默认 `WINEDEBUG=-all` 静音。

### 6.10 在当前 Linux 宿主直接 wine Throne.exe 会失败

宿主 wine 同样缺 ICU / 其它系统 DLL。这**不代表** Windows 目标机无法运行 ——
真实 Windows 自带 ICU。只是：**不要**用本机 wine 作为功能验证手段，
最终验证需要在真实 Windows 上完成。

---

## 7. 常见故障排查

| 症状 | 原因 / 解决 |
|------|-------------|
| `Missing required command: wine/cmake/ninja/7z` | §2.1 apt 安装 |
| `msvc-wine wrappers not found at /data/msvc-wine/msvc/bin/x64` | 跑 §2.3 的 `setup-local-msvc.sh` |
| configure 阶段 `moc: command not found` 或 `exit status 53` | binfmt_misc 未注册（§2.2），或 ICU 依赖工具未被 shim 覆盖 |
| `makensis` 报文件不存在 | `deployment/windows-amd64/` 下缺 Go 产物。默认 pack 会自动跑 Go 构建；若 `SKIP_GO=1` 且 `SKIP_CORE_STUBS=1`，就会命中此问题 |
| Go 构建卡住 | 第一次下载 Go module 数量很大（sing-box/xray/tailscale …），允许 5–10 分钟 |
| `Qt6 / OpenSSL` 下载 403 | 检查网络能否访问 github release CDN |
| `Throne-dev-windows64.zip` 体积 < 20 MB | 多半是 Go 产物没打进来，检查 `SKIP_GO` 与 `deployment/windows-amd64/` 内容 |
| `wine: wine32 is missing ...` 警告 | 无害，可忽略；脚本默认已 `WINEDEBUG=-all` 静音 |
| 重复构建想彻底清理 | `rm -rf build-windows deployment` |
| 只想重建 C++ 不重下 Qt | 直接再跑 `./script/build_windows_msvc_wine.sh`，`_deps_cache` 会命中 |

---

## 8. 与官方 CI 的对比

`.github/workflows/build.yml` 把构建拆成 `build-go`（macOS runner，交叉编译 Go）
与 `build-cpp`（Windows runner，MSVC）两个 job，最后在 publish job 里合并打包。
本地构建等价关系：

| CI 步骤 | 本地等价 |
|---------|----------|
| `build-go` + `script/build_go.sh` | `script/build_go_windows_msvc_wine.sh`（改为在 Linux 上以 `GOOS=windows` 交叉编译，不用 macOS） |
| `build-cpp` + MSVC + `script/deploy_windows.sh` | `script/build_windows_msvc_wine.sh`（改用 msvc-wine） |
| `build-cpp` + `makensis windows_installer.nsi` | `script/pack_windows_msvc_wine.sh` 中的 NSIS 环节 |
| `publish` 中 `zip -9 -r Throne-<tag>-windows64.zip Throne` | `script/pack_windows_msvc_wine.sh` 中的 zip 环节 |

产物内容与官方完全一致（Throne.exe + Throne.pdb + ThroneCore.exe + updater.exe + libcronet.dll）。
注意官方发布包不包含 OpenSSL runtime DLL，本地脚本也保持一致（§6.7）。

---

## 9. 产出文件清单（事实基线）

以 `INPUT_VERSION=dev` 构建一次为例：

```
deployment/windows-amd64/Throne.exe       PE32+ GUI, x86-64, 12 sections
deployment/windows-amd64/Throne.pdb       MSVC debug symbols
deployment/windows-amd64/ThroneCore.exe   PE32+ console, x86-64, 8 sections
deployment/windows-amd64/updater.exe      PE32+ console, x86-64, 6 sections
deployment/windows-amd64/libcronet.dll    PE32+ DLL,     x86-64, 10 sections
deployment/Throne-dev-windows64.zip       zip, 5 entries under Throne/
deployment/Throne-dev-windows64-installer.exe  NSIS self-extracting PE32
```

---

## 10. 常用命令速查

```bash
# 只编译 Throne.exe（保持所有缓存）
./script/build_windows_msvc_wine.sh

# 只编译 Go 部分
./script/build_go_windows_msvc_wine.sh

# 只打包（需已有 Throne.exe）
./script/pack_windows_msvc_wine.sh

# 打 zip 但不要 installer
SKIP_INSTALLER=1 ./script/pack_windows_msvc_wine.sh

# 打 installer 但跳过 Go（用占位，仅冒烟用）
SKIP_GO=1 ./script/pack_windows_msvc_wine.sh

# 指定版本号（影响 zip/installer 文件名与 Throne.exe 内 NKR_VERSION 宏）
INPUT_VERSION=1.2.3 ./script/build_windows_msvc_wine.sh
INPUT_VERSION=1.2.3 ./script/pack_windows_msvc_wine.sh

# 从零开始（删除所有缓存）
rm -rf build-windows deployment
./script/build_windows_msvc_wine.sh
./script/pack_windows_msvc_wine.sh
```
