#!/bin/sh
# The iOS side of this plugin is built from the iOS SDK's own sources, copied into the plugin so it is one self-contained package.
# Run it after changing sdk/ios.
set -e
here="$(cd "$(dirname "$0")/.." && pwd)"
from="$here/../../ios/Sources"
to="$here/ios/zapiack/Sources/zapiack/Zapiack"
rm -rf "$to"
mkdir -p "$to"
for f in "$from"/ZapiackCore/*.swift "$from"/ZapiackPush/*.swift; do
  # One module here, so the imports between the SDK's targets and its re-exported names are dropped.
  grep -v -e '^import ZapiackCore$' -e '^public typealias ' "$f" > "$to/$(basename "$f")"
done
echo "copied $(ls "$to" | wc -l | tr -d ' ') files"
