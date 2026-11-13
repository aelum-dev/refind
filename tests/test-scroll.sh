#!/usr/bin/env bash
#
# test-scroll.sh — prove the submenu-scrolling patch in a real OVMF boot,
# headless: one menuentry holding 40 snapshot-style submenuentries (more than
# the window can hold), under a banner_scale fillscreen image whose artwork band
# sits at 5%-11% of the screen height — the shape of the Aelum theme's banner,
# which is the case that let the window grow up through the logo.
#
#   baseline (work/refind-baseline.efi): the list never scrolls; after End the
#     selection is off-screen and the rows run past the bottom of the screen,
#     and the window covers the banner's artwork band.
#   patched  (work/refind-patched.efi):  the window scrolls, ^/v indicators
#     appear, End and Home keep the selection visible, and the artwork band is
#     untouched in every frame (measured, at the end of this script).
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

# The mode the fixture boots, and the band of the banner the submenu must not
# cover. A banner_scale fillscreen image is scaled to the screen, so its artwork
# occupies a fraction of the display: the Aelum theme's lockup sits at 5%-11% of
# a 2160-tall image (live-iso/scripts/gen-refind-theme.py), which is what the
# snapshot submenu used to cut in half. The fixture draws that band in solid
# white so a screenshot can be measured against it.
#
# 1024x768 is the largest mode ramfb's GOP offers — rEFInd logs "Error setting
# graphics mode … using default mode!" and drops to 800x600 for anything bigger,
# which the check at the end treats as a failure rather than a silent downgrade.
XRES="${XRES:-1024}"
YRES="${YRES:-768}"
BAND_TOP=$((YRES * 5 / 100))
BAND_BOT=$((YRES * 11 / 100))
BAND_LEFT=$((XRES * 38 / 100))
BAND_RIGHT=$((XRES * 62 / 100))

mkdir -p "$FIX" "$SHOTS"
for v in baseline patched; do
    [ -f "$WORK/refind-$v.efi" ] || { echo "Error: work/refind-$v.efi missing — run tests/build-bins.sh." >&2; exit 1; }
done

# --- the banner: a dark field with the artwork band, like the Aelum theme -----
python3 - "$FIX/banner.png" "$XRES" "$YRES" "$BAND_TOP" "$BAND_BOT" "$BAND_LEFT" "$BAND_RIGHT" <<'PY'
import sys
from PIL import Image, ImageDraw
path, w, h, top, bot, left, right = (sys.argv[1], *map(int, sys.argv[2:]))
img = Image.new("RGB", (w, h), (24, 20, 18))          # the theme's #141218
ImageDraw.Draw(img).rectangle((left, top, right, bot), fill=(240, 240, 240))
img.save(path)
PY

# --- the fixture config: one entry holding 40 snapshot-style submenuentries ---
{
    echo "log_level 5"
    echo "timeout 0"
    echo "resolution $XRES $YRES"
    # fillscreen is what the Aelum theme does (theme.conf), and it is what makes
    # rEFInd discard the banner's bottom edge: BannerBottomEdge becomes the
    # screen height, which menu.c then treats as "no banner at all".
    echo "banner banner.png"
    echo "banner_scale fillscreen"
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
        mcopy -i /work/work/fixture/esp-$v.img /work/work/fixture/banner.png ::/EFI/BOOT/banner.png
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
      | tr -d '\000' | grep -E "ScanCode|RunGenericMenu|GotoSub|Selecting item|graphics mode|video mode" | head -30
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

# --- the assertion: the submenu window must never cover the banner's artwork.
# The window is filled with the banner's own corner colour, so an overlap shows
# up as the band losing pixels the main-menu frame had. The baseline build is
# expected to lose them (that is the bug); the patched one must not.
python3 - "$FIX" "$XRES" "$YRES" "$BAND_TOP" "$BAND_BOT" "$BAND_LEFT" "$BAND_RIGHT" <<'PY'
import sys, os, glob
from PIL import Image
fix, xres, yres, top, bot, left, right = sys.argv[1], *map(int, sys.argv[2:])

def band(p):
    im = Image.open(p).convert("RGB")
    if im.size != (xres, yres):
        sys.exit(f"{os.path.basename(p)} is {im.size[0]}x{im.size[1]}, not {xres}x{yres}: "
                 "the fixture did not boot in the requested mode")
    px = im.crop((left, top, right + 1, bot + 1)).load()
    w, h = right - left + 1, bot - top + 1
    return sum(1 for y in range(h) for x in range(w)
               if px[x, y][0] > 150 and px[x, y][1] > 150 and px[x, y][2] > 150), w * h

fail = 0
for v in ("baseline", "patched"):
    frames = sorted(glob.glob(os.path.join(fix, f"{v}-*.ppm")))
    if not frames:
        print(f"{v}: no screenshots")
        continue
    ref, total = band(frames[0])
    print(f"{v}: banner band {ref}/{total} px in the main-menu frame "
          f"(band y {top}..{bot}, x {left}..{right})")
    if ref == 0:
        sys.exit("the banner's artwork band is not on screen — the fixture banner is not being drawn")
    for p in frames[1:]:
        n, _ = band(p)
        lost = ref - n
        print(f"  {os.path.basename(p)}: {n}/{ref} band px kept"
              + ("" if lost <= 0 else f" — {lost} covered by the window"))
        if v == "patched" and lost > 0:
            fail = 1
sys.exit(fail)
PY
