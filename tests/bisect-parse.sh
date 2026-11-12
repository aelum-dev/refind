#!/usr/bin/env bash
#
# bisect-parse.sh — does a menuentry WITH N submenuentry blocks reach the main
# menu? Check via rEFInd's own log ("Adding menu entry for ..."). This is how
# the gnu-efi ReallocatePool ABI bug was bisected (14 blocks fine, 15+ dropped;
# fixed by the compat patch). Usage: bisect-parse.sh <num-blocks> [efi]
#
# Defaults to work/refind-patched.efi; pass work/refind-baseline.efi as the
# second argument to compare.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT_DIR/work"
FIX="$WORK/fixture"
QMON="${QMON:-$ROOT_DIR/../docker/scripts/qemu-mon.py}"
CONTAINER="${CONTAINER:-refind-build}"
N=${1:-1}
EFI=${2:-$WORK/refind-patched.efi}
BASE=$(basename "$EFI")

[ -f "$EFI" ] || { echo "Error: $EFI missing — run tests/build-bins.sh." >&2; exit 1; }
mkdir -p "$FIX"

{
    echo "log_level 5"
    echo "timeout 0"
    echo "resolution 1024 768"
    echo "scanfor manual"
    echo 'menuentry "Plain" {'
    echo '    loader /EFI/aelum/refind_x64.efi'
    echo '}'
    echo 'menuentry "Test sub" {'
    echo '    loader /EFI/aelum/refind_x64.efi'
    for i in $(seq 1 "$N"); do
        echo "    submenuentry \"S\" {"
        echo "        options \"a\""
        echo "    }"
    done
    echo '}'
} > "$FIX/bisect.conf"

docker exec "$CONTAINER" bash -c '
    pacman -Sy --noconfirm mtools dosfstools >/dev/null 2>&1
    if [ ! -f /work/work/fixture/esp-bisect.img ]; then
        dd if=/dev/zero of=/work/work/fixture/esp-bisect.img bs=1M count=64 status=none
        mkfs.vfat -F 32 /work/work/fixture/esp-bisect.img >/dev/null
        mmd -i /work/work/fixture/esp-bisect.img ::/EFI ::/EFI/BOOT
        mcopy -s -n -i /work/work/fixture/esp-bisect.img /work/work/refind-patched/icons ::/EFI/BOOT/
    fi
    mcopy -o -i /work/work/fixture/esp-bisect.img "/work/work/'"$BASE"'" ::EFI/BOOT/BOOTX64.EFI
    mcopy -o -i /work/work/fixture/esp-bisect.img /work/work/fixture/bisect.conf ::EFI/BOOT/refind.conf
    chown -R 1000:1000 /work/work/fixture'

rm -f "$FIX/monitor.sock"
cp /usr/share/OVMF/x64/OVMF_VARS.4m.fd "$FIX/vars-bisect.fd"
qemu-system-x86_64 -enable-kvm -m 1G -machine q35 -display none -nodefaults -vga none -device ramfb \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/x64/OVMF_CODE.4m.fd \
    -drive if=pflash,format=raw,file="$FIX/vars-bisect.fd" \
    -drive file="$FIX/esp-bisect.img",format=raw,if=virtio \
    -monitor "unix:$FIX/monitor.sock,server,nowait" &
QPID=$!
sleep 8
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
echo "== N=$N ($BASE) =="
docker exec "$CONTAINER" bash -c 'mtype -i /work/work/fixture/esp-bisect.img ::EFI/BOOT/refind.log' \
  | tr -d '\000' | grep -E "Adding menu entry for 'Boot (Plain|Test sub)|Creating subscreen|Entry is disabled" || echo "(no matches)"
