#!/bin/bash
# Baut die Mac-App (Release, ad-hoc signiert) nach build-mac/HomeThread.app und packt sie als Zip.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate -q
rm -rf build-mac
xcodebuild -project HomeThread.xcodeproj -scheme HomeThreadMac -configuration Release -derivedDataPath build-mac/dd \
  CODE_SIGN_IDENTITY="-" OTHER_SWIFT_FLAGS="-file-prefix-map $PWD=." OTHER_CFLAGS="-ffile-prefix-map=$PWD=." \
  STRIP_INSTALLED_PRODUCT=YES DEPLOYMENT_POSTPROCESSING=YES STRIP_STYLE=non-global -quiet build
cp -R build-mac/dd/Build/Products/Release/HomeThread.app build-mac/
rm -rf build-mac/dd
if grep -raqiF -e "$USER" -e "$HOME" build-mac/HomeThread.app; then
  echo "FEHLER: Benutzername oder Home-Pfad in der App – aus einem neutralen Ordner bauen."; exit 1
fi
(cd build-mac && ditto -c -k --keepParent HomeThread.app HomeThread-mac.zip)
echo "Fertig: build-mac/HomeThread.app (+ HomeThread-mac.zip)"
