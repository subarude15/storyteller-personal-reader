# Private TestFlight (GitHub-hosted macOS)

`.github/workflows/ios-testflight.yml` is manual-only (`workflow_dispatch`). It does not run on push or pull requests. It is separate from `ios.yml` and the AltStore `scripts/package-ipa` path, and does not reuse either.

| Mode | Needs | Does |
| --- | --- | --- |
| `validate` (default) | nothing | Builds an **unsigned** archive from the TestFlight-only project (signing explicitly disabled, `DEVELOPMENT_TEAM` cleared), then checks bundle IDs, versions, the App Group key, and that the CarPlay scene is gone. Uses no secrets, profiles, team variables, or environment approval, and makes no Apple calls. |
| `signed-archive` | assets below + approval | Imports user-provided signing assets, validates them, then signs, exports, and verifies. Does not upload. |
| `upload` | assets + ASC key + approval | Everything in `signed-archive`, then uploads for internal TestFlight testing and waits for App Store Connect processing. |

The two signed modes run in the `testflight` environment, and only from trusted refs: `refs/heads/punk-rally-ios` (the ink+amp release branch) or `refs/tags/testflight/<name>`. Upstream-tracking `main` is not trusted. `workflow_dispatch` only lists workflows that exist on the default branch (`main`), so the workflow file must be there before it can be run, and the selected release ref must contain it too. Changing the default branch is not part of this work. Signed jobs are serialized through the `ios-testflight-release` concurrency group. Before any secret is decoded, the workflow checks that the environment has required reviewers and a deployment branch policy, and fails if it doesn't.

**Temporary validation-only exception:** `refs/heads/feature/private-testflight` (exact ref) is accepted for `signed-archive` only, so signing can be validated before release-ref setup. `upload` from that branch is still rejected by the `tf.py check-inputs` gate. The protected `testflight` environment (required reviewers, deployment branch policy) is unchanged, so its branch policy must also allow this branch for the run to proceed. Remove the exception (`SIGNED_ARCHIVE_ONLY_REF` in `tf.py`) once validation is done.

## What the TestFlight build is

- **Team: `ZN8HWD257P` (VERIFIED).** The user confirmed this paid Apple Developer team directly in the portal. The repository default `9CJ7KG7UKQ` (`Configs/Common.xcconfig`) is *not* the paid team. `TestFlight.xcconfig` pins `DEVELOPMENT_TEAM = ZN8HWD257P`, and the TestFlight `project.yml` deliberately does not re-declare `DEVELOPMENT_TEAM` (doing so would mask the xcconfig). Every signing entrypoint in `tf.py` (`check-inputs --signed`, `validate-signing`, signed `verify-app`, `export-options`) rejects any other team, including `9CJ7KG7UKQ` and arbitrary well-formed 10-character IDs. The profile's `ApplicationIdentifierPrefix` is validated separately and is never assumed to equal the Team ID.
- Main app bundle ID: `com.punkrally.reader.ZN8HWD257P`. Extensions: `.widgets` (WidgetKit) and `.share`. The user has confirmed the App Store Connect app record for the main bundle ID. Whether all three Developer Portal App IDs and the App Group (plus its capability grants) are registered under `ZN8HWD257P` is **unverified**: a read-only portal inspection was attempted but could not read the page due to a browser tooling restriction.
- Separate inputs: `XCodeApps/TestFlight/{project.yml,TestFlight.xcconfig,App/Widgets/Share.entitlements}`. Generated Info plists go to `.build-testflight/`, which is gitignored. Shipping files are not touched: `XCodeApps/project.yml`, `Configs/*.xcconfig`, the existing entitlements and plists, `ios.yml`, and `package-ipa`. `scripts/testflight/test_tf.py` fails if the TestFlight targets drift from the shipping iOS targets (Info, sources, dependencies).
- **CarPlay:** the build omits the managed `com.apple.developer.carplay-audio` entitlement and the `CPTemplateApplicationSceneSessionRoleApplication` scene. That means no ink+amp CarPlay icon, templates, or browsing. Background audio (`UIBackgroundModes` audio/fetch) and the MPNowPlayingInfoCenter/remote-command code are unchanged, so the system Now Playing controls *should* appear through normal audio metadata. This has not been verified on a device. Do not describe this build as having CarPlay support.
- **Keychain:** the service is still `com.kyonifer.silveran.storyteller`. The access group is `$(AppIdentifierPrefix)com.kyonifer.silveran.shared`, and the prefix comes from the profile's `ApplicationIdentifierPrefix`. The workflow never assumes the prefix equals the Team ID.
- **App Group:** the default is `group.com.punkrally.reader.ZN8HWD257P`. One build setting (`APP_GROUP_ID`) feeds all three entitlements files and all three `SILVERAN_WIDGET_APP_GROUP` Info keys. Signed verification requires exactly this one group on every bundle, so the old literal `group.com.punkrally.reader` fallback can't cause a mismatch. To use the existing `group.com.punkrally.reader` instead, first verify that your paid team owns it and that it is enabled on all three App IDs. Then set the repository variable `TESTFLIGHT_APP_GROUP_ID`, which is applied to all six places together. The AltStore `ALTAppGroups` runtime logic is unchanged.
- Version: the `marketing_version` input (default `0.1`). The build number is `<run_number>.<run_attempt>`. If that is not above the highest existing ASC build (including builds still processing), it becomes `<highest major + 1>.1`. A rerun gets a new number. The workflow fails explicitly rather than emit a first component over 4 digits. App, widgets, and share all get the same `CFBundleVersion`. Tracked source is never stamped.

