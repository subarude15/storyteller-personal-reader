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

`Home scroll native geometry` runs on push to `cursor/home-scroll-clearance-v2`
and retains logs/results for 14 days. A build/probe/setup failure is a harness
failure, **not** a reproduced layout regression. Read assertions and attachments
before choosing the smallest production correction. No PR, tag, release or
production rollout is part of this baseline submission.

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
