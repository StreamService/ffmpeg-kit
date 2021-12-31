#!/bin/bash

# DISABLE ASM WORKAROUNDS BEFORE APPLYING THEM AGAIN
git checkout ${BASEDIR}/src/${LIB_NAME}/aom_ports 1>>"${BASEDIR}"/build.log 2>&1

# SET BUILD OPTIONS
ASM_OPTIONS=""
case ${ARCH} in
arm-v7a)
  ASM_OPTIONS="-DARCH_ARM=1 -DENABLE_NEON=0 -DHAVE_NEON=0"
  ;;
arm-v7a-neon)
  ASM_OPTIONS="-DARCH_ARM=1 -DENABLE_NEON=1 -DHAVE_NEON=1"
  ;;
arm64-v8a)
  ASM_OPTIONS="-DARCH_ARM=1 -DENABLE_NEON=1 -DHAVE_NEON=1"
  ;;
x86)
  ASM_OPTIONS="-DENABLE_SSE=1 -DHAVE_SSE=1 -DENABLE_SSE3=1 -DHAVE_SSE3=1"
  ;;
x86-64)
  ASM_OPTIONS="-DENABLE_SSE4_2=1 -DHAVE_SSE4_2=1"
  ;;
esac

mkdir -p "${BUILD_DIR}" || return 1
cd "${BUILD_DIR}" || return 1

cmake -Wno-dev \
  -DCMAKE_VERBOSE_MAKEFILE=0 \
  -DCONFIG_PIC=1 \
  -DCMAKE_C_FLAGS="${CFLAGS}" \
  -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
  -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
  -DCMAKE_SYSROOT="${ANDROID_SYSROOT}" \
  -DCMAKE_FIND_ROOT_PATH="${ANDROID_SYSROOT}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Generic \
  -DCMAKE_INSTALL_PREFIX="${LIB_INSTALL_PREFIX}" \
  -DCMAKE_CXX_COMPILER="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/${TOOLCHAIN}/bin/$CXX" \
  -DCMAKE_C_COMPILER="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/${TOOLCHAIN}/bin/$CC" \
  -DCMAKE_LINKER="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/${TOOLCHAIN}/bin/$LD" \
  -DCMAKE_AR="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/${TOOLCHAIN}/bin/$AR" \
  -DCMAKE_AS="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/${TOOLCHAIN}/bin/$AS" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=1 \
  ${ASM_OPTIONS} \
  -DENABLE_TESTS=0 \
  -DENABLE_EXAMPLES=0 \
  -DENABLE_TOOLS=0 \
  -DCONFIG_UNIT_TESTS=0 \
  -DAOM_TARGET_CPU=generic \
  -DBUILD_SHARED_LIBS=0 "${BASEDIR}"/src/"${LIB_NAME}" || return 1

make -j$(get_cpu_count) || return 1

make install || return 1

# CREATE PACKAGE CONFIG MANUALLY
create_libaom_package_config "3.2.0" || return 1
