# Copyright 2026, Leia Inc.
# SPDX-License-Identifier: Apache-2.0
#
# DisplayXR Leia conversion provider (runtime ADR-053):
#   Windows       DisplayXR-LeiaConversion.dll  (D3D11 transport)
#   desktop Linux DisplayXR-LeiaConversion.so   (CPU transport)
# over Leia's NeurD module. NeurD itself (its runtime, licence check and models)
# is an EXTERNAL prerequisite the provider finds at run time; this repo never
# builds, links, ships or downloads it.

cmake_minimum_required(VERSION 3.22)
project(
    DisplayXR-LeiaConversion
    VERSION 0.1.0
    LANGUAGES C CXX
    DESCRIPTION "DisplayXR Leia conversion provider (2D to 3D over NeurD)"
)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(GNUInstallDirs)

if(NOT DEFINED BUILD_NUM)
    set(BUILD_NUM "0")
endif()

set(DXR_CONV_LINUX_DESKTOP FALSE)
if(UNIX AND NOT APPLE AND NOT ANDROID)
    set(DXR_CONV_LINUX_DESKTOP TRUE)
endif()

# The provider builds on Windows and desktop Linux. Everywhere else (macOS, a
# box without the runtime's build dependencies) only the pure layers and their
# tests build: the policy, the CPU pixel moves, the viewpoint and depth
# helpers. None of them needs the runtime or the NeurD headers.
set(_dxr_conv_pure_default OFF)
if(NOT WIN32 AND NOT DXR_CONV_LINUX_DESKTOP)
    set(_dxr_conv_pure_default ON)
endif()
option(DXR_CONV_PURE_TESTS_ONLY
    "Build only the pure layers and their tests: no runtime fetch, no provider binary"
    ${_dxr_conv_pure_default})
if(NOT DXR_CONV_PURE_TESTS_ONLY AND NOT WIN32 AND NOT DXR_CONV_LINUX_DESKTOP)
    message(FATAL_ERROR
        "The Leia conversion provider builds on Windows and desktop Linux only. "
        "Configure with -DDXR_CONV_PURE_TESTS_ONLY=ON for the pure tests.")
endif()

# --- Build identity --------------------------------------------------------
#
# git-describe, baked into the provider's iface `.version` so the loader log
# and `displayxr-cli conv list` say which build is loaded. A release runner
# that patches the VERSION line above before configuring passes the true
# identity in DXR_PLUGIN_GIT_DESC (the tree is then legitimately modified and
# `--dirty` would fire on a build that IS the tag).
if(DEFINED ENV{DXR_PLUGIN_GIT_DESC} AND NOT "$ENV{DXR_PLUGIN_GIT_DESC}" STREQUAL "")
    set(DXR_PLUGIN_GIT_DESC "$ENV{DXR_PLUGIN_GIT_DESC}")
else()
    execute_process(
        COMMAND git describe --tags --always --dirty --match "v[0-9]*"
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        OUTPUT_VARIABLE DXR_PLUGIN_GIT_DESC
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    if(NOT DXR_PLUGIN_GIT_DESC)
        set(DXR_PLUGIN_GIT_DESC "v${PROJECT_VERSION}")
    endif()
endif()
message(STATUS "Provider version (iface .version): ${DXR_PLUGIN_GIT_DESC}")
if(DXR_PLUGIN_GIT_DESC MATCHES "-dirty$"
   AND DEFINED ENV{DXR_RELEASE_BUILD} AND NOT "$ENV{DXR_RELEASE_BUILD}" STREQUAL "0")
    message(FATAL_ERROR
        "refusing to build a RELEASE from a dirty tree: the provider would ship as "
        "'${DXR_PLUGIN_GIT_DESC}'. Build from a clean checkout, or pass the true "
        "identity in DXR_PLUGIN_GIT_DESC.")
endif()

# --- Runtime dependency ------------------------------------------------------
#
# The provider consumes the runtime's conversion ABI header
# (xrt/xrt_conversion_plugin.h, API 1) and its aux logging. On Windows it links
# the runtime DLL's import library (ADR-019); on Linux aux_util / aux_os are
# linked statically and kept local by the version script.
#
# Two modes, as in the vendor template and the Leia display plug-in:
#   - DXR_RUNTIME_SOURCE_DIR = a local displayxr-runtime checkout;
#   - otherwise FetchContent fetches DXR_RUNTIME_GIT_TAG.
#
# The pin is a literal quoted string: the workflows' rule-5 self-check greps
# `DXR_RUNTIME_GIT_TAG\s+"([^"]+)"` and compares it with their RUNTIME_REF.
# It is the HEADER the provider is compiled against, not a floor: the
# conversion ABI has been API 1 since runtime v2.41.0, and everything this
# provider uses past v1 is appended and guarded (describe_settings,
# XRT_CONVERSION_PLUGIN_HAS_DESCRIBE_SETTINGS, v2.45.0; the capability bits it
# defines itself when the header lacks them). Move the pin when the code needs
# a newer macro, never to chase a release.
set(DXR_RUNTIME_GIT_TAG "v2.70.5" CACHE STRING
    "Runtime git ref to fetch. Must equal the workflows' RUNTIME_REF (rule-5 CI check).")

# The oldest runtime that can host the provider at all: the first with the
# conversion-provider ABI. Informational on Windows (an older runtime ignores
# the ConversionProviders row; the installer says so and installs anyway) and
# the .deb's `Depends: displayxr-runtime (>= ...)`.
set(DXR_CONV_MIN_RUNTIME_VERSION "2.41.0" CACHE STRING
    "First runtime release with the conversion-provider ABI (API 1)")

if(NOT DXR_CONV_PURE_TESTS_ONLY)
    if(DXR_CONV_LINUX_DESKTOP)
        # Headless runtime defaults, the set the runtime's scripts/build_linux.sh
        # passes: this build needs headers + aux, never a window system.
        foreach(_dxr_off
                XRT_FEATURE_SERVICE
                XRT_BUILD_DRIVER_QWERTY
                XRT_FEATURE_DEBUG_GUI
                XRT_FEATURE_WINDOW_PEEK
                XRT_HAVE_SDL2
                XRT_HAVE_OPENCV
                XRT_HAVE_LIBUSB
                XRT_BUILD_DRIVER_EUROC)
            set(${_dxr_off} OFF CACHE BOOL "headless Linux default (leia-conversion)")
        endforeach()
    endif()

    if(DXR_RUNTIME_SOURCE_DIR)
        message(STATUS "Using local runtime checkout: ${DXR_RUNTIME_SOURCE_DIR}")
        add_subdirectory("${DXR_RUNTIME_SOURCE_DIR}" runtime-build EXCLUDE_FROM_ALL)
    else()
        include(FetchContent)
        message(STATUS "Fetching runtime via FetchContent @ ${DXR_RUNTIME_GIT_TAG}")
        set(_dxr_runtime_fc_exclude "")
        if(CMAKE_VERSION VERSION_GREATER_EQUAL 3.28)
            set(_dxr_runtime_fc_exclude EXCLUDE_FROM_ALL)
        endif()
        FetchContent_Declare(
            displayxr_runtime
            GIT_REPOSITORY https://github.com/DisplayXR/displayxr-runtime.git
            GIT_TAG "${DXR_RUNTIME_GIT_TAG}"
            ${_dxr_runtime_fc_exclude}
        )
        FetchContent_MakeAvailable(displayxr_runtime)
    endif()
endif()

enable_testing()
add_subdirectory(src)
if(WIN32 AND NOT DXR_CONV_PURE_TESTS_ONLY)
    add_subdirectory(installer)
endif()
