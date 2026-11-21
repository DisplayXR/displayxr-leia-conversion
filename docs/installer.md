# Installing, upgrading and releasing

Two packages, one per OS, each carrying only this repo's provider binary:

| | Windows | Linux |
|---|---|---|
| Artifact | `DisplayXRLeiaConversionSetup-<ver>.exe` (NSIS) | `displayxr-leia-conversion_<ver>_<arch>.deb` |
| Installs | `%ProgramFiles%\DisplayXR\Plugins\LeiaConversion\DisplayXR-LeiaConversion.dll`, `dxr-rm-close.exe`, `Uninstall.exe` | `/usr/lib/displayxr/plugins/DisplayXR-LeiaConversion.so`, `050-leia-conversion-conversion-provider.json` |
| Registers | `HKLM\Software\DisplayXR\ConversionProviders\leia-conversion` (64-bit view) | the manifest, in the runtime's built-in discovery root |
| Tracks itself at | `HKLM\Software\DisplayXR\Plugins\LeiaConversion` (`InstallPath`, `Version`), ARP key `DisplayXRLeiaConversion` | dpkg |
| Built by | `installer/DisplayXRLeiaConversionInstaller.nsi` | `scripts/package_deb.sh` |

Neither has a prerequisite, and neither installs NeurD:

- **No DisplayXR runtime yet**: the files and the registration are written anyway; the runtime
  reads them once it is installed. (The `.deb` does `Depends` on `displayxr-runtime`, as every
  DisplayXR plug-in package does.) A runtime older than 2.41.0 has no conversion providers and
  ignores the registration; the Windows installer prints a note and continues.
- **No NeurD runtime yet**: the provider loads without it and reports `ABSENT` until NeurD's own
  installer has run. The Windows installer prints which case it found
  (`HKLM\SOFTWARE\LeiaInc\NeurD`); it never fails on it, because the provider also finds a NeurD
  on `PATH` / `NEURD_PATH`.

## Windows: close the host, never the service

The DLL is mapped only by the runtime's `displayxr-conversion-host.exe`. The installer follows
the discovery spec's §3.8 sequence:

