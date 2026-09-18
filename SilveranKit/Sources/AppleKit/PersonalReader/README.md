# Personal Reader Feature Boundary

This directory is the preferred home for iPhone/iPad functionality that belongs to Storyteller Personal Reader rather than upstream Silveran.

Planned structure:

```text
PersonalReader/
├── Features/
│   ├── Home/
│   ├── Library/
│   ├── Podcasts/
│   └── Journal/
└── Services/
    ├── Activity/
    └── Podcasts/
```

Directories should be created when they contain executable code rather than as empty placeholders.

## Rules

- Use Silveran book identity, library, reader, playback, and Storyteller progress APIs instead of duplicating them.
- Podcast identity/progress must remain separate from `ProgressSyncActor`.
- Activity services observe playback/reading; they do not own canonical book progress.
- Prefer composition and narrowly scoped adapters over modifying upstream core actors.
- Any required change to Silveran core should include regression coverage and a note explaining why an extension point was insufficient.
