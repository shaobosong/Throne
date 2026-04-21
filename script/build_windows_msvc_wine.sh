#!/usr/bin/env bash
#
# Build Throne.exe (Windows x64) on Linux using the msvc-wine toolchain.
#
# Required host packages: wine, cmake, ninja-build, python3, curl, p7zip-full.
# Required one-off setup (installs MSVC to /data/msvc-wine):
#     /root/freedom/msvc-wine/setup-local-msvc.sh
#
# Environment variables (optional):
#   MSVC_WINE_ROOT  Path to msvc-wine source tree (default: /root/freedom/msvc-wine)
#   MSVC_WINE_BIN   Path to wrappers (default: /data/msvc-wine/msvc/bin/x64)
#   QT_VERSION      Qt version to download (default: 6.11.0)
#   QT_ARCH         Qt MSVC arch (default: msvc2022_64)
#   BUILD_DIR       Build directory (default: <repo>/build-windows)
#   DEPS_DIR        Dependency cache dir (default: <repo>/build-windows/_deps_cache)
#   INPUT_VERSION   Version string embedded into binaries (default: dev)
#   BUILD_TYPE      CMake build type (default: RelWithDebInfo)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

: "${MSVC_WINE_ROOT:=/root/freedom/msvc-wine}"
: "${MSVC_WINE_BIN:=/data/msvc-wine/msvc/bin/x64}"
: "${QT_VERSION:=6.11.0}"
: "${QT_ARCH:=x64}"
: "${BUILD_DIR:=$PROJECT_DIR/build-windows}"
: "${DEPS_DIR:=$BUILD_DIR/_deps_cache}"
: "${INPUT_VERSION:=dev}"
: "${BUILD_TYPE:=RelWithDebInfo}"

log() { printf '\033[1;32m[build-windows]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build-windows]\033[0m %s\n' "$*" >&2; exit 1; }

for cmd in wine cmake ninja curl 7z python3; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done

[ -x "$MSVC_WINE_BIN/cl" ] || die "msvc-wine wrappers not found at $MSVC_WINE_BIN. Run $MSVC_WINE_ROOT/setup-local-msvc.sh first."

# Qt's host tools (moc/uic/rcc/lrelease) are Windows PE binaries that CMake
# executes directly during configure/build. Register wine via binfmt_misc so
# the kernel transparently routes PE binaries to wine.
if [ ! -f /proc/sys/fs/binfmt_misc/wine ] && [ ! -f /proc/sys/fs/binfmt_misc/DOSWin ] && [ ! -f /proc/sys/fs/binfmt_misc/windows ]; then
    if [ "$(id -u)" = "0" ] && [ -w /proc/sys/fs/binfmt_misc/register ]; then
        log "Registering wine binfmt_misc handler"
        printf ':wine:M::MZ::/usr/bin/wine:\n' > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true
    else
        echo "Warning: wine binfmt_misc handler is not registered and we cannot register it (not root)." >&2
        echo "         Running Qt host tools may fail. Register as root with:" >&2
        echo "           echo ':wine:M::MZ::/usr/bin/wine:' > /proc/sys/fs/binfmt_misc/register" >&2
    fi
fi

mkdir -p "$DEPS_DIR" "$BUILD_DIR"

# ---------------------------------------------------------------------------
# Fetch Qt (prebuilt MSVC) from throneproj/buildqt
# ---------------------------------------------------------------------------
QT_URL="https://github.com/throneproj/buildqt/releases/download/Qt_${QT_VERSION}/Qt_${QT_VERSION}_${QT_ARCH}.7z"
QT_ARCHIVE="$DEPS_DIR/Qt_${QT_VERSION}_${QT_ARCH}.7z"
QT_ROOT="$DEPS_DIR/Qt_${QT_VERSION}_${QT_ARCH}"

if [ ! -d "$QT_ROOT/Qt/lib/cmake" ]; then
    if [ ! -f "$QT_ARCHIVE" ]; then
        log "Downloading Qt $QT_VERSION ($QT_ARCH)"
        curl -fL --retry 3 -o "$QT_ARCHIVE.part" "$QT_URL"
        mv "$QT_ARCHIVE.part" "$QT_ARCHIVE"
    fi
    log "Extracting Qt to $QT_ROOT"
    rm -rf "$QT_ROOT"
    mkdir -p "$QT_ROOT"
    7z x -y -o"$QT_ROOT" "$QT_ARCHIVE" >/dev/null
    # 7z extraction on Linux does not set +x on Windows PE files; CMake's
    # configure-time tests (uic -h, moc -h, ...) need them to be executable
    # so binfmt_misc can hand them off to wine.
    find "$QT_ROOT" \( -name '*.exe' -o -name '*.dll' \) -exec chmod +x {} +

    # Some tools in the prebuilt Qt (lrelease, lupdate) dynamically link
    # against icuuc.dll, which is not shipped in the throneproj/buildqt
    # bundle and not provided by Wine. Replace them with shell shims that
    # delegate to the host's Qt linguist tools (packages: qt6-l10n-tools,
    # linguist-qt6). The generated .qm files are forward compatible with
    # newer Qt runtimes.
    QT_BIN_ROOT=$(find "$QT_ROOT" -type d -name bin -path '*/Qt/bin' | head -1)
    for tool_basename in lrelease lupdate lconvert uic rcc qhelpgenerator qdbuscpp2xml qdbusxml2cpp; do
        host_tool=""
        for candidate in \
            "/usr/lib/qt6/bin/$tool_basename" \
            "/usr/lib/qt6/libexec/$tool_basename" \
            "/usr/lib/qt6/libexec/${tool_basename}-pro" \
            "$(command -v ${tool_basename}-qt6 2>/dev/null || true)" \
            "$(command -v $tool_basename 2>/dev/null || true)"; do
            if [ -n "$candidate" ] && [ -x "$candidate" ]; then
                host_tool="$candidate"
                break
            fi
        done
        if [ -n "$host_tool" ]; then
            for exe in "$QT_BIN_ROOT/$tool_basename.exe" "$QT_BIN_ROOT/$tool_basename-pro.exe"; do
                [ -f "$exe" ] || continue
                log "Shimming $(basename "$exe") -> $host_tool"
                cat > "$exe" <<EOF_SHIM
