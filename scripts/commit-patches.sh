#!/usr/bin/env bash
#
# commit-patches.sh — regenerate the patch files in packaging/ from the trees
# under work/, update the PKGBUILD's sha256sums, and prove the result: a fresh
# extraction of the tarball plus the regenerated patches must reproduce
# work/refind-patched byte for byte.
#
#   work/refind-orig     → work/refind-pristine   = refind-<ver>-gnuefi4-compat.patch
#   work/refind-pristine → work/refind-patched    = refind-<ver>-submenu-scrolling.patch
#
# A patch covers exactly the source files that differ between its pair of
# trees; build artifacts (.o/.a/.efi/.so/.d, gptsync binaries) are ignored, so
# the trees may already have been built (tests/build-bins.sh).
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$ROOT_DIR/packaging"
WORK="$ROOT_DIR/work"

VER="$(sed -n 's/^pkgver=\(.*\)$/\1/p' "$PKG_DIR/PKGBUILD" | head -n1)"
COMPAT_PATCH="$PKG_DIR/refind-$VER-gnuefi4-compat.patch"
SCROLL_PATCH="$PKG_DIR/refind-$VER-submenu-scrolling.patch"

for tree in refind-orig refind-pristine refind-patched; do
    [ -d "$WORK/$tree" ] || { echo "Error: work/$tree missing — run scripts/prepare-work.sh first." >&2; exit 1; }
done

# Source files that differ between two trees (build artifacts excluded);
# printed relative to the first tree.
changed_files() {
    diff -rq "$1" "$2" 2>/dev/null \
        | sed -n "s|^Files $1/\(.*\) and .* differ\$|\1|p" \
        | grep -vE '\.(o|a|efi|so|d|png|ppm|zst|gz|tar)$' \
        | grep -v '/gptsync_[a-z0-9]*$' \
        || true
}

make_patch() { # make_patch <from-tree> <to-tree> <out-file>
    local from="$WORK/$1" to="$WORK/$2" out="$3" f n=0
    : > "$out"
    while IFS= read -r f; do
        # diff exits 1 when files differ — that is the normal case here.
        diff -u --label "a/$f" --label "b/$f" "$from/$f" "$to/$f" >> "$out" || true
        n=$((n + 1))
    done < <(changed_files "$from" "$to")
    [ "$n" -gt 0 ] || { echo "Error: no changed sources between $1 and $2" >&2; exit 1; }
    echo "==> wrote $(basename "$out") ($n files)"
}

make_patch refind-orig refind-pristine "$COMPAT_PATCH"
make_patch refind-pristine refind-patched "$SCROLL_PATCH"

# --- update the PKGBUILD's sha256sums for the two patch entries ---------------
newsums=()
for p in "$COMPAT_PATCH" "$SCROLL_PATCH"; do
    newsums+=("$(sha256sum "$p" | cut -d' ' -f1)")
done
python3 - "$PKG_DIR/PKGBUILD" "${newsums[0]}" "${newsums[1]}" <<'PY'
import re, sys
path, compat, scroll = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
m = re.search(r'sha256sums=\((.*?)\)', src, re.S)
if not m:
    sys.exit("no sha256sums array found")
entries = re.findall(r"'([0-9a-f]{64})'", m.group(1))
if len(entries) != 3:
    sys.exit(f"expected 3 sha256sums, found {len(entries)}")
new = f"'{entries[0]}'\n            '{compat}'\n            '{scroll}'"
start, end = m.span(1)
open(path, "w").write(src[:start] + new + src[end:])
print("==> PKGBUILD sha256sums updated")
PY

# --- round-trip proof: fresh tarball + regenerated patches == work/refind-patched
RT="$WORK/.roundtrip"
rm -rf "$RT" && mkdir -p "$RT"
tar xzf "$WORK/refind-src-$VER.tar.gz" -C "$RT"
(cd "$RT/refind-$VER" && patch -p1 -s -i "$COMPAT_PATCH" && patch -p1 -s -i "$SCROLL_PATCH")
fail=0
extra=$(changed_files "$RT/refind-$VER" "$WORK/refind-patched")
if [ -n "$extra" ]; then
    echo "MISMATCH after round-trip (files the patches did not reproduce):" >&2
    echo "$extra" >&2
    fail=1
fi
rm -rf "$RT"
[ "$fail" = 0 ] || exit 1
echo "==> round-trip OK: fresh tarball + regenerated patches reproduce work/refind-patched"
