#!/bin/zsh
# Build sonos-stereo. The Info.plist is embedded so macOS can ask for Bluetooth access.
# After rebuilding, run "./sonos-stereo install" again. macOS may ask for Accessibility
# again too, because a rebuilt binary counts as a new app.
set -e
cd "${0:A:h}"
swiftc -O sonos-stereo.swift -o sonos-stereo \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
codesign --force --sign - --identifier local.sonos-stereo sonos-stereo
echo "built ./sonos-stereo"
