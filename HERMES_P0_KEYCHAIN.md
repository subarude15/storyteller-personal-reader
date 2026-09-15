# P0 — Sideload Keychain fix (AltStore Storyteller Save)

From Smokey Coding. OmniRoute / Hermes smokeycoding. Branch punk-rally-ios on subarude15/storyteller-personal-reader.
Worktree: C:\Users\imalo\dev\silveran-ios\silveran-reader

## Bug
Josh can Test Connection to Storyteller but Save fails with “Connection failed.”

Root cause: createBookSource → AuthenticationActor.saveCredentials → SecurityKeychainStore uses Info.plist KEYCHAIN_ACCESS_GROUP ($(AppIdentifierPrefix)com.kyonifer.silveran.shared). Sideload entitlements still declare keychain-access-groups. Free AltStore signing can’t use that shared group → Keychain write throws → createBookSource returns nil → StorytellerServerSettingsView.failureMessageForCurrentSource returns literal “Connection failed.” for new sources (sourceID nil).

SIDELOAD.md claims “Keychain Access Groups | Fallback to default” but Sideload target still sets KEYCHAIN_ACCESS_GROUP in Info and keeps the entitlement — fix the mismatch.

## Fix (do these)
1. Silveran Reader Sideload (iOS): omit KEYCHAIN_ACCESS_GROUP from Info-iOS-Sideload (or empty) so SecurityKeychainStore.accessGroup is nil.
2. Strip keychain-access-groups from SilveranReaderSideload.entitlements (or empty array).
3. Optionally improve failureMessageForCurrentSource to “Couldn’t save credentials (Keychain)” when create fails for new Storyteller sources.
4. Ship new Sideload IPA via GHA; push to josh/punk-rally-ios.

## Do NOT redo
ink+amp display rename, AppIcon, Settings sheets, URL prefill, Continue, Builtin.

Update C:\Users\imalo\dev\silveran-ios\HERMES_PROGRESS.md when done.
## ADDENDUM (Smokey)
Tip Sideload IPA Info.plist has KEYCHAIN_ACCESS_GROUP=`com.kyonifer.silveran.shared` with AppIdentifierPrefix empty because package-ipa sets CODE_SIGNING_ALLOWED=NO. That’s why AltStore resign mismatches. Same fix — omit the key from Sideload Info + strip entitlement.
