# Explore — Authorized Sources Only

> **Board policy:** Explore never bundles piracy, never scrapes Audible logins, and never strips DRM. This folder enforces the lawful boundary.

Reference for what **not** to copy: PlayTorrio v3 (pirate bundle) — https://github.com/ayman708-UX/PlayTorrioV3 — which bulk-scrapes LibGen/Z-Lib/Anna’s Archive, logs into Audible, and strips DRM. ink+amp’s board explicitly bans bundling that path.

---

## Allowed transports

| Transport | Code | How it enters the app |
|-----------|------|----------------------|
| **Public OPDS / Atom** | `OPDSCatalogs.builtIn` in `OPDSCatalog.swift` + `OPDSCatalogService` | Curated https allow-list shipped with the app (Gutenberg, Standard Ebooks, Internet Archive, Feedbooks, Open Library Atom). |
| **Your OPDS** | `OPDSCatalogStore` + `OPDSCatalogService.fetchUserCatalog` | User pastes any https OPDS/Atom URL they control (public library, publisher store, self-hosted Komga/Kavita/Calibre-Web). Validated, persisted in `UserDefaults` (`explore.userOPDSCatalogs`). |
| **Direct https link** | `DirectLinkIngestService` | User pastes a direct `https://…/*.epub|*.cbz|*.m4b|*.m4a|*.mp3|*.zip`. Validated (https + allow-listed extension + HEAD probe) then downloaded. |
| **BYO debrid / torrent link** | `BYOTransportService` | User authenticates to *their own* debrid provider (Real-Debrid / AllDebrid / Premiumize) and pastes **one** magnet/https link they supply. Single-link unrestrict only; no bundled index search, no default tracker list. |

All downloads require an explicit **Add to Library** tap and are tagged with an `AcquisitionProvenance` (`AuthorizedTransport` + source name).

## Forbidden

- Bundled pirate indexes (LibGen, Z-Library, Anna’s Archive, etc.).
- Audible login scrape / `activation_bytes` / session-cookie flows.
- Any DRM removal (LCP, Adobe ACSM, Audible AAX/AAXC).
- Hardcoded torrent-index search or default tracker list.
- Auto-ingest without a user tap on a lawful source.

`grep -R "libgen\|annas-archive\|z-lib\|activation_bytes" --include="*.swift" SilveranKit` should return **nothing** (except this doc).

## Metadata discovery vs. download

- `ExploreWishlistService` wraps **Open Library** (`openlibrary.org/search.json`) and **Hardcover** (`HardcoverActor`) as **wishlist/search only**: title, author, cover, description, “Not in Library” badge.
- Selecting a wishlist result never downloads. The user chooses a lawful transport (A–D) and taps **Add to Library** to actually acquire the file.
- `ExploreMoreLikeThisService` is **library-only** (`moreLike(_:in:)` scores author/series/tag/narrator overlap inside `[BookMetadata]`). No network calls.

## Adding a new public OPDS catalog

1. Verify the feed is publisher-authorized or public-domain (host it lawfully serves only content it has the right to distribute).
2. Confirm it speaks OPDS 1.2 or Atom 1.0 over `https`.
3. Add an entry to `OPDSCatalogs.builtIn` in `OPDSCatalog.swift`:
   ```swift
   OPDSCatalog(
       id: "my-publisher",
       name: "My Publisher",
       url: URL(string: "https://publisher.example/opds")!,
       provenance: "Licensed — My Publisher OPDS"
   )
   ```
4. Ensure `OPDSCatalogService.allowedMIMETypes` still covers its `Content-Type` and `OPDSSimpleXMLParser` can find its `<entry>` markers.
5. No other code change needed — the UI picks up the new catalog automatically.

## Adding a new BYO debrid provider

1. Add a case to `BYOProvider`.
2. Implement a single-link `unrestrict` method in `BYOTransportService` (no search, no listing).
3. Store the token via `setToken(_:for:)` (Keychain in the app shell; `UserDefaults` fallback in the Kit target).
4. Document the provider’s `displayName` and auth flow in Settings copy.

## Cursor

Paste `docs/cursor-paste-explore-authorized.md` into Cursor to extend Explore. It contains the full ban/allow checklist and acceptance criteria. If any prior prompt asks for the PlayTorrio path, this folder’s bans win.

## Tests

- `ExploreLawfulGuardrailTests` (if present) asserts no banned hosts and lawful transports compile.
- Manual: add a public OPDS book → verify badge says “via … OPDS” → Add to Library → confirm no DRM step.
