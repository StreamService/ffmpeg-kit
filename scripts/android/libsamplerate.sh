#!/bin/bash

# ALWAYS CLEAN THE PREVIOUS BUILD
make distclean 2>/dev/null 1>/dev/null

# REGENERATE BUILD FILES IF NECESSARY OR REQUESTED
if [[ ! -f "${BASEDIR}"/src/"${LIB_NAME}"/configure ]] || [[ ${RECONF_libsamplerate} -eq 1 ]]; then
  autoreconf_library "${LIB_NAME}" 1>>"${BASEDIR}"/build.log 2>&1 || return 1
fi

./configure \
  --prefix="${LIB_INSTALL_PREFIX}" \
  --with-pic \
  --with-sysroot="${ANDROID_SYSROOT}" \
  --enable-static \
  --disable-alsa \
  --disable-fftw \
  --disable-shared \
  --disable-fast-install \
  --host="${HOST}" || return 1

# WORKAROUND TO DISABLE BUILDING OF EXAMPLES AND TESTS
${SED_INLINE} 's/^examples_/#examples_/g' "${BASEDIR}"/src/"${LIB_NAME}"/Makefile || return 1
${SED_INLINE} 's/^tests_/#tests_/g' "${BASEDIR}"/src/"${LIB_NAME}"/Makefile || return 1

make -j$(get_cpu_count) || return 1

make install || return 1

# MANUALLY COPY PKG-CONFIG FILES
cp ./*.pc "${INSTALL_PKG_CONFIG_DIR}" || return 1
