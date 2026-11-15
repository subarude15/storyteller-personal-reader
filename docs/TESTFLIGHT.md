# Private TestFlight (GitHub-hosted macOS)

`.github/workflows/ios-testflight.yml` is manual-only (`workflow_dispatch`). It does not run on push or pull requests. It is separate from `ios.yml` and the AltStore `scripts/package-ipa` path, and does not reuse either.

| Mode | Needs | Does |
| --- | --- | --- |
| `validate` (default) | nothing | Builds an **unsigned** archive from the TestFlight-only project (signing explicitly disabled, `DEVELOPMENT_TEAM` cleared), then checks bundle IDs, versions, the App Group key, and that the CarPlay scene is gone. Uses no secrets, profiles, team variables, or environment approval, and makes no Apple calls. |
| `signed-archive` | assets below + approval | Imports user-provided signing assets, validates them, then signs, exports, and verifies. Does not upload. |
| `upload` | assets + ASC key + approval | Everything in `signed-archive`, then uploads for internal TestFlight testing and waits for App Store Connect processing. |

The two signed modes run in the `testflight` environment, and only from trusted refs: `refs/heads/punk-rally-ios` (the ink+amp release branch) or `refs/tags/testflight/<name>`. Upstream-tracking `main` is not trusted. `workflow_dispatch` only lists workflows that exist on the default branch (`main`), so the workflow file must be there before it can be run, and the selected release ref must contain it too. Changing the default branch is not part of this work. Signed jobs are serialized through the `ios-testflight-release` concurrency group. Before any secret is decoded, the workflow checks that the environment has required reviewers and a deployment branch policy, and fails if it doesn't.

The temporary `signed-archive` exception for `refs/heads/feature/private-testflight` has been removed. Both signed modes (`signed-archive` and `upload`) now accept only the two trusted release refs above; `tf.py check-inputs` rejects the feature branch and lookalikes for every mode.

## Verified status

