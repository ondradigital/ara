#!/bin/bash
# Builds the Release version, installs it to /Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -project Ara.xcodeproj -scheme Ara -configuration Release -derivedDataPath build -quiet build

pkill -x Ara || true
rm -rf /Applications/Ara.app
ditto build/Build/Products/Release/Ara.app /Applications/Ara.app
open /Applications/Ara.app
