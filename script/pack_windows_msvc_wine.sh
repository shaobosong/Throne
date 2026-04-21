#!/usr/bin/env bash
#
# Package Windows build artifacts produced by build_windows_msvc_wine.sh
# into a portable zip and (optionally) a NSIS installer.
#
# Environment variables (optional):
#   BUILD_DIR       Directory containing Throne.exe (default: <repo>/build-windows)
#   QT_VERSION      Qt version used by the build (default: 6.11.0)
#   QT_ARCH         Qt arch id (default: msvc2022_64)
#   DEPS_DIR        Dependency cache dir (default: $BUILD_DIR/_deps_cache)
#   DEPLOY_DIR      Output root directory (default: <repo>/deployment)
#   DEST_SUFFIX     Sub-folder name (default: windows-amd64)
#   INPUT_VERSION   Version string used in archive filenames (default: dev)
#   SKIP_INSTALLER  If "1", skip NSIS installer step
#   SKIP_GO         If "1", skip the Go build step (ThroneCore/updater/libcronet)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

: "${BUILD_DIR:=$PROJECT_DIR/build-windows}"
: "${QT_VERSION:=6.11.0}"
: "${QT_ARCH:=x64}"
: "${DEPS_DIR:=$BUILD_DIR/_deps_cache}"
: "${DEPLOY_DIR:=$PROJECT_DIR/deployment}"
: "${DEST_SUFFIX:=windows-amd64}"
: "${INPUT_VERSION:=dev}"
: "${SKIP_INSTALLER:=0}"
: "${SKIP_GO:=0}"
: "${MSVC_WINE_ROOT:=/root/freedom/msvc-wine}"

log() { printf '\033[1;34m[pack-windows]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[pack-windows]\033[0m %s\n' "$*" >&2; exit 1; }

DEST="$DEPLOY_DIR/$DEST_SUFFIX"
QT_BIN="$DEPS_DIR/Qt_${QT_VERSION}_${QT_ARCH}/Qt/bin"
QT_ROOT="$DEPS_DIR/Qt_${QT_VERSION}_${QT_ARCH}/Qt"
OPENSSL_ROOT="$DEPS_DIR/openssl_${QT_ARCH}/openssl"

[ -f "$BUILD_DIR/Throne.exe" ] || die "$BUILD_DIR/Throne.exe not found. Run script/build_windows_msvc_wine.sh first."

command -v wine >/dev/null 2>&1 || die "wine not installed"
command -v zip  >/dev/null 2>&1 || die "zip not installed"

rm -rf "$DEST"
mkdir -p "$DEST"

# ---------------------------------------------------------------------------
# Stage the binary
# ---------------------------------------------------------------------------
cp "$BUILD_DIR/Throne.exe" "$DEST/"
[ -f "$BUILD_DIR/Throne.pdb" ] && cp "$BUILD_DIR/Throne.pdb" "$DEST/" || true

# ---------------------------------------------------------------------------
# Build the Go-side artifacts (ThroneCore.exe, updater.exe, libcronet.dll).
# Mirrors what the `build-go` job in .github/workflows/build.yml produces.
# Set SKIP_GO=1 to skip and rely on placeholder stubs instead.
# ---------------------------------------------------------------------------
if [ "$SKIP_GO" != "1" ]; then
    log "Building Go artifacts (ThroneCore.exe / updater.exe / libcronet.dll)"
    DEST="$DEST" DEPS_DIR="$DEPS_DIR" \
        "$SCRIPT_DIR/build_go_windows_msvc_wine.sh"
else
    log "SKIP_GO=1 set - skipping Go build; ThroneCore/updater/libcronet will be absent"
fi

# ---------------------------------------------------------------------------
# Detect whether the executable needs Qt DLLs (dynamic Qt build) or if Qt
# is statically linked (like the throneproj/buildqt prebuilts). We only
# invoke windeployqt when dynamic Qt DLLs are imported.
# ---------------------------------------------------------------------------
NEEDS_WINDEPLOYQT=0
if command -v wine >/dev/null 2>&1 && [ -f "$MSVC_WINE_ROOT/msvc/bin/x64/dumpbin.exe" ] || [ -f /data/msvc-wine/msvc/bin/x64/dumpbin.exe ]; then
    DUMPBIN="${DUMPBIN:-/data/msvc-wine/msvc/bin/x64/dumpbin.exe}"
    if wine "$DUMPBIN" /imports "$BUILD_DIR/Throne.exe" 2>/dev/null | grep -qiE '^\s+Qt6[A-Za-z]+\.dll'; then
        NEEDS_WINDEPLOYQT=1
    fi
fi

