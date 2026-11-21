# Leia conversion provider (`DisplayXR-LeiaConversion.dll`)

The Leia **conversion provider** serves the runtime's 2D→3D conversion tasks — depth from an
image or a video, and a stereo pair from one image — through Leia's NeurD module. It is a
DisplayXR conversion provider (runtime [ADR-053](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/adr/ADR-053-conversion-providers.md)),
shipped from this repo as its own package. It is the only place Leia's 2D→3D conversion lives:
the Leia SR display processor no longer carries a NeurD module or lift slots, and the provider
still declares `Supersedes = dp-lift` so the runtime's legacy adapter stays hidden on a box whose
Leia SR plug-in predates that change.

**NeurD itself is an external prerequisite.** The NeurD runtime (a Leia media_sdk product: its
library, its licence check, its models) has its own installer. This repo builds against NeurD's
public headers only, never ships or downloads NeurD, and the provider finds an installed NeurD at
run time ([Readiness](#readiness-and-the-version-gate), [Desktop Linux](#desktop-linux-displayxr-leiaconversionso-cpu-transport)).
Without it the provider loads, reports `ABSENT`, and the runtime uses its next provider.

Contract (runtime repo): header `src/xrt/include/xrt/xrt_conversion_plugin.h` (ABI 1, runtime
≥ v2.41.0), [discovery spec](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/specs/runtime/conversion-provider-discovery.md)
§2 (C ABI, threading, hosting rules), §3 (registration) and §3.8 (installer contract), and the
vendor onboarding guide §9.

## Shape: its own binary, its own package

| | |
|---|---|
| Binary | `DisplayXR-LeiaConversion.dll` / `.so` |
| Export | `xrtConversionPluginNegotiate` (the only one; CI asserts it) |
| Registration | Windows: `HKLM\Software\DisplayXR\ConversionProviders\leia-conversion`; Linux: `050-leia-conversion-conversion-provider.json` |
| Loaded by | the runtime's conversion host (`displayxr-conversion-host`), only |
| Needs LeiaSR | **never**: no SR SDK import, no weaver, no SR session, no link to any display processor |
| Needs NeurD | at run time only, found on the box; never at build or link time |

It is hosted in the satellite, so the service never maps the provider or NeurD (discovery spec
§3.7): updating either costs no app session. Source: `src/`.

| File | What |
|---|---|
| `leia_conv_plugin.cpp` | the negotiate entry point, the v1 iface, and `describe_settings` |
| `leia_conv_d3d11.{h,cpp}` | Windows: the provider's own D3D11 device and its image import (NT handle / CPU), sync, and the output blit |
| `leia_lift_neurd.{h,cpp}` | Windows: the NeurD module (discovery, load, licence, streams, the device bridge, convert). See [NeurD module](neurd-module.md) |
| `leia_conv_neurd_posix.cpp`, `leia_conv_neurd_cpu.h` | Linux: the NeurD module over NeurD's CPU entry point |
| `leia_conv_cpu.{h,c}` | Linux: the pixel moves of the CPU transport (pure) |
| `leia_lift_viewpoint.{h,c}`, `leia_lift_depth.{h,c}` | both: viewpoint mapping, depth metadata and the off-axis camera (pure) |
| `leia_conv_policy.{h,c}` | pure decisions: the readiness gate, the licence class, output extents, convergence units |
| `tests/` | the pure tests (every lane), the provider test against fake modules (Windows), the harness and the fake `libNeurD.so` (Linux) |

## Capabilities

| `cap_id` | Task | Lane | Outputs | Notes |
|---|---|---|---|---|
| 1 | `DEPTH_MONO` | stream | depth | per-frame normalised disparity |
| 2 | `DEPTH_VIDEO` | stream | depth | `TEMPORAL`; `FRAME_RESET` drops the module stream (fresh temporal state) |
| 3 | `VIEWS_MONO` | stream | views (+ depth) | exactly 2 views (`min_views = max_views = 2`), `EXPLICIT_VIEWPOINTS`, `OFFAXIS_CAMERA` when the module has the metric off-axis camera; aux depth of the **same inference** iff the module reports it |

- **Why 2 views.** NeurD's public output types fix the tile grid ([N-view](neurd-module.md#n-view)). A
  stream for more views is served by the runtime's composed pipeline (a depth capability + its
  reference view synthesis), never by this capability.
- **Depth.** A depth target is `R32_FLOAT`. `DEPTH_*` write the module's per-frame min-max
  normalised disparity as `AFFINE_INVERSE` (decoded value = disparity, larger = nearer).
  `VIEWS_MONO`'s aux depth keeps the module's own units: `METRIC` (metres) with
  `VideoModel=metric`, else `AFFINE_INVERSE` — mapped field by field exactly as the runtime's
  `dp-lift` adapter mapped a display processor's `lift_get_depth`, including the relief mapping
  (ADR-046 A1, `relief_*`) of an off-axis convert and the assumed pinhole (rescaled to the target).
- **Per-request geometry in, relief out.** Display metres, resolved viewpoints, the axis mode,
  clamp and nominal distance arrive on every call in `xrt_conv_params`; the provider reads no
  tracker and no panel geometry (it has no SR session). The runtime's convergence comes as a
  plane in the decoded units of the stream's last depth; the provider maps it back to the
  module's terms (relative: `1 − value`; metric: metres, converted with the stream's own model
  scale) and otherwise lets the module run its own auto-convergence.
