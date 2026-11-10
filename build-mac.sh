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
# ./build-mac.sh --install kopiert die App nach /Applications. Liegt neben dem Skript eine Datei .sign-identity
# (eine Zeile: Name oder SHA-1 eines eigenen Signatur-Zertifikats), wird nur diese installierte Kopie damit signiert –
# sonst fragt der Schlüsselbund nach jedem neuen Bau wieder nach dem Passwort. Das Zip bleibt ad hoc und ohne Namen.
if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/HomeThread.app
  ditto build-mac/HomeThread.app /Applications/HomeThread.app
  if [ -s "${SIGN_IDENTITY_FILE:-.sign-identity}" ]; then
    codesign -f -s "$(head -1 "${SIGN_IDENTITY_FILE:-.sign-identity}")" /Applications/HomeThread.app
    codesign --verify --strict /Applications/HomeThread.app
  fi
  echo "Installiert: /Applications/HomeThread.app"
fi
echo "Fertig: build-mac/HomeThread.app (+ HomeThread-mac.zip)"
