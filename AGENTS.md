# Aelum refind — Agent Context

This repo builds and publishes **Aelum's `refind` package**: upstream rEFInd
0.14.2 plus two patches, shipped in the `[aelum]` pacman repository as a
drop-in replacement for extra's `refind`. What makes pacman pick ours is
**repository order, not version**: measured with pacman 7.1, one package name
in two enabled repositories is won by the repository listed FIRST in
pacman.conf, even against a higher version later (extra carries 0.14.2-3;
the installer and the ISO build list `[aelum]` before `[extra]`, which is
what selects ours). It is what makes the snapshot boot menu's submenu
scrollable on installed systems.

**Read `NOTES.md` before touching the patches.** It holds every measured fact
behind them (the gnu-efi ABI analysis with disassembly evidence, the QEMU key
map, the ramfb capture trick, the fixture quirks). Re-deriving any of it the
expensive way is avoidable.

## Why the package exists

1. **Scrollable graphical submenus** (`refind-<ver>-submenu-scrolling.patch`,
   only `refind/menu.c`): upstream's graphical submenu never scrolls —
   `ComputeSubScreenWindowSize` had a literal `// TODO: Implement scrolling`.
   The patch gives that function a `VisibleRows` out-param, sets
   `State->MaxVisible` from the measured window in `GraphicsMenuStyle` INIT,
   paints only `FirstVisible..LastVisible` at relative rows with `^`/`v`
   overflow markers, and re-paints through PAINT_ALL when the selection
   leaves the window. It reuses rEFInd's own `SCROLL_MODE_TEXT` state machine
   (`AdjustScrollState`/`UpdateScroll` are already called for every menu), so
   arrows/Home/End/PageUp/PageDown come free. Two layout fixes ride along, both
   measured in NOTES.md: the window is capped at 2/3 of the screen height (an
   uncapped one under a `banner_scale fillscreen` banner starts at 2.5 font
   heights from the top and cut the theme's lockup in half at every common
   mode), and the text field reserves one cell more so the `^`/`v` markers get a
   margin instead of butting into a full-length entry.
