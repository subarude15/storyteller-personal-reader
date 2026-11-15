# Reader immersive controls (iOS ebook + readaloud)

Status: implemented on `fix/immersive-reader-controls`, **not device-verified, not CI-verified**.
Scope: iOS ebook and readaloud reader only. Comics and macOS keep the original behavior
(`EbookPlayerViewModel.effectiveControlsMode` is always `.classic` for comics; the JS side
only applies immersive when `navigator.maxTouchPoints > 0`).

## Modes

Settings: Reader → Customize → **Reader Controls** (`ReadingBar.controlsMode`, default
`immersive`). Missing or unknown stored values decode to `immersive`. The reader panel's
"Reset to Defaults" sets the mode back to Immersive; it leaves Mini Player › Always Show alone.

| | Immersive (default) | Classic |
|---|---|---|
| Chrome on open | Top toolbar + bottom card/scrubber hidden | Original (both visible) |
| Long-press (~500 ms) | Shows chrome; no selection, highlight edit, seek, or page turn | Native text selection |
| Center tap | Hides chrome (never reveals) | Toggles chrome (legacy) |
| Margin tap / arrow keys | Turns page and hides chrome | Turns page only |
| Idle | Hides after 4 s without interaction | Never |
| Highlighting | Show chrome → **Select Text** → **Done Selecting** | Long-press selects |
| iPad sidebar | Not auto-opened from the stored preference; stays open until closed; toggles are not persisted | Stored preference restored on entering Classic; toggles persisted (legacy) |
| Hidden-chrome narration overlay (time + skip/play) | Never shown | Legacy: shown while the toolbar is hidden |
| Thin narration progress strip | Only with revealed chrome or the pinned compact card | Legacy: always in readaloud |

Swipes, scroll mode, and page-curl dragging are unchanged in both modes.

## How a long-press is arbitrated

`ReaderGestures.js` (`ReaderHoldArbiter`) attaches **capture-phase** listeners to each
section document, so it runs before the Foliate paginator, `PageTurnAnimator`,
`FoliateManager`, and `BookmarkManager` listeners.

- The arbiter is inert until Swift pushes state (`setReaderControls`); until then the legacy behavior applies.
- A hold starts on a single touch that is not on a link. It fires at 500 ms if the finger moved ≤ 5 px, no curl/turn drag is in progress (`PageTurnAnimator.isTurnInProgress`), and there is no selection.
- On fire it releases the armed curl (`releaseForHold`), ends any spread curl, cancels a pending tap, and posts `ReaderChromeReveal`.
- After the hold is consumed, `touchmove` is blocked (except in scrolled mode). `touchend` is prevented and stopped, and the paginator is snapped back with `snap(0,0)`. Click, dblclick, and contextmenu are swallowed for 1 s or until the next `touchstart`.
- In browse state the document gets `inkamp-immersive-browse` (`user-select: none`, `-webkit-touch-callout: none`; form fields stay selectable). Select Text mode removes the class. Leaving Select Text mode clears the selection.
- Lifecycle: each section doc is released (listeners, its window `pagehide`/`unload` listeners, lock class and CSS, any pending hold timer or post-hold swallow window it owns) when its window fires `pagehide`/`unload`, or when its hosting iframe is gone (`defaultView` null or `frameElement.isConnected === false`). Gone docs are pruned on every attach, state change, and hold deadline; live docs (spreads) stay attached. Reader teardown (`pagehide` of the reader page) calls `dispose()`, which releases every doc and returns the arbiter to the inert, pre-state mode.
- Double-tap seek (`resolveSeekRange`): unlocked (Classic, macOS, Select Text) it is exactly the legacy rule — WebKit's selection range or no seek. Only under the immersive lock does it hit-test `caretRangeFromPoint` (class lifted for the probe), and it accepts the caret only when it lands on non-whitespace text under the finger. Images, whitespace, and empty margins never seek.

## Startup push (no long-press selection window)

