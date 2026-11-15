#!/usr/bin/env bash
# Temporary signing material for ios-testflight.yml (macOS runner, bash 3.2 safe).
#   setup                     throwaway keychain + P12 import, decode profiles / ASC key
#   install APP WIDGETS SHARE copy validated profiles (named by UUID) where Xcode looks
#   cleanup                   remove everything and restore the keychain search list
# Never creates, repairs, or downloads signing assets. Never echoes secret values.
set -euo pipefail
umask 077

WORK="${RUNNER_TEMP:?}/tf-signing"
STATE="${RUNNER_TEMP}/tf-signing-state"
KC="$WORK/tf-signing.keychain-db"
PROFILE_DIRS=("$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles")

die() { echo "::error::$*"; exit 1; }
out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }
decode() {
    local value="${!1:-}"
    [[ -n "$value" ]] || die "$1 is not configured"
    printf '%s' "$value" | base64 --decode > "$2" 2>/dev/null || die "$1 is not valid base64"
    [[ -s "$2" ]] || die "$1 decoded to an empty file"
}

setup() {
    rm -rf "$WORK" "$STATE"
    mkdir -p "$WORK" "$STATE"
    security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' > "$STATE/keychains"

    local pass
    pass="$(openssl rand -hex 32)"
    echo "::add-mask::$pass"
    security create-keychain -p "$pass" "$KC"
    echo "$KC" > "$STATE/keychain"
    security set-keychain-settings -lut 7200 "$KC"
    security unlock-keychain -p "$pass" "$KC"

    decode APPLE_DISTRIBUTION_P12_BASE64 "$WORK/dist.p12"
    [[ -n "${APPLE_DISTRIBUTION_P12_PASSWORD:-}" ]] || die "APPLE_DISTRIBUTION_P12_PASSWORD is not configured"
    security import "$WORK/dist.p12" -k "$KC" -f pkcs12 -P "$APPLE_DISTRIBUTION_P12_PASSWORD" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null || die "P12 import failed (wrong password or not a PKCS#12)"
    rm -f "$WORK/dist.p12"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "$KC" >/dev/null

    local search=("$KC") line
    while IFS= read -r line; do if [[ -n "$line" ]]; then search+=("$line"); fi; done < "$STATE/keychains"
    security list-keychains -d user -s "${search[@]}"

    # A "valid" identity proves the certificate chains to Apple AND its private key is present.
    local ids
    ids="$(security find-identity -v -p codesigning "$KC" | grep -E '^ +[0-9]+\) [0-9A-F]{40} "' || true)"
    [[ -n "$ids" && "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" == 1 ]] \
        || die "expected exactly one valid code-signing identity (certificate + private key) in the P12"
    out identity_sha1 "$(sed -E 's/^ +[0-9]+\) ([0-9A-F]{40}) .*/\1/' <<<"$ids")"
    security find-certificate -a -p "$KC" > "$WORK/certs.pem"

    decode APPLE_PROFILE_APP_BASE64 "$WORK/app.mobileprovision"
    decode APPLE_PROFILE_WIDGETS_BASE64 "$WORK/widgets.mobileprovision"
    decode APPLE_PROFILE_SHARE_BASE64 "$WORK/share.mobileprovision"
    security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain > "$WORK/apple-roots.pem"

    if [[ -n "${APPSTORE_API_PRIVATE_KEY:-}" ]]; then
        [[ "${APPSTORE_API_KEY_ID:-}" =~ ^[A-Z0-9]{10}$ ]] || die "vars.APPSTORE_API_KEY_ID is missing or malformed"
        local dir="$HOME/.appstoreconnect/private_keys"
        mkdir -p "$dir"
        chmod 700 "$dir"
        printf '%s\n' "$APPSTORE_API_PRIVATE_KEY" > "$dir/AuthKey_${APPSTORE_API_KEY_ID}.p8"
        chmod 600 "$dir/AuthKey_${APPSTORE_API_KEY_ID}.p8"
        echo "$dir/AuthKey_${APPSTORE_API_KEY_ID}.p8" > "$STATE/asc-key"
        out asc_key_path "$dir/AuthKey_${APPSTORE_API_KEY_ID}.p8"
    fi

    out work "$WORK"
    out keychain "$KC"
}

install_profiles() {
    local labels=(app widgets share) uuids=("$@") i dir
    [[ ${#uuids[@]} == 3 ]] || die "install needs 3 profile UUIDs"
    for i in 0 1 2; do
        [[ "${uuids[$i]}" =~ ^[0-9A-Fa-f-]{36}$ ]] || die "bad profile UUID"
        for dir in "${PROFILE_DIRS[@]}"; do
            mkdir -p "$dir"
            cp "$WORK/${labels[$i]}.mobileprovision" "$dir/${uuids[$i]}.mobileprovision"
            echo "$dir/${uuids[$i]}.mobileprovision" >> "$STATE/installed"
        done
    done
}

cleanup() {
    set +e
    if [[ -f "$STATE/keychains" ]]; then
        local search=() line
        while IFS= read -r line; do if [[ -n "$line" ]]; then search+=("$line"); fi; done < "$STATE/keychains"
        [[ ${#search[@]} -gt 0 ]] && security list-keychains -d user -s "${search[@]}"
    fi
    [[ -f "$STATE/keychain" ]] && security delete-keychain "$(cat "$STATE/keychain")" 2>/dev/null
    if [[ -f "$STATE/installed" ]]; then
        while IFS= read -r line; do rm -f "$line"; done < "$STATE/installed"
    fi
    [[ -f "$STATE/asc-key" ]] && rm -f "$(cat "$STATE/asc-key")"
    rm -rf "$WORK" "$STATE" .build-testflight/ExportOptions.plist
    echo "signing material removed"
    return 0
}

case "${1:-}" in
    setup) setup ;;
    install) shift; install_profiles "$@" ;;
    cleanup) cleanup ;;
    *) die "usage: $0 setup|install APP WIDGETS SHARE|cleanup" ;;
esac
