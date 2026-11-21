@echo off
setlocal enabledelayedexpansion

:: ============================================================
:: DisplayXR Leia Conversion Provider - Local Windows Build Script
:: ============================================================
:: Usage: scripts\build-windows.bat [generate|build|test|installer|all] [config]
::   generate   - CMake configure only
::   build      - Build DisplayXR-LeiaConversion.dll + install into _package
::   test       - ctest (the provider test against fake NeurD modules + the pure tests)
::   installer  - Build the NSIS installer (depends on build)
::   all        - generate + build + test + installer (default)
::   config     - Release (default) | RelWithDebInfo | Debug
::
:: Environment (auto-resolved if missing):
::   NEURD_SDK_ROOT         - dir with include\NeurD.h (+ generated NeurD_version.h).
::                            Default: NeurD-SDK-<ref>\ in this repo, fetched from the
::                            private media_sdk repo at the ref pinned in
::                            scripts\neurd-pins.env (needs `gh auth` with read access).
::   DXR_RUNTIME_SOURCE_DIR - a local displayxr-runtime checkout. If unset, probes the
::                            sibling ..\displayxr-runtime. If none is found, CMake
::                            fetches the tag pinned in CMakeLists.txt (slow first build).
::
:: Runtime-side build deps (vcpkg, Vulkan SDK, OpenXR loader, VS 2022, ninja, gh)
:: must be set up as for the runtime build: this script assumes
:: `scripts\build_windows.bat all` already works in the runtime checkout. The NeurD
:: RUNTIME is not needed to build or to run the tests (they use fake modules).
:: ============================================================

set SCRIPT_DIR=%~dp0
set REPO=%SCRIPT_DIR%..\
set TARGET=%~1
if "%TARGET%"=="" set TARGET=all
set CONFIG=%~2
if "%CONFIG%"=="" set CONFIG=Release

:: --- NeurD header pins: the single source is scripts\neurd-pins.env ---
for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%SCRIPT_DIR%neurd-pins.env") do set "%%A=%%B"
if "%NEURD_SDK_REF_WINDOWS%"=="" (
    echo ERROR: NEURD_SDK_REF_WINDOWS not found in scripts\neurd-pins.env
    exit /b 1
)

:: --- Resolve runtime source dir ---
if "%DXR_RUNTIME_SOURCE_DIR%"=="" (
    if exist "%REPO%..\displayxr-runtime\CMakeLists.txt" (
        set DXR_RUNTIME_SOURCE_DIR=%REPO%..\displayxr-runtime
        echo Detected local runtime at !DXR_RUNTIME_SOURCE_DIR!
    ) else (
        echo Local runtime checkout not found next to %REPO% ^(displayxr-runtime^)
        echo CMake will FetchContent the runtime from GitHub ^(slow first build^).
    )
)

:: --- MSVC env ---
echo === Setting up MSVC environment ===
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VCVARS="
if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
        if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=%%i\VC\Auxiliary\Build\vcvars64.bat"
    )
)
if not defined VCVARS (
    for %%E in (Community Professional Enterprise BuildTools) do (
        if not defined VCVARS if exist "C:\Program Files\Microsoft Visual Studio\2022\%%E\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=C:\Program Files\Microsoft Visual Studio\2022\%%E\VC\Auxiliary\Build\vcvars64.bat"
    )
)
if not defined VCVARS (
    echo ERROR: VS 2022 with the C++ workload not found.
    exit /b 1
)
call "%VCVARS%" >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: vcvars64.bat failed: !VCVARS!
    exit /b 1
)

:: --- NeurD headers (required: without them there is no provider to build) ---
if "%NEURD_SDK_ROOT%"=="" (
    set NEURD_SDK_ROOT=%REPO%NeurD-SDK-%NEURD_SDK_REF_WINDOWS%
)
if not exist "%NEURD_SDK_ROOT%\include\NeurD_version.h" (
    echo === Fetching NeurD headers ^(%NEURD_SDK_REPO%@%NEURD_SDK_REF_WINDOWS%^) ===
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%fetch-neurd-headers.ps1" -Repo %NEURD_SDK_REPO% -Ref %NEURD_SDK_REF_WINDOWS% -Dest "%NEURD_SDK_ROOT%"
    if !ERRORLEVEL! NEQ 0 (
        echo ERROR: NeurD headers unavailable. Run: gh auth login ^(an account that can read %NEURD_SDK_REPO%^)
        exit /b 1
    )
)

echo.
echo === Dependencies ready ===
echo   NEURD_SDK_ROOT=%NEURD_SDK_ROOT%
echo   DXR_RUNTIME_SOURCE_DIR=%DXR_RUNTIME_SOURCE_DIR%
echo.

