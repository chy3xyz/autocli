#!/bin/sh
# Build release binaries for all supported targets.
# Usage: ./scripts/build-release.sh [version]
# Output: release/<target>/autocli

set -e

VERSION="${1:-dev}"
OUTDIR="release"

TARGETS="
x86_64-linux-musl
aarch64-linux-musl
x86_64-macos
aarch64-macos
x86_64-windows-gnu
"

info() { printf "\033[0;36m▸\033[0m %s\n" "$1"; }
success() { printf "\033[0;32m✓\033[0m %s\n" "$1"; }

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

for target in $TARGETS; do
    [ -z "$target" ] && continue
    info "Building ${target} ..."

    zig build -Doptimize=ReleaseSafe -Dtarget="${target}" 2>&1 | tail -2

    DEST="${OUTDIR}/${target}"
    mkdir -p "$DEST"

    if [ -f "zig-out/bin/autocli.exe" ]; then
        cp "zig-out/bin/autocli.exe" "${DEST}/"
    elif [ -f "zig-out/bin/autocli" ]; then
        cp "zig-out/bin/autocli" "${DEST}/"
    fi

    # Package
    cd "$OUTDIR"
    if echo "$target" | grep -q "windows"; then
        zip -q "autocli-${target}.zip" "${target}/autocli.exe"
    else
        tar czf "autocli-${target}.tar.gz" "${target}/autocli"
    fi
    cd ..

    success "autocli-${target} packaged"
done

echo ""
info "Release artifacts in ${OUTDIR}/:"
ls -lh "${OUTDIR}/"*.tar.gz "${OUTDIR}/"*.zip 2>/dev/null || true
