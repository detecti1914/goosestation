set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(MINGW_TRIPLE x86_64-w64-mingw32)

set(CMAKE_C_COMPILER   ${MINGW_TRIPLE}-gcc)
set(CMAKE_CXX_COMPILER ${MINGW_TRIPLE}-g++)
set(CMAKE_RC_COMPILER  ${MINGW_TRIPLE}-windres)
set(CMAKE_AR           ${MINGW_TRIPLE}-ar)
set(CMAKE_RANLIB       ${MINGW_TRIPLE}-ranlib)
set(CMAKE_STRIP        ${MINGW_TRIPLE}-strip)

# Win10 1803+ baseline — exposes VirtualAlloc2 / MapViewOfFile3 used by
# DuckStation's SharedMemoryMappingArea. Arch's mingw headers default high
# enough; Debian's don't, so set it explicitly.
add_compile_definitions(_WIN32_WINNT=0x0A00 NTDDI_VERSION=0x0A000005 WINVER=0x0A00)

list(APPEND CMAKE_FIND_ROOT_PATH /usr/${MINGW_TRIPLE})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
