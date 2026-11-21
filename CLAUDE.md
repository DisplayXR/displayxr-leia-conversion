# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## What this repo is

The **Leia conversion provider** for the DisplayXR runtime (ADR-053): `DisplayXR-LeiaConversion.dll`
(Windows, D3D11 transport) and `DisplayXR-LeiaConversion.so` (desktop Linux, CPU transport), id
`leia-conversion`, ProbeOrder 50, over Leia's NeurD module. Split out of `displayxr-leia-plugin`,
whose display processor used to carry the same module behind its lift slots; conversion now lives
only here.

**NeurD is an external prerequisite.** Its runtime (library, licence check, models) has its own
installer. This repo compiles against NeurD's public headers and finds an installed NeurD at run
time. It never ships, downloads, installs or modifies NeurD, and packaging or hosting NeurD is not
this repo's work.

## Hard rules

- **Never commit or re-host NeurD material.** The headers are Leia-private: fetched at build time
  from `LeiaInc/media_sdk` into the gitignored `NeurD-SDK-<ref>/`. Not in a commit, not in a CI
  artifact, not in a release, not quoted in docs. CI reads them with the `LEIALOFT_GITHUB_TOKEN`
  secret; without it (fork PRs) only the `Pure` job runs in full.
- **No NeurD link dependency.** The provider `LoadLibrary`s / `dlopen`s NeurD by path. CI and
  `package_deb.sh` refuse a static import / `DT_NEEDED`.
- **Exactly one export**, `xrtConversionPluginNegotiate`. No SR SDK, no display plug-in import.
- **Settings only through `host->get_setting`.** Never `getenv`, never an ad-hoc registry key: in
  the conversion host the environment is the service's. A new key goes in three places together:
  the module's `read_knobs`, `g_settings` in `src/leia_conv_plugin.cpp` (`describe_settings`), and
  the table in `docs/conversion-provider.md`. The Windows test pins the count (16), the Linux
  ctest too (15).
- **Read and write boundary structs only within their `struct_size`.** The `[C]` slots answer from
  a snapshot under a short mutex, never across a module or D3D11 call.
- **Don't `throw` across the ABI.** The runtime is C.
- **There is no `.clang-format` here.** Do not run `git clang-format`: hand-match the tab style
  and do not rewrap neighbouring lines.
- **Never run the installer or its uninstaller on a shared dev box**, and never `apt install` the
  `.deb` outside a throwaway container.

## Layout

| Path | What |
|---|---|
| `src/leia_conv_plugin.cpp` | negotiate, the v1 iface, `describe_settings` (both OSes; `LEIA_CONV_CPU_TRANSPORT` selects the Linux arm) |
| `src/leia_lift_neurd.{h,cpp}` | Windows NeurD module: discovery, load, licence, streams, the cross-device bridge, convert |
| `src/leia_conv_d3d11.{h,cpp}` | Windows: the provider's device, image import, sync, output blit |
| `src/leia_conv_neurd_posix.cpp`, `leia_conv_neurd_cpu.h`, `leia_conv_cpu.{h,c}` | Linux NeurD module + CPU transport |
| `src/leia_lift_viewpoint.{h,c}`, `leia_lift_depth.{h,c}`, `leia_conv_policy.{h,c}` | pure, host-tested everywhere |
| `src/tests/` | pure tests; `test_conv_leia_provider.cpp` + fake `NeurD.dll` modules (Windows); `conv_leia_harness.c` + `fake_neurd.c` (Linux) |
| `installer/` | NSIS installer, allowlist generator, the Restart Manager helper |
| `scripts/neurd-pins.env` | the NeurD header refs: the ONE place they are written |
| `scripts/` | build, header fetch, `.deb` packaging, install and handover checks |
| `catalog/leia-conversion.json` | DRAFT of this component's entry in the runtime's component catalog (schema 1; nothing reads the file, the runtime's generator derives real entries) |

## Pins: one source each

- Runtime header ref: `set(DXR_RUNTIME_GIT_TAG "vX.Y.Z" …)` in `CMakeLists.txt`. The workflows
  read it from there. It is the header the provider compiles against, not a floor: move it when
  the code needs a newer macro, never to chase a release.
- NeurD header refs: `scripts/neurd-pins.env` (Windows, Linux, Linux fallback). Workflows and both
  build scripts read that file. Windows and Linux differ on purpose (the Linux arm needs
  `NeurD_convert_stream_cpu_ex` and `NeurD_get_table_size`).
- `DXR_CONV_MIN_RUNTIME_VERSION` (2.41.0): first runtime with the conversion ABI; the `.deb`'s
  `Depends` and the installer's notice.
- `LEIA_SR_SPLIT_VERSION` in `scripts/package_deb.sh`: the first `displayxr-leia-sr` release
  without the provider. A guess until that release exists.

## Build and test

```bash
./scripts/build-linux.sh --pure                 # anywhere, seconds
./scripts/build-linux.sh                        # Linux: provider + checks + ctest (build/src)
./scripts/package_deb.sh                        # Linux .deb
./scripts/test_deb_handover.sh dist/*.deb       # root, throwaway container only
```
```bat
scripts\build-windows.bat all
```

Run only this repo's tests: `ctest --test-dir build/src`. With a fetched runtime and CMake < 3.28
the runtime's own tests land in the same tree; they are not ours and some fail outside the
runtime's CI.

A Mac can run the pure tests, `makensis` over the `.nsi` with stub payload files (it compiles the
script; it cannot run the result), and the Linux lane in a container. It cannot build or run the
Windows provider.

## Installer and handover

`docs/installer.md` is the contract: maintenance mutex, a Restart Manager session over the
provider's files only, `Version` written last, nothing started. The row
`ConversionProviders\leia-conversion` was owned by the Leia SR plug-in installer before the
split; this installer takes it over and its uninstaller deletes it only while it still points
here. Change either side only with the other in view (`displayxr-leia-plugin`'s installer and
`docs/conversion-moved.md`).

## Releasing

Tag `vX.Y.Z` → `release.yml` (reuses both build workflows with `release: true`) → installer +
`.deb` on the GitHub Release → `versions-bump` dispatch (`field: leia_conversion`). The runtime
side needs that field in `versions.json` first.

## Follow-ups

- **Strip the display-processor hosting from `leia_lift_neurd.cpp`** (the activation thread, the
  `DXR_LEIA_LIFT*` / `HKLM\SOFTWARE\DisplayXR\Leia\Lift` knob reader). Unreachable from the
  provider. Needs a Windows box to build and run `test_conv_leia_provider`.
- `docs/neurd-module.md` still reads as the display-processor write-up under a banner; rewrite it
  once the code above is gone.
- Runtime side, before the Leia SR plug-in installer's chain can fetch this package: a `leia_conversion` field in `versions.json` and a `leia_conversion` component in `scripts/gen_catalog.py` (shape: `catalog/leia-conversion.json`).

## License

Apache-2.0, `Copyright 2026, Leia Inc.` headers on new files.
