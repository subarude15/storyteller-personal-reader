#!/usr/bin/env bash
# Generates the TestFlight-only project and archives it (signed mode also exports
# an app-store-connect IPA). No automatic provisioning or profile repair.
#   build.sh unsigned   needs MARKETING_VERSION BUILD_NUMBER APP_GROUP_ID
#   build.sh signed     also APPLE_TEAM_ID SIGNING_IDENTITY_SHA1 TF_KEYCHAIN UUID_APP UUID_WIDGETS UUID_SHARE
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

MODE="${1:-}"
PROJECT=SilveranTestFlight.xcodeproj
SCHEME="ink+amp TestFlight (iOS)"
OUT=.build-testflight
DD="$OUT/DerivedData"
ARCHIVE="$OUT/$MODE.xcarchive"
: "${MARKETING_VERSION:?}" "${BUILD_NUMBER:?}" "${APP_GROUP_ID:?}"

mkdir -p "$OUT"
"${XCODEGEN:-xcodegen}" -r . -p . -s XCodeApps/TestFlight/project.yml
mkdir -p "$PROJECT/project.xcworkspace/xcshareddata/swiftpm"
cp Package.resolved "$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" \
    -derivedDataPath "$DD" -onlyUsePackageVersionsFromResolvedFile
python3 scripts/testflight/tf.py patch-wordaligner "$DD/SourcePackages"

ARGS=(archive -quiet -project "$PROJECT" -scheme "$SCHEME" -configuration Release
    -destination "generic/platform=iOS" -derivedDataPath "$DD" -archivePath "$ARCHIVE"
    -disableAutomaticPackageResolution
    MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" APP_GROUP_ID="$APP_GROUP_ID")

case "$MODE" in
    unsigned)
        xcodebuild "${ARGS[@]}" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
        ;;
    signed)
        : "${APPLE_TEAM_ID:?}" "${SIGNING_IDENTITY_SHA1:?}" "${TF_KEYCHAIN:?}" "${UUID_APP:?}" "${UUID_WIDGETS:?}" "${UUID_SHARE:?}"
        # Rejects any team other than the verified paid team before anything is signed.
        python3 scripts/testflight/tf.py export-options --team "$APPLE_TEAM_ID" \
            --identity-sha1 "$SIGNING_IDENTITY_SHA1" --uuid-app "$UUID_APP" \
            --uuid-widgets "$UUID_WIDGETS" --uuid-share "$UUID_SHARE" --out "$OUT/ExportOptions.plist"
        xcodebuild "${ARGS[@]}" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Manual \
            CODE_SIGN_IDENTITY="$SIGNING_IDENTITY_SHA1" OTHER_CODE_SIGN_FLAGS="--keychain $TF_KEYCHAIN" \
            TF_PROFILE_APP="$UUID_APP" TF_PROFILE_WIDGETS="$UUID_WIDGETS" TF_PROFILE_SHARE="$UUID_SHARE"
        rm -rf "$OUT/export"
        xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
            -exportOptionsPlist "$OUT/ExportOptions.plist"
        rm -rf "$OUT/ipa" && mkdir -p "$OUT/ipa"
        IPAS=("$OUT"/export/*.ipa)
        [[ ${#IPAS[@]} == 1 && -f "${IPAS[0]}" ]] || { echo "::error::expected exactly one exported IPA"; exit 1; }
        unzip -q "${IPAS[0]}" -d "$OUT/ipa"
        echo "ipa=${IPAS[0]}" >> "${GITHUB_OUTPUT:-/dev/null}"
        ;;
    *)
        echo "usage: $0 unsigned|signed" >&2
        exit 2
        ;;
esac
echo "app=$ARCHIVE/Products/Applications/Silveran Reader.app" >> "${GITHUB_OUTPUT:-/dev/null}"
