#!/usr/bin/env bash
#
# build-bins.sh — build refind_x64.efi from both trees in the container and
# leave them where tests/*.sh expect them:
#
#   work/refind-baseline.efi   from work/refind-pristine (compat fixes only)
#   work/refind-patched.efi    from work/refind-patched  (+ submenu scrolling)
#
# A full `make` per tree, not just `make -C refind`: the top-level make builds
# libeg/mok/EfiLib/gzip too, and linking only refind/'s objects against stale
# library archives silently keeps yesterday's bug (measured the hard way).
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${CONTAINER:-refind-build}"

for tree in refind-pristine refind-patched; do
    [ -d "$ROOT_DIR/work/$tree" ] || { echo "Error: work/$tree missing — run scripts/prepare-work.sh first." >&2; exit 1; }
done

docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true \
    || { echo "Error: container $CONTAINER is not running. Create it (see refind/AGENTS.md)." >&2; exit 1; }

docker exec "$CONTAINER" bash -eu -o pipefail -c '
    cd /work/work/refind-pristine && make clean >/dev/null 2>&1 || true
    make > /tmp/build-baseline.log 2>&1 || { tail -20 /tmp/build-baseline.log; exit 1; }
    cp refind/refind_x64.efi /work/work/refind-baseline.efi
    cd /work/work/refind-patched && make clean >/dev/null 2>&1 || true
    make > /tmp/build-patched.log 2>&1 || { tail -20 /tmp/build-patched.log; exit 1; }
    cp refind/refind_x64.efi /work/work/refind-patched.efi
    chown 1000:1000 /work/work/refind-baseline.efi /work/work/refind-patched.efi
'
ls -la "$ROOT_DIR"/work/refind-{baseline,patched}.efi
echo "==> now run: tests/test-scroll.sh"