2. **The gnu-efi 4.0.4 ABI bug** (`refind-<ver>-gnuefi4-compat.patch`):
   Arch builds libefi.a with `GNU_EFI_USE_MS_ABI=1`; rEFInd compiles with
   `EFIAPI`=empty and calls `SetMem`/`CopyMem`/`CompareGuid`/`ReallocatePool`
   directly — SysV registers into ms_abi functions. Measured symptom: any menu
   list growing past 16 entries loses its parent entry (`AddListElement` →
   broken `ReallocatePool`). No build flag fixes this (see NOTES.md for why);
   the patch routes every call site through ABI-safe code: `MySetMem` (new,
   in `refind/lib.h`), `MyCopyMem` (rEFInd's own existing idiom),
   `GuidsAreEqual`, local `EfiReallocatePool` helpers, and a `CompareMem`
   macro for `filesystems/`. (Measured Nov 2026: extra's current 0.14.2-3
   binary does NOT show the bug — Arch fixed their own build by April; the
   bug is what an unpatched upstream 0.14.2 does against today's gnu-efi,
   which is the build this repo produces.)
3. **Buildability on current Arch**: binutils ≥ 2.42 removed the `efi-app-*`
   objcopy targets (the patch's Make.common hunk produces the same PE32+ via
   `-O pei-x86-64 --subsystem 10:3`), and gnu-efi 4 headers collide with
   `EfiLib/gnuefi-helper.c`'s duplicate `AsciiStrLen`.

## Layout

```
packaging/            PKGBUILD + the two patch files (the release inputs)
scripts/prepare-work.sh    work/{refind-orig,refind-pristine,refind-patched} from tarball+patches
scripts/commit-patches.sh  regenerate patches from the trees, update PKGBUILD sums, round-trip prove
scripts/build-pkg.sh       makepkg in the container → dist/<pkg>.pkg.tar.zst (+ .sha256)
tests/build-bins.sh        work/refind-{baseline,patched}.efi from the two trees
tests/test-scroll.sh       the headless OVMF proof (screenshots in work/shots/)
tests/probe-keys2.sh       key map: rEFInd's own log vs QEMU sendkey
tests/bisect-parse.sh      N submenuentry blocks → does the entry survive?
NOTES.md                   measured facts — the reason the patches are shaped this way
dist/                      built packages (gitignored)
work/                      trees, fixtures, shots, test binaries (gitignored)
```

`work/refind-orig` → `work/refind-pristine` is the compat patch;
`work/refind-pristine` → `work/refind-patched` is the scrolling patch. Edit
the trees, never the patch files.

## Container (one-time setup)

The build and the proof harness run in a warm Arch container with this repo
mounted at `/work` (the host stays root-free):

```bash
docker run -d --name refind-build -v "$PWD":/work archlinux:latest sleep infinity
docker exec refind-build pacman -Syu --noconfirm base-devel gnu-efi dosfstools mtools curl
```

`build-pkg.sh` and `tests/build-bins.sh` re-install makedepends idempotently.
Files the container writes are root-owned; the scripts chown to 1000:1000.

## The loop

```bash
./scripts/prepare-work.sh            # (re)create the three trees
# edit work/refind-patched/... (or the compat set in work/refind-pristine)
./tests/build-bins.sh                # both .efi binaries (full make — see the script's comment)
./tests/test-scroll.sh              # the proof: work/shots/{baseline,patched}-*.png
./scripts/commit-patches.sh         # regenerate patches + sums, round-trip verified
./scripts/build-pkg.sh              # dist/refind-<ver>-<rel>-x86_64.pkg.tar.zst
../repo/publish-repo.sh refind/dist/<that file>   # signs + uploads to [aelum]
```

`tests/test-scroll.sh` needs host `qemu-system-x86_64`, OVMF (`/usr/share/OVMF/x64/`),
`python3` with Pillow, and `../docker/scripts/qemu-mon.py` (overridable via
`QMON=`). What "passing" looks like: baseline frames show the list overflowing
the screen with the selection off-screen after End, and its window covering the
fixture banner's artwork band; patched frames show the window scrolled with
`^`/`v` markers, the selection visible, and that band untouched — the script
counts the band's pixels in every frame and exits non-zero if the window covered
any of them.

## Testing a change on an installed system

`make -C docker install-pkg PKG=refind/dist/<pkg>` is not enough. The firmware boots the
**ESP's own copy** of the binary, which the installer wrote once: `pacman -U` replaces
`/usr/share/refind/refind_x64.efi` and leaves `/efi/EFI/refind/refind_x64.efi` exactly as it
was (measured Nov 2026: package 0.14.2-5 installed, the ESP still held the 0.14.2-4 binary by
sha256, mtime = install time). The package ships no hook and no scriptlet for this — Arch's
`refind` doesn't either; its PKGBUILD says the install target calls `refind-install`, "therefore
install manually". So refresh it from the live ISO before re-shooting the menu:

```bash
make -C docker test-boot
ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost \
  'mount /dev/vda2 /mnt; mount /dev/vda1 /mnt/efi;
   cp /mnt/usr/share/refind/refind_x64.efi /mnt/efi/EFI/refind/refind_x64.efi; umount -R /mnt; poweroff'
./docker/scripts/menu-shots.sh        # and demo-snapshots EXTRA=40 to overflow the submenu
```

The same gap is a user-visible one, not just a test one: an installed system that updates
`refind` from `[aelum]` keeps booting the old binary until something rewrites the ESP copy.

## Upgrading rEFInd

1. Bump `pkgver` in `packaging/PKGBUILD`; keep `pkgrel` above extra's
   (`pacman -Si refind` against a synced DB) for hand-enabled/older configs —
   but the deciding factor is that pacman.conf lists `[aelum]` before
   `[extra]` (installer `configure/pacman_repo.go`, ISO
   `docker/scripts/build-iso.sh`). Rename the two patch files to the new
   version.
2. `./scripts/prepare-work.sh` — it downloads the new tarball (cached under
   `work/`) and applies the old patches; expect conflicts in the compat patch
   (it is the version-sensitive one; the scroll patch usually survives).
3. Re-resolve the conflicts in the trees, then the full loop above.
4. Re-verify the ABI section of NOTES.md against the new gnu-efi if the image
   moved: the four EFIAPI-marked symbols are the invariant to check
   (`nm -u` on the objects must show zero references to
   SetMem/CopyMem_1/CompareGuid_1/ReallocatePool_1).

## Upstream

- rEFInd: https://www.rodsbooks.com/refind/ — source at SourceForge
  (`refind/0.14.2/refind-src-0.14.2.tar.gz`).
- The gnu-efi ABI analysis in NOTES.md is upstream-relevant (plain 0.14.2
  miscompiles against gnu-efi 4.0.4; Arch fixed their own build before we
  measured theirs, so this is a build-correctness note, not a live bug in
  extra). If a future rEFInd carries the call-site fixes, the compat patch
  shrinks to whatever build fixes remain — drop what upstream covers and
  re-run the loop.

## Publishing notes

- `repo/publish-repo.sh` is the only publisher (it signs the package + DB and
  uploads to R2; see `repo/AGENTS.md`). Packages are immutable in the bucket;
  a rebuild needs a `pkgrel` bump. The PKGBUILD is a split package — publish
  BOTH halves (`refind-…` and `refind-docs-…`), or the docs subpackage keeps
  resolving from extra while the binary comes from us.
- What selects our refind is the `[aelum]`-before-`[extra]` order the
  installer writes (see the measured ordering fact in the workspace
  `AGENTS.md`); the higher `pkgrel` is only belt-and-braces for hand-edited
  configs.
- After publishing, prove the channel with real pacman in any container:
  `pacman -Sl aelum | grep refind` against `cdn.aelum.dev/repo/x86_64`.
- Installed systems already trust the key (installer `configure/pacman_repo.go`).
