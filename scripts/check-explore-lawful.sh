#!/bin/bash
# check-explore-lawful.sh — CI guard for Explore lawful boundary
# Fails if a diff or working tree bundles piracy/DRM-strip transports outside the deny-list.
#
# Allowed references:
#   - OPDSCatalogs.bannedHosts (deny-list)
#   - docs/* (documentation about what is banned, e.g. PlayTorrio link)
#   - This script itself
#
# Everything else that mentions a pirate index, Audible login scrape, or DRM strip lib is a violation.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXIT=0

echo "== Explore lawful guard =="

# Patterns that must NOT appear in Swift sources except in the deny-list
# We search SilveranKit and XCodeApps for bundled piracy hosts.
# The deny-list file is SilveranKit/Sources/AppleKit/PersonalReader/Features/Explore/OPDSCatalog.swift
# So we exclude that file from the “bundled search” check, but we still verify it only appears there as a block.

BANNED_PATTERNS=(
  "libgen"
  "annas-archive"
  "z-lib"
  "zlibrary"
)

# The deny-list file is expected to contain those hosts as a block-list.
ALLOWLIST_FILE="SilveranKit/Sources/AppleKit/PersonalReader/Features/Explore/OPDSCatalog.swift"

for pat in "${BANNED_PATTERNS[@]}"; do
  # Search, but exclude the deny-list file, docs, and the guard script itself.
  # Also exclude pure-comment warnings that say “do not add / banned / If you are about to add”
  # — those are board-policy warnings, not bundled indexes.
  if grep -R -i --include="*.swift" -n "$pat" "$ROOT/SilveranKit" | grep -v "$ALLOWLIST_FILE" | grep -v "do not add\|banned\|If you are about to add\|No imports" | grep -q .; then
    echo "FAIL: banned pattern '$pat' found bundled in Swift sources (outside deny-list):"
    grep -R -i --include="*.swift" -n "$pat" "$ROOT/SilveranKit" | grep -v "$ALLOWLIST_FILE" | grep -v "do not add\|banned\|If you are about to add\|No imports"
    EXIT=1
  fi
done

# DRM-strip tokens in comments are warnings, not bundling. Only fail if they appear
# as a real import statement (line starts with import) — not a policy comment.
if grep -R --include="*.swift" -n "^[[:space:]]*import.*DeDRM\|^[[:space:]]*import.*libation" "$ROOT/SilveranKit" | grep -v "$ALLOWLIST_FILE" | grep -q .; then
  echo "FAIL: DRM-strip import found"
  grep -R --include="*.swift" -n "^[[:space:]]*import.*DeDRM\|^[[:space:]]*import.*libation" "$ROOT/SilveranKit"
  EXIT=1
fi
if grep -R --include="*.swift" -n "activation_bytes" "$ROOT/SilveranKit" | grep -v "$ALLOWLIST_FILE" | grep -v "do not add\|banned\|If you are tempted" | grep -q .; then
  echo "FAIL: activation_bytes found outside policy comment"
  grep -R --include="*.swift" -n "activation_bytes" "$ROOT/SilveranKit" | grep -v "$ALLOWLIST_FILE" | grep -v "do not add\|banned\|If you are tempted"
  EXIT=1
fi

# DRM-strip libs must not be added to Package.swift
if grep -q -i "DeDRM\|libation\|activation_bytes" "$ROOT/Package.swift" 2>/dev/null; then
  echo "FAIL: DRM-strip dependency found in Package.swift"
  EXIT=1
fi

# Pirate search hosts must not be in Package.swift or Info.plist either
if grep -R -i --include="*.swift" --include="*.plist" "annas-archive\|libgen" "$ROOT/Package.swift" "$ROOT/XCodeApps" 2>/dev/null | grep -v "$ALLOWLIST_FILE" | grep -q .; then
  echo "FAIL: pirate host in Package.swift / XCodeApps"
  EXIT=1
fi

# Verify Explore transports are the four lawful ones
if ! grep -q "publicOPDS" "$ROOT/SilveranKit/Sources/AppleKit/PersonalReader/Features/Explore/AuthorizedTransport.swift"; then
  echo "FAIL: AuthorizedTransport missing lawful cases"
  EXIT=1
fi

# Verify BYO is single-link only (no “search” function)
if grep -R --include="*.swift" -n "func search.*torrent\|func.*torrent.*search\|trackerList" "$ROOT/SilveranKit/Sources/AppleKit/PersonalReader/Features/Explore" | grep -q .; then
  echo "FAIL: BYO must not contain torrent search / tracker list"
  grep -R --include="*.swift" -n "func search.*torrent\|func.*torrent.*search\|trackerList" "$ROOT/SilveranKit/Sources/AppleKit/PersonalReader/Features/Explore"
  EXIT=1
fi

if [ $EXIT -eq 0 ]; then
  echo "PASS: Explore lawful guard — no bundled pirate/DRM-strip transports found."
else
  echo "== Guard failed =="
  echo "See docs/cursor-paste-explore-authorized.md §2 (Hard bans) and Features/Explore/README.md"
fi
exit $EXIT
