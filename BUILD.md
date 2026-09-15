# Building ink+amp (iOS)

ink+amp is a fork of [Silveran Reader](https://github.com/kyonifer/silveran-reader)
that keeps SilveranKit's Storyteller sync brain and adds a phone-first five-tab shell
(Home · Library · Shelf · Podcasts · Stats), RSS podcasts and reading stats ported from
Enve Book Player (AGPL), and Fast Font defaults.

**You need a Mac with Xcode.** This codebase cannot be built on Windows (no `xcodebuild`).
The files are Xcode-ready and verified structurally on the Windows dev box; compile in Xcode.

## Prerequisites

- macOS on **Apple Silicon**
- **Xcode 16+** (Swift 6.2 compatible)
- Git
- `xcodegen` for regenerating the project from `XCodeApps/project.yml`:
  ```bash
  brew install xcodegen
  ```

## 1. Clone your fork

```bash
git clone https://github.com/YOUR_GITHUB/silveran-reader.git
cd silveran-reader
git checkout ink-amp-ios
```

## 2. Resolve Swift packages

The project is a SwiftPM package with XcodeGen-defined app targets. Resolve first:

```bash
xcodebuild -resolvePackageDependencies \
  -project Silveran.xcodeproj \
  -scheme "Silveran Reader (iOS)"
```

## 3. Generate the Xcode project (after xcodegen install)

The checked-in `Silveran.xcodeproj` may be stale if `project.yml` changed. Regenerate:

```bash
cd XCodeApps
xcodegen generate
cd ..
```

This produces `Silveran.xcodeproj` at repo root from `XCodeApps/project.yml`, including
the ink+amp Theme + PunkRallyModules source directories.

## 4. Build for iOS Simulator

```bash
# List available destinations
xcodebuild -project Silveran.xcodeproj -scheme "Silveran Reader (iOS)" -showdestinations

# Build via script (includes code signing disable and simulator flags)
./scripts/iosbuild

# Or directly with xcodebuild:
xcodebuild -project Silveran.xcodeproj \
  -scheme "Silveran Reader (iOS)" \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

> If the scheme name differs (older fork), check `xcodebuild -list`.

## 5. Run in Simulator

Open `Silveran.xcodeproj`, select the **ink+amp** scheme, pick an iPhone simulator,
and press Run. Or from CLI:

```bash
xcrun simctl boot "iPhone 16"
open -a Simulator
xcodebuild -project Silveran.xcodeproj -scheme "Silveran Reader (iOS)" \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

## 6. Build for a physical device

Requires your Apple Developer team + signing. Set `DEVELOPMENT_TEAM` (e.g. env var or
`XCodeApps/Configs/Local.xcconfig`), or sign in Xcode under Signing & Capabilities.

```bash
xcodebuild -project Silveran.xcodeproj \
  -scheme "Silveran Reader (iOS)" \
  -destination 'generic/platform=iOS' \
  -configuration Debug build
```

## 7. Build unsigned device IPA for AltStore / Sideloading (Free Apple ID)

For sideloading onto physical iPhone/iPad with a free Apple ID via AltStore Classic, use the slim sideload target and packaging script:

```bash
./scripts/package-ipa "Silveran Reader Sideload (iOS)" Release .buildIosDevice punkrally-sideload-unsigned.ipa
```

This builds an unsigned device IPA with CarPlay, widgets, and watchOS companions stripped so it installs cleanly on free personal Apple Developer accounts. See [SIDELOAD.md](SIDELOAD.md) for full AltStore Classic + AltServer on Windows instructions.

## Signing & identity

- Default bundle ID: `com.punkrally.reader`
- App display name: `ink+amp`
- Entitlements: `XCodeApps/SilveranReaderIos.entitlements` (keychain, network, audio,
  background fetch)
- Set `DEVELOPMENT_TEAM` in `XCodeApps/Configs/Debug.xcconfig` / `Release.xcconfig`
  (they include a `Local?` that you can fill).

## What's in this milestone (M1)

- **SilveranKit untouched** — EPUB/SMIL, Storyteller actors, progress sync, readaloud,
  downloads all upstream.
- **New 5-tab shell** — `XCodeApps/PunkRallyApp.swift` (`PunkRallyTabView`).
- **AppLaunchContext hook** — Silveran's iOS root now consults
  `AppLaunchContext.iosRootView`; `EntryPointStub` injects the tab shell.
- **Theme tokens** — `XCodeApps/Theme/PunkRallyTokens.swift` (light+dark chrome per DESIGN.md).
- **Shelf = downloads-only** — `SilveranKit/.../PunkRallyShellSupport.swift` exposes
  `PunkRallyShelfView` (searchable `DownloadedContentView` grid) as a public facade;
  the Shelf tab uses it (no full-library duplication).
- **Mini-player bar** — same facade exposes `PunkRallyMiniPlayerBar` (wraps Silveran's
  internal `GlobalMiniPlayerBar`); the shell pins it above the tab bar via `safeAreaInset`.
- **Library without nested tabs** — `PunkRallyLibraryView` wraps Silveran's
  `BooksContentView` grid with search + detail navigation (no inner tab bar).
- **Fast Fonts** — 5 TTFs bundled via `SilveranKit/Sources/Kit/Resources/assets/fonts/`;
  default reader body `Fast Serif` via `kDefaultFontFamily`.
- **Podcasts rail (AGPL)** — `XCodeApps/PunkRallyModules/Podcasts/` (RSS parser, store,
  view model, views) — RSS only, not Storyteller.
- **Stats (AGPL)** — `XCodeApps/PunkRallyModules/Stats/` (session tracker, models, view).
- **AGPL notice** — `XCodeApps/AGPL_NOTICE.md` + SPDX headers on ported files.

## Known gaps (next milestone)

- **Podcast playback**: feeds parse + show; episode playback via shared player is M2.
- **Stats wiring**: tracker records sessions locally but isn't yet fed by the Silveran
  player/reader events (M2).
- **Home Continue hero + sync chip** driven by real progress: wired dynamically to MediaViewModel / LastOpenBookStore.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `xcodebuild` can't find scheme | Regenerate project (`xcodegen generate`); scheme name may be "Silveran Reader (iOS)" on a fresh fork |
| Missing `DEVELOPMENT_TEAM` | Set it in Local.xcconfig or Xcode Signing |
| Fast Serif not in Aa list | Confirm the 5 TTFs are in `SilveranKit/Sources/Kit/Resources/assets/fonts/` and got re-resolved (`xcodegen` + rebuild) |
| AGPL notice missing | It's at `XCodeApps/AGPL_NOTICE.md`; wire Settings → Licenses in M2 |
| Podcast fetch fails | The feed parser is strict RFC-822 date tolerant; check the URL returns valid RSS |