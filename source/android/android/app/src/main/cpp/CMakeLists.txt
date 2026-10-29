cmake_minimum_required(VERSION 3.22.1)
project(yingyu_disc LANGUAGES C CXX)
set(BD ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../dependencies/bluray/libbluray-1.3.4)
set(CMAKE_C_STANDARD 99)
set(CMAKE_CXX_STANDARD 17)
# Unmodified VideoLAN release sources, included by our metadata-only wrapper.
file(GLOB BD_NAV ${BD}/src/libbluray/bdnav/*.c)
file(GLOB BD_DEC ${BD}/src/libbluray/decoders/*.c)
file(GLOB BD_DISC ${BD}/src/libbluray/disc/*.c)
file(GLOB BD_HDMV ${BD}/src/libbluray/hdmv/*.c)
file(GLOB BD_UTIL ${BD}/src/util/*.c)
add_library(yingyu_disc SHARED disc_jni.cpp disc_direct.cpp
  disc_bluray.c ${BD}/src/libbluray/register.c
  bdj_disabled.c ${BD}/src/libbluray/bdj/bdjo_parse.c
  ${BD_NAV} ${BD_DEC} ${BD_DISC} ${BD_HDMV} ${BD_UTIL}
  ${BD}/src/file/file.c ${BD}/src/file/filesystem.c
  ${BD}/src/file/dir_posix.c ${BD}/src/file/file_posix.c
  ${BD}/src/file/dirs_xdg.c ${BD}/src/file/dl_posix.c ${BD}/src/file/mount.c
  ${BD}/contrib/libudfread/src/default_blockinput.c
  ${BD}/contrib/libudfread/src/ecma167.c
  ${BD}/contrib/libudfread/src/udfread.c)
set(BLURAY_VERSION_MAJOR 1)
set(BLURAY_VERSION_MINOR 3)
set(BLURAY_VERSION_MICRO 4)
configure_file(${BD}/src/libbluray/bluray-version.h.in ${CMAKE_CURRENT_BINARY_DIR}/bluray-version.h @ONLY)
target_include_directories(yingyu_disc PRIVATE . ${CMAKE_CURRENT_BINARY_DIR} ${BD}/src
  ${BD}/src/libbluray ${BD}/contrib/libudfread/src)
target_compile_definitions(yingyu_disc PRIVATE HAVE_CONFIG_H=1 _FILE_OFFSET_BITS=64 _POSIX_C_SOURCE=200809L)
target_compile_options(yingyu_disc PRIVATE -fvisibility=hidden -g)
target_link_options(yingyu_disc PRIVATE -Wl,-z,max-page-size=16384 -Wl,--build-id=sha1)
target_link_libraries(yingyu_disc PRIVATE dl log)
