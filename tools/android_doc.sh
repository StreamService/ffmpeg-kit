#!/bin/bash
#
# Generates docs for Android library
#

CURRENT_DIR="`pwd`"

cd "${CURRENT_DIR}"/../android/ffmpeg-kit-android-lib

doxygen
