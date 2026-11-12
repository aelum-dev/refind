# rEFInd headless proof harness — measured facts

Everything here was measured on this machine (QEMU 10.x + Arch OVMF, `-machine q35`),
Nov 2026. Scripts: `tests/test-scroll.sh` (proof), `tests/probe-keys2.sh` (key
map), `tests/bisect-parse.sh` (config parsing).

## QEMU display / capture

- `-display none -vga std`: `screendump` returns a STALE surface — partial GOP blits
  never reach it; only mode-switch frames do. Symptom: screenshots show only the
  rEFInd banner (the last `SwitchToGraphicsAndClear` frame) while the log proves the
  guest drew a full menu.
- `-display none -vga none -device ramfb`: live capture works. OVMF picks ramfb via
  fw_cfg automatically; rEFInd uses its GOP and every blit is mirrored to QEMU.

## QEMU sendkey → EFI ScanCode (via OVMF PS/2 translation)

Keys arrive UN-shifted: OVMF, EDK2, and gnu-efi all use the same table
(UP=1, DOWN=2, RIGHT=3, LEFT=4, HOME=5, END=6, INSERT=7, DELETE=8, PGUP=9,
PGDN=10, F1=0x0B, F2=0x0C). An earlier reading of "shifted by one" was an
artifact of comparing against the UEFI PI spec's zero-based numbering
(UP=0) — the log lines and rEFInd's own SCAN_* constants agree.

Measured (probe-keys2.sh, log_level 5, rEFInd's own "Processing keystroke"
lines): sendkey right→3, f2→0x0C, end→6, home→5, down→2, left→4.

PageUp/PageDown: QEMU sendkey pageup/pagedown produce no keystroke at all.
Practical mapping for driving rEFInd: `right`/`left` move between icons,
`down`/`up` move between rows, `f2` opens a submenu (Insert/Tab/+ too),
`end`/`home` jump to last/first item, Esc returns.

## gnu-efi 4.0.4 ABI mismatch (the real "40 submenuentries vanish" bug)

rEFInd 0.14.2 compiled against Arch's gnu-efi 4.0.4 with default flags has a
silent calling-convention mismatch:

- Arch's libefi.a is built with `GNU_EFI_USE_MS_ABI=1` → every `EFIAPI`-marked
  library function uses the Microsoft x64 ABI (rcx/rdx/r8).
- rEFInd's build defines neither `GNU_EFI_USE_MS_ABI` nor `EFIAPI` → its headers
  expand `EFIAPI` to nothing → direct calls to library functions pass SysV
  registers (rdi/rsi/rdx).
- Firmware protocol calls are safe (they go through gnu-efi's `efi_callN`
  register-shuffle thunks when ms_abi is off); only DIRECT library calls break:
  `SetMem`, `CopyMem_1`, `CompareGuid_1`, `ReallocatePool_1` (verified by
  disassembly of Arch's libefi.a vs. rEFInd's .o call sites).

Visible symptom (measured): `AddListElement` reallocates any menu list when it
grows past 16 entries via `ReallocatePool` (lib.c:540). The call returns garbage
(NULL-ish), the parent `menuentry` of a >16-entry `submenuentry` stanza is
silently dropped from the main menu. Bisected: 14 submenuentry blocks fine, 15+
broken. rEFInd 0.14.2's own log confirms: "Reallocating memory in
AddListElement(); *ElementCount is 16" immediately followed by
AddStanzaEntries returning Entry=NULL.