`EbookPlayerViewModel.pushReaderControlsToJS` runs when bridge callbacks are installed (first load and WebView recovery), when settings load or the mode changes (`applyControlsMode`), on Select Text changes, and again on structure-ready. It is skipped until settings are loaded (the arbiter stays legacy, which is correct for Classic) and for comics; it is iOS-only.

Each push first registers, synchronously, a document-start `WKUserScript` that sets `window.inkampPendingReaderControls = {immersive, selectionMode: false}` (`ReaderCommsBridge.setReaderControlsForPageLoads`). The bridge is installed before `loadFileURL`, so the reader page always gets the state; a recovered page never resumes Select Text. The push then evaluates a script that sets the same global and, if `window.foliateManager` exists, calls `setReaderControls` (returns `"applied"`, otherwise `"pending"`; failures are logged). `FoliateManager`'s constructor consumes the global before `open()`, so the first section attaches already locked. macOS gets no push and the JS gate (`maxTouchPoints > 0`) keeps immersive off.

## Precedence (Swift: `ReaderChromePolicy.swift`)

`ReaderChromeState.apply(_:)` is the single source of truth; `ReaderChromeController`
owns the idle timer (stale generations are ignored).

- **Activity:** toolbar actions and the audio card's own controls (`DraggableAudioCard.onActivity`: Book/Chapter scope toggle, collapse, expand, drag release) restart the idle timer. There is no whole-page touch interceptor. This card wiring is source-only (no SwiftUI test).
- **Blockers** pin revealed chrome until the interaction ends: scrubbing, card drag, expanded card, any modal sheet (root sheets plus toolbar/card sheets via `reportsReaderChromeSheet`), and Select Text mode. While any blocker is active, idle, center tap, margin tap, and "Hide reader controls" do not dismiss chrome; margin taps still turn the page. A deliberate card swipe-down (`cardDismissed`) always closes the card; in Immersive it also hides the toolbar unless Select Text or a sheet is active. Classic center/margin taps and swipe-down behave as before.
- **VoiceOver:** turning it on reveals chrome and disables auto-hide. "Hide reader controls" is a toolbar accessibility action. A VoiceOver-only "Show reader controls" button appears while hidden.
- **Background:** idle timer is suspended while the scene is not active.
- **Page curl:** masks chrome while active; it does not change revealed state. A stuck curl is reset when the WebView bridge is recreated.
- **Always Show mini player:** in Immersive it pins only the compact narration card (readaloud). It never pins the pure-ebook scrubber. In Classic it keeps the legacy meaning.
- **Overlays and strips** are decided by `ReaderChromeState` so each one is unit-tested:
  - `showsNarrationOverlay`: the hidden-chrome `EbookOverlayIos` time/transport overlay is Classic-only. In Immersive, playback stays reachable through revealed chrome and the card. The `showOverlay*` / time-remaining settings are not changed; Classic still honors them.
  - `showsPlaybackProgressStrip`: Classic keeps the always-on readaloud strip. Immersive shows it only with revealed chrome or the pinned compact card.
  - `showsRevealedProgressOverlay` (floating page/progress readout with revealed chrome) and `showsBookmarkRibbon`: same rule in both modes as before.
- **iPad sidebar** (`ReaderSidebarPolicy`): entering Classic, including the first apply, opens the sidebar if the stored preference is open. It never closes a sidebar the reader opened, and re-applying the same mode, idle, or reveal never touches it. Immersive never auto-opens it.
- **Jump-back pill:** unchanged.
- **Reduce Motion:** chrome show/hide animation is disabled.

## First-run hint

`ReaderControlsHint.currentVersion = 1`, stored per device in `UserDefaults`
(`ReaderControlsHintAcknowledgedVersion`). Shown once the reader is ready in Immersive mode.
Bump the version to re-show after a behavior change. "Show Controls Tips Again" in Reader
Controls settings resets it.

## Checks

