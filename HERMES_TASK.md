# HERMES TASK — punk+rally / Silveran iOS merge (OmniRoute)

You are Hermes on JoshNuc13Pro. Inference is already OmniRoute custom `auto/coding:free` (free first). Do NOT use paid Grok Bot credits.

## Goal
Fork/build on kyonifer/silveran-reader (already cloned at C:\Users\imalo\dev\silveran-ios\silveran-reader). Keep SilveranKit (EPUB/SMIL, Storyteller actors, progress sync). Do NOT merge opisaac9001/Enve-Book-Player as a whole repo (reference clone at C:\Users\imalo\dev\silveran-ios\Enve-Book-Player for porting modules only).

## Port from Enve as MODULES ONLY
1. Prettier library chrome
2. Reading stats
3. RSS podcasts rail (podcasts are NOT Storyteller/OPDS)

## Constraints
- Storyteller book kinds only: ebook / audiobook / readaloud
- Default Storyteller URL: https://storyteller.banditoburrito.xyz (Auth + OPDS; Cloudflare Access Google gate is OFF)
- iOS shell tabs from Ui: Home / Library / Shelf / Podcasts / Stats
- Read UX specs (mandatory): 
  - C:\Users\imalo\dev\silveran-ios\UX-SHELL.md
  - C:\Users\imalo\dev\silveran-ios\DESIGN.md
- Dark Stitch is the visual reference; Fast Font in reader; light Stitch skipped
- Enve is AGPL-3.0 — treat ported files as copyleft-aware (note LICENSE / ATTRIBUTION for ported modules)
- iOS-first; do NOT burn cycles on Android/Linux unless asked

## Known environment blocker
This machine is Windows (JoshNuc13Pro). There is no Xcode here. You CANNOT produce a verified `xcodebuild` success on this host. Work product should be:
1. Swift/iOS project changes that are structurally ready for Xcode on a Mac / Cursor iOS Mac build
2. A BUILD.md with exact steps for Joshua to build on Mac/Xcode
3. Progress notes + blockers file at C:\Users\imalo\dev\silveran-ios\HERMES_PROGRESS.md

## Done criteria (adjusted for Windows)
- iOS app shell implements Ui tabs: Home / Library / Shelf / Podcasts / Stats
- Storyteller default URL set to https://storyteller.banditoburrito.xyz
- Podcasts = Enve-style RSS rail (not OPDS)
- Stats + prettier library chrome present WITHOUT replacing SilveranKit sync core
- AGPL attribution for ported Enve modules
- HERMES_PROGRESS.md updated with what shipped and what still needs a Mac build

## Working rules
- Work inside C:\Users\imalo\dev\silveran-ios\silveran-reader (create a branch `punk-rally-ios` if useful)
- Prefer small commits locally; do not force-push; do not push unless a remote fork exists and you were asked
- Read UX-SHELL.md + DESIGN.md before changing UI
- Start by inventorying Silveran iOS targets and Enve modules to port, then implement iteratively
- When stuck, write the blocker into HERMES_PROGRESS.md and continue on the next unblocked slice

Begin now.
## UPDATE 2026-09-14 09:09 ET (from Smokey + Ui)
DONE WHEN (Windows NUC first slice — DO NOT stall for Mac):
- Xcode-ready iOS sources under C:\Users\imalo\dev\silveran-ios\
- BUILD.md + HERMES_PROGRESS.md written
- NOT required: xcodebuild on this host

Ui shell pack now on disk:
- UX-SHELL.md, DESIGN.md (already)
- fonts\Fast_Serif.ttf (default body), Fast_Sans, Fast_Sans_Dotted, Fast_OpenDyslexic, Fast_Mono
- stitch\stitch-01.png … stitch-10.png (prefer 02 Home, 03 Library, 07 Now Playing, 08 Reader, 10 overview)
- Accent #E85D04 · gold #E1B46E · dark bg #0B0B0C
- Light Stitch abandoned — ship dark chrome as visual reference

Tabs exact: Home · Library · Shelf · Podcasts · Stats