if "%TARGET%"=="build" if exist "%REPO%build\build.ninja" goto :do_build
if "%TARGET%"=="test" if exist "%REPO%build\build.ninja" goto :do_test
if "%TARGET%"=="installer" if exist "%REPO%build\build.ninja" goto :do_installer

:: ============================================================
:: CMake Generate
:: ============================================================
:: add_subdirectory(runtime) runs the runtime's own CMake, which needs vcpkg
:: (Eigen3 etc.), the Vulkan SDK and the OpenXR loader. They are inherited from
:: the runtime sibling's already-built dev tree.
echo === CMake Generate ===
set CMAKE_ARGS=-S "%REPO%." -B "%REPO%build" -G "Ninja Multi-Config" ^
  -DCMAKE_INSTALL_PREFIX="%REPO%_package" ^
  -DDXR_CONV_REQUIRE_PROVIDER=ON ^
  -DNEURD_SDK_ROOT="%NEURD_SDK_ROOT%"

if not "%DXR_RUNTIME_SOURCE_DIR%"=="" (
    set CMAKE_ARGS=!CMAKE_ARGS! -DDXR_RUNTIME_SOURCE_DIR="%DXR_RUNTIME_SOURCE_DIR%"
    if exist "%DXR_RUNTIME_SOURCE_DIR%\vcpkg\scripts\buildsystems\vcpkg.cmake" (
        set CMAKE_ARGS=!CMAKE_ARGS! -DCMAKE_TOOLCHAIN_FILE="%DXR_RUNTIME_SOURCE_DIR%\vcpkg\scripts\buildsystems\vcpkg.cmake" -DX_VCPKG_APPLOCAL_DEPS_INSTALL=ON -DVCPKG_MANIFEST_DIR="%DXR_RUNTIME_SOURCE_DIR%"
        echo Using runtime sibling's vcpkg toolchain + vcpkg.json.
    ) else (
        echo WARN: runtime vcpkg not found at %DXR_RUNTIME_SOURCE_DIR%\vcpkg
        echo       Run scripts\build_windows.bat all in the runtime first.
    )
    if exist "%DXR_RUNTIME_SOURCE_DIR%\openxr_sdk\x64\lib\openxr_loader.lib" (
        set CMAKE_ARGS=!CMAKE_ARGS! -DOpenXR_ROOT="%DXR_RUNTIME_SOURCE_DIR%\openxr_sdk"
    )
)

cmake !CMAKE_ARGS!
if %ERRORLEVEL% NEQ 0 (
    echo CMake generate FAILED
    exit /b 1
)
if "%TARGET%"=="generate" goto :end

:do_build
echo === Build ===
cmake --build "%REPO%build" --config !CONFIG! --target install
if %ERRORLEVEL% NEQ 0 (
    echo Build FAILED
    exit /b 1
)
if "%TARGET%"=="build" goto :end

:do_test
echo === Tests ===
cmake --build "%REPO%build" --config !CONFIG! --target test_conv_leia_provider test_conv_leia_policy test_conv_leia_cpu test_lift_viewpoint test_lift_depth
if %ERRORLEVEL% NEQ 0 (
    echo Test build FAILED
    exit /b 1
)
ctest --test-dir "%REPO%build\src" -C !CONFIG! --output-on-failure
if %ERRORLEVEL% NEQ 0 (
    echo Tests FAILED
    exit /b 1
)
if "%TARGET%"=="test" goto :end

:do_installer
:: Code signing (gated on %SIGN_CMD%): off unless SIGN_CMD is set (only on a
:: signing-capable build machine). No certificate or secret lives in this repo.
:: The DLL must be signed BEFORE makensis packs it.
if defined SIGN_CMD (
    echo === Signing binaries [SIGN_CMD set] ===
    powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO%scripts\sign-release.ps1" -Path "%REPO%_package\bin" -SignCmd "%SIGN_CMD%"
    if errorlevel 1 (
        echo Binary signing FAILED
        exit /b 1
    )
) else (
    echo === Signing skipped [SIGN_CMD not set] - installer will be UNSIGNED ===
)

echo === Build Installer ===
cmake --build "%REPO%build" --config !CONFIG! --target installer
if %ERRORLEVEL% NEQ 0 (
    echo Installer build FAILED
    exit /b 1
)
if defined SIGN_CMD (
    echo === Signing installer .exe ===
    powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO%scripts\sign-release.ps1" -Path "%REPO%_package" -SignCmd "%SIGN_CMD%"
    if errorlevel 1 (
        echo Installer signing FAILED
        exit /b 1
    )
)

:end
echo.
echo === Done ===
echo Outputs:
echo   Provider DLL: %REPO%_package\bin\plugins\DisplayXR-LeiaConversion.dll
echo   Installer:    %REPO%_package\DisplayXRLeiaConversionSetup-*.exe
endlocal