| Check | Command | Covers |
|---|---|---|
| Gesture arbiter + tap router | `node scripts/reader-gestures-selfcheck.mjs` | Hold timing/tolerance, release suppression, cancellation, mode bypass, CSS lock, iframe lifecycle (removed iframe with live window, pagehide, spreads, dispose), pending startup state, tap routing, seek range |
| Animator hooks | `node scripts/page-turn-animator-selfcheck.mjs` | `isTurnInProgress`, `releaseForHold` |
| Policy + persistence | `./scripts/test --filter 'ReaderChromePolicyTests\|ReaderChromeControllerTests\|ReaderControlsBridgeTests'` (macOS, repo root; runs `swift test` on the root `Package.swift`) | Mode decoding and reset default, `ReadingBar` back-compat, every visibility/overlay/strip rule, sidebar transitions, controller timer, startup push scripts |
| iOS-only wiring compiles | `./scripts/iosbuild` (CI job "iOS Simulator Build") | `EbookPlayerView` / `EbookPlayerViewModel` / toolbar / card `#if os(iOS)` code |

### Native test limits

- Host `swift test` runs on macOS, so it compiles `ReaderChromePolicy.swift` but **not** the `#if os(iOS)` view and view-model wiring. That code is only compiled by the iOS Simulator build. Neither has run for this branch yet.
- CI (`ios.yml`) runs the full `./scripts/test`, which includes these suites. The three Node self-checks run in the `ios.yml` job "Reader JS Self-checks" (ubuntu-latest, Node 24, no submodules needed). That job has not run yet for this branch.
- The Node checks use fake documents and a fake clock. They do **not** prove WKWebView behavior: real long-press timing against the system selection recognizer, whether `user-select: none` fully suppresses the loupe/callout, synthetic click ordering, `caretRangeFromPoint` and per-character `getClientRects()` hit-testing, iframe `pagehide`/`frameElement` behavior in WebKit, or document-start `WKUserScript` timing.
- There is no XCUITest/WKWebView harness. SwiftUI wiring (sheets, card blockers, VoiceOver button, sidebar, Reduce Motion, overlay gating) is verified only on a device.

## Device smoke checklist

Run on an iPhone and an iPad, with one ebook and one readaloud book.

1. Open a book: toolbar and scrubber hidden; the hint appears once; "Got It" dismisses it and it stays dismissed on reopen. Long-press immediately on the first page (before chapters load): no selection, chrome appears.
2. Hold ~0.5 s on text: chrome appears. No selection, loupe, callout, highlight bar, page turn, or audio seek, including after lifting the finger.
3. Hold on an existing highlight: chrome appears, highlight bar does not.
4. Leave it: chrome hides after ~4 s. Tap the center: hides. Tap a margin: turns the page and hides.
5. Swipe and curl-drag pages: unchanged; a slow curl drag never reveals chrome.
6. Scroll mode: holding still reveals chrome; scrolling still works afterwards.
7. Select Text → select → highlight/edit/delete works → Done Selecting clears selection and returns to browse.
8. Readaloud: double-tap a sentence seeks audio; double-tap an image or blank margin does not; single center tap does not seek. Audio card hides with chrome and playback continues. While hidden, there is no time/skip/play overlay and no progress strip. Drag the slider for over 4 s: chrome stays. With the card expanded or a sheet open, center and margin taps do not hide chrome (margin taps still turn the page); swipe-down still closes the card.
9. Always Show on: compact narration card (and its strip) stays pinned in readaloud; pure ebook scrubber still hides. Classic readaloud: hidden-chrome overlay and strip appear as before.
10. Open Chapters, Speed, Options, Sleep timer: chrome stays while the sheet is open.
11. iPad: open the sidebar, wait 4 s: it stays. With the Classic preference open, reopen the book in Immersive: sidebar not auto-opened. Switch to Classic in the same session: sidebar opens. Open it in Immersive, then switch to Classic with the preference closed: it stays open.
12. Switch to Classic: chrome shows; center tap toggles; long-press selects text.
13. VoiceOver on: chrome shows and does not auto-hide; "Hide reader controls" action and "Show reader controls" button work.
14. Reduce Motion on: chrome appears/disappears without animation.
15. Background the app mid-countdown and return: no immediate hide; comics and macOS unchanged.
