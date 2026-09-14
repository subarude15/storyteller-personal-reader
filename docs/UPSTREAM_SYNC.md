# Updating From Silveran Upstream

This repository is intentionally kept close to `kyonifer/silveran-reader` so improvements to Storyteller integration, progress sync, reader behavior, and playback can continue to flow into the personal app.

## Remotes

A local checkout should use:

```bash
git remote -v
git remote add upstream https://github.com/kyonifer/silveran-reader.git
```

If `upstream` already exists, do not add it again.

Fetch both repositories before an update:

```bash
git fetch origin
git fetch upstream
```

## Recommended update flow

Never merge upstream directly into a feature branch.

1. Make sure local `main` matches `origin/main`.
2. Create an integration branch from current `main`.
3. Merge the latest upstream `main` into the integration branch.
4. Resolve conflicts while preserving the Personal Reader architectural guardrails.
5. Run the Silveran test suite and personal-reader guardrail tests.
6. Build the iOS target.
7. Manually validate Storyteller login, library refresh, ebook open, audiobook playback, and cross-format position behavior.
8. Open a dedicated upstream-sync PR.
9. Squash/merge only after validation is green.

Example:

```bash
git checkout main
git pull --ff-only origin main
git checkout -b maintenance/sync-silveran-YYYYMMDD
git merge upstream/main
swift test
```

Use the repository's normal iOS build helper for the iOS build after tests pass.

## Conflict priority

When an upstream merge conflicts, use this priority order:

1. Preserve upstream fixes in Storyteller, progress, reader, and playback code whenever possible.
2. Preserve Personal Reader feature code inside its dedicated boundaries.
3. Re-apply small app-shell adaptations on top of current upstream behavior rather than preserving stale copies of Silveran internals.
4. Never resolve a conflict by creating a second progress/sync path.

## Files considered high-risk

Changes involving these areas deserve extra review:

- `SilveranKit/Sources/Kit/Actors/ProgressSyncActor.swift`
- `SilveranKit/Sources/Kit/Actors/BookServiceActor.swift`
- `SilveranKit/Sources/Kit/Actors/storyteller/`
- reader session/progress code
- audiobook/session playback actors
- Storyteller book/source identity models

A merge conflict in one of these files is not automatically bad, but it should never be resolved mechanically.

## Personal Reader ownership

Prefer placing app-specific additions under:

```text
SilveranKit/Sources/AppleKit/PersonalReader/
```

This keeps most future upstream merges boring, which is exactly what we want.

## Regression checklist after every upstream sync

- Storyteller credentials still validate.
- Remote library refresh succeeds.
- A dual-format book displays once as one story.
- Ebook opens at the expected position.
- Audiobook starts at the expected corresponding position.
- Switching ebook -> audiobook preserves conceptual location.
- Switching audiobook -> ebook preserves conceptual location.
- Offline progress survives relaunch and eventually uploads.
- A newer server position wins over stale local progress.
- A newer local queued position is not replaced by stale server progress.
- Podcast state does not appear in Storyteller progress queues.
- Reading/listening statistics do not alter canonical book progress.
