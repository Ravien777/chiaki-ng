#!/bin/bash

set -xe

if [ "$(uname -m)" = "aarch64" ]
then
    export GCC_STRING="gcc_arm64"
else
    export GCC_STRING="gcc_64"
fi

export QT_DIR="$(find ${QT_PATH} -maxdepth 1 -type d -name "${QT_VERSION}")"
export PATH="${QT_DIR}/${GCC_STRING}/bin:$PATH"
if [ -f "${HOME}/chiaki-venv/bin/activate" ]
then
   source "${HOME}/chiaki-venv/bin/activate"
fi

# sometimes there are errors in linuxdeploy in docker/podman when the appdir is on a mount
appdir=${1:-`pwd`/appimage/appdir}

rm -rf appimage && mkdir -p appimage

scripts/fetch-protoc.sh appimage
export PATH="`pwd`/appimage/protoc/bin:$PATH"
scripts/build-ffmpeg.sh appimage
scripts/build-sdl2-compat.sh appimage
scripts/build-libplacebo.sh appimage
scripts/build-hidapi.sh appimage

rm -rf build_appimage && mkdir -p build_appimage
cd build_appimage 
qt-cmake \
	-GNinja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCHIAKI_ENABLE_TESTS=ON \
	-DCHIAKI_ENABLE_GUI=ON \
	-DCHIAKI_GUI_ENABLE_SDL_GAMECONTROLLER=ON \
	-DCMAKE_INSTALL_PREFIX=/usr \
	..
cd ..

# purge leftover proto/nanopb_pb2.py which may have been created with another protobuf version
rm -fv third-party/nanopb/generator/proto/nanopb_pb2.py

ninja -C build_appimage
build_appimage/test/chiaki-unit

DESTDIR="${appdir}" ninja -C build_appimage install

# linuxdeploy does not reliably pick up libSDL3 when it is only required through
# the packaged sdl2-compat shim. Stage both SDL runtimes explicitly so the
# resulting AppImage can load the controller backend without host SDL3.
mkdir -p "${appdir}/usr/lib"
shopt -s nullglob
SDL_LIB_DIRS=(
    "$(pwd)"/appimage/SDL3-*/build
    "$(pwd)"/appimage/sdl2-compat-*/build
)
shopt -u nullglob
if [ "${#SDL_LIB_DIRS[@]}" -eq 0 ]; then
    echo "Failed to locate SDL build directories for AppImage staging" >&2
    exit 1
fi
while IFS= read -r -d '' sdl_lib; do
    cp -a "${sdl_lib}" "${appdir}/usr/lib/"
done < <(find "${SDL_LIB_DIRS[@]}" \
    -type f,l \
    \( -name 'libSDL2*.so*' -o -name 'libSDL3*.so*' \) \
    -print0 2>/dev/null)

# The PSN token dialog creates its WebEngineView dynamically via
# Qt.createQmlObject(), so qmlimportscanner cannot detect the QtWebEngine QML
# import and linuxdeploy-plugin-qt never bundles the module. Stage the plugin
# and its locale resources explicitly so PSN login works in the AppImage.
mkdir -p "${appdir}/usr/qml" "${appdir}/usr/translations"
cp -a "${QT_DIR}/${GCC_STRING}/qml/QtWebEngine" "${appdir}/usr/qml/"
if [ -d "${QT_DIR}/${GCC_STRING}/translations/qtwebengine_locales" ]; then
    cp -a "${QT_DIR}/${GCC_STRING}/translations/qtwebengine_locales" "${appdir}/usr/translations/"
fi

cd appimage

export ARCH="$(uname -m)"
curl -L -O https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${ARCH}.AppImage
chmod +x linuxdeploy-${ARCH}.AppImage

export LD_LIBRARY_PATH="${QT_DIR}/${GCC_STRING}/lib:$(pwd)/../build_appimage/third-party/cpp-steam-tools:$LD_LIBRARY_PATH"
export QML_SOURCES_PATHS="$(pwd)/../gui/src/qml"
export EXTRA_QT_MODULES="waylandclient;waylandcompositor"
export EXTRA_PLATFORM_PLUGINS="libqwayland-egl.so;libqwayland-generic.so;libqeglfs.so;libqminimal.so;libqminimalegl.so;libqvkkhrdisplay.so;libqvnc.so;libqoffscreen.so;libqlinuxfb.so"
curl -L -O https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-${ARCH}.AppImage
chmod +x linuxdeploy-plugin-qt-${ARCH}.AppImage
# First let linuxdeploy-plugin-qt deploy the Qt runtime (QML modules, plugins,
# translations). It deploys a partial NSS/nspr stack as a dependency of
# QtWebEngineCore even when excluded, so that is removed afterwards.
./linuxdeploy-${ARCH}.AppImage \
    --appdir="${appdir}" \
    -e "${appdir}/usr/bin/chiaki" \
    -d "${appdir}/usr/share/applications/chiaking.desktop" \
    --plugin qt

# Chromium (QtWebEngine) dlopens system NSS modules (e.g. libsoftokn3) at
# runtime. Bundling only a part of the NSS/nspr stack mixes symbol versions
# with the host's remaining modules and crashes WebEngine on hosts with newer
# system NSS, so leave the whole stack to the host and repack without the Qt
# plugin, which honors the library exclusions.
rm -f "${appdir}"/usr/lib/libnss3.so* \
      "${appdir}"/usr/lib/libnssutil3.so* \
      "${appdir}"/usr/lib/libsmime3.so* \
      "${appdir}"/usr/lib/libnspr4.so* \
      "${appdir}"/usr/lib/libplc4.so* \
      "${appdir}"/usr/lib/libplds4.so*

./linuxdeploy-${ARCH}.AppImage \
    --appdir="${appdir}" \
    -e "${appdir}/usr/bin/chiaki" \
    -d "${appdir}/usr/share/applications/chiaking.desktop" \
    --exclude-library='libva*' \
    --exclude-library='libvulkan*' \
    --exclude-library='libnss3*' \
    --exclude-library='libnssutil3*' \
    --exclude-library='libsmime3*' \
    --exclude-library='libnspr4*' \
    --exclude-library='libplc4*' \
    --exclude-library='libplds4*' \
    --output appimage
mv chiaki-ng-${ARCH}.AppImage chiaki-ng.AppImage
