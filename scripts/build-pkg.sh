#!/usr/bin/env bash
#
# build-pkg.sh — build the patched refind package with makepkg and move the
# result to dist/.
#
# The build runs in the refind-build container (this repo mounted at /work),
# because the toolchain it needs (gnu-efi, the EFI build flags) is exactly what
# the package is about — see AGENTS.md for the one-time container setup.
# LOCAL=1 runs makepkg on this machine instead (needs gnu-efi installed here).
#
# Usage:
#   ./scripts/build-pkg.sh              # clean build (make clean first)
#   ./scripts/build-pkg.sh --keep-src   # reuse packaging/src from the last run
#
# Publish to the [aelum] repository with:
#   ../repo/publish-repo.sh refind/dist/<the .pkg.tar.zst>
# (the publisher signs the package and the DB; no signing happens here.)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$ROOT_DIR/packaging"
DIST_DIR="$ROOT_DIR/dist"
CONTAINER="${CONTAINER:-refind-build}"

KEEP_SRC=false
for arg in "$@"; do
    case "$arg" in
        --keep-src) KEEP_SRC=true ;;
        *) echo "Usage: $0 [--keep-src]" >&2; exit 2 ;;
    esac
done

mkdir -p "$DIST_DIR"
VER="$(sed -n 's/^pkgver=\(.*\)$/\1/p' "$PKG_DIR/PKGBUILD" | head -n1)"
REL="$(sed -n 's/^pkgrel=\(.*\)$/\1/p' "$PKG_DIR/PKGBUILD" | head -n1)"
EXPECTED="refind-$VER-$REL-x86_64.pkg.tar.zst"

if [ "${LOCAL:-0}" = "1" ]; then
    command -v makepkg >/dev/null || { echo "Error: makepkg not found (or drop LOCAL)." >&2; exit 1; }
    [ "$KEEP_SRC" = false ] && rm -rf "$PKG_DIR/src"
    (cd "$PKG_DIR" && makepkg --noconfirm --skippgpcheck)
    mv -f "$PKG_DIR"/refind-*.pkg.tar.zst "$DIST_DIR/"
else
    docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true \
        || { echo "Error: container $CONTAINER is not running. Create it (see refind/AGENTS.md)." >&2; exit 1; }
    # The container's /work is this repo; makepkg refuses root, so use a
    # builder user. Caching the tarball under work/ keeps makepkg from
    # re-downloading it.
    docker exec -e VER="$VER" "$CONTAINER" bash -eu -o pipefail -c '
        pacman -Sy --noconfirm bash dosfstools efibootmgr gnu-efi >/dev/null
        id builder >/dev/null 2>&1 || useradd -m -u 1000 -G users builder
        mkdir -p /work/work
        [ -f "/work/work/refind-src-$VER.tar.gz" ] || \
            curl -fL -o "/work/work/refind-src-$VER.tar.gz" \
            "https://sourceforge.net/projects/refind/files/$VER/refind-src-$VER.tar.gz"
        cp -n "/work/work/refind-src-$VER.tar.gz" /work/packaging/ 2>/dev/null || true
        chown -R 1000:1000 /work/packaging
        su builder -c "cd /work/packaging && makepkg --noconfirm --skippgpcheck"
    '
    [ "$KEEP_SRC" = false ] && docker exec "$CONTAINER" rm -rf /work/packaging/src
    docker exec "$CONTAINER" bash -c 'chown 1000:1000 /work/packaging/refind-*.pkg.tar.zst 2>/dev/null || true'
    mv -f "$PKG_DIR"/refind-*.pkg.tar.zst "$DIST_DIR/"
fi

# The PKGBUILD is a split package: both halves must exist, and both get
# published — publishing only the binary would leave refind-docs resolving
# from extra forever.
DOCS="refind-docs-$VER-$REL-x86_64.pkg.tar.zst"
for f in "$EXPECTED" "$DOCS"; do
    ls "$DIST_DIR/$f" >/dev/null || { echo "Error: expected $DIST_DIR/$f — not found." >&2; exit 1; }
done
( cd "$DIST_DIR" && sha256sum "$EXPECTED" "$DOCS" | tee /dev/stderr > "refind-$VER-$REL.sha256" )
echo "==> built dist/$EXPECTED + dist/$DOCS"
echo "    publish BOTH with:"
echo "      ../repo/publish-repo.sh refind/dist/$EXPECTED"
echo "      ../repo/publish-repo.sh refind/dist/$DOCS"