## Repository configuration (user, via GitHub UI)

1. **Environment `testflight`:** add required reviewers and a deployment branch/tag rule (`punk-rally-ios`, `testflight/*`). Storing the secrets below as *environment* secrets keeps them out of every other job.
2. **Variables:** `APPLE_TEAM_ID` is optional. The signed job defaults to `ZN8HWD257P`; if the variable is set to anything else, the gate fails before any secret is decoded. Nothing falls back to `9CJ7KG7UKQ`. Also needed: the existing `APPSTORE_ISSUER_ID` and `APPSTORE_API_KEY_ID`. Optionally set `TESTFLIGHT_APP_GROUP_ID`.
3. **Secrets:** `APPLE_DISTRIBUTION_P12_BASE64`, `APPLE_DISTRIBUTION_P12_PASSWORD`, `APPLE_PROFILE_APP_BASE64`, `APPLE_PROFILE_WIDGETS_BASE64`, `APPLE_PROFILE_SHARE_BASE64`, and the existing `APPSTORE_API_PRIVATE_KEY`. The ASC key only authenticates the API; it is not used for code signing.

## What gets validated before signing (fails closed)

- **P12:** must yield exactly one *valid* code-signing identity in a throwaway keychain, which proves both the private key and the Apple chain. The certificate must be Apple Distribution with `OU` and CN team equal to `ZN8HWD257P`, currently valid, and not expiring within 24 hours.
- **Each profile:** its CMS signature must verify against the Apple roots on the runner. It must be an iOS App Store profile: no `ProvisionedDevices`, no `ProvisionsAllDevices`, `get-task-allow` false, and `beta-reports-active` true. It must not expire within 24 hours, must have `TeamIdentifier` and the `team-identifier` entitlement equal to `ZN8HWD257P`, and its `DeveloperCertificates` must contain the exact imported certificate. `application-identifier` must be exactly `<prefix>.<bundle>`, the same prefix must appear in all three profiles, and the App Group must be granted. The app profile must also allow the keychain group. Each target needs its own UUID.
- **Signing:** manual, with per-target `PROVISIONING_PROFILE_SPECIFIER` values (not one global profile). There are no automatic provisioning updates, and nothing is ever created, repaired, or revoked.
- **Archive and exported IPA:** must pass `codesign --verify --deep --strict` and be signed with the distribution authority and team. Each bundle's leaf certificate SHA-1 must equal the selected identity. Each bundle's embedded profile must be its mapped UUID. Entitlements must match an exact allow list, with no CarPlay. All three bundle IDs and versions must match.
- **Export options:** `app-store-connect`, manual, `manageAppVersionAndBuildNumber=false`, `testFlightInternalTestingOnly=true`. These keys are checked against `xcodebuild -help` for the pinned Xcode.
- **Upload:** a read-only lookup must find exactly one ASC app whose `bundleId` matches. The upload uses `xcrun altool --upload-package` with the API key, never an Apple ID password or 2FA. Fastlane is not used, which avoids a Ruby toolchain and lockfile. The job then polls processing state (up to 45 minutes) and reports it. **A finished upload does not mean testers have the build.** Testers get it only if a preconfigured internal group has automatic distribution. The workflow does not create groups, add testers, enable external testing, or submit for beta review.

