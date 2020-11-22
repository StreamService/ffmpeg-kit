#!/bin/bash

# ALWAYS CLEAN THE PREVIOUS BUILD
make distclean 2>/dev/null 1>/dev/null

# REGENERATE BUILD FILES IF NECESSARY OR REQUESTED
if [[ ! -f "${BASEDIR}"/src/"${LIB_NAME}"/configure ]] || [[ ${RECONF_harfbuzz} -eq 1 ]]; then
  NOCONFIGURE=1 ./autogen.sh || return 1
fi

./configure \
  --prefix="${LIB_INSTALL_PREFIX}" \
  --with-pic \
  --with-sysroot="${ANDROID_SYSROOT}" \
  --with-glib=no \
  --with-fontconfig=yes \
  --with-freetype=yes \
  --enable-static \
  --disable-shared \
  --disable-fast-install \
  --host="${HOST}" || return 1

make -j$(get_cpu_count) || return 1

make install || return 1

# MANUALLY COPY PKG-CONFIG FILES
cp ./src/harfbuzz.pc "${INSTALL_PKG_CONFIG_DIR}" || return 1

# WORKAROUND TO REMOVE INSTALLED .la FILES
rm -f "${LIB_INSTALL_PREFIX}"/lib/*.la
