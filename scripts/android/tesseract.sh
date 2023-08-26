#!/bin/bash

# UPDATE BUILD FLAGS
PKG_CONFIG_PATH=${INSTALL_PKG_CONFIG_DIR}
export LEPTONICA_CFLAGS=" $(pkg-config --cflags lept 2>>"${BASEDIR}"/build.log)"
export LEPTONICA_LIBS=" $(pkg-config --libs lept 2>>"${BASEDIR}"/build.log)"

# ALWAYS CLEAN THE PREVIOUS BUILD
make distclean 2>/dev/null 1>/dev/null

# REGENERATE BUILD FILES IF NECESSARY OR REQUESTED
if [[ ! -f "${BASEDIR}"/src/"${LIB_NAME}"/configure ]] || [[ ${RECONF_tesseract} -eq 1 ]]; then
  ./autogen.sh 1>>"${BASEDIR}"/build.log 2>&1 || return 1
fi

# WORKAROUND TO MANUALLY SET ENDIANNESS
export ac_cv_c_bigendian=no

./configure \
  --prefix="${LIB_INSTALL_PREFIX}" \
  --with-pic \
  --without-tensorflow \
  --without-curl \
  --without-archive \
  --enable-static \
  --disable-shared \
  --disable-fast-install \
  --disable-debug \
  --disable-graphics \
  --disable-openmp \
  --disable-tessdata-prefix \
  --host="${HOST}" || return 1

make -j$(get_cpu_count) || return 1

make install || return 1

# CREATE PACKAGE CONFIG MANUALLY
create_tesseract_package_config "5.3.2" || return 1
