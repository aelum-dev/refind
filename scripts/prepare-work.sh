#!/usr/bin/env bash
#
# prepare-work.sh — (re)create the three working trees the patches are built
# from, under work/:
#
#   work/refind-orig      the untouched upstream tarball
#   work/refind-pristine  orig + the gnuefi4-compat patch  (the test baseline)
#   work/refind-patched   pristine + the submenu-scrolling patch (the feature)
#
# Edit work/refind-patched (or the compat set in work/refind-pristine), then
# run scripts/commit-patches.sh to regenerate packaging/*.patch from the trees.
# The version and the patch order come from packaging/PKGBUILD itself.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$ROOT_DIR/packaging"
WORK="$ROOT_DIR/work"

VER="$(sed -n 's/^pkgver=\(.*\)$/\1/p' "$PKG_DIR/PKGBUILD" | head -n1)"
[ -n "$VER" ] || { echo "Error: cannot read pkgver from PKGBUILD." >&2; exit 1; }

mkdir -p "$WORK"
TARBALL="$WORK/refind-src-$VER.tar.gz"
if [ ! -f "$TARBALL" ]; then
    echo "==> downloading refind-src-$VER.tar.gz"
    curl -fL -o "$TARBALL" "https://sourceforge.net/projects/refind/files/$VER/refind-src-$VER.tar.gz"
fi

echo "==> extracting $VER"
rm -rf "$WORK/refind-orig" "$WORK/refind-pristine" "$WORK/refind-patched"
tar xzf "$TARBALL" -C "$WORK"
mv "$WORK/refind-$VER" "$WORK/refind-orig"
cp -a "$WORK/refind-orig" "$WORK/refind-pristine"

# The patches, in the order the PKGBUILD lists them: compat first (it becomes
# the pristine baseline), the feature patch on top (it becomes the diff between
# the two trees).
eval "$(sed -n '/^source=(/,/^)/p' "$PKG_DIR/PKGBUILD" | sed "s/\$pkgver/$VER/g")"
first=true
for src in "${source[@]}"; do
    case "$src" in
        *.patch)
            patch_file="$PKG_DIR/$(basename "$src")"
            [ -f "$patch_file" ] || { echo "Error: missing patch $patch_file" >&2; exit 1; }
            if $first; then
                echo "==> applying $(basename "$patch_file") to refind-pristine"
                (cd "$WORK/refind-pristine" && patch -p1 -s -i "$patch_file")
                first=false
            else
                echo "==> applying $(basename "$patch_file") to refind-patched"
                cp -a "$WORK/refind-pristine" "$WORK/refind-patched"
                (cd "$WORK/refind-patched" && patch -p1 -s -i "$patch_file")
            fi
            ;;
    esac
done
[ -d "$WORK/refind-patched" ] || { echo "Error: PKGBUILD lists no second patch; the scroll tree is undefined." >&2; exit 1; }

echo "==> trees ready under work/ (orig / pristine / patched)"
