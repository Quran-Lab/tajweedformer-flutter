# TajweedFormer for Flutter on Windows: the C SDK (tajweedformer-c) and Quran Lab's Core, beside the app's program.
#
# The Dart side calls the C SDK through dart:ffi (lib/src/ffi). This file bundles the C SDK's release for Windows x64
# (tajweedformer.dll, the Core qlcore.dll and its thread library libwinpthread-1.dll), EXACTLY this version, checked
# by its SHA-256, and builds the plugin's own small library (src/quranlab_tajweedformer_shim.c: what the plugin keeps
# for the process across a Dart hot restart). Change the version only together with the plugin's checks against the
# new release (src/tajweedformer.h is that release's header; lib/src/ffi/tajweedformer.g.dart is generated from it).
#
# QURANLAB_C_SDK=<folder> in the environment takes the three DLLs from that folder instead (a release before it is
# published, or a Core under test).
cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "quranlab_tajweedformer")
project(${PROJECT_NAME} LANGUAGES C CXX)

set(QURANLAB_C_SDK_VERSION "4.0.3")
set(QURANLAB_C_SDK_SHA256 "438934b90fb6fddfd2a60299e4e713371abd7696849d06c208699114733e9afa")
set(QURANLAB_C_SDK_URL
    "https://github.com/Quran-Lab/tajweedformer-c/releases/download/${QURANLAB_C_SDK_VERSION}/tajweedformer-${QURANLAB_C_SDK_VERSION}-windows-x64.zip")

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8 OR CMAKE_GENERATOR_PLATFORM MATCHES "ARM" OR CMAKE_SYSTEM_PROCESSOR MATCHES "ARM")
  message(FATAL_ERROR "quranlab_tajweedformer: the C SDK and the Core run on Windows x64 only")
endif()

if(DEFINED ENV{QURANLAB_C_SDK} AND NOT "$ENV{QURANLAB_C_SDK}" STREQUAL "")
  file(TO_CMAKE_PATH "$ENV{QURANLAB_C_SDK}" QURANLAB_C_SDK_DIR)
else()
  set(archive "${CMAKE_CURRENT_BINARY_DIR}/tajweedformer-${QURANLAB_C_SDK_VERSION}-windows-x64.zip")
  if(EXISTS "${archive}")
    file(SHA256 "${archive}" have)
    if(NOT have STREQUAL QURANLAB_C_SDK_SHA256)
      file(REMOVE "${archive}")
    endif()
  endif()
  if(NOT EXISTS "${archive}")
    file(DOWNLOAD "${QURANLAB_C_SDK_URL}" "${archive}" EXPECTED_HASH SHA256=${QURANLAB_C_SDK_SHA256} TLS_VERIFY ON
         STATUS status)
    list(GET status 0 code)
    if(NOT code EQUAL 0)
      message(FATAL_ERROR "quranlab_tajweedformer: the C SDK ${QURANLAB_C_SDK_VERSION} could not be downloaded "
                          "(${status}) from ${QURANLAB_C_SDK_URL}")
    endif()
  endif()
  file(ARCHIVE_EXTRACT INPUT "${archive}" DESTINATION "${CMAKE_CURRENT_BINARY_DIR}/c_sdk")
  set(QURANLAB_C_SDK_DIR "${CMAKE_CURRENT_BINARY_DIR}/c_sdk/tajweedformer-${QURANLAB_C_SDK_VERSION}-windows-x64")
endif()

foreach(dll tajweedformer.dll qlcore.dll libwinpthread-1.dll)
  if(NOT EXISTS "${QURANLAB_C_SDK_DIR}/${dll}")
    message(FATAL_ERROR "quranlab_tajweedformer: ${QURANLAB_C_SDK_DIR} has no ${dll}")
  endif()
endforeach()

add_library(quranlab_tajweedformer_shim SHARED "${CMAKE_CURRENT_SOURCE_DIR}/../src/quranlab_tajweedformer_shim.c")
set_target_properties(quranlab_tajweedformer_shim PROPERTIES OUTPUT_NAME "quranlab_tajweedformer_shim")

# What Flutter copies beside the app's program.
set(quranlab_tajweedformer_bundled_libraries
  $<TARGET_FILE:quranlab_tajweedformer_shim>
  "${QURANLAB_C_SDK_DIR}/tajweedformer.dll"
  "${QURANLAB_C_SDK_DIR}/qlcore.dll"
  "${QURANLAB_C_SDK_DIR}/libwinpthread-1.dll"
  PARENT_SCOPE
)
