#!/bin/sh
# AutoCLI installer — build from source (requires Zig 0.17.0+)
# Usage: curl -fsSL https://raw.githubusercontent.com/chy3xyz/autocli/main/scripts/install.sh | sh
#
# Options:
#   AUTOCLI_INSTALL_DIR  — install directory (default: /usr/local/bin)
#   AUTOCLI_VERSION      — tag to install (default: latest)

set -e

REPO="chy3xyz/autocli"
INSTALL_DIR="${AUTOCLI_INSTALL_DIR:-/usr/local/bin}"
BINARY_NAME="autocli"

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()    { printf "${CYAN}▸${NC} %s\n" "$1"; }
success() { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn()    { printf "${YELLOW}!${NC} %s\n" "$1"; }
error()   { printf "${RED}✗ Error:${NC} %s\n" "$1" >&2; exit 1; }

# ── Preflight checks ───────────────────────────────────────────────
for cmd in git curl; do
    command -v "$cmd" >/dev/null 2>&1 || error "$cmd is required but not found."
done

# Check Zig
if ! command -v zig >/dev/null 2>&1; then
    error "Zig is required. Install from https://ziglang.org/download/
  macOS:   brew install zig
  Linux:   snap install zig --classic
  Manual:  https://ziglang.org/download/#release-0.17.0"
fi

ZIG_VERSION=$(zig version 2>/dev/null || echo "unknown")
case "$ZIG_VERSION" in
    0.17.*) ;;
    *)
        warn "Zig $ZIG_VERSION detected — 0.17.0 is recommended."
        warn "Proceeding anyway, but build may fail."
        ;;
esac

# ── Clone / update repo ────────────────────────────────────────────
BUILD_DIR="${TMPDIR:-/tmp}/autocli-build-$$"
trap 'rm -rf "$BUILD_DIR"' EXIT

VERSION="${AUTOCLI_VERSION:-latest}"

if [ "$VERSION" = "latest" ]; then
    info "Cloning latest from https://github.com/${REPO}.git ..."
    git clone --depth 1 "https://github.com/${REPO}.git" "$BUILD_DIR" 2>/dev/null
else
    info "Cloning tag ${VERSION} from https://github.com/${REPO}.git ..."
    git clone --depth 1 --branch "$VERSION" "https://github.com/${REPO}.git" "$BUILD_DIR" 2>/dev/null
fi

cd "$BUILD_DIR"

# ── Build ──────────────────────────────────────────────────────────
info "Building with Zig ${ZIG_VERSION} ..."
zig build -Doptimize=ReleaseSafe 2>&1 | tail -5

if [ ! -f "zig-out/bin/${BINARY_NAME}" ]; then
    error "Build failed — binary not found at zig-out/bin/${BINARY_NAME}"
fi

# ── Install ────────────────────────────────────────────────────────
info "Installing to ${INSTALL_DIR}/${BINARY_NAME} ..."
mkdir -p "$INSTALL_DIR"

if [ -w "$INSTALL_DIR" ]; then
    cp "zig-out/bin/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
else
    info "(requires sudo for ${INSTALL_DIR})"
    sudo cp "zig-out/bin/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
fi

chmod +x "${INSTALL_DIR}/${BINARY_NAME}"

# ── Verify ─────────────────────────────────────────────────────────
if command -v "$BINARY_NAME" >/dev/null 2>&1; then
    INSTALLED=$("$BINARY_NAME" --version 2>/dev/null || echo "installed")
    success "${BOLD}${BINARY_NAME}${NC} installed! (${INSTALLED})"
else
    success "Installed to ${INSTALL_DIR}/${BINARY_NAME}"
    warn "Make sure ${INSTALL_DIR} is in your PATH."
fi

echo ""
echo "  Get started:"
echo "    ${BINARY_NAME} --help          # Show usage"
echo "    ${BINARY_NAME} list             # List all 333+ commands"
echo "    ${BINARY_NAME} hackernews front # Fetch HN front page"
echo "    ${BINARY_NAME} doctor           # Check environment"
echo ""
