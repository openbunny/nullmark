# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.28)
project(nullmark-mupdf LANGUAGES NONE)

include(ExternalProject)
find_program(MAKE make REQUIRED)
cmake_host_system_information(RESULT NPROC QUERY NUMBER_OF_LOGICAL_CORES)
set(MUPDF_PREFIX "${CMAKE_SOURCE_DIR}/../build/mupdf" CACHE PATH
  "Install prefix of the static MuPDF build that every other build consumes")
cmake_path(NORMAL_PATH MUPDF_PREFIX OUTPUT_VARIABLE MUPDF_PREFIX)
# Reason: MuPDF's Makefile links OpenSSL, X11 and GLUT when pkg-config finds
# them, which would put a Homebrew dylib back on the link line of a static
# build. The core uses none of them.
set(MUPDF_MAKE_ARGS build=release HAVE_LIBCRYPTO=no HAVE_X11=no HAVE_GLUT=no)
set(MUPDF_VERSION 1.28.5)
ExternalProject_Add(mupdf-source
  URL https://mupdf.com/downloads/archive/mupdf-${MUPDF_VERSION}-source.tar.gz
  URL_HASH SHA256=98a5c10cda20c3992cdf76ff6b2a1149c32bd79cc796d3f703230b1185b7e934
  DOWNLOAD_EXTRACT_TIMESTAMP ON
  BUILD_IN_SOURCE ON
  INSTALL_DIR "${MUPDF_PREFIX}"
  CONFIGURE_COMMAND ""
  BUILD_COMMAND ${CMAKE_COMMAND} -E env
    MACOSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}
    ${MAKE} -j${NPROC} ${MUPDF_MAKE_ARGS} libs
  INSTALL_COMMAND ${MAKE} ${MUPDF_MAKE_ARGS} prefix=<INSTALL_DIR> install-libs
  BUILD_BYPRODUCTS
    "${MUPDF_PREFIX}/lib/libmupdf.a"
    "${MUPDF_PREFIX}/lib/libmupdf-third.a")
set(MUPDF_LICENSE_FILES
  mupdf:COPYING
  brotli:thirdparty/brotli/LICENSE
  cmark-gfm:thirdparty/cmark-gfm/COPYING
  extract:thirdparty/extract/COPYING
  freetype:thirdparty/freetype/LICENSE.TXT
  freetype:thirdparty/freetype/docs/FTL.TXT
  gumbo-parser:thirdparty/gumbo-parser/COPYING
  harfbuzz:thirdparty/harfbuzz/COPYING
  jbig2dec:thirdparty/jbig2dec/COPYING
  jbig2dec:thirdparty/jbig2dec/LICENSE
  lcms2:thirdparty/lcms2/LICENSE
  libjpeg:thirdparty/libjpeg/README
  mujs:thirdparty/mujs/COPYING
  openjpeg:thirdparty/openjpeg/LICENSE
  zlib:thirdparty/zlib/LICENSE)
set(MUPDF_LICENSE_COMMANDS)
foreach(entry IN LISTS MUPDF_LICENSE_FILES)
  string(REPLACE ":" ";" parts "${entry}")
  list(GET parts 0 name)
  list(GET parts 1 file)
  list(APPEND MUPDF_LICENSE_COMMANDS
    COMMAND ${CMAKE_COMMAND} -E make_directory "${MUPDF_PREFIX}/licenses/${name}"
    COMMAND ${CMAKE_COMMAND} -E copy "<SOURCE_DIR>/${file}" "${MUPDF_PREFIX}/licenses/${name}/")
endforeach()
# Reason: `cmake -E copy` exits non-zero on a missing file, so a licence file
# that a MuPDF release moves or drops fails the build.
ExternalProject_Add_Step(mupdf-source install-licenses
  DEPENDEES install
  ${MUPDF_LICENSE_COMMANDS})