Why no flag can fix it (all measured against /usr/include/efi/legacy/efilib.h
+ disassembly of Arch's libefi.a):
- `-DGNU_EFI_USE_MS_ABI=1` makes rEFInd itself uncompilable: with
  HAVE_USE_MS_ABI, `uefi_call_wrapper` becomes a direct call, and
  refit_call_wrapper.h's `(UINT64)(argN)` casts then break every firmware call;
  GenericBdsLib.h's `DevicePathToStr` also conflicts with the EFIAPI-marked
  efilib.h declaration.
- The compat knobs don't help: `CopyMem→CopyMemC` — CopyMemC is EFIAPI too;
  `ReallocatePool→ReallocatePool_0` and `CompareGuid→CompareGuid_0` are
  EFI_INTERNAL inlines that still call the EFIAPI `_1` versions.
- Shadowing by name is impossible: misc.o (defines SetMem/CopyMem_1/
  ReallocatePool_1) and guid.o are pulled in anyway for
  AllocatePool/FreePool/ZeroMem/CompareMem.

Fix actually applied (call sites, mirroring rEFInd's own MyCopyMem idiom):
- refind/lib.h: new `MySetMem` static-inline (byte fill;
  -fno-tree-loop-distribute-patterns keeps it from becoming a memset call).
- 5 `SetMem` sites → MySetMem (config.c, launch_legacy.c, lib.c,
  EfiLib/legacy.c, lodepng_xtra.c — the lodepng one also had swapped
  value/size args upstream: `SetMem(s, c, n)` for memset(s, c, n)).
- 11 raw `CopyMem` sites → MyCopyMem (EfiLib/legacy.c, EfiLib/BdsTianoCore.c).
- 6 `CompareGuid(a,b) == 0` sites → rEFInd's own `GuidsAreEqual(a,b)`
  (refind/driver_support.c; same semantics — gnu-efi's CompareGuid is
  memcmp-style, 0 = equal).
- 2 `#define EfiReallocatePool ReallocatePool` → local static helpers with
  gnu-efi's exact semantics (allocate, copy min(old,new), free old even on
  failure) in refind/lib.c + EfiLib/legacy.c.
- filesystems/fsw_efi.h: upstream's `#define CompareGuid(a,b) CompareGuid(a,b)==0`
  self-referenced gnu-efi 3.x's FUNCTION; against 4.0's macro it breaks the
  build outright. → `#undef` + `(CompareMem(a,b,16)==0)` (CompareMem is not
  EFIAPI; same semantics).
- gptsync/gptsync.c: 1 `SetMem` → plain zero loop (gptsync doesn't include
  refind/lib.h).
- Keep `-DGNU_EFI_USE_REALLOCATEPOOL_ABI=0` (defensive; no call remains).
After the fix, `nm` shows zero U references to SetMem/CopyMem_1/CompareGuid_1/
ReallocatePool_1, and bisect-parse.sh 40 now logs "Adding menu entry for
'Boot Test sub'" (was: dropped).

Measured Nov 2026, second half: extra's refind 0.14.2-3 (Build Date Apr 2026,
against the same gnu-efi 4.0.4 — in extra since Dec 2025) parses 40
submenuentries fine (bisect-parse.sh 40 work/refind-arch.efi: "Adding menu
entry for 'Boot Test sub'"). So Arch fixed their build by April and the bug
does NOT ship in today's extra/refind. What remains true: upstream rEFInd
0.14.2 with no patches miscompiles against gnu-efi 4.0.4 (measured here), so
any rebuild of plain upstream — ours included — needs the call-site fixes;
the compat patch is our independent, verified path to that build.

## rEFInd 0.14.2 fixture quirks

- `resolution 1024 768` — two tokens. `1024x768` parses as "1024 x 0" and
  "Error setting graphics mode".
- rEFInd forces `textonly = TRUE` when no `icons` directory sits next to
  `refind.conf` (config.c: "Icons directory doesn't exist"). Copy `icons/` into the
  ESP or the graphics menu never runs.
- `submenuentry` blocks are multi-line only: `AddSubmenu` consumes lines until `}`
  and makes ONE entry per block — one-line `submenuentry "x" { options "y" }`
  stanzas all merge into a single entry.
- `log_level` is an integer (5 = everything); the log is flushed per line
  (`WriteToLog` calls `Flush`), so killing QEMU keeps the log. `refind.log` lands
  next to `refind.conf` on the ESP.
- Main menu: built-in tools (shell/about/shutdown/reboot/firmware) are real entries
  in the same scrolling row as manual `menuentry` stanzas — arrow keys walk into
  them, and F2 on them is ignored ("no sub-screen").

## mtools

- `mformat -i <64MB raw image> -F32` hangs pathologically (99% CPU, minutes).
  Use `mkfs.vfat -F 32` on the raw image, then `mmd`/`mcopy` to populate.

## Container

- Warm builder container `refind-build` (archlinux:latest, `/work` = this dir):
  has base-devel, gnu-efi 4.0.4, mtools, dosfstools. Files it writes are root-owned —
  `chown -R 1000:1000 /work/...` from inside before QEMU on the host reads them.
