#!/usr/bin/env bash
# Pinned toolchain for ios-testflight.yml: exact Xcode (fail if absent),
# checksum-pinned XcodeGen, then the existing icon generator.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

: "${XCODE_VERSION:?}" "${XCODEGEN_VERSION:?}" "${XCODEGEN_SHA256:?}"

XCODE_APP="/Applications/Xcode_${XCODE_VERSION}.app"
if [[ ! -d "$XCODE_APP" ]]; then
    echo "::error::Pinned Xcode ${XCODE_VERSION} is not installed on this runner image (${XCODE_APP})."
    ls -d /Applications/Xcode*.app 2>/dev/null || true
    exit 1
fi
sudo xcode-select -s "$XCODE_APP/Contents/Developer"
ACTUAL="$(xcodebuild -version | awk '/^Xcode /{print $2}')"
if [[ "$ACTUAL" != "$XCODE_VERSION" && "$ACTUAL" != "$XCODE_VERSION".* ]] || (( ${ACTUAL%%.*} < 26 )); then
    echo "::error::Selected Xcode reports ${ACTUAL}; expected ${XCODE_VERSION} (>= 26)."
    exit 1
fi
echo "Xcode ${ACTUAL}, iOS SDK $(xcrun --sdk iphoneos --show-sdk-version)"

# Export keys the workflow relies on must exist in this Xcode's help text.
HELP="$(xcodebuild -help 2>&1)"
for KEY in app-store-connect manageAppVersionAndBuildNumber testFlightInternalTestingOnly; do
    if [[ "$HELP" != *"$KEY"* ]]; then
        echo "::error::xcodebuild -help does not document export option '${KEY}'."
        exit 1
    fi
done

TOOLS=".build-testflight/tools"
mkdir -p "$TOOLS"
curl -fsSL -o "$TOOLS/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
echo "${XCODEGEN_SHA256}  $TOOLS/xcodegen.zip" | shasum -a 256 -c -
unzip -q -o "$TOOLS/xcodegen.zip" -d "$TOOLS"
XCODEGEN="$PWD/$TOOLS/xcodegen/bin/xcodegen"
"$XCODEGEN" --version
echo "XCODEGEN=$XCODEGEN" >> "${GITHUB_ENV:-/dev/null}"

# ponytail: ImageMagick comes from Homebrew unpinned (same as ios.yml); pin a bottle if icon output ever drifts.
command -v magick >/dev/null || brew install imagemagick
./scripts/genicons
