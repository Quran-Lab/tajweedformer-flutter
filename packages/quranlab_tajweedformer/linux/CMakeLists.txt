# TajweedFormer for Flutter on Linux: the C SDK (tajweedformer-c) and Quran Lab's Core, in the app bundle's lib/.
#
# The Dart side calls the C SDK through dart:ffi (lib/src/ffi). The C SDK's release has no Linux library yet, so
# this builds libtajweedformer.so from the C SDK's public source at EXACTLY the commit of its release tag, over the
# Core's published Linux x86-64 binary (qlcore.so, checked by its SHA-256), as the C SDK's README builds it. The build
# machine needs git, libcurl and OpenSSL 3 development files (Debian and Ubuntu: libcurl4-openssl-dev libssl-dev),
# and a connection the first time. It also builds the plugin's own small library
# (src/quranlab_tajweedformer_shim.c: what the plugin keeps for the process across a Dart hot restart).
#
# QURANLAB_C_SDK=<folder> in the environment takes libtajweedformer.so and qlcore.so from that folder instead (a
# prebuilt library, a Core under test).
cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "quranlab_tajweedformer")
project(${PROJECT_NAME} LANGUAGES C CXX)

set(QURANLAB_C_SDK_VERSION "4.0.3")
# the release tag 4.0.3 of github.com/Quran-Lab/tajweedformer-c
set(QURANLAB_C_SDK_COMMIT "87387c114df8810bc59bdfabfaab35fe40ead85f")
set(QURANLAB_CORE_URL "https://cdn.quranlab.ai/sdk/native/${QURANLAB_C_SDK_VERSION}/qlcore-${QURANLAB_C_SDK_VERSION}-linux-x64.tar.gz")
set(QURANLAB_CORE_SHA256 "9b261784fafcd003f4cda78b048624b7d799424f152537f95f28f3de032de566")

if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64|amd64")
  message(FATAL_ERROR "quranlab_tajweedformer: the C SDK and the Core run on Linux x86-64 only")
endif()

add_library(quranlab_tajweedformer_shim SHARED "${CMAKE_CURRENT_SOURCE_DIR}/../src/quranlab_tajweedformer_shim.c")
set_target_properties(quranlab_tajweedformer_shim PROPERTIES OUTPUT_NAME "quranlab_tajweedformer_shim")

if(DEFINED ENV{QURANLAB_C_SDK} AND NOT "$ENV{QURANLAB_C_SDK}" STREQUAL "")
  set(dir "$ENV{QURANLAB_C_SDK}")
  foreach(so libtajweedformer.so qlcore.so)
    if(NOT EXISTS "${dir}/${so}")
      message(FATAL_ERROR "quranlab_tajweedformer: ${dir} has no ${so}")
    endif()
  endforeach()
  set(quranlab_tajweedformer_bundled_libraries
    $<TARGET_FILE:quranlab_tajweedformer_shim> "${dir}/libtajweedformer.so" "${dir}/qlcore.so" PARENT_SCOPE)
  return()
endif()

# the Core, checked: the archive is kept and its SHA-256 checked again at every configure, and each version has its
# own folder, so a pin moved by a plugin update never bundles the Core of the version before
set(core_archive "${CMAKE_CURRENT_BINARY_DIR}/qlcore-${QURANLAB_C_SDK_VERSION}-linux-x64.tar.gz")
set(core_dir "${CMAKE_CURRENT_BINARY_DIR}/qlcore-${QURANLAB_C_SDK_VERSION}")
if(EXISTS "${core_archive}")
  file(SHA256 "${core_archive}" have)
  if(NOT have STREQUAL QURANLAB_CORE_SHA256)
    file(REMOVE "${core_archive}")
    file(REMOVE_RECURSE "${core_dir}")
  endif()
endif()
if(NOT EXISTS "${core_archive}")
  file(DOWNLOAD "${QURANLAB_CORE_URL}" "${core_archive}" EXPECTED_HASH SHA256=${QURANLAB_CORE_SHA256} TLS_VERIFY ON
       STATUS status)
  list(GET status 0 code)
  if(NOT code EQUAL 0)
    message(FATAL_ERROR "quranlab_tajweedformer: the Core ${QURANLAB_C_SDK_VERSION} could not be downloaded (${status}) "
                        "from ${QURANLAB_CORE_URL}")
  endif()
  file(REMOVE_RECURSE "${core_dir}")
endif()
if(NOT EXISTS "${core_dir}/qlcore.so")
  file(ARCHIVE_EXTRACT INPUT "${core_archive}" DESTINATION "${core_dir}")
endif()

# the C SDK's library, from its release commit, built on its own (its CMake, its flags): only the library target
include(ExternalProject)
set(c_sdk_build "${CMAKE_CURRENT_BINARY_DIR}/tajweedformer-c-${QURANLAB_C_SDK_VERSION}-build")
ExternalProject_Add(quranlab_tajweedformer_c
  GIT_REPOSITORY "https://github.com/Quran-Lab/tajweedformer-c.git"
  GIT_TAG "${QURANLAB_C_SDK_COMMIT}"
  GIT_SHALLOW OFF
  UPDATE_DISCONNECTED ON
  PREFIX "${CMAKE_CURRENT_BINARY_DIR}/tajweedformer-c-${QURANLAB_C_SDK_VERSION}"
  BINARY_DIR "${c_sdk_build}"
  CMAKE_ARGS -DCMAKE_BUILD_TYPE=Release "-DQLCORE_DIR=${core_dir}" "-DCMAKE_C_COMPILER=${CMAKE_C_COMPILER}"
  BUILD_COMMAND ${CMAKE_COMMAND} --build "${c_sdk_build}" --target tajweedformer
  INSTALL_COMMAND ""
  BUILD_BYPRODUCTS "${c_sdk_build}/libtajweedformer.so"
)
add_dependencies(quranlab_tajweedformer_shim quranlab_tajweedformer_c)

# What Flutter copies into the bundle's lib/ (libtajweedformer.so finds qlcore.so beside it: its rpath is $ORIGIN).
set(quranlab_tajweedformer_bundled_libraries
  $<TARGET_FILE:quranlab_tajweedformer_shim>
  "${c_sdk_build}/libtajweedformer.so"
  "${core_dir}/qlcore.so"
  PARENT_SCOPE
)
