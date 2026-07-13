#!/bin/bash
# Build Dropper, install it to /Applications, and relaunch it.
set -euo pipefail
cd "$(dirname "$0")"

make bundle

# Kill any running copy — graceful quit first, then force.
osascript -e 'quit app "Dropper"' 2>/dev/null || true
sleep 1
pkill -x Dropper 2>/dev/null || true
sleep 0.5

rm -rf /Applications/Dropper.app
cp -R build/Dropper.app /Applications/
open /Applications/Dropper.app

echo "Dropper installed and relaunched."