- **Extents** (`stream_get_output_desc`, pure): views = the input size per view (scaled down to fit
  16384 texels in a row); depth = the input size with its long edge capped at 1280 (aux depth:
  1024). The module's output is resampled into the runtime-allocated target.
- **Transport.** Every image is runtime-allocated and imported, never exported: an NT handle opened
  on the provider's own D3D11 device (created on the adapter `get_adapter_hint` names, else next to
  NeurD's device), or CPU memory. Sync: `NONE`, `KEYED_MUTEX`, `FENCE_NT`. Imports are cached by
  `import_key` and dropped when unseen for 64 calls or at `stream_destroy`.
- **No job lane** in this version (no capability declares it; `job_execute` refuses).

## Readiness and the version gate

The three capabilities share one module, so they share one state. Until the first `warm`, the
state comes from **discovery only** (no load): the module's file, found in NeurD's own order
(PATH → `NEURD_PATH` → `HKLM\SOFTWARE\LeiaInc\NeurD`, or only the `NeurDPath` setting when set),
and its version resource.

| Situation | State | `failure_reason` | `retryable` |
|---|---|---|---|
| no module found | `ABSENT` | `MODEL` | yes — installed later, the next warm finds it |
| module found, **older than the floor** (`MinVersion`, default 0.4.6) | **`FAILED`** | **`VERSION`** (never `MODEL`) | yes — an update replaces the file |
| module found, cold | `INSTALLED` | | |
| `warm` running (load, licence, model) | `WARMING` | | |
| ready | `READY` | | |
| licence activation needs the network | `FAILED` | `NETWORK` | yes (the runtime's backoff retries) |
| licence refused | `UNLICENSED` | `LICENCE` | no |
| found but unloadable / no entry point | `FAILED` | `LOAD` | yes when a new file can fix it |
| `Enable=0` | `DISABLED` | | |
| the provider's D3D11 device was lost | `FAILED` | `DEVICE_LOST` | yes (re-warm re-creates it) |

A module refused as too old is refused from its version resource **before it is loaded**, so an
update can replace it under a running host. `get_provider_status` reports the same discovery as
the ADR-045 platform state: `PLATFORM_ABSENT` (no module), `INCOMPATIBLE` (too old), else `READY`.

`warm` runs the module's discovery, load and initialisation **on the runtime's thread** (no
activation thread of its own) and then creates the provider's device. NeurD's initialisation (the
licence check, the model load — seconds) cannot be interrupted; `is_cancelled` is honoured before
and after it. `evict` is a no-op (NeurD is never de-initialised: a reload re-runs licensing).

## Licence class

From the module's **own** words, never invented: its licence line once it has printed one, else
its file's product name. A module that calls itself internal / non-commercial / research /
evaluation is `RESEARCH_ONLY`; one that says commercial is `COMMERCIAL`; otherwise `UNKNOWN`.
The runtime selects `RESEARCH_ONLY` and `UNKNOWN` only with its `AllowResearchOnly` opt-in, which
signed DisplayXR installers never write (ADR-053 decision 2 (e)). An internal build of the module
therefore needs that opt-in on the box; the module's own installer may set it for an internal
build. `licence_spdx` is `LicenseRef-LeiaInc`.

## Settings

Only through `host->get_setting` — never this process's environment, never the retired
`HKLM\SOFTWARE\DisplayXR\Leia\Lift` key or `DXR_LEIA_LIFT*` variables (those belonged to the
display processor's lift slots, which no longer exist; nothing reads them). The host resolves
`DXR_CONV_LEIA_CONVERSION_<KEY>` in its environment (the service's), else the per-user store, else
`HKLM\Software\DisplayXR\ConversionProviders\leia-conversion\Settings\<KEY>` (Linux: the
per-user `leia-conversion.settings.json`, else the manifest's `settings` object).

The provider declares every key through `describe_settings` (the runtime's one options contract),
so the CLI lists and edits them:

```
displayxr-cli conv options leia-conversion
displayxr-cli conv set leia-conversion Backend openvino
displayxr-cli conv unset leia-conversion Backend
```

| Key | Meaning |
|---|---|
| `Enable` | `0` turns the provider off (`DISABLED`) |
| `NeurDPath` | absolute path of the module DLL; when set it is the **only** place looked at |
| `MinVersion`, `Backend`, `VideoModel`, `InteractiveMin` (Windows only), `Scale` | as in [neurd-module.md § Knobs](neurd-module.md#knobs) (process-wide; the first warm in a host decides) |
| `ViewGain`, `YGain`, `ZGain`, `ConvGain`, `DepthGain`, `Dilate`, `OffAxis`, `ReliefDepthM`, `MetricReliefMaxM` | as in [neurd-module.md § Knobs](neurd-module.md#knobs) (snapshotted per stream) |

Types, defaults and the accepted words are in the table `g_settings` in `src/leia_conv_plugin.cpp`
(16 keys on Windows, 15 on Linux); keep it in step with the modules' `read_knobs` and this table.

## Registration

The installer writes, in the 64-bit view:

| `HKLM\Software\DisplayXR\ConversionProviders\leia-conversion` | |
|---|---|
| `Binary` | `<install dir>\DisplayXR-LeiaConversion.dll` (`%ProgramFiles%\DisplayXR\Plugins\LeiaConversion`) |
| `DisplayName` | `Leia conversion (NeurD)` |
| `Vendor` | `Leia Inc.` |
| `ProbeOrder` | `50` (the vendor band) |
| `Supersedes` | `dp-lift` — hides the runtime's legacy adapter over a display plug-in's lift slots (an older Leia SR plug-in), so the two are never listed twice; it never affects selection among other providers, so an absent module still falls through |
| `UninstallString` | this package's uninstaller |
| `Version` | written **last** (removed first on an update): the "row complete" marker |

`Hosting` is not written (the runtime default, satellite). A `Settings` subkey the user created
survives an update; the uninstaller removes the whole row, but only while the row still points at
this package's DLL.

Installer contract ("close the host, never the service"), the handover from the Leia SR plug-in
installer that used to own this row, the `.deb`'s `Replaces` / `Breaks`, and releasing:
[installer.md](installer.md).

## Building and testing

The DLL needs the runtime headers with `xrt_conversion_plugin.h` (the pin `DXR_RUNTIME_GIT_TAG`
in `CMakeLists.txt`, ≥ v2.41.0) and the private NeurD headers (`NEURD_SDK_ROOT`, fetched by
`scripts\build-windows.bat` / CI at the ref in `scripts/neurd-pins.env`). Without the NeurD
headers there is no provider to build; only the pure tests are (`-DDXR_CONV_PURE_TESTS_ONLY=ON`).
The NeurD **runtime** is not needed to build or to run any test here.

```bat
scripts\build-windows.bat all
scripts\build-windows.bat test
```

| Test | What it pins |
|---|---|
| `test_lift_viewpoint`, `test_lift_depth`, `test_conv_leia_cpu` | viewpoint mapping, depth metadata + the off-axis camera, the CPU transport's pixel moves. Pure C, every lane |
| `test_conv_leia_policy` | the readiness gate (too old → `FAILED(VERSION)`, missing → `ABSENT(MODEL)`, network / licence / load / device-loss rows), the licence class from the module's words, extents, decoded-convergence mapping, depth kinds. Pure C, every lane |
| `test_conv_leia_provider_{missing,old,noentry,disabled}` | the provider's entry point linked statically, a fake host (settings only): negotiate (another major refused), every iface slot present, the declared settings (`describe_settings`: 16 well-formed, unique keys), the describe_cap contract (count, well-formed capabilities, index past the end untouched, writes only within `struct_size`, one generation per walk), `get_state` truncation, no stream before `READY` — and the gate on fake modules: no module → `ABSENT(MODEL)` + `PLATFORM_ABSENT`; a module older than the floor → `FAILED(VERSION)` at probe **and** after `warm`, `INCOMPATIBLE`, **never mapped**; a new-enough module without the entry point → `INSTALLED`, then `FAILED(LOAD)` with a pushed `notify_changed`; `Enable=0` → `DISABLED`; a cancelled `warm` changes nothing |

CI (`build-windows.yml`) also asserts the DLL's export set (exactly `xrtConversionPluginNegotiate`)
and that it imports neither the SR SDK, a display plug-in nor the NeurD module.

On a box with the runtime: register the dev DLL with the runtime's
`scripts\register_dev_plugin.bat conv <dll>` (elevated), then `displayxr-cli conv list` /
`conv status` and `displayxr-cli lift probe`. The conversion host logs to
`%LOCALAPPDATA%\DisplayXR\DisplayXR_conversion-host_leia-conversion.<pid>_<ts>.log`; this
provider's lines start `Leia conversion:` and the module's `Leia lift:` / `NeurD:`.

## Desktop Linux (`DisplayXR-LeiaConversion.so`, CPU transport)

The same provider source builds on desktop Linux with `LEIA_CONV_CPU_TRANSPORT`
(`src/CMakeLists.txt`, POSIX section): the D3D11 transport and `leia_lift_neurd.cpp` are not
compiled there.

| | Windows | Linux |
|---|---|---|
| Binary | `DisplayXR-LeiaConversion.dll` | `DisplayXR-LeiaConversion.so` (one export, `xrtConversionPluginNegotiate`; version script) |
| NeurD module | `leia_lift_neurd.cpp` (D3D11 bridge, `NeurD_convert_stream_dx_ex`) | `leia_conv_neurd_posix.cpp` (`dlopen("libNeurD.so")`; `NeurD_convert_stream_cpu_ex` on NeurD >= 0.5.0, else `NeurD_convert_stream_cpu`) |
| Transport | NT handle / CPU, keyed mutex / fence | host memory only (`XRT_CONV_MEM_CPU`, `SYNC_NONE`); the runtime copies GPU images to host memory for this lane |
| Capabilities | DEPTH_MONO (1), DEPTH_VIDEO (2), VIEWS_MONO (3) | VIEWS_MONO (3) only; with `cpu_ex` on OpenVINO it also returns the R32F depth of the same inference (aux depth) |
| Viewpoints | explicit (interactive / off-axis) | `cpu_ex`: identical to Windows — the metric off-axis camera from the runtime's rect-relative eyes (`leia_lift_oa_build`, the same helper), else the dimensionless pattern (`leia_lift_vp_map`). Older NeurD: the pair's horizontal separation only, as NeurD's gain (no look-around) |
| Convergence | runtime's DECODED value, or NeurD's own AUTO | `cpu_ex`: as Windows — `AUTO_CONVERGENCE` declared; the off-axis screen plane comes from the runtime's value, else NeurD's auto-convergence of the previous inference (when its depth is retained), else mid-depth. Older NeurD: not applied (its CPU renderer ignores `CONVERGENCE`), `AUTO_CONVERGENCE` never declared |
| Registration | `HKLM\…\ConversionProviders\leia-conversion`, ProbeOrder 50 | `050-leia-conversion-conversion-provider.json` in a discovery root (the build writes a dev one under `build/src/_conv_manifest/`) |

**Finding NeurD (no load).** In order: the `NeurDPath` setting (the `.so` or its
directory; pins it), the NeurD runtime package's install directory
`/opt/immersity/neurd-runtime` (the `neurd-runtime` `.deb`, which downloads the
encrypted models at install; NeurD's own loader falls back to the same directory),
`NEURD_PATH`, each `LD_LIBRARY_PATH` directory, then the per-user root
`${XDG_DATA_HOME:-~/.local/share}/LeiaInc/NeurD-Runtime` (an unpacked runtime, for
development). The install's `VERSION.txt` (NeurD's install rules
write it next to the library) is the pre-load version, the VERSIONINFO twin; the
`MinVersion` floor (0.4.6) applies before and after the load. The licence class
comes from NeurD's own `License:` log line, as on Windows; the
`LICENSED_LOCAL_INSTALL` flag follows the same rule (#510).

**Which NeurD table entries exist (the cpu_ex guard).** NeurD's table grows only at the
end and each entry records the version that introduced it, but two builds of one version
can differ: a NeurD 0.5.0 built before `NeurD_convert_stream_cpu_ex` was added reports
0.5.0 too. NeurD's own `version >= introduced && entry != NULL` test reads the entry, which
for that build is past the end of its table (the provider used to segfault there). So the
provider learns the table's size after `NeurD_load` and checks `offsetof(entry)` against
it before reading anything: from `NeurD_get_table_size()` when the library exports it
(media_sdk #610), else from the ELF size of the exported table object (builds without
NeurD's export version script, every 0.4.x), else it trusts only entries introduced
**before** the library's own version, and takes `NeurD_convert_stream_cpu` (fixed pair)
rather than guess. The load logs which: `NeurD function table 344 bytes
(NeurD_get_table_size; ...)` or `NeurD function table size unknown (...)`. Look-around
therefore needs a NeurD that exports `NeurD_get_table_size`. A plain 0.5.0 `dev` build
works, but without look-around. The fake `libNeurD.so` in `tests/fake_neurd.c` (a 0.5.0
table that ends right before a `PROT_NONE` page, with and without the entry and the
export) checks this in CI.

**Packaging.** `scripts/package_deb.sh` builds `displayxr-leia-conversion_<ver>_<arch>.deb`:
`/usr/lib/displayxr/plugins/DisplayXR-LeiaConversion.so` plus
`050-leia-conversion-conversion-provider.json` (probe order 50, absolute `binary_path`). The
package has no relation to NeurD: the provider loads no NeurD symbol at link time (the script
refuses a `libNeurD` `DT_NEEDED`), and the NeurD runtime package is in no Ubuntu archive, so a
`Recommends` would fail the install checks. Without NeurD the provider reports `ABSENT` and the
runtime uses its next provider. The script also refuses a provider built without `cpu_ex` unless
you pass `--allow-no-look-around`. It `Replaces` and `Breaks` the `displayxr-leia-sr` versions that
shipped the same two files ([installer.md](installer.md#linux-the-deb)).

**Settings** (`<id>.settings.json` / the manifest `settings` object /
`DXR_CONV_LEIA_CONVERSION_<KEY>`): `Enable`, `NeurDPath`, `Backend`
(`auto` / `openvino` / `cuda`), `Scale` (default **1080p** here: NeurD renders the
views at the autoscaled size, and a smaller frame costs a CPU resample back up),
`DepthGain`, `Dilate`, `ConvGain`, `MinVersion`, `VideoModel`, and the Windows
module's look-around knobs `ViewGain`, `YGain`, `ZGain`, `OffAxis`, `ReliefDepthM`,
`MetricReliefMaxM` (same ranges and defaults). OpenVINO picks its
device itself (GPU, NPU, CPU); `NEURD_OV_DEVICE` in the hosting process's
environment overrides it. The GPU needs the Intel compute runtime (OpenCL), the
NPU the Level Zero NPU driver; without them OpenVINO runs on the CPU.

**Testing without the panel.** `conv_leia_harness` loads the `.so` through its
export with a fake host and converts a still image file:

```bash
./scripts/build-linux.sh                          # fetches the pinned NeurD headers when missing
build/src/conv_leia_harness --provider build/src/DisplayXR-LeiaConversion.so \
    --neurd-path /opt/immersity/neurd-runtime --input frame.png --out views.png --frames 20
```

It prints the capability before / after warm, one line per frame and a
summary (warm, first, median, p90 convert time). `--eye-x 0,0.02,0.04` sweeps the
viewer's midpoint (one `<out>.<i>.png` per value), `--rect WxH` / `--no-rect` choose
rect-relative or panel viewpoints, `--depth d.f32` requests the aux depth. Without NeurD,
`--expect absent` / `--enable 0 --expect disabled` check the gates (CI runs both), and
`--neurd-path build/src/fake_neurd/<short|short_sized|full|full_sized>/libNeurD.so
--expect ready` the table guard, and `--list-settings` prints what `describe_settings` declares.