- Paid team `ZN8HWD257P`, all three App IDs (`com.punkrally.reader.ZN8HWD257P`, `.widgets`, `.share`), and the App Group `group.com.punkrally.reader.ZN8HWD257P` are verified under that team.
- An unsigned `validate` run passed. The signed `signed-archive` run [41351172941](https://github.com/subarude15/storyteller-personal-reader/actions/runs/41351172941) at `b970a7caf064f9fe5212d6f1866f7f70687b8133` succeeded: archive and export succeeded, and signed verification passed for both the archive and the exported IPA (version 0.1, build 2.1). Upload was skipped by design.
- The ASC API key (`APPSTORE_API_KEY_ID`) has the **App Manager** role on a Team key (user-confirmed). That is enough for read-only lookups and upload, but not for certificate management. The upload / ASC API path has **not** been exercised remotely: the signed-archive run makes no ASC calls.
- Read-only GitHub metadata: repo variables `APPSTORE_API_KEY_ID` and `APPSTORE_ISSUER_ID` are set, the repo secret `APPSTORE_API_PRIVATE_KEY` exists, and the `testflight` environment holds the five signing secrets under their exact names, with required reviewers and a deployment policy. That policy is verified as the tag pattern `testflight/*`, with the required reviewers kept.

## Release sequence (each step needs explicit user approval)

Nothing below happens automatically, and a failed step is never retried automatically: investigate, then ask again.

1. **Publish the cleanup.** Only after approval, push the reviewed feature cleanup commit (this removal of the exception).
2. **Pick the release ref.** Either merge into `punk-rally-ios`, or, as an alternative to merging the application branch, create an approved tag `testflight/<name>` that points at the exact reviewed cleanup commit. `workflow_dispatch` needs the workflow file on `main` (already published there), and the release ref must contain it too, so the tag route needs no application merge.
3. **Change the environment policy (separate approval).** In the `testflight` environment, the user adds the release policy (tag `testflight/*` and/or branch `punk-rally-ios`) and removes the `feature/private-testflight` branch policy, keeping the required reviewers. Done for the tag route: the policy is verified as tag `testflight/*` with required reviewers. Adding branch `punk-rally-ios` would need its own approval.
4. **Optional:** run `signed-archive` from the release ref to re-verify signing there.
5. **Upload (separate explicit approval).** Before dispatching `upload`, confirm: the ASC app record matches bundle `com.punkrally.reader.ZN8HWD257P`; `APPSTORE_ISSUER_ID`/`APPSTORE_API_KEY_ID` are set and `APPSTORE_API_PRIVATE_KEY` is present; the key still has the App Manager role; the version/build algorithm (`<run_number>.<run_attempt>`, bumped above every existing ASC build) gives the expected number; export stays manual and `testFlightInternalTestingOnly=true`. The run is only a success when processing reaches `VALID` **and** a preconfigured internal group gives testers access.

Example commands for the tag route. These are for documentation only: every tag push, environment change, and dispatch below needs its own future approval. `<reviewed-cleanup-sha>` is the exact reviewed commit.

```sh
git tag -a testflight/0.1-internal-1 <reviewed-cleanup-sha> -m "TestFlight 0.1 internal 1"
git push origin refs/tags/testflight/0.1-internal-1   # explicit tag only, never --force
# (environment policy change in the GitHub UI, step 3)
gh workflow run ios-testflight.yml --repo subarude15/storyteller-personal-reader \
  --ref testflight/0.1-internal-1 -f mode=signed-archive -f marketing_version=0.1
# only after a separate explicit approval:
gh workflow run ios-testflight.yml --repo subarude15/storyteller-personal-reader \
  --ref testflight/0.1-internal-1 -f mode=upload -f marketing_version=0.1
```

## What the TestFlight build is

- **Team: `ZN8HWD257P` (VERIFIED).** The user confirmed this paid Apple Developer team directly in the portal. The repository default `9CJ7KG7UKQ` (`Configs/Common.xcconfig`) is *not* the paid team. `TestFlight.xcconfig` pins `DEVELOPMENT_TEAM = ZN8HWD257P`, and the TestFlight `project.yml` deliberately does not re-declare `DEVELOPMENT_TEAM` (doing so would mask the xcconfig). Every signing entrypoint in `tf.py` (`check-inputs --signed`, `validate-signing`, signed `verify-app`, `export-options`) rejects any other team, including `9CJ7KG7UKQ` and arbitrary well-formed 10-character IDs. The profile's `ApplicationIdentifierPrefix` is validated separately and is never assumed to equal the Team ID.
- Main app bundle ID: `com.punkrally.reader.ZN8HWD257P`. Extensions: `.widgets` (WidgetKit) and `.share`. The user has confirmed the App Store Connect app record for the main bundle ID. All three Developer Portal App IDs and the App Group `group.com.punkrally.reader.ZN8HWD257P` are verified under `ZN8HWD257P`, and the signed-archive run confirmed the profiles grant them.
- Separate inputs: `XCodeApps/TestFlight/{project.yml,TestFlight.xcconfig,App/Widgets/Share.entitlements}`. Generated Info plists go to `.build-testflight/`, which is gitignored. Shipping files are not touched: `XCodeApps/project.yml`, `Configs/*.xcconfig`, the existing entitlements and plists, `ios.yml`, and `package-ipa`. `scripts/testflight/test_tf.py` fails if the TestFlight targets drift from the shipping iOS targets (Info, sources, dependencies).
- **CarPlay:** the build omits the managed `com.apple.developer.carplay-audio` entitlement and the `CPTemplateApplicationSceneSessionRoleApplication` scene. That means no ink+amp CarPlay icon, templates, or browsing. Background audio (`UIBackgroundModes` audio/fetch) and the MPNowPlayingInfoCenter/remote-command code are unchanged, so the system Now Playing controls *should* appear through normal audio metadata. This has not been verified on a device. Do not describe this build as having CarPlay support.
- **Keychain:** the service is still `com.kyonifer.silveran.storyteller`. The access group is `$(AppIdentifierPrefix)com.kyonifer.silveran.shared`, and the prefix comes from the profile's `ApplicationIdentifierPrefix`. The workflow never assumes the prefix equals the Team ID.
- **App Group:** the default is `group.com.punkrally.reader.ZN8HWD257P`. One build setting (`APP_GROUP_ID`) feeds all three entitlements files and all three `SILVERAN_WIDGET_APP_GROUP` Info keys. Signed verification requires exactly this one group on every bundle, so the old literal `group.com.punkrally.reader` fallback can't cause a mismatch. To use the existing `group.com.punkrally.reader` instead, first verify that your paid team owns it and that it is enabled on all three App IDs. Then set the repository variable `TESTFLIGHT_APP_GROUP_ID`, which is applied to all six places together. The AltStore `ALTAppGroups` runtime logic is unchanged.
- Version: the `marketing_version` input (default `0.1`). The build number is `<run_number>.<run_attempt>`. If that is not above the highest existing ASC build (including builds still processing), it becomes `<highest major + 1>.1`. A rerun gets a new number. The workflow fails explicitly rather than emit a first component over 4 digits. App, widgets, and share all get the same `CFBundleVersion`. Tracked source is never stamped.

## Repository configuration (user, via GitHub UI)

1. **Environment `testflight`:** required reviewers plus a deployment branch/tag rule (`punk-rally-ios`, `testflight/*`). Storing the secrets below as *environment* secrets keeps them out of every other job. The verified rule is the tag `testflight/*` (step 3 of the release sequence above).
2. **Variables:** `APPLE_TEAM_ID` is optional. The signed job defaults to `ZN8HWD257P`; if the variable is set to anything else, the gate fails before any secret is decoded. Nothing falls back to `9CJ7KG7UKQ`. Also needed: the existing `APPSTORE_ISSUER_ID` and `APPSTORE_API_KEY_ID`. Optionally set `TESTFLIGHT_APP_GROUP_ID`.
3. **Secrets:** `APPLE_DISTRIBUTION_P12_BASE64`, `APPLE_DISTRIBUTION_P12_PASSWORD`, `APPLE_PROFILE_APP_BASE64`, `APPLE_PROFILE_WIDGETS_BASE64`, `APPLE_PROFILE_SHARE_BASE64`, and the existing `APPSTORE_API_PRIVATE_KEY`. The ASC key only authenticates the API; it is not used for code signing.

## What gets validated before signing (fails closed)

- **P12:** must yield exactly one *valid* code-signing identity in a throwaway keychain, which proves both the private key and the Apple chain. The certificate must be Apple Distribution with `OU` and CN team equal to `ZN8HWD257P`, currently valid, and not expiring within 24 hours.
- **Each profile:** its CMS signature must verify against the Apple roots on the runner. It must be an iOS App Store profile: no `ProvisionedDevices`, no `ProvisionsAllDevices`, `get-task-allow` false, and `beta-reports-active` true. It must not expire within 24 hours, must have `TeamIdentifier` and the `team-identifier` entitlement equal to `ZN8HWD257P`, and its `DeveloperCertificates` must contain the exact imported certificate. `application-identifier` must be exactly `<prefix>.<bundle>`, the same prefix must appear in all three profiles, and the App Group must be granted. The app profile must also allow the keychain group. Each target needs its own UUID.
- **Signing:** manual, with per-target `PROVISIONING_PROFILE_SPECIFIER` values (not one global profile). There are no automatic provisioning updates, and nothing is ever created, repaired, or revoked.
- **Archive and exported IPA:** must pass `codesign --verify --deep --strict` and be signed with the distribution authority and team. Each bundle's leaf certificate SHA-1 must equal the selected identity. Each bundle's embedded profile must be its mapped UUID. Entitlements must match an exact allow list, with no CarPlay. All three bundle IDs and versions must match.
- **Export options:** `app-store-connect`, manual, `manageAppVersionAndBuildNumber=false`, `testFlightInternalTestingOnly=true`. These keys are checked against `xcodebuild -help` for the pinned Xcode.
- **Upload:** a read-only lookup must find exactly one ASC app whose `bundleId` matches. The upload uses `xcrun altool --upload-package` with the API key, never an Apple ID password or 2FA. Fastlane is not used, which avoids a Ruby toolchain and lockfile. The job then polls processing state (up to 45 minutes) and reports it. **A finished upload does not mean testers have the build.** Testers get it only if a preconfigured internal group has automatic distribution. The workflow does not create groups, add testers, enable external testing, or submit for beta review.

## Feature validation notes

The `validate` mode also runs feature checks. Neither check uses signing or makes Apple calls.

- **Offline checks job (ubuntu):** `node scripts/spread-layout-selfcheck.mjs`. This checks the iPad spread paginator geometry against the pinned foliate-js grid math: 48pt outer margins, a 32pt gutter, and one turn equals one spread. It also checks the native curl message protocol and that the JS curl stays off while the native curl owns turns.
- **Unsigned archive job (after `setup-tools.sh` selects the pinned Xcode):** `swift test --filter 'coverTint|InkAmpPlaybackActivityTests|InkAmpLiveActivityGateTests|CarPlayBrowseTests|ReaderSpreadPolicyTests'`. This covers cover-tint math, the Live Activity content state and lifecycle gate, the CarPlay browse model, and the spread policy (thresholds, page pairs, rotation and sidebar sizes, spine opacity).
- **Run locally:** `python -m unittest discover -s scripts/testflight -p "test_*.py" -v`, `node scripts/page-turn-animator-selfcheck.mjs`, `node scripts/spread-layout-selfcheck.mjs`.

These checks do not replace device QA. Nothing has been run on a device yet: the native spread curl, CarPlay, and Live Activity are all unverified on hardware.

Secret handling: secrets are written with `umask 077` under `$RUNNER_TEMP`. The keychain password is random and masked. There is no `set -x`, no environment dumps, no artifacts, and no caches. The cleanup step runs on `always()` and deletes the keychain, profiles, and API key file. One exception: `security import` only accepts the P12 password as an argument, so it is briefly visible in the process list of the single-tenant hosted VM.

## One-time bootstrap (supervised, Windows/Linux, no Mac)

Shell examples assume Git Bash, WSL, or Linux (GNU `base64 -w0`, OpenSSL 3).

Do not run any step that creates something without explicit approval for that step. Never revoke or replace existing certificates or profiles.

1. Team ID `ZN8HWD257P`, the three App IDs, and the default App Group are verified; no variable is required. If you switch to a different App Group, verify it in the portal first and do not create anything without approval.
2. If you already have an Apple Distribution certificate *and its private key* (P12), reuse it. Otherwise, with approval, create the key and CSR locally: `openssl req -new -newkey rsa:2048 -nodes -keyout dist.key -out dist.csr -subj "/CN=ink+amp Distribution/C=US"`. Then submit the CSR through the portal, or through the ASC API `POST /v1/certificates` (`DISTRIBUTION`) if that API key's role allows it. The downloaded `.cer` is DER, so convert it first: `openssl x509 -inform DER -in dist.cer -out dist.pem`. Then build the P12: `openssl pkcs12 -export -legacy -inkey dist.key -in dist.pem -out dist.p12`. The `-legacy` flag keeps it importable by macOS `security`.
3. Create three **App Store** profiles in the portal (or with approval via the API): one per bundle ID, each including that certificate. Download the `.mobileprovision` files.
4. Store the files straight from disk. Never paste them into logs, chats, or artifacts: `base64 -w0 dist.p12 | gh secret set APPLE_DISTRIBUTION_P12_BASE64 --env testflight`, `gh secret set APPLE_DISTRIBUTION_P12_PASSWORD --env testflight` (interactive prompt), and do the same for each profile. Afterwards, delete the local copies or move them to an encrypted store.
5. Do not create a workflow or PAT that can write secrets or bootstrap signing.

**ASC key role:** the existing key (`APPSTORE_API_KEY_ID`) is a Team key with the App Manager role (user-confirmed). That covers read-only lookups and uploads. It is not suitable for certificate management (that needs Admin), so certificates and profiles stay portal-managed.

## Running TestFlight next to AltStore and moving data

- TestFlight installs as a separate app (different bundle ID and App Group). It never replaces or removes the AltStore install. Keep AltStore until you have checked the TestFlight build.
- Both apps register the `punkrally` (and `magnet`) URL schemes. With both installed, iOS can send a link to either one, so treat link handoff as unreliable until one is removed.
- **Settings → Backup → Local Backup & Restore** (in AltStore first):
  1. Enter **Backup password** (at least 8 characters) and **Confirm for export**, tap **Create Encrypted Backup**, and save the `.inkampbackup` file.
  2. In TestFlight, enter the same **Backup password**, tap **Restore Encrypted Backup**, and pick the file.
  - Included: app settings (reader, playback, sync, search, NAS), Storyteller sources with their accounts and passwords, API keys and service logins, synced settings, and the book-format link cache.
  - Not included: widget snapshots and cover thumbnails, downloaded books, podcasts, and staged torrents, temporary caches and App Group handoff queues. It is **not** a full backup of the library, local reading progress, or downloads.
- Before switching, sync reading progress to Storyteller from AltStore and confirm it on the server. Anything stored only locally (and unsupported by sync) stays in AltStore. Expect to redownload media. There is no guarantee that all reading data carries over.

## Known limits and open blockers

- macOS/Xcode archiving can't run locally; it runs on `macos-15-intel` with Xcode `26.3`, and the run fails explicitly if that Xcode is missing. The unsigned archive and the signed archive/export paths were verified remotely on `macos-15` (see Verified status), not yet on `macos-15-intel`.
- **Runner: `macos-15-intel` (ARM capacity workaround).** Both the unsigned and signed jobs moved off the Apple Silicon `macos-15` label because its hosted ARM queue was capacity-starved, which left jobs waiting instead of running. The x86_64 image is a separate pool. Nothing else changed: same Xcode pin, same signing identity, entitlements, secrets, `testflight` environment and reviewers, trusted-ref gate, internal-only upload, and no automatic retries. `ios.yml` (AltStore) stays on `macos-15`. `setup-tools.sh` still requires `/Applications/Xcode_26.3.app` and fails closed if the Intel image doesn't have it; check the runner-images readme for `macos-15` x86_64 before relying on it. The signing check prefers Homebrew OpenSSL 3 at `/usr/local/opt/openssl@3` on Intel (`/opt/homebrew/opt/openssl@3` on ARM). Required validation before any `upload`: one approved `signed-archive` run on `macos-15-intel` from a trusted ref that passes the toolchain check and signed verification of both the archive and the IPA. That run already compiles and checks every bundle, so an unsigned `validate` run first is optional. Revert to `macos-15` once ARM capacity recovers, or if the Intel image drops Xcode 26.3 or x86_64 hosted runners are retired. The upload and ASC processing paths are **unverified** until an approved `upload` run. Pinned: `actions/checkout` SHA, XcodeGen 2.46.0 zip SHA-256, the test-only PyYAML wheel hash (`scripts/testflight/requirements-test.txt`), and SwiftPM through `Package.resolved` with `-onlyUsePackageVersionsFromResolvedFile`. ImageMagick comes from Homebrew and is not pinned (same as `ios.yml`).
- Team, App IDs, App Group, signing assets, environment secrets, and the ASC key role are no longer blockers. The `testflight` environment's release policy (tag `testflight/*`, required reviewers) is verified. Still blocked on the user: approvals for each step of the release sequence. No recorded run has exercised live ASC authentication or upload yet.
- **SwiftPM warning (recommendation only, not changed):** the build warns that the direct dependency `github.com/kyonifer/ZIPFoundation` (`Package.swift`) conflicts with `github.com/weichsel/ZIPFoundation`, which comes in through `github.com/kyonifer/StoryAlign`. Both have the identity `zipfoundation`, and future SwiftPM versions will make this an error. Future fix: point StoryAlign and the root package at one canonical ZIPFoundation URL and revision that keeps the fork's fixes, regenerate `Package.resolved`, then separately regression-test archives, playback, and imports. Do not change dependencies as part of TestFlight work.
- The environment-protection check uses the job token (`actions: read`). If GitHub rejects that read, the signed job fails closed until access is sorted out.