Secret handling: secrets are written with `umask 077` under `$RUNNER_TEMP`. The keychain password is random and masked. There is no `set -x`, no environment dumps, no artifacts, and no caches. The cleanup step runs on `always()` and deletes the keychain, profiles, and API key file. One exception: `security import` only accepts the P12 password as an argument, so it is briefly visible in the process list of the single-tenant hosted VM.

## One-time bootstrap (supervised, Windows/Linux, no Mac)

Shell examples assume Git Bash, WSL, or Linux (GNU `base64 -w0`, OpenSSL 3).

Do not run any step that creates something without explicit approval for that step. Never revoke or replace existing certificates or profiles.

1. Team ID `ZN8HWD257P` is already verified; no variable is required. Still unverified: whether `com.punkrally.reader.ZN8HWD257P`, `.widgets`, and `.share` are registered under that team, and whether the chosen App Group is registered and enabled on all three. Check this in the portal yourself; until then treat ownership and availability as unknown and do not create anything.
2. If you already have an Apple Distribution certificate *and its private key* (P12), reuse it. Otherwise, with approval, create the key and CSR locally: `openssl req -new -newkey rsa:2048 -nodes -keyout dist.key -out dist.csr -subj "/CN=ink+amp Distribution/C=US"`. Then submit the CSR through the portal, or through the ASC API `POST /v1/certificates` (`DISTRIBUTION`) if that API key's role allows it. The downloaded `.cer` is DER, so convert it first: `openssl x509 -inform DER -in dist.cer -out dist.pem`. Then build the P12: `openssl pkcs12 -export -legacy -inkey dist.key -in dist.pem -out dist.p12`. The `-legacy` flag keeps it importable by macOS `security`.
3. Create three **App Store** profiles in the portal (or with approval via the API): one per bundle ID, each including that certificate. Download the `.mobileprovision` files.
4. Store the files straight from disk. Never paste them into logs, chats, or artifacts: `base64 -w0 dist.p12 | gh secret set APPLE_DISTRIBUTION_P12_BASE64 --env testflight`, `gh secret set APPLE_DISTRIBUTION_P12_PASSWORD --env testflight` (interactive prompt), and do the same for each profile. Afterwards, delete the local copies or move them to an encrypted store.
5. Do not create a workflow or PAT that can write secrets or bootstrap signing.

**Flag:** the role of the existing ASC API key (`APPSTORE_API_KEY_ID`) is unknown. Read-only lookups and uploads need at least App Manager/Developer-level access. Certificate creation needs Admin. Confirm the role before relying on it.

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

- macOS/Xcode archiving can't run locally. The archive, signing, and upload paths are **unverified** until an approved run on `macos-15` with Xcode `26.3`, and the run fails explicitly if that Xcode is missing. No remote CI has been run for this change. Pinned: `actions/checkout` SHA, XcodeGen 2.46.0 zip SHA-256, the test-only PyYAML wheel hash (`scripts/testflight/requirements-test.txt`), and SwiftPM through `Package.resolved` with `-onlyUsePackageVersionsFromResolvedFile`. ImageMagick comes from Homebrew and is not pinned (same as `ios.yml`).
- Team ID `ZN8HWD257P` is verified and no longer a blocker. The ASC app record for the main bundle is user-confirmed. Unverified: Developer Portal registration/ownership of the three App IDs and the App Group (and its capability grants) under that team. Still blocked on the user: the three App Store profiles plus the P12, protection rules on the `testflight` environment, and the ASC key role.
- The environment-protection check uses the job token (`actions: read`). If GitHub rejects that read, the signed job fails closed until access is sorted out.
