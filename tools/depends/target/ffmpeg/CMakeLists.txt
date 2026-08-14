project(ffmpeg)

cmake_minimum_required(VERSION 3.12)

if(ENABLE_CCACHE AND CCACHE_PROGRAM)
  set(ffmpeg_conf "--cc=${CCACHE_PROGRAM} ${CMAKE_C_COMPILER}"
                  "--cxx=${CCACHE_PROGRAM} ${CMAKE_CXX_COMPILER}"
                )
else()
  # FFmpeg's configure script is executed by Bash on Windows. Use the
  # toolchain-provided compiler names rather than absolute paths containing
  # spaces (e.g. "C:/Program Files/..."). The Visual Studio environment is
  # initialized by the GitHub Actions workflow before CMake runs.
  set(ffmpeg_conf --cc=cl.exe
                  --cxx=cl.exe
                  --toolchain=msvc
                )
endif()

if(CROSSCOMPILING)
  set(pkgconf "PKG_CONFIG_LIBDIR=${DEPENDS_PATH}/lib/pkgconfig")
  list(APPEND ffmpeg_conf --pkg-config=${PKG_CONFIG_EXECUTABLE}
                          --pkg-config-flags=--static
                          --enable-cross-compile
                          --enable-pic
                          --ar=${CMAKE_AR}
                          --ranlib=${CMAKE_RANLIB}
                          --strip=${CMAKE_STRIP}
              )

  message(STATUS "CROSS: ${ffmpeg_conf}")
endif()

set(CONFIGARCH --arch=${CPU})

list(APPEND ffmpeg_conf --disable-doc
                        --disable-devices
                        --disable-programs
                        --disable-sdl2
                        --disable-vulkan
                        --enable-gpl
                        --enable-postproc
                        --enable-runtime-cpudetect
                        --enable-pthreads
                        --extra-version="Kodi"
            )

if(CMAKE_C_FLAGS)
  list(APPEND ffmpeg_conf --extra-cflags=${CMAKE_C_FLAGS})
endif()

if(CMAKE_CXX_FLAGS)
  list(APPEND ffmpeg_conf --extra-cxxflags=${CMAKE_CXX_FLAGS})
endif()

if(CMAKE_EXE_LINKER_FLAGS)
  list(APPEND ffmpeg_conf --extra-ldflags=${CMAKE_EXE_LINKER_FLAGS})
endif()

if(ENABLE_NEON)
  list(APPEND ffmpeg_conf --enable-neon)
endif()

if(CMAKE_BUILD_TYPE STREQUAL Release)
  list(APPEND ffmpeg_conf --disable-debug)
endif()

if(CORE_SYSTEM_NAME STREQUAL linux OR CORE_SYSTEM_NAME STREQUAL freebsd)
  list(APPEND ffmpeg_conf --enable-pic
                          --target-os=linux
              )
  if(ENABLE_VAAPI)
    list(APPEND ffmpeg_conf --enable-vaapi)
  else()
    list(APPEND ffmpeg_conf --disable-vaapi)
  endif()
  if(ENABLE_VDPAU)
    list(APPEND ffmpeg_conf --enable-vdpau)
  else()
    list(APPEND ffmpeg_conf --disable-vdpau)
  endif()
elseif(CORE_SYSTEM_NAME STREQUAL android)
  list(APPEND ffmpeg_conf --target-os=android
                          --extra-libs=-liconv
                          --disable-linux-perf
              )
  if(CPU MATCHES arm64)
    set(CONFIGARCH --arch=aarch64)
    list(APPEND ffmpeg_conf --cpu=cortex-a53)
  elseif(CPU MATCHES arm)
    list(APPEND ffmpeg_conf --cpu=cortex-a9)
  elseif(CPU MATCHES x86_64)
    list(APPEND ffmpeg_conf --cpu=x86_64)
    list(APPEND ffmpeg_conf --extra-cflags=-mno-stackrealign)
  else()
    list(APPEND ffmpeg_conf --cpu=i686 --disable-mmx --disable-asm)
    list(APPEND ffmpeg_conf --extra-cflags=-mno-stackrealign)
  endif()
