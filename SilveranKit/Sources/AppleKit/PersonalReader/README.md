# Personal Reader Feature Boundary

This directory is the preferred home for iPhone/iPad functionality that belongs to Storyteller Personal Reader rather than upstream Silveran.

Planned structure:

```text
PersonalReader/
├── Features/
│   ├── Home/
│   ├── Library/
│   ├── Podcasts/
│   ├── Journal/
│   └── Explore/            # lawful-only: public OPDS/Atom, user OPDS, direct https, BYO debrid link (no pirate bundle)
└── Services/
    ├── Activity/
    └── Podcasts/
```

Explore is lawful-only per `Features/Explore/README.md` and `docs/cursor-paste-explore-authorized.md`:
no bundled pirate indexes, no Audible login scrape, no DRM strip; Open Library/Hardcover are
wishlist/search (metadata-only); “More like this” is library-only until Add to Library.

Directories should be created when they contain executable code rather than as empty placeholders.

## Rules

- Use Silveran book identity, library, reader, playback, and Storyteller progress APIs instead of duplicating them.
- Podcast identity/progress must remain separate from `ProgressSyncActor`.
- Activity services observe playback/reading; they do not own canonical book progress.
- Prefer composition and narrowly scoped adapters over modifying upstream core actors.
- Any required change to Silveran core should include regression coverage and a note explaining why an extension point was insufficient.
