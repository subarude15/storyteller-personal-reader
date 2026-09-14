# Storyteller Personal Reader — Roadmap

## Product goal

Build a personal iPhone/iPad reading and listening app on top of Silveran Reader.

Silveran remains authoritative for Storyteller integration, ebook/audiobook position synchronization, audiobook playback, ebook rendering, read-aloud behavior, and book downloads.

Selected Enve Book Player concepts and components will be adapted for podcast subscriptions/playback, activity statistics, a reading journal, and a richer cover-first library.

The defining product principle is:

> A book is one story with multiple ways to consume it: Read, Listen, or Read Along.

Changing formats must never feel like switching between unrelated media items.

## Architectural guardrails

- `ProgressSyncActor` is protected infrastructure. Do not rewrite or bypass it for app features.
- Storyteller authentication, source-scoped `BookID`, locator serialization, and server/local timestamp reconciliation remain Silveran-owned.
- Podcasts use their own identity and progress stores and must never enter Storyteller progress synchronization.
- Statistics observe reading/listening activity. They never become canonical progress storage.
- Prefer new personal-reader feature boundaries over invasive edits to upstream Silveran files.
- Keep the fork easy to update from `kyonifer/silveran-reader`.

## ✅ PR001 — Foundation & upstream safety

Completed and merged.

- Document product architecture and protected Silveran boundaries.
- Document upstream synchronization workflow.
- Create initial personal-feature namespaces for Home, Library, Podcasts, Journal, Activity, and Podcast services.
- Add progress-model regression tests that establish core progress semantics before UI work begins.
- No intentional runtime UX changes.

## 🚧 PR002 — Personal app shell

In progress.

Introduce the iPhone/iPad shell with primary navigation:

**Home · Library · Podcasts · Journal**

Settings remains secondary. Add a persistent mini-player presentation that can later represent either book or podcast playback while leaving Silveran's reader/player engines intact.

Implementation notes:

- New Personal Reader shell lives alongside the upstream Silveran iOS shell.
- iOS entry point routes through the Personal Reader shell.
- Home and Library reuse Silveran views/data directly.
- Podcasts and Journal begin as explicit placeholders for their later feature PRs.
- Existing Silveran ebook/audiobook players, restore behavior, background progress sync, deep links, and mini-player remain in use.

## PR003 — Home & library redesign

Build a cover-first Home and Library experience using Silveran library and progress models.

Home includes current story, Continue, Recently Added, Finished, and Downloaded sections. Library includes adaptive grid/list presentation, search, filters, author/series browsing, sorting, and richer book detail.

When both ebook and audiobook formats exist, the UI represents them as one conceptual book with Read, Listen, and Read Along actions.

## PR004 — Activity tracking foundation

Add observational reading/listening session tracking with separate audiobook, ebook, and podcast activity categories.

Track daily totals, per-item totals, sessions, completions, and streaks without changing canonical Storyteller progress.

## PR005 — Journal & reading statistics

Create the Journal surface with weekly reading/listening totals, books finished, episodes finished, current/longest streaks, recent sessions, and per-book history. Add a year heatmap after validating daily-history cost and persistence.

## PR006 — Podcast data foundation

Adapt podcast infrastructure for RSS subscriptions and Apple podcast-directory discovery.

Introduce dedicated `PodcastShow`, `PodcastEpisode`, subscription, feed parsing, and persistence types. Podcast identity stays independent from Storyteller books.

## PR007 — Podcast library & discovery UI

Build the Podcasts tab with Up Next, Latest Episodes, Shows, Downloads, Discover, show pages, episode pages, subscription state, played state, and download state.

## PR008 — Podcast playback, queue & downloads

Add podcast playback, independent progress, queueing, auto-queue rules, variable speed, seek controls, sleep timer, Now Playing integration, AirPlay, resume, and offline downloads.

Only one audio domain may own playback at a time.

## PR009 — Unified Now Playing & CarPlay

Create one presentation layer over book and podcast playback. Extend CarPlay for books, podcasts, Up Next, and downloads while keeping podcast progress isolated from Storyteller sync.

## PR010 — iPad, widgets & polish

Finish the daily-driver experience with responsive iPad layouts, widgets, background refresh, storage management, podcast auto-download rules, accessibility, performance profiling, and a full Storyteller sync regression pass.

## Later candidates

- Apple Watch podcast controls/playback
- Siri/App Intents
- reading goals
- OPML podcast import/export
- smart collections
- podcast chapters and artwork
- transcript support
- search across podcast show notes
- reading-session notes
- ratings/reviews
- statistics export
