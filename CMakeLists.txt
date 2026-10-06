# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.28)
project(nullmark LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(NULLMARK_COVERAGE "Instrument the corpus runner for gcov coverage" OFF)

find_path(MUPDF_INCLUDE_DIR mupdf/fitz.h REQUIRED)
find_library(MUPDF_LIBRARY mupdf REQUIRED)
add_library(mupdf UNKNOWN IMPORTED)
set_target_properties(mupdf PROPERTIES
  IMPORTED_LOCATION "${MUPDF_LIBRARY}"
  INTERFACE_INCLUDE_DIRECTORIES "${MUPDF_INCLUDE_DIR}")
get_filename_component(MUPDF_LIBRARY_DIR "${MUPDF_LIBRARY}" DIRECTORY)
set(CMAKE_BUILD_RPATH "${MUPDF_LIBRARY_DIR}")

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
