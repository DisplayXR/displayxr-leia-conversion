# DisplayXR Leia conversion provider

2D→3D conversion for the [DisplayXR runtime](https://github.com/DisplayXR/displayxr-runtime)
through Leia's **NeurD** module: depth from an image or a video, and a stereo pair from one image
whose views follow the tracked viewer. It is a DisplayXR **conversion provider**
(runtime ADR-053), registered as `leia-conversion` at probe order 50 (the vendor band).

| | Windows | desktop Linux |
|---|---|---|
| Binary | `DisplayXR-LeiaConversion.dll` | `DisplayXR-LeiaConversion.so` |
| Transport | D3D11 (shared NT handles, the provider's own device) | host memory (NeurD's CPU entry point) |
| Package | `DisplayXRLeiaConversionSetup-<ver>.exe` | `displayxr-leia-conversion_<ver>_<arch>.deb` |
| Capabilities | `DEPTH_MONO`, `DEPTH_VIDEO`, `VIEWS_MONO` (2 views) | `VIEWS_MONO` (2 views) |

> **Status: no release yet.** This repository was split out of the Leia SR display plug-in
> (`displayxr-leia-plugin`), which carried the provider until v2.23.0. See
> [docs/installer.md](docs/installer.md) for the migration order between the two packages.

## NeurD is a prerequisite you install separately

The NeurD **runtime** is a Leia product with its own installer, its own licence check and its own
models. This package does not contain, download or install any of it.

- With NeurD installed, the provider finds it (Windows: `PATH`, `NEURD_PATH`,
  `HKLM\SOFTWARE\LeiaInc\NeurD`; Linux: `/opt/immersity/neurd-runtime`, `NEURD_PATH`,
  `LD_LIBRARY_PATH`; or exactly where the `NeurDPath` setting says) and serves conversion once the
  runtime warms it. NeurD's first activation checks its licence over the network.
- Without NeurD, or with one older than the floor (0.4.6), the provider still loads and reports
  why (`ABSENT`, `FAILED(VERSION)`), and the runtime uses its next conversion provider.

```
displayxr-cli conv list                      # is leia-conversion registered, and its state
displayxr-cli conv status
displayxr-cli conv options leia-conversion   # its settings: key, type, default, value, source
```

## Building

The provider compiles against two things it does not ship: the runtime's conversion ABI header
(fetched at the tag pinned in `CMakeLists.txt`, or a local checkout via `DXR_RUNTIME_SOURCE_DIR`)
and NeurD's **public headers** (Leia-private; fetched from `LeiaInc/media_sdk` at the refs in
`scripts/neurd-pins.env` into a gitignored `NeurD-SDK-<ref>/`; needs `gh` access to that repo).

```bash
./scripts/build-linux.sh           # Linux: build + every check + ctest
./scripts/build-linux.sh --pure    # any OS: only the pure layers and their tests (no runtime, no headers)
./scripts/package_deb.sh           # Linux: the .deb (build on Ubuntu 22.04)
```
```bat
scripts\build-windows.bat all      REM Windows: DLL + tests + NSIS installer
```

No test needs the NeurD runtime: Windows tests run against fake `NeurD.dll` modules, Linux tests
against a fake `libNeurD.so`.

## Documents

- [docs/conversion-provider.md](docs/conversion-provider.md) — capabilities, readiness and the
  version gate, the licence class, settings, registration, the Linux arm, testing.
- [docs/installer.md](docs/installer.md) — the installers, the handover from the Leia SR plug-in,
  the `.deb`'s `Replaces` / `Breaks`, releasing.
- [docs/neurd-module.md](docs/neurd-module.md) — the Windows NeurD module's internals.
- [catalog/leia-conversion.json](catalog/leia-conversion.json) — a **draft** of this component's entry in the runtime's component catalog.
- Contract (runtime repo): `src/xrt/include/xrt/xrt_conversion_plugin.h`,
  `docs/specs/runtime/conversion-provider-discovery.md`.

## License

[Apache-2.0](LICENSE) for everything in this repository. NeurD is licensed separately by Leia.
