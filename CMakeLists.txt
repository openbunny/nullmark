# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.28)
project(nullmark LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(NULLMARK_COVERAGE "Instrument the corpus runner for gcov coverage" OFF)

include(ExternalProject)
find_program(MAKE make REQUIRED)
cmake_host_system_information(RESULT NPROC QUERY NUMBER_OF_LOGICAL_CORES)
set(MUPDF_PREFIX "${CMAKE_BINARY_DIR}/mupdf")
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
file(MAKE_DIRECTORY "${MUPDF_PREFIX}/include")
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
add_library(mupdf-third STATIC IMPORTED)
set_target_properties(mupdf-third PROPERTIES
  IMPORTED_LOCATION "${MUPDF_PREFIX}/lib/libmupdf-third.a")
add_library(mupdf STATIC IMPORTED)
set_target_properties(mupdf PROPERTIES
  IMPORTED_LOCATION "${MUPDF_PREFIX}/lib/libmupdf.a"
  INTERFACE_INCLUDE_DIRECTORIES "${MUPDF_PREFIX}/include"
  INTERFACE_LINK_LIBRARIES mupdf-third)
add_dependencies(mupdf mupdf-source)

set(CORPUS "${CMAKE_SOURCE_DIR}/CTask4PDF/fuzz/corpus")
set(SOURCES CTask4PDF/task4pdf.c)
set(INCLUDES CTask4PDF/include)

if(NULLMARK_COVERAGE)
  add_executable(corpus-coverage CTask4PDF/fuzz/fuzz_t4_replace.c ${SOURCES})
  target_include_directories(corpus-coverage PRIVATE ${INCLUDES})
  target_compile_options(corpus-coverage PRIVATE --coverage -fsanitize=fuzzer)
  target_link_options(corpus-coverage PRIVATE --coverage -fsanitize=fuzzer)
  target_link_libraries(corpus-coverage PRIVATE mupdf)
  enable_testing()
  add_test(NAME corpus-coverage COMMAND corpus-coverage -runs=0 ${CORPUS})
  return()
endif()

add_executable(nullmark-cli ${SOURCES})
target_include_directories(nullmark-cli PRIVATE ${INCLUDES})
target_compile_definitions(nullmark-cli PRIVATE T4_MAIN _FORTIFY_SOURCE=2)
target_compile_options(nullmark-cli PRIVATE
  -Wall -Wextra -Wpedantic -Werror -O2 -fstack-protector-strong -fPIE)
target_link_libraries(nullmark-cli PRIVATE mupdf)

add_library(fake-task4pdf OBJECT AppTests/Support/fake_task4pdf.c)
target_include_directories(fake-task4pdf PRIVATE ${INCLUDES})

# The fuzz build is also the sanitizer gate: ASan, UBSan and LeakSanitizer
# together over the seed corpus and every input libFuzzer derives from it.
set(SANITIZERS -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=undefined)
add_executable(fuzz-t4-replace CTask4PDF/fuzz/fuzz_t4_replace.c ${SOURCES})
target_include_directories(fuzz-t4-replace PRIVATE ${INCLUDES})
target_compile_options(fuzz-t4-replace PRIVATE -g -O1 ${SANITIZERS})
target_link_options(fuzz-t4-replace PRIVATE ${SANITIZERS})
target_link_libraries(fuzz-t4-replace PRIVATE mupdf)

enable_testing()
find_program(UV uv REQUIRED)
add_test(NAME pytest COMMAND ${UV} run --frozen pytest
  WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}/tests")
set_tests_properties(pytest PROPERTIES
  ENVIRONMENT "NULLMARK_CLI=$<TARGET_FILE:nullmark-cli>")

# -rss_limit_mb=0 stops libFuzzer starting its RSS monitor thread, which
# LeakSanitizer reports as a leak at exit; -malloc_limit_mb keeps the
# allocation cap the RSS limit otherwise sets.
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/fuzz-corpus")
add_test(NAME fuzz COMMAND fuzz-t4-replace
  "${CMAKE_BINARY_DIR}/fuzz-corpus" ${CORPUS}
  "-dict=${CMAKE_SOURCE_DIR}/CTask4PDF/fuzz/pdf.dict"
  -max_total_time=60 -rss_limit_mb=0 -malloc_limit_mb=4096
  "-artifact_prefix=${CMAKE_SOURCE_DIR}/CTask4PDF/fuzz/")
set_tests_properties(fuzz PROPERTIES ENVIRONMENT "ASAN_OPTIONS=detect_leaks=1")
