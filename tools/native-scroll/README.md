# Home scroll native geometry baseline

This is a **CI-only native regression harness**, not a release.
It runs the production `PunkRallyTabView`, Home's `NavigationStack -> ScrollView`
and `punkRallyMiniPlayerInset(topClearance: 24)`, the real Home Stats action,
More -> Stats, and the real `InkAmpMiniPlayerChrome` in an unsigned simulator host.

The separately authorized More correction removes the inset outside its
NavigationStack and applies it to the visible List or pushed destination inside
that stack. The previous List is not another on-screen reservation when a
destination is pushed. No height constants or duplicate nested insets are added.
Its eight measured RED assertions remain unchanged; GREEN requires native CI.
Home's production inset policy has not been changed: its faithful renderer and
restoration matrices must first reproduce a failure before any Home correction.

## Reproduction evidence

Josh reports that fully scrolling down does not expose the Stats strip at rest;
it appears only while pulling/holding upward. Static screenshots capture that
pulled position and do **not** prove unobstructed resting layout. Before-state
images supplied by Chief (local references only; images are not uploaded here):

- `C:\Users\imalo\AppData\Local\hermes\profiles\chief\images\upload_ulhwhybp.jpg`
- `C:\Users\imalo\AppData\Local\hermes\profiles\chief\images\upload_q16iegs0.jpg`
- `C:\Users\imalo\AppData\Local\hermes\profiles\chief\images\upload_8f7q18is.jpg`

## Scope and limitations

- Local `BookMetadata`, progress timestamps and podcast inputs pass through the
  production `HomeMixedQueue.build`. Home renders its real greeting,
  Finish-tonight, Continue, covers/badges, horizontal Up next and Stats strip;
  there is no longer a substitute fixed-size card path.
- Inputs match screenshot title lengths, readaloud/podcast badges, Played copy,
  long Continue time and the podcast's 1h36 remaining. Stats use a local history
  ledger through the real tracker. Artwork is the real renderer's placeholder
  branch because no authenticated VM or live covers are loaded.
- Matrix profiles cover the real bedtime card present/absent, plus player
  restoration after the initial scroll layout. A harness-only toolbar action
  injects that state transition without changing any production layout policy.
  Its pre/post UIScrollView measurements expose the first propagation failure.
- The actual Stats strip/action, scroll hierarchy, inset and bar chrome remain
  production code. Runtime frames/insets are observed, never imposed by a mock.
- The host has its own `com.punkrally.reader.geometry` bundle. Production bundle
  IDs, signing, IPA/TestFlight workflows and the app's layout policy are unchanged.
- The data seam in SilveranAppleKit is DEBUG-only and opt-in via
  `INKAMP_GEOMETRY_FIXTURE=1`. App-side fixture/probes compile only under
  `INKAMP_GEOMETRY_HARNESS`, which only this isolated target defines.
- Remaining differences: isolated fresh Debug host instead of the release
  entrypoint/startup-restore wrapper, no authenticated MediaViewModel or real
  progress/cover refresh races, simulated player chrome state instead of real
  audio transport/session restoration, deterministic local sample metadata and
  history rather than an exported device library, and the runner's simulator
  device/OS/text settings rather than a verified match for Josh's device/zoom.
  The restoration profile adds a diagnostic toolbar item and controls the
  reveal explicitly, rather than replaying the real asynchronous audio monitor.
- A passing production-renderer fixture still means **not reproduced under
  these represented conditions**. Do not overrule Josh or claim a Home fix.

## Native acceptance and evidence

XCTest covers Home and More -> Stats in portrait/landscape, normal/accessibility3
Dynamic Type, and playing/paused/hidden player states. Each gesture is released,
then allowed to settle. It observes the actual UIScrollView's content offset,
content size, bounds, adjusted/content/safe-area insets and calculated maximum
resting offset. It compares content's accessibility frames with the real player
and tab-bar ceiling. Home's Stats button is coordinate-tapped **after** measuring,
so XCTest cannot conceal the bug by auto-scrolling the button into view.

The stop case checks that the inset collapses rather than leaving a permanent
reservation. Each matrix case retains a screenshot, native metrics and the
accessibility hierarchy in the `.xcresult`, including when assertions fail.

Run locally **on macOS** from the repository root:

```sh
xcodegen generate --spec tools/native-scroll/project.yml --project "$PWD" --project-root "$PWD"
xcodebuild test -project InkAmpGeometry.xcodeproj -scheme InkAmpGeometry \
  -configuration Debug -destination 'platform=iOS Simulator,id=<available-UDID>' \
  -parallel-testing-enabled NO -resultBundlePath HomeScroll.xcresult \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

## Lifecycle matrix and measured scroll-root correction

`HomeLifecycleGeometryTests` adds three 8-case flows (24 final native cases:
portrait/landscape, normal/accessibility3, playing/paused). The entire original
48-case test file, including More -> Stats and stop/collapse assertions, remains
byte-identical. The user-confirmed released-scroll obstruction on device is the
failing acceptance case; simulator non-reproduction does not negate it.

The production correction uses `punkRallyMiniPlayerScrollInset` directly on
Home's ScrollView, More's List and the Stats destination's ScrollView. An
intrinsically sized overlay measures the actual rendered player (including Home's
existing top clearance); `safeAreaPadding` on that same scrolling root consumes
the measured height. No copied player-height constant, navigation-container
reservation or second Stats reservation is used. Hidden content measures zero.
Other destinations retain their existing inset strategy without a second wrapper.

- **Cover:** the real private `iOSRootView` awaits local prerequisites, restores
  local `PlayerBookData` through the original `PlayerPresenter.present`, and
  mounts the production shell's existing `fullScreenCover`. The test observes
  the cover and live visibility policy, minimizes through the unchanged
  `PlayerPresenter.dismissCard`, then scrolls/releases/measures and coordinate-taps Stats.
- **Async-at-bottom:** with no session/card, first scroll/release/settle Home at
  its native bottom. Only then post a cross-process Darwin notification to
  publish local snapshot DATA through `AudioSessionActor`'s actual observer ->
  `AudioSessionMonitor.apply` -> live policy/transition path. There is no nav
  toolbar touch, keyboard, URL, app relaunch or foreground transition. Publication
  records the actual UIKit Home probe at that instant; the test asserts it was
  already at rest/bottom before measuring the revealed bar and scrolling again.
- **Headless startup:** publish local session data during the real root's startup
  prerequisite seam, with no card. Verify the observed live docked player and the
  same released-bottom geometry/tap contract. This is local startup publication,
  not real persisted-engine transport restoration.
- The state probe records real presenter/monitor/policy state, cover appear/
  disappear counts, publication count, and native Home measurements. Each
  transition/final case retains JSON, frames, screenshot and accessibility text,
  even on an assertion or setup failure. Geometry tolerances are not relaxed.
- `INKAMP_GEOMETRY_FIXTURE=0` is mandatory for these flows; `liveContent` and its
  production move/opacity transition are used, not `MiniPlayerGeometryFixture`.
  New framework data seams require DEBUG, the exact unsigned geometry bundle
  ID, and `INKAMP_GEOMETRY_LIFECYCLE=cover|async|launch`. Data seams are inactive in
  Release; the measured scroll-root layout correction is production code.

**Remaining limits:** this is the actual root wrapper/AnyView and an injected
local MediaViewModel, not authenticated migration/network startup. The audio
engine snapshot data, persisted-route resolution, and cover image I/O are local.
Inside the actual full-screen cover, a local content pane replaces file/audio
player controls; the true audio player's internal setup/onDisappear/engine
teardown is NOT exercised. The real presenter and full-screen presentation/
dismissal remain unchanged. AppDelegate/background hooks, device library/cache
races, live media/artwork, exact device/OS/zoom and genuine persisted-session
transport restore remain unrepresented. GREEN verifies the candidate against the
native regression assertions, not that the original device failure is fixed.
On-device released-scroll/tap confirmation remains a separate acceptance gate.

`Home scroll native geometry` runs on push to `cursor/home-scroll-clearance-v2`
and `cursor/home-lifecycle-native-repro` / `cursor/home-scroll-root-reservation`,
with a 75-minute job budget for the
expanded native suite, and retains logs/results for 14 days. A build/probe/setup
failure is a harness failure, **not** a reproduced layout regression. Read
assertions and attachments before choosing any production correction. No PR,
tag, release or production rollout is authorized by this diagnostic extension.

## Initial measured baseline (f6dab706)

[Run 43651706073](https://github.com/subarude15/storyteller-personal-reader/actions/runs/43651706073)
compiled and executed native XCTest on iPhone 17 Pro / iOS 26.2. Three test
methods ran: Home matrix and stop/collapse passed; More -> Stats failed.

- All 12 synthetic-content Home cases passed released-bottom geometry and
  coordinate-tap checks. This does NOT reproduce or disprove Josh's original
  Home library/device failure.
- Six More -> Stats cases demonstrated resting-footer obstruction. In portrait
  normal type, adjusted bottom inset stayed at 83 with or without the player;
  footer bottom was 779 and player top 727 (52 points of vertical overlap).
  The equivalent Home fixture had inset 171 with player, 83 hidden, and Stats
  button bottom 691 above player top 727.
- Three more failures were test navigation setup, not geometry: landscape with
  accessibility type did not reach the offscreen Stats row in More's lazy List.
  The test now scrolls that hub before navigation, without auto-scrolling or
  weakening any measured-destination assertion. Those cases require a new run.
- Native screenshots, metrics and hierarchy are retained in artifact
  `home-scroll-native-f6dab70615223fb040a0da7903e5b1a4c76f93af` (ID 14137391162).
  The normal iOS workflow [43651706021](https://github.com/subarude15/storyteller-personal-reader/actions/runs/43651706021)
  passed all four jobs on that same commit.

This is a RED baseline, not a production layout correction. Preserve the
observed failures until the actual boundary correction is separately made and
native-tested; never make the CI green by loosening its visibility assertions.