elseif(CORE_SYSTEM_NAME STREQUAL darwin_embedded)
  list(APPEND ffmpeg_conf --enable-videotoolbox
                          --disable-filter=yadif_videotoolbox
                          --target-os=darwin
              )
elseif(CORE_SYSTEM_NAME STREQUAL osx)
  list(APPEND ffmpeg_conf --enable-videotoolbox
                          --target-os=darwin
                          --disable-securetransport
              )
endif()

if(CPU MATCHES arm)
  list(APPEND ffmpeg_conf --disable-armv5te --disable-armv6t2)
elseif(CPU MATCHES mips)
  list(APPEND ffmpeg_conf --disable-mips32r2 --disable-mipsdsp --disable-mipsdspr2)
endif()

find_package(GnuTLS)
if(GNUTLS_FOUND)
  list(APPEND ffmpeg_conf --enable-gnutls)
endif()

if(CPU MATCHES x86 OR CPU MATCHES x86_64)
  find_package(NASM REQUIRED)
  list(APPEND ffmpeg_conf --x86asmexe=${NASM_EXECUTABLE})
endif()

if(USE_LTO)
   list(APPEND ffmpeg_conf --enable-lto)
endif()

if(ENABLE_DAV1D)
  list(APPEND ffmpeg_conf --enable-libdav1d
                          --pkg-config=pkg-config)
  set(pkgconf_path "PKG_CONFIG_PATH=${CMAKE_INSTALL_PREFIX}/lib/pkgconfig")
else()
  list(APPEND ffmpeg_conf --disable-libdav1d)
endif()

if(EXTRA_FLAGS)
  string(REPLACE " " ";" EXTRA_FLAGS ${EXTRA_FLAGS})
  list(APPEND ffmpeg_conf ${EXTRA_FLAGS})
endif()

list(APPEND ffmpeg_conf ${CONFIGARCH})

message(STATUS "FFMPEG_CONF: ${ffmpeg_conf}")

set(MAKE_COMMAND $(MAKE))
if(CMAKE_GENERATOR STREQUAL Ninja)
  set(MAKE_COMMAND make)
  include(ProcessorCount)
  ProcessorCount(N)
  if(NOT N EQUAL 0)
    set(MAKE_COMMAND make -j${N})
  endif()
endif()

# ExternalProject's CONFIGURE_COMMAND is executed directly by the generator.
# Use CMake's environment wrapper instead of shell-style assignments so the
# configure step also works with Windows cmd.exe.
set(ffmpeg_env ${CMAKE_COMMAND} -E env)
# Git Bash/MSYS can rewrite slash-prefixed MSVC arguments (/D..., /O2, /machine:x64,
# etc.) as filesystem paths. Disable that conversion for FFmpeg's configure run.
list(APPEND ffmpeg_env MSYS_NO_PATHCONV=1)
if(pkgconf)
  list(APPEND ffmpeg_env ${pkgconf})
endif()
if(pkgconf_path)
  list(APPEND ffmpeg_env ${pkgconf_path})
endif()

include(ExternalProject)

find_program(FFMPEG_BASH_EXECUTABLE NAMES bash bash.exe REQUIRED)

externalproject_add(ffmpeg
                    SOURCE_DIR ${CMAKE_SOURCE_DIR}
                    CONFIGURE_COMMAND ${ffmpeg_env} ${FFMPEG_BASH_EXECUTABLE} <SOURCE_DIR>/configure
                      --prefix=${CMAKE_INSTALL_PREFIX}
                      --extra-version="kodi-${FFMPEG_VER}"
                      ${ffmpeg_conf}
                    BUILD_COMMAND ${MAKE_COMMAND})

install(CODE "Message(Done)")

# Quell warnings
set(BUILD_SHARED_LIBS)
set(XBMC_BUILD_DIR)
set(KODI_BUILD_DIR)
