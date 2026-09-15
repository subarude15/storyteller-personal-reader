# ink+amp / punk+rally — roadmap

Living board for Hermes + the Grok crew. Update when PRs/IPAs land.
Repo: https://github.com/subarude15/storyteller-personal-reader · branch `punk-rally-ios`
NUC workspace: `C:\Users\imalo\dev\silveran-ios\`

## Now (do first)
- [ ] Sideload IPA with Keychain strip (`cf081e1`) — Actions run [34922548643](https://github.com/subarude15/storyteller-personal-reader/actions/runs/34922548643)
- [ ] On device: Test Connection → **Save** Storyteller (`https://storyteller.banditoburrito.xyz`) with Safari-same credentials
- [ ] Confirm ink+amp display name + twin-pages icon after AltStore install

## Shipped
- [x] Storyteller Cloudflare Access Google bypass (server)
- [x] M1 shell: Home / Library / Shelf / Podcasts / Stats
- [x] Storyteller URL **prefill** (not auto-save)
- [x] Shelf downloads-only + mini-player
- [x] PR 4: Home Continue + sync chip + CI Builtin/StoryAlign fix (merged `937ef9a`)
- [x] ink+amp display rename (keep bundle `com.punkrally.reader`) + twin-pages AppIcon (`b09a74b`)
- [x] Settings half of PR 6
- [x] Sideload Keychain strip for AltStore Save (`cf081e1`) — IPA baking

## Next (after Save sticks)
### UX (Ui And Design)
- [ ] Separate **Couldn’t save server** copy (not “Connection failed”)
- [ ] Empty state when URL prefilled but no saved Storyteller source
- [ ] Podcast Audio | Video picker when dual enclosures exist (remember per show)

### Engineering (Smokey / Hermes)
- [ ] Wire podcasts into **shared player** → reuse `PlaybackRateButton`
- [ ] Shelf **auto-prune** half-listened podcast downloads (+ Ui policy)
- [ ] Silence-trim spike
- [ ] AI sponsored/ad strip as async post-download pipeline (on-device / NAS / OmniRoute)

## Later / ideas (not blocking)
- True cross-device place (phone/iPad/CarPlay on Storyteller progress)
- Glance / Watch tile: now-playing + Continue deep-link into ink+amp
- One-tap LAN failover: public URL → `http://192.168.1.2:1800` on home Wi‑Fi

## Constraints
- Keep `SilveranKit`; do not merge Enve tree (modules + AGPL only)
- Storyteller = ebook / audiobook / readaloud only; podcasts = RSS rail
- AltStore unsigned IPA; no Apple Developer until we choose to
- No Expo; no Xcode on JoshNuc — GHA macOS for builds
- Grok Bot included usage may be exhausted — heavy work via Hermes/OmniRoute

## Owners
| Area | Owner |
|------|--------|
| Storyteller / NAS / Cloudflare | Nas-ty Girl |
| UX shell / Stitch / icon | Ui And Design |
| App code / PRs / IPA | Smokey Coding + Hermes |
| Triage / briefs | Chief of Staff → Omni Router |

## UX source of truth
- `UX-SHELL.md`, `DESIGN.md`, `fonts/` under NUC `silveran-ios\`
- Icon: `icons\twin-pages-final.png` (also `/workspace/punk-rally-reader/icons/`)
- Stitch: https://stitch.withgoogle.com/projects/131401596261616247?pli=1