if [ "$NEEDS_WINDEPLOYQT" = "1" ] && [ -x "$QT_BIN/windeployqt.exe" ]; then
    log "Running windeployqt under wine (dynamic Qt detected)"
    export WINEPREFIX="${WINEPREFIX:-/data/msvc-wine/wineprefix}"
    export WINEDEBUG="${WINEDEBUG:--all}"
    QT_BIN_WIN=$(winepath -w "$QT_BIN")
    DEST_WIN=$(winepath -w "$DEST")
    (
        export WINEPATH="$QT_BIN_WIN"
        wine "$QT_BIN/windeployqt.exe" \
            --release \
            --no-compiler-runtime \
            --no-system-d3d-compiler \
            --no-opengl-sw \
            "$DEST_WIN\\Throne.exe"
    )
else
    log "Qt is statically linked - skipping windeployqt"
fi

# ---------------------------------------------------------------------------
# Bundle OpenSSL runtime DLLs if we can find any. Qt Network with a static
# Qt build still loads OpenSSL dynamically at runtime.
# ---------------------------------------------------------------------------
copied=0
for dll in \
    "$OPENSSL_ROOT"/bin/libcrypto*.dll \
    "$OPENSSL_ROOT"/bin/libssl*.dll \
    "$OPENSSL_ROOT"/*.dll; do
    if [ -f "$dll" ]; then
        cp "$dll" "$DEST/"
        copied=$((copied + 1))
    fi
done
if [ "$copied" = "0" ]; then
    log "Note: no OpenSSL DLLs found to bundle ($OPENSSL_ROOT only contains .lib files)."
    log "      If TLS is required at runtime, drop libcrypto-1_1-x64.dll / libssl-1_1-x64.dll"
    log "      next to Throne.exe before shipping."
fi

# ---------------------------------------------------------------------------
# Bundle MSVC runtime DLLs from the toolchain redistributable (if present)
# ---------------------------------------------------------------------------
REDIST_DIR=$(find /data/msvc-wine/msvc/vc/redist -maxdepth 4 -type d -name x64 2>/dev/null | head -1 || true)
if [ -n "$REDIST_DIR" ]; then
    for sub in "$REDIST_DIR"/Microsoft.VC*.CRT "$REDIST_DIR"/Microsoft.VC*.OpenMP; do
        if ls "$sub"/*.dll >/dev/null 2>&1; then
            cp "$sub"/*.dll "$DEST/" 2>/dev/null || true
        fi
    done
fi

log "Portable layout ready at: $DEST"
ls -la "$DEST"

# ---------------------------------------------------------------------------
# Portable zip
# ---------------------------------------------------------------------------
(
    cd "$DEPLOY_DIR"
    ZIP_NAME="Throne-${INPUT_VERSION}-windows64.zip"
    rm -f "$ZIP_NAME"
    rm -rf Throne
    cp -r "$DEST_SUFFIX" Throne
    zip -9 -qr "$ZIP_NAME" Throne
    rm -rf Throne
    log "Created $DEPLOY_DIR/$ZIP_NAME"
)

# ---------------------------------------------------------------------------
# NSIS installer
# ---------------------------------------------------------------------------
if [ "$SKIP_INSTALLER" != "1" ]; then
    command -v makensis >/dev/null 2>&1 || die "makensis not installed (apt install nsis)"
    NSI_WORK="$BUILD_DIR/_nsis"
    rm -rf "$NSI_WORK"
    mkdir -p "$NSI_WORK"
    cp "$PROJECT_DIR/script/windows_installer.nsi" "$NSI_WORK/"
    cp -r "$PROJECT_DIR/res"    "$NSI_WORK/"
    cp -r "$PROJECT_DIR/script" "$NSI_WORK/"
    # NSIS script expects ./deployment/windows-amd64 relative to the .nsi
    mkdir -p "$NSI_WORK/deployment"
    cp -r "$DEST" "$NSI_WORK/deployment/"

    # The upstream NSIS script hard-references ThroneCore.exe / updater.exe
    # (produced by a separate Go build). When missing (which is the case for
    # a pure C++ build on Linux), create stubs so makensis does not error,
    # unless SKIP_CORE_STUBS=1 is explicitly set.
    if [ "${SKIP_CORE_STUBS:-0}" != "1" ]; then
        for stub in ThroneCore.exe updater.exe; do
            if [ ! -f "$NSI_WORK/deployment/$DEST_SUFFIX/$stub" ]; then
                log "Creating placeholder $stub (Go build artifacts not present)"
                : > "$NSI_WORK/deployment/$DEST_SUFFIX/$stub"
            fi
        done
    fi

    (
        cd "$NSI_WORK"
        log "Running makensis"
        makensis -V2 windows_installer.nsi
    )

    INSTALLER_OUT="$DEPLOY_DIR/Throne-${INPUT_VERSION}-windows64-installer.exe"
    cp "$NSI_WORK/ThroneSetup.exe" "$INSTALLER_OUT"
    log "Created $INSTALLER_OUT"
fi

log "All done."