#!/usr/bin/env bash
exec "$host_tool" "\$@"
EOF_SHIM
                chmod +x "$exe"
            done
        else
            echo "Warning: could not find a host replacement for $tool_basename; build may fail if Qt's $tool_basename.exe misses icuuc.dll under wine." >&2
        fi
    done
fi
[ -d "$QT_ROOT/Qt/lib/cmake" ] || die "Unexpected Qt layout under $QT_ROOT"

# ---------------------------------------------------------------------------
# Fetch OpenSSL (prebuilt for MSVC x64) used by Qt Network
# ---------------------------------------------------------------------------
OPENSSL_URL="https://github.com/throneproj/env_windows_legacy/releases/download/latest/openssl_${QT_ARCH}.7z"
OPENSSL_ARCHIVE="$DEPS_DIR/openssl_${QT_ARCH}.7z"
OPENSSL_ROOT="$DEPS_DIR/openssl_${QT_ARCH}/openssl"

if [ ! -d "$OPENSSL_ROOT" ]; then
    if [ ! -f "$OPENSSL_ARCHIVE" ]; then
        log "Downloading OpenSSL ($QT_ARCH)"
        curl -fL --retry 3 -o "$OPENSSL_ARCHIVE.part" "$OPENSSL_URL"
        mv "$OPENSSL_ARCHIVE.part" "$OPENSSL_ARCHIVE"
    fi
    log "Extracting OpenSSL"
    rm -rf "$DEPS_DIR/openssl_${QT_ARCH}"
    mkdir -p "$DEPS_DIR/openssl_${QT_ARCH}"
    7z x -y -o"$DEPS_DIR/openssl_${QT_ARCH}" "$OPENSSL_ARCHIVE" >/dev/null
    find "$DEPS_DIR/openssl_${QT_ARCH}" \( -name '*.exe' -o -name '*.dll' \) -exec chmod +x {} +
fi
[ -d "$OPENSSL_ROOT" ] || die "Unexpected OpenSSL layout under $DEPS_DIR/openssl_${QT_ARCH}"

# ---------------------------------------------------------------------------
# Fetch extra srslist.h (matches CI behaviour)
# ---------------------------------------------------------------------------
SRSLIST="$BUILD_DIR/srslist.h"
if [ ! -f "$SRSLIST" ]; then
    log "Downloading srslist.h"
    curl -fLso "$SRSLIST" "https://raw.githubusercontent.com/throneproj/routeprofiles/rule-set/srslist.h"
fi

# ---------------------------------------------------------------------------
# Enable msvc-wine environment (sets INCLUDE, LIB, LIBPATH + PATH)
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$MSVC_WINE_ROOT/use-msvc-x64.sh"

export CMAKE_PREFIX_PATH="$QT_ROOT/Qt/lib/cmake:${CMAKE_PREFIX_PATH:-}"
export OPENSSL_ROOT_DIR="$OPENSSL_ROOT"
export INPUT_VERSION="$INPUT_VERSION"

log "Qt prefix:      $QT_ROOT/Qt"
log "OpenSSL prefix: $OPENSSL_ROOT"
log "Build dir:      $BUILD_DIR"
log "Build type:     $BUILD_TYPE"

# ---------------------------------------------------------------------------
# Configure & build
# ---------------------------------------------------------------------------
cmake -S "$PROJECT_DIR" -B "$BUILD_DIR" \
    -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$PROJECT_DIR/cmake/windows/toolchain-msvc-wine.cmake" \
    -DMSVC_WINE_BIN="$MSVC_WINE_BIN" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_PREFIX_PATH="$QT_ROOT/Qt/lib/cmake" \
    -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT"

cmake --build "$BUILD_DIR"

[ -f "$BUILD_DIR/Throne.exe" ] || die "Throne.exe was not produced"

log "Build OK: $BUILD_DIR/Throne.exe"
