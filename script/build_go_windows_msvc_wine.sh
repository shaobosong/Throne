#!/usr/bin/env bash
#
# Build the Go side of Throne for Windows amd64 on a Linux host.
#
# This produces, into $DEST (default: <repo>/deployment/windows-amd64):
#   - ThroneCore.exe   Go core built from core/server
#   - updater.exe      Prebuilt auto-updater from throneproj/updater
#   - libcronet.dll    Prebuilt Chromium network stack from SagerNet/cronet-go
#
# All toolchain dependencies (Go SDK, protoc, protoc-gen-go{,-grpc}) are
# installed into $DEPS_DIR so nothing leaks into the system.
#
# Environment variables (all optional):
#   DEPS_DIR        Cache dir (default: <repo>/build-windows/_deps_cache)
#   DEST            Output dir (default: <repo>/deployment/windows-amd64)
#   GO_VERSION      Go SDK version (default: 1.25.9)
#   PROTOC_VERSION  protoc version (default: 25.1)
#   GOARCH          Target arch (default: amd64)
#   SKIP_UPDATER    "1" to skip downloading updater.exe
#   SKIP_CRONET     "1" to skip downloading libcronet.dll

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

: "${DEPS_DIR:=$PROJECT_DIR/build-windows/_deps_cache}"
: "${DEST:=$PROJECT_DIR/deployment/windows-amd64}"
: "${GO_VERSION:=1.25.9}"
: "${PROTOC_VERSION:=25.1}"
: "${GOARCH:=amd64}"
: "${SKIP_UPDATER:=0}"
: "${SKIP_CRONET:=0}"

log() { printf '\033[1;36m[build-go]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build-go]\033[0m %s\n' "$*" >&2; exit 1; }

for cmd in curl tar unzip; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done

mkdir -p "$DEPS_DIR" "$DEST"

# ---------------------------------------------------------------------------
# 1. Pinned Go SDK (core/server/go.mod requires >= 1.25)
# ---------------------------------------------------------------------------
GO_ROOT="$DEPS_DIR/go-${GO_VERSION}/go"
if [ ! -x "$GO_ROOT/bin/go" ]; then
    GO_TARBALL="$DEPS_DIR/go-${GO_VERSION}.linux-amd64.tar.gz"
    if [ ! -f "$GO_TARBALL" ]; then
        log "Downloading Go ${GO_VERSION}"
        curl -fL --retry 3 -o "$GO_TARBALL.part" \
            "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
        mv "$GO_TARBALL.part" "$GO_TARBALL"
    fi
    log "Extracting Go SDK to $(dirname "$GO_ROOT")"
    rm -rf "$(dirname "$GO_ROOT")"
    mkdir -p "$(dirname "$GO_ROOT")"
    tar -xzf "$GO_TARBALL" -C "$(dirname "$GO_ROOT")"
fi

export GOROOT="$GO_ROOT"
export GOPATH="$DEPS_DIR/gopath"
export GOCACHE="$DEPS_DIR/gocache"
export GOMODCACHE="$DEPS_DIR/gomodcache"
mkdir -p "$GOPATH" "$GOCACHE" "$GOMODCACHE"
export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"

log "Go:        $(go version)"

# ---------------------------------------------------------------------------
# 2. protoc + Go plugins
# ---------------------------------------------------------------------------
PROTOC_ROOT="$DEPS_DIR/protoc-${PROTOC_VERSION}"
if [ ! -x "$PROTOC_ROOT/bin/protoc" ]; then
    PROTOC_ZIP="$DEPS_DIR/protoc-${PROTOC_VERSION}-linux-x86_64.zip"
    if [ ! -f "$PROTOC_ZIP" ]; then
        log "Downloading protoc ${PROTOC_VERSION}"
        curl -fL --retry 3 -o "$PROTOC_ZIP.part" \
            "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-x86_64.zip"
        mv "$PROTOC_ZIP.part" "$PROTOC_ZIP"
    fi
    log "Extracting protoc"
    rm -rf "$PROTOC_ROOT"
    mkdir -p "$PROTOC_ROOT"
    unzip -q "$PROTOC_ZIP" -d "$PROTOC_ROOT"
    chmod +x "$PROTOC_ROOT/bin/protoc"
fi
export PATH="$PROTOC_ROOT/bin:$PATH"
log "protoc:    $(protoc --version)"

if [ ! -x "$GOPATH/bin/protoc-gen-go" ]; then
    log "Installing protoc-gen-go"
    go install github.com/golang/protobuf/protoc-gen-go@latest
fi
if [ ! -x "$GOPATH/bin/protoc-gen-go-grpc" ]; then
    log "Installing protoc-gen-go-grpc"
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
fi

# ---------------------------------------------------------------------------
# 3. Build ThroneCore.exe (with same tags as script/build_go.sh)
# ---------------------------------------------------------------------------
TAGS="with_clash_api,with_gvisor,with_quic,with_wireguard,with_utls,with_dhcp,with_tailscale,badlinkname,tfogo_checklinkname0,with_purego,with_naive_outbound"

export GOOS=windows
export GOARCH
export CGO_ENABLED=0

pushd "$PROJECT_DIR/core/server" >/dev/null

log "Generating protobuf bindings"
(
    cd gen
    protoc -I . --go_out=. --go-grpc_out=. libcore.proto
)

VERSION_SINGBOX=$(go list -m -f '{{.Version}}' github.com/sagernet/sing-box)
log "sing-box:  $VERSION_SINGBOX"

log "go build -> $DEST/ThroneCore.exe  (GOOS=$GOOS GOARCH=$GOARCH)"
go build -v -o "$DEST" -trimpath \
    -ldflags "-w -s -X 'github.com/sagernet/sing-box/constant.Version=${VERSION_SINGBOX}' -X 'internal/godebug.defaultGODEBUG=multipathtcp=0' -checklinkname=0" \
    -tags "$TAGS"
popd >/dev/null

[ -f "$DEST/ThroneCore.exe" ] || die "ThroneCore.exe was not produced"

# ---------------------------------------------------------------------------
# 4. Fetch libcronet.dll
# ---------------------------------------------------------------------------
if [ "$SKIP_CRONET" != "1" ]; then
    log "Downloading libcronet.dll"
    curl -fL --retry 3 -o "$DEST/libcronet.dll" \
        "https://github.com/SagerNet/cronet-go/releases/latest/download/libcronet-windows-${GOARCH}.dll"
fi

# ---------------------------------------------------------------------------
# 5. Fetch updater.exe
# ---------------------------------------------------------------------------
if [ "$SKIP_UPDATER" != "1" ]; then
    # Matches build_go.sh: updater-windows-x${GOARCH: -2}.exe
    # amd64 -> updater-windows-x64.exe, arm64 -> updater-windows-x64.exe (same suffix),
    # 386   -> updater-windows-x86.exe
    UPD_TAG="${GOARCH: -2}"
    log "Downloading updater-windows-x${UPD_TAG}.exe"
    curl -fL --retry 3 -o "$DEST/updater.exe" \
        "https://github.com/throneproj/updater/releases/latest/download/updater-windows-x${UPD_TAG}.exe"
fi

log "Go artifacts staged at: $DEST"
ls -la "$DEST"
