# P0 follow-up — Keychain -34018 on Sideload IPA

After cf081e1 (KEYCHAIN_ACCESS_GROUP omitted), Josh still gets Keychain -34018 on new Sideload IPA. loadCredentials/saveCredentials both fail with unableToLoad(status: -34018).

## Fix
In SecurityKeychainStore.baseQuery, when accessGroup is nil (sideload), do NOT set kSecUseDataProtectionKeychain (or set false). That flag commonly causes errSecMissingEntitlement under free AltStore resign even without a shared group.

Also keep URL scheme required (http/https) — bare host:port hits Invalid base URL.

Optional: sideload-only file-backed credential store if Keychain still fails after that.

## Do NOT redo
icon / ink+amp name / Settings sheets.

Branch: punk-rally-ios on josh remote (subarude15/storyteller-personal-reader).
Worktree: C:\Users\imalo\dev\silveran-ios\silveran-reader
Push + new GHA Sideload IPA when fixed.
Update C:\Users\imalo\dev\silveran-ios\HERMES_PROGRESS.md