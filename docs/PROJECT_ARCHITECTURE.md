# Project Architecture

## Purpose

Storyteller Personal Reader is a personal iPhone/iPad application built from Silveran Reader with additional library, podcast, and activity features.

The project deliberately treats Silveran as the book engine rather than as disposable starter code.

## Core rule

**Book state belongs to Silveran. App experience belongs above Silveran.**

Silveran remains authoritative for:

- Storyteller authentication and API access
- source-scoped `BookID`
- library persistence
- EPUB parsing and reader behavior
- audiobook playback coordination
- read-aloud alignment
- book downloads
- canonical reading/listening position
- Storyteller progress upload/reconciliation

Personal Reader owns:

- Home presentation
- cover-first Library presentation
- podcast subscriptions/discovery
- podcast playback progress and queueing
- reading/listening activity tracking
- Journal/statistics presentation
- unified app navigation and Now Playing presentation

## Protected Silveran sync path

The following path is considered protected infrastructure:

`Reader / Audiobook Player -> ProgressSyncActor -> BookServiceActor -> Storyteller`

`ProgressSyncActor` already owns offline queueing, timestamp ordering, conflict resolution, local metadata updates, server reconciliation, history, and incoming server-position observation.

Features should observe or invoke the existing interfaces rather than duplicate that logic.

### Never do this

- Store a second canonical position for a Storyteller book.
- Convert podcast episodes into fake Storyteller books.
- Let activity/statistics persistence overwrite book position.
- Bypass source-scoped `BookID` with a title/author-derived identifier.
- Replace server/local timestamp reconciliation in presentation code.

## Domain boundaries

### Books

Books use Silveran models and services.

The UI may present ebook, audiobook, and read-aloud assets as one conceptual story, but the underlying Storyteller/Silveran identity remains unchanged.

### Podcasts

Podcasts are an independent domain.

Expected types include:

- `PodcastShowID`
- `PodcastEpisodeID`
- `PodcastShow`
- `PodcastEpisode`
- `PodcastSubscriptionStore`
- `PodcastProgressStore`
- `PodcastQueue`
- `PodcastDownloadManager`

Podcast progress never enters `ProgressSyncActor`.

### Activity

Activity is observational data.

Expected categories:

- ebook reading
- audiobook listening
- podcast listening

The activity layer records sessions, durations, completions, and daily aggregates. It consumes playback/reader events but does not control canonical book position.

## Initial feature boundaries

Personal-reader work should prefer these locations for new code:

```text
SilveranKit/Sources/AppleKit/PersonalReader/
├── Features/
│   ├── Home/
│   ├── Library/
│   ├── Podcasts/
│   └── Journal/
└── Services/
    ├── Activity/
    └── Podcasts/
```

The directories are introduced gradually as features gain executable code. Empty architecture-only directories are intentionally avoided because Git does not preserve them.

## UI architecture

The iPhone/iPad app will eventually expose four primary destinations:

**Home · Library · Podcasts · Journal**

Settings remains secondary.

The app shell may present one unified mini-player / Now Playing surface, but playback remains internally separated into:

- Silveran book playback
- Personal Reader podcast playback

Starting one domain must pause the other.

## Upstream philosophy

Changes inside existing Silveran core files should be minimized and justified.

Preferred order of implementation:

1. Compose existing public/internal Silveran APIs from new Personal Reader code.
2. Add narrowly scoped extension points if composition is insufficient.
3. Modify Silveran core behavior only when the feature cannot be implemented safely otherwise.

Every core modification should be evaluated for future merge conflict risk with `kyonifer/silveran-reader`.

## Licensing note

This repository retains upstream license notices. The project is intended for personal use. Any future distribution decision should trigger a fresh review of GPL/AGPL obligations and App Store constraints before release.
