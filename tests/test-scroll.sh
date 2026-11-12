#!/usr/bin/env bash
#
# test-scroll.sh — prove the submenu-scrolling patch in a real OVMF boot,
# headless: one menuentry holding 40 snapshot-style submenuentries (more than
# the window can hold).
#
#   baseline (work/refind-baseline.efi): the list never scrolls; after End the
#     selection is off-screen and the rows run past the bottom of the screen.
#   patched  (work/refind-patched.efi):  the window scrolls, ^/v indicators
#     appear, End and Home keep the selection visible.
#
# Build the two binaries first: tests/build-bins.sh.
# Screenshots land in work/shots/; rEFInd's own log (log_level 5) is dumped
# per case so every keystroke is attributable.
#
# Keys arrive UN-shifted (see NOTES.md): right/left move between icons, f2
# opens the selected entry's submenu, end/home jump to the last/first item.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT_DIR/work"
FIX="$WORK/fixture"
SHOTS="$WORK/shots"
MON="$FIX/monitor.sock"
QMON="${QMON:-$ROOT_DIR/../docker/scripts/qemu-mon.py}"
CONTAINER="${CONTAINER:-refind-build}"
OVMF_CODE=/usr/share/OVMF/x64/OVMF_CODE.4m.fd
OVMF_VARS_SRC=/usr/share/OVMF/x64/OVMF_VARS.4m.fd

mkdir -p "$FIX" "$SHOTS"
for v in baseline patched; do
    [ -f "$WORK/refind-$v.efi" ] || { echo "Error: work/refind-$v.efi missing — run tests/build-bins.sh." >&2; exit 1; }
done

# --- the fixture config: one entry holding 40 snapshot-style submenuentries ---
{
    echo "log_level 5"
    echo "timeout 0"
    echo "resolution 1024 768"
    echo "scanfor manual"
    echo 'menuentry "Aelum" {'
    echo '    loader /EFI/aelum/refind_x64.efi'
    echo '}'
    echo 'menuentry "Snapshot history" {'
    echo '    loader /EFI/aelum/refind_x64.efi'
    for n in $(seq 40 -1 1); do
        # multi-line stanza: AddSubmenu reads lines until "}" and makes ONE
        # entry per block, so one-line blocks would collapse into a single entry
        printf '    submenuentry "Snapshot %d - 11/12/26 %02d:%02d PM - post" {\n' \
            "$n" "$((9 + n % 12))" "$((n % 60))"
        printf '        options "rootflags=subvol=@/.snapshots/%d/snapshot"\n' "$n"
        printf '    }\n'
    done
    echo '}'
} > "$FIX/refind.conf"

# --- two ESP images, one per binary (superfloppy FAT: OVMF probes block I/O) ---
docker exec "$CONTAINER" bash -c '
    pacman -Sy --noconfirm mtools dosfstools >/dev/null 2>&1
    for v in baseline patched; do
        rm -f /work/work/fixture/esp-$v.img
        dd if=/dev/zero of=/work/work/fixture/esp-$v.img bs=1M count=64 status=none
        mkfs.vfat -F 32 /work/work/fixture/esp-$v.img >/dev/null
        mmd -i /work/work/fixture/esp-$v.img ::/EFI ::/EFI/BOOT
        mcopy -i /work/work/fixture/esp-$v.img /work/work/refind-$v.efi ::/EFI/BOOT/BOOTX64.EFI
        mcopy -i /work/work/fixture/esp-$v.img /work/work/fixture/refind.conf ::/EFI/BOOT/refind.conf
        # rEFInd forces textonly=TRUE when the icons directory is missing next
        # to its config (config.c) - the graphics submenu path needs it present.
        mcopy -s -n -i /work/work/fixture/esp-$v.img /work/work/refind-patched/icons ::/EFI/BOOT/
        chown -R 1000:1000 /work/work/fixture
    done'
chown -R "$(id -u):$(id -g)" "$FIX" 2>/dev/null || true

run_case() {
    local v=$1
    rm -f "$MON"
    cp "$OVMF_VARS_SRC" "$FIX/vars-$v.fd"
    # ramfb: QEMU mirrors the guest GOP framebuffer continuously, so screendump
    # is live; with -vga std + -display none partial GOP blits never reach the
    # screendump surface (only mode-switch frames do — measured).
    qemu-system-x86_64 -enable-kvm -m 1G -machine q35 -display none -nodefaults -vga none -device ramfb \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$FIX/vars-$v.fd" \
        -drive file="$FIX/esp-$v.img",format=raw,if=virtio \
        -monitor "unix:$MON,server,nowait" &
    local qpid=$!
    sleep 8
    python3 "$QMON" --socket "$MON" --wait 10 "screendump $FIX/$v-1-main.ppm" >/dev/null
    python3 "$QMON" --socket "$MON" "sendkey right" "sendkey f2" "screendump $FIX/$v-2-sub-top.ppm" >/dev/null
    sleep 1
    python3 "$QMON" --socket "$MON" "screendump $FIX/$v-3-sub-top.ppm" >/dev/null
    python3 "$QMON" --socket "$MON" "sendkey end" "screendump $FIX/$v-4-sub-end.ppm" >/dev/null
    sleep 1
    python3 "$QMON" --socket "$MON" "screendump $FIX/$v-5-sub-end.ppm" >/dev/null
    python3 "$QMON" --socket "$MON" "sendkey home" "screendump $FIX/$v-6-sub-home.ppm" >/dev/null
    kill "$qpid" 2>/dev/null || true
    wait "$qpid" 2>/dev/null || true
    echo "--- $v log (keys + menu actions) ---"
    docker exec "$CONTAINER" bash -c "mtype -i /work/work/fixture/esp-$v.img ::EFI/BOOT/refind.log" \
      | tr -d '\000' | grep -E "ScanCode|RunGenericMenu|GotoSub|Selecting item" | head -30
}

for v in baseline patched; do
    echo "== $v"
    run_case "$v"
done

python3 - "$FIX" "$SHOTS" <<'PY'
import sys, os, glob
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
for p in sorted(glob.glob(os.path.join(src, "*.ppm"))):
    Image.open(p).save(os.path.join(dst, os.path.basename(p).replace(".ppm", ".png")))
    print("wrote", os.path.join(dst, os.path.basename(p).replace(".ppm", ".png")))
PY
