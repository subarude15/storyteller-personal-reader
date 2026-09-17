# Hermes — continue ink+amp (punk+rally)

Queued by Omni Router from CoS + Nas-ty. Run on OmniRoute (auto/coding:free / smokeycoding). NOT Grok Bot.

Owner path: C:\Users\imalo\dev\silveran-ios\
Repo: https://github.com/subarude15/storyteller-personal-reader
Branch: punk-rally-ios (tip should be ~82dc05f after pull)
Worktree: C:\Users\imalo\dev\silveran-ios\silveran-reader
Icon: C:\Users\imalo\dev\silveran-ios\icons\twin-pages-final.png

## Product
Private iOS reader (ink+amp): Storyteller sync ebook/audiobook/readaloud + Enve RSS podcasts + local stats.
Server: https://storyteller.banditoburrito.xyz (Access Google bypassed; app login required).
Install: AltStore + unsigned IPA. No Apple Developer. Dark Stitch; twin-pages icon.

## Already done — do NOT redo
- Silveran fork; keep SilveranKit
- Tabs Home/Library/Shelf/Podcasts/Stats
- Storyteller URL prefill
- Shelf downloads-only + mini-player
- Home Continue + sync chip (PR 4)
- CI green (Builtin/StoryAlign fix)
- Settings half of PR 6; IPA available Actions run 34916809120 → punkrally-sideload-unsigned-ipa
- UX: UX-SHELL.md, DESIGN.md, fonts/
- Icon source at icons\twin-pages-final.png

## Your job now
1. Display name → ink+amp (CFBundleDisplayName / INFOPLIST only)
2. Keep bundle id com.punkrally.reader (AltStore continuity)
3. AppIcon from twin-pages-final.png (full iOS sizes)
4. Finish any remaining PR 6 work on punk-rally-ios if still open after tip 82dc05f
5. GHA Sideload Device IPA artifact (ensure workflow cuts unsigned IPA)
6. Update SIDELOAD.md/BUILD.md if needed
7. Backlog only (do NOT block IPA): podcast Audio|Video dual enclosures; podcast speed/prune/silence/ad-strip after IPA

## Constraints
No Enve tree merge. No Expo. No Xcode on NUC — use GHA macOS. Don’t redo URL/Continue/Builtin/Settings sheet wiring.
Push to josh remote (subarude15/storyteller-personal-reader) on punk-rally-ios when ready; open/update PR if needed.
Update C:\Users\imalo\dev\silveran-ios\HERMES_PROGRESS.md as you go.

## One-liner
Continue subarude15/storyteller-personal-reader branch punk-rally-ios: rename display to ink+amp, keep com.punkrally.reader, AppIcon twin-pages-final.png, cut sideload IPA via GHA.