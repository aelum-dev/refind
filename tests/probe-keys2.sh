#!/usr/bin/env bash
#
# probe-keys2.sh — boot the patched binary with log_level 5, send an explicit
# key sequence (one qemu-mon call, keys 1s apart), then read rEFInd's log with
# context: the scan codes AND what the menu did with them. This is how the
# key map in NOTES.md was settled (keys arrive UN-shifted; f2/Insert open the
# submenu).
#
# Usage: probe-keys2.sh [sendkey tokens...]   (default: right f2 end home)
# Uses work/refind-patched.efi — build it with tests/build-bins.sh first.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT_DIR/work"
FIX="$WORK/fixture"
QMON="${QMON:-$ROOT_DIR/../docker/scripts/qemu-mon.py}"
CONTAINER="${CONTAINER:-refind-build}"
KEYS=("$@"); [ ${#KEYS[@]} -gt 0 ] || KEYS=(right f2 end home)

[ -f "$WORK/refind-patched.efi" ] || { echo "Error: work/refind-patched.efi missing — run tests/build-bins.sh." >&2; exit 1; }
mkdir -p "$FIX"

# fixture config: two entries, the second holds a small submenu, logging on
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
    for i in $(seq 1 3); do
        echo "    submenuentry \"S$i\" {"
        echo "        options \"a\""
        echo "    }"
    done
    echo '}'
} > "$FIX/probe2.conf"
docker exec "$CONTAINER" bash -c '
    pacman -Sy --noconfirm mtools dosfstools >/dev/null 2>&1
    if [ ! -f /work/work/fixture/esp-probe.img ]; then
        dd if=/dev/zero of=/work/work/fixture/esp-probe.img bs=1M count=64 status=none
        mkfs.vfat -F 32 /work/work/fixture/esp-probe.img >/dev/null
        mmd -i /work/work/fixture/esp-probe.img ::/EFI ::/EFI/BOOT
        mcopy -s -n -i /work/work/fixture/esp-probe.img /work/work/refind-patched/icons ::/EFI/BOOT/
    fi
    mcopy -o -i /work/work/fixture/esp-probe.img /work/work/refind-patched.efi ::EFI/BOOT/BOOTX64.EFI
    mcopy -o -i /work/work/fixture/esp-probe.img /work/work/fixture/probe2.conf ::EFI/BOOT/refind.conf
    chown -R 1000:1000 /work/work/fixture'

rm -f "$FIX/monitor.sock"
cp /usr/share/OVMF/x64/OVMF_VARS.4m.fd "$FIX/vars-probe2.fd"
qemu-system-x86_64 -enable-kvm -m 1G -machine q35 -display none -nodefaults -vga none -device ramfb \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/x64/OVMF_CODE.4m.fd \
    -drive if=pflash,format=raw,file="$FIX/vars-probe2.fd" \
    -drive file="$FIX/esp-probe.img",format=raw,if=virtio \
    -monitor "unix:$FIX/monitor.sock,server,nowait" &
QPID=$!
sleep 8
CMDS=()
for k in "${KEYS[@]}"; do CMDS+=("sendkey $k"); done
python3 "$QMON" --socket "$FIX/monitor.sock" --wait 10 "${CMDS[@]}" >/dev/null
sleep 1
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
echo "--- keys sent: ${KEYS[*]} ---"
docker exec "$CONTAINER" bash -c 'mtype -i /work/work/fixture/esp-probe.img ::EFI/BOOT/refind.log' \
  | tr -d '\000' | grep -iE "ScanCode|Key:|Selecting|subscreen|submenu|Goto|arrow" | head -60