1. Create **and own** `Global\DisplayXR-ConvMaintenance-leia-conversion`, held to the end (wait up
   to 120 s if another installer — NeurD's own, or an older Leia SR plug-in installer — holds it).
   While it is held the service spawns no conversion host for `leia-conversion`.
2. A Restart Manager session (`dxr-rm-close.exe session`) over the provider's files **only**. It
   lists the conversion host, which exits 20 ("closed for update"); the provider's tasks report
   `WARMING(updating)` and every app session and stream stays alive. No `taskkill` fallback:
   nothing in this installer may stop the service. A file still held aborts the install
   (`AllowSkipFiles off`) with a non-zero exit code, and the row is not rewritten.
3. Copy the files; write the allowlist row (unsigned builds); write the `ConversionProviders` row
   with `Version` **last**.
4. End the session restarting **nothing** (the host never registers for restart; the service
   respawns it on demand), then release the mutex.

Uninstall runs the same sequence. An aborted install or uninstall releases the mutex and ends the
session.

`/S` is the silent install. `/NOSTART` (which a bundle passes to every child) is accepted and has
nothing to do here: this installer never starts anything. Exit code 3 = not 64-bit Windows.

**The NeurD installer** (a separate, vendor installer) should take the same mutex and run its
Restart Manager session over the NeurD files; with the provider satellite-hosted that session
lists the conversion host, not the service.

## Handover from the Leia SR plug-in

Until it dropped the provider, the Leia SR plug-in package carried this same binary:

| | Leia SR plug-in, before the split | this package |
|---|---|---|
| Windows DLL | `%ProgramFiles%\DisplayXR\Plugins\LeiaSR\DisplayXR-LeiaConversion.dll` | `…\Plugins\LeiaConversion\DisplayXR-LeiaConversion.dll` |
| Row `Binary`, `UninstallString`, `Version` | the plug-in's DLL path, **its** uninstaller, **its** version | this package's |
| Row removed by | the plug-in's uninstaller, unconditionally | this uninstaller, only while `Binary` is this package's DLL |
| Linux files | owned by `displayxr-leia-sr` | owned by `displayxr-leia-conversion` |

The registry row has one owner at a time: whoever wrote it last. What each side does:

- **This installer, over a row written by the plug-in.** It reads the row's `Binary` first. A
  `DisplayXR-LeiaConversion.dll` outside this package's directory is the plug-in's copy: the
  Restart Manager session covers that file too (the running host maps it, not ours), every row
  value is rewritten to this package, and the superseded copy is deleted from the plug-in's
  directory. A `Settings` subkey survives.
- **This uninstaller.** It deletes the row only when `Binary` still points at this package's DLL.
  A row somebody else took over is left alone.
- **A Leia SR plug-in installer from after the split.** It no longer writes the row. On an upgrade
  over a plug-in that had the provider it removes that leftover copy, and deletes the row **only
  if the row still points at that copy** — never a row that points at this package.
  Having removed a working registration, it then tries to bring this package in through the
  runtime's `dxr-get` (`dxr-get install leia_conversion`, the signed component catalog); until
  the catalog carries that component it prints where to get the installer instead.
- **A Leia SR plug-in installer or uninstaller from BEFORE the split** knows nothing about this
  package. Installing it rewrites the row to its own copy (this package is then installed but not
  the registered provider); uninstalling it deletes the row. Either way, re-run this installer
  to take the row back. This is why the supported order is the one below.

### Migration order

1. Release this package (Windows `.exe` + Linux `.deb`).
2. Teach the runtime side about it: a `leia_conversion` field in `versions.json`, the
   orchestrator's component rows (`setup-displayxr.{sh,bat}`), the bundle if it should chain it.
3. Only then merge and release the Leia SR plug-in without the provider, with
   `LEIA_SR_SPLIT_VERSION` here equal to that plug-in release.
4. From then on install the two in either order; a box that upgrades the plug-in first has no
   Leia conversion (the runtime uses its next provider) until this package is installed.

Between steps 1 and 3 do not cut a Leia SR plug-in release from its old line onto a box that
already has this package: that installer would take the row back (above).

## Linux: the `.deb`

`scripts/package_deb.sh` builds on the oldest supported Ubuntu (22.04; `DXR_DEB_MAX_GLIBC=2.35`
makes a newer build host an error), derives versioned `Depends` with `dpkg-shlibdeps`, refuses a
`DT_NEEDED` outside its cross-release list, a NeurD link dependency, a second export, and a
build without look-around (`--allow-no-look-around` overrides the last).

The two installed files are the ones `displayxr-leia-sr` shipped before the split, at the same
paths, so the package declares (Debian policy 7.6.1):

```
Replaces: displayxr-leia-sr (<< <split>~)
Breaks:   displayxr-leia-sr (<< <split>~)
```

`<split>` is `LEIA_SR_SPLIT_VERSION` in `scripts/package_deb.sh`: the first `displayxr-leia-sr`
release **without** the provider. It is a guess (`2.24.0`) until that release is cut — set it
then, before this package's release that follows. Consequences:

- On a box with an older `displayxr-leia-sr`, upgrade both in one transaction:
  `sudo apt install ./displayxr-leia-conversion_*.deb ./displayxr-leia-sr_*.deb`. This package
  alone is refused there; that is `Breaks` doing its job (an old `displayxr-leia-sr` left
  installed could be removed later and take the files with it).
- An old `displayxr-leia-sr` cannot be installed next to this package.
- A `displayxr-leia-sr` built from a commit after the split but before its release tag has a
  version below `<split>` (`2.23.0+12.gabc…`) and is refused too. Dev builds only.

`scripts/test_deb_handover.sh` runs these cases against stand-in packages in a throwaway
container; `scripts/verify_deb_install_linux.sh` is the clean-release install check.

No maintainer scripts. POSIX has no Restart Manager and no maintenance mutex: dpkg replaces the
files by rename under a running host, which keeps the old mapping until its next restart.

## Releasing

Tag `vX.Y.Z` on `main`. `.github/workflows/release.yml` reuses the two build workflows with
`release: true` (a missing NeurD header fetch then fails instead of skipping), attaches the
installer and the `.deb` to the GitHub Release, and dispatches `versions-bump` to
`displayxr-runtime` with `field: "leia_conversion"`.

- CI builds are unsigned. A signed Windows release comes from the signing provider (the runtime's
  `docs/specs/runtime/release-signing.md`): `SIGN_CMD` signs the DLL, the installer and (two-pass)
  the uninstaller. An unsigned build still loads: the installer writes the DLL's SHA-256 under
  `HKLM\Software\DisplayXR\Trust\Allowlist` (ADR-054 N4b) and the uninstaller removes that row.
- The version comes from the tag: the Windows job patches `project(... VERSION)` from the latest
  `vX.Y.Z` tag (DLL `VERSIONINFO`, installer name, row `Version`); the `.deb` takes `git describe`.
- **Runtime-side prerequisites, not in this repo**: `versions.json` needs the `leia_conversion`
  field, `versions-bump.yml` accepts any `vX.Y.Z` field as it is, and the orchestrator needs the
  component rows (repo, asset pattern, marker `HKLM\Software\DisplayXR\ConversionProviders\leia-conversion`).
  For `dxr-get` (and so for the Leia SR plug-in installer's chain) the catalog generator
  (`scripts/gen_catalog.py`) must also emit a `leia_conversion` component with a signed Windows
  asset: `catalog/leia-conversion.json` sketches it.
  Until the field exists the dispatched `versions-bump` run fails ("versions.json has no field
  'leia_conversion'"); the release itself is unaffected.
- Never attach anything of NeurD's to a release: no headers, no library, no models.
