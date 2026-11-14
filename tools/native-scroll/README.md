# Home scroll native geometry baseline

This is a **CI-only diagnostic harness**, not a layout correction or a release.
It runs the production `PunkRallyTabView`, Home's `NavigationStack -> ScrollView`
and `punkRallyMiniPlayerInset(topClearance: 24)`, the real Home Stats action,
More -> Stats, and the real `InkAmpMiniPlayerChrome` in an unsigned simulator host.

## Reproduction evidence

Josh reports that fully scrolling down does not expose the Stats strip at rest;
it appears only while pulling/holding upward. Static screenshots capture that
pulled position and do **not** prove unobstructed resting layout. Before-state
images supplied by Chief (local references only; images are not uploaded here):

- `C:\Users\imalo\AppData\Local\hermes\profiles\chief\images\upload_ulhwhybp.jpg`
- `C:\Users\imalo\AppData\Local\hermes\profiles\chief\images\upload_q16iegs0.jpg`
- `C:\Users\imalo\AppData\Local\hermes\profiles\chief\images\upload_8f7q18is.jpg`

## Scope and limitations

- Synthetic local cards replace only Home's greeting/queue CONTENT in this
  target. No server, real user library or real audio transport is needed.
- These cards deliberately overflow the viewport. Their fixture dimensions are
  NOT player-height reservations, padding fixes or measurements of Josh's cards.
- The actual Stats strip/action, scroll hierarchy, inset and bar chrome remain
  production code. Runtime frames/insets are observed, never imposed by a mock.
- The host has its own `com.punkrally.reader.geometry` bundle. Production bundle
  IDs, signing, IPA/TestFlight workflows and the app's layout policy are unchanged.
- The data seam in SilveranAppleKit is DEBUG-only and opt-in via
  `INKAMP_GEOMETRY_FIXTURE=1`. App-side fixture/probes compile only under
  `INKAMP_GEOMETRY_HARNESS`, which only this isolated target defines.
- A passing simulator baseline means **not reproduced in this fixture/runtime**;
  it does not overrule Josh's device report or establish a device fix.

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

`Home scroll native geometry` runs on push to `cursor/home-scroll-clearance-v2`
and retains logs/results for 14 days. A build/probe/setup failure is a harness
failure, **not** a reproduced layout regression. Read assertions and attachments
before choosing the smallest production correction. No PR, tag, release or
production rollout is part of this baseline submission.
