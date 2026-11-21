# Copyright 2026, Leia Inc.
# SPDX-License-Identifier: Apache-2.0
#
# NSIS installer for the DisplayXR Leia conversion provider.

if(NOT WIN32)
    return()
endif()

# dxr-rm-close.exe — the installer's Restart Manager driver (NSIS has no RM
# plug-in). Closes whatever holds the provider's files before they are replaced
# or deleted. Generic Windows code, no DisplayXR knowledge; the same source the
# Leia SR plug-in installer ships. Built before the NSIS check so a box without
# NSIS still compiles it. Static CRT: it runs from the installer's temp dir on
# boxes that may not have the VC++ redistributable. Staged into
# _package/bin/tools so the signing pass (which walks _package/bin) covers it
# and the installer packs the signed copy.
add_executable(dxr-rm-close rm-helper/dxr_rm_close.cpp)
target_compile_definitions(dxr-rm-close PRIVATE UNICODE _UNICODE)
target_link_libraries(dxr-rm-close PRIVATE rstrtmgr)
set_target_properties(dxr-rm-close PROPERTIES
    MSVC_RUNTIME_LIBRARY "MultiThreaded")
install(TARGETS dxr-rm-close
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}/tools COMPONENT Runtime)

# Test-only holder process for dxr-rm-close (never shipped, never installed):
#   cmake --build build --config Release --target rm-test-holder
add_executable(rm-test-holder EXCLUDE_FROM_ALL rm-helper/rm_test_holder.cpp)
target_compile_definitions(rm-test-holder PRIVATE UNICODE _UNICODE)
set_target_properties(rm-test-holder PROPERTIES
    MSVC_RUNTIME_LIBRARY "MultiThreaded"
    WIN32_EXECUTABLE ON)
if(MSVC)
    target_link_options(rm-test-holder PRIVATE "/ENTRY:wmainCRTStartup")
endif()

if(NOT TARGET DisplayXR-LeiaConversion)
    message(STATUS "Installer: the provider was not built (no NeurD headers) - no installer target")
    return()
endif()

find_program(NSIS_EXECUTABLE makensis
    PATHS
        "$ENV{PROGRAMFILES}/NSIS"
        "$ENV{PROGRAMFILES\(X86\)}/NSIS"
        "C:/Program Files/NSIS"
        "C:/Program Files (x86)/NSIS"
)
if(NOT NSIS_EXECUTABLE)
    message(WARNING "NSIS not found - installer target will not be available")
    return()
endif()
message(STATUS "Found NSIS: ${NSIS_EXECUTABLE}")

set(DXR_CONV_VERSION "${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}.${PROJECT_VERSION_PATCH}")
set(DXR_BIN_DIR "${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_BINDIR}")

# Optional code-signing command, from the SIGN_CMD environment variable at
# configure time. Empty on any machine without it (clones, GitHub-hosted CI):
# installer + uninstaller build unsigned. FORCE so the live environment always
# wins on a reconfigure. No certificate or secret lives in this repo.
set(SIGN_CMD "$ENV{SIGN_CMD}" CACHE STRING "Code-signing command for installer/uninstaller (empty = unsigned)" FORCE)

# ADR-054 N4b: the provenance-allowlist row for the provider DLL, generated from
# the exact bytes in BIN_DIR right before makensis runs.
set(CONV_ALLOWLIST_NSH "${CMAKE_CURRENT_BINARY_DIR}/Allowlist.nsh")
file(TO_NATIVE_PATH "${CONV_ALLOWLIST_NSH}" CONV_ALLOWLIST_NSH_NATIVE)

add_custom_target(installer
    COMMAND "${CMAKE_COMMAND}"
        "-DBIN_DIR=${DXR_BIN_DIR}"
        "-DVERSION=${DXR_CONV_VERSION}"
        "-DOUT=${CONV_ALLOWLIST_NSH}"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/gen_allowlist_nsh.cmake"
    COMMAND "${NSIS_EXECUTABLE}"
        "/DVERSION=${DXR_CONV_VERSION}"
        "/DVERSION_MAJOR=${PROJECT_VERSION_MAJOR}"
        "/DVERSION_MINOR=${PROJECT_VERSION_MINOR}"
        "/DVERSION_PATCH=${PROJECT_VERSION_PATCH}"
        "/DBUILD_NUM=${BUILD_NUM}"
        "/DBIN_DIR=${DXR_BIN_DIR}"
        "/DMIN_RUNTIME_VERSION=${DXR_CONV_MIN_RUNTIME_VERSION}"
        "/DSOURCE_DIR=${CMAKE_SOURCE_DIR}"
        "/DOUTPUT_DIR=${CMAKE_INSTALL_PREFIX}"
        "/DSIGN_CMD=${SIGN_CMD}"
        "/DALLOWLIST_NSH=${CONV_ALLOWLIST_NSH_NATIVE}"
        "${CMAKE_CURRENT_SOURCE_DIR}/DisplayXRLeiaConversionInstaller.nsi"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    COMMENT "Building the DisplayXR Leia conversion provider installer..."
    VERBATIM
)
add_dependencies(installer DisplayXR-LeiaConversion dxr-rm-close)
