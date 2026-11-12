# refind — Aelum's patched rEFInd

Aelum ships its own `refind` package: upstream [rEFInd](https://www.rodsbooks.com/refind/)
plus two patches, published to the `[aelum]` repository. Aelum systems get it
through the repository the installer already enables, listed ahead of `extra`
so the patched package is the one pacman resolves.

## What the patches do

**Scrollable boot submenus.** Aelum's boot menu puts every system snapshot in
one submenu. Upstream rEFInd's graphical submenus don't scroll — a long
history simply ran off the bottom of the screen and the selection could leave
it entirely. Our patch makes the submenu a scrolling window with `^`/`v`
overflow markers, driven by rEFInd's own scroll machinery, so the whole
snapshot history is reachable with the arrow keys, Home and End.

**Correctness on modern Arch.** Arch's `gnu-efi` 4.x builds its library with
the Microsoft x64 calling convention; unpatched rEFInd 0.14.2 calls some of
those functions with the wrong convention. The visible symptom: a menu holding
more than 16 entries silently loses that entry. (Arch fixed their own package
for this in April; our package carries its own verified fix, so the build
here is correct regardless.) This package also builds cleanly against current
binutils.

## Building

Needs an Arch environment (the `refind-build` container — see `AGENTS.md`):

```bash
./scripts/build-pkg.sh            # → dist/refind-<ver>-<rel>-x86_64.pkg.tar.zst
```

To see the feature without a package: `tests/build-bins.sh` then
`tests/test-scroll.sh` boots both the unpatched and patched binaries under
OVMF and leave screenshots in `work/shots/`.

## Publishing

```bash
../repo/publish-repo.sh refind/dist/<the .pkg.tar.zst>
```

`NOTES.md` records the measured facts behind every decision here; `AGENTS.md`
is the working guide for future changes and upstream upgrades.

## License

The patches and scripts in this repository: GPL-3.0 (see `LICENSE`).
The upstream rEFInd sources keep their own license, shipped in the package at
`/usr/share/licenses/refind/`.
