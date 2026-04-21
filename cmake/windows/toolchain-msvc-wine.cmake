# CMake toolchain file for cross-compiling Windows binaries on Linux
# using the msvc-wine toolchain (https://github.com/mstorsjo/msvc-wine).
#
# Usage:
#   . /root/freedom/msvc-wine/use-msvc-x64.sh   # puts wrappers on PATH
#   cmake -G Ninja \
#         -DCMAKE_TOOLCHAIN_FILE=cmake/windows/toolchain-msvc-wine.cmake \
#         -DCMAKE_BUILD_TYPE=RelWithDebInfo ..
#
# The MSVC_WINE_BIN variable can override the location of the wrapper
# directory (default: $ENV{MSVC_WINE_BIN} or /data/msvc-wine/msvc/bin/x64).

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR AMD64)

# Where are the msvc-wine wrappers?
if(NOT DEFINED MSVC_WINE_BIN)
    if(DEFINED ENV{MSVC_WINE_BIN})
        set(MSVC_WINE_BIN "$ENV{MSVC_WINE_BIN}")
    else()
        set(MSVC_WINE_BIN "/data/msvc-wine/msvc/bin/x64")
    endif()
endif()

if(NOT EXISTS "${MSVC_WINE_BIN}/cl")
    message(FATAL_ERROR
        "msvc-wine wrapper directory not found: ${MSVC_WINE_BIN}\n"
        "Run /root/freedom/msvc-wine/setup-local-msvc.sh first, or set "
        "MSVC_WINE_BIN / the MSVC_WINE_BIN environment variable.")
endif()

# Point CMake at the wrapper scripts (plain shell scripts that shell out to wine).
set(CMAKE_C_COMPILER   "${MSVC_WINE_BIN}/cl")
set(CMAKE_CXX_COMPILER "${MSVC_WINE_BIN}/cl")
set(CMAKE_RC_COMPILER  "${MSVC_WINE_BIN}/rc")
set(CMAKE_MT           "${MSVC_WINE_BIN}/mt" CACHE FILEPATH "mt" FORCE)
set(CMAKE_AR           "${MSVC_WINE_BIN}/lib" CACHE FILEPATH "lib.exe archiver" FORCE)
set(CMAKE_LINKER       "${MSVC_WINE_BIN}/link" CACHE FILEPATH "link" FORCE)

# Qt's tooling (moc, uic, rcc, lrelease, lupdate, windeployqt, etc.) and any
# generated host tool (spb-protoc, ...) is a Windows PE built to run under
# Wine. Tell CMake to emulate.
if(DEFINED ENV{WINE})
    set(_wine_cmd "$ENV{WINE}")
else()
    find_program(_wine_cmd wine REQUIRED)
endif()
set(CMAKE_CROSSCOMPILING_EMULATOR "${_wine_cmd}" CACHE STRING "" FORCE)

# Make sure find_package/find_library search the dependency trees we put on
# CMAKE_PREFIX_PATH (Qt, OpenSSL, ...) rather than the host system.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Silence MSVC manifest embedding (mt.exe runs fine under wine but is
# sensitive to TMP; we leave the default on).
