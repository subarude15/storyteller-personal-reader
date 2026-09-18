# Next cut — Library/Shelf tap does nothing on downloaded titles

Keychain P0 cleared (86a9edd — omit kSecUseDataProtectionKeychain). Josh confirmed Storyteller Save works.

## Bug
Library/Shelf tap on a **downloaded** ebook/audiobook/readaloud does nothing (no player/reader opens).

## Reproduce
1. Download a title
2. Tap it on Library or Shelf
3. Expect player/reader to open

## Fix goals
- Wire tap → open player/reader for downloaded ebook/audiobook/readaloud
- If open still fails, show toast: “Can’t open yet · try again”
- Report root cause + PR/IPA

## Do NOT redo
icon / ink+amp name / Settings / Keychain

Branch: punk-rally-ios · Worktree: C:\Users\imalo\dev\silveran-ios\silveran-reader
Push to josh + new Sideload IPA when fixed.
Update C:\Users\imalo\dev\silveran-ios\HERMES_PROGRESS.md